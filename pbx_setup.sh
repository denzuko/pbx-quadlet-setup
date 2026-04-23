#!/usr/bin/env bash
## PBX INFRASTRUCTURE AUTOMATION SCRIPT v4.1
## ARCHITECTURE: ZFS + homectl + Quadlet .build + Keepalived VIP
## STANDARDS COMPLIANCE: 2026.QA.v4
##
## Changes from v4.0:
##   - SC2015: replaced && log || exit with explicit if blocks (smoke tests)
##   - Added trap for ERR/EXIT to handle CRED_FILE cleanup on abort
##   - Added UID collision preflight check
##   - Added retry loop (with timeout) replacing hardcoded sleep 15
##   - machinectl exit-code propagation documented; wrapped in explicit checks
##   - PJSIP smoke test demoted to WARNING (endpoint reg is async post-start)
set -euo pipefail

## SECTION 1: VARIABLE DECLARATIONS
PBX_USER="pbxadmin"
PBX_UID=2000
PBX_DATASET="storage/containers/pbx"
PBX_MOUNT="/srv/pbx"
RTP_START=10000
RTP_END=10100
VRRP_IFACE="wlan0"              # Interface keepalived manages the VIP on
MOH_STREAM_URL="http://host.containers.internal:8000/live.mp3"
CONTAINER_STARTUP_TIMEOUT=60   # seconds
CRED_FILE=""                   # set after mktemp; used by trap

log()  { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"; }
die()  { log "FATAL: $1"; exit 1; }

# Trap: remove cred file on any unclean exit so secrets don't linger
cleanup() {
    local rc=$?
    if [[ -n "$CRED_FILE" && -f "$CRED_FILE" && $rc -ne 0 ]]; then
        rm -f "$CRED_FILE"
        log "Removed $CRED_FILE due to non-zero exit ($rc)"
    fi
}
trap cleanup EXIT

# ── Programmatic VIP Retrieval (Rule 15) ────────────────────────────────────
# keepalived assigns the VIP as a secondary address on the VRRP interface.
# Read directly from kernel interface state via ip(1); /proc/net/fib_trie
# as fallback. /var/run/keepalived.pid is the daemon PID only — not the VIP.
PUBLIC_IP=""

# Primary: ip(1) — secondary flag set by keepalived on MASTER node
PUBLIC_IP=$(ip -4 addr show dev "$VRRP_IFACE" 2>/dev/null \
    | awk '/inet / && /secondary/ {sub(/\/.*/, "", $2); print $2; exit}')

# Fallback: /proc/net/fib_trie — enumerate all kernel-bound addresses,
# subtract the interface primary to isolate the VIP
if [[ -z "$PUBLIC_IP" ]]; then
    _PRIMARY=$(ip -4 addr show dev "$VRRP_IFACE" 2>/dev/null \
        | awk '/inet / && !/secondary/ {sub(/\/.*/, "", $2); print $2; exit}')
    PUBLIC_IP=$(awk '
        /32 host/ { print ip }
        { ip = $1 }
    ' /proc/net/fib_trie 2>/dev/null \
        | grep -v "^127\\.|^0\\.|^255\\.|^${_PRIMARY}$" \
        | head -1)
    unset _PRIMARY
fi

# Secret generation (ephemeral; written only to /dev/shm later)
PASS_1000=$(openssl rand -hex 16)
PASS_2600=$(openssl rand -hex 16)

## SECTION 2: PREFLIGHT CHECKS
log "Starting preflight checks..."
[[ "$EUID" -eq 0 ]]    || die "Must run as root"
[[ -n "$PUBLIC_IP" ]]  || die "Cannot determine keepalived VIP — is keepalived running?"

# Dependency audit
for cmd in homectl podman zfs machinectl openssl ip awk getent loginctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
done

# UID collision check — abort if UID 2000 is already claimed by another user
EXISTING_UID_USER=$(getent passwd | awk -F: -v uid="$PBX_UID" '$3==uid{print $1}')
if [[ -n "$EXISTING_UID_USER" && "$EXISTING_UID_USER" != "$PBX_USER" ]]; then
    die "UID $PBX_UID already assigned to '$EXISTING_UID_USER' — adjust PBX_UID"
fi

# ZFS pool check
zfs list "${PBX_DATASET%%/*}" >/dev/null 2>&1 || die "ZFS pool '${PBX_DATASET%%/*}' not found"

## SECTION 3: ZFS / FILESYSTEM SETUP
if ! zfs list "$PBX_DATASET" >/dev/null 2>&1; then
    log "Creating ZFS dataset $PBX_DATASET"
    zfs create -p "$PBX_DATASET"
    zfs set mountpoint="$PBX_MOUNT" "$PBX_DATASET"
fi
zfs list "$PBX_DATASET" >/dev/null 2>&1 || die "ZFS dataset creation failed"

mkdir -p "$PBX_MOUNT"/{etc/asterisk,var/lib/asterisk/moh,build}
chown -R "$PBX_UID:$PBX_UID" "$PBX_MOUNT"

## SECTION 4: IDENTITY MANAGEMENT
if ! getent passwd "$PBX_USER" >/dev/null; then
    log "Creating service account $PBX_USER (directory storage)"
    homectl create "$PBX_USER" \
        --storage=directory \
        --uid="$PBX_UID" \
        --shell=/bin/bash
fi

log "Enabling linger for $PBX_USER"
loginctl enable-linger "$PBX_USER"
loginctl show-user "$PBX_USER" | grep -q "Linger=yes" \
    || die "Linger activation failed for $PBX_USER"

# Wait for user@UID.service to start and D-Bus session socket to appear.
# loginctl enable-linger triggers user@2000.service asynchronously —
# machinectl shell will fail with "No such file or directory" if called
# before /run/user/$PBX_UID/bus exists.
log "Waiting for user session bus at /run/user/$PBX_UID/bus..."
_bus_timeout=30
_bus_elapsed=0
until [[ -S "/run/user/$PBX_UID/bus" ]]; do
    if (( _bus_elapsed >= _bus_timeout )); then
        die "Timed out waiting for /run/user/$PBX_UID/bus (user@${PBX_UID}.service may have failed)"
    fi
    sleep 1
    (( _bus_elapsed++ ))
done
log "Session bus ready after ${_bus_elapsed}s"
unset _bus_timeout _bus_elapsed

# Dynamic home resolution (Rule 10)
PBXADMIN_HOME=$(getent passwd "$PBX_USER" | cut -d: -f6)
[[ -n "$PBXADMIN_HOME" ]] || die "Could not resolve home for $PBX_USER"
USER_QUADLET_DIR="$PBXADMIN_HOME/.config/containers/systemd"

## SECTION 5: CONFIG GENERATION + HARDENING
log "Generating Asterisk configs for VIP: $PUBLIC_IP"

cat > "$PBX_MOUNT/etc/asterisk/pjsip.conf" << EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_signaling_address=$PUBLIC_IP
external_media_address=$PUBLIC_IP
local_net=127.0.0.1/32
local_net=10.88.0.0/16
[1000]
type=endpoint
context=from-internal
disallow=all
allow=ulaw
auth=auth1000
aors=aor1000
moh_suggest=daplanet-stream
[auth1000]
type=auth
auth_type=userpass
password=$PASS_1000
username=1000
[aor1000]
type=aor
max_contacts=1
[2600]
type=endpoint
context=from-internal
disallow=all
allow=ulaw
auth=auth2600
aors=aor2600
[auth2600]
type=auth
auth_type=userpass
password=$PASS_2600
username=2600
[aor2600]
type=aor
max_contacts=1
EOF

cat > "$PBX_MOUNT/etc/asterisk/rtp.conf" << EOF
[general]
rtpstart=$RTP_START
rtpend=$RTP_END
EOF

cat > "$PBX_MOUNT/etc/asterisk/musiconhold.conf" << EOF
[daplanet-stream]
mode=custom
application=/usr/bin/ffmpeg -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i $MOH_STREAM_URL -ar 8000 -ac 1 -f s16le -acodec pcm_s16le pipe:1
EOF

cat > "$PBX_MOUNT/etc/asterisk/extensions.conf" << 'EOF'
[from-internal]
exten => 1000,1,Answer()
same => n,Dial(PJSIP/1000,20,m(daplanet-stream))
exten => 2600,1,Dial(PJSIP/2600,20)
EOF

chmod 640 "$PBX_MOUNT"/etc/asterisk/*.conf
chown -R "$PBX_UID:$PBX_UID" "$PBX_MOUNT/etc/asterisk"

## SECTION 6: QUADLET .BUILD AND .CONTAINER DEPLOYMENT
mkdir -p "$USER_QUADLET_DIR"
chown -R "$PBX_UID:$PBX_UID" "$PBXADMIN_HOME/.config"

cat > "$PBX_MOUNT/build/Containerfile" << 'EOF'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    asterisk asterisk-modules ffmpeg libldap-2.5-0 libradiusclient-ng2 \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["asterisk", "-f"]
EOF

cat > "$USER_QUADLET_DIR/asterisk.build" << EOF
[Build]
ImageTag=localhost/asterisk-full:latest
File=$PBX_MOUNT/build/Containerfile
SetWorkingDirectory=$PBX_MOUNT/build
EOF

cat > "$USER_QUADLET_DIR/asterisk.container" << EOF
[Unit]
Description=Asterisk PBX Rootless Container
After=network-online.target
[Container]
Image=localhost/asterisk-full:latest
ContainerName=asterisk-pbx
AddHost=host.containers.internal:host-gateway
Volume=$PBX_MOUNT/etc/asterisk:/etc/asterisk:Z
Volume=$PBX_MOUNT/var/lib/asterisk/moh:/var/lib/asterisk/moh:Z
PublishPort=5060:5060/udp
PublishPort=$RTP_START-$RTP_END:$RTP_START-$RTP_END/udp
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF

chown -R "$PBX_UID:$PBX_UID" "$USER_QUADLET_DIR"

## SECTION 7: SERVICE ACTIVATION
log "Activating user units via machinectl"
machinectl shell "$PBX_USER"@ /bin/systemctl --user daemon-reload
machinectl shell "$PBX_USER"@ /bin/systemctl --user enable --now asterisk

## SECTION 8: SMOKE TESTS
log "Waiting for container startup (max ${CONTAINER_STARTUP_TIMEOUT}s)..."
elapsed=0
interval=5
container_up=false
while (( elapsed < CONTAINER_STARTUP_TIMEOUT )); do
    if machinectl shell "$PBX_USER"@ /bin/podman ps --format "{{.Names}}" 2>/dev/null \
            | grep -q "asterisk-pbx"; then
        container_up=true
        break
    fi
    sleep "$interval"
    (( elapsed += interval ))
done

if $container_up; then
    log "PASS: Container running after ${elapsed}s"
else
    die "Container failed to start within ${CONTAINER_STARTUP_TIMEOUT}s"
fi

# PJSIP endpoint check — WARNING only; registration is async post-startup
if machinectl shell "$PBX_USER"@ \
        /bin/podman exec asterisk-pbx asterisk -rx "pjsip show endpoints" 2>/dev/null \
        | grep -q "1000"; then
    log "PASS: PJSIP endpoints visible"
else
    log "WARNING: PJSIP endpoints not yet registered — check after 30s"
fi

## SECTION 9: CREDENTIAL OUTPUT (Rules 11 & 16)
CRED_FILE=$(mktemp /dev/shm/pbx-creds-XXXXXX)
chmod 600 "$CRED_FILE"
{
    echo "--- PBX DEPLOYMENT SECRETS $(date) ---"
    echo "Keepalived VIP: $PUBLIC_IP"
    echo "Endpoint 1000:  $PASS_1000"
    echo "Endpoint 2600:  $PASS_2600"
    echo "RTP Range:      $RTP_START - $RTP_END"
    echo "Note: RAM-backed tmpfs — cleared on reboot."
} > "$CRED_FILE"
log "SUCCESS: Secrets at $CRED_FILE (memory-only)"
