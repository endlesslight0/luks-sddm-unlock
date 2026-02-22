#!/bin/bash
#
# uninstall-luks-sddm-unlock.sh
# Reverts the LUKS password auto-unlock for SDDM setup
#
# This script attempts to remove all changes made by install-luks-sddm-unlock.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run as root (sudo)"
    exit 1
fi

log_info "Stopping and disabling service..."
systemctl disable luks-sddm-password.service 2>/dev/null || true
systemctl daemon-reload

log_info "Removing systemd service and script..."
rm -f /usr/lib/systemd/system/luks-sddm-password.service
rm -f /usr/lib/systemd/luks-sddm-password.sh
rm -f /usr/lib64/security/pam_luks_cached.so

log_info "Removing SDDM configuration..."
rm -f /etc/sddm.conf.d/autologin.conf
rm -f /etc/systemd/system/sddm.service.d/after-luks-password.conf
rmdir /etc/systemd/system/sddm.service.d 2>/dev/null || true
rmdir /etc/sddm.conf.d 2>/dev/null || true

log_info "Restoring PAM configuration..."
if [ -f /etc/pam.d/sddm-autologin.bak ]; then
    cp /etc/pam.d/sddm-autologin.bak /etc/pam.d/sddm-autologin
    rm -f /etc/pam.d/sddm-autologin.bak
fi

log_info "Cleaning up credential files..."
rm -f /run/sddm/luks-password
rm -f /run/luks-password
rm -rf /run/credstore

systemctl daemon-reload

log_info ""
log_info "Uninstallation complete."
log_info "Reboot to apply changes."
