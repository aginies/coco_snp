// =============================================================================
// snp-report-gen.c — generate an SEV-SNP attestation report with a
// caller-specified report_data, bound to the guest's identity.
//
// Usage: snp-report-gen <report_data_hex> <output_file>
//   report_data_hex: 64-byte report_data as 128 hex chars
//   output_file:      path to write the 4000-byte report
//
// Requires: running inside an SEV-SNP guest with /dev/sev-guest present.
//
// The report is generated via the SNP_GUEST_REPORT ioctl on /dev/sev-guest.
// The CPU's PSP signs the report with the VCEK. The report's report_data
// field is set to the caller-specified value, which lets the report be bound
// to a TEE public key (report_data = sha384(canonical runtime data)).
//
// This is the SEV-SNP equivalent of the TDX tdx-quote-gen tool: the distro's
// 'snpguest report' uses a random report_data by default, but host-mode
// secret-get needs a report whose report_data matches a known value.
//
// Build: gcc -O2 -o snp-report-gen snp-report-gen.c
// (No external libraries required — only the kernel /dev/sev-guest ioctl.)
//
// SPDX-License-Identifier: GPL-3.0-only
// =============================================================================

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

// --- /dev/sev-guest ioctl interface (mirrors include/uapi/linux/sev-guest.h) ---
#if __has_include(<linux/sev-guest.h>)
#include <linux/sev-guest.h>
#endif

#ifndef SNP_GET_REPORT
#define SNP_GUEST_REQ_IOC_TYPE 'S'
#define SNP_REPORT_USER_DATA_SIZE 64

struct snp_report_req {
    uint8_t user_data[SNP_REPORT_USER_DATA_SIZE];
    uint32_t vmpl;
    uint8_t rsvd[28];
};

struct snp_report_resp {
    uint8_t data[4000];
};

struct snp_guest_request_ioctl {
    uint8_t msg_version;
    uint64_t req_data;
    uint64_t resp_data;
    union {
        uint64_t exitinfo2;
        struct {
            uint32_t fw_error;
            uint32_t vmm_error;
        };
    };
};

#define SNP_GET_REPORT _IOWR(SNP_GUEST_REQ_IOC_TYPE, 0x0, struct snp_guest_request_ioctl)
#endif

// A SEV-SNP attestation report is 4000 bytes (the CPU PSP signs it).
#define SNP_REPORT_SIZE 4000

static int hex_to_bytes(const char *hex, unsigned char *out, size_t out_len) {
    if (strlen(hex) != out_len * 2)
        return -1;
    for (size_t i = 0; i < out_len; i++) {
        unsigned int byte;
        if (sscanf(hex + 2 * i, "%2x", &byte) != 1)
            return -1;
        out[i] = (unsigned char)byte;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <report_data_hex> <output_file>\n", argv[0]);
        return 1;
    }

    // Parse the report_data hex string (128 hex chars = 64 bytes).
    unsigned char report_data[64];
    if (hex_to_bytes(argv[1], report_data, sizeof(report_data)) != 0) {
        fprintf(stderr, "Error: report_data must be 128 hex chars (64 bytes)\n");
        return 1;
    }

    // Open /dev/sev-guest (the SNP guest attestation device).
    int fd = open("/dev/sev-guest", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "Error: cannot open /dev/sev-guest: %s\n", strerror(errno));
        fprintf(stderr, "Are you inside an SEV-SNP guest with the snpguest module loaded?\n");
        return 1;
    }

    struct snp_report_req req;
    memset(&req, 0, sizeof(req));
    memcpy(req.user_data, report_data, sizeof(req.user_data));
    req.vmpl = 0;

    struct snp_report_resp resp;
    memset(&resp, 0, sizeof(resp));

    struct snp_guest_request_ioctl guest_req;
    memset(&guest_req, 0, sizeof(guest_req));
    guest_req.msg_version = 1;
    guest_req.req_data = (uint64_t)(uintptr_t)&req;
    guest_req.resp_data = (uint64_t)(uintptr_t)&resp;

    if (ioctl(fd, SNP_GET_REPORT, &guest_req) < 0) {
        fprintf(stderr, "Error: SNP_GET_REPORT ioctl failed: %s (fw_error=%u, vmm_error=%u)\n",
                strerror(errno), guest_req.fw_error, guest_req.vmm_error);
        close(fd);
        return 1;
    }

    // Write the 4000-byte report to the output file.
    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        fprintf(stderr, "Error: cannot open %s for writing: %s\n", argv[2], strerror(errno));
        close(fd);
        return 1;
    }
    if (fwrite(resp.data, 1, sizeof(resp.data), out) != sizeof(resp.data)) {
        fprintf(stderr, "Error: short write to %s\n", argv[2]);
        fclose(out);
        close(fd);
        return 1;
    }
    fclose(out);
    close(fd);

    printf("Wrote %zu-byte SEV-SNP report to %s\n", sizeof(resp.data), argv[2]);
    return 0;
}
