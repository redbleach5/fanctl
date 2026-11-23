/*
 * smc_wtest.c — безопасная проверка записи ключей вентиляторов.
 *
 * Последовательность (всегда восстанавливает auto-режим):
 *   1. читает F0Ac/F0Tg/F0Md/F0Mn/F0Mx
 *   2. пишет F0Tg = 1200 (auto-режим ещё активен → без влияния)
 *   3. пишет F0Md = 1 (форсированный режим)
 *   4. 3 c ждёт, читает F0Ac
 *   5. пишет F0Md = 0 (возврат в auto)
 *   6. 3 c ждёт, читает F0Ac
 *
 * Сборка: clang smc_wtest.c -o smc_wtest -framework IOKit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPowerLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPowerLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

#define CMD_READ_BYTES 5
#define CMD_WRITE_BYTES 6
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
static int key_info(uint32_t key, SMCKeyInfoData *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize == 0) return -1;
    *info = out.keyInfo;
    return 0;
}
static int key_read_f(const char *k, double *out) {
    uint32_t key = fourcc(k);
    SMCKeyInfoData info;
    if (key_info(key, &info) != 0) return -1;
    SMCKeyData in = {0}, o = {0};
    in.key = key; in.keyInfo = info; in.data8 = CMD_READ_BYTES;
    if (smc_call(&in, &o) != kIOReturnSuccess || o.result != 0) return -1;
    if (info.dataType == fourcc("flt ") && info.dataSize == 4) {
        float f; memcpy(&f, o.bytes, 4); *out = f; return 0;
    }
    if (info.dataSize == 1) { *out = o.bytes[0]; return 0; }
    return -1;
}
static int key_write(const char *k, const uint8_t *bytes, uint32_t n) {
    uint32_t key = fourcc(k);
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = n;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, n);
    kern_return_t r = smc_call(&in, &out);
    if (r != kIOReturnSuccess) { printf("    write %s: IOConnect error 0x%x\n", k, r); return -1; }
    if (out.result != 0) { printf("    write %s: smc result=%u\n", k, out.result); return -1; }
    return 0;
}
static int write_flt(const char *k, float v) {
    uint8_t b[4]; memcpy(b, &v, 4);
    return key_write(k, b, 4);
}
static int write_u8(const char *k, uint8_t v) { return key_write(k, &v, 1); }

int main(int argc, char **argv) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { printf("no AppleSMC\n"); return 1; }
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess) { printf("open failed 0x%x\n", r); return 1; }
    printf("uid=%d euid=%d\n", getuid(), geteuid());

    double ac, tg, md, mn, mx;
    key_read_f("F0Ac", &ac); key_read_f("F0Tg", &tg); key_read_f("F0Md", &md);
    key_read_f("F0Mn", &mn); key_read_f("F0Mx", &mx);
    printf("before: Ac=%.0f Tg=%.0f Md=%.0f Mn=%.0f Mx=%.0f\n", ac, tg, md, mn, mx);

    if (argc > 1 && strcmp(argv[1], "ro") == 0) { IOServiceClose(g_conn); return 0; }

    printf("step1: write F0Tg=1200 (в auto-режиме)\n");
    if (write_flt("F0Tg", 1200.0f) != 0) printf("    FAILED\n");
    key_read_f("F0Tg", &tg); printf("    F0Tg now=%.0f\n", tg);

    printf("step2: write F0Md=1 (forced)\n");
    if (write_u8("F0Md", 1) != 0) printf("    FAILED\n");
    key_read_f("F0Md", &md); printf("    F0Md now=%.0f\n", md);

    sleep(3);
    key_read_f("F0Ac", &ac); key_read_f("F0Tg", &tg);
    printf("after 3s: Ac=%.0f Tg=%.0f\n", ac, tg);

    printf("step3: restore F0Md=0 (auto)\n");
    if (write_u8("F0Md", 0) != 0) printf("    FAILED\n");
    key_read_f("F0Md", &md); printf("    F0Md now=%.0f\n", md);
    sleep(3);
    key_read_f("F0Ac", &ac);
    printf("restored: Ac=%.0f\n", ac);

    IOServiceClose(g_conn);
    return 0;
}
