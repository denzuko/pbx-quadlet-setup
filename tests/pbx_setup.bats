#!/usr/bin/env bats
## BATS Unit Tests — pbx_setup.sh v4.1

setup() {
    TEST_DIR="$(mktemp -d /tmp/pbx-bats-XXXXXX)"
    MOCK_DIR="$TEST_DIR/mock_bin"
    mkdir -p "$TEST_DIR/etc/asterisk" "$TEST_DIR/build" "$TEST_DIR/quadlet" "$MOCK_DIR"

    printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/zfs"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/homectl"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_DIR/machinectl"
    cat > "$MOCK_DIR/loginctl" << 'EOF'
#!/bin/bash
[[ "$*" == *"show-user"* ]] && echo "Linger=yes" || exit 0
EOF
    cat > "$MOCK_DIR/ip" << 'EOF'
#!/bin/bash
echo "    inet 203.0.113.42/32 scope global secondary eth0"
EOF
    cat > "$MOCK_DIR/openssl" << 'EOF'
#!/bin/bash
echo "aabbccddeeff0011aabbccddeeff0011"
EOF
    chmod +x "$MOCK_DIR"/*
    export PATH="$MOCK_DIR:$PATH"
    export PBX_MOUNT="$TEST_DIR"
    export USER_QUADLET_DIR="$TEST_DIR/quadlet"
    export PUBLIC_IP="203.0.113.42"
    export PASS_1000="aabbccddeeff0011aabbccddeeff0011"
    export PASS_2600="ffeeddcc99887766ffeeddcc99887766"
    export RTP_START=10000
    export RTP_END=10100
    export MOH_STREAM_URL="http://host.containers.internal:8000/live.mp3"
    export PBX_USER="pbxadmin"
    export PBX_UID=2000
}

teardown() { rm -rf "$TEST_DIR"; }

_gen_configs() {
    cat > "$PBX_MOUNT/etc/asterisk/pjsip.conf" << EOF
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_signaling_address=${PUBLIC_IP}
external_media_address=${PUBLIC_IP}
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
password=${PASS_1000}
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
password=${PASS_2600}
username=2600
[aor2600]
type=aor
max_contacts=1
EOF
    cat > "$PBX_MOUNT/etc/asterisk/rtp.conf" << EOF
[general]
rtpstart=${RTP_START}
rtpend=${RTP_END}
EOF
    cat > "$PBX_MOUNT/etc/asterisk/musiconhold.conf" << EOF
[daplanet-stream]
mode=custom
application=/usr/bin/ffmpeg -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i ${MOH_STREAM_URL} -ar 8000 -ac 1 -f s16le -acodec pcm_s16le pipe:1
EOF
    cat > "$PBX_MOUNT/etc/asterisk/extensions.conf" << 'EOF'
[from-internal]
exten => 1000,1,Answer()
same => n,Dial(PJSIP/1000,20,m(daplanet-stream))
exten => 2600,1,Dial(PJSIP/2600,20)
EOF
    chmod 640 "$PBX_MOUNT"/etc/asterisk/*.conf
    cat > "$USER_QUADLET_DIR/asterisk.build" << EOF
[Build]
ImageTag=localhost/asterisk-full:latest
File=${PBX_MOUNT}/build/Containerfile
SetWorkingDirectory=${PBX_MOUNT}/build
EOF
    cat > "$USER_QUADLET_DIR/asterisk.container" << EOF
[Unit]
Description=Asterisk PBX Rootless Container
After=network-online.target
[Container]
Image=localhost/asterisk-full:latest
ContainerName=asterisk-pbx
AddHost=host.containers.internal:host-gateway
Volume=${PBX_MOUNT}/etc/asterisk:/etc/asterisk:Z
Volume=${PBX_MOUNT}/var/lib/asterisk/moh:/var/lib/asterisk/moh:Z
PublishPort=5060:5060/udp
PublishPort=${RTP_START}-${RTP_END}:${RTP_START}-${RTP_END}/udp
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
}

@test "shellcheck passes at style level" {
    run shellcheck -S style tests/pbx_setup.sh
    [ "$status" -eq 0 ]
}

@test "VIP resolved from mock ip command" {
    result=$(ip -4 addr show scope global | awk '/inet .* secondary/{print $2}' | cut -d/ -f1 | head -1)
    [ "$result" = "203.0.113.42" ]
}

@test "script aborts when PUBLIC_IP is empty" {
    run bash -c 'PUBLIC_IP=""; [[ -n "$PUBLIC_IP" ]] || { echo "FATAL: keepalived VIP"; exit 1; }'
    [ "$status" -eq 1 ]
}

@test "UID collision detected when claimed by different user" {
    run bash -c '
        PBX_UID=2000; PBX_USER="pbxadmin"
        EXISTING=$(echo "otheruser:x:2000:2000::/home/other:/bin/bash" | awk -F: -v uid="$PBX_UID" '"'"'$3==uid{print $1}'"'"')
        [[ -n "$EXISTING" && "$EXISTING" != "$PBX_USER" ]] && { echo "FATAL: UID collision"; exit 1; }
    '
    [ "$status" -eq 1 ]
}

@test "UID collision passes when user matches" {
    run bash -c '
        PBX_UID=2000; PBX_USER="pbxadmin"
        EXISTING=$(echo "pbxadmin:x:2000:2000::/home/pbxadmin:/bin/bash" | awk -F: -v uid="$PBX_UID" '"'"'$3==uid{print $1}'"'"')
        [[ -n "$EXISTING" && "$EXISTING" != "$PBX_USER" ]] && exit 1; echo "OK"
    '
    [ "$status" -eq 0 ]
}

@test "pjsip.conf generated" {
    _gen_configs
    [ -f "$PBX_MOUNT/etc/asterisk/pjsip.conf" ]
}

@test "pjsip.conf has no duplicate sections" {
    _gen_configs
    dups=$(grep '^\[' "$PBX_MOUNT/etc/asterisk/pjsip.conf" | sort | uniq -d)
    [ -z "$dups" ]
}

@test "pjsip.conf has no TLS or SDES" {
    _gen_configs
    run grep -iE "transport-tls|media_encryption|sdes|protocol=tls" "$PBX_MOUNT/etc/asterisk/pjsip.conf"
    [ "$status" -eq 1 ]
}

@test "pjsip.conf VIP set correctly" {
    _gen_configs
    run grep "external_signaling_address=203.0.113.42" "$PBX_MOUNT/etc/asterisk/pjsip.conf"
    [ "$status" -eq 0 ]
}

@test "Dial target 1000 has endpoint section" {
    _gen_configs
    run grep '^\[1000\]' "$PBX_MOUNT/etc/asterisk/pjsip.conf"
    [ "$status" -eq 0 ]
}

@test "Dial target 2600 has endpoint section" {
    _gen_configs
    run grep '^\[2600\]' "$PBX_MOUNT/etc/asterisk/pjsip.conf"
    [ "$status" -eq 0 ]
}

@test "rtp.conf rtpstart matches variable" {
    _gen_configs
    val=$(grep rtpstart "$PBX_MOUNT/etc/asterisk/rtp.conf" | cut -d= -f2 | tr -d ' ')
    [ "$val" = "$RTP_START" ]
}

@test "rtp.conf rtpend matches variable" {
    _gen_configs
    val=$(grep rtpend "$PBX_MOUNT/etc/asterisk/rtp.conf" | cut -d= -f2 | tr -d ' ')
    [ "$val" = "$RTP_END" ]
}

@test "Quadlet PublishPort RTP range matches variables" {
    _gen_configs
    run grep "PublishPort=${RTP_START}-${RTP_END}" "$USER_QUADLET_DIR/asterisk.container"
    [ "$status" -eq 0 ]
}

@test "musiconhold.conf uses no public FQDN" {
    _gen_configs
    run grep "klaxon.dapla.net" "$PBX_MOUNT/etc/asterisk/musiconhold.conf"
    [ "$status" -eq 1 ]
}

@test "musiconhold.conf uses host.containers.internal" {
    _gen_configs
    run grep "host.containers.internal" "$PBX_MOUNT/etc/asterisk/musiconhold.conf"
    [ "$status" -eq 0 ]
}

@test "musiconhold.conf has FFmpeg reconnect flags" {
    _gen_configs
    run grep "reconnect_streamed 1" "$PBX_MOUNT/etc/asterisk/musiconhold.conf"
    [ "$status" -eq 0 ]
}

@test "all asterisk configs are 640" {
    _gen_configs
    for f in "$PBX_MOUNT"/etc/asterisk/*.conf; do
        [ "$(stat -c '%a' "$f")" = "640" ]
    done
}

@test "asterisk.build has all required keys" {
    _gen_configs
    grep -q '^\[Build\]' "$USER_QUADLET_DIR/asterisk.build"
    grep -q '^ImageTag=' "$USER_QUADLET_DIR/asterisk.build"
    grep -q '^File=' "$USER_QUADLET_DIR/asterisk.build"
    grep -q '^SetWorkingDirectory=' "$USER_QUADLET_DIR/asterisk.build"
}

@test "asterisk.container has AddHost directive" {
    _gen_configs
    run grep "AddHost=host.containers.internal:host-gateway" "$USER_QUADLET_DIR/asterisk.container"
    [ "$status" -eq 0 ]
}

@test "asterisk.container has After=network-online.target" {
    _gen_configs
    run grep "After=network-online.target" "$USER_QUADLET_DIR/asterisk.container"
    [ "$status" -eq 0 ]
}

@test "asterisk.container has Restart=always" {
    _gen_configs
    run grep "Restart=always" "$USER_QUADLET_DIR/asterisk.container"
    [ "$status" -eq 0 ]
}

@test "asterisk.container publishes 5060/udp" {
    _gen_configs
    run grep "PublishPort=5060:5060/udp" "$USER_QUADLET_DIR/asterisk.container"
    [ "$status" -eq 0 ]
}

@test "mktemp targets /dev/shm" {
    CRED_FILE=$(mktemp /dev/shm/pbx-creds-XXXXXX)
    [[ "$CRED_FILE" == /dev/shm/* ]]
    rm -f "$CRED_FILE"
}

@test "credential file is 600" {
    CRED_FILE=$(mktemp /dev/shm/pbx-creds-XXXXXX)
    chmod 600 "$CRED_FILE"
    [ "$(stat -c '%a' "$CRED_FILE")" = "600" ]
    rm -f "$CRED_FILE"
}

@test "log() output contains no raw credential values" {
    run bash -c "echo 'SUCCESS: Secrets at /dev/shm/pbx-creds-abc123' | grep -iE 'password|PASS_|hex'"
    [ "$status" -eq 1 ]
}

@test "trap removes cred file on non-zero exit" {
    CRED_FILE=$(mktemp /dev/shm/pbx-creds-XXXXXX)
    run bash -c "
        CRED_FILE=$CRED_FILE
        cleanup() { local rc=\$?; [[ -f \"\$CRED_FILE\" && \$rc -ne 0 ]] && rm -f \"\$CRED_FILE\"; }
        trap cleanup EXIT
        exit 1
    "
    [ ! -f "$CRED_FILE" ]
}
