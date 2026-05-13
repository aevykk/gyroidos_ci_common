#!/usr/bin/env bash

set -euo pipefail

RUNDIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "${RUNDIR}/common.sh"

GYROIDOS_CACHE_DIR="/home/_share/yocto_mirror"
KEEP_ARTIFACTS_FOR_DAYS="30"

declare -A HYPERVISOR_MAP
HYPERVISOR_MAP[runner-1]="epyc-14.aisec.fraunhofer.de"
HYPERVISOR_MAP[runner-2]="epyc-13.aisec.fraunhofer.de"
HYPERVISOR_MAP[runner-3]="epyc-09.aisec.fraunhofer.de"
HYPERVISOR_MAP[runner-4]="epyc-13.aisec.fraunhofer.de"
# TARGET_MAP directs each runner to its sync target: TARGET_MAP[hostname]=next_host
declare -A TARGET_MAP
TARGET_MAP[runner-1]="epyc-13.aisec.fraunhofer.de -p 10002" # -> runner-2
TARGET_MAP[runner-2]="epyc-09.aisec.fraunhofer.de -p 10004" # -> runner-3
TARGET_MAP[runner-3]="epyc-13.aisec.fraunhofer.de -p 10003" # -> runner-4
TARGET_MAP[runner-4]="epyc-14.aisec.fraunhofer.de -p 10003" # -> runner-1

HOSTNAME="${HYPERVISOR_MAP["$(hostname)"]}"
NUM_HOSTS="${#TARGET_MAP[@]}"

#######################################
# This sync works as follows:
# 1. Any ssh login to root on a sync host, using the specific key, invokes this script as ForceCommand
# 2. We spawn a rsync deamon locally, and map its port via ssh to the next host in the sync chain
# 2.1. This host pulls the data from us, and then goes to step 2, but connecting to the next host in the chain
# 2.2. When the last host in the chain syncs to us, we are the first host with all changes accumulated
# 3. Now that we have all changes, we delete everything that is older than KEEP_ARTIFACTS_FOR_DAYS days
# 4. We continue with the same logic as 2., and propagate the final data onto all hosts.
#    We can spare the last step (start with index == 1 % NUM_NODES), as the invoking node already has all changes.
#
# When being invoked by the previous node, the ssh authorized_keys file sets a forcecommand to this script
# Thereby, we loose any argument. We restore this argument (our position in the sync loop) from the SSH env vars.
#
# You can test the setup by invoking a test run:
#   ci@runner-host: ssh root@localhost "/srv/gyroidos_sync/sync.sh 0 TEST"
#   This will spawn a test run, which skips any data copying operations
# A production run is invoked like:
#   ci@runner-host: ssh root@localhost "/srv/gyroidos_sync/sync.sh 0"
#   Such run will propagate the mirror.
#######################################

if [[ ! -v SSH_CONNECTION ]]; then
	# Invoked as first script in the chain or by the exec $0 that spawns iteration 2 on node 0
	POSITION="${1:-0}"  # Position in the chain, first arg, but, default to 0
	TESTRUN="${2:-}"
	INITIAL_NODE="yes"
else
	# Called by the previous Host
	read -r _ POSITION TESTRUN <<< "${SSH_ORIGINAL_COMMAND:-}"
	[[ -z "${POSITION:-}" ]] && POSITION=0
	(( POSITION == 0 )) && INITIAL_NODE="yes"
fi
if [[ -n "${INITIAL_NODE:-}" ]]; then
	if [[ ! -v GOS_FINAL_SYNC ]]; then
	       	einfo "Hi, this is ${HOSTNAME}. I am the first in the sync chain."
	else
		einfo "Hi, this is ${HOSTNAME}, continuing with the final sync"
	fi
fi

function cleanup() {
	[[ -n "${RSYNC_PID:-}" ]] && kill "$RSYNC_PID" 2>/dev/null
	[[ -n "${rsync_conf:-}" ]] && rm -f "$rsync_conf"
	return 0
}
trap cleanup EXIT

if [[ "$POSITION" =~ ^[0-9]+ ]]; then
	# ###############################################################
	# FIRST ITERATION, sync all changes to the next host in the chain
	# ###############################################################
	begin "Hi. Starting to sync."
	[[ -n "${TESTRUN:-}" ]] && eattention "We are in TEST mode."
	read -ra target_host <<< "${TARGET_MAP["$(hostname)"]}"
	# We have been invoked by the host before us. Start by pulling changes.
	if [[ -z "${TESTRUN:-}" && -z "${INITIAL_NODE:-}" ]]; then
		eprint "Pulling data from the host before us"
		# The host before us listens on port RSYNC_PORT, with pass RSYNC_PASS, user g-sync
		rsync_args=(-ah --info=stats2 -W)
		(( POSITION >= NUM_HOSTS )) && rsync_args+=(--delete-during)
		rsync "${rsync_args[@]}" "rsync://127.0.0.1:9001/gos_cache" "${GYROIDOS_CACHE_DIR}"
	fi
	if (( POSITION % NUM_HOSTS == 0 && POSITION > 0 )); then
		ok "Circle completed. Handing over to previous runner."
		exit 0
	fi

	# In the second iteration, rsync is already running on node POSITION 0
	if [[ -z "${TESTRUN:-}" && -z "${RSYNC_PID:-}" ]]; then
		rsync_conf="$(mktemp)"
		cat > "$rsync_conf" <<-EOF
		[gos_cache]
		    path = ${GYROIDOS_CACHE_DIR}
		    use chroot = no
		    read only = yes
		EOF
		rsync --daemon --no-detach --address=127.0.0.1 --port=9000 --config="$rsync_conf" &
		eprint "Rsync daemon running."
		RSYNC_PID=$!
	fi

	# Call script on the next host, thereby pulling changes from us
	einfo "Continuing with invocation on the next server (${target_host[@]})"
	next_invoke="$0 $(( POSITION + 1 ))"
	[[ -n "${TESTRUN:-}" ]] && next_invoke+=" TEST"
	#                                                                                                                                 v-- map remote 9001 to our 9000 (where rsync listens)
	ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=3s -o Compression=no -c aes128-gcm@openssh.com "${target_host[@]}" -R 127.0.0.1:9001:127.0.0.1:9000 "$next_invoke"

	# Only the first node continues executing
	if [[ -z "${INITIAL_NODE:-}" ]]; then
		ok "Done syncing. Handing over to previous runner."
		exit 0
	elif [[ -z "${GOS_FINAL_SYNC:-}" ]]; then
		export GOS_FINAL_SYNC="yes"
		# Clean up: delete regular files older than 7 days
		if [[ -z "${TESTRUN:-}" ]]; then
			einfo "Cleaning up files older than ${KEEP_ARTIFACTS_FOR_DAYS} days from mirror"
			deleted_count="$(find "${GYROIDOS_CACHE_DIR}" -type f -mtime "+${KEEP_ARTIFACTS_FOR_DAYS}" -delete -printf '.' | wc -c)"
			einfo "Removed ${deleted_count} file(s), keeping files younger than ${KEEP_ARTIFACTS_FOR_DAYS} days."
		fi
		# Start second iteration at NUM_HOSTS+1 so all nodes see POSITION >= NUM_HOSTS
		exec env RSYNC_PID="${RSYNC_PID:-}" "$0" $((NUM_HOSTS + 1)) "${TESTRUN:-}"
	fi
	# Final node, final run, exit 0
	ok "This is goodbye from the inital node. Sync completed. Thanks for playing."
	exit 0
else
	die "Garbage was given as position: \`$POSITION'"
fi

