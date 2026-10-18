# vim: set ts=4 sw=4 et:
# void-hardperf-light: firewall rules before any network service starts (stage 2).
# If the ruleset fails to load, an emergency "deny everything" set is installed: the
# network is closed, not open (fail-closed). The iwd/dhcpcd services check for the vh table.
msg "vh: nftables..."
if ! nft -f /etc/nftables.conf; then
    printf '! nftables.conf did not load: the emergency ruleset is active (all network closed)\n'
    nft -f - <<'NFT'
flush ruleset
table inet vh_failsafe {
    chain input { type filter hook input priority filter; policy drop; iif "lo" accept; }
    chain forward { type filter hook forward priority filter; policy drop; }
    chain output { type filter hook output priority filter; policy drop; oif "lo" accept; }
}
NFT
fi
