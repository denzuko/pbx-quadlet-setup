# pbx-quadlet-setup

Production PBX infrastructure automation for Albany/Da Planet Security stack.

**Stack:** ZFS · POSIX useradd · Podman Quadlets · Asterisk 22 (Sangoma) · HAProxy TLS · Icecast2 MOH  
**Standard:** 2026.QA.v4 · 27 BATS tests · ShellCheck clean

## Install

```bash
# Download, review, install
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh -o pbx_setup.sh
less pbx_setup.sh   # review before running
sudo bash pbx_setup.sh
```

## Prerequisites

- Ubuntu 25.10 / systemd 257
- ZFS pool named `storage`
- keepalived managing VIP on `wlan0`
- HAProxy with wildcard cert at `/etc/haproxy/certs/dapla_stack.pem`
- firewalld — script opens SIP/STUN/TURN/RTP ports in `work` zone
- Icecast2 (klaxon) reachable via `https://klaxon.dapla.net`

## Architecture

- **Identity**: POSIX `useradd`/`groupadd` — works with PID 1, logind, PAM, glibc
- **Image**: `pbx-stack.build` — single golden image (debian:bookworm-slim + Sangoma asterisk22)
  - `asterisk.container` — `Exec=/usr/sbin/asterisk -f`, `Network=host`
  - `coturn.container` — `Exec=turnserver -c /etc/coturn/coturn.conf`, `Network=host`
- **TLS**: HAProxy terminates on 5061 (SIPS), forwards plain TCP to Asterisk on 5060
- **MOH**: ffmpeg → `https://klaxon.dapla.net` → HAProxy → icecast2:9000
- **VIP**: retrieved from keepalived via `ip -4 addr show dev wlan0`
- **Credentials**: written to `/dev/shm` (tmpfs) only — never disk

## Extensions

| Ext  | Function |
|------|----------|
| 1000 | Live radio stream (MOH → klaxon/icecast2) |
| 1010 | Echo test |
| 2600 | Operator handset |

## Development

```bash
# Lint
shellcheck -S style pbx_setup.sh

# Test
bats tests/pbx_setup.bats
```

## License

MIT
