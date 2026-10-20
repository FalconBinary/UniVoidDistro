#!/bin/bash
# The firmware trim through links (install/lib.sh: vh_firmware_noextract, vh_firmware_link_keep).
# linux-firmware keeps the names drivers ask for as links: into vendor directories under the same
# name (iwlwifi-*.ucode -> intel/iwlwifi/, 2025), under another name (amdgpu/vcn_4_0_4.bin ->
# vcn_4_0_0.bin), relative (intel/ish/ -> ../../dell/ish/), through chains, and whole
# directories (nvidia/ad104 -> ad102). The cases below are those of Void's linux-firmware
# 20260810 (xbps-query -R -f); the trim must keep every link's target and nothing else, as xbps
# applies noextract: every pattern in order, fnmatch without FNM_PATHNAME, the last match wins.
#   bash tests/install/firmware_test.sh /src   (tests/install/run.sh runs it in the vh-dev image)
set -u
src=${1:?"the repository"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

fw=/usr/lib/firmware
files=$(mktemp)
cat > "$files" <<EOF
$fw/iwlwifi-Qu-c0-hr-b0-77.ucode.zst -> $fw/intel/iwlwifi/iwlwifi-Qu-c0-hr-b0-77.ucode.zst
$fw/intel/iwlwifi/iwlwifi-Qu-c0-hr-b0-77.ucode.zst
$fw/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode.zst
$fw/amdgpu/vcn_4_0_4.bin.zst -> $fw/amdgpu/vcn_4_0_0.bin.zst
$fw/amdgpu/vcn_4_0_0.bin.zst
$fw/intel/ish/ish_lnlm_39ceeaf8.bin.zst -> ../../dell/ish/ish_lnlm_39ceeaf8_58.7727.0.bin.zst
$fw/dell/ish/ish_lnlm_39ceeaf8_58.7727.0.bin.zst
$fw/15E2-0-0x9.bin.zst -> $fw/15E2-0-0x8.bin.zst
$fw/15E2-0-0x8.bin.zst -> $fw/ti/audio/tas2783/15E2-0-0x8.bin.zst
$fw/ti/audio/tas2783/15E2-0-0x8.bin.zst
$fw/nvidia/ad104 -> $fw/nvidia/ad102
$fw/nvidia/ad102/gsp/gsp-570.144.bin.zst
$fw/nvidia/ad102/sec2/desc-1.bin.zst
$fw/intel/sof-ace-tplg -> $fw/intel/sof-ipc4-tplg
$fw/intel/sof-ipc4-tplg/sof-hda-generic.tplg.zst
$fw/brcm/brcmfmac43455-sdio.Raspberry Pi Foundation-Raspberry Pi 4 Model B.txt.zst -> $fw/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst
$fw/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst
$fw/qcom/a660_gmu.bin.zst
EOF

keep() { ( . "$src/install/lib.sh"; vh_firmware_link_keep "$files" "$@" ) 2>&1 | tr '\n' ' ' | sed 's/ $//'; }
check() { # NAME EXPECTED PATTERN...
	local name=$1 want=$2 got
	shift 2
	got=$(keep "$@")
	[ "$got" = "$want" ] && ok "$name: ${want:-(nothing beyond the patterns)}" || bad "$name" "want '$want', got '$got'"
}

echo "== vh_normpath"
r=$( . "$src/install/lib.sh"; vh_normpath "$fw/intel/ish/../../dell/ish/x.bin" )
[ "$r" = "$fw/dell/ish/x.bin" ] && ok "intel/ish/../../dell/ish/x.bin is dell/ish/x.bin" || bad "vh_normpath" "$r"

echo "== the targets of the links the patterns keep"
check "the same name in a vendor directory: */PATTERN keeps it" "" "iwlwifi-Qu*"
check "another name" "amdgpu/vcn_4_0_0.bin.zst" "amdgpu/vcn_4_0_4*"
check "a relative target" "dell/ish/ish_lnlm_39ceeaf8_58.7727.0.bin.zst" "intel/ish/ish_lnlm_39ceeaf8*"
check "a chain" "15E2-0-0x8.bin.zst ti/audio/tas2783/15E2-0-0x8.bin.zst" "15E2-0-0x9*"
check "a pattern below a directory link: the link and the pattern through it, not the whole target" \
	"nvidia/ad102/gsp/* nvidia/ad104" "nvidia/ad104/gsp/*"
check "a directory link the pattern keeps with its target" "" "intel/sof*"
check "a name with spaces" "brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst" "brcm/brcmfmac43455-sdio.Raspberry*"
check "nothing for what no pattern names" "" "qcom-not-here*"

echo "== xbps over the whole trim: every kept link leads to a kept file"
# xbps_patterns_match: in order, fnmatch without flags ("*" crosses "/"), the last match wins
pats=('iwlwifi-Qu*' 'amdgpu/vcn_4_0_4*' 'intel/ish/ish_lnlm_39ceeaf8*' '15E2-0-0x9*' 'nvidia/ad104/gsp/*' 'intel/sof*' 'brcm/brcmfmac43455-sdio.Raspberry*')
conf=$( . "$src/install/lib.sh"; VH_PLAN_FIRMWARE="${pats[*]}" vh_firmware_noextract "$files" | sed -n 's/^noextract=//p' )
declare -A extracted=() link=()
while IFS= read -r line; do
	path=${line%% -> *}
	[[ $line == *" -> "* ]] && { t=${line#* -> }; [[ $t == /* ]] || t=$( . "$src/install/lib.sh"; vh_normpath "${path%/*}/$t" ); link[$path]=$t; }
	ex=0
	while IFS= read -r p; do
		# shellcheck disable=SC2053 # the pattern is a glob on purpose, as xbps matches it
		if [[ $p == !* ]]; then [[ $path == ${p#!} ]] && ex=0; else [[ $path == $p ]] && ex=1; fi
	done <<< "$conf"
	[ "$ex" = 1 ] || extracted[$path]=1
done < "$files"
reach() { # a path, through extracted links and directory links, to an extracted file
	local p=$1 n=0 l
	while [ $n -lt 16 ]; do
		n=$((n + 1))
		if [ -n "${link[$p]:-}" ]; then [ -n "${extracted[$p]:-}" ] || return 1; p=${link[$p]}; continue; fi
		[ -n "${extracted[$p]:-}" ] && return 0
		# a directory: something below it was extracted
		for l in "${!extracted[@]}"; do [[ $l == "$p"/* ]] && return 0; done
		for l in "${!link[@]}"; do
			if [[ $p == "$l"/* ]]; then [ -n "${extracted[$l]:-}" ] || return 1; p=${link[$l]}${p#"$l"}; continue 2; fi
		done
		return 1
	done
	return 1
}
for k in "${pats[@]}"; do
	named=0 usable=0
	while IFS= read -r line; do
		path=${line%% -> *}
		[[ $path == $fw/$k ]] || continue
		named=$((named + 1)); reach "$path" && usable=$((usable + 1))
	done < "$files"
	# a directory link reached below it: the name a driver asks for
	[ "$k" = "nvidia/ad104/gsp/*" ] && { named=1; reach "$fw/nvidia/ad104/gsp/gsp-570.144.bin.zst" && usable=1; }
	[ "$named" -gt 0 ] && [ "$named" = "$usable" ] && ok "$k: $usable of $named usable" || bad "$k" "$usable of $named usable"
done
[ -z "${extracted[$fw/qcom/a660_gmu.bin.zst]:-}" ] && ok "what no pattern names stays out" || bad "qcom/a660_gmu.bin.zst was extracted"
[ -z "${extracted[$fw/nvidia/ad102/sec2/desc-1.bin.zst]:-}" ] && ok "a directory link's target: only below the pattern" || bad "nvidia/ad102/sec2 was extracted"
rm -f "$files"

echo
[ "$fails" = 0 ] && echo "firmware_test: all checks passed" || echo "firmware_test: $fails FAILED"
exit $(( fails > 0 ))
