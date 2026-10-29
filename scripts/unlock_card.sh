#!/usr/bin/env bash
# ==============================================================================
# MicroSD CSD Write-Protection Unlock & Recovery Utility
# Target: OEM / Educational / BYJU'S Locked MicroSD Cards
# Requirements: Native MMC slot (/dev/mmcblk0) e.g., on Raspberry Pi (USB Boot)
# License: MIT
# ==============================================================================

set -euo pipefail

DEV="/dev/mmcblk0"
FS_TYPE="exfat"
VOL_LABEL="SDCARD"
PERFORM_TEST=true

usage() {
    cat <<EOF
Usage: sudo $(basename "$0") [OPTIONS] [DEVICE]

Options:
  -d, --device <dev>   Target MMC block device (default: /dev/mmcblk0)
  --fs <type>          Filesystem format: 'exfat' (default) or 'fat32'
  -l, --label <label>  Volume label (default: SDCARD)
  --no-test            Skip post-format write benchmark
  -h, --help           Display this help message

Examples:
  sudo $(basename "$0") /dev/mmcblk0
  sudo $(basename "$0") --fs fat32 /dev/mmcblk0
EOF
    exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            DEV="$2"
            shift 2
            ;;
        --fs)
            FS_TYPE="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        -l|--label)
            VOL_LABEL="$2"
            shift 2
            ;;
        --no-test)
            PERFORM_TEST=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        /dev/*)
            DEV="$1"
            shift
            ;;
        *)
            echo "[-] Unknown argument: $1" >&2
            usage
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================================="
echo "    MicroSD Hardware CSD Write-Protection Recovery        "
echo "=========================================================="
echo "[*] Target Device:     $DEV"
echo "[*] Filesystem Target: $FS_TYPE"
echo "[*] Volume Label:      $VOL_LABEL"
echo "----------------------------------------------------------"

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

# Edge Case 1: Check if device node exists; if missing, trigger host bus rescan
if [ ! -b "$DEV" ]; then
    echo "[!] Device '$DEV' not found yet. Triggering MMC host bus rescan..."
    for h in /sys/class/mmc_host/mmc*; do
        if [ -w "$h/rescan" ]; then
            echo 1 > "$h/rescan" 2>/dev/null || true
        fi
    done
    sleep 2
    command -v udevadm &>/dev/null && udevadm settle || sleep 1
fi

if [ ! -b "$DEV" ]; then
    echo "[-] FATAL: Block device '$DEV' not found!" >&2
    echo "    1. Ensure the MicroSD card is firmly seated in the native MMC slot." >&2
    echo "    2. Note: USB card readers are unsupported because they cannot pass" >&2
    echo "       raw MMC ioctl commands (CMD27). Use a Raspberry Pi onboard slot." >&2
    exit 1
fi

# Ensure required packages exist
REQUIRED_PKGS=()
command -v parted &>/dev/null || REQUIRED_PKGS+=(parted)
command -v wipefs &>/dev/null || REQUIRED_PKGS+=(util-linux)

if [ "$FS_TYPE" = "exfat" ]; then
    command -v mkfs.exfat &>/dev/null || REQUIRED_PKGS+=(exfatprogs)
elif [ "$FS_TYPE" = "fat32" ]; then
    command -v mkfs.vfat &>/dev/null || REQUIRED_PKGS+=(dosfstools)
fi

if [ ${#REQUIRED_PKGS[@]} -gt 0 ]; then
    echo "[*] Installing required system packages (${REQUIRED_PKGS[*]})..."
    apt-get update -y && apt-get install -y "${REQUIRED_PKGS[@]}"
fi

# Locate unlocking utility
SDTOOL=""
if [ -x "$REPO_DIR/src/unlock_direct" ]; then
    SDTOOL="$REPO_DIR/src/unlock_direct"
elif [ -x "$REPO_DIR/bin/arm-sdtool" ] && [ "$(uname -m)" != "x86_64" ]; then
    SDTOOL="$REPO_DIR/bin/arm-sdtool"
elif [ -x "$REPO_DIR/bin/amd64-sdtool" ] && [ "$(uname -m)" = "x86_64" ]; then
    SDTOOL="$REPO_DIR/bin/amd64-sdtool"
elif command -v sdtool &>/dev/null; then
    SDTOOL="$(command -v sdtool)"
elif [ -f "$REPO_DIR/src/unlock_direct.c" ] && command -v gcc &>/dev/null; then
    echo "[*] Compiling standalone unlock_direct from source..."
    gcc -O2 "$REPO_DIR/src/unlock_direct.c" -o "$REPO_DIR/src/unlock_direct"
    SDTOOL="$REPO_DIR/src/unlock_direct"
fi

# Fallback: Download prebuilt sdtool binary if still not found
if [ -z "$SDTOOL" ]; then
    echo "[*] Fetching prebuilt sdtool utility..."
    ARCH="$(uname -m)"
    mkdir -p "$REPO_DIR/bin"
    if [ "$ARCH" = "aarch64" ] || [[ "$ARCH" =~ arm.* ]]; then
        wget -q https://raw.githubusercontent.com/BertoldVdb/sdtool/master/static/arm-sdtool -O "$REPO_DIR/bin/arm-sdtool"
        chmod +x "$REPO_DIR/bin/arm-sdtool"
        SDTOOL="$REPO_DIR/bin/arm-sdtool"
    else
        wget -q https://raw.githubusercontent.com/BertoldVdb/sdtool/master/static/amd64-sdtool -O "$REPO_DIR/bin/amd64-sdtool"
        chmod +x "$REPO_DIR/bin/amd64-sdtool"
        SDTOOL="$REPO_DIR/bin/amd64-sdtool"
    fi
fi

echo "[+] Using unlock utility: $SDTOOL"

# Step 1: Unmount any active partitions on the card
echo "[*] Unmounting active partitions on $DEV..."
for mnt in $(lsblk -ln -o MOUNTPOINT "$DEV" 2>/dev/null | grep -v '^$'); do
    umount -f "$mnt" 2>/dev/null || true
done
umount ${DEV}* 2>/dev/null || true

# Step 2: Probe CSD Status
echo "[+] Probing CSD Register on $DEV..."
STATUS_CMD=("$SDTOOL" "$DEV" "status")
if [[ "$SDTOOL" =~ unlock_direct ]]; then
    STATUS_CMD=("$SDTOOL" "--status" "$DEV")
fi

STATUS_OUT=$("${STATUS_CMD[@]}" 2>&1 || true)
echo "$STATUS_OUT"

if echo "$STATUS_OUT" | grep -qi "Permanent"; then
    echo "[-] FATAL: The card has PERMANENT write protection set (Bit 13)." >&2
    echo "    This is an irreversible hardware OTP fuse. Software cannot clear it." >&2
    exit 2
fi

if echo "$STATUS_OUT" | grep -qi "Off" || echo "$STATUS_OUT" | grep -qi "already write-protection DISABLED"; then
    echo "[+] Hardware write protection is already OFF!"
else
    echo "[*] Temporary Write Protection detected. Sending CMD27 (PROGRAM_CSD)..."
    UNLOCK_CMD=("$SDTOOL" "$DEV" "unlock")
    if [[ "$SDTOOL" =~ unlock_direct ]]; then
        UNLOCK_CMD=("$SDTOOL" "--unlock" "$DEV")
    fi

    UNLOCK_OUT=$("${UNLOCK_CMD[@]}" 2>&1 || true)
    echo "$UNLOCK_OUT"

    # Step 3: Verify write protection was cleared
    VERIFY_OUT=$("${STATUS_CMD[@]}" 2>&1 || true)
    if ! echo "$VERIFY_OUT" | grep -qiE "(Off|DISABLED)"; then
        echo "[-] ERROR: Failed to clear write protection. Output:" >&2
        echo "$VERIFY_OUT" >&2
        exit 3
    fi
    echo "[+] SUCCESS: Hardware write-protection successfully disabled!"
fi

# Step 4: Wipe Primary AND Secondary (Backup GPT) Partition Tables
# Edge Case: Android OEM formatting uses GPT. Wiping only the start leaves
# the backup GPT at disk end, causing the kernel to restore OEM partitions!
echo "[*] Erasing partition signatures and metadata..."
command -v wipefs &>/dev/null && wipefs -af "$DEV" 2>/dev/null || true

echo "[*] Zeroing primary partition table (first 16 MiB)..."
dd if=/dev/zero of="$DEV" bs=1M count=16 oflag=direct conv=fsync status=none 2>/dev/null || true

DEV_SIZE_BYTES=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
if [ "$DEV_SIZE_BYTES" -gt 33554432 ]; then
    DEV_SIZE_MB=$((DEV_SIZE_BYTES / 1024 / 1024))
    SEEK_POS=$((DEV_SIZE_MB - 16))
    echo "[*] Zeroing secondary GPT backup table at end of card (offset: ${SEEK_POS} MiB)..."
    dd if=/dev/zero of="$DEV" bs=1M seek="$SEEK_POS" count=16 oflag=direct conv=fsync status=none 2>/dev/null || true
fi

# Step 5: Create Clean MBR with 4 MiB Erase-Block Alignment
echo "[*] Creating fresh MBR partition table (aligned to 4 MiB erase blocks)..."
parted -s "$DEV" mklabel msdos
parted -s "$DEV" mkpart primary 4MiB 100%
partprobe "$DEV" 2>/dev/null || true
command -v udevadm &>/dev/null && udevadm settle || sleep 1

PART="${DEV}p1"
if [ ! -b "$PART" ]; then
    PART="${DEV}1"
fi

if [ ! -b "$PART" ]; then
    echo "[-] Error: Partition node $PART was not created." >&2
    exit 4
fi

# Step 6: Format Filesystem
if [ "$FS_TYPE" = "exfat" ]; then
    echo "[*] Formatting $PART as exFAT (Volume Label: $VOL_LABEL)..."
    mkfs.exfat -L "$VOL_LABEL" "$PART"
elif [ "$FS_TYPE" = "fat32" ]; then
    echo "[*] Formatting $PART as FAT32 with 32KB clusters (Volume Label: $VOL_LABEL)..."
    mkfs.vfat -F 32 -s 64 -n "$VOL_LABEL" "$PART"
else
    echo "[-] Unknown filesystem: $FS_TYPE" >&2
    exit 5
fi

# Step 7: Write & Data Integrity Benchmark (Optional)
if [ "$PERFORM_TEST" = true ]; then
    echo "[*] Verifying write performance and data integrity (50 MiB payload)..."
    TEST_MNT="/tmp/sd_test_mnt_$$"
    mkdir -p "$TEST_MNT"
    mount "$PART" "$TEST_MNT"

    TEST_SRC="/tmp/sd_src_sample_$$.bin"
    dd if=/dev/urandom of="$TEST_SRC" bs=1M count=50 status=none
    SRC_MD5=$(md5sum "$TEST_SRC" | awk '{print $1}')

    START_TIME=$(date +%s%N)
    dd if="$TEST_SRC" of="$TEST_MNT/verify.bin" bs=1M count=50 conv=fsync status=none
    END_TIME=$(date +%s%N)

    DEST_MD5=$(md5sum "$TEST_MNT/verify.bin" | awk '{print $1}')

    ELAPSED_NS=$((END_TIME - START_TIME))
    if [ "$ELAPSED_NS" -gt 0 ]; then
        SPEED_MB_S=$(awk -v ns="$ELAPSED_NS" 'BEGIN { printf "%.2f", (50 / (ns / 1000000000)) }')
    else
        SPEED_MB_S="N/A"
    fi

    rm -f "$TEST_MNT/verify.bin" "$TEST_SRC"
    umount "$TEST_MNT"
    rmdir "$TEST_MNT"

    if [ "$SRC_MD5" != "$DEST_MD5" ]; then
        echo "[-] FATAL: Checksum mismatch! Flash NAND cells may be corrupted or failing." >&2
        exit 6
    fi

    echo "[+] Benchmark Result: Write Speed ~${SPEED_MB_S} MB/s | MD5 Integrity: 100% MATCH"
fi

echo "=========================================================="
echo "[+] SUCCESS: Card $DEV is fully unlocked and ready to use!"
echo "    Partition:  $PART"
echo "    Filesystem: $FS_TYPE (Label: $VOL_LABEL)"
echo "    Alignment:  4 MiB Boundary"
echo "=========================================================="
