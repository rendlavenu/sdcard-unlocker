# OEM / Educational MicroSD Card Unlock & Recovery Runbook

A production-grade, reproducible runbook for removing hardware electronic write protection (`TMP_WRITE_PROTECT`) from locked OEM and educational MicroSD cards (64GB / 128GB / 256GB), wiping proprietary OEM partition tables, and restoring full, high-speed storage.

---

## 1. Technical Architecture & Lock Mechanism

Educational tablet distributors protect their preloaded course cards using low-level SD/MMC hardware register flags:

* **The Lock Mechanism**: The card's internal flash controller holds a 128-bit **Card-Specific Data (CSD)** register.
  * Normal writable card: Byte 14 has value `0x00`.
  * Locked OEM card: Byte 14 has value `0x10` (`00010000b`), where Bit 12 (`TMP_WRITE_PROTECT`) is enabled.
* **Why USB Card Readers Fail**:
  * USB card readers communicate via USB Mass Storage (SCSI emulation).
  * USB bridge controllers (Realtek, Genesys, Alcor) drop low-level SD bus commands (`MMC_IOC_CMD`, `CMD27 PROGRAM_CSD`).
  * Any format attempt throws `Sense Key: Not Ready` or `fdatasync: Input/output error`.
* **Why MediaTek Android Devices Fail**:
  * Budget tablets run MediaTek SoCs (MT8768, MT6765, Helio P22T) using the `mtk-msdc` driver.
  * For block transfers under 512 bytes (such as the 16-byte CSD payload), MediaTek's driver forces Programmed I/O (PIO) mode.
  * The hardware FIFO watermark is never reached on a 16-byte write (`MSDC_FIFOCS_TXCNT = 16`). Transmission across physical DAT lines never asserts.
  * After 3000 ms, the controller times out (`MSDC_INT_DATTMO` error `-110`), returning `EILSEQ` (Error 84: Illegal byte sequence).
* **Why the Raspberry Pi Works**:
  * The Raspberry Pi (3B+, 4, Zero 2W) uses a native **Broadcom SDHCI controller** (`bcm2835-mmc`) connected directly to the MicroSD slot.
  * It supports arbitrary block-size command transfers (`CMD27`) natively without FIFO hangs.

---

## 2. Requirements & Bill of Materials

1. **Host Board**: Raspberry Pi 3 Model B+, 4, or Zero 2W.
2. **Boot Media**: Any spare USB flash drive (pendrive) $\ge$ 4GB flashed with **Raspberry Pi OS Lite (64-bit)**.
3. **Network**: Local Wi-Fi or Ethernet connection to access the Pi via SSH.
4. **Target Card**: Any locked OEM MicroSD card (where CSD Byte 14 has `TMP_WRITE_PROTECT` set).

---

## 3. Preparation: Setting Up the USB Boot Drive

If you already have a USB boot drive, skip to Section 4.

### Flashing with Raspberry Pi Imager:
1. Open **Raspberry Pi Imager** on your computer.
2. **Device**: Select your Raspberry Pi model (e.g., `Raspberry Pi 3` or `Raspberry Pi 4`).
3. **OS**: Choose `Raspberry Pi OS (other)` $\rightarrow$ `Raspberry Pi OS Lite (64-bit)`.
4. **Storage**: Select your **USB flash drive** (NOT a MicroSD card).
5. Click **Next** $\rightarrow$ **Edit Settings**:
   * Set Username and Password (e.g. `pi` / `<your_secure_password>`).
   * Check **Configure wireless LAN** and enter your local Wi-Fi credentials.
   * Under the **Services** tab, check **Enable SSH** (Use password authentication or SSH public key).
6. Click **Save** and **Write**.

---

## 4. Execution Workflow

### Step 1: Boot Raspberry Pi from USB
1. Disconnect power from the Raspberry Pi.
2. **Remove any MicroSD card from the Pi's slot** (leave the slot completely empty).
3. Insert your **USB boot pendrive** into any USB port on the Pi.
4. Connect power. The Pi will boot from the USB drive within 20–30 seconds.

### Step 2: Insert the Locked MicroSD Card
1. Once the Pi is online and connected to your network, insert the **locked MicroSD card** into the Pi's onboard slot.
2. The card is hot-pluggable and will register as `/dev/mmcblk0`.

### Step 3: Run the Automated Recovery Script
SSH into the Pi:
```bash
ssh <username>@<pi_ip_or_hostname>
```

Clone the repository and run the automated unlock script:
```bash
git clone https://github.com/<your-username>/sdcard-csd-unlocker.git
cd sdcard-csd-unlocker
sudo ./scripts/unlock_card.sh /dev/mmcblk0
```

*(Alternatively, to format as FAT32 for older devices: `sudo ./scripts/unlock_card.sh --fs fat32 /dev/mmcblk0`)*

---

## 5. Manual Step-by-Step Commands

If you prefer running commands manually:

### 1. Unmount any active partition:
```bash
sudo umount /dev/mmcblk0* 2>/dev/null || true
```

### 2. Verify write-protection status:
```bash
sudo ./bin/arm-sdtool /dev/mmcblk0 status
```
*Expected Output for a locked card:*
```text
[+] Found RCA for /dev/mmcblk0: 0001.
[+] Card CSD: 400E005A5B590001DC277F800A40106F.
[+] Write protection state: Temporary.
```

### 3. Clear the write protection (`CMD27`):
```bash
sudo ./bin/arm-sdtool /dev/mmcblk0 unlock
```
*Expected Output:*
```text
[+] Found RCA for /dev/mmcblk0: 0001.
[+] Writing CSD.
[+] Write protection state: Off.
```

### 4. Wipe primary AND secondary (backup GPT) partition tables:
```bash
# Wipe filesystem signatures
sudo wipefs -af /dev/mmcblk0

# Wipe primary partition table (first 16 MiB)
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=16 oflag=direct conv=fsync status=none

# Wipe secondary GPT backup table at the end of the disk
DEV_BYTES=$(sudo blockdev --getsize64 /dev/mmcblk0)
SEEK_MB=$(( (DEV_BYTES / 1024 / 1024) - 16 ))
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M seek=$SEEK_MB count=16 oflag=direct conv=fsync status=none
```

### 5. Create fresh MBR with 4 MiB erase-block alignment:
```bash
sudo parted -s /dev/mmcblk0 mklabel msdos
sudo parted -s /dev/mmcblk0 mkpart primary 4MiB 100%
sudo partprobe /dev/mmcblk0
```

### 6. Format as exFAT:
```bash
sudo mkfs.exfat -L "SDCARD" /dev/mmcblk0p1
```

---

## 6. Edge Cases & Technical Mitigations

### Edge Case 1: Card Not Detected on Hot-Plug
* **Symptom**: `/dev/mmcblk0` does not appear after inserting the card while the Pi is booted.
* **Mitigation**: Manually trigger an MMC bus rescan:
  ```bash
  echo 1 | sudo tee /sys/class/mmc_host/mmc0/rescan
  sudo udevadm settle
  lsblk
  ```

### Edge Case 2: Ghost Partitions Reappearing (Secondary GPT Restoration)
* **Symptom**: After partitioning and formatting, previous OEM partitions reappear upon re-inserting the card.
* **Cause**: Android OEM tables use GPT. Wiping only the start of the card leaves the Secondary GPT header intact at the end of the disk, prompting the Linux kernel to restore corrupt partition tables.
* **Mitigation**: Always wipe both the first 16 MiB and the last 16 MiB of the block device using `wipefs -af` and `dd` seek as demonstrated in Section 5.

### Edge Case 3: Permanent Write-Protection (`PERM_WRITE_PROTECT`)
* **Symptom**: `sdtool status` returns `Write protection state: Permanent` (Byte 14 Bit 13 is `1`, e.g. `0x20` or `0x30`).
* **Root Cause**: The physical OTP fuse inside the flash controller has been blown, or the NAND controller entered permanent write-lock due to bad-block exhaustion.
* **Mitigation**: This is an irreversible hardware state. Software commands cannot unlock this card; it can only function as read-only media.

### Edge Case 4: Raspberry Pi 3 Model B (Non-Plus) USB Boot
* **Symptom**: Older Raspberry Pi 3 Model B boards (v1.2) do not boot from USB by default.
* **Mitigation**: Enable USB boot mode once via OTP by booting Raspberry Pi OS from an SD card, adding `program_usb_boot_mode=1` to `/boot/config.txt`, rebooting, and verifying with `vcgencmd otp_dump | grep 17:`. (Raspberry Pi 3B+ and Pi 4 support USB boot by default).

### Edge Case 5: Flash Cell Degradation / Bad Blocks Verification
* **Symptom**: The card unlocks successfully, but large file transfers crash or hang after several gigabytes.
* **Mitigation**: Verify the true health of the NAND flash array using `f3` (Fight Flash Fraud):
  ```bash
  sudo apt-get install -y f3
  mkdir -p /tmp/sd_test && sudo mount /dev/mmcblk0p1 /tmp/sd_test
  f3write /tmp/sd_test
  f3read /tmp/sd_test
  sudo umount /tmp/sd_test
  ```

---

## 7. Reassembly Checklist

1. Safely power down the Pi:
   ```bash
   sudo poweroff
   ```
2. Unplug power, remove the unlocked MicroSD card, and insert it into your phone, tablet, camera, or PC.
3. Verify that the operating system displays the expected capacity (~59.5 GiB for a 64GB card) and formats without errors.
4. If your Pi is used for Pi-hole or Home Assistant, re-insert your primary SD card and power the Pi back on.
