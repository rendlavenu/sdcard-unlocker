# MicroSD Lock Mechanism & Kernel Driver Analysis

Technical breakdown of the electronic write-protection mechanism (`TMP_WRITE_PROTECT`), the MediaTek host controller FIFO bug (`mtk-msdc`), and hardware register telemetry.

---

## 1. CSD Register Architecture: Permanent vs. Temporary Lock

Standard SD/SDHC/SDXC flash cards implement a 128-bit internal **Card-Specific Data (CSD)** register. Write protection attributes are defined in **Byte 14**:

```text
Normal Writable Card:    Byte 14 = 0x00  -> [0 0 0 0  0 0 0 0]  (Fully Writable)
Temporary Locked Card:   Byte 14 = 0x10  -> [0 0 0 1  0 0 0 0]  (Bit 12: TMP_WRITE_PROTECT = 1)
Permanent Locked Card:   Byte 14 = 0x20  -> [0 0 1 0  0 0 0 0]  (Bit 13: PERM_WRITE_PROTECT = 1)
```

* **Bit 13 (`PERM_WRITE_PROTECT`)**: Irreversible hardware one-time programmable (OTP) fuse. Once blown, software commands cannot unlock the card.
* **Bit 12 (`TMP_WRITE_PROTECT`)**: Electronic temporary write protection flag. Software writes can be blocked or unblocked using SD bus command **`CMD27 (PROGRAM_CSD)`**.

Educational content providers (BYJU'S, Aakash, Allen) program Byte 14 to `0x10` before distribution to prevent students from overwriting course content. Reprogramming this byte to `0x00` and recalculating the CRC-7 checksum restores the card to a standard writable Class 10 device.

---

## 2. Why MediaTek Android Devices Fail (`Error 84 / EILSEQ`)

Previous community guides suggested running `sdtool` on rooted Android tablets. However, on MediaTek-powered tablets (such as Samsung Galaxy Tab A7 Lite `SM-T220` or Lenovo Tab M8), `sdtool` consistently aborts with:

```text
[-] Failed to send command: Illegal byte sequence (Linux errno 84: EILSEQ)
```

### Kernel Driver Trace Analysis (`dmesg`)
Tracing the MediaTek MMC host driver (`drivers/mmc/host/mtk-msdc.c`) during `CMD27` execution reveals the hardware cause:

```text
[  412.392011] mtk-msdc 11240000.mmc: CMD<27> arg<00000000> ... resp<00000900>
[  415.464019] mtk-msdc 11240000.mmc: write pio data->error<-110>
[  415.464045] mtk-msdc 11240000.mmc: MSDC1: cmd<27> data<16 bytes> failed with err<-110>
[  415.464080] mmcblk1: error -84 transferring data, sector 0, nr 0, cmd response 0x900
```

### The Sub-512B PIO FIFO Bug:
1. In `mtk-msdc.c`, block transfers smaller than 512 bytes (such as the 16-byte CSD payload) bypass DMA and force **Programmed I/O (PIO)** mode (`msdc_pio_write`).
2. The MediaTek MSDC hardware FIFO (`MSDC_FIFOCS`) requires a minimum burst-watermark threshold (>16 bytes) before asserting data transmission over the physical bus.
3. When exactly 16 bytes are written into `MSDC_TXDATA`, the hardware threshold is never reached (`MSDC_FIFOCS_TXCNT = 16`).
4. The controller **never clocks data over physical DAT lines**. After 3000 ms, the hardware triggers a Data Timeout (`MSDC_INT_DATTMO` error `-110`).
5. The Linux MMC core translates block transfer timeouts to `EILSEQ` (Error 84: Illegal byte sequence).

> [!IMPORTANT]
> The card is **not bricked**. MediaTek host controllers are simply physically incapable of completing sub-512B CSD write transfers due to this silicon/driver FIFO threshold bug.

---

## 3. Target Card Identification & OEM Fingerprints

### Physical Markings (Gold Pin Side)
* **Form Factor**: MicroSDXC Class 10 U1 (64 GB, 128 GB, 256 GB).
* **Rear Laser Etchings**:
  * Line 1 (Batch): `3A2236HIA` (or `3A21...`, `3A22...`)
  * Line 2 (Wafer Code): `CMH36A031MA6311`
  * Origin: Made in Taiwan / OEM assembly.

### Associated Tablet Hardware
* **Samsung Galaxy Tab A7 Lite** (`SM-T220` Wi-Fi / `SM-T225` LTE)
* **Lenovo Tab M8 HD / FHD** (`TB-8505X`, `TB-8505F`, `TB-8705F`)
* **Lenovo Tab M10 / M10 Plus** (`TB-X505X`, `TB-X606V`)
* **Lava & Wishtel OEM Educational Tablets**

### Electronic Register Telemetry (`/sys/bus/mmc/devices/mmc*:0001/`)

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
