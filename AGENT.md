# AI Assistant Guide & Repository Instructions

This document provides architectural context, hardware constraints, development guidelines, and safety rules for AI coding assistants (Claude Code, Antigravity, Cursor, Copilot, Windsurf) working on this repository.

---

## 1. Project Purpose & Core Domain

This repository contains tools, technical reverse-engineering documentation, and automation scripts to recover educational/OEM MicroSD cards (such as those bundled with BYJU'S, Aakash, and other learning tablets) that appear permanently "write-protected".

### The Core Problem
- Educational tablet vendors preload course material onto high-capacity MicroSD cards (64GB, 128GB, 256GB).
- Before distribution, vendors set the **`TMP_WRITE_PROTECT`** bit (Bit 12 of Byte 14 in the Card-Specific Data register, CSD) via SD bus command `CMD27 (PROGRAM_CSD)`.
- When users attempt to format or reuse these cards on Windows, macOS, or Linux using standard USB card readers, the card rejects write commands (`Sense Key: Not Ready` / `fdatasync: Input/output error`).

### Target Card Profile & Fingerprint
- **Form Factor**: 64GB / 128GB / 256GB MicroSDXC Class 10 U1.
- **Physical Markings**: Rear laser etchings on gold-pin side: `3A2236HIA` / `CMH36A031MA6311` (Made in Taiwan).
- **Bundled Ecosystems**: BYJU'S Learning App (Think & Learn), Aakash Digital, Allen, PhysicsWallah. Bundled with Samsung Galaxy Tab A7 Lite (`SM-T220`), Lenovo Tab M8/M10 (`TB-8505X`, `TB-X505X`), and Lava tablets.
- **CID Register**: `000000555344000010000029cc01690d` (Product Name: `USD`, Revision: `0x10`, Date: `09/2022`).
- **CSD Register**: Locked: `400E00325B590001DC277F800A4010B9` (Byte 14 = `0x10` -> `TMP_WRITE_PROTECT = 1`). Unlocked: `400E00325B590001DC277F800A40008B` (Byte 14 = `0x00`).

---

## 2. Fundamental Hardware Rules & Invariants (Never Violate)

When providing advice or writing code in this repository, always enforce these principles:

1. **Never Recommend External USB Card Readers or Internal USB Laptop Slots for Unlocking**:
   - USB card readers communicate via the USB Mass Storage class (SCSI encapsulation).
   - USB bridge controllers (Realtek, Genesys Logic, Alcor) **drop low-level MMC ioctls** (`MMC_IOC_CMD`, `CMD27`).
   - **Crucial Hardware Trap**: Built-in laptop SD slots are often wired internally to USB 2.0 rather than PCIe/SDHCI (e.g., Lenovo ThinkPad T480s uses `0bda:0316 Realtek Card Reader` over internal USB 2.0). These appear as `/dev/sdX` via `usb-storage` / `uas` and **will fail to unlock**.
   - Unlocking requires a host with a **native MMC/SD controller** exposed directly to the kernel MMC subsystem (e.g., Raspberry Pi Broadcom `bcm2835-mmc`, Qualcomm Snapdragon `sdhci-msm`, or PC PCIe Realtek `rtsx_pci`). Look for `/dev/mmcblk0`.

2. **Never Misdiagnose MediaTek `Error 84 (EILSEQ)` as a Bricked Card**:
   - When users try `sdtool` on budget Android devices (Samsung Galaxy Tab A7 Lite, Lenovo M8/M10, Xiaomi Redmi), it fails with:
     `[-] Failed to send command: Illegal byte sequence (errno 84: EILSEQ)`
   - **Root Cause**: MediaTek SoCs run `drivers/mmc/host/mtk-msdc.c`. For transfers under 512 bytes (such as the 16-byte CSD write payload), the driver forces Programmed I/O (`msdc_pio_write`). The MediaTek MSDC FIFO watermark is never reached on 16 bytes (`MSDC_FIFOCS_TXCNT = 16`), transmission never starts on the physical DAT lines, and the controller times out after 3000 ms (`MSDC_INT_DATTMO` error `-110`).
   - This is a **MediaTek host controller driver bug**, NOT a permanent hardware lock on the card. Do not tell users their card is ruined; direct them to the Raspberry Pi USB-boot workflow.

3. **Distinguish Permanent vs. Temporary Write Protection**:
   - In CSD Byte 14:
     - **Bit 13 (`PERM_WRITE_PROTECT`)**: Permanent OTP (One-Time Programmable) hardware fuse or controller bad-block exhaustion. **Irreversible by software.**
     - **Bit 12 (`TMP_WRITE_PROTECT`)**: Electronic temporary flag. **100% reversible via `CMD27`**.

4. **Always Erase Both Primary AND Secondary (Backup) GPT Tables**:
   - Android OEM tablets partition SD cards using GPT.
   - Wiping only the first few megabytes (`dd count=16`) leaves the **Secondary GPT table** intact at the very end of the disk.
   - When Linux boots or rescans, the kernel detects the backup GPT and automatically reconstructs the old locked OEM partitions!
   - Every wipe procedure must wipe **both** the first 16 MiB and the final 16 MiB of the disk (`wipefs -af`, plus `dd seek`).

5. **Maintain 4 MiB Erase Block Alignment**:
   - Flash NAND cells operate on erase blocks (typically 4 MiB or 16 MiB on Class 10 / UHS-1 media).
   - Misaligned partition boundaries degrade write speeds by 20–30% and accelerate flash wear.
   - Always partition with `mkpart primary 4MiB 100%`.

6. **Zero-Tolerance for Sensitive Information**:
   - Never commit or log real Wi-Fi credentials, passwords, private IP addresses (`192.168.x.x`), device serial numbers, or personal usernames/paths. Always use generic placeholders.

---

## 3. Repository Architecture

```text
sdcard_unlock/
├── README.md                 # Complete documentation, technical report & benchmarks
├── AGENT.md                  # Instructions for AI coding assistants (this file)
├── CLAUDE.md                 # Symlink / mirror for Claude Code compatibility
├── LICENSE                   # MIT License
├── .gitignore                # Git ignore filters
├── bin/
│   ├── arm-sdtool            # Precompiled static ARM binary (RPi 3B+/4/Zero 2W)
│   └── amd64-sdtool          # Precompiled static x86_64 binary
├── src/
│   └── unlock_direct.c       # Standalone zero-dependency C implementation of CMD27
├── scripts/
│   └── unlock_card.sh        # Automated unlock, wipe, and exFAT formatting script
└── docs/
    ├── HARDWARE_ANALYSIS.md      # MediaTek FIFO bug trace & CSD bit architecture
    └── SDCARD_UNLOCK_RUNBOOK.md  # Detailed operational runbook & partition procedures
```

### Component Details
* **`src/unlock_direct.c`**:
  - Standalone C source with zero external library dependencies (uses only standard Linux libc and `<linux/mmc/ioctl.h>`).
  - Reads CSD from sysfs (`/sys/block/<dev>/device/csd`).
  - Calculates CRC-7 checksum (standard polynomial $x^7 + x^3 + 1$, generator `0x09`).
  - Issues `CMD16` (SET_BLOCKLEN 16) followed by `CMD27` (PROGRAM_CSD) via `MMC_IOC_CMD`.
* **`scripts/unlock_card.sh`**:
  - Automated Bash recovery script.
  - Checks EUID (root), handles hot-plug detection/bus rescan (`/sys/class/mmc_host/mmc0/rescan`), verifies CSD status, clears temporary protection, wipes primary and secondary GPT tables, aligns to 4 MiB MBR, formats to exFAT or FAT32, and runs an MD5 50MB random write benchmark.

---

## 4. Build, Test & Validation Commands

### Compiling Standalone Tool:
```bash
# Standard dynamic build
gcc -Wall -Wextra -O2 src/unlock_direct.c -o src/unlock_direct

# Static build (for portable deployment to embedded Linux / Raspberry Pi)
gcc -static -Wall -Wextra -O2 src/unlock_direct.c -o bin/arm-sdtool && strip bin/arm-sdtool
```

### Validating Shell Scripts:
```bash
# Shell syntax validation
bash -n scripts/unlock_card.sh

# Shellcheck (if installed)
shellcheck scripts/unlock_card.sh
```

### Safe Device Testing:
```bash
# Inspect CSD status non-destructively
sudo ./src/unlock_direct --status /dev/mmcblk0

# Automated unlock dry-run / execution
sudo ./scripts/unlock_card.sh /dev/mmcblk0
```

---

## 5. Coding & Interaction Guidelines for AI Agents

1. **Be Concise & Technical**: Explain exact register values, ioctl parameters, and error codes (`EILSEQ`, `ETIMEDOUT`, `EPERM`).
2. **Warn Before Destructive Operations**: Always remind the user that partitioning and formatting operations irreversibly destroy all existing data on the target block device.
3. **Check Device Nodes**: Always prompt the user to double-check their device node (`/dev/mmcblk0` vs `/dev/sda`) to avoid accidentally wiping system boot drives.
4. **Preserve Disclaimers**: Maintain all legal, educational, and safety disclaimers in `README.md`, `unlock_card.sh`, and `unlock_direct.c`.
