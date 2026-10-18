# shellcheck shell=sh
# vh-audit: mount options (docs/05). Sourced by vh-audit.
sec "Mounts"
mopt() { findmnt -no OPTIONS "$1" 2>/dev/null; }
has() { case ",$(mopt "$1")," in *",$2,"*) ok "$1: $2" ;; *) bad "$1: missing $2 ($(mopt "$1"))" ;; esac; }
has /proc hidepid=invisible
for m in /tmp /var/tmp /dev/shm; do has "$m" noexec; has "$m" nosuid; has "$m" nodev; done
has /run noexec
has /home nodev; has /home nosuid
has /home/xfer nosymfollow; has /home/xfer noexec
has /var/lib/vh-browser noexec
findmnt /boot/efi >/dev/null && unk "the ESP is mounted (it should be only during an update)" || ok "the ESP is not mounted"
