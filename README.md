# dns-blacklist-generator
A Bash script which generates DNS blocklists for multiple recursors.

The blacklists are based on the same blacklists as what the Pi-Hole project uses. The idea of this script is that you don't have to setup a separate machine for DNS blackholing, but that you can just integrate it with a machine that is already running at your location.

What this script does is add a list of blacklisted domains to the DNS recursors that you are running. It makes sure that all the traffic for those ad- and scam-domains are actually send towards the DNS recursor. It is advisable to have nothing running on port 80 and 443, and actively reject connections to those ports (iptables language: `-j REJECT`). If you just drop the traffic (iptables: `-j DROP`) then you will notice long timeouts in your network when a blacklisted domain is visited, making your browsing experience horrible.

You should configure this script to run in a cronjob, so it will keep the blacklists up-to-date and make sure you always get a more adblock free web browsing experience.

## Setup

First you have to configure the script a bit, but this is easily done.

### `envs`

You start with configuring the list of DNS recursors you run on your server in the variable named `envs`. You can run multiple recursors on the same host. You only have to make sure they listen on seperate IP addresses. How to do that for the DNS recursor of your choice is out of the scope of this project and you should consult the documentation of your recursor to find out how to do that.

For each recursor you want a blacklist for you need to know three things:

1. The name of the recursor (without spaces)
2. Which sofware it uses (unbound or pdns)
3. The IP address on which it listens

You then add all of this information is a colon seperated list, in the setting `envs`. If you have more than 1 environment you want to generate a blacklist for, you can place them all in this var, whitespace seperated. So the env variable can look like this:

`envs=main:unbound:10.0.0.1 guest:pdns:10.0.1.1`

Meaning: There are 2 environments, named `main` and `guest`. The `main` network runs Unbound, the `guest` network runs PowerDNS. Unbound for `main` listens on `10.0.0.1`, PowerDNS for `guest` listens on `10.0.1.1`.

### `logfile`

The second setting you need to configure is a lot simpler. This is the logfile in which the normal output is placed. This logfile name has to end in the `.log` extension.

The script itself also uses an error logfile. The errorlog is named exactly the same as the normal logfile, only the `.log` extension is replaced with `_error.log`, so you will get the `_error` suffix in the filename for you error log. This will be placed in the same directory as the normale logfile

### Config files (PowerDNS)

For PowerDNS you can add extra hostnames which should be added to the generated configuration. For PowerDNS you should create a directory with the name of the environment in the PowerDNS config directory. So, for my example given earlier I should create the directory `/etc/powerdns/guest`, if I want to use these config files. If I don't have a need for these extra config files than I don't need to create these directories.

#### Static hostnames towards the recursor

This is useful if your recursor also has different tasks then being recursor. Then these services will be reachable via a hostname instead of an ip address.
In the config directory you should place a file called `static_hostnames`, with each extra hostname on a seperate line.

#### Static hostnames towards other servers

You can also add hostnames towards other hosts in your network, if you do have more than one device. The file you need for this is called `static_hostnames_otherhosts`. The syntax of this file is 1 line per other host that you have in your network. The first item on this line is the IP address of the other host, and then you add all the hostnames for that other device whitespace seperated behind the IP address.

#### Whitelist domains

I can happen that a hostname is automatically added to the blacklist, but you want to visit that domain anyway. Then you can add this hostname to the whitelist, and the script will remove it from the blacklist when it is found on it. This file is simply called `whitelist`. Just place one whitelisted domain per line, and they will be removed from the blacklist when the script is ran again.

#### Blacklist domains

If the script misses a domain that you actually want to have blocked you would expect that there is a blacklist file. There isn't a dedicated file for this. But if you just add these hostnames to `static_hostnames` you will have the same effect.

### Config files (Unbound)

Unbound doesn't support static hostnames or whitelist files. I found it easier to just configure these things in Unbound directly than hack them into my config via extra config files for this script.