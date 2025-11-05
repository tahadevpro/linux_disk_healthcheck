#!/usr/bin/env bash
# safe-health-v2.sh - Enhanced Safe Disk Health Check (read-only by default)
# Usage:
# sudo ./safe-health-v2.sh # normal (may attempt suggested installs with prompt)
# sudo ./safe-health-v2.sh --dry-run # don't run anything, only show planned checks
# ./safe-health-v2.sh --no-install # never attempt installing packages
# sudo ./safe-health-v2.sh --device /dev/sda --device /dev/nvme0n1
#
# IMPORTANT: This script is INTENDED to be non-destructive and only runs read-only commands.
# Check README.md before use. Default: prompt before making changes.
set -euo pipefail
IFS=$'\n\t'

# --------- Defaults ----------
DRY_RUN=0
NO_INSTALL=0
WHITELIST=() # explicit devices passed by --device
LOGFILE="" # optional log
REALLY_RUN_INSTALL=0

# Tools we may use (only read-only invocations)
REQUIRED_TOOLS=(lsblk df awk grep sed smartctl nvme fsck)

# Note: we won't force-install; we'll suggest
# --------- Helpers ----------
echoy() { printf "%b\n" "$*"; }
die() { printf "%b\n" "$*" >&2; exit 1; }
plan() { # print or run depending on DRY_RUN
  if [ "$DRY_RUN" -eq 1 ]; then
    echoy "${YELLOW}[DRY-RUN]${NC} $*"
  else
    echoy "$*"
  fi
}

# Colors (optional)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'

# --------- Arg parse ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    --device) WHITELIST+=("$2"); shift 2 ;;
    --devices-file) [ -f "$2" ] || die "devices-file not found"; mapfile -t tmp < "$2"; WHITELIST+=("${tmp[@]}"); shift 2 ;;
    --log) LOGFILE="$2"; shift 2 ;;
    -h|--help) cat << EOF
safe-health-v2.sh - Enhanced Disk Health Checker

Usage: $0 [OPTIONS]

Options:
  --dry-run          Show planned actions without executing.
  --no-install       Skip package installation prompts.
  --device <dev>     Specify a device (e.g., /dev/sda). Repeatable.
  --devices-file <file> Read devices from a file (one per line).
  --log <file>       Log output to file (with timestamps).
  -h, --help         Show this help.

Features:
- Read-only SMART/NVMe checks.
- Filesystem usage and dry-run integrity (fsck -n).
- Temperature warnings (>50°C).
- Auto-detects distros for installs (apt, dnf, yum, pacman).

Run with sudo for full access.
EOF
    exit 0 ;;
    *) die "Unknown arg: $1";;
  esac
done

# --------- Sanity: require user confirmation before any install ---
confirm_install_if_needed() {
  if [ "$NO_INSTALL" -eq 1 ]; then
    echoy "${YELLOW}Auto-install disabled by --no-install${NC}"
    return 1
  fi
  read -r -p "Script suggests installing missing packages. Proceed? [y/N] " ans
  case "$ans" in [yY][eE][sS]|[yY]) return 0 ;; *) return 1 ;; esac
}

# --------- Detect distro for installs ----------
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian) echo "apt" ;;
      fedora|rhel|centos) echo "dnf" ;;
      arch) echo "pacman" ;;
      *) echo "yum" ;; # fallback
    esac
  else
    echo "yum" # conservative fallback
  fi
}

# --------- Check available tools (non-fatal)
missing_tools=()
for t in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$t" &>/dev/null; then
    missing_tools+=("$t")
  fi
done
if [ "${#missing_tools[@]}" -ne 0 ]; then
  echoy "${YELLOW}Missing tools: ${missing_tools[*]}${NC}"
  echoy "Recommendation: install smartmontools (for smartctl), nvme-cli (for NVMe), and e2fsprogs (for fsck)."
  if [ "$NO_INSTALL" -eq 0 ] && [ "$EUID" -eq 0 ]; then
    if confirm_install_if_needed; then
      if [ "$DRY_RUN" -eq 1 ]; then
        echoy "[DRY-RUN] Install command (based on distro)"
      else
        pkg_mgr=$(detect_distro)
        case "$pkg_mgr" in
          apt) apt update && apt install -y smartmontools nvme-cli e2fsprogs || echoy "${YELLOW}Install failed; continue in degraded mode${NC}" ;;
          dnf) dnf install -y smartmontools nvme-cli e2fsprogs || echoy "${YELLOW}Install failed; continue in degraded mode${NC}" ;;
          pacman) pacman -Syu --noconfirm smartmontools nvme-cli e2fsprogs || echoy "${YELLOW}Install failed; continue in degraded mode${NC}" ;;
          yum) yum install -y smartmontools nvme-cli e2fsprogs || echoy "${YELLOW}Install failed; continue in degraded mode${NC}" ;;
        esac
      fi
    else
      echoy "${YELLOW}Skipped install per user choice.${NC}"
    fi
  fi
fi

# --------- Collect devices (whitelist first, else auto-detect)
devices=()
if [ "${#WHITELIST[@]}" -gt 0 ]; then
  for d in "${WHITELIST[@]}"; do
    devices+=("$d")
  done
else
  # auto-detect (only common block devices)
  mapfile -t auto < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
  devices=("${auto[@]}")
fi
[ "${#devices[@]}" -gt 0 ] || die "No block devices detected. Use --device to specify."

# --------- Main checks (read-only)
summary=""
critical=0
warning=0
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

log_entry() {
  if [ -n "$LOGFILE" ] && [ "$DRY_RUN" -eq 0 ]; then
    printf "[%s] %b\n" "$timestamp" "$*" >> "$LOGFILE"
  fi
}

for dev in "${devices[@]}"; do
  summary+=$'\n'"=== $dev ==="$'\n'
  log_entry "Checking device: $dev"

  # SMART checks (avoid destructive tests)
  if command -v smartctl &>/dev/null; then
    plan "smartctl -H $dev"
    if [ "$DRY_RUN" -eq 0 ]; then
      out=$(smartctl -H "$dev" 2>&1) || out="$out"
      summary+="$out"$'\n'
      attrs=$(smartctl -A "$dev" 2>/dev/null || true)
      summary+="$attrs"$'\n'
      if echo "$out" | grep -iq "fail"; then critical=1; fi

      # Temperature check
      temp=$(echo "$attrs" | awk '/Temperature_Celsius/ {print $10}' | tail -1)
      if [ -n "$temp" ] && [ "$temp" -gt 50 ]; then
        warning=1
        summary+="${YELLOW}WARNING: Temperature high ($temp°C)!${NC}"$'\n'
      fi
    fi
  elif command -v nvme &>/dev/null && [[ "$dev" == /dev/nvme* ]]; then
    plan "nvme smart-log $dev"
    if [ "$DRY_RUN" -eq 0 ]; then
      out=$(nvme smart-log "$dev" 2>&1) || out="$out"
      summary+="$out"$'\n'
      # Enhanced NVMe checks
      if echo "$out" | grep -Eqi "critical_warning.*[1-9]"; then critical=1; fi
      avail_spare=$(echo "$out" | awk '/available_spare/ {print $3}')
      pct_used=$(echo "$out" | awk '/percentage_used/ {print $3}')
      if [ -n "$avail_spare" ] && [ "$avail_spare" -lt 10 ]; then
        warning=1
        summary+="${YELLOW}WARNING: Available spare low ($avail_spare%)!${NC}"$'\n'
      fi
      if [ -n "$pct_used" ] && [ "$pct_used" -gt 90 ]; then
        warning=1
        summary+="${YELLOW}WARNING: Percentage used high ($pct_used%)!${NC}"$'\n'
      fi
    fi
  else
    summary+="(no smartctl/nvme available to query $dev)$'\n'"
  fi

  # Filesystem dry-run integrity check (for mounted filesystems on this dev)
  mounts=$(lsblk -no MOUNTPOINT "$dev" | grep -v '^$' | head -1) # primary mount
  if [ -n "$mounts" ] && command -v fsck &>/dev/null; then
    plan "fsck -n $mounts" # dry-run only
    if [ "$DRY_RUN" -eq 0 ]; then
      fsck_out=$(fsck -n "$mounts" 2>&1 || true)
      if echo "$fsck_out" | grep -iq "error\|dirty"; then
        warning=1
        summary+="${YELLOW}WARNING: Filesystem issues detected (dry-run).${NC}"$'\n'
      else
        summary+="Filesystem integrity OK (dry-run)."$'\n'
      fi
    fi
  fi
done

# Filesystem usage (read-only)
plan "df -h --output=source,size,used,avail,pcent,target"
if [ "$DRY_RUN" -eq 0 ]; then
  fsout=$(df -h --output=source,size,used,avail,pcent,target | sed '1d')
  summary+=$'\n'"=== Filesystems Usage ==="$'\n'
  while IFS= read -r line; do
    pct=$(echo "$line" | awk '{print $4}' | sed 's/%//')
    if [ "$pct" -gt 90 ]; then
      warning=1
      summary+="${YELLOW}WARNING: High usage on $line${NC}"$'\n'
    else
      summary+="$line"$'\n'
    fi
  done <<< "$fsout"
fi

# --------- Output & optional log
echoy "${BLUE}--- Enhanced Health Summary ---${NC}"
echoy "$summary"
log_entry "Full summary: $summary" # log the whole thing at end

if [ -n "$LOGFILE" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echoy "${YELLOW}DRY-RUN: would write log to $LOGFILE${NC}"
  else
    echoy "${GREEN}Logged to $LOGFILE (with timestamps)${NC}"
  fi
fi

if [ "$critical" -eq 1 ]; then
  echoy "${RED}CRITICAL indicators found. Investigate immediately.${NC}"
  exit 2
elif [ "$warning" -eq 1 ]; then
  echoy "${YELLOW}Warnings found. Monitor closely.${NC}"
  exit 1
else
  echoy "${GREEN}No immediate issues detected. All good!${NC}"
  exit 0
fi