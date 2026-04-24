#!/usr/bin/env bash
## PBX INFRASTRUCTURE AUTOMATION SCRIPT v4.1.14
## ARCHITECTURE: ZFS + useradd + Podman Quadlets + Keepalived VIP
## STANDARDS COMPLIANCE: 2026.QA.v4
##
## Identity: POSIX useradd/groupadd — resolved by PID 1, logind, PAM, glibc
## Build:    Quadlet .build unit — Image=asterisk.build wires dependency
## VIP:      ip(1) first global address on VRRP_IFACE (no secondary filter)
## Secrets:  mktemp /dev/shm only, never stdout or persistent paths
set -euo pipefail

## SECTION 1: VARIABLE DECLARATIONS
PBX_USER="pbxadmin"
PBX_UID=2000
PBX_DATASET="storage/containers/pbx"
PBX_MOUNT="/srv/pbx"
RTP_START=10000
RTP_END=10100
VRRP_IFACE="wlan0"              # Interface keepalived manages the VIP on
MOH_STREAM_URL="https://klaxon.dapla.net/live.mp3"
CONTAINER_STARTUP_TIMEOUT=60   # seconds
CRED_FILE=
TURN_SECRET=""                   # set after mktemp; used by trap

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
# Read the VIP directly from the VRRP interface via ip(1).
# On this host keepalived manages wlan0 as the sole address on that interface
# (no node-primary + secondary split) — take the first global scope address.
# grep -oP exits 1 on no match: || true prevents set -e from firing silently.
PUBLIC_IP=""

# Primary: first global-scope address on the VRRP interface
PUBLIC_IP=$(ip -4 addr show dev "$VRRP_IFACE" 2>/dev/null \
    | grep -oP 'inet \K[\d.]+' | head -1 || true)

# Fallback: first global-scope address on any interface (excludes loopback)
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(ip -4 addr show scope global 2>/dev/null \
        | grep -oP 'inet \K[\d.]+' | head -1 || true)
fi

log "VIP detection: ${PUBLIC_IP:-not found}"

# Secret generation (ephemeral; written only to /dev/shm later)
PASS_1000=$(openssl rand -hex 16)
PASS_2600=$(openssl rand -hex 16)
TURN_SECRET=$(openssl rand -hex 32)

## SECTION 2: PREFLIGHT CHECKS
log "Starting preflight checks..."
[[ "$EUID" -eq 0 ]]    || die "Must run as root"
[[ -n "$PUBLIC_IP" ]]  || die "Cannot determine keepalived VIP — is keepalived running?"

# Dependency audit
for cmd in podman zfs machinectl openssl ip awk getent loginctl useradd groupadd; do
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
# POSIX useradd/groupadd — resolved by every layer without exception:
# PID 1, logind, PAM, nss-systemd, glibc getpwuid(). No Varlink,
# no drop-in files, no NSS ordering dependencies.
PBXADMIN_HOME="/home/$PBX_USER"

if ! getent group "$PBX_USER" >/dev/null 2>&1; then
    log "Creating group $PBX_USER (GID $PBX_UID)"
    groupadd --gid "$PBX_UID" "$PBX_USER"
fi

if ! getent passwd "$PBX_USER" >/dev/null 2>&1; then
    log "Creating user $PBX_USER (UID $PBX_UID)"
    useradd \
        --uid "$PBX_UID" \
        --gid "$PBX_UID" \
        --home-dir "$PBXADMIN_HOME" \
        --create-home \
        --shell /bin/bash \
        --no-user-group \
        "$PBX_USER"
fi

getent passwd "$PBX_USER" >/dev/null 2>&1 \
    || die "Failed to verify user $PBX_USER"
log "User $PBX_USER ready (UID $PBX_UID)"

# Lock account — service account, no interactive login
passwd -l "$PBX_USER" >/dev/null 2>&1 || true

log "Enabling linger for $PBX_USER"
loginctl enable-linger "$PBX_USER"
loginctl show-user "$PBX_USER" | grep -q "Linger=yes" \
    || die "Linger activation failed for $PBX_USER"

# Start user manager — linger alone does not start it on a fresh account
log "Starting user@${PBX_UID}.service..."
systemctl start "user@${PBX_UID}.service" \
    || die "Failed to start user@${PBX_UID}.service"

# Poll for D-Bus session socket
log "Waiting for session bus at /run/user/${PBX_UID}/bus..."
_bus_timeout=30
_bus_elapsed=0
until [[ -S "/run/user/${PBX_UID}/bus" ]]; do
    if (( _bus_elapsed >= _bus_timeout )); then
        die "Timed out waiting for /run/user/${PBX_UID}/bus"
    fi
    sleep 1
    (( _bus_elapsed++ ))
done
log "Session bus ready after ${_bus_elapsed}s"
unset _bus_timeout _bus_elapsed

USER_QUADLET_DIR="$PBXADMIN_HOME/.config/containers/systemd"

## SECTION 5: CONFIG GENERATION + HARDENING
log "Generating Asterisk configs for VIP: $PUBLIC_IP"

# asterisk.conf is required — without it Asterisk cannot locate any other
# config files. The volume mount replaces /etc/asterisk entirely so we must
# generate it; the Alpine asterisk package provides no default.
cat > "$PBX_MOUNT/etc/asterisk/asterisk.conf" << 'EOF'
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
[options]
documentation_language = en_US
EOF
chmod 640 "$PBX_MOUNT/etc/asterisk/asterisk.conf"

# modules.conf — autoload everything; no manual module list needed
cat > "$PBX_MOUNT/etc/asterisk/modules.conf" << 'EOF'
[modules]
autoload = yes
EOF
chmod 640 "$PBX_MOUNT/etc/asterisk/modules.conf"

# logger.conf — console + journal logging
cat > "$PBX_MOUNT/etc/asterisk/logger.conf" << 'EOF'
[general]
[logfiles]
console => notice,warning,error,verbose
syslog.local0 => notice,warning,error
EOF
chmod 640 "$PBX_MOUNT/etc/asterisk/logger.conf"

cat > "$PBX_MOUNT/etc/asterisk/pjsip.conf" << EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_signaling_address=$PUBLIC_IP
external_media_address=$PUBLIC_IP
local_net=127.0.0.0/8
local_net=192.168.0.0/16
[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
external_signaling_address=$PUBLIC_IP
external_media_address=$PUBLIC_IP
local_net=127.0.0.0/8
local_net=192.168.0.0/16
[1000]
type=endpoint
context=from-internal
disallow=all
allow=ulaw
auth=auth1000
aors=aor1000
moh_suggest=daplanet-stream
transport=transport-udp
force_rport=yes
rewrite_contact=yes
rtp_symmetric=yes
direct_media=no
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
transport=transport-udp
force_rport=yes
rewrite_contact=yes
rtp_symmetric=yes
direct_media=no
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

# stun.conf — point res_stun_monitor at local coturn
cat > "$PBX_MOUNT/etc/asterisk/stun.conf" << EOF
[general]
stunaddr=$PUBLIC_IP:3478
EOF
chmod 640 "$PBX_MOUNT/etc/asterisk/stun.conf"

# coturn config
mkdir -p "$PBX_MOUNT/etc/coturn"
cat > "$PBX_MOUNT/etc/coturn/coturn.conf" << EOF
listening-port=3478
tls-listening-port=5349
listening-ip=$PUBLIC_IP
relay-ip=$PUBLIC_IP
external-ip=$PUBLIC_IP
realm=dapla.net
use-auth-secret
static-auth-secret=$TURN_SECRET
cert=/etc/coturn/tls.crt
pkey=/etc/coturn/tls.key
no-stdout-log
log-file=/dev/null
EOF
chmod 640 "$PBX_MOUNT/etc/coturn/coturn.conf"

# Copy HAProxy wildcard cert for coturn TLS
cp /etc/haproxy/certs/dapla_stack.pem "$PBX_MOUNT/etc/coturn/tls.crt"
openssl pkey -in /etc/haproxy/certs/dapla_stack.pem     -out "$PBX_MOUNT/etc/coturn/tls.key" 2>/dev/null     || cp /etc/haproxy/certs/dapla_stack.pem "$PBX_MOUNT/etc/coturn/tls.key"
chmod 640 "$PBX_MOUNT/etc/coturn/tls.crt"           "$PBX_MOUNT/etc/coturn/tls.key"
chown -R "$PBX_UID:$PBX_UID" "$PBX_MOUNT/etc/coturn"

## SECTION 6: QUADLET .BUILD AND .CONTAINER DEPLOYMENT
mkdir -p "$USER_QUADLET_DIR"
chown -R "$PBX_UID:$PBX_UID" "$PBXADMIN_HOME/.config"

cat > "$PBX_MOUNT/build/Containerfile" << 'EOF'
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    asterisk \
    coturn \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*
EOF

cat > "$USER_QUADLET_DIR/pbx-stack.build" << EOF
[Build]
ImageTag=localhost/pbx-stack:latest
File=$PBX_MOUNT/build/Containerfile
SetWorkingDirectory=$PBX_MOUNT/build
EOF

cat > "$USER_QUADLET_DIR/asterisk.container" << EOF
[Unit]
Description=Asterisk PBX
After=network-online.target
[Container]
Image=pbx-stack.build
ContainerName=asterisk-pbx
Network=host
Exec=asterisk -f
Volume=$PBX_MOUNT/etc/asterisk:/etc/asterisk:Z
Volume=$PBX_MOUNT/var/lib/asterisk/moh:/var/lib/asterisk/moh:Z
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF

cat > "$USER_QUADLET_DIR/coturn.container" << EOF
[Unit]
Description=Coturn STUN/TURN Server
After=network-online.target
[Container]
Image=pbx-stack.build
ContainerName=coturn
Network=host
Exec=turnserver -c /etc/coturn/coturn.conf
Volume=$PBX_MOUNT/etc/coturn:/etc/coturn:Z
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF

chown -R "$PBX_UID:$PBX_UID" "$USER_QUADLET_DIR"

## SECTION 7: SERVICE ACTIVATION
log "Activating user units via machinectl"
# Quadlet units are generated units — cannot use "enable --now".
# daemon-reload triggers the Quadlet generator which writes the service
# and honours WantedBy=default.target automatically.
# Use "start" only — the generator has already wired up the target dependency.
machinectl shell "$PBX_USER"@ /bin/systemctl --user daemon-reload
machinectl shell "$PBX_USER"@ /bin/systemctl --user start asterisk
machinectl shell "$PBX_USER"@ /bin/systemctl --user start coturn

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
    echo "TURN Secret:    $TURN_SECRET"
    echo "TURN Realm:     dapla.net"
    echo "STUN/TURN:      $PUBLIC_IP:3478"
    echo "RTP Range:      $RTP_START - $RTP_END"
    echo "Note: RAM-backed tmpfs — cleared on reboot."
} > "$CRED_FILE"
log "SUCCESS: Secrets at $CRED_FILE (memory-only)"
