#!/usr/bin/env bash
# pxe_reset.sh — power-cycle the PXE test target's outlet on a Raritan PX PDU via SNMP.
# Invoked by pxe_bootstrap_test.sh via RESET_CMD to trigger the initial (flash) boot.
# Talks to the PX PDU directly (the KX III KVM has no scriptable power).
#
# Config comes from the environment (set on the pxe Jenkins node):
#   PDU_HOST        PX PDU hostname/IP                                (required)
#   PDU_OUTLET      outlet the target is plugged into, 1-based        (required)
#   SNMP_COMMUNITY  SNMPv2c write community                           (v2c)
#   SNMP_USER       SNMPv3 security name — its presence selects v3    (v3)
#   SNMP_AUTH_PASS  SNMPv3 auth passphrase  (SNMP_AUTH_PROTO, default SHA)
#   SNMP_PRIV_PASS  SNMPv3 privacy passphrase (SNMP_PRIV_PROTO, default AES)
#   SNMP_LEVEL      force sec level: noAuthNoPriv|authNoPriv|authPriv (else auto)
#   OFF_SETTLE      seconds off before on for the cold reset          (default 5)
set -euo pipefail

OFF_SETTLE="${OFF_SETTLE:-5}"

log() { echo "[pxe-reset $(date +%H:%M:%S)] $*"; }
die() { echo "[pxe-reset] ERROR: $*" >&2; exit 1; }

[ -n "${PDU_HOST:-}" ]   || die "PDU_HOST not set"
[ -n "${PDU_OUTLET:-}" ] || die "PDU_OUTLET not set"
command -v snmpset >/dev/null 2>&1 || die "snmpset not installed (net-snmp)"

# SNMPv3 (USM) if SNMP_USER is set, else SNMPv2c with SNMP_COMMUNITY.
if [ -n "${SNMP_USER:-}" ] || [ "${SNMP_VERSION:-}" = "3" ]; then
    [ -n "${SNMP_USER:-}" ] || die "SNMP_USER not set (required for SNMPv3)"
    if   [ -n "${SNMP_LEVEL:-}" ];     then level="$SNMP_LEVEL"
    elif [ -n "${SNMP_PRIV_PASS:-}" ]; then level="authPriv"
    elif [ -n "${SNMP_AUTH_PASS:-}" ]; then level="authNoPriv"
    else                                    level="noAuthNoPriv"; fi
    snmp_args=(-v3 -u "$SNMP_USER" -l "$level")
    [ -n "${SNMP_AUTH_PASS:-}" ] && snmp_args+=(-a "${SNMP_AUTH_PROTO:-SHA}" -A "$SNMP_AUTH_PASS")
    [ -n "${SNMP_PRIV_PASS:-}" ] && snmp_args+=(-x "${SNMP_PRIV_PROTO:-AES}" -X "$SNMP_PRIV_PASS")
    log "SNMPv3 as '${SNMP_USER}' (${level})"
else
    [ -n "${SNMP_COMMUNITY:-}" ] || die "set SNMP_COMMUNITY (v2c) or SNMP_USER (v3)"
    snmp_args=(-v2c -c "$SNMP_COMMUNITY")
    log "SNMPv2c"
fi

# PDU2-MIB::switchingOperation.<pduId=1>.<outlet>  (off=0, on=1). Cold reset: off, settle, on.
oid=".1.3.6.1.4.1.13742.6.4.1.2.1.2.1.${PDU_OUTLET}"
log "power-cycling ${PDU_HOST} outlet ${PDU_OUTLET} (off, ${OFF_SETTLE}s, on)"
snmpset "${snmp_args[@]}" "$PDU_HOST" "$oid" i 0
sleep "$OFF_SETTLE"
snmpset "${snmp_args[@]}" "$PDU_HOST" "$oid" i 1

log "reset issued for ${PDU_HOST} outlet ${PDU_OUTLET}"
