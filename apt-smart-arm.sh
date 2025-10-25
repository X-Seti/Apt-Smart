#!/bin/bash

# X-Seti September 25 - Smart Armbian Distribution Upgrader
# Enhanced version with SBC-specific checks (Orange Pi, Rock Pi, etc.)
# Version: 1.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging
LOG_FILE="/var/log/armbian-smart-upgrade-$(date +%Y%m%d-%H%M%S).log"
HARDWARE_LOG="/var/log/hardware-check-$(date +%Y%m%d-%H%M%S).log"

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

detect_hardware() {
    print_header "Detecting Hardware Configuration"
    
    # Detect SoC
    if [ -f /proc/device-tree/model ]; then
        BOARD_MODEL=$(cat /proc/device-tree/model | tr -d '\0')
        log_message "Board: $BOARD_MODEL" "$BLUE"
    else
        BOARD_MODEL="Unknown"
        log_message "Board: Unknown (not ARM device tree)" "$YELLOW"
    fi
    
    # Detect SoC type
    if grep -q "rk3588" /proc/device-tree/compatible 2>/dev/null; then
        SOC_TYPE="RK3588"
        GPU_TYPE="Mali-G610"
    elif grep -q "rk3399" /proc/device-tree/compatible 2>/dev/null; then
        SOC_TYPE="RK3399"
        GPU_TYPE="Mali-T860"
    elif grep -q "rk3568" /proc/device-tree/compatible 2>/dev/null; then
        SOC_TYPE="RK3568"
        GPU_TYPE="Mali-G52"
    else
        SOC_TYPE=$(grep -oP "Model.*:\s*\K.*" /proc/cpuinfo | head -1 || echo "Unknown")
        GPU_TYPE="Unknown"
    fi
    
    log_message "SoC: $SOC_TYPE" "$BLUE"
    log_message "GPU: $GPU_TYPE" "$BLUE"
    
    # Check boot device
    BOOT_DEVICE=$(findmnt -n -o SOURCE /)
    log_message "Boot device: $BOOT_DEVICE" "$BLUE"
    
    if echo "$BOOT_DEVICE" | grep -q "mmcblk"; then
        if echo "$BOOT_DEVICE" | grep -q "mmcblk0"; then
            BOOT_TYPE="SD Card"
        else
            BOOT_TYPE="eMMC"
        fi
    else
        BOOT_TYPE="Other (NVMe/USB)"
    fi
    
    log_message "Boot type: $BOOT_TYPE" "$BLUE"
    
    # Save hardware info
    {
        echo "Board: $BOARD_MODEL"
        echo "SoC: $SOC_TYPE"
        echo "GPU: $GPU_TYPE"
        echo "Boot: $BOOT_TYPE ($BOOT_DEVICE)"
        echo "Kernel: $(uname -r)"
    } > "$HARDWARE_LOG"
}

check_armbian_specifics() {
    print_header "Armbian-Specific Checks"
    
    # Check if Armbian
    if [ -f /etc/armbian-release ]; then
        log_message "✓ Armbian system detected" "$GREEN"
        source /etc/armbian-release
        log_message "Armbian Version: ${VERSION:-Unknown}" "$BLUE"
        log_message "Armbian Board: ${BOARD:-Unknown}" "$BLUE"
    else
        log_message "WARNING: Not an official Armbian system" "$YELLOW"
    fi
    
    # Check Armbian config tool
    if command -v armbian-config &> /dev/null; then
        log_message "✓ armbian-config tool available" "$GREEN"
    else
        log_message "WARNING: armbian-config not found" "$YELLOW"
    fi
    
    # Check for Armbian kernel
    KERNEL_VERSION=$(uname -r)
    if echo "$KERNEL_VERSION" | grep -qE "rockchip|sunxi|meson|armbian"; then
        log_message "✓ Armbian/vendor kernel detected: $KERNEL_VERSION" "$GREEN"
    else
        log_message "INFO: Generic kernel in use: $KERNEL_VERSION" "$BLUE"
    fi
}

check_gpu_drivers() {
    print_header "GPU Driver Verification"
    
    # Check for Mali/Panfrost drivers
    if lsmod | grep -qE "panfrost|panthor|mali"; then
        LOADED_DRIVER=$(lsmod | grep -E "panfrost|panthor|mali" | awk '{print $1}' | head -1)
        log_message "✓ GPU driver loaded: $LOADED_DRIVER" "$GREEN"
    else
        log_message "WARNING: No Mali GPU driver detected" "$YELLOW"
    fi
    
    # Check DRM devices
    if ls /dev/dri/card* &>/dev/null; then
        DRI_DEVICES=$(ls /dev/dri/card* | wc -l)
        log_message "✓ DRI devices found: $DRI_DEVICES" "$GREEN"
    else
        log_message "WARNING: No DRI devices found" "$YELLOW"
    fi
    
    # Check Mesa version (critical for GPU)
    if dpkg -l | grep -q "mesa"; then
        MESA_VERSION=$(dpkg -l | grep "libgles2-mesa" | awk '{print $3}' | head -1)
        log_message "Mesa version: $MESA_VERSION" "$BLUE"
    fi
    
    # Check firmware
    if [ -d /lib/firmware/rockchip ]; then
        FIRMWARE_COUNT=$(find /lib/firmware/rockchip -type f | wc -l)
        log_message "✓ Rockchip firmware files: $FIRMWARE_COUNT" "$GREEN"
    fi
}

check_plasma_desktop() {
    print_header "Plasma Desktop Environment Check"
    
    # Check Plasma version
    if dpkg -l | grep -q "plasma-desktop"; then
        PLASMA_PKG=$(dpkg -l | grep "plasma-desktop" | head -1)
        PLASMA_VERSION=$(echo "$PLASMA_PKG" | awk '{print $3}')
        
        if echo "$PLASMA_VERSION" | grep -q "^6\."; then
            log_message "✓ Plasma 6 installed: $PLASMA_VERSION" "$GREEN"
            PLASMA_VER=6
        elif echo "$PLASMA_VERSION" | grep -q "^5\."; then
            log_message "✓ Plasma 5 installed: $PLASMA_VERSION" "$BLUE"
            PLASMA_VER=5
        else
            log_message "Plasma version: $PLASMA_VERSION" "$BLUE"
            PLASMA_VER=0
        fi
    else
        log_message "INFO: Plasma desktop not installed" "$BLUE"
        PLASMA_VER=0
        return
    fi
    
    # Check KDE Frameworks
    if [ $PLASMA_VER -eq 6 ]; then
        if dpkg -l | grep -q "libkf6"; then
            log_message "✓ KDE Frameworks 6 libraries found" "$GREEN"
        else
            log_message "WARNING: Plasma 6 but KF6 libraries missing" "$YELLOW"
        fi
        
        # Check for leftover KF5 packages
        KF5_COUNT=$(dpkg -l | grep -c "libkf5" 2>/dev/null || echo "0")
        if [ "$KF5_COUNT" -gt 0 ]; then
            log_message "INFO: $KF5_COUNT KDE Frameworks 5 packages still installed" "$YELLOW"
            log_message "  (These may be removed after upgrade)" "$YELLOW"
        fi
    fi
    
    # Check display manager
    if systemctl is-enabled sddm &>/dev/null; then
        log_message "✓ SDDM display manager enabled" "$GREEN"
        
        if systemctl is-active sddm &>/dev/null; then
            log_message "✓ SDDM is running" "$GREEN"
        else
            log_message "INFO: SDDM not currently running (expected in SSH)" "$BLUE"
        fi
    elif systemctl is-enabled lightdm &>/dev/null; then
        log_message "✓ LightDM display manager enabled" "$GREEN"
    else
        log_message "WARNING: No display manager enabled" "$YELLOW"
    fi
    
    # Check Wayland/X11 support
    if [ -d /usr/share/wayland-sessions ]; then
        WAYLAND_SESSIONS=$(ls /usr/share/wayland-sessions/*.desktop 2>/dev/null | wc -l)
        log_message "Wayland sessions available: $WAYLAND_SESSIONS" "$BLUE"
    fi
    
    if [ -d /usr/share/xsessions ]; then
        X11_SESSIONS=$(ls /usr/share/xsessions/*.desktop 2>/dev/null | wc -l)
        log_message "X11 sessions available: $X11_SESSIONS" "$BLUE"
    fi
}

backup_critical_configs() {
    print_header "Backing Up Critical Configurations"
    
    BACKUP_DIR="/root/upgrade-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Backup APT sources
    cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup Armbian config
    cp /etc/armbian-release "$BACKUP_DIR/" 2>/dev/null || true
    cp /boot/armbianEnv.txt "$BACKUP_DIR/" 2>/dev/null || true
    cp /boot/boot.cmd "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup network config
    cp -r /etc/NetworkManager "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup display manager config
    cp -r /etc/sddm.conf* "$BACKUP_DIR/" 2>/dev/null || true
    
    # List of installed packages
    dpkg -l > "$BACKUP_DIR/package-list.txt"
    
    log_message "✓ Backups saved to: $BACKUP_DIR" "$GREEN"
    echo "$BACKUP_DIR" > /tmp/last-upgrade-backup-location
}

pre_upgrade_checks() {
    print_header "Pre-Upgrade System Checks"
    
    # Check disk space
    AVAILABLE_SPACE=$(df / | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=5000000 # 5GB in KB
    
    AVAILABLE_GB=$((AVAILABLE_SPACE/1024/1024))
    
    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        log_message "WARNING: Low disk space. Available: ${AVAILABLE_GB}GB, Recommended: 5GB+" "$RED"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_message "✓ Disk space check passed: ${AVAILABLE_GB}GB available" "$GREEN"
    fi
    
    # Check current version
    CURRENT_VERSION=$(lsb_release -cs)
    CURRENT_RELEASE=$(lsb_release -rs)
    log_message "Current distribution: Ubuntu $CURRENT_RELEASE ($CURRENT_VERSION)" "$BLUE"
    
    # Check for running package managers
    if pgrep -x "apt" > /dev/null || pgrep -x "apt-get" > /dev/null || pgrep -x "dpkg" > /dev/null; then
        log_message "ERROR: Another package manager is running. Please wait for it to finish." "$RED"
        ps aux | grep -E "apt|dpkg" | grep -v grep | tee -a "$LOG_FILE"
        exit 1
    fi
    
    log_message "✓ No conflicting package managers running" "$GREEN"
    
    # Check for held packages
    HELD_PACKAGES=$(apt-mark showhold | wc -l)
    if [ "$HELD_PACKAGES" -gt 0 ]; then
        log_message "WARNING: $HELD_PACKAGES packages are held:" "$YELLOW"
        apt-mark showhold | tee -a "$LOG_FILE"
    fi
}

update_package_lists() {
    print_header "Updating Package Lists"
    
    apt update 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_message "✓ Package lists updated successfully" "$GREEN"
    else
        log_message "WARNING: Some repositories may have issues" "$YELLOW"
    fi
    
    # Show upgrade statistics
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
    log_message "Packages to upgrade: $UPGRADABLE" "$BLUE"
}

smart_upgrade() {
    print_header "Starting Smart Upgrade Process"
    
    log_message "Attempting upgrade with automatic conflict resolution..." "$BLUE"
    
    # Try upgrade with force-overwrite from the start (common in dist-upgrades)
    if apt -o Dpkg::Options::="--force-overwrite" \
           -o Dpkg::Options::="--force-confdef" \
           -o Dpkg::Options::="--force-confold" \
           full-upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✓ Upgrade completed successfully" "$GREEN"
        return 0
    fi
    
    log_message "Initial upgrade attempt failed. Analyzing issues..." "$YELLOW"
    
    # Fix broken packages
    log_message "Attempting to fix broken packages..." "$YELLOW"
    apt --fix-broken install -y 2>&1 | tee -a "$LOG_FILE"
    
    # Try again
    if apt -o Dpkg::Options::="--force-overwrite" \
           -o Dpkg::Options::="--force-confdef" \
           -o Dpkg::Options::="--force-confold" \
           full-upgrade -y 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✓ Upgrade completed after fixing broken packages" "$GREEN"
        return 0
    fi
    
    log_message "ERROR: Upgrade failed. Check log: $LOG_FILE" "$RED"
    return 1
}

handle_kde_transition() {
    print_header "Handling KDE Plasma 5 → 6 Transition"
    
    # Check if we have both KF5 and KF6 packages
    KF5_COUNT=$(dpkg -l | grep -c "libkf5" 2>/dev/null || echo "0")
    KF6_COUNT=$(dpkg -l | grep -c "libkf6" 2>/dev/null || echo "0")
    
    if [ "$KF5_COUNT" -gt 0 ] && [ "$KF6_COUNT" -gt 0 ]; then
        log_message "Detected KDE Frameworks transition (KF5 → KF6)" "$YELLOW"
        log_message "KF5 packages: $KF5_COUNT | KF6 packages: $KF6_COUNT" "$BLUE"
        
        # Remove old KF5 packages that conflict
        log_message "Removing conflicting KF5 packages..." "$YELLOW"
        
        apt remove -y \
            libkpim5akonadimime-data \
            libkpim5libkleo-data \
            libkf5purpose-bin \
            2>&1 | tee -a "$LOG_FILE" || true
        
        log_message "✓ Cleaned up KF5 conflicts" "$GREEN"
    elif [ "$KF5_COUNT" -eq 0 ] && [ "$KF6_COUNT" -gt 0 ]; then
        log_message "✓ Clean KDE Frameworks 6 installation" "$GREEN"
    fi
}

post_upgrade_cleanup() {
    print_header "Post-Upgrade Cleanup"
    
    log_message "Removing unnecessary packages..." "$BLUE"
    apt autoremove -y 2>&1 | tee -a "$LOG_FILE"
    
    log_message "Cleaning package cache..." "$BLUE"
    apt autoclean 2>&1 | tee -a "$LOG_FILE"
    
    # Update bootloader
    log_message "Updating bootloader..." "$BLUE"
    if [ -f /boot/boot.cmd ]; then
        mkimage -C none -A arm64 -T script -d /boot/boot.cmd /boot/boot.scr 2>&1 | tee -a "$LOG_FILE" || true
    fi
    update-grub 2>&1 | tee -a "$LOG_FILE" || true
    
    log_message "✓ Cleanup completed" "$GREEN"
}

verify_post_upgrade() {
    print_header "Post-Upgrade Verification"
    
    # Check for broken packages
    BROKEN=$(dpkg -l | grep -c "^iU" 2>/dev/null || echo "0")
    if [ "$BROKEN" -gt 0 ]; then
        log_message "WARNING: $BROKEN broken packages remain" "$YELLOW"
        dpkg -l | grep "^iU" | tee -a "$LOG_FILE"
    else
        log_message "✓ No broken packages" "$GREEN"
    fi
    
    # Check dependencies
    log_message "Checking dependencies..." "$BLUE"
    apt check 2>&1 | tee -a "$LOG_FILE"
    
    # Show new version
    NEW_VERSION=$(lsb_release -cs)
    NEW_RELEASE=$(lsb_release -rs)
    log_message "New distribution: Ubuntu $NEW_RELEASE ($NEW_VERSION)" "$GREEN"
    
    # Re-check hardware
    detect_hardware
    check_gpu_drivers
    check_plasma_desktop
    
    # Check kernel
    CURRENT_KERNEL=$(uname -r)
    LATEST_KERNEL=$(dpkg -l | grep "^ii.*linux-image" | tail -1 | awk '{print $2}' | sed 's/linux-image-//')
    log_message "Current kernel: $CURRENT_KERNEL" "$BLUE"
    if [ "$CURRENT_KERNEL" != "$LATEST_KERNEL" ]; then
        log_message "Latest kernel: $LATEST_KERNEL (will load after reboot)" "$YELLOW"
    fi
    
    # Check initramfs
    INITRAMFS_COUNT=$(ls /boot/initrd.img-* 2>/dev/null | wc -l)
    log_message "Initramfs images: $INITRAMFS_COUNT" "$BLUE"
}

create_upgrade_report() {
    print_header "Creating Upgrade Report"
    
    REPORT_FILE="/root/upgrade-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "========================================"
        echo "Armbian Smart Upgrade Report"
        echo "========================================"
        echo "Date: $(date)"
        echo ""
        echo "Hardware:"
        cat "$HARDWARE_LOG"
        echo ""
        echo "Upgrade Status: Completed"
        echo ""
        echo "Previous Version: $CURRENT_VERSION"
        echo "New Version: $(lsb_release -cs)"
        echo ""
        echo "Kernel: $(uname -r)"
        echo ""
        echo "Full log: $LOG_FILE"
        echo "Hardware log: $HARDWARE_LOG"
        echo "Backup location: $(cat /tmp/last-upgrade-backup-location 2>/dev/null || echo 'N/A')"
        echo ""
        echo "========================================"
    } > "$REPORT_FILE"
    
    log_message "✓ Upgrade report saved to: $REPORT_FILE" "$GREEN"
}

main() {
    clear
    log_message "╔══════════════════════════════════════════════════════╗" "$PURPLE"
    log_message "║   Smart Armbian Distribution Upgrader v1.0          ║" "$PURPLE"
    log_message "║   Optimized for Orange Pi, Rock Pi, and other SBCs  ║" "$PURPLE"
    log_message "╚══════════════════════════════════════════════════════╝" "$PURPLE"
    echo ""
    
    check_root
    
    log_message "Main log: $LOG_FILE" "$BLUE"
    log_message "Hardware log: $HARDWARE_LOG" "$BLUE"
    echo ""
    
    # Initial hardware detection
    detect_hardware
    check_armbian_specifics
    check_gpu_drivers
    check_plasma_desktop
    
    echo ""
    read -p "Continue with upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_message "Upgrade cancelled by user" "$YELLOW"
        exit 0
    fi
    
    backup_critical_configs
    pre_upgrade_checks
    update_package_lists
    handle_kde_transition
    smart_upgrade
    
    if [ $? -eq 0 ]; then
        post_upgrade_cleanup
        verify_post_upgrade
        create_upgrade_report
        
        echo ""
        log_message "╔══════════════════════════════════════════════════════╗" "$GREEN"
        log_message "║           Upgrade Process Completed!                 ║" "$GREEN"
        log_message "╚══════════════════════════════════════════════════════╝" "$GREEN"
        echo ""
        log_message "Full log: $LOG_FILE" "$BLUE"
        log_message "Hardware log: $HARDWARE_LOG" "$BLUE"
        log_message "Upgrade report: /root/upgrade-report-*.txt" "$BLUE"
        echo ""
        
        read -p "Reboot now to complete upgrade? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_message "Rebooting system in 5 seconds..." "$GREEN"
            log_message "Press Ctrl+C to cancel..." "$YELLOW"
            sleep 5
            reboot
        else
            log_message "IMPORTANT: Please reboot manually to complete the upgrade!" "$YELLOW"
            log_message "Run: sudo reboot" "$YELLOW"
        fi
    else
        log_message "Upgrade encountered errors. Check logs:" "$RED"
        log_message "  Main log: $LOG_FILE" "$RED"
        log_message "  Hardware log: $HARDWARE_LOG" "$RED"
        exit 1
    fi
}

# Run main function
main "$@"
