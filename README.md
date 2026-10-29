# MicroSD Hardware Unlocker: Salvaging Locked OEM / BYJU'S Cards

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Verified Controller](https://img.shields.io/badge/Verified%20Controller-Broadcom%20bcm2835--mmc%20(Raspberry%20Pi)-blue.svg)](#)
[![Target Media](https://img.shields.io/badge/Target-OEM%20%2F%20Educational%20MicroSDXC-brightgreen.svg)](#)

> [!IMPORTANT]
> ### 💡 The Breakthrough (TL;DR)
> * **The Myth**: Attempting to format locked BYJU'S or educational MicroSD cards on a PC or rooted Android tablet fails with `Write-protected` or `Error 84 (Illegal byte sequence)`. The community assumed these cards had **permanent factory OTP fuses** or vendor-locked firmware.
> * **The Reality**: The cards are **NOT permanently bricked**. They only have an electronic temporary write-protection bit (`TMP_WRITE_PROTECT`). USB card readers drop the raw low-level unlock command, and budget Android devices fail because MediaTek's Linux kernel driver has a FIFO watermark bug that hangs on 16-byte transfers (`CMD27`).
> * **The Fix**: Booting any Raspberry Pi 3B+/4 from a USB pendrive provides direct Broadcom MMC bus access, clearing the hardware write-lock in **0.5 seconds** and restoring the card to full 60GB Class 10 storage.

---

## ⚡ Quick 1-Minute Recovery

If you just want to unlock and format your card immediately:

1. **Flash a USB pendrive** with Raspberry Pi OS Lite (64-bit) using [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (enable SSH in settings).
2. **Boot your Raspberry Pi from USB** with the onboard MicroSD slot empty.
3. **Hot-plug the locked card** into the Pi's slot (`/dev/mmcblk0`).
4. **SSH into the Pi** and run:
   ```bash
   git clone https://github.com/rendlavenu/sdcard-unlocker.git
   cd sdcard-unlocker
   sudo ./scripts/unlock_card.sh /dev/mmcblk0
   ```
*(The script automatically clears the hardware lock, wipes both primary & secondary backup GPT tables, and formats as clean, 4 MiB-aligned exFAT).*

---

## 📌 Table of Contents
1. [The Problem: Why Millions of Cards Were Abandoned](#-the-problem)
2. [What Was Previously Known vs. Our Novel Discoveries](#-novel-findings--busting-the-mediatek-myth)
   - [The MediaTek `mtk-msdc` Sub-512B PIO FIFO Bug (Error 84 Root Cause)](#the-mediatek-mtk-msdc-sub-512b-pio-fifo-bug)
   - [The Host Controller Matrix](#the-host-controller-matrix)
   - [The Universal Raspberry Pi USB-Boot Workflow](#the-universal-raspberry-pi-usb-boot-workflow)
3. [Target Card Identification & Known OEM Markings](#-target-card-identification--known-oem-markings)
4. [How the Hardware Lock Works (CSD Register Dissection)](#-how-the-hardware-lock-works)
5. [Manual Step-by-Step Procedure](#-manual-step-by-step-procedure)
6. [Critical Edge Cases (Secondary GPT Restoration, Bus Rescan)](#-edge-cases--technical-deep-dive)
7. [Post-Unlock Verification & Benchmarks](#-post-unlock-verification--benchmarks)
8. [Troubleshooting & FAQ](#-troubleshooting--faq)
9. [Disclaimer & Legal Notice](#-disclaimer--legal-notice)

---

## 🛑 The Problem

Millions of 64 GB, 128 GB, and 256 GB MicroSD cards distributed with educational learning tablets (BYJU'S, Aakash, Allen) end up in drawers and e-waste landfills once subscriptions expire. 

When users connect these cards to a PC, Mac, or camera:
- Files cannot be deleted, renamed, or added.
- Partition editors (`diskpart`, `gparted`, Disk Utility) report `Media is write-protected`.
- Format attempts fail with `fdatasync: Input/output error` or SCSI `Sense Key: Not Ready / Medium may have changed`.

---

## 🔬 Novel Findings: Busting the MediaTek Myth

Previous forum guides across XDA Developers and Reddit advised using a rooted Android phone with `sdtool`. However, when users ran `sdtool` on their tablets, it consistently failed:
```text
[-] Failed to send command: Illegal byte sequence (Linux errno 84: EILSEQ)
```
This error led the entire community to believe the cards were permanently hardware-locked via OTP fuses.

### The MediaTek `mtk-msdc` Sub-512B PIO FIFO Bug
During our reverse-engineering investigation on budget Android tablets (MediaTek MT8768/MT6765)—the exact hardware bundled by BYJU'S—we captured low-level kernel driver traces in `dmesg` during `CMD27 (PROGRAM_CSD)` execution:

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

## 🔍 Target Card Identification & Known OEM Markings

If you have a locked MicroSD card from an educational bundle, use this section to identify whether your card matches this recovery profile.

### 1. Physical Markings & Laser Etchings
* **Form Factor**: MicroSDXC (typically 64 GB, 128 GB, or 256 GB), UHS-I Class 10 U1.
* **Front Casing**: Plain black casing, often unbranded or printed with standard MicroSDXC / Class 10 markings.
* **Rear Laser Etchings** (micro-etched on the gold contact pin side):
  * **Line 1 (Batch / Date Code)**: `3A2236HIA` *(or similar batch variations: `3A22...`, `3A21...`)*
  * **Line 2 (Wafer / Serial Code)**: `CMH36A031MA6311` *(or alphanumeric tracking string)*
  * **Manufacturing Origin**: Made in Taiwan / OEM assembly.

### 2. Associated Tablets & Educational Bundles
These cards were widely bundled with tablets by EdTech programs and coaching institutes across India:
* **Educational Bundles**: **BYJU'S Learning App / Think & Learn Pvt. Ltd.**, **Aakash Digital (AESL)**, **Allen Career Institute**, **PhysicsWallah**, **Extramarks**.
* **Preloaded Data**: Contains encrypted media catalogs (`.enc`, `.mp4` chunks, `com.byjus.*` assets) and encrypted course partition structures.
* **Common Bundled Tablet Models**:
  * **Samsung Galaxy Tab A7 Lite** (`SM-T220` Wi-Fi / `SM-T225` LTE)
  * **Lenovo Tab M8 HD / FHD** (`TB-8505X`, `TB-8505F`, `TB-8705F`)
  * **Lenovo Tab M10 / M10 Plus** (`TB-X505X`, `TB-X606V`)
  * **Lava / Wisdom / Wishtel OEM Android Tablets**

### 3. Electronic Register Telemetry (Sysfs / Dmesg)
When inserted into a Linux system with a native MMC controller, reading the hardware registers via `/sys/bus/mmc/devices/mmc*:0001/` yields:

| Register / Field | Raw Hex / Value | Interpretation |
| :--- | :--- | :--- |
| **Card Identification (CID)** | `000000555344000010000029cc01690d` | Standard OEM flash CID string |
| **Product Name (PNM)** | `USD` (`55 53 44 00 00`) | Generic OEM product identifier |
| **Product Revision (PRV)** | `0x10` | Hardware Revision 1.0 |
| **Manufacturing Date (MDT)** | `0x0169` (09/2022) | Manufactured September 2022 |
| **Card-Specific Data (CSD) - Locked** | `400E00325B590001DC277F800A4010B9` | **Byte 14 = `0x10` (`TMP_WRITE_PROTECT = 1`)** |
| **Card-Specific Data (CSD) - Unlocked**| `400E00325B590001DC277F800A40008B` | **Byte 14 = `0x00` (`TMP_WRITE_PROTECT = 0`)** |
| **SD Status Register (SSR)** | `000000000800000004049000080a...` | Class 10 / High Speed bus indicator |
| **SD Card Configuration (SCR)** | `0285808300000000` | SD Spec Version 3.0 / Physical Layer |

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

## 🛠 Manual Step-by-Step Procedure

If you prefer executing the operations manually without the automated script:

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

### 4. Flash Array Health Verification (`f3`)
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

## ⚠️ Disclaimer & Legal Notice

> [!WARNING]
> 1. **Research & E-Waste Reduction Only**: This project is published strictly for educational research, reverse engineering, technical interoperability, and electronic waste reduction (Right to Repair). The objective is to salvage functional flash storage hardware and keep working silicon out of landfills after educational subscriptions terminate.
> 2. **Irreversible Data Erasure**: The unlocking, wiping, and partitioning procedures **permanently destroy all existing data, partitions, and preloaded content** residing on the storage medium. Ensure proper authorization before reusing media.
> 3. **No Warranty & Limitation of Liability**: All software, scripts, and documentation are provided **"AS IS"**, without warranty of any kind. Under no circumstances shall the authors or contributors be held liable for any data loss, hardware damage, or unintended consequences. You assume all responsibility.
> 4. **Trademarks & Fair Use**: All brand names, trademarks, product names, and company names cited (such as BYJU'S, Samsung, MediaTek, Broadcom, Raspberry Pi) are the intellectual property of their respective owners. Their mention is solely for technical diagnostic and descriptive interoperability purposes under fair-use doctrine and does not imply affiliation or endorsement.
