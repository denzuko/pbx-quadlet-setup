# CLAUDE.md — pbx-quadlet-setup

## Project context

This repo automates deployment of a production PBX stack for Da Planet Security (Albany, NY).
It is maintained by Den Zuko (Dwight Spencer) and reviewed with Claude (Anthropic).

## Stack

- **OS**: Ubuntu 25.10 (Questing) / systemd 257
- **Storage**: ZFS pool `storage`, dataset `storage/containers/pbx` → `/srv/pbx`
- **Identity**: POSIX `useradd`/`groupadd` — UID 2000, account `pbxadmin`
- **Containers**: Podman rootless Quadlets under `user@2000.service`
- **Image**: `pbx-stack.build` — debian:bookworm-slim + Sangoma asterisk22 + coturn + ffmpeg
- **PBX**: Asterisk 22.8.x (Sangoma official repo), `Network=host`
- **STUN/TURN**: coturn, `Network=host`, ports 3478/5349
- **TLS**: HAProxy wildcard cert (`/etc/haproxy/certs/dapla_stack.pem`) terminates on 5061
- **MOH**: ffmpeg → `https://klaxon.dapla.net` → HAProxy → icecast2:9000 (nuci3/klaxon)
- **VIP**: keepalived on `wlan0`, retrieved via `ip -4 addr show dev wlan0 | grep -oP 'inet \K[\d.]+' | head -1`
- **Firewall**: firewalld `work` zone on `wlan0` — must allow 5060/tcp+udp, 5061/tcp, 3478, 10000-10100/udp

## Key decisions

- **No homectl**: Cannot activate non-interactively. Use POSIX useradd.
- **No /etc/userdb/ drop-ins**: PID 1 user@UID.service spawning uses glibc getpwuid(), not Varlink. useradd writes /etc/passwd which every layer resolves without exception.
- **No Alpine**: Alpine's asterisk package has ABI mismatch between binary and .so modules. Use Sangoma's official debian repo.
- **No debian:trixie**: Asterisk not in trixie repos. Sangoma provides bookworm packages.
- **host networking**: SIP/RTP have poor behaviour through pasta/slirp4netns port mapping. Network=host required.
- **Image=pbx-stack.build**: Tells Quadlet to build locally before starting container. Image=localhost/... triggers a registry pull.
- **AOR names = endpoint names**: PJSIP registrar matches REGISTER Request-URI username against AOR section names. [1000]/[2600] not [aor1000]/[aor2600].
- **sorcery.conf**: Required on Sangoma asterisk22 to map PJSIP objects to flat config files. Without it, endpoints load but ignore custom values.

## Extensions

4-digit NANP format. PhreakNet prefix replaces 555 in v5.0.

| Ext  | Function |
|------|----------|
| 0    | Operator intercept → 2600 |
| 0100 | Milliwatt tone (1004 Hz, 30s) |
| 0101 | Echo test |
| 0102 | Speaking clock (America/New_York) |
| 0103 | Intercept / SIT tone + ss-noservice |
| 0200 | Open conference bridge (ConfBridge pbx-open) |
| 0201 | Private conference (ConfBridge pbx-private, random PIN) |
| 0300 | MOTD / info line |
| 0301 | Da Planet Security info |
| 1000 | MusicOnHold(daplanet-stream) — live radio via klaxon |
| 2600 | Dial(PJSIP/2600) — operator handset |

## QA standard

2026.QA.v4 — 16 rules, 27 BATS tests, ShellCheck clean at style level.
See docs/index.html for the full QA review prompt.

## v5.0 planned

- PhreakNet IAX2 trunk integration
- PhreakScript for AT&T network simulation tones
- BBS dial-in support
- GPG code signing in CI
- firewalld pbx zone automated in install script
