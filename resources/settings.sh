#!/bin/bash
set -e

export PATH="/sbin/:usr/sbin/:${PATH}"

PROCESS_NAME="qemu-gyroid-ci"
SSH_PORT=2222
BUILD_DIR=""
KILL_VM=false
IMGPATH=""
MODE=""
LOG_DIR=""

# Hardware-target mode: when TARGET_IP is set (env or --target-ip), the suite runs
# against a physical node over SSH instead of a local QEMU VM. SSH_HOST is the host
# the ssh/scp commands target (localhost for QEMU port-forward, the node IP for HW).
TARGET_IP="${TARGET_IP:-}"
SSH_HOST="127.0.0.1"

# Directory containing test PKI for image
PKI_DIR=""

# Serial of USB Token
HSM_SERIAL=""

# Copy root CA from test PKI to image
COPY_ROOTCA="y"

SCRIPTS_DIR=""

TESTPW="pw"

###################################################################################################
# COMMAND LINE INTERFACE
###################################################################################################
parse_cli() {
    # Argument retrieval
    # -----------------------------------------------
    while [[ $# > 0 ]]; do
    case $1 in
        -h|--help)
        echo -e "Performs set of tests to start, stop and modify containers in VM among other operations."
        echo " "
        echo "Run with ./run-tests.sh { --builddir <out-yocto dir> | --img <image file> } [-c] [-k] [-v <display number>] [-f] [-b <branch name>] [-d <directory>]"
        echo " "
        echo "options:"
        echo "-h, --help                  Show brief help"
        echo "-c, --compile               (Re-)compile images (e.g. if new changes were commited to the repository)"
        echo "-b, --branch <branch>       Use this cml git branch (if not default) during compilation"
        echo "                            (see cmld recipe and init_ws.sh for details on branch name and repository location)"
        echo "-d, --dir <directory>       Use this path to workspace root directory if not current directory"
        echo "-d, --builddir <directory>       Use this path as build directory name"
        echo "-f, --force                 Clean up all components and rebuild them"
        echo "-s, --ssh <ssh port>        Use this port on the host for port forwarding (if not default 2223)"
        echo "-v, --vnc <display number>  Start the VM with VNC (port 5900 + display number)"
        echo "-t, --telnet <telnet port>  Start VM with telnet on specified port (connect with 'telnet localhost <telnet port>')"
        echo "-k, --kill                  Kill the VM after the tests are completed"
        echo "-n, --name        	Use the given name for the QEMU VM"
        echo "-p, --pki         	Use the given test PKI directory"
        echo "-i, --image       	Test the given GyroidOS image instead of looking inside --dir"
        echo "-m, --mode        	Test \"dev\", \"production\", or \"ccmode\" image? Default is \"dev\""
        echo "-e, --enable-hsm <serial> <vid> <pid> <pin>	Test with given hsm"
        echo "-k, --skip-rootca	Skip attempt to copy custom root CA to image"
        echo "-r, --scripts-dir	Specify directory containing signing scripts (gyroidos_build repo)"
        exit 1
        ;;
        -c|--compile)
        COMPILE=true
        shift
        ;;
        -b|--branch)
        shift
        BRANCH=$1
        if [[ $BRANCH  == "" ]]
        then
            echo_error "No branch specified. Run with --help for more information."
            exit 1
        fi
        shift
        ;;
        -d|--dir)
        shift
        if [[ $1  == "" || ! -d $1 ]]
        then
            echo_error "No (existing) directory specified. Run with --help for more information."
            exit 1
        fi
        echo_status "changing to directory $(pwd)"
        cd $1
        echo_status "changed to directory $(pwd)"
        shift
        ;;
        -o|--builddir)
        shift
        BUILD_DIR="$(readlink -v -f $1)"
        shift
        ;;
        -f|--force)
        shift
        FORCE=true
        ;;
        -v|--vnc)
        shift
        if ! [[ $1 =~ ^[0-9]+$ ]]
        then
            echo_error "VNC port must be a number. (got $1)"
            exit 1
        fi
        VNC="-vnc 0.0.0.0:$1 -vga std"
        shift
        ;;
        -s|--ssh)
        shift
        SSH_PORT=$1
        if ! [[ $SSH_PORT =~ ^[0-9]+$ ]]
        then
            echo_error "ssh host port must be a number. (got $SSH_PORT)"
            exit 1
        fi
        shift
        ;;
        -t|--telnet)
        shift
        if ! [[ $1 =~ ^[0-9]+$ ]]
        then
            echo_error "telnet host port must be a number. (got $1)"
            exit 1
        fi
        TELNET="-serial mon:telnet:127.0.0.1:$1,server,nowait"
        shift
        ;;
        -k|--kill)
        shift
        KILL_VM=true
        ;;
        -n|--name)
        shift
        PROCESS_NAME=$1
        shift
        ;;
        -p|--pki)
        shift
        PKI_DIR="$(readlink -v -f $1)"
        shift
        ;;
        -i|--image)
        shift
        IMGPATH=$1
        shift
        ;;
        -m|--mode)
        shift
        if ! [[ "$1" = "dev" ]] && ! [[ $1 = "production" ]] && ! [[ "$1" = "ccmode" ]];then
        echo_error "Unkown mode \"$1\" specified. Exiting..."
        exit 1
        fi
        echo_status "Testing \"$1\" image"
        MODE=$1
        shift
        ;;
        -e|--enable-hsm)
        shift
        HSM_SERIAL="$1"
        shift
        HSM_VID="$1"
        shift
        HSM_PID="$1"
        shift
        TESTPW="$1"
        PASS_HSM="-usb -device qemu-xhci -device usb-host,vendorid=0x${HSM_VID},productid=0x${HSM_PID}"
        echo_status "Enable sc-hsm tests for token ${HSM_SERIAL}"
        shift
        ;;
        -k|--skip-rootca)
        COPY_ROOTCA="n"
        shift
        ;;
        -r| --scripts-dir)
        shift
        SCRIPTS_DIR="$(readlink -v -f $1)"
        shift
        ;;
        -l| --log-dir)
        shift
        LOG_DIR="$(readlink -v -m $1)"
        shift
        ;;
        --force-sig-cfgs)
          echo "Enforcing signed configs"
          OPT_FORCE_SIG_CFGS="y"
          shift
          ;;
        --cc-mode-experimental)
          echo "Testing with CC_MODE_EXPERIMENTAL enabled"
          OPT_CC_MODE_EXPERIMENTAL="y"
          shift
          ;;
        --target-ip)
        shift
        TARGET_IP="$1"
        shift
        ;;

        *)
        echo_error "Unknown arguments specified? ($1)"
        exit 1
        ;;
    esac
    done

    # check PKI dir
    if [[ -z "${PKI_DIR}" ]];then
        echo_status "--pki not specified, assuming \"test_certificates\""
        PKI_DIR="test_certificates"
    fi

    if ! [ -d "${PKI_DIR}" ];then
        echo_error "No PKI given, exiting..."
        exit 1
    fi

    # Hardware target: talk to the real node over SSH (port 22). QEMU keeps using the
    # forwarded localhost port. Default to the 'dev' image for the hardware bring-up.
    if [[ -n "${TARGET_IP}" ]];then
        SSH_HOST="${TARGET_IP}"
        SSH_PORT=22
        [[ -z "${MODE}" ]] && MODE="dev"
        echo_status "Hardware-target mode: root@${SSH_HOST}:${SSH_PORT}"
    fi

    BASE_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=${PROCESS_NAME}.vm_key -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=30"
    SCP_OPTS="-P $SSH_PORT $BASE_OPTS"
    SSH_OPTS="-p $SSH_PORT $BASE_OPTS root@${SSH_HOST}"
}
