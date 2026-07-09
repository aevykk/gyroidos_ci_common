#!/usr/bin/env bash
# pxe_run_tests.sh — run the integration suite against the already-flashed node.
# Runs as the "PXE Test" stage AFTER pxe_bootstrap_test.sh has flashed and booted
# the node (boot.ipxe already points at local.ipxe). The suite reboots the node a few
# times; each reboot re-PXEs and fetches boot.ipxe -> local.ipxe -> sanboot, so we
# stand up a plain static HTTP server over $PXE_DIR for the duration — no flash
# symlink flipping or /flashed|/log beacon handling needed here.
set -euo pipefail

### config (override via environment from the Jenkins job) ###################
PXE_DIR="${PXE_DIR:-$HOME/pxe}"
HTTP_ADDR="${HTTP_ADDR:-10.187.4.85}"     # test-facing interface IP
HTTP_PORT="${HTTP_PORT:-8080}"
TARGET_IP="${TARGET_IP:-}"                # flashed node's IP (required)
TEST_MODE="${TEST_MODE:-dev}"             # image variant under test
TEST_PKI="${TEST_PKI:-test_certificates}" # PKI dir (relative to this script)
TEST_LOG_DIR="${TEST_LOG_DIR:-}"          # where the suite writes cml logs (optional)
###############################################################################

HTTP_PID=""
log() { echo "[pxe-test $(date +%H:%M:%S)] $*"; }

cleanup() {
    rc=$?
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    exit $rc
}
trap cleanup EXIT

[ -n "$TARGET_IP" ] || { log "TARGET_IP not set"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/VM-container-tests.sh" ] || { log "missing $HERE/VM-container-tests.sh"; exit 2; }
[ -d "$HERE/$TEST_PKI" ] || { log "missing PKI dir $HERE/$TEST_PKI"; exit 2; }

### serve $PXE_DIR so in-test reboots can fetch boot.ipxe -> local.ipxe -> sanboot ##
python3 -m http.server --bind "$HTTP_ADDR" --directory "$PXE_DIR" "$HTTP_PORT" >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { log "http server failed to start on $HTTP_ADDR:$HTTP_PORT (port in use?)"; exit 2; }
log "serving $PXE_DIR on $HTTP_ADDR:$HTTP_PORT for in-test reboots"

### run the suite in hardware-target mode ####################################
log "running integration suite against $TARGET_IP (mode=$TEST_MODE)"
cd "$HERE"
bash "$HERE/VM-container-tests.sh" \
    --target-ip "$TARGET_IP" --mode "$TEST_MODE" --pki "$HERE/$TEST_PKI" \
    ${TEST_LOG_DIR:+--log-dir "$TEST_LOG_DIR"}

log "integration suite passed"
