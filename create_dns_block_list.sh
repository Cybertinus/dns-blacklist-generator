#!/bin/bash

##########
# CONFIG #
##########

# List of the environments you want to generate blocklists for.
#  syntax: <name_environment>:<recursor_software>:<ip_recursor>
#  currently supported recursor softwares: Unbound (unbound) and PowerDNS (pdns)
envs="main:unbound:10.0.0.1 guest:pdns:10.0.1.1"
logfile="/var/log/dns_update_blacklist.log"

#################
# ACTUAL SCRIPT #
#################

### GENERIC ###

# Create a directory to save some temp files
scratchdir="$(mktemp -d)"
cd "${scratchdir}"

# Cleanup when done
trap "cd; rm -rf "${scratchdir}";" EXIT SIGINT SIGTERM SIGKILL

# Generate the errorlog file name bases on the normale logfile name
error_logfile="$(echo "${logfile}" | sed 's/\.log$/_error.log/')"
# Rotate the logfiles, to also keep the last one
mv ${logfile}{,.1}
mv ${error_logfile}{,.1}
# Save the output in seperate logfiles
exec >> ${logfile}
exec 2>> ${error_logfile}

# File in which Pi-Hole defines their sources for the blacklists
# Old command, from before the 4.0 release
#blacklist_urls="$(curl https://raw.githubusercontent.com/pi-hole/pi-hole/master/adlists.default 2>/dev/null | grep ^http)"
# New command needed since the PiHole 4.0 release
blacklist_urls="$(curl https://raw.githubusercontent.com/pi-hole/pi-hole/master/automated%20install/basic-install.sh 2>/dev/null| awk -F\" '/echo "http/ {print $2}')"
totalurls="$(echo "${blacklist_urls}" | wc -l)"
if [ "${totalurls}" -eq 0 ] ; then
	echo "Failed to download the source URLs" 1>&2
	exit 1
fi

# Loop through all the source urls found
counter=1
for url in $blacklist_urls; do
	# Extract the domain for the current source URL
	domain="$(echo $url | awk -F\/ '{print $3}')"

	# Define in which file this should be placed
	filename="${counter}.${domain}.list"
	echo "Downloading ${counter}/${totalurls} (${url})..."
	# Download the sourcefile, and remove empty lines, comments, and some common words that need to continue working
	curl "${url}" 2>/dev/null | \
	  dos2unix | \
	  grep -ve '^$' -e '^#' -e ' local$' -e 'localhost$' -e 'localhost$' -e 'localhost.localdomain$' -e 'broadcasthost$' \
	  > "${filename}"

	# Alert the sysadmin when the download of one file failed
	if [ "${?}" -ne 0 ] ; then
		echo "Downloading ${url} failed" 1>&2
	fi

	# Check if an IP address is mentioned as first field or not.
	#   Only keep the actual hostname that needs to be blocked
	secondfield="$(head -n 1 "${filename}" | awk '{print $2}')"
	if [ -n "${secondfield}" ] ; then
		awk '{print $2}' "${filename}" >> totalfile.list
	else
		cat "${filename}" >> totalfile.list
	fi

	# Increase the counter for the program notifications
	counter=$(($counter + 1))
done

if [ ! -s totalfile.list ] ; then
	echo "Downloading of blacklist sources has failed, exiting out" 1>&2
	exit 2
fi

# Remove duplicates from the blacklisted URLs
echo "Make the blacklist unique"
sort -uo totalfile_sorted.list totalfile.list

# Remove lines from the blacklist that need to remain active
sed -i '/^0\.0\.0\.0$/d' totalfile_sorted.list
sed -i '/^$/d' totalfile_sorted.list

# Put all the blacklist URLs on one line, because that's the correct format of a hosts file
echo "Generate a oneline file"
tr '\n' ' ' < totalfile_sorted.list > totalfile_sorted_oneline.list

### POWERDNS ###

# Generate a blacklist hosts file for each of the VLANs that exist in my network
for env in ${envs}; do
	env_name="$(echo "${env}" | cut -d ':' -f 1)"
	env_type="$(echo "${env}" | cut -d ':' -f 2)"
	env_ip="$(echo "${env}" | cut -d ':' -f 3)"
	if [ "${env_type}" = 'pdns' ] ; then
		if [ ! -d "/etc/powerdns/${env_name}" ] ; then
			echo "Configuration directory for ${env_name} does not exist, generating it now"
			mkdir "/etc/powerdns/${env_name}"
		fi
		echo "Generate the blacklist for the ${env_name} network"
		sed "s/^/${env_ip}\t/" totalfile_sorted_oneline.list > "/etc/powerdns/${env_name}/hostsfile"

		# Add static hostnames to the file per server
		echo "Adding the static hostnames to ${env_name}"
		if [ -f "/etc/powerdns/${env_name}/static_hostnames" ] ; then
			tr '\n' ' ' < "/etc/powerdns/${env_name}/static_hostnames" >> "/etc/powerdns/${env_name}/hostsfile"
		fi

		# Add static hostnames to other hostnames
		echo "Adding the static hostnames for other hostnames to ${env_name}"
		if [ -f "/etc/powerdns/${env_name}/static_hostnames_otherhosts" ] ; then
			echo '' >> "/etc/powerdns/${env_name}/hostsfile"
			cat "/etc/powerdns/${env_name}/static_hostnames_otherhosts" >> "/etc/powerdns/${env_name}/hostsfile"
		fi

		# Remove the whitelist names from the list
		echo "Removing whitelisted hostnames for ${env_name}"
		if [ -f "/etc/powerdns/${env_name}/whitelist" ] ; then
			while read line ; do
				sed -i "s/ ${line}//" "/etc/powerdns/${env_name}/hostsfile"
			done < "/etc/powerdns/${env_name}/whitelist"
		fi

		# Fix the permissions on the PowerDNS directory
		chown -R root:pdns "/etc/powerdns/${env_name}"
		chmod -R o-rwx "/etc/powerdns/${env_name}"

		# Restart the recursors (except main), to load the new hostsfiles
		echo "Restarting the recursor ${env_name} to load the new blacklist files"
		kill "$(ps aux | grep pdns | grep "${env_name}" | grep -v grep | awk '{print $2}')"
		/usr/sbin/pdns_recursor --config-name=${env_name}
		if [ "${?}" -ne 0 ] ; then
			echo "Restarting the DNS recursor for ${env_name} failed!" 1>&2
			exit 3
		fi
	fi
done

# Fix the permissions on the PowerDNS directory
chown -R root:pdns /etc/powerdns
chmod -R o-rwx /etc/powerdns

### UNBOUND ###

# Extract the zones from the blacklist, to create a seperate file for each
for env in ${envs}; do
	env_name="$(echo "${env}" | cut -d ':' -f 1)"
	env_type="$(echo "${env}" | cut -d ':' -f 2)"
	env_ip="$(echo "${env}" | cut -d ':' -f 3)"
	if [ "${env_type}" = 'unbound' ] ; then
		# Only extract the zones if this hasn't been done yet
		if [ ! -f zones.list ] ; then
			echo 'Extract the zones from the blacklist'
			awk -F. '{print $(NF-1) "." $NF}' totalfile_sorted.list | sort | uniq > zones.list
		fi

		# Generate zonefile per zone
		echo 'Generate the zonefile'
		touch ${env_name}.conf
		while read zone; do
    		echo "local-zone: \"${zone}.\" typetransparent" >> ${env_name}.conf
    		grep "${zone}\$" totalfile_sorted.list | sed "s/^/local-data: \"/;s/$/. 3600 IN A ${env_ip}\"/" >> ${env_name}.conf
		done < zones.list
	
		# Copy the generated blacklist to the correct location
		echo 'Copy the new blacklist file to the correct location'
		mv ${env_name}.conf /etc/unbound/unbound.conf.d/blacklists/
		chown unbound: /etc/unbound/unbound.conf.d/blacklists/${env_name}.conf
		
		# Restart Unbound if the syntax is OK
		echo 'Check the configfile and restart Unbound'
		/usr/sbin/unbound-checkconf 1>/dev/null 2>&1
		if [ "${?}" -eq 0 ] ; then
			echo 'Restarting unbound, syntax is OK'
    		unbound-control dump_cache > unbound.cache
    		/bin/systemctl restart unbound
    		unbound-control load_cache < unbound.cache
		else
    		echo 'Syntax error in the Unbound file' 1>&2
			/usr/sbin/unbound-checkconf 1>&2
    		exit 3
		fi
	fi
done
