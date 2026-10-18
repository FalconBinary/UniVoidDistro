# void-hardperf-light: the root shell (doas -s) is not a login shell and does not read
# /etc/profile. The idle limit is set here. trap 'kill -KILL -1' must not go here for
# root: as root it would kill the whole system.
if [ "$(id -u)" = 0 ]; then
	readonly TMOUT=600
	export TMOUT
fi
