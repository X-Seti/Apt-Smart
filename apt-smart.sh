#!/bin/bash

# X-Seti September 25 - art Ubuntu/Armbian Distribution Upgrader
# Handles common conflicts during dist-upgrade operations
# Version: 1.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/smart-upgrade-$(date +%Y%m%d-%H%M%S).log"

log_message() {
    echo -e "${2}${1}${NC}" | tee -a "$LOG_FILE"
}

print_header() {
    echo ""
    log_message "================================================" "$BLUE"
    log_message "$1" "$BLUE"
    log_message "================================================" "$BLUE"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_message "ERROR: This script must be run as root (use sudo)" "$RED"
        exit 1
    fi
}

backup_sources() {
    print_header "Backing up APT sources"
    
    if [ ! -d /etc/apt/sources.list.backup ]; then
        mkdir -p /etc/apt/sources.list.backup
    fi
    
    BACKUP_DIR="/etc/apt/sources.list.backup/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null || true
    
    log_message "✓ Backed up to: $BACKUP_DIR" "$GREEN"
}

pre_upgrade_checks() {
    print_header "Pre-Upgrade System Checks"
    
    # Check disk space
    AVAILABLE_SPACE=$(df / | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=5000000 # 5GB in KB
    
    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        log_message "WARNING: Low disk space. Available: $((AVAILABLE_SPACE/1024))MB, Recommended: 5GB+" "$YELLOW"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_message "Disk space check passed: $((AVAILABLE_SPACE/1024/1024))GB available" "$GREEN"
    fi
    
    # Check current version
    CURRENT_VERSION=$(lsb_release -cs)
    log_message "Current distribution: $CURRENT_VERSION" "$BLUE"
    
    # Check for running package managers
    if pgrep -x "apt" > /dev/null || pgrep -x "apt-get" > /dev/null || pgrep -x "dpkg" > /dev/null; then
        log_message "ERROR: Another package manager is running. Please wait for it to finish." "$RED"
        exit 1
    fi
    
    log_message "No conflicting package managers running" "$GREEN"
}

update_package_lists() {
    print_header "Updating Package Lists"
    
    apt update 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_message "Package lists updated successfully" "$GREEN"
    else
        log_message "WARNING: Some repositories may have issues" "$YELLOW"
    fi
}

handle_broken_packages() {
    print_header "Checking for Broken Packages"
    
    BROKEN_COUNT=$(dpkg -l | grep -c "^iU" 2>/dev/null || echo "0")
    
    if [ "$BROKEN_COUNT" -gt 0 ]; then
        log_message "Found $BROKEN_COUNT broken packages. Attempting to fix..." "$YELLOW"
        
        apt --fix-broken install -y 2>&1 | tee -a "$LOG_FILE"
        
        log_message "Fixed broken packages" "$GREEN"
    else
        log_message "No broken packages found" "$GREEN"
    fi
}

smart_upgrade() {
    print_header "Starting Smart Upgrade Process"
    
    # Common conflict patterns
    declare -A CONFLICT_PATTERNS=(
        ["KDE5-to-KDE6"]="libkf5|libkf6|libkpim5|plasma-|kwin"
        ["Qt5-to-Qt6"]="libqt5|libqt6|qt5-|qt6-"
        ["wx-widgets"]="libwx|wxwidgets"
    )
    
    log_message "Attempting upgrade with conflict resolution..." "$BLUE"
    
    # Try normal upgrade first
    if apt full-upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Upgrade completed successfully" "$GREEN"
        return 0
    fi
    
    log_message "Normal upgrade failed. Analyzing conflicts..." "$YELLOW"
    
    # Check for file overwrite conflicts
    if grep -q "trying to overwrite" "$LOG_FILE"; then
        log_message "Detected file overwrite conflicts. Applying force-overwrite..." "$YELLOW"
        
        apt -o Dpkg::Options::="--force-overwrite" full-upgrade -y 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            log_message "✓ Upgrade completed with conflict resolution" "$GREEN"
            return 0
        fi
    fi
    
    # Check for dependency issues
    if grep -q "Unmet dependencies" "$LOG_FILE" || grep -q "Depends:" "$LOG_FILE"; then
        log_message "Detected dependency issues. Attempting automated resolution..." "$YELLOW"
        
        # Try to fix broken installs
        apt --fix-broken install -y 2>&1 | tee -a "$LOG_FILE"
        
        # Try upgrade again
        apt -o Dpkg::Options::="--force-overwrite" full-upgrade -y 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            log_message "✓ Upgrade completed after dependency resolution" "$GREEN"
            return 0
        fi
    fi
    
    log_message "ERROR: Upgrade failed. Manual intervention may be required." "$RED"
    log_message "Check log file: $LOG_FILE" "$YELLOW"
    return 1
}

handle_problematic_packages() {
    print_header "Handling Known Problematic Packages"
    
    # List of packages that commonly cause issues during upgrades
    PROBLEMATIC_PACKAGES=(
        "libqt5webengine5"
        "libqt5webenginecore5"
        "libqt5webenginewidgets5"
        "python3-pyqt5.qtwebengine"
        "libalien-wxwidgets-perl"
        "libwx-perl-datawalker-perl"
        "libwx-perl-processstream-perl"
    )
    
    FOUND_PROBLEMATIC=0
    
    for pkg in "${PROBLEMATIC_PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg"; then
            log_message "Found problematic package: $pkg" "$YELLOW"
            FOUND_PROBLEMATIC=1
        fi
    done
    
    if [ $FOUND_PROBLEMATIC -eq 1 ]; then
        read -p "Remove problematic packages to continue upgrade? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            apt remove -y "${PROBLEMATIC_PACKAGES[@]}" 2>&1 | tee -a "$LOG_FILE" || true
            apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
            log_message "Removed problematic packages" "$GREEN"
        fi
    else
        log_message "No known problematic packages found" "$GREEN"
    fi
}

post_upgrade_cleanup() {
    print_header "Post-Upgrade Cleanup"
    
    log_message "Removing unnecessary packages..." "$BLUE"
    apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Cleaning package cache..." "$BLUE"
    apt autoclean 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Cleanup completed" "$GREEN"
}

verify_system() {
    print_header "System Verification"
    
    # Check for broken packages
    BROKEN=$(dpkg -l | grep -c "^iU" 2>/dev/null || echo "0")
    if [ "$BROKEN" -gt 0 ]; then
        log_message "WARNING: $BROKEN broken packages remain" "$YELLOW"
    else
        log_message "No broken packages" "$GREEN"
    fi
    
    # Check dependencies
    if apt check 2>&1 | grep -q "0 not"; then
        log_message "All dependencies satisfied" "$GREEN"
    else
        log_message "WARNING: Some dependency issues remain" "$YELLOW"
        apt check 2>&1 | tee -a "$LOG_FILE"
    fi
    
    # Show new version
    NEW_VERSION=$(lsb_release -cs)
    log_message "Current distribution: $NEW_VERSION" "$BLUE"
    
    # Check kernel
    CURRENT_KERNEL=$(uname -r)
    INSTALLED_KERNELS=$(dpkg -l | grep "linux-image-" | grep "^ii" | wc -l)
    log_message "Current kernel: $CURRENT_KERNEL" "$BLUE"
    log_message "Installed kernels: $INSTALLED_KERNELS" "$BLUE"
}

pre_reboot_checks() {
    print_header "Pre-Reboot Verification"
    
    log_message "Checking bootloader..." "$BLUE"
    update-grub 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Checking initramfs..." "$BLUE"
    KERNEL_COUNT=$(ls /boot/initrd.img-* 2>/dev/null | wc -l)
    log_message "Found $KERNEL_COUNT initramfs images" "$BLUE"
    
    # Check critical services
    log_message "Checking critical services..." "$BLUE"
    
    SERVICES=("NetworkManager" "sddm" "systemd-logind")
    for service in "${SERVICES[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            log_message "  ✓ $service is enabled" "$GREEN"
        else
            log_message "  ⚠ $service is not enabled" "$YELLOW"
        fi
    done
}

main() {
    clear
    log_message "╔════════════════════════════════════════════════╗" "$BLUE"
    log_message "║   Smart Ubuntu/Armbian Distribution Upgrader  ║" "$BLUE"
    log_message "╚════════════════════════════════════════════════╝" "$BLUE"
    echo ""
    
    check_root
    
    log_message "Log file: $LOG_FILE" "$BLUE"
    echo ""
    
    read -p "Continue with upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_message "Upgrade cancelled by user" "$YELLOW"
        exit 0
    fi
    
    backup_sources
    pre_upgrade_checks
    update_package_lists
    handle_broken_packages
    handle_problematic_packages
    smart_upgrade
    
    if [ $? -eq 0 ]; then
        post_upgrade_cleanup
        verify_system
        pre_reboot_checks
        
        echo ""
        log_message "╔════════════════════════════════════════════════╗" "$GREEN"
        log_message "║        Upgrade Process Completed!              ║" "$GREEN"
        log_message "╚════════════════════════════════════════════════╝" "$GREEN"
        echo ""
        log_message "Full log saved to: $LOG_FILE" "$BLUE"
        echo ""
        
        read -p "Reboot now? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_message "Rebooting system..." "$GREEN"
            reboot
        else
            log_message "Please reboot manually to complete the upgrade." "$YELLOW"
        fi
    else
        log_message "Upgrade encountered errors. Check log: $LOG_FILE" "$RED"
        exit 1
    fi
}

# Run main function
main "$@"
