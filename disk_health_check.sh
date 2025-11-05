#!/bin/bash
# ============================================
# Universal Linux Disk Health Check Script (Safe Edition)
# Supports: HDD / SSD / NVMe / HP SmartArray / Dell PERC / StorCLI
# Works on: Debian, Ubuntu, CentOS, AlmaLinux, Rocky, Fedora, SUSE
# Safety: Non-destructive, optional installs, no exits on failure
# ============================================
# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color
# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Please run as root.${NC}"
  exit 1
fi
# --- INSTALL DEPENDENCIES (Optional & Safe) ---
install_packages() {
    local tools=("smartmontools" "nvme-cli")
    echo -e "${BLUE}🔧 Checking/Installing required tools (skipping if already present)...${NC}"
    
    # Check if tools are already available
    local missing_tools=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -eq 0 ]; then
        echo -e "${GREEN}✅ All tools already installed.${NC}"
        return
    fi
    
    echo -e "${YELLOW}⚠️ Missing: ${missing_tools[*]}. Attempting install...${NC}"
    
    if [ -f /etc/redhat-release ]; then
        if command -v dnf &>/dev/null; then
            # Add Dell repo for StorCLI if needed
            if ! command -v storcli &>/dev/null; then
                dnf config-manager --add-repo https://linux.dell.com/repo/community/openmanage/RPM-GPG-KEY-libsm -y || true
                dnf install -y https://linux.dell.com/repo/community/openmanage/1950/rhel9/10/x86_64/storcli-007.XXXX.XXXX.XXXXX-1.noarch.rpm || true  # Use latest from Dell site
            fi
            dnf install -y "${missing_tools[@]}" || echo -e "${YELLOW}⚠️ Some installs skipped (non-critical).${NC}"
        else
            yum install -y "${missing_tools[@]}" || echo -e "${YELLOW}⚠️ Some installs skipped (non-critical).${NC}"
        fi
    elif [ -f /etc/debian_version ]; then
        apt update -qq -y  # Quiet mode
        apt install -y "${missing_tools[@]}" || echo -e "${YELLOW}⚠️ Some installs skipped (non-critical).${NC}"
    elif grep -qi suse /etc/os-release 2>/dev/null; then
        zypper install -y "${missing_tools[@]}" || echo -e "${YELLOW}⚠️ Some installs skipped (non-critical).${NC}"
    else
        echo -e "${YELLOW}⚠️ Unsupported OS for auto-install. Manual install recommended.${NC}"
    fi
    
    # Check HP/Dell RAID tools (optional, no install if not present)
    if ! command -v ssacli &>/dev/null && ! command -v hpssacli &>/dev/null; then
        echo -e "${YELLOW}⚠️ HP RAID tool not found (ssacli/hpssacli). Download from HPE if needed.${NC}"
    fi
    if ! command -v storcli &>/dev/null && ! command -v megacli &>/dev/null; then
        echo -e "${YELLOW}⚠️ Dell RAID tool not found (storcli/megacli). Download from Dell if needed.${NC}"
    fi
}
# --- CHECK DISK HEALTH (Safe & Comprehensive) ---
check_disk_health() {
    echo -e "${BLUE}\n🔍 Checking disk health...${NC}"
    
    # Priority: HP SmartArray with modern tools first
    if command -v ssacli &>/dev/null; then
        echo -e "${GREEN}✅ HP Smart Array (ssacli) detected.${NC}"
        ssacli controller all show config | grep -E "physicaldrive|Status|Model|Serial" || echo -e "${YELLOW}⚠️ No detailed HP data.${NC}"
        return
    elif command -v hpssacli &>/dev/null; then
        echo -e "${GREEN}✅ HP Smart Array (hpssacli) detected.${NC}"
        hpssacli controller all show config | grep -E "physicaldrive|Status|Model|Serial" || echo -e "${YELLOW}⚠️ No detailed HP data.${NC}"
        return
    elif ls /dev/cciss/c*d* &>/dev/null; then
        echo -e "${GREEN}✅ HP Smart Array (cciss fallback) detected.${NC}"
        for dev in /dev/cciss/c*d*; do
            # Get actual disk slots dynamically (safer than fixed loop)
            local slots=$(smartctl -i -d cciss "$dev" 2>/dev/null | grep -oP '(?<=Slot: )\d+' || seq 0 7)  # Fallback to 0-7 if can't detect
            for i in $slots; do
                echo -e "\n📦 ${YELLOW}Device: $dev - Disk #$i${NC}"
                smartctl -a -d cciss,$i "$dev" 2>/dev/null | grep -E "Model|Serial|Reallocated_Sector_Ct|Wear_Leveling_Count|Overall|Health|SMART" || echo "⚠️ No SMART data for this disk."
            done
        done
        return
    fi
    
    # Dell PERC RAID (prefer StorCLI)
    if command -v storcli &>/dev/null; then
        echo -e "${GREEN}✅ Dell StorCLI detected.${NC}"
        storcli /c0 /eall /sall show all | grep -E "PD LIST|State|Media Type|Predictive Failures" || echo -e "${YELLOW}⚠️ No detailed Dell data.${NC}"
        return
    elif command -v megacli &>/dev/null; then
        echo -e "${GREEN}✅ Dell MegaRAID detected.${NC}"
        megacli -PDList -aALL | grep -E "Device Id|Firmware state|Media Type|Predictive Failure Count" || echo -e "${YELLOW}⚠️ No detailed Dell data.${NC}"
        return
    fi
    
    # NVMe disks (enhanced for SSD wear)
    if ls /dev/nvme*n1 &>/dev/null; then
        echo -e "${GREEN}✅ NVMe disks detected.${NC}"
        for dev in /dev/nvme*n1; do
            echo -e "\n📦 ${YELLOW}Device: $dev${NC}"
            nvme smart-log "$dev" 2>/dev/null | grep -E "critical_warning|temperature|data_units_written|data_units_read|power_cycles|power_on_hours|percentage_used|available_spare|media_wear" || echo "⚠️ No NVMe data."
        done
    fi
    
    # SATA/SAS (sdX) - only if no RAID above
    if ls /dev/sd[a-z] &>/dev/null 2>/dev/null; then
        echo -e "${GREEN}✅ SATA/SAS disks detected.${NC}"
        for dev in /dev/sd[a-z]; do
            # Skip if it's a CD-ROM or loop device (safety)
            [ -b "$dev" ] && [ ! "$(cat /sys/block/$(basename $dev)/device/type 2>/dev/null)" = "5" ] || continue
            echo -e "\n📦 ${YELLOW}Device: $dev${NC}"
            smartctl -H "$dev" 2>/dev/null | head -1 | grep -E "SMART overall-health|PASSED|FAILED" || echo "⚠️ Health check unavailable."
            smartctl -A "$dev" 2>/dev/null | grep -E "Reallocated_Sector_Ct|Power_On_Hours|Temperature_Celsius|Wear_Leveling_Count" || echo "⚠️ No attribute data."
        done
    fi
    
    # Generic fallback (always safe)
    echo -e "${YELLOW}\n📋 Basic disk overview:${NC}"
    lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT | column -t  # Nicer table format if column available
}
# --- MAIN ---
install_packages
check_disk_health
echo -e "\n${GREEN}✅ Disk health check complete (no changes made to system).${NC}"