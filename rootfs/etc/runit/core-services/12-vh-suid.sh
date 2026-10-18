# vim: set ts=4 sw=4 et:
# void-hardperf-light: a package update brings back the SUID bits and file capabilities
# removed with chmod/setcap. They are stripped again at every boot (and in vh-update): docs/05.
/usr/local/sbin/vh-suid-strip --quiet
