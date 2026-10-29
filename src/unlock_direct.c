/*
 * unlock_direct.c - Standalone MicroSD CSD Register Unlocker
 *
 * Description:
 *   Clears TMP_WRITE_PROTECT (Bit 12 of CSD Byte 14) via SD Bus Command CMD27 (PROGRAM_CSD).
 *   Recalculates the CRC-7 checksum according to SD Physical Layer Specification.
 *   Designed for recovering OEM/educational write-protected cards (e.g. BYJU'S, Aakash)
 *   connected to a native MMC host controller (e.g. Broadcom bcm2835-mmc on Raspberry Pi).
 *
 * Author: Open Source Community
 * License: MIT
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <libgen.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <linux/types.h>
#include <linux/mmc/ioctl.h>

#define SD_SET_BLOCKLEN 16
#define SD_WRITE_CSD    27

#define MMC_COMMAND_ADTC      (1 << 5)
#define MMC_COMMAND_REPLY_R1  (1 | (1 << 2) | (1 << 4))
#define MMC_COMMAND_REPLY_R1B (MMC_COMMAND_REPLY_R1 | (1 << 3))

/* CRC-7 Calculation for SD CSD (Polynomial x^7 + x^3 + 1, standard generator 0x09) */
static uint8_t crc7_add_word(uint8_t crc, uint8_t word, uint8_t len) {
    for (uint8_t i = 0; i < len; i++) {
        uint8_t bit = ((word & 0x80) > 0);
        bit ^= (crc >> 6);
        if (bit) {
            crc ^= 0x04;
        }
        crc <<= 1;
        crc &= 0x7F;
        crc |= bit;
        word <<= 1;
    }
    return crc;
}

static uint8_t calc_csd_crc(const uint8_t *csd) {
    uint8_t crc = 0;
    for (int i = 0; i < 15; i++) {
        crc = crc7_add_word(crc, csd[i], 8);
    }
    return (crc << 1) | 1;
}

static int locate_csd_sysfs(const char *devpath, char *out_path, size_t max_len) {
    char base_dev[256];
    strncpy(base_dev, devpath, sizeof(base_dev) - 1);
    base_dev[sizeof(base_dev) - 1] = '\0';
    char *bname = basename(base_dev);

    /* Check canonical sysfs block path: /sys/block/<dev>/device/csd */
    snprintf(out_path, max_len, "/sys/block/%s/device/csd", bname);
    if (access(out_path, R_OK) == 0) return 0;

    /* Check sysfs class path: /sys/class/block/<dev>/device/csd */
    snprintf(out_path, max_len, "/sys/class/block/%s/device/csd", bname);
    if (access(out_path, R_OK) == 0) return 0;

    /* Check mmc bus devices */
    DIR *d = opendir("/sys/bus/mmc/devices");
    if (d) {
        struct dirent *dir;
        while ((dir = readdir(d)) != NULL) {
            if (dir->d_name[0] == '.') continue;
            snprintf(out_path, max_len, "/sys/bus/mmc/devices/%.128s/csd", dir->d_name);
            if (access(out_path, R_OK) == 0) {
                closedir(d);
                return 0;
            }
        }
        closedir(d);
    }

    return -1;
}

static void print_usage(const char *progname) {
    fprintf(stderr, "Usage: %s [options] <device_node>\n\n", progname);
    fprintf(stderr, "Disclaimer: For educational research and e-waste hardware recovery only.\n");
    fprintf(stderr, "            Provided AS-IS without warranty of any kind.\n\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --status      Inspect and print CSD write-protection bits only\n");
    fprintf(stderr, "  --unlock      Clear TMP_WRITE_PROTECT bit and reprogram CSD (Default)\n");
    fprintf(stderr, "  -h, --help    Show this help message\n\n");
    fprintf(stderr, "Example:\n");
    fprintf(stderr, "  sudo %s /dev/mmcblk0\n", progname);
    fprintf(stderr, "  sudo %s --status /dev/mmcblk0\n", progname);
}

int main(int argc, char *argv[]) {
    int check_only = 0;
    const char *devpath = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--status") == 0) {
            check_only = 1;
        } else if (strcmp(argv[i], "--unlock") == 0) {
            check_only = 0;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (argv[i][0] != '-') {
            devpath = argv[i];
        }
    }

    if (!devpath) {
        devpath = "/dev/mmcblk0";
    }

    printf("========================================================\n");
    printf("   MicroSD Hardware CSD Write-Protection Utility        \n");
    printf("========================================================\n");
    printf("[*] Target Device: %s\n", devpath);

    char csd_sysfs_path[512];
    if (locate_csd_sysfs(devpath, csd_sysfs_path, sizeof(csd_sysfs_path)) != 0) {
        fprintf(stderr, "[-] Error: Could not locate CSD sysfs attribute for '%s'.\n", devpath);
        fprintf(stderr, "    Ensure the card is inserted in a native MMC slot (/dev/mmcblkX),\n");
        fprintf(stderr, "    not an external USB card reader.\n");
        return 1;
    }

    FILE *f = fopen(csd_sysfs_path, "r");
    if (!f) {
        perror("[-] Error: Failed to open CSD sysfs path");
        return 1;
    }

    char hex_str[64] = {0};
    if (fscanf(f, "%32s", hex_str) != 1) {
        fprintf(stderr, "[-] Error: Failed to parse CSD hex string.\n");
        fclose(f);
        return 1;
    }
    fclose(f);

    uint8_t csd[16];
    for (int i = 0; i < 16; i++) {
        sscanf(&hex_str[i * 2], "%02hhx", &csd[i]);
    }

    printf("[+] Active CSD: %s\n", hex_str);
    printf("[+] CSD Byte 14: 0x%02X\n", csd[14]);

    int perm_wp = (csd[14] & 0x20) != 0;
    int temp_wp = (csd[14] & 0x10) != 0;

    printf("[+] Hardware Write Protection State:\n");
    printf("    * PERM_WRITE_PROTECT (Bit 13): %s\n", perm_wp ? "ENABLED (Locked)" : "Disabled (Writable)");
    printf("    * TMP_WRITE_PROTECT  (Bit 12): %s\n", temp_wp ? "ENABLED (Locked)" : "Disabled (Writable)");

    if (perm_wp) {
        fprintf(stderr, "\n[-] FATAL: PERM_WRITE_PROTECT is permanently active on this card.\n");
        fprintf(stderr, "    Permanent write-protection is an irreversible OTP hardware fuse.\n");
        fprintf(stderr, "    It CANNOT be unlocked via software or CSD commands.\n");
        return 2;
    }

    if (!temp_wp) {
        printf("\n[+] The card already has write-protection DISABLED!\n");
        printf("    No CSD modification required.\n");
        return 0;
    }

    if (check_only) {
        printf("\n[*] Check-only mode selected. Exiting without modifications.\n");
        return 0;
    }

    printf("\n[*] Preparing CSD update payload to clear TMP_WRITE_PROTECT...\n");
    csd[14] &= ~0x30; /* Clear bits 12 and 13 */
    csd[15] = calc_csd_crc(csd);

    printf("[+] Unlocked CSD Payload: ");
    for (int i = 0; i < 16; i++) printf("%02X", csd[i]);
    printf("\n");

    int fd = open(devpath, O_RDWR);
    if (fd < 0) {
        fd = open(devpath, O_RDONLY);
    }
    if (fd < 0) {
        perror("[-] Error: Unable to open device node (run as root / sudo)");
        return 1;
    }

    /* Step 1: Explicitly set transfer block length to 16 bytes via CMD16 */
    struct mmc_ioc_cmd cmd16;
    memset(&cmd16, 0, sizeof(cmd16));
    cmd16.opcode = SD_SET_BLOCKLEN;
    cmd16.arg = 16;
    cmd16.flags = MMC_COMMAND_REPLY_R1;
    cmd16.cmd_timeout_ms = 1000;
    ioctl(fd, MMC_IOC_CMD, &cmd16);

    /* Step 2: Send CMD27 (PROGRAM_CSD) */
    struct mmc_ioc_cmd cmd27;
    memset(&cmd27, 0, sizeof(cmd27));
    cmd27.write_flag = 1;
    cmd27.opcode = SD_WRITE_CSD;
    cmd27.arg = 0;
    cmd27.flags = MMC_COMMAND_ADTC | MMC_COMMAND_REPLY_R1B;
    cmd27.blksz = 16;
    cmd27.blocks = 1;
    cmd27.postsleep_min_us = 250000;
    cmd27.postsleep_max_us = 250000;
    cmd27.cmd_timeout_ms = 5000;
    cmd27.data_timeout_ns = 3000000000ULL;
    cmd27.data_ptr = (uint64_t)(uintptr_t)csd;

    printf("[*] Sending CMD27 (PROGRAM_CSD) to flash controller...\n");
    int ret = ioctl(fd, MMC_IOC_CMD, &cmd27);
    if (ret != 0) {
        int err = errno;
        fprintf(stderr, "[-] Error: ioctl failed with code %d (errno %d: %s)\n", ret, err, strerror(err));
        if (err == 84 || err == 71) {
            fprintf(stderr, "\n[!] CAUTION: Controller returned EILSEQ / EPROTO.\n");
            fprintf(stderr, "    If running on a MediaTek Android device, this is caused by the\n");
            fprintf(stderr, "    driver FIFO watermark bug in mtk-msdc for transfers < 512 bytes.\n");
            fprintf(stderr, "    Switch to a Raspberry Pi 3B+/4 booting from USB.\n\n");
        }
        close(fd);
        return 1;
    }

    close(fd);
    printf("[+] SUCCESS: CMD27 executed cleanly! Hardware write protection removed.\n");
    return 0;
}
