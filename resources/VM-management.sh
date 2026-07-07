#!/bin/bash
set -e

sync_to_disk() {
    echo_status "Syncing VM state to disk"
    for I in $(seq 1 3) ;do
        if ssh ${SSH_OPTS} 'sh -c sync && sleep 1' 2>&1;then
            echo_status "Synced VM state to disk"
            break
        elif ! [[ "$I" == "3" ]];then
            echo_status "Failed to sync VM state to disk, retrying"
            sleep 0.5
        else
            echo_error "Could not sync VM state to disk, exiting..."
        fi
    done
}

force_stop_vm() {
    sync_to_disk

    sleep 2
    echo_status "Sending quit to QEMU monitor socket"
    if echo "quit" | socat - ./${PROCESS_NAME}.qemumon;then
        echo_status "Sucessfully requested VM to exit cleanly"
    else
        echo_status "Failed to request clean VM exit"
    fi

    # Wait for the QEMU process to actually exit before returning. Without
    # this, the next start_vm can race the old QEMU, potentially failing to attach
	# USB devices.
    local pid
    pid="$(pgrep -f "process=${PROCESS_NAME}" || true)"
    if [ -n "$pid" ]; then
        echo_status "Waiting up to 15s for QEMU pid $pid to exit"
        for _ in $(seq 1 30); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo_status "QEMU pid $pid did not exit in 15s; sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        else
            echo_status "QEMU pid $pid exited"
        fi
    fi

    rm -f ${PROCESS_NAME}.vm_key
}

fetch_logs() {
    if [ -z "${LOG_DIR}" ];then
        echo_status "-l / --log-dir not specified, skipping log file retrieval"
        return 0
    fi

    mkdir -p "${LOG_DIR}"

    # Copy guest serial console and QEMU stderr first — these are the most
    # important artifacts when the VM never reaches SSH, and they must not be
    # skipped if disk-image extraction below fails.
    for f in "${PROCESS_NAME}.console.log" \
             "${PROCESS_NAME}.kernel.log" \
             "${PROCESS_NAME}.cml.log"; do
        if [ -f "./$f" ]; then
            cp "./$f" "${LOG_DIR}/"
        else
            echo_status "Logfile '$f' NOT found"
        fi
    done
    for f in "${PROCESS_NAME}.qemu.stderr" "${PROCESS_NAME}.qemu.stdout"; do
        if [ -f "./$f" ]; then
            cp "./$f" "${LOG_DIR}/"
        fi
    done

    # Best-effort extraction of /userdata/logs from the disk image. Wrap in a
    # subshell so set -e failures here don't skip the console-log copy above
    # and don't abort the caller (err_fetch_cml_logs still needs to run).
    (
        set +e
        local skip sectors sector_size fdisk_out
        fdisk_out="$(/sbin/fdisk -lu "${PROCESS_NAME}.img" 2>&1)" || {
            echo_status "fdisk failed: ${fdisk_out}"
            exit 0
        }
        sector_size="$(awk '/Sector size/ {print $4; exit}' <<< "${fdisk_out}")"
        : "${sector_size:=512}"

        local last_line
        last_line="$(tail -n1 <<< "${fdisk_out}")"
        skip="$(awk '{print $2}' <<< "${last_line}")"
        sectors="$(awk '{print $4}' <<< "${last_line}")"

        if ! [[ "${skip}" =~ ^[0-9]+$ ]] || ! [[ "${sectors}" =~ ^[0-9]+$ ]]; then
            echo_status "Could not parse userdata partition from fdisk output; skipping userdata extraction"
            echo_status "fdisk output was:"
            sed 's/^/  /' <<< "${fdisk_out}"
            exit 0
        fi

        dd if="${PROCESS_NAME}.img" of="${PROCESS_NAME}.data" bs=4M \
            iflag=skip_bytes,count_bytes \
            skip=$((skip*sector_size)) count=$((sectors*sector_size)) status=none || {
            echo_status "dd extraction of userdata failed; skipping"
            exit 0
        }

        for i in $(e2ls "${PROCESS_NAME}.data:/userdata/logs" 2>/dev/null); do
            if [ -z "${i##*.current}" ]; then
                continue
            fi
            e2cp "${PROCESS_NAME}.data:/userdata/logs/${i}" "${LOG_DIR}/" 2>/dev/null || true
        done
    )

    echo_status "Retrieved CML logs"
}

err_fetch_logs() {
    echo_status "An error occurred, attempting to fetch logs from VM"

    trap - EXIT INT TERM

    force_stop_vm

    fetch_logs
    exit 1
}


trap 'err_fetch_logs' EXIT INT TERM

wait_vm () {
    local timeout_sec=300
    echo_status "Waiting up to ${timeout_sec}s for VM to become available"
    # Give QEMU a moment to register its process name before pgrep checks.
    sleep 3
    local deadline=$(($(date +%s) + timeout_sec))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [[ -z "$(pgrep $PROCESS_NAME)" ]]; then
            echo_status "Error: QEMU process exited"
            exit 1
        fi
        if ssh -q -o ConnectTimeout=5 ${SSH_OPTS} "true" 2>/dev/null; then
            echo_status "VM access was successful"
            return
        fi
        sleep 1
    done
    echo_status "VM access failed after ${timeout_sec}s, exiting..."
    exit 1
}

start_swtpm() {
    if [[ ! -d "/tmp/swtpmqemu" ]];then
	    mkdir /tmp/swtpmqemu
    fi

    swtpm socket --tpmstate dir=/tmp/swtpmqemu --tpm2 --ctrl type=unixio,path=/tmp/swtpmqemu/swtpm-sock &
}

# $1: Disk Image Path
align_image () {
    local img_path="$(realpath -e "$1")"
    # Get mountpoint of hosting filesystem
    local hosting_mount="$(df --output=target "$img_path" | tail -1)"
    # Get filesystem block size
    local fs_bsize="$(stat -fc%s "$hosting_mount" 2>/dev/null || echo 4096)"
    # Resize to be a multiple of the fs block size
    echo_status "Resizing ${1} to match fs block size of ${fs_bsize}B"
    qemu-img resize -f raw "$img_path" $(( (($(stat -c%s "$img_path") + $fs_bsize - 1) / $fs_bsize) * $fs_bsize ))
}

start_vm() {
	ovmf_code=""
	if [ -f "/usr/share/OVMF/OVMF_CODE.fd" ];then
		ovmf_code="/usr/share/OVMF/OVMF_CODE.fd"
	elif [ -f "/usr/share/OVMF/OVMF_CODE_4M.fd" ];then
		ovmf_code="/usr/share/OVMF/OVMF_CODE_4M.fd"
	else
		echo_error "Failed to locate OVMF_CODE"
		exit 1
	fi

    align_image "${PROCESS_NAME}.img"
    align_image "${PROCESS_NAME}.ext4fs"
    # If --telnet wasn't passed, capture guest serial to a file so we can see
    # kernel/initramfs output when the guest dies before cmld writes its logs.
    # ttyS0: login getty; ttyS1: kernel printk (via dev kernel cmdline);
    # ttyS2: CML LOGTTY (GYROIDOS_LOGTTY set to ttyS2 in dev x86 builds, so
    # CML's `exec > /dev/$LOGTTY` writes here directly — no bind mount).
    local serial_args="${TELNET:--serial file:./${PROCESS_NAME}.console.log}"
    serial_args="$serial_args -serial file:./${PROCESS_NAME}.kernel.log"
    serial_args="$serial_args -serial file:./${PROCESS_NAME}.cml.log"
    qemu-system-x86_64 -machine accel=kvm,vmport=off -m 16G -smp 4 -cpu host -bios OVMF.fd \
        -monitor unix:./${PROCESS_NAME}.qemumon,server,nowait \
        -name gyroidos-tester,process=${PROCESS_NAME} -nodefaults -nographic \
        -device virtio-rng-pci,rng=id -object rng-random,id=id,filename=/dev/urandom \
        -device virtio-scsi-pci,id=scsi -device scsi-hd,drive=hd0 \
        -drive if=none,id=hd0,file=${PROCESS_NAME}.img,cache=writeback,format=raw \
        -device scsi-hd,drive=hd1 \
        -drive if=none,id=hd1,file=${PROCESS_NAME}.ext4fs,cache=writeback,format=raw \
        -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
        -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
        -drive "if=pflash,format=raw,file=./OVMF_VARS.fd" \
        $SWTPM \
        $VNC \
        $serial_args \
        $PASS_HSM >"./${PROCESS_NAME}.qemu.stdout" 2>"./${PROCESS_NAME}.qemu.stderr" &

    wait_vm
}
