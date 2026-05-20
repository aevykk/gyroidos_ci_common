#!/bin/bash

set -e

STAGE="PREPARING"

echo_status () {
    echo "$(date --rfc-3339=ns) [${STAGE}] STATUS: $1"
}
echo_error () {
    echo "$(date --rfc-3339=ns) [${STAGE}] ERROR:  $1"
}

CMDPATH="${BASH_SOURCE[0]}"
echo_status "Sourcing $(dirname "${CMDPATH}")/settings.sh"
source "$(dirname "${CMDPATH}")/settings.sh"

echo_status "Sourcing $(dirname "${CMDPATH}")/VM-container-commands.sh"
source "$(dirname "${CMDPATH}")/VM-container-commands.sh"

echo_status "Sourcing $(dirname "${CMDPATH}")/VM-management.sh"
source "$(dirname "${CMDPATH}")/VM-management.sh"

echo_status "Sourcing $(dirname "${CMDPATH}")/testdata.sh"
source "$(dirname "${CMDPATH}")/testdata.sh"

OPT_FORCE_SIG_CFGS="n"

# Function definitions
# ----------------------------------------------

do_copy_update_configs(){
# Copy test guestos configs for update to VM
for I in $(seq 1 10) ;do
	echo_status "Trying to copy GuestOS configs to image"

	FILES=" nullos-1.conf nullos-1.sig nullos-1.cert \
		nullos-2.conf nullos-2.sig nullos-2.cert \
		nullos-3.conf nullos-3.sig nullos-3.cert"

	if scp $SCP_OPTS $FILES root@127.0.0.1:/tmp/;then
		echo_status "scp was successful"
		break
	elif ! [ $I -eq 10 ];then
		echo_status "scp failed, retrying..."
	else
		echo_status "Failed to copy nullos GuestOS configs to VM, exiting..."
		err_fetch_logs
	fi
done
}

do_copy_kernel_update(){
KERNEL_VERSION=$1
# Copy test kernel config for update to VM
for I in $(seq 1 10) ;do
	echo_status "Trying to copy kernel config to image"

	FILES=" kernel-$KERNEL_VERSION.conf \
					kernel-$KERNEL_VERSION.sig \
					kernel-$KERNEL_VERSION.cert \
					kernel-$KERNEL_VERSION"

	if scp -r $SCP_OPTS $FILES root@127.0.0.1:/tmp/;then
		echo_status "scp was successful"
		break
	elif ! [ $I -eq 10 ];then
		echo_status "scp failed, retrying..."
	else
		echo_status "Failed to copy kernel GuestOS configs to VM, exiting..."
		err_fetch_logs
	fi
done
}

do_test_rm() {
	CONTAINER="$1"

	echo_status "Change pin: (set pin) -> $TESTPW token PIN"
	cmd_control_change_pin "${CONTAINER}" "" "$TESTPW"

	echo_status "Starting container \"${CONTAINER}\""
	cmd_control_start "${CONTAINER}" "$TESTPW"

	# Test container removal of running container
	echo_status "Removing container \"${CONTAINER}\""
	cmd_control_remove "${CONTAINER}" "$TESTPW"
}

do_test_complete() {
	CONTAINER="$1"
	SECOND_RUN="$2"
	USBTOKEN="$3"
	echo_status "########## Starting container test suite, CONTAINER=${CONTAINER}, SECOND_RUN=${SECOND_RUN}, USBTOKEN=${USBTOKEN} ##########"

	# Test if cmld is up and running
	echo_status "Test if cmld is up and running"
	cmd_control_list

	if [ "n" = "$USBTOKEN" ];then
		# Skip these tests for physical schsm
		if ! [ "${SECOND_RUN}" = "y" ];then
			echo_status "Trigger ERROR_UNPAIRED"
			cmd_control_start_error_unpaired "${CONTAINER}" "$TESTPW"

			echo_status "Change pin: (set pin) -> $TESTPW token PIN"
			cmd_control_change_pin "${CONTAINER}" "" "$TESTPW"

		else
			echo_status "Re-changing token PIN"
			cmd_control_change_pin "${CONTAINER}" "$TESTPW" "$TESTPW"
		fi

		cmd_control_change_pin_error "${CONTAINER}" "wrongpin" "$TESTPW"
	else
		# TODO add --schsm-all flag
		echo_status "Skipping change_pin test for sc-hsm"
	fi

	echo_status "Starting container \"${CONTAINER}\""
	cmd_control_start "${CONTAINER}" "$TESTPW"

	cmd_control_config "${CONTAINER}"

	ssh ${SSH_OPTS} "echo testmessage1 > /dev/fifos/signedfifo1"

	ssh ${SSH_OPTS} "echo testmessage2 > /dev/fifos/signedfifo2"

	cmd_control_list_guestos "gyroidos-coreos"

	cmd_control_remove_error_eexist "nonexistent-container"

	cmd_control_start_error_eexist "${CONTAINER}" "$TESTPW"


	# Stop test container
	cmd_control_stop "${CONTAINER}" "$TESTPW"

	cmd_control_stop_error_notrunning "${CONTAINER}" "$TESTPW"

	# Perform extended update test (triggers reload)
	if [[ -f "${CONTAINER}_rename.conf" ]]; then
		# get uuid since name is changed during update
		uuid=$(cmd_control_get_uuid "${CONTAINER}")

		# direct reload
		cmd_control_update_config "${uuid} /tmp/${CONTAINER}_rename.conf /tmp/${CONTAINER}_rename.sig /tmp/${CONTAINER}_rename.cert" "name: \"${CONTAINER}-rename\""

		# check if reload worked by starting with new name
		cmd_control_start "${CONTAINER}-rename" "$TESTPW"

		# indirect reload, trigger internal out-of-sync state
		cmd_control_update_config "${uuid} /tmp/${CONTAINER}_update.conf /tmp/${CONTAINER}_update.sig /tmp/${CONTAINER}_update.cert" "name: \"${CONTAINER}\""

		# trigger reload
		cmd_control_stop "${uuid}" "$TESTPW"

		# check if reload worked by starting with old name
		cmd_control_start "${CONTAINER}" "$TESTPW"

		cmd_control_stop "${CONTAINER}" "$TESTPW"
	fi
	#
	# Perform additional tests in second run
	if [[ "${SECOND_RUN}" == "y" ]];then

		# test start / stop cycles
		for I in {1..100};do
			echo_status "Start/stop cycle $I"

			cmd_control_start "${CONTAINER}" "$TESTPW"

			cmd_control_stop "${CONTAINER}" "$TESTPW"
		done


		# test retrieve_logs command
		TMPDIR="$(ssh ${SSH_OPTS} "mktemp -d -p /tmp")"

		if [[ "ccmode" == "${MODE}" ]] && ! [[ "y" == "${OPT_CC_MODE_EXPERIMENTAL}" ]];then
			cmd_control_retrieve_logs "${TMPDIR}" "CMD_UNSUPPORTED"
		else
			cmd_control_retrieve_logs "${TMPDIR}" "CMD_OK"
		fi

		# Test container removal
		echo_status "Second test run, removing container"
		cmd_control_remove "${CONTAINER}" "$TESTPW"

		echo_status "Check container has been removed"
		cmd_control_list_ncontainer "${CONTAINER}"

		echo_status "Removing non-existent container"
		cmd_control_remove_error_eexist "${CONTAINER}" "$TESTPW"
	fi

}

do_test_provisioning() {
	echo_status "########## Starting device provisioning test suite ##########"
	# test provisioning always last since set_provisioned reduces the command set

	echo_status "Check that device is not provisioned yet"
	cmd_control_get_provisioned false

	echo_status "Setting device to provisioned state"
	cmd_control_set_provisioned "CMD_OK"

	echo_status "Check that device is provisioned"
	cmd_control_get_provisioned true

	echo_status "Check device reduced command set"
	cmd_control_set_provisioned "CMD_UNSUPPORTED"
}

do_test_update() {
	GUESTOS_NAME="$1"
	GUESTOS_VERSION="$2"

	local update_path="/${update_base_url#/}/operatingsystems/x86/${GUESTOS_NAME}-${GUESTOS_VERSION}"
	echo_status "########## Starting guestos update test suite, GUESTOS=${GUESTOS_NAME}, VERSION=${GUESTOS_VERSION} ##########"

	ssh ${SSH_OPTS} "mkdir -p '${update_path}'"
	cmd_control_push_guestos_config "/tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.conf /tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.sig /tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.cert" "GUESTOS_MGR_INSTALL_FAILED"

	ssh ${SSH_OPTS} "truncate -s '${GUESTOS_VERSION}G' '${update_path}/root.img'"
	echo_status "ssh ${SSH_OPTS} \"truncate -s '${GUESTOS_VERSION}G' '${update_path}/root.img'\""
	ssh ${SSH_OPTS} "truncate -s '${GUESTOS_VERSION}M' '${update_path}/root.hash.img'"

	echo_status "ssh ${SSH_OPTS} \"ls -lh '${update_path}'\""
	ssh ${SSH_OPTS} "ls -lh '${update_path}'"

	cmd_control_push_guestos_config "/tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.conf /tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.sig /tmp/${GUESTOS_NAME}-${GUESTOS_VERSION}.cert" "GUESTOS_MGR_INSTALL_COMPLETED"

	ssh ${SSH_OPTS} "rm -r '${update_path}'"
}

do_test_push_kernel_update() {
	# obtain the guestos verion of the current kernel, should match the installed one
	KERNEL_VERSION=$(gawk 'match($0, /^version: (.*)/, ary) {print ary[1]}' kernel/kernel-*.conf)
	KERNEL_VERSION_NEW=$(($KERNEL_VERSION + 1))

	echo_status "########## Starting kernel update test suite, GUESTOS=${GUESTOS_NAME}, VERSION_UPDATE: ${KERNEL_VERSION} -> ${KERNEL_VERSION_NEW}  ##########"
	do_copy_kernel_update $KERNEL_VERSION_NEW
	ssh ${SSH_OPTS} "mkdir -p /${update_base_url}/operatingsystems/x86"
	ssh ${SSH_OPTS} "mv /tmp/kernel-${KERNEL_VERSION_NEW} /${update_base_url}/operatingsystems/x86"
	cmd_control_push_guestos_config "/tmp/kernel-${KERNEL_VERSION_NEW}.conf /tmp/kernel-${KERNEL_VERSION_NEW}.sig /tmp/kernel-${KERNEL_VERSION_NEW}.cert" "GUESTOS_MGR_INSTALL_COMPLETED"

	#ssh ${SSH_OPTS} "rm -r /${update_base_url}/operatingsystems/x86/kernel-${KERNEL_VERSION}"

	# after successful kernel update both versions must be installed
	cmd_control_list_guestos "${KERNEL_VERSION}"
	cmd_control_list_guestos "${KERNEL_VERSION_NEW}"
}

do_test_check_kernel_version() {
	# obtain the guestos verion of the current kernel, should match the installed one
	KERNEL_VERSION=$(gawk 'match($0, /^version: (.*)/, ary) {print ary[1]}' kernel/kernel-*.conf)
	KERNEL_VERSION_NEW=$(($KERNEL_VERSION + 1))

	# after reboot, still both versions must be installed
	cmd_control_list_guestos "${KERNEL_VERSION}"
	cmd_control_list_guestos "${KERNEL_VERSION_NEW}"

	# check the logs to ensure B boot option was started after update
	if [[ "ccmode" != "${MODE}" ]] || [[ "y" == "${OPT_CC_MODE_EXPERIMENTAL}" ]];then
		TMPDIR=$(ssh ${SSH_OPTS} "mktemp -d -p /tmp")
		cmd_control_retrieve_logs "${TMPDIR}" "CMD_OK"
		LATEST_LOG=$(ssh ${SSH_OPTS} "ls ${TMPDIR}/cml-daemon* | tail -n1")
		echo_status "latest log: ${LATEST_LOG}"
		# 'device.conf path is /data/cml/device.conf.B' appears in every build's log
		GREP_OUT=$(ssh ${SSH_OPTS} "grep 'device.conf path is /data/cml/device.conf.B' ${LATEST_LOG}")
		echo_status "grep output: ${GREP_OUT}"
		if [[ -z "${GREP_OUT}" ]]; then
			echo_status "cmld did not load expected config. kernel update failed."
			exit 1
		fi
	fi
}

# Parse CLI arguments
# -----------------------------------------------
parse_cli $@

# Compile project
# -----------------------------------------------
if [[ $COMPILE == true ]]
then
	# changes dir to BUILD_DIR
	source init_ws.sh ${BUILD_DIR} x86 genericx86-64

	if [[ $FORCE == true ]]
	then
		bitbake -c clean multiconfig:container:gyroidos-core
		bitbake -c clean cmld
		bitbake -c clean gyroidos-cml-initramfs
		bitbake -c clean gyroidos-cml
	fi

	if [[ $BRANCH != "" ]]
	then
		# TODO \${BRANCH} is defined in init_ws.sh -> if changes there, this won't work
		sed -i "s/branch=\${BRANCH}/branch=$BRANCH/g" cmld_git.bbappend
	fi

	bitbake multiconfig:container:gyroidos-core
	bitbake gyroidos-cml
elif [[ -z "${IMGPATH}" ]]
then
	if [ ! -d "${BUILD_DIR}" ]
	then
		echo_error "Could not find build directory at \"${BUILD_DIR}\". Specify --build-dir or --img."
		exit 1
	fi

	cd ${BUILD_DIR}
	echo_status "Changed dir to ${BUILD_DIR}"
fi

# Check if the branch matches the built one
if [[ $BRANCH != "" ]]
then
	# Check if cmld was build
	if [ -z $(ls -d tmp/work/core*/cmld/git*/git) ]
	then
		echo_error "No cmld build found: did you compile?"
		exit 1
	fi


	BUILD_BRANCH=$(git -C tmp/work/core*/cmld/git*/git branch | tee /proc/self/fd/1 | grep '*' | awk '{ print $NF }')  # check if git repo found and correct branch used
	if [[ $BRANCH != $BUILD_BRANCH ]]
	then
		echo_error "The specified branch \"$BRANCH\" does not match the build ($BUILD_BRANCH). Please recompile with flag -c."
		exit 1
	fi
fi

# Ensure VM is not running
# -----------------------------------------------
echo_status "Ensure VM is not running"
if [[ $(pgrep $PROCESS_NAME) != "" ]]
then
	if [ ${KILL_VM} ];then
		echo_status "Kill current VM (--kill was given)"
		pgrep ${PROCESS_NAME} | xargs kill -SIGKILL
else
		echo_error "VM instance called \"$PROCESS_NAME\" already running. Please stop/kill it first."
		exit 1
fi
else
	echo_status "VM not running"
fi

# Create image
# -----------------------------------------------
echo_status "Creating images"
if ! [ -e "${PROCESS_NAME}.ext4fs" ]
then
	truncate -s 10G "${PROCESS_NAME}.ext4fs"
fi

mkfs.ext4 -E nodiscard -L containers "${PROCESS_NAME}.ext4fs"

# Backup system image
# TODO it could have been modified if VM run outside of this script with different args already
rm -f ${PROCESS_NAME}.img

if ! [[ -z "${IMGPATH}" ]];then
	echo_status "Testing image at ${IMGPATH}"
	mv -- "${IMGPATH}" "${PROCESS_NAME}.img"
else
	echo_status "Testing image at $(pwd)/tmp/deploy/images/genericx86-64/gyroidos_image/gyroidosimage.img"
	# Attempt COW copy, fallback to regular cp
	cp --reflink=auto --dereference tmp/deploy/images/genericx86-64/gyroidos_image/gyroidosimage.img "${PROCESS_NAME}.img"
fi

# Prepare image for test with physical tokens
if ! [[ -z "${HSM_SERIAL}" ]]
then
	echo_status "Preparing image for test with hsm container"
	/usr/local/bin/local_tokentest_handling.sh prepare_img "$(pwd)/${PROCESS_NAME}.img"
fi

# Start VM
# -----------------------------------------------

# copy for faster startup
if [ -f "/usr/share/OVMF/OVMF_VARS.fd" ];then
	cp /usr/share/OVMF/OVMF_VARS.fd OVMF_VARS.fd
elif [ -f "/usr/share/OVMF/OVMF_VARS_4M.fd" ];then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS.fd
else
	echo_error "Failed to locate OVMF_VARS"
	exit 1
fi

STAGE="BOOT1"
# Start test VM
start_vm
STAGE="RUN1"


# Retrieve VM host key
echo_status "Retrieving VM host key"
for I in $(seq 1 10) ;do
	echo_status "Scanning for VM host key on port $SSH_PORT"
	if ssh-keyscan -T 10 -p $SSH_PORT -H 127.0.0.1 > ${PROCESS_NAME}.vm_key ;then
		echo_status "Got VM host key: $!"
		break
	elif [ "10" = "$I" ];then
		echo_error "exitcode $1"
		exit 1
	fi

	echo_status "Failed to retrieve VM host key"
done

echo_status "extracting current installed OS version"
installed_guestos_version="$(cmd_control_get_guestos_version gyroidos-coreos)"
echo_status "Found OS version: $installed_guestos_version"

update_base_url="var/volatile/tmp"

# Prepare tests
# -----------------------------------------------
echo_status "########## Preparing tests ##########"

do_create_testconfigs

do_copy_configs

# Prepare test container
# -----------------------------------------------


echo_status "########## Setting up test containers ##########"
# Test if cmld is up and running
echo_status "Test if cmld is up and running"
cmd_control_list

# Skip root CA registering test if test PKI no available or disabled
if [[ "$COPY_ROOTCA" == "y" ]]
then
	echo_status "Copying root CA at ${PKI_DIR}/ssig_rootca.cert to image as requested"
	for I in $(seq 1 10) ;do
		echo_status "Trying to copy rootca cert"
		if scp -q $SCP_OPTS ${PKI_DIR}/ssig_rootca.cert root@127.0.0.1:/tmp/;then
			echo_status "scp was sucessful"
			break
		elif ! [ $I -eq 10 ];then
			echo_status "Failed to copy root CA, retrying..."
			sleep 0.5
		else
			echo_error "Could not copy root CA to VM, exiting..."
			exit 1
		fi
	done


	cmd_control_ca_register " /tmp/ssig_rootca.cert"
fi

echo_status "Updating c0.conf"
cmd_control_update_config "core0 /tmp/c0.conf /tmp/c0.sig /tmp/c0.cert" "allow_dev: \"b 8:"
cmd_control_config "core0"

# Create test containers
echo_status "OPT_FORCE_SIG_CFGS: $OPT_FORCE_SIG_CFGS"
if [ "dev" = "$MODE" ] && [ "n" = "$OPT_FORCE_SIG_CFGS" ];then
	echo_status "Creating unsigned test container, expecting success:\n$(cat testcontainer.conf)"
	cmd_control_create "/tmp/testcontainer.conf"
	cmd_control_list_container "testcontainer"
else
	echo_status "Creating unsigned test container, expecting error:\n$(cat testcontainer.conf)"
	cmd_control_create_error "/tmp/testcontainer.conf"
fi

echo_status "Creating signed container:\n$(cat signedcontainer1.conf)"
cmd_control_create "/tmp/signedcontainer1.conf" "/tmp/signedcontainer1.sig" "/tmp/signedcontainer1.cert"
cmd_control_list_container "signedcontainer1"


if [[ -z "${HSM_SERIAL}" ]];then
	echo_status "Creating signed container:\n$(cat signedcontainer2.conf)"
	cmd_control_create "/tmp/signedcontainer2.conf" "/tmp/signedcontainer2.sig" "/tmp/signedcontainer2.cert"
	cmd_control_list_container "signedcontainer2"
fi

echo_status "Creating rmcontainer:\n$(cat rmcontainer3.conf)"
cmd_control_create "/tmp/rmcontainer3.conf" "/tmp/rmcontainer3.sig" "/tmp/rmcontainer3.cert"
cmd_control_list_container "rmcontainer3"

sync_to_disk

sync_to_disk


STAGE="BOOT2"
cmd_control_reboot
wait_vm
STAGE="RUN2"

# List test containers
if [ "dev" = "$MODE" ] && [ "n" = "$OPT_FORCE_SIG_CFGS" ];then
	cmd_control_list_container "testcontainer"
fi

cmd_control_list_container "signedcontainer1"

if [[ -z "${HSM_SERIAL}" ]];then
	cmd_control_list_container "signedcontainer2"
fi

do_copy_configs

echo_status "Updating signedcontainer1"

cmd_control_update_config "signedcontainer1 /tmp/signedcontainer1_update.conf /tmp/signedcontainer1_update.sig /tmp/signedcontainer1_update.cert" "netif: \"00:00:00:00:00:11\""
# Workaround to avoid issues qith QEMU's forwarding rules
#sleep 5

# Set device container pairing state if testing with physical tokens
if ! [[ -z "${HSM_SERIAL}" ]];then
	STAGE="SE_PREPARE"
	echo_status "########## Preparing SE ##########"

	sync_to_disk
	sync_to_disk

	force_stop_vm

	echo_status "Setting container pairing state"
	/usr/local/bin/local_tokentest_handling.sh prepare_container "$(pwd)/${PROCESS_NAME}.ext4fs"

	echo_status "Waiting for QEMU to cleanup USB devices"
	sleep 2

	start_vm
	echo_status "Waiting for USB devices to become ready in QEMU"
	sleep 2
	echo_status "VM USB Devices:"
	ssh ${SSH_OPTS} 'lsusb' 2>&1
	STAGE="RUN2"

	do_copy_configs
fi

# List test containers
if [ "dev" = "$MODE" ] && [ "n" = "$OPT_FORCE_SIG_CFGS" ];then
	cmd_control_list_container "testcontainer"
fi

cmd_control_list_container "signedcontainer1"

if [[ -z "${HSM_SERIAL}" ]];then
	cmd_control_list_container "signedcontainer2"
fi

do_copy_update_configs

# Start tests
# -----------------------------------------------

echo_status "Starting tests"

if [ -z "${HSM_SERIAL}" ];then
	do_test_complete "signedcontainer1" "n" "n"
	do_test_complete "signedcontainer2" "n" "n"
else
	do_test_complete "signedcontainer1" "n" "y"
fi

do_test_rm "rmcontainer3"

do_test_update "nullos" "1"
do_test_update "nullos" "2"

STAGE="BOOT3"
cmd_control_reboot
# Workaround to avoid issues qith QEMU's forwarding rules
#sleep 5
wait_vm
STAGE="RUN3"

do_copy_configs
do_copy_update_configs

#echo_status "Waiting for USB devices to become ready in QEMU"
#sleep 5
#ssh ${SSH_OPTS} 'echo_status "VM USB Device: " && lsusb' 2>&1

if [ -z "${HSM_SERIAL}" ];then
	do_test_complete "signedcontainer1" "y" "n"
	do_test_complete "signedcontainer2" "y" "n"
else
	do_test_complete "signedcontainer1" "y" "y"
fi

do_test_update "nullos" "3"

# Remove installed nullos test GuestOS versions from data partition to free
# disk space for the kernel update test. Uses control remove_guestos which
# removes the latest version each call, so call once per installed version.
echo_status "Removing nullos test GuestOS images to free disk space"
for i in 1 2 3; do
	ssh ${SSH_OPTS} "/usr/sbin/control remove_guestos nullos" 2>&1 || true
done
ssh ${SSH_OPTS} "df -h /data" || true

do_test_provisioning

do_test_push_kernel_update

STAGE="BOOT4"
cmd_control_reboot
wait_vm
STAGE="RUN4"

do_test_check_kernel_version

if [[ "production" == "${MODE}" ]];then
	STAGE="PREPARE SWTPM"
	force_stop_vm

	echo_status "Waiting for QEMU to cleanup"
	sleep 2

	# logs cannot be retrieved with fetch_logs after encryption
	fetch_logs

	echo_status "Starting swtpm"
	start_swtpm

	SWTPM="-chardev socket,id=chrtpm,path=/tmp/swtpmqemu/swtpm-sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0"
	start_vm

	STAGE="RUN5"
	cmd_control_state_is_running "TPM2D"
fi

# Success
# -----------------------------------------------
echo -e "\n\nSUCCESS: All tests passed"

trap - EXIT

force_stop_vm

if [[ "production" != "${MODE}" ]];then
	fetch_logs
fi

exit 0
