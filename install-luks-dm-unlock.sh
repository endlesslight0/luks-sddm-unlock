#!/bin/bash
#
# install-luks-dm-unlock.sh
# Installs LUKS password auto-unlock for SDDM / Plasma Login Manager on Fedora
#
# ⚠️ WARNING: This script is experimental and not widely tested.
# Use at your own risk. The author is not responsible for any damage.
#
# This script:
# 1. Creates a PAM module that reads the cached LUKS password
# 2. Creates a systemd service that captures the password from kernel keyring
# 3. Configures display manager autologin
# 4. Updates PAM config for kwallet auto-unlock
#
# Usage: sudo ./install-luks-dm-unlock.sh
#

set -e

# Detect active display manager
detect_display_manager() {
    if [ -L /etc/systemd/system/display-manager.service ]; then
        local dm_service=$(readlink -f /etc/systemd/system/display-manager.service)
        case "$dm_service" in
            *plasmalogin*) echo "plasmalogin" ;;
            *sddm*) echo "sddm" ;;
            *) echo "sddm" ;;
        esac
    elif systemctl is-active -q plasmalogin 2>/dev/null; then
        echo "plasmalogin"
    elif systemctl is-active -q sddm 2>/dev/null; then
        echo "sddm"
    else
        echo "sddm"
    fi
}

DISPLAY_MANAGER=$(detect_display_manager)

# Map display-manager-specific paths
case "$DISPLAY_MANAGER" in
    plasmalogin)
        DM_SERVICE="plasmalogin.service"
        PAM_SERVICE="plasmalogin-autologin"
        DM_CONF_DIR="/etc/plasmalogin.conf.d"
        DM_RUN_DIR="/run/plasmalogin"
        DM_USER="plasmalogin"
        ;;
    *)
        DM_SERVICE="sddm.service"
        PAM_SERVICE="sddm-autologin"
        DM_CONF_DIR="/etc/sddm.conf.d"
        DM_RUN_DIR="/run/sddm"
        DM_USER="sddm"
        ;;
esac

# Auto-detect current user (prefer SUDO_USER over logname; whoami would return "root" under sudo)
AUTOLOGIN_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
AUTOLOGIN_SESSION="plasma.desktop"

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

if [ -z "$AUTOLOGIN_USER" ] || [ "$AUTOLOGIN_USER" = "root" ]; then
    log_error "Could not detect a non-root user for autologin."
    log_error "Run via: sudo ./install-luks-dm-unlock.sh   (so SUDO_USER is set)"
    log_error "Or set AUTOLOGIN_USER manually at the top of this script."
    exit 1
fi

# Show warning and require confirmation
echo ""
echo "=============================================="
echo "WARNING: This script is experimental!"
echo "=============================================="
echo ""
echo "This script modifies PAM configuration and system services."
echo "Use at your own risk. The author is not responsible"
echo "for any damage or system breakage."
echo ""
echo "Detected display manager: $DISPLAY_MANAGER"
echo "Detected user: $AUTOLOGIN_USER"
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
BUILD_DIR=""
cleanup() {
    # Always re-enable dontaudit rules and remove build dir, even on failure
    if [ "$SEMODULE_DBDONE" = true ]; then
        semodule -B 2>/dev/null || true
    fi
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT
if command -v semodule &> /dev/null; then
    semodule -DB 2>/dev/null && SEMODULE_DBDONE=true
    log_info "SELinux dontaudit rules disabled for detection"
fi

# Create PAM module source - CRED_DIR is patched in via sed below
log_info "Detected display manager: $DISPLAY_MANAGER"
log_info "Creating PAM module..."
BUILD_DIR=$(mktemp -d -t luks-dm-build.XXXXXX)
cat > "$BUILD_DIR/pam_luks_cached.c" << 'PAMEOF'
/*
 * pam_luks_cached - PAM module that injects a cached LUKS password
 * into PAM_AUTHTOK so pam_kwallet can use it for auto-unlock.
 *
 * Reads password from credential file created by luks-dm-password service
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <syslog.h>
#include <security/pam_modules.h>
#include <security/pam_ext.h>

#define CRED_DIR "/run"
#define MAX_PASS_LEN 1024

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                int argc, const char **argv)
{
    FILE *fp;
    char password[MAX_PASS_LEN];
    char *newline;
    int ret;

    char cred_file[256];
    snprintf(cred_file, sizeof(cred_file), "%s/luks-password", CRED_DIR);

    if (access(cred_file, R_OK) != 0) {
        pam_syslog(pamh, LOG_DEBUG, "pam_luks_cached: no credential file");
        return PAM_AUTHINFO_UNAVAIL;
    }

    fp = fopen(cred_file, "r");
    if (!fp) {
        pam_syslog(pamh, LOG_WARNING, "pam_luks_cached: cannot open %s", cred_file);
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
    unlink(cred_file);

    pam_syslog(pamh, LOG_INFO, "pam_luks_cached: injected cached LUKS password");
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                               int argc, const char **argv)
{
    return PAM_SUCCESS;
}
PAMEOF

# Update CRED_DIR in C code based on detected display manager
sed -i "s|#define CRED_DIR \"/run\"|#define CRED_DIR \"${DM_RUN_DIR}\"|" "$BUILD_DIR/pam_luks_cached.c"

# Compile PAM module
log_info "Compiling PAM module..."
gcc -shared -fPIC -o "$BUILD_DIR/pam_luks_cached.so" "$BUILD_DIR/pam_luks_cached.c" -lpam

# Install PAM module
log_info "Installing PAM module..."
cp "$BUILD_DIR/pam_luks_cached.so" /usr/lib64/security/pam_luks_cached.so
chmod 755 /usr/lib64/security/pam_luks_cached.so
chown root:root /usr/lib64/security/pam_luks_cached.so

# Create capture script
log_info "Creating password capture script..."
cat > /usr/lib/systemd/luks-dm-password.sh << 'SCRIPTEOF'
#!/bin/bash
# Capture the LUKS passphrase cached in the kernel keyring by systemd-cryptsetup
# and store it for display manager autologin + kwallet auto-unlock.

TMP_FILE="/run/luks-password"

KEY_ID=$(keyctl search @u user cryptsetup 2>/dev/null)

if [ -z "$KEY_ID" ]; then
    echo "luks-dm-password: No cached password in keyring" >&2
    exit 0
fi

# Write to temp file in /run (init_t can write to var_run_t)
keyctl pipe "$KEY_ID" | tr "\0" "\n" | head -1 > "$TMP_FILE"

if [ -s "$TMP_FILE" ]; then
    chmod 600 "$TMP_FILE"
    CRED_FILE=""
    # Detect display manager and set credential file path
    if [ -L /etc/systemd/system/display-manager.service ]; then
        dm_service=$(readlink -f /etc/systemd/system/display-manager.service)
        case "$dm_service" in
            *plasmalogin*)
                mkdir -p /run/plasmalogin
                chmod 755 /run/plasmalogin
                CRED_FILE="/run/plasmalogin/luks-password"
                ;;
            *)
                mkdir -p /run/sddm
                chmod 755 /run/sddm
                CRED_FILE="/run/sddm/luks-password"
                ;;
        esac
    fi

    if [ -n "$CRED_FILE" ]; then
        mv "$TMP_FILE" "$CRED_FILE"
        # Fix SELinux context so xdm_t can read it
        chcon -t xdm_var_run_t "$CRED_FILE" 2>/dev/null || true
        chmod 600 "$CRED_FILE"
        echo "luks-dm-password: Stored password in $CRED_FILE"
    else
        rm -f "$TMP_FILE"
        echo "luks-dm-password: No display manager detected" >&2
    fi
else
    rm -f "$TMP_FILE"
    echo "luks-dm-password: Failed to read keyring" >&2
fi
SCRIPTEOF
chmod 755 /usr/lib/systemd/luks-dm-password.sh

# Create systemd service
log_info "Creating systemd service..."
cat > /usr/lib/systemd/system/luks-dm-password.service << UNITEOF
[Unit]
Description=Forward LUKS password to display manager credential store
DefaultDependencies=no
After=cryptsetup.target local-fs.target systemd-tmpfiles-setup.service
Before=display-manager.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
KeyringMode=shared
ExecStart=/usr/lib/systemd/luks-dm-password.sh

[Install]
WantedBy=graphical.target
UNITEOF

# Create autologin config
log_info "Configuring autologin for $DISPLAY_MANAGER..."
mkdir -p "$DM_CONF_DIR"
cat > "$DM_CONF_DIR/autologin.conf" << AUTOLOGINEOF
[Autologin]
User=${AUTOLOGIN_USER}
Session=${AUTOLOGIN_SESSION}
AUTOLOGINEOF

# Create display manager service drop-in for ordering
log_info "Creating display manager service drop-in..."
mkdir -p "/etc/systemd/system/${DM_SERVICE}.d"
cat > "/etc/systemd/system/${DM_SERVICE}.d/after-luks-password.conf" << DROPINEOF
[Unit]
After=luks-dm-password.service
Wants=luks-dm-password.service
DROPINEOF

# Backup and modify PAM config for autologin
log_info "Configuring PAM for kwallet auto-unlock..."
PAM_FILE="/etc/pam.d/${PAM_SERVICE}"
PAM_CREATED_MARKER="${PAM_FILE}.created-by-luks-dm-unlock"
if [ ! -f "$PAM_FILE" ]; then
    # Fedora 44+ ships some PAM files only in /usr/lib/pam.d/. Promote a copy
    # to /etc/pam.d/ so our edit lives in the local override layer.
    if [ -f "/usr/lib/pam.d/${PAM_SERVICE}" ]; then
        log_info "PAM file ${PAM_SERVICE} not in /etc/pam.d/; copying from /usr/lib/pam.d/"
        cp "/usr/lib/pam.d/${PAM_SERVICE}" "$PAM_FILE"
        touch "$PAM_CREATED_MARKER"
    else
        log_error "PAM file ${PAM_SERVICE} not found in /etc/pam.d/ or /usr/lib/pam.d/"
        exit 1
    fi
elif [ ! -f "${PAM_FILE}.bak" ] && [ ! -f "$PAM_CREATED_MARKER" ]; then
    # Only snapshot a .bak when there's a real pre-existing file to restore.
    # If the marker exists, install previously created this file from
    # /usr/lib/pam.d/, so the "original state" is "no local file" — no .bak.
    cp "$PAM_FILE" "${PAM_FILE}.bak"
fi

# Add pam_luks_cached in the auth section. The grep anchors on ^auth so we
# only fire the elif when the sed has a matching auth line — otherwise files
# that mention pam_kwallet only in session lines (e.g. plasmalogin-autologin
# on Fedora 44) caused the grep to match but the sed to silently do nothing.
if grep -q "pam_luks_cached" "$PAM_FILE" 2>/dev/null; then
    log_info "pam_luks_cached already present in ${PAM_SERVICE}, skipping insertion"
elif grep -q "^auth.*pam_kwallet" "$PAM_FILE" 2>/dev/null; then
    sed -i '/^auth.*pam_kwallet/i -auth      optional      pam_luks_cached.so' "$PAM_FILE"
    log_info "Inserted pam_luks_cached before auth pam_kwallet in ${PAM_SERVICE}"
elif grep -q "^auth.*required.*pam_permit.so" "$PAM_FILE" 2>/dev/null; then
    sed -i '/^auth.*required.*pam_permit.so/a -auth      optional      pam_luks_cached.so' "$PAM_FILE"
    log_info "Inserted pam_luks_cached after auth pam_permit in ${PAM_SERVICE}"
else
    log_warn "Could not find an auth pam_kwallet or pam_permit anchor in ${PAM_SERVICE}; skipping PAM edit"
    log_warn "You may need to add this line manually to ${PAM_FILE}:"
    log_warn "  -auth      optional      pam_luks_cached.so"
fi

# Enable the service
log_info "Enabling services..."
systemctl daemon-reload
systemctl enable luks-dm-password.service

# Re-enable SELinux dontaudit rules and clean up build dir (handled by trap on exit too)
if [ "$SEMODULE_DBDONE" = true ]; then
    semodule -B 2>/dev/null && log_info "SELinux dontaudit rules re-enabled"
    SEMODULE_DBDONE=false
fi

log_info ""
log_info "Installation complete!"
log_info ""
log_info "Display manager: $DISPLAY_MANAGER"
log_info ""
log_info "To test immediately without reboot:"
log_info "  sudo systemctl start luks-dm-password.service"
log_info "  ls -la ${DM_RUN_DIR}/luks-password"
log_info ""
log_info "To check for SELinux issues after reboot:"
log_info "  journalctl -b -u luks-dm-password.service"
log_info "  ausearch -m AVC -ts boot | grep -i '$DM_USER'"
log_info ""
log_info "To revert, run:"
log_info "  sudo ./uninstall-luks-dm-unlock.sh"
log_info ""
log_info "Reboot to test the setup."
