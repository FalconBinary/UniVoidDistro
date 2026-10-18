# shellcheck shell=sh
# vh-audit: the desktop binaries and the shared caches they depend on (docs/08). Sourced by vh-audit.
sec "Desktop (RefursWM + RefursLine)"
# shared caches built by package triggers: without the MIME database GTK does not load SVG
# and Firefox crashes; with umask 077 (doas xbps-install bypassing vh-update) only root can read them
for f in /usr/share/mime/mime.cache /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
	/usr/share/glib-2.0/schemas/gschemas.compiled /usr/share/icons/hicolor/icon-theme.cache; do
	if [ ! -s "$f" ]; then bad "missing $f (doas xbps-reconfigure -f the owning package)"
	elif [ "$(( 0$(stat -c %a "$f") & 4 ))" = 4 ]; then ok "$f is world-readable"
	else bad "$f: $(stat -c %a "$f") -- the user cannot read it (umask 022; xbps-reconfigure -f)"; fi
done
if [ -r /etc/vh/desktop.sha256 ]; then
	if out=$(cd /usr/local/bin && grep -v '^#' /etc/vh/desktop.sha256 | sha256sum -c --quiet 2>&1); then
		ok "refurswm, refursline: sha256 as installed ($(head -1 /etc/vh/desktop.sha256 | cut -c3-))"
	else
		bad "refurswm/refursline differ from /etc/vh/desktop.sha256: $out"
	fi
	for b in refurswm refursline; do
		[ "$(stat -c %U:%a /usr/local/bin/$b 2>/dev/null)" = root:755 ] && ok "/usr/local/bin/$b: root, 0755" \
			|| bad "/usr/local/bin/$b: $(stat -c %U:%a /usr/local/bin/$b 2>&1)"
	done
else
	bad "no /etc/vh/desktop.sha256 (install/build-desktop.sh)"
fi
