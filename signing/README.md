# Code Signing

Script is signed with GPG (detached armored signature).

## Sign a release
```bash
gpg --armor --detach-sign --output pbx_setup.sh.sig pbx_setup.sh
gpg --export --armor YOUR_KEY_ID > signing/pubkey.asc
```

## Verify before install
```bash
gpg --import signing/pubkey.asc
gpg --verify pbx_setup.sh.sig pbx_setup.sh
```

## One-liner install with verification
```bash
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh -o pbx_setup.sh
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pbx_setup.sh.sig -o pbx_setup.sh.sig
curl -fsSL https://denzuko.github.io/pbx-quadlet-setup/pubkey.asc | gpg --import
gpg --verify pbx_setup.sh.sig pbx_setup.sh && sudo bash pbx_setup.sh
```
