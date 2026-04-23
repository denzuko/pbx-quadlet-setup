# pbx-quadlet-setup

Production PBX infrastructure automation for Albany/Sovereign Tech stack.

**Stack:** ZFS · systemd-homed · Podman Quadlets · Asterisk 20 · HAProxy TLS · Icecast2 MOH  
**Standard:** 2026.QA.v4 · 16 rules · 27 BATS tests · ShellCheck clean · GPG signed

## Install

```bash
# Verify then install
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pubkey.asc | gpg --import
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh     -o pbx_setup.sh
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh.sig -o pbx_setup.sh.sig
gpg --verify pbx_setup.sh.sig pbx_setup.sh && sudo bash pbx_setup.sh
```

## Development

```bash
# Lint
shellcheck -S style pbx_setup.sh

# Test
bats tests/pbx_setup.bats

# Sign a release
gpg --armor --detach-sign --output pbx_setup.sh.sig pbx_setup.sh
gpg --export --armor YOUR_KEY_ID > signing/pubkey.asc
```

## Architecture

- TLS terminated by HAProxy + acme.sh — Asterisk uses UDP only
- Icecast2 (klaxon/nuci3) reached via `host.containers.internal`
- Public IP retrieved from keepalived VIP at runtime
- Credentials written to `/dev/shm` (tmpfs) only — never disk

## License

MIT
