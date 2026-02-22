#!/bin/bash
#
# install-luks-sddm-unlock.sh
# Installs LUKS password auto-unlock for SDDM on Fedora
#
# ⚠️ WARNING: This script is experimental and not widely tested.
# Use at your own risk. The author is not responsible for any damage.
#
# This script:
# 1. Creates a PAM module that reads the cached LUKS password
# 2. Creates a systemd service that captures the password from kernel keyring
# 3. Configures SDDM autologin
# 4. Updates PAM config for kwallet auto-unlock
#
# Usage: sudo ./install-luks-sddm-unlock.sh
#

set -e

# Auto-detect current user
SDDM_USER=$(logname 2>/dev/null || echo "$SUDO_USER" || whoami)
SDDM_SESSION="plasma"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (sudo)"
    exit 1
fi

# Show warning and require confirmation
echo ""
echo "=============================================="
echo "⚠️  WARNING: This script is experimental!"
echo "=============================================="
echo ""
echo "This script modifies PAM configuration and system services."
echo "Use at your own risk. The author is not responsible"
echo "for any damage or system breakage."
echo ""
echo "Detected user: $SDDM_USER"
echo ""
read -p "Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Check for required packages
log_info "Checking dependencies..."
if ! command -v gcc &> /dev/null; then
    log_warn "gcc not found, installing..."
    dnf install -y gcc
fi

if ! rpm -q pam-devel &> /dev/null; then
    log_warn "pam-devel not found, installing..."
    dnf install -y pam-devel
fi

# Install SELinux tools for troubleshooting
if ! rpm -q setools-console &> /dev/null; then
    log_warn "setools-console not found, installing (for troubleshooting)..."
    dnf install -y setools-console
fi

# Disable SELinux dontaudit rules temporarily to catch any hidden denials
log_info "Checking for SELinux issues..."
SEMODULE_DBDONE=false
if command -v semodule &> /dev/null; then
    semodule -DB 2>/dev/null && SEMODULE_DBDONE=true
    log_info "SELinux dontaudit rules disabled for detection"
fi

# Create PAM module source
log_info "Creating PAM module..."
mkdir -p /tmp/luks-sddm-build
cat > /tmp/luks-sddm-build/pam_luks_cached.c << 'PAMEOF'
/*
 * pam_luks_cached - PAM module that injects a cached LUKS password
 * into PAM_AUTHTOK so pam_kwallet can use it for auto-unlock.
 *
 * Reads password from /run/sddm/luks-password (created by luks-sddm-password service)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <syslog.h>
#include <security/pam_modules.h>
#include <security/pam_ext.h>

#define CRED_FILE "/run/sddm/luks-password"
#define MAX_PASS_LEN 1024

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                    int argc, const char **argv)
{
    FILE *fp;
    char password[MAX_PASS_LEN];
    char *newline;
    int ret;

    if (access(CRED_FILE, R_OK) != 0) {
        pam_syslog(pamh, LOG_DEBUG, "pam_luks_cached: no credential file");
        return PAM_AUTHINFO_UNAVAIL;
    }

    fp = fopen(CRED_FILE, "r");
    if (!fp) {
        pam_syslog(pamh, LOG_WARNING, "pam_luks_cached: cannot open %s", CRED_FILE);
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (!fgets(password, sizeof(password), fp)) {
        fclose(fp);
        return PAM_AUTHINFO_UNAVAIL;
    }
    fclose(fp);

    newline = strchr(password, '\n');
    if (newline) *newline = '\0';

    if (strlen(password) == 0) {
        memset(password, 0, sizeof(password));
        return PAM_AUTHINFO_UNAVAIL;
    }

    ret = pam_set_item(pamh, PAM_AUTHTOK, password);
    memset(password, 0, sizeof(password));

    if (ret != PAM_SUCCESS) {
        pam_syslog(pamh, LOG_ERR, "pam_luks_cached: failed to set PAM_AUTHTOK");
        return PAM_AUTHINFO_UNAVAIL;
    }

    /* Delete credential file after use */
    unlink(CRED_FILE);

    pam_syslog(pamh, LOG_INFO, "pam_luks_cached: injected cached LUKS password");
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                               int argc, const char **argv)
{
    return PAM_SUCCESS;
}
PAMEOF

# Compile PAM module
log_info "Compiling PAM module..."
gcc -shared -fPIC -o /tmp/luks-sddm-build/pam_luks_cached.so /tmp/luks-sddm-build/pam_luks_cached.c -lpam

# Install PAM module
log_info "Installing PAM module..."
cp /tmp/luks-sddm-build/pam_luks_cached.so /usr/lib64/security/pam_luks_cached.so
chmod 755 /usr/lib64/security/pam_luks_cached.so
chown root:root /usr/lib64/security/pam_luks_cached.so

# Create capture script
log_info "Creating password capture script..."
cat > /usr/lib/systemd/luks-sddm-password.sh << 'SCRIPTEOF'
#!/bin/bash
# Capture the LUKS passphrase cached in the kernel keyring by systemd-cryptsetup
# and store it for SDDM autologin + kwallet auto-unlock.

CRED_FILE="/run/sddm/luks-password"
TMP_FILE="/run/luks-password"

KEY_ID=$(keyctl search @u user cryptsetup 2>/dev/null)

if [ -z "$KEY_ID" ]; then
    echo "luks-sddm-password: No cached password in keyring" >&2
    exit 0
fi

# Ensure directories exist
mkdir -p /run/sddm
chmod 755 /run/sddm

# Write to temp file in /run (init_t can write to var_run_t)
keyctl pipe "$KEY_ID" | tr "\0" "\n" | head -1 > "$TMP_FILE"

if [ -s "$TMP_FILE" ]; then
    chmod 600 "$TMP_FILE"
    # Move to final location
    mv "$TMP_FILE" "$CRED_FILE"
    # Fix SELinux context so xdm_t can read it
    chcon -t xdm_var_run_t "$CRED_FILE" 2>/dev/null || true
    chmod 600 "$CRED_FILE"
    echo "luks-sddm-password: Stored password"
else
    rm -f "$TMP_FILE"
    echo "luks-sddm-password: Failed to read keyring" >&2
fi
SCRIPTEOF
chmod 755 /usr/lib/systemd/luks-sddm-password.sh

# Create systemd service
log_info "Creating systemd service..."
cat > /usr/lib/systemd/system/luks-sddm-password.service << 'UNITEOF'
[Unit]
Description=Forward LUKS password to SDDM credential store
DefaultDependencies=no
After=cryptsetup.target local-fs.target systemd-tmpfiles-setup.service
Before=sddm.service display-manager.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
KeyringMode=shared
ExecStart=/usr/lib/systemd/luks-sddm-password.sh
ExecStop=/bin/rm -f /run/sddm/luks-password

[Install]
WantedBy=graphical.target
UNITEOF

# Create SDDM autologin config
log_info "Configuring SDDM autologin..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << SDDMEOF
[Autologin]
User=${SDDM_USER}
Session=${SDDM_SESSION}
SDDMEOF

# Create SDDM drop-in for ordering
log_info "Creating SDDM service drop-in..."
mkdir -p /etc/systemd/system/sddm.service.d
cat > /etc/systemd/system/sddm.service.d/after-luks-password.conf << DROPINEOF
[Unit]
After=luks-sddm-password.service
Wants=luks-sddm-password.service
DROPINEOF

# Backup and modify PAM config for sddm-autologin
log_info "Configuring PAM for kwallet auto-unlock..."
if [ ! -f /etc/pam.d/sddm-autologin.bak ]; then
    cp /etc/pam.d/sddm-autologin /etc/pam.d/sddm-autologin.bak
fi

# Add pam_luks_cached before pam_kwallet in auth section
sed -i '/^auth.*required.*pam_permit.so/a # Inject cached LUKS password for kwallet auto-unlock\n-auth      optional      pam_luks_cached.so' /etc/pam.d/sddm-autologin

# Enable the service
log_info "Enabling services..."
systemctl daemon-reload
systemctl enable luks-sddm-password.service

# Re-enable SELinux dontaudit rules
if [ "$SEMODULE_DBDONE" = true ]; then
    semodule -B 2>/dev/null && log_info "SELinux dontaudit rules re-enabled"
fi

# Clean up
rm -rf /tmp/luks-sddm-build

log_info ""
log_info "Installation complete!"
log_info ""
log_info "To test immediately without reboot:"
log_info "  sudo systemctl start luks-sddm-password.service"
log_info "  ls -la /run/sddm/luks-password"
log_info ""
log_info "To check for SELinux issues after reboot:"
log_info "  journalctl -b -u luks-sddm-password.service"
log_info "  ausearch -m AVC -ts boot | grep -i sddm"
log_info ""
log_info "To revert, run:"
log_info "  sudo ./uninstall-luks-sddm-unlock.sh"
log_info ""
log_info "Reboot to test the setup."
