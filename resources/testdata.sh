#!/bin/bash
set -e

do_create_testconfigs() {
# Create container configuration files for tests
# -----------------------------------------------

if [[ -z "$SCHSM_SERIAL" ]];then

cat > ./testcontainer.conf << EOF
name: "testcontainer"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
EOF


cat > ./signedcontainer1.conf << EOF
name: "signedcontainer1"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
EOF


cat > ./signedcontainer1_update.conf << EOF
name: "signedcontainer1"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
fifos: "signedfifo11"
fifos: "signedfifo12"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_1"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_2"
}


net_ifaces {
netif: "00:00:00:00:00:11"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:14"
}
EOF

cat > ./signedcontainer1_rename.conf << EOF
name: "signedcontainer1-rename"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
fifos: "signedfifo11"
fifos: "signedfifo12"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_1"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_2"
}


net_ifaces {
netif: "00:00:00:00:00:11"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:14"
}
EOF

cat > ./signedcontainer2.conf << EOF
name: "signedcontainer2"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:3 rwm"
allow_dev: "b 8:* rwm"
fifos: "signedfifo21"
fifos: "signedfifo22"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_3"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_4"
}

net_ifaces {
netif: "00:00:00:00:00:14"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:11"
}
net_ifaces {
netif: "00:00:00:00:00:15"
}
net_ifaces {
netif: "00:00:00:00:00:16"
}
EOF


else

cat > ./testcontainer.conf << EOF
name: "testcontainer"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:5 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
EOF


cat > ./signedcontainer1.conf << EOF
name: "signedcontainer1"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
token_type: USB
usb_configs {
  id: "${HSM_VID}:${HSM_PID}"
  serial: "${HSM_SERIAL}"
  assign: true
  type: TOKEN
}
image_sizes {
  image_name: "etc"
  image_size: 10
}
EOF


cat > ./signedcontainer1_update.conf << EOF
name: "signedcontainer1"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
token_type: USB
usb_configs {
  id: "${HSM_VID}:${HSM_PID}"
  serial: "${HSM_SERIAL}"
  assign: true
  type: TOKEN
}
image_sizes {
  image_name: "etc"
  image_size: 10
}
fifos: "signedfifo11"
fifos: "signedfifo12"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_1"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_2"
}


net_ifaces {
netif: "00:00:00:00:00:11"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:14"
}
EOF

cat > ./signedcontainer1_rename.conf << EOF
name: "signedcontainer1-rename"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:2 rwm"
token_type: USB
usb_configs {
  id: "${HSM_VID}:${HSM_PID}"
  serial: "${HSM_SERIAL}"
  assign: true
  type: TOKEN
}
image_sizes {
  image_name: "etc"
  image_size: 10
}
fifos: "signedfifo11"
fifos: "signedfifo12"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_1"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_2"
}


net_ifaces {
netif: "00:00:00:00:00:11"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:14"
}
EOF

cat > ./signedcontainer2.conf << EOF
name: "signedcontainer2"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:3 rwm"
fifos: "signedfifo21"
fifos: "signedfifo22"

vnet_configs {
if_name: "vnet0"
configure: false
if_rootns_name: "r_3"
}
vnet_configs {
if_name: "vnet1"
configure: false
if_rootns_name: "r_4"
}

net_ifaces {
netif: "00:00:00:00:00:14"
mac_filter: "AA:AA::AA:AA:AA"
mac_filter: "00:00:00:00:00:11"
}
net_ifaces {
netif: "00:00:00:00:00:15"
}
net_ifaces {
netif: "00:00:00:00:00:16"
}
EOF

fi

echo_status "Prepared testcontainer.conf:"
echo "$(cat ./testcontainer.conf)"

echo_status "Prepared signedcontainer1.conf:"
echo "$(cat ./signedcontainer1.conf)"

echo_status "Prepared signedcontainer1_update.conf:"
echo "$(cat ./signedcontainer1_update.conf)"

echo_status "Prepared signedcontainer1_rename.conf:"
echo "$(cat ./signedcontainer1_rename.conf)"

echo_status "Prepared signedcontainer2.conf:"
echo "$(cat ./signedcontainer2.conf)"


cat > ./rmcontainer3.conf << EOF
name: "rmcontainer3"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:4 rwm"
image_sizes {
  image_name: "etc"
  image_size: 10
}
EOF

echo_status "Prepared rmcontainer3.conf:"
echo "$(cat ./rmcontainer3.conf)"


cat > ./c0.conf << EOF
name: "core0"
guest_os: "gyroidos-coreos"
guestos_version: $installed_guestos_version
assign_dev: "c 4:1 rwm"
allow_dev: "b 8:* rwm"
EOF


echo_status "Prepared c0.conf:"
echo "$(cat ./c0.conf)"


cat > ./nullos-1.conf << EOF
name: "nullos"
hardware: "x86"
version: 1
init_path: "/sbin/init"
init_param: "splash"
mounts {
	image_file: "root"
	mount_point: "/"
	fs_type: "squashfs"
	mount_type: SHARED_RW
	image_size: 1073741824
	image_sha1: "2a492f15396a6768bcbca016993f4b4c8b0b5307"
	image_sha2_256: "49bc20df15e412a64472421e13fe86ff1c5165e18b2afccf160d4dc19fe68a14"
	image_verity_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
}
description {
	en: "null os just for update testing 1GB root.img (x86)"
}
update_base_url: "file://$update_base_url"
build_date: "$(date +%F%T%Z -u)"
EOF

cat > ./nullos-2.conf << EOF
name: "nullos"
hardware: "x86"
version: 2
init_path: "/sbin/init"
init_param: "splash"
mounts {
	image_file: "root"
	mount_point: "/"
	fs_type: "squashfs"
	mount_type: SHARED_RW
	image_size: 2147483648
	image_sha1: "91d50642dd930e9542c39d36f0516d45f4e1af0d"
	image_sha2_256: "a7c744c13cc101ed66c29f672f92455547889cc586ce6d44fe76ae824958ea51"
	image_verity_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
}
description {
	en: "null os just for update testing 2GB root.img (x86)"
}
update_base_url: "file://$update_base_url"
build_date: "$(date +%F%T%Z -u)"
EOF

cat > ./nullos-3.conf << EOF
name: "nullos"
hardware: "x86"
version: 3
init_path: "/sbin/init"
init_param: "splash"
mounts {
	image_file: "root"
	mount_point: "/"
	fs_type: "squashfs"
	mount_type: SHARED_RW
	image_size: 3221225472
	image_sha1: "6e7f6dca8def40df0b21f58e11c1a41c3e000285"
	image_sha2_256: "305b66a59d15b252092fbda9d09711230c429f351897cbd430e7b55a35fd3b97"
	image_verity_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
}
description {
	en: "null os just for update testing 3GB root.img (x86)"
}
update_base_url: "file://$update_base_url"
build_date: "$(date +%F%T%Z -u)"
EOF


echo_status "Prepared nullos-1.conf:"
echo "$(cat ./nullos-1.conf)"

echo_status "Prepared nullos-2.conf:"
echo "$(cat ./nullos-2.conf)"

echo_status "Prepared nullos-3.conf:"
echo "$(cat ./nullos-3.conf)"


echo "PKI_DIR there?: $PKI_DIR"
# Sign signedcontainer{1,2}.conf, c0.conf (enforced in production and ccmode images)
if [[ -d "$PKI_DIR" ]];then
	scripts_path=""
	if ! [[ -z "${SCRIPTS_DIR}" ]];then
		scripts_path="${SCRIPTS_DIR}/"
	elif ! [[ -z "${BUILD_DIR}" ]];then
		echo_status "--scripts-dir not given, assuming \"../gyroidos/build\""
		scripts_path="$(pwd)/../gyroidos/build"
		echo "scripts_path: $scripts_path"
	else
		echo_status "--scripts-dir not given, assuming \"./gyroidos/build\""
		scripts_path="$(pwd)/gyroidos/build"
	fi

	if ! [[ -d "$scripts_path" ]];then
		echo_status "Could not find gyroidos_build directory at $scripts_path."
		read -r -p "Download from GitHub?" -n 1

		if [[ "$REPLY" == "y" ]];then
			mkdir -p "$scripts_path"
			echo_status "Got y, downloading gyroidos_build repository to $scripts_path"
			git clone https://github.com/gyroidos/gyroidos_build.git "$scripts_path"
		fi
	fi

	if ! [ -f "$scripts_path/device_provisioning/oss_enrollment/config_creator/sign_config.sh" ];then
		echo_error "Could not find sign_config.sh at $scripts_path/device_provisioning/oss_enrollment/config_creator/sign_config.sh. Exiting..."
		exit 1
	fi

	signing_script="$scripts_path/device_provisioning/oss_enrollment/config_creator/sign_config.sh"

	if ! [[ -f "$signing_script" ]];then
		echo_error "$signing_script does not exist or is not a regular file. Exiting..."
		exit 1
	fi

	echo_status "Signing container configuration files using PKI at ${PKI_DIR} and $signing_script"


	for conf in "signedcontainer1" "signedcontainer1_update" "signedcontainer1_rename" "signedcontainer2" "rmcontainer3" "c0"; do
		echo "bash \"$signing_script\" --config \"./$conf.conf\" --key \"${PKI_DIR}/ssig_cml.key\" --cert \"${PKI_DIR}/ssig_cml.cert\""
		bash "$signing_script" --config "./$conf.conf" --key "${PKI_DIR}/ssig_cml.key" --cert "${PKI_DIR}/ssig_cml.cert"
	done


	echo_status "Signing guestos configuration files using using PKI at ${PKI_DIR} and $signing_script"

	for I in $(seq 1 3); do
		echo "bash \"$signing_script\" --config \"./nullos-${I}.conf\" --key \"${PKI_DIR}/ssig_cml.key\" --cert \"${PKI_DIR}/ssig_cml.cert\""
		bash "$signing_script" --config "./nullos-${I}.conf" --key "${PKI_DIR}/ssig_cml.key" --cert "${PKI_DIR}/ssig_cml.cert"
	done

	echo_status "Signing kernel update using using PKI at ${PKI_DIR} and $signing_script"
	# obtain the guestos verion of the current kernel, should match the installed one
	KERNEL_VERSION=$(gawk 'match($0, /^version: (.*)/, ary) {print ary[1]}' kernel/kernel-*.conf)
	KERNEL_VERSION_NEW=$(($KERNEL_VERSION + 1))

	# create a copy of the currently installed kernel an update with the incremented version
	cp kernel/kernel-$KERNEL_VERSION.conf kernel-$KERNEL_VERSION_NEW.conf
	echo "update_base_url: \"file://$update_base_url\"" >> kernel-$KERNEL_VERSION_NEW.conf
	cp -r kernel/kernel-$KERNEL_VERSION kernel-$KERNEL_VERSION_NEW
	sed -i "s/$KERNEL_VERSION/$KERNEL_VERSION_NEW/g" kernel-$KERNEL_VERSION_NEW.conf

	echo "bash \"$signing_script\" --config \"./kernel-$KERNEL_VERSION_NEW.conf\" --key \"${PKI_DIR}/ssig_cml.key\" --cert \"${PKI_DIR}/ssig_cml.cert\""
	bash "$signing_script" --config "./kernel-$KERNEL_VERSION_NEW.conf" --key "${PKI_DIR}/ssig_cml.key" --cert "${PKI_DIR}/ssig_cml.cert"
else
	echo_error "No test PKI found at $PKI_DIR, exiting..."
	exit 1
fi

echo_status "Signed signedcontainer{1,2}.conf, signedcontainer1_{update,rename}.conf, rmcontainer3.conf, c0.conf:"
}

do_copy_configs(){
# Copy test container configs to VM
for I in $(seq 1 10) ;do
	echo_status "Trying to copy container configs to image"

	# copy only .conf if signing was skipped
	if [ -f signedcontainer1.sig ];then
		FILES="testcontainer.conf signedcontainer1.conf signedcontainer1.sig signedcontainer1.cert \
			   signedcontainer1_update.conf signedcontainer1_update.sig signedcontainer1_update.cert \
			   signedcontainer1_rename.conf signedcontainer1_rename.sig signedcontainer1_rename.cert \
			   signedcontainer2.conf signedcontainer2.sig signedcontainer2.cert \
			   rmcontainer3.conf rmcontainer3.sig rmcontainer3.cert \
			   c0.conf c0.sig c0.cert"
	else
		FILES="signedcontainer1.conf signedcontainer1_update.conf signedcontainer2.conf c0.conf \
			   sigendcontainer1_rename.conf rmcontainer3.conf"

	fi

	if ( set -o pipefail; tar -cf - $FILES | ssh ${SSH_OPTS} 'tar -C /tmp -xf -' );then
		echo_status "copy was successful"
		break
	elif ! [ $I -eq 10 ];then
		echo_status "copy failed, retrying..."
	else
		echo_status "Failed to copy container configs to VM, exiting..."
		err_fetch_logs
	fi
done
}
