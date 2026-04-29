#!/bin/bash
#
# uninstall-luks-dm-unlock.sh
# Reverts the LUKS password auto-unlock setup
#
# This script attempts to remove all changes made by install-luks-dm-unlock.sh
# (also cleans up files from the previous install-luks-sddm-unlock.sh naming)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

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

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root (sudo)"
    exit 1
fi

DISPLAY_MANAGER=$(detect_display_manager)

# Map display-manager-specific paths
case "$DISPLAY_MANAGER" in
    plasmalogin)
        DM_SERVICE="plasmalogin.service"
        PAM_SERVICE="plasmalogin-autologin"
        DM_CONF_DIR="/etc/plasmalogin.conf.d"
        DM_RUN_DIR="/run/plasmalogin"
        ;;
    *)
        DM_SERVICE="sddm.service"
        PAM_SERVICE="sddm-autologin"
        DM_CONF_DIR="/etc/sddm.conf.d"
        DM_RUN_DIR="/run/sddm"
        ;;
esac

log_info "Detected display manager: $DISPLAY_MANAGER"
log_info "Stopping and disabling service..."
systemctl disable luks-dm-password.service 2>/dev/null || true
systemctl disable luks-sddm-password.service 2>/dev/null || true   # legacy name
systemctl daemon-reload

log_info "Removing systemd service and script..."
rm -f /usr/lib/systemd/system/luks-dm-password.service
rm -f /usr/lib/systemd/luks-dm-password.sh
rm -f /usr/lib/systemd/system/luks-sddm-password.service           # legacy name
rm -f /usr/lib/systemd/luks-sddm-password.sh                       # legacy name
rm -f /usr/lib64/security/pam_luks_cached.so

log_info "Removing autologin configuration..."
rm -f "$DM_CONF_DIR/autologin.conf"
rmdir "$DM_CONF_DIR" 2>/dev/null || true

log_info "Removing display manager service drop-in..."
rm -f "/etc/systemd/system/${DM_SERVICE}.d/after-luks-password.conf"
rmdir "/etc/systemd/system/${DM_SERVICE}.d" 2>/dev/null || true

log_info "Restoring PAM configuration..."
PAM_FILE="/etc/pam.d/${PAM_SERVICE}"
PAM_CREATED_MARKER="${PAM_FILE}.created-by-luks-dm-unlock"
if [ -f "$PAM_CREATED_MARKER" ]; then
    # Install copied this file from /usr/lib/pam.d/; remove the local override
    # so PAM falls back to the vendor file under /usr/lib/pam.d/.
    rm -f "$PAM_FILE" "$PAM_CREATED_MARKER" "${PAM_FILE}.bak"
elif [ -f "${PAM_FILE}.bak" ]; then
    cp "${PAM_FILE}.bak" "$PAM_FILE"
    rm -f "${PAM_FILE}.bak"
fi

log_info "Cleaning up credential files..."
rm -f "$DM_RUN_DIR/luks-password"
rm -f /run/sddm/luks-password
rm -f /run/plasmalogin/luks-password
rm -f /run/luks-password

systemctl daemon-reload

log_info ""
log_info "Uninstallation complete."
log_info "Reboot to apply changes."