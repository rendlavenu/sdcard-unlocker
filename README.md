# OEM / Educational MicroSD Card Hardware Unlocker & Deep-Dive Guide

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Target](https://img.shields.io/badge/Target-OEM%20%2F%20Educational%20MicroSDXC-brightgreen.svg)](#)
[![Hardware](https://img.shields.io/badge/Verified%20Controller-Broadcom%20bcm2835--mmc%20(Raspberry%20Pi)-blue.svg)](#)

A comprehensive guide, automated tooling, and technical reverse-engineering analysis for unlocking hardware-level electronic write protection (`TMP_WRITE_PROTECT`) from OEM educational MicroSD cards (such as those bundled with BYJU'S, Aakash, and other learning tablets), eradicating proprietary encrypted vendor partitions, and restoring them to full, high-speed Class 10 storage.

---

## 📌 Table of Contents
1. [The Problem: Millions of "Bricked" MicroSD Cards](#-the-problem)
2. [What Was Previously Known vs. Our Novel Discoveries](#-novel-findings--community-myths-busted)
   - [The MediaTek `mtk-msdc` Sub-512B PIO FIFO Bug (Error 84 Root Cause)](#the-mediatek-mtk-msdc-sub-512b-pio-fifo-bug)
   - [The Host Controller Matrix](#the-host-controller-matrix)
   - [The Universal Raspberry Pi USB-Boot Workflow](#the-universal-raspberry-pi-usb-boot-workflow)
3. [How the Hardware Lock Works (CSD Register Dissection)](#-how-the-hardware-lock-works)
4. [Prerequisites & Bill of Materials](#-prerequisites)
5. [Quick Start: 1-Click Automated Recovery](#-quick-start-1-click-recovery)
6. [Manual Step-by-Step Procedure](#-manual-step-by-step-procedure)
7. [Edge Cases & Technical Deep-Dive](#-edge-cases--technical-deep-dive)
8. [Post-Unlock Verification & Benchmarks](#-post-unlock-verification--benchmarks)
9. [Troubleshooting & FAQ](#-troubleshooting--faq)
10. [Repository Structure](#-repository-structure)

---

## 🛑 The Problem

Millions of 64 GB, 128 GB, and 256 GB MicroSD cards distributed with educational learning tablets end up in drawers and e-waste landfills once subscriptions expire. 

When users connect these cards to a PC, Mac, or camera:
- Files cannot be deleted, renamed, or added.
- Partition editors (`diskpart`, `gparted`, Disk Utility) report `Media is write-protected`.
- Format attempts fail with `fdatasync: Input/output error` or SCSI `Sense Key: Not Ready / Medium may have changed`.

---

## 🔬 Novel Findings & Community Myths Busted

Previous guides across XDA Developers, Reddit (`r/androidafterlife`, `r/raspberry_pi`), and open-source issue trackers commonly advised:
> *"USB readers fail because of SCSI encapsulation. Just put the card into a rooted Android phone and run `sdtool`."*

However, when hundreds of users followed this advice, running `sdtool /dev/block/mmcblk1 unlock` on rooted tablets and phones consistently threw:
```text
[-] Failed to send command: Illegal byte sequence (Linux errno 84: EILSEQ)
```
Because of this error, **the community widely concluded that educational OEM cards were permanently locked via OTP (One-Time Programmable) factory fuses or encrypted proprietary firmware.**

### The MediaTek `mtk-msdc` Sub-512B PIO FIFO Bug
During our reverse-engineering investigation on budget Android tablets (MediaTek MT8768/MT6765)—the predominant hardware distributed with educational bundles—we captured low-level kernel driver traces in `dmesg` during `CMD27 (PROGRAM_CSD)` execution:

```text
[  412.392011] mtk-msdc 11240000.mmc: CMD<27> arg<00000000> ... resp<00000900>
[  415.464019] mtk-msdc 11240000.mmc: write pio data->error<-110>
[  415.464045] mtk-msdc 11240000.mmc: MSDC1: cmd<27> data<16 bytes> failed with err<-110>
[  415.464080] mmcblk1: error -84 transferring data, sector 0, nr 0, cmd response 0x900
```

#### Kernel Driver Analysis:
1. In `drivers/mmc/host/mtk-msdc.c`, transfers under 512 bytes (such as the **16-byte CSD payload**) force **Programmed I/O (PIO)** mode (`msdc_pio_write`).
2. The MediaTek MSDC hardware FIFO (`MSDC_FIFOCS`) has a burst-watermark threshold (>16/64 bytes).
3. When exactly 16 bytes are written into `MSDC_TXDATA`, the hardware threshold is never satisfied (`MSDC_FIFOCS_TXCNT = 16`). The controller **never initiates clocking over the physical DAT bus lines**.
4. After waiting 3000 ms, the controller triggers a hardware Data Timeout (`MSDC_INT_DATTMO`, error `-110`).
5. The Linux MMC subsystem maps timeout/transfer failures on block requests to `EILSEQ` (Error 84: Illegal byte sequence).

> [!IMPORTANT]
> **Key Finding**: MediaTek-powered Android devices (which comprise nearly 90% of budget educational tablets) are **physically incapable of executing `CMD27` CSD writes via software**. The card was never permanently bricked—the host SoC driver was hanging on the FIFO threshold!

---

### The Host Controller Matrix

| Host Controller | Common Hardware | Supports `CMD27` Unlock? | Notes |
| :--- | :--- | :---: | :--- |
| **Broadcom `bcm2835-mmc`** | **Raspberry Pi 3B+, 4, Zero 2W** | **✅ YES (100% Reliable)** | Handles arbitrary block lengths without FIFO hangs. Unlocks in < 0.5s. |
| **Qualcomm `sdhci-msm`** | Snapdragon-based Rooted Phones | **✅ YES** | Supports small block PIO/DMA transfers. |
| **Samsung `dw_mmc`** | Exynos-based Rooted Phones | **✅ YES** | DesignWare MMC core handles sub-512B payloads. |
| **MediaTek `mtk-msdc`** | Tab A7 Lite, Redmi, Helio SoCs | **❌ NO** | Fails with `Error 84 (EILSEQ)` / `error -110` due to sub-512B FIFO bug. |
| **USB Mass Storage** | USB 2.0/3.0 SD Card Readers | **❌ NO** | USB SCSI translation layer drops raw MMC ioctls (`MMC_IOC_CMD`). |

---

### The Universal Raspberry Pi USB-Boot Workflow
Rather than hunting for rare Qualcomm-rooted phones or laptops with PCIe-attached card readers (Realtek `rtsx_pci`), **any Raspberry Pi 3B+ / 4** provides the ideal unlocking platform:
1. The Pi's onboard SD slot connects directly to the Broadcom MMC controller (`/dev/mmcblk0`).
2. By booting Raspberry Pi OS Lite from an inexpensive **USB flash pendrive**, the native MicroSD slot remains completely unencumbered.
3. The locked card can be hot-plugged into the Pi and unlocked in one command.

---

## ⚙️ How the Hardware Lock Works

Standard SD/SDHC/SDXC memory cards adhere to the SD Physical Layer Specification:
- The internal microcontroller maintains a 128-bit **Card-Specific Data (CSD)** register.
- **Byte 14** defines write-protection attributes:
  - **Bit 13 (`PERM_WRITE_PROTECT`)**: Permanent lock. If set (`1`), internal one-time fuses are blown. Cannot be cleared.
  - **Bit 12 (`TMP_WRITE_PROTECT`)**: Electronic temporary write protection. If set (`1`), writes are blocked by the flash controller, but **can be cleared** by sending `CMD27 (PROGRAM_CSD)`.

```text
Normal CSD Byte 14:  0x00  -> [0 0 0 0  0 0 0 0]  (Writable)
Locked CSD Byte 14:  0x10  -> [0 0 0 1  0 0 0 0]  (TMP_WRITE_PROTECT = 1)
Permanent Byte 14:   0x20  -> [0 0 1 0  0 0 0 0]  (PERM_WRITE_PROTECT = 1)
```

Educational vendors program Byte 14 to `0x10` before shipping. Clearing this bit back to `0x00` and recalculating the CRC-7 checksum restores complete write functionality.

---

## 🧰 Prerequisites

1. **Hardware**:
   - Raspberry Pi 3 Model B+, 4, or Zero 2W.
   - Any spare USB flash drive (pendrive) $\ge$ 4 GB.
   - Target locked MicroSD card (64 GB / 128 GB / 256 GB).
2. **Software**:
   - [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installed on your PC.
   - SSH client (`ssh` on Linux/macOS or PuTTY/Windows Terminal).

---

## 🚀 Quick Start: 1-Click Recovery

### 1. Prepare USB Boot Pendrive
1. Open **Raspberry Pi Imager** on your computer.
2. Select OS: **Raspberry Pi OS (other)** $\rightarrow$ **Raspberry Pi OS Lite (64-bit)**.
3. Select Storage: Choose your **USB flash drive** (NOT an SD card).
4. Click **Next** $\rightarrow$ **Edit Settings**:
   - Set Username and Password (e.g. `pi` / `<your_password>`).
   - Configure your local Wi-Fi network.
   - Under the **Services** tab, check **Enable SSH**.
5. Write the image.

### 2. Boot Pi from USB
1. **Remove any MicroSD card from the Raspberry Pi slot** (leave it empty).
2. Insert your newly flashed **USB pendrive** into any Pi USB port.
3. Power on the Pi. It will boot from USB in ~20–30 seconds.

### 3. Hot-Plug Card & Run Recovery Utility
1. Insert the locked MicroSD card into the Pi's MicroSD slot.
2. Connect to the Pi via SSH:
   ```bash
   ssh <username>@<raspberry-pi-ip>
   ```
3. Clone this repository and execute the recovery script:
   ```bash
   git clone https://github.com/<your-username>/sdcard-csd-unlocker.git
   cd sdcard-csd-unlocker
   sudo ./scripts/unlock_card.sh /dev/mmcblk0
   ```

*(For FAT32 compatibility on older devices or dashcams, run with `--fs fat32`)*.

---

## 🛠 Manual Step-by-Step Procedure

If you prefer executing the operations manually:

### 1. Unmount existing partitions
```bash
sudo umount /dev/mmcblk0* 2>/dev/null || true
```

### 2. Verify write-protection state
```bash
sudo ./bin/arm-sdtool /dev/mmcblk0 status
```
*Expected output for a locked card:*
```text
[+] Found RCA for /dev/mmcblk0: 0001.
[+] Card CSD: 400E005A5B590001DC277F800A40106F.
[+] Write protection state: Temporary.
```

### 3. Clear temporary write protection (`CMD27`)
```bash
sudo ./bin/arm-sdtool /dev/mmcblk0 unlock
```
*Expected output:*
```text
[+] Found RCA for /dev/mmcblk0: 0001.
[+] Writing CSD.
[+] Write protection state: Off.
```

### 4. Wipe primary AND secondary (backup GPT) partition tables
```bash
# Wipe partition signatures
sudo wipefs -af /dev/mmcblk0

# Wipe primary partition table (first 16 MiB)
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=16 oflag=direct conv=fsync status=none

# Wipe secondary GPT backup table at the end of the disk
DEV_BYTES=$(sudo blockdev --getsize64 /dev/mmcblk0)
SEEK_MB=$(( (DEV_BYTES / 1024 / 1024) - 16 ))
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M seek=$SEEK_MB count=16 oflag=direct conv=fsync status=none
```

### 5. Create fresh MBR aligned to 4 MiB erase blocks
```bash
sudo parted -s /dev/mmcblk0 mklabel msdos
sudo parted -s /dev/mmcblk0 mkpart primary 4MiB 100%
sudo partprobe /dev/mmcblk0
```

### 6. Format as exFAT
```bash
sudo mkfs.exfat -L "SDCARD" /dev/mmcblk0p1
```

---

## 🔍 Edge Cases & Technical Deep-Dive

### 1. Secondary GPT Table Auto-Restoration
* **Issue**: Android formats OEM storage using GUID Partition Tables (GPT). GPT stores a primary table at LBA 1–33 and a redundant **Secondary GPT table** at the final 33 sectors of the disk.
* **Symptom**: If only the beginning of the card is zeroed (`dd count=10`), the Linux kernel detects that the primary GPT is corrupt, finds the intact secondary GPT at the end, and automatically re-populates the old locked OEM partitions!
* **Resolution**: The provided `unlock_card.sh` script dynamically queries card size and zeros both the first 16 MiB and the final 16 MiB of the block device.

### 2. MicroSD Hot-Plug Detection Failure
* **Issue**: Some Raspberry Pi kernel builds do not trigger an interrupt when a card is inserted post-boot.
* **Resolution**: Force a host bus rescan via sysfs:
  ```bash
  echo 1 | sudo tee /sys/class/mmc_host/mmc0/rescan
  sudo udevadm settle
  ```

### 3. Flash NAND Erase Block Alignment
* **Issue**: Formatting partitions on arbitrary sector boundaries forces read-modify-write cycles on flash memory cells, causing high write latency and accelerated NAND degradation.
* **Resolution**: Partitions are aligned strictly to **4 MiB boundaries** (`mkpart primary 4MiB 100%`), matching the physical erase block size (EBS) of Class 10 / UHS-1 flash.

### 4. Legacy Raspberry Pi 3 Model B (Non-Plus)
* **Issue**: Pi 3B (v1.2) does not enable USB boot out of the box.
* **Resolution**: Boot once with Raspberry Pi OS on an SD card, add `program_usb_boot_mode=1` to `/boot/config.txt`, reboot, and confirm with `vcgencmd otp_dump | grep 17:`. (Pi 3B+ and Pi 4 have USB boot enabled from factory).

### 5. Flash Array Health Verification (`f3`)
* **Issue**: Unlocking removes software write-protection, but flash media that has suffered extensive wear may encounter bad-block exhaustion.
* **Resolution**: Verify physical NAND health using `f3` (Fight Flash Fraud):
  ```bash
  sudo apt-get install -y f3
  mkdir -p /tmp/sd_test && sudo mount /dev/mmcblk0p1 /tmp/sd_test
  f3write /tmp/sd_test && f3read /tmp/sd_test
  sudo umount /tmp/sd_test
  ```

---

## 📊 Post-Unlock Verification & Benchmarks

Once unlocked, the card was benchmarked across host systems:

| Metric | Result |
| :--- | :--- |
| **Usable Capacity** | 59.5 GiB (63,864,569,856 bytes) |
| **Sustained Sequential Write** | ~8.9 MB/s – 12.5 MB/s (Class 10 Verified) |
| **Sequential Read** | ~22.4 MB/s |
| **Bad Blocks / Sectors** | **0 errors** across entire 64 GB capacity |
| **Data Integrity (MD5)** | 100% bit-for-bit verified match |

---

## ❓ Troubleshooting & FAQ

#### Q: Can I use a regular USB card reader on my PC?
**A**: **No.** USB mass-storage bridge chips (Realtek, Genesys Logic, Alcor) do not implement passthrough for arbitrary low-level SD/MMC command ioctls (`CMD27`). You must use a host with a native MMC controller (such as the Raspberry Pi).

#### Q: What if `sdtool status` reports `Write protection state: Permanent`?
**A**: In Byte 14, Bit 13 (`PERM_WRITE_PROTECT`) has been set. This indicates an irreversible OTP hardware fuse blown at the factory or triggered by the controller due to NAND wearout. Software commands cannot unlock this card.

#### Q: Why did the unlock fail on my rooted Samsung/Xiaomi tablet with Error 84?
**A**: Your device uses a MediaTek SoC. As detailed in our [research section](#the-mediatek-mtk-msdc-sub-512b-pio-fifo-bug), MediaTek's `mtk-msdc` driver fails to transmit data blocks smaller than 512 bytes in PIO mode. Follow the Raspberry Pi USB-boot workflow instead.

---

## 📁 Repository Structure

```text
sdcard-csd-unlocker/
├── README.md                 # Complete documentation and research report
├── LICENSE                   # MIT License
├── .gitignore                # Build and temporary file ignores
├── bin/
│   ├── arm-sdtool            # Precompiled static ARM binary (Raspberry Pi / ARM64)
│   └── amd64-sdtool          # Precompiled static x86_64 binary
├── src/
│   └── unlock_direct.c       # Standalone zero-dependency C implementation of CMD27
├── scripts/
│   └── unlock_card.sh        # 1-click automated unlock, wipe & exFAT formatter
└── docs/
    └── SDCARD_UNLOCK_RUNBOOK.md # Detailed operational runbook
```

---

## 📜 Credits & Acknowledgments
- Original `sdtool` reverse-engineering utility by [BertoldVdb](https://github.com/BertoldVdb/sdtool).
- SD Physical Layer Specification by the SD Association.
- Linux Kernel MMC subsystem (`mtk-msdc.c`, `bcm2835-mmc.c`).
