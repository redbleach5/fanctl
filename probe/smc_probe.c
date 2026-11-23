/*
 * smc_probe.c — исследование AppleSMC на Apple Silicon (M1 Max).
 * Определяет: доступность сервиса, layout структуры, ключи вентиляторов и температур.
 *
 * Сборка (два варианта layout):
 *   clang -DSTRUCT_PAD=1 smc_probe.c -o probe_pad  -framework IOKit
 *   clang -DSTRUCT_PAD=0 smc_probe.c -o probe_nopad -framework IOKit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPowerLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPowerLimitData pLimitData;
    SMCKeyInfoData keyInfo;
#if STRUCT_PAD
    uint16_t padding;
#endif
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_INDEX   8
#define CMD_READ_KEYINFO 9

static io_connect_t g_conn = 0;

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(SMCKeyData), out, &outSize);
}

static uint32_t fourcc(const char *s) {
    uint32_t v = 0;
    for (int i = 0; i < 4 && s[i]; i++) v = (v << 8) | (uint8_t)s[i];
    return v;
}

static void ccstr(uint32_t v, char out[5]) {
    out[0] = (v >> 24) & 0xff; out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8) & 0xff;  out[3] = v & 0xff; out[4] = 0;
}

static int key_info(uint32_t key, SMCKeyInfoData *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.data8 = CMD_READ_KEYINFO;
    kern_return_t r = smc_call(&in, &out);
    if (r != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize == 0) return -1;
    *info = out.keyInfo;
    return 0;
}

static int key_read(const char *k, uint8_t *bytes, uint32_t *size, char type[5]) {
    uint32_t key = fourcc(k);
    SMCKeyInfoData info;
    if (key_info(key, &info) != 0) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.keyInfo = info;
    in.data8 = CMD_READ_BYTES;
    kern_return_t r = smc_call(&in, &out);
    if (r != kIOReturnSuccess || out.result != 0) return -1;
    uint32_t n = info.dataSize < 32 ? info.dataSize : 32;
    memcpy(bytes, out.bytes, n);
    *size = n;
    ccstr(info.dataType, type);
    return 0;
}

static double decode(const char *type, const uint8_t *b, uint32_t n) {
    if (strcmp(type, "sp78") == 0 && n >= 2) {
        int16_t raw = (int16_t)((b[0] << 8) | b[1]);
        return raw / 256.0;
    }
    if (strcmp(type, "flt ") == 0 && n >= 4) {
        float f; memcpy(&f, b, 4); return f;
    }
    if (strcmp(type, "fpe2") == 0 && n >= 2) {
        return ((b[0] << 8) | b[1]) / 4.0;
    }
    if (strcmp(type, "fp88") == 0 && n >= 2) {
        return ((b[0] << 8) | b[1]) / 256.0;
    }
    if (strcmp(type, "ui8 ") == 0 && n >= 1) return b[0];
    if (strcmp(type, "ui16") == 0 && n >= 2) return (b[0] << 8) | b[1];
    if (strcmp(type, "ui32") == 0 && n >= 4)
        return ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    if (strcmp(type, "si8 ") == 0 && n >= 1) return (int8_t)b[0];
    if (strcmp(type, "si16") == 0 && n >= 2) return (int16_t)((b[0] << 8) | b[1]);
    return -1;
}

static void print_key(const char *k) {
    uint8_t b[32]; uint32_t n; char type[5];
    if (key_read(k, b, &n, type) != 0) { printf("  %-4s  <unreadable>\n", k); return; }
    double d = decode(type, b, n);
    printf("  %-4s  type=%-4s size=%u  value=%.2f  bytes=", k, type, n, d);
    for (uint32_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

int main(void) {
    printf("sizeof(SMCKeyData) = %zu (STRUCT_PAD=%d)\n", sizeof(SMCKeyData), STRUCT_PAD);
    printf("  offset key=%zu vers=%zu plimit=%zu keyInfo=%zu result=%zu status=%zu data8=%zu data32=%zu bytes=%zu\n",
           offsetof(SMCKeyData, key), offsetof(SMCKeyData, vers), offsetof(SMCKeyData, pLimitData),
           offsetof(SMCKeyData, keyInfo), offsetof(SMCKeyData, result), offsetof(SMCKeyData, status),
           offsetof(SMCKeyData, data8), offsetof(SMCKeyData, data32), offsetof(SMCKeyData, bytes));

    io_service_t service = 0;
    const char *used = NULL;
    const char *names[] = {"AppleSMC", "AppleSMCKeysEndpoint", "SMCEndpoint1", NULL};
    for (int i = 0; names[i]; i++) {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(names[i]));
        if (service) { used = names[i]; break; }
    }
    if (!service) { printf("SMC service not found\n"); return 1; }
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess) { printf("IOServiceOpen(%s) failed: 0x%x\n", used, r); return 1; }
    printf("opened service: %s, conn=%u, uid=%d euid=%d\n", used, g_conn, getuid(), geteuid());

    print_key("#KEY");
    print_key("FNum");
    print_key("F0ID");
    print_key("F0Ac");
    print_key("F0Mn");
    print_key("F0Mx");
    print_key("F0Sf");
    print_key("F0Tg");
    print_key("F0Md");
    print_key("FS! ");
    print_key("F1Ac");
    print_key("F1Tg");
    print_key("F1Md");
    print_key("Ftst");

    uint8_t b[32]; uint32_t n; char type[5];
    if (key_read("#KEY", b, &n, type) == 0) {
        uint32_t total = decode(type, b, n);
        printf("\n--- enumeration: %u keys ---\n", total);
        for (uint32_t i = 0; i < total && i < 2000; i++) {
            SMCKeyData in = {0}, out = {0};
            in.data8 = CMD_READ_INDEX;
            in.data32 = i;
            if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) continue;
            char k[5]; ccstr(out.key, k);
            if (k[0] != 'T' && k[0] != 'F') continue;
            uint8_t vb[32]; uint32_t vn; char vt[5];
            if (key_read(k, vb, &vn, vt) != 0) { printf("  %-4s type=? <err>\n", k); continue; }
            double d = decode(vt, vb, vn);
            if (d == -1 && !(vn == 1 && vb[0] == 0)) {
                printf("  %-4s type=%-4s size=%u bytes=", k, vt, vn);
                for (uint32_t j = 0; j < vn; j++) printf("%02x", vb[j]);
                printf("\n");
            } else {
                printf("  %-4s type=%-4s size=%u value=%.2f\n", k, vt, vn, d);
            }
        }
    }

    IOServiceClose(g_conn);
    return 0;
}
