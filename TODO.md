# TODO — v5.0

## PhreakNet / IAX2 trunk integration

- [ ] Register with PhreakNet — obtain API key, CLLI code, thousand-block reservation
- [ ] Add `asterisk-phreaknet` container alongside `asterisk-pbx` (same pbx-stack image)
- [ ] Configure IAX2 trunk in `iax.conf` — PhreakNet uses IAX2 not SIP/PJSIP for inter-exchange
- [ ] Add `chan_iax2` to modules.conf
- [ ] Wire PhreakNet dial context in extensions.conf for outbound NANP routing

## PhreakScript tones

- [ ] Run `phreaknet sounds` inside Containerfile build to install PhreakNet boilerplate audio
- [ ] Install AT&T network simulation ringtones (reorder, intercept, SIT tones)
- [ ] Add `indications.conf` with North American Bellcore tone definitions
- [ ] Replace `demo-echotest` / `pbx-invalid` with authentic Bell System recordings

## BBS dial-in support

- [ ] Add modem emulation context to extensions.conf
- [ ] Route dedicated DID block to BBS context
- [ ] Evaluate `app_modem` vs external ATA bridge for data calls

## Firewalld automation

- [x] Add Section 2 preflight step to create `pbx` firewalld zone
- [x] Auto-open ports: 5060/tcp+udp, 5061/tcp, 3478/tcp+udp, 5349/tcp, 10000-10100/udp
- [x] Link `work` zone to `pbx` zone via rich rules
- [x] Add `firewall-cmd` to dependency check in preflight

## GPG code signing

- [ ] Restore GPG signing step in `.github/workflows/ci.yml` (currently commented out TODO)
- [ ] Generate and publish signing key to `signing/pubkey.asc`
- [ ] Add `pbx_setup.sh.sig` to each GitHub release asset
- [ ] Document verification steps in README

## STUN/TURN hardening

- [ ] Add coturn `min-port` / `max-port` to match RTP_START-RTP_END range
- [ ] Add coturn `denied-peer-ip` ranges for RFC1918 to prevent SSRF via TURN
- [ ] Add coturn TLS cert renewal hook (cert rotates with HAProxy acme.sh)
- [ ] Test TURN relay with Linphone on ChromeOS ARCVM

## General hardening

- [ ] Add `systemd-analyze security asterisk.service` output to CI
- [ ] ZFS encryption for `storage/containers/pbx` dataset
- [ ] Automatic credential rotation on reinstall (detect existing `/dev/shm/pbx-creds-*`)
- [ ] Add `TURN_SECRET` to sorcery.conf for res_stun_monitor authentication

## Prometheus monitoring + Grafana dashboard

- [ ] Add `asterisk-prometheus` container to pbx-stack (same golden image)
- [ ] Enable `res_prometheus` module in modules.conf
- [ ] Generate `prometheus.conf` in Section 5 with HTTP endpoint on localhost:8088
- [ ] Add HAProxy backend `prometheus` → `127.0.0.1:8088` with auth
- [ ] Add coturn Prometheus metrics endpoint (coturn supports `--prometheus-port`)
- [ ] Add pbx-stack scrape job to host Prometheus config (`/etc/prometheus/prometheus.yml`)
- [ ] Build Grafana dashboard covering:
  - Active channels / calls processed
  - SIP registration state per endpoint
  - RTP packet loss / jitter
  - MOH stream uptime (ffmpeg process alive)
  - coturn allocations / relay bandwidth
  - Asterisk module load / uptime
- [ ] Add `alerting/pbx.rules.yml` — alert on zero active transports, MOH stream down, coturn unhealthy
- [ ] Export dashboard JSON to `grafana/pbx-dashboard.json` in repo
