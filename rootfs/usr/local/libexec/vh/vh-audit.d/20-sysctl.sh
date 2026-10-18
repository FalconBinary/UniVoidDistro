# shellcheck shell=sh
# vh-audit: every value from /etc/sysctl.d/*vh*.conf must be in effect (docs/05). Sourced by vh-audit.
sec "sysctl (values from /etc/sysctl.d/*vh*.conf)"
for f in /etc/sysctl.d/*vh*.conf; do
	grep -E '^[a-z]' "$f" | sed 's/[[:space:]]*#.*//' | while IFS='=' read -r k v; do
		k=$(echo "$k" | tr -d ' \t'); v=$(echo "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' \t' ' ')
		cur=$(sysctl -n "$k" 2>/dev/null | tr -s ' \t' ' ') || { echo "[ ?? ] $k: no such key"; continue; }
		[ "$cur" = "$v" ] && echo "[ ok ] $k = $v" || echo "[FAIL] $k = $cur (expected $v)"
	done
done | tee /tmp/vh-audit-sysctl.$$ | grep -v '^\[ ok \]'
n_ok=$(grep -c '^\[ ok \]' /tmp/vh-audit-sysctl.$$); n_bad=$(grep -c '^\[FAIL\]' /tmp/vh-audit-sysctl.$$)
pass=$((pass + n_ok)); fail=$((fail + n_bad)); rm -f /tmp/vh-audit-sysctl.$$
echo "       sysctl: $n_ok matched"
