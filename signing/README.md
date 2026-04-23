# Code Signing

GPG signing is planned for a future release. v4.1 ships without detached signatures.

## Install

```bash
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh -o pbx_setup.sh
less pbx_setup.sh
sudo bash pbx_setup.sh
```

## Verify via ShellCheck (recommended)

```bash
shellcheck -S style pbx_setup.sh
```

## Run BATS tests

```bash
bats tests/pbx_setup.bats
```
