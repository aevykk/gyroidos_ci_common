#!/bin/bash
# flash.sh — GRML netscript (bash + wget). Shipped from
# gyroidos_ci_common/resources/pxe_flash.sh and installed into the PXE dir by
# pxe_bootstrap_test.sh, so the flashing logic is version-controlled instead
# of living untracked on the PXE host.
#
# The grml liveboot fetches this via the netscript= cmdline param and runs it as
# root. Every command that does real work is wrapped in run(), which beacons the
# command (URL-encoded) to the CI agent's /log endpoint before executing it; the
# agent decodes it so the Jenkins console shows live, human-readable progress.

PXE_HOST="__PXE_HOST__"   # substituted by pxe_bootstrap_test.sh at install time (node has no CI env)
SRV="http://$PXE_HOST:8080"

# url-encode $* (RFC3986 unreserved chars kept literal)
urlencode() {
    local s=$* i c out=
    for (( i=0; i<${#s}; i++ )); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9._~-]) out+=$c ;;
            *) printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

# mark <phase>: coarse phase beacon (start/flashed/FAILED/...)
mark() { wget -q -O /dev/null "$SRV/log?step=$1" 2>/dev/null || true; }

# run <cmd...>: beacon the command to the CI agent, then execute it. The "+ cmd"
# marker goes to stderr so it never pollutes captured/piped stdout of the wrapped
# command (e.g. $(run readlink ...) or `run lsblk ... | grep`).
run() {
    printf '+ %s\n' "$*" >&2
    wget -q -O /dev/null "$SRV/log?run=$(urlencode "$*")" 2>/dev/null || true
    "$@"
}

# beacon FIRST: proves execution in the HTTP log before anything can fail
mark exec

set -euo pipefail
# best-effort terminal sizing; grml runs us via netscript with no TTY, where stty
# errors — must not abort under set -e (this line runs before the ERR trap is armed).
stty columns 83 rows 40 2>/dev/null || true

DISK="/dev/disk/by-id/usb-Samsung_PSSD_T7_S6XDNS0W364404X-0:0"
#DISK="/dev/sda"
IMG="images/image.tar.zstd"     # served by pxe_bootstrap_test.sh (zstd tarball of the wic image)

# mirror all output to a local log (tail -f /tmp/flash.log over ssh)
exec > >(tee /tmp/flash.log) 2>&1

fail() {
    trap - ERR
    set +e
    echo "!!! $*" >&2
    mark FAILED
    # surface the reason + tail of the local log to the CI agent, so the failure
    # is visible in the Jenkins console (not only in /tmp/flash.log on the target)
    wget -q -O /dev/null "$SRV/log?err=$(urlencode "$*")" 2>/dev/null || true
    tail -n 30 /tmp/flash.log 2>/dev/null | while IFS= read -r l; do
        [ -n "$l" ] && wget -q -O /dev/null "$SRV/log?err=$(urlencode "$l")" 2>/dev/null || true
    done
    echo "!!! dropping to shell — ssh in, see /tmp/flash.log" >&2
    exec bash
}
trap 'fail "unexpected error at line $LINENO"' ERR

mark start

# wait for the target disk to enumerate
for i in $(seq 1 15); do
    [ -b "$DISK" ] && break
    echo "waiting for $DISK ($i)"
    sleep 1
done
[ -b "$DISK" ] || { ls -l /dev/disk/by-id/ >&2; fail "$DISK never appeared"; }

# never write to a mounted device
REAL=$(run readlink -f "$DISK")
if run lsblk -no MOUNTPOINT "$REAL" | grep -q .; then
    fail "$REAL has mounted partitions, refusing to flash"
fi

# stream straight onto the disk: download -> zstd-decompress -> untar member -> dd.
# No temp file, so the ~800MB tarball never lands in grml's RAM-backed /tmp, and
# the download overlaps the write. iflag=fullblock reassembles short pipe reads
# into whole blocks; oflag=direct is omitted (O_DIRECT needs aligned blocks a pipe
# can't guarantee), conv=fsync still flushes before we return.
run bash -c "set -o pipefail; wget -q -O - '$SRV/$IMG' | tar --zstd -xO -f - gyroidosimage.img | dd of='$DISK' bs=4M iflag=fullblock conv=fsync oflag=direct status=progress" || fail "download/flash failed"
run sync
run blockdev --rereadpt "$REAL" || true
run udevadm settle || true

mark flashed
IFACE="$(ip -o route get "$PXE_HOST" | sed -n 's/.*dev \([^ ]*\).*/\1/p')"
MAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo unknown)"
wget -q -O /dev/null "$SRV/flashed?device=pxe&mac=$MAC" || echo "ping-back failed (non-fatal)"

run systemctl reboot
