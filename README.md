# LUKS Password Auto-Unlock for Display Managers

Use your LUKS partition encryption password to automatically unlock SDDM/Plasma Login Manager and KDE Wallet on Fedora.

## Disclaimer - Important

**THIS SCRIPT IS NOT TESTED ON A WIDE VARIETY OF SYSTEMS. IT IS PROVIDED AS IS WITHOUT ANY WARRANTY.**

- The author is not responsible if this script breaks your system
- You use this script entirely at your own risk
- Always have a backup and know how to revert changes before running
- Review the code before executing on your machine

## What This Does

When you boot your encrypted Fedora system:
1. Plymouth asks for your LUKS password once to decrypt the root partition
2. Display manager (SDDM or Plasma Login Manager) automatically logs you in (no password needed at login screen)
3. KDE Wallet automatically unlocks using the same password
4. Your desktop appears, ready to use

You only enter your password **once** at boot, not twice.

## Requirements

- Fedora 43+ with KDE Plasma
- LUKS-encrypted root partition
- SDDM or Plasma Login Manager display manager (auto-detected)
- KDE Wallet enabled

## Installation

```bash
sudo chmod +x install-luks-dm-unlock.sh
sudo ./install-luks-dm-unlock.sh
```

The script will auto-detect:
- Your display manager (SDDM or Plasma Login Manager)
- Your username (from `SUDO_USER` or `logname`)

If you need to specify a different user or session, edit these variables near the top of the script:
- `AUTOLOGIN_USER` - username to autologin (auto-detected)
- `AUTOLOGIN_SESSION` - session to use (default: plasma)

## How It Works

1. **Kernel Keyring Cache**: When systemd-cryptsetup unlocks your LUKS partition, it caches the password in the kernel keyring (enabled by default via `password-cache=yes` in systemd)

2. **Password Capture Service**: A systemd service (`luks-dm-password.service`) runs early in boot with `KeyringMode=shared` to access the cached password, then writes it to the appropriate credential directory (`/run/sddm/luks-password` or `/run/plasmalogin/luks-password`)

3. **PAM Integration**: A custom PAM module (`pam_luks_cached.so`) reads this file during autologin and injects the password into PAM_AUTHTOK, which pam_kwallet5 uses to auto-unlock KDE Wallet

4. **Autologin**: Configured to automatically log in your user without showing the greeter

## Display Manager Support

The script automatically detects which display manager is in use:

| Display Manager | Service | Config Dir | Credential Dir |
|----------------|---------|-----------|-----------------|
| SDDM | `sddm.service` | `/etc/sddm.conf.d` | `/run/sddm` |
| Plasma Login Manager | `plasmalogin.service` | `/etc/plasmalogin.conf.d` | `/run/plasmalogin` |

Detection command:
```bash
systemctl status display-manager
# or
readlink /etc/systemd/system/display-manager.service
```

## Troubleshooting

### Check logs after reboot:
```bash
journalctl -b -u luks-dm-password.service
```

### For SDDM:
```bash
journalctl -b -t sddm-helper | grep -i 'kwallet\|luks'
ls -la /run/sddm/luks-password
```

### For Plasma Login Manager:
```bash
journalctl -b -t plasmalogin-helper | grep -i 'kwallet\|luks'
ls -la /run/plasmalogin/luks-password
```

### SELinux Issues

If KDE Wallet still asks for password, check for SELinux denials:
```bash
# Check for AVC denials
ausearch -m AVC -ts boot | grep -i 'sddm\|plasmalogin\|xdm'

# Check our specific denial (init_t trying to create file in xdm_var_run_t)
ausearch -m AVC -ts boot | grep -i "xdm_var_run\|luks-password"

# If there are denials, the script uses chcon to fix them automatically
# But if needed, manually set the context:
sudo chcon -t xdm_var_run_t /run/sddm/luks-password
# or
sudo chcon -t xdm_var_run_t /run/plasmalogin/luks-password

# For debugging, temporarily disable dontaudit rules:
sudo semodule -DB
# Then check for denials:
ausearch -m AVC -ts recent | grep -i 'sddm\|plasmalogin'
# Re-enable:
sudo semodule -B
```

### Common issues:

- **KDE Wallet still asks for password**: Check if the credential file was created:
  - SDDM: `ls -la /run/sddm/luks-password`
  - PLM: `ls -la /run/plasmalogin/luks-password`

- **SELinux denials**: The script handles SELinux contexts automatically using `chcon -t xdm_var_run_t`. If issues persist, see SELinux Issues section above.

### Revert changes:
```bash
sudo ./uninstall-luks-dm-unlock.sh
```

## Files Created

| File | Description |
|------|-------------|
| `/usr/lib/systemd/system/luks-dm-password.service` | Systemd service that captures LUKS password |
| `/usr/lib/systemd/luks-dm-password.sh` | Script that reads from kernel keyring |
| `/usr/lib64/security/pam_luks_cached.so` | PAM module that injects password |
| `/etc/sddm.conf.d/autologin.conf` or `/etc/plasmalogin.conf.d/autologin.conf` | Autologin configuration |
| `/etc/pam.d/sddm-autologin` or `/etc/pam.d/plasmalogin-autologin` | Modified PAM config for kwallet |

## Security Notes

- Credential file is on tmpfs (`/run/`), never written to disk
- File is owned by root with 600 permissions
- File is deleted after first login attempt
- Works with SELinux Enforcing (Fedora default)
- After first login, screen lock/unlock uses your normal password

## Tested On

- Fedora 43+ with KDE Plasma (Wayland)
- LUKS2 encrypted root partition
- systemd 258+
- SDDM 0.21+ or Plasma Login Manager
- KDE Wallet 6

## License

This project is licensed under the MIT License - See LICENSE file for details.