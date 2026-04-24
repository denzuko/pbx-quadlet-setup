# Changelog

All notable changes to pbx-quadlet-setup are documented here.

## [v4.1.25] - 2026-04-24
- Containerfile: split core sounds download into separate RUN layer (STEP 4)
- SayUnixTime format confirmed working — "at H o'clock PM" on hour is correct Bell System behavior
- Core sounds (ulaw 1.6.1) confirmed in image

## [v4.1.24] - 2026-04-24
- Fix musiconhold.conf missing [general] section — res_musiconhold silently fails without it
- Fix SayUnixTime format string to 'digits/at' IMp

## [v4.1.23] - 2026-04-24
- Implement 4-digit NANP dialplan (0/0100-0301/1000/2600)
- Add confbridge.conf with pbx-open and pbx-private bridges
- Add from-phreaknet context stub for v5.0 IAX2 prefix routing
- Add random CONF_PIN to credential output

## [v4.1.22] - 2026-04-24
- DRY firewall code into _fw_open/_fw_open_range/_fw_apply helpers
- Add ufw support
- Add pf anchor support (pbx-quadlet)

## [v4.1.21] - 2026-04-24
- firewalld automation in Section 2 preflight
- Create pbx zone, open all SIP/STUN/TURN/RTP ports
- Rich rules on work zone for wlan0

## [v4.1.20] - 2026-04-24
- Add Playback prompts for all extensions (demo-echotest, pbx-invalid, silence/1)
- Add Asterisk core sounds (ulaw) download to Containerfile
- Add extension 1010 (Echo test)
- Fix extension 1000 — MusicOnHold(daplanet-stream) not Dial(PJSIP/1000)
- Add invalid extension (i) and timeout (t) handlers

## [v4.1.19] - 2026-04-24
- SIP registration working on Zoiper and Linphone
- Fix AOR names — must match endpoint names for REGISTER URI matching ([1000]/[2600] not [aor1000]/[aor2600])
- Add identify_by=username to both endpoints
- Add sorcery.conf to map PJSIP objects to flat config files
- Fix Sangoma asterisk22 module path (/usr/lib/x86_64-linux-gnu/asterisk/modules/)
- Fix /usr/sbin/asterisk full path in Exec=
- Add missing libxslt1.1 and liburiparser1 deps to Containerfile
- Switch base image to debian:bookworm-slim + Sangoma official repo (deb.freepbx.org)
- Document firewalld work zone requirement for wlan0

## [v4.1.18] - 2026-04-24
- Publish 5060/tcp for SIP TLS via HAProxy (5061 frontend)
- Document HAProxy sips/sip frontend + pbx backend stanzas

## [v4.1.17] - 2026-04-24
- MOH stream validated — ffmpeg → HAProxy HTTPS → klaxon.dapla.net → icecast2:9000
- Fix MOH URL: http://host.containers.internal:8000 → https://klaxon.dapla.net/live.mp3

## [v4.1.16] - 2026-04-24
- Switch from Alpine 3.21 to debian:bookworm-slim (Alpine asterisk ABI mismatch)
- Generate asterisk.conf and modules.conf (Alpine/Sangoma ship no defaults)
- Add astmoddir path fix for Sangoma package layout

## [v4.1.14] - 2026-04-24
- Golden image architecture: pbx-stack.build serves both asterisk and coturn containers
- Add coturn STUN/TURN sidecar container (Network=host)
- Generate coturn.conf with static-auth-secret and TLS from HAProxy cert
- Generate stun.conf for res_stun_monitor
- Switch to host networking — resolves SIP/RTP pasta/slirp4netns issues
- Fix PJSIP NAT traversal: force_rport, rewrite_contact, rtp_symmetric, direct_media=no
- Add TURN_SECRET to credential output

## [v4.1.13] - 2026-04-23
- Fix systemd-userdbd ordering — must start before writing /etc/userdb/ files
- Fix silent die bypass — explicit if/die pattern replaces masked || die

## [v4.1.12] - 2026-04-23
- Fix loginctl enable-linger — pass UID directly; ensure userdbd running

## [v4.1.11] - 2026-04-23
- Replace homectl with /etc/userdb/ JSON drop-in provisioning (Ubuntu 25.10 / systemd 257)

## [v4.1.10] - 2026-04-23
- Fix homectl non-interactive via NEWPASSWORD env var

## [v4.1] - 2026-04-23
- Initial release
- ZFS dataset provisioning
- Podman Quadlet .build + .container units
- PJSIP config with HAProxy TLS termination
- RTP port range 10000-10100
- Keepalived VIP detection via ip(1)
- Credentials to /dev/shm via mktemp
- 27 BATS tests, ShellCheck clean
