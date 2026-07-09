#!/usr/bin/env bash
# pxe_bootstrap_test.sh — flash the test machine with a fresh image, invoked by Jenkins.
# Exit 0: image flashed, symlink at local boot, machine rebooting into it.
set -euo pipefail

### config (override via environment from the Jenkins job) ###################
PXE_DIR="${PXE_DIR:-$HOME/pxe}"
IMAGE_SRC="${IMAGE_SRC:-$HOME/gyroid/image.iso}"
FLASH_SRC="${FLASH_SRC:-}"                # CI-tracked flash.sh to install into $PXE_DIR (optional)
HTTP_ADDR="${HTTP_ADDR:-10.0.2.1}"        # test-facing interface IP
HTTP_PORT="${HTTP_PORT:-8080}"
PXE_HOST="${PXE_HOST:-$HTTP_ADDR}"        # address the NODE uses to reach us (IP); baked into flash.sh
RESET_CMD="${RESET_CMD:-}"                # e.g. ipmitool/pdu/relay command to power-cycle target
FLASH_TIMEOUT="${FLASH_TIMEOUT:-1800}"    # seconds to wait for the flashed ping-back
TARGET_IP="${TARGET_IP:-}"                # optional: wait for flashed system to answer ping
BOOT_WAIT="${BOOT_WAIT:-180}"             # seconds to wait for TARGET_IP (if set)
REBOOT_WAIT="${REBOOT_WAIT:-300}"         # seconds to wait for the post-flash boot.ipxe request
###############################################################################

RUN_DIR=$(mktemp -d)
DONE_STAMP="$RUN_DIR/flashed"
BOOTED_STAMP="$RUN_DIR/booted"
TRAIL="$RUN_DIR/trail"
HTTP_LOG="$RUN_DIR/http.log"
HTTP_PID=""
TAIL_PID=""

log() { echo "[pxe-bootstrap $(date +%H:%M:%S)] $*"; }

set_boot() {  # atomic symlink flip: boot.ipxe -> $1
    ln -s "$1" "$PXE_DIR/.boot.ipxe.tmp"
    mv -T "$PXE_DIR/.boot.ipxe.tmp" "$PXE_DIR/boot.ipxe"
}

cleanup() {
    rc=$?
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
    # invariant: outside a flash window, boot.ipxe always points at local boot
    set_boot local.ipxe
    if [ $rc -ne 0 ]; then
        log "FAILED — step trail:"; cat "$TRAIL" 2>/dev/null || echo "(no steps seen)"
        log "http server log:"; tail -20 "$HTTP_LOG" 2>/dev/null || true
    fi
    rm -rf "$RUN_DIR"
    exit $rc
}
trap cleanup EXIT

### sanity ####################################################################
[ -f "$IMAGE_SRC" ] || { log "no image at $IMAGE_SRC"; exit 2; }
[ -z "$FLASH_SRC" ] || [ -f "$FLASH_SRC" ] || { log "no flash script at $FLASH_SRC"; exit 2; }
for f in flash.ipxe local.ipxe grml/vmlinuz grml/initrd.img; do
    [ -e "$PXE_DIR/$f" ] || { log "missing $PXE_DIR/$f"; exit 2; }
done
# flash.sh is installed from FLASH_SRC below; require a pre-existing one only if unset
[ -n "$FLASH_SRC" ] || [ -e "$PXE_DIR/flash.sh" ] || { log "missing $PXE_DIR/flash.sh (set FLASH_SRC)"; exit 2; }

### 1. deploy image atomically ################################################
log "deploying image ($(du -h "$IMAGE_SRC" | cut -f1))"
mkdir -p "$PXE_DIR/images"
# rsync writes to a temp file in the dest dir and atomically renames it into
# place (image.iso is never served half-written), and skips the copy entirely
# when the image is unchanged from the previous deploy.
# rsync -a "$IMAGE_SRC" "$PXE_DIR/images/image.iso"
ln -sf "$IMAGE_SRC" "$PXE_DIR/images/image.tar.zstd"

# install the CI-tracked flash script (served to the target as flash.sh), baking in
# PXE_HOST since the node has no CI env to read it from.
if [ -n "$FLASH_SRC" ]; then
    [ -n "$PXE_HOST" ] || { log "PXE_HOST empty"; exit 2; }
    log "installing flash script (PXE_HOST=$PXE_HOST) from $FLASH_SRC"
    sed "s|__PXE_HOST__|$PXE_HOST|g" "$FLASH_SRC" > "$PXE_DIR/flash.sh"
fi

### 2. arm flash boot #########################################################
set_boot flash.ipxe
log "boot.ipxe -> flash.ipxe"

### 3. serve ~/pxe + handle /flashed and /log beacons #########################
python3 - "$PXE_DIR" "$HTTP_ADDR" "$HTTP_PORT" "$DONE_STAMP" "$TRAIL" "$BOOTED_STAMP" >>"$HTTP_LOG" 2>&1 <<'EOF' &
import http.server, os, sys, time, urllib.parse
pxe, addr, port, stamp, trail, booted = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]

def write_stamp(path, text):   # atomic like the boot.ipxe flip: a bash waiter polling
    tmp = path + '.tmp'        # for -f never sees a half-written or empty stamp file
    with open(tmp, 'w') as f:
        f.write(text)
    os.replace(tmp, path)

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=pxe, **kw)
    def do_GET(self):
        if self.path.startswith('/flashed'):
            # flip to local boot BEFORE acknowledging: target only reboots after our 200
            tmp = os.path.join(pxe, '.boot.ipxe.tmp')
            try: os.remove(tmp)
            except FileNotFoundError: pass
            os.symlink('local.ipxe', tmp)
            os.replace(tmp, os.path.join(pxe, 'boot.ipxe'))
            write_stamp(stamp, self.path + '\n')
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok\n')
        elif self.path.startswith('/log'):
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if 'err' in params:    msg = 'ERR  ' + params['err'][0]
            elif 'run' in params:  msg = 'RUN  ' + params['run'][0]
            elif 'step' in params: msg = 'STEP ' + params['step'][0]
            else:                  msg = self.path
            # parse_qs URL-decodes values, so a %0a/%0d in a beacon becomes real
            # newlines. Keep multi-line content (e.g. the err= flash.log tail) readable,
            # but indent continuation lines under a '|' marker so a beacon can never
            # forge a line that lines up with the timestamped STEP/RUN format at column 0.
            msg = msg.replace('\r\n', '\n').replace('\r', '\n')
            ts = time.strftime('%H:%M:%S ')
            head, *rest = msg.split('\n')
            indent = ' ' * (len(ts) + 1)
            lines = [f"{ts} {head}"] + [f"{indent}| {r}" for r in rest]
            with open(trail, 'a') as f: f.write('\n'.join(lines) + '\n')
            for l in lines: sys.stderr.write('[flash] ' + l + '\n')
            sys.stderr.flush()
            self.send_response_only(200); self.end_headers()
        elif self.path.startswith('/boot.ipxe'):
            # a boot.ipxe fetch AFTER the flash-done flip is the target rebooting
            # into the freshly-flashed disk — our success signal. The initial
            # pre-flash grml fetch is ignored: DONE_STAMP does not exist yet.
            if os.path.exists(stamp):
                write_stamp(booted, self.path + '\n')
                sys.stderr.write('[boot] target fetched boot.ipxe after flash — booted into disk\n'); sys.stderr.flush()
            super().do_GET()
        else:
            super().do_GET()

http.server.ThreadingHTTPServer((addr, port), H).serve_forever()
EOF
HTTP_PID=$!
sleep 1
kill -0 "$HTTP_PID" 2>/dev/null || { log "http server failed to start (port in use?)"; exit 2; }
log "serving $PXE_DIR on $HTTP_ADDR:$HTTP_PORT"

# mirror the HTTP access log to our stdout so the Jenkins console shows live
# progress: kernel/initrd/image fetches and the target's /log?step=... beacons
tail -n +1 -f "$HTTP_LOG" 2>/dev/null &
TAIL_PID=$!

### 4. power-cycle the target #################################################
if [ -n "$RESET_CMD" ]; then
    log "resetting target: $RESET_CMD"
    eval "$RESET_CMD"
else
    log "WARNING: RESET_CMD not set — power-cycle the test machine >>>NOW<<<"
fi

### 5. wait for the flash to complete #########################################
log "waiting for flash completion (timeout ${FLASH_TIMEOUT}s)"
deadline=$(( $(date +%s) + FLASH_TIMEOUT ))
while [ ! -f "$DONE_STAMP" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { log "timeout waiting for /flashed"; exit 1; }
    sleep 2
done
log "flash complete: $(cat "$DONE_STAMP")"
log "boot.ipxe -> local.ipxe (flipped by handler); target rebooting into disk"

### keep serving until the target reboots and re-requests boot.ipxe ###########
# The post-flash boot.ipxe fetch (now resolving to local.ipxe) proves the target
# rebooted and is chaining into the freshly-flashed disk. The HTTP server stays
# up (only cleanup on exit kills it), so this request is actually served.
log "waiting up to ${REBOOT_WAIT}s for target to reboot and fetch boot.ipxe (local boot)"
deadline=$(( $(date +%s) + REBOOT_WAIT ))
while [ ! -f "$BOOTED_STAMP" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { log "timeout waiting for post-flash boot.ipxe request"; exit 1; }
    sleep 2
done
log "target fetched boot.ipxe after flash — booted into the disk image"

### 6. optionally wait for the flashed system to come up ######################
if [ -n "${TARGET_IP:-}" ]; then
    log "waiting up to ${BOOT_WAIT}s for $TARGET_IP"
    deadline=$(( $(date +%s) + BOOT_WAIT ))
    until ping -c1 -W1 "$TARGET_IP" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || { log "target never answered ping"; exit 1; }
        sleep 3
    done
    log "target is up"
fi

log "All done, host booting. Thanks for playing. Bye!"
