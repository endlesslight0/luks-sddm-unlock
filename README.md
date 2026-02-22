# LUKS Password Auto-Unlock for SDDM

Use your LUKS partition encryption password to automatically unlock SDDM and KDE Wallet on Fedora.

## ⚠️ Disclaimer - Important

**THIS SCRIPT IS NOT TESTED ON A WIDE VARIETY OF SYSTEMS. IT IS PROVIDED AS IS WITHOUT ANY WARRANTY.**

- The author is not responsible if this script breaks your system
- You use this script entirely at your own risk
- Always have a backup and know how to revert changes before running
- Review the code before executing on your machine

## What This Does

When you boot your encrypted Fedora system:
1. Plymouth asks for your LUKS password once to decrypt the root partition
2. SDDM automatically logs you in (no password needed at login screen)
3. KDE Wallet automatically unlocks using the same password
4. Your desktop appears, ready to use

You only enter your password **once** at boot, not twice.

## Requirements

- Fedora 43+ with KDE Plasma
- LUKS-encrypted root partition
- SDDM display manager
- KDE Wallet enabled

## Installation

```bash
sudo chmod +x install-luks-sddm-unlock.sh
sudo ./install-luks-sddm-unlock.sh
```

The script will auto-detect your username. If you need to specify a different user or session, edit these variables near the top of the script:
- `SDDM_USER` - username to autologin (auto-detected)
- `SDDM_SESSION` - session to use (default: plasma)

## How It Works

1. **Kernel Keyring Cache**: When systemd-cryptsetup unlocks your LUKS partition, it caches the password in the kernel keyring (enabled by default via `password-cache=yes` in systemd)

2. **Password Capture Service**: A systemd service (`luks-sddm-password.service`) runs early in boot with `KeyringMode=shared` to access the cached password, then writes it to `/run/sddm/luks-password` with the correct SELinux context

3. **PAM Integration**: A custom PAM module (`pam_luks_cached.so`) reads this file during SDDM autologin and injects the password into PAM_AUTHTOK, which pam_kwallet5 uses to auto-unlock KDE Wallet

4. **SDDM Autologin**: Configured to automatically log in your user without showing the greeter

## Troubleshooting

### Check logs after reboot:
```bash
journalctl -b -u luks-sddm-password.service
journalctl -b -t sddm-helper | grep -i 'kwallet\|luks'
```

### SELinux Issues

If KDE Wallet still asks for password, check for SELinux denials:
```bash
# Check for AVC denials
ausearch -m AVC -ts boot | grep -i sddm

# Check our specific denial (init_t trying to create file in xdm_var_run_t)
ausearch -m AVC -ts boot | grep -i "xdm_var_run\|luks-password"

# If there are denials, the script uses chcon to fix them automatically
# But if needed, manually set the context:
sudo chcon -t xdm_var_run_t /run/sddm/luks-password

# For debugging, temporarily disable dontaudit rules:
sudo semodule -DB
# Then check for denials:
ausearch -m AVC -ts recent | grep sddm
# Re-enable:
sudo semodule -B
```

### Common issues:

- **KDE Wallet still asks for password**: Check if the credential file was created: `ls -la /run/sddm/luks-password`
- **SELinux denials**: The script handles SELinux contexts automatically using `chcon -t xdm_var_run_t`. If issues persist, see SELinux Issues section above.

### Revert changes:
```bash
sudo ./uninstall-luks-sddm-unlock.sh
```

## Files Created

| File | Description |
|------|-------------|
| `/usr/lib/systemd/luks-sddm-password.service` | Systemd service that captures LUKS password |
| `/usr/lib/systemd/luks-sddm-password.sh` | Script that reads from kernel keyring |
| `/usr/lib64/security/pam_luks_cached.so` | PAM module that injects password |
| `/etc/sddm.conf.d/autologin.conf` | SDDM autologin configuration |
| `/etc/pam.d/sddm-autologin` | Modified PAM config for kwallet |

## Security Notes

- Credential file is on tmpfs (`/run/`), never written to disk
- File is owned by root with 600 permissions
- File is deleted after first login attempt
- Works with SELinux Enforcing (Fedora default)
- After first login, screen lock/unlock uses your normal password

## Tested On

- Fedora 43 with KDE Plasma (Wayland)
- LUKS2 encrypted root partition
- systemd 258
- SDDM 0.21
- KDE Wallet 6

## License

This project is licensed under the Unlicense - See LICENSE file for details.
This is public domain with no copyright restrictions.
