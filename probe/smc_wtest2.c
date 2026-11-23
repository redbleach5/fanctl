/*
 * smc_wtest2.c — детальная проверка управления вентилятором с правильным порядком:
 *   1) F0Md=1 (forced), 2) F0Tg=<rpm>, затем наблюдение за F0Ac.
 * Всегда восстанавливает auto-режим в конце.
 *
 * clang smc_wtest2.c -o smc_wtest2 -framework IOKit
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
static int key_info(const char *k, SMCKeyInfoData *info) {
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(k); in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize == 0) return -1;
    *info = out.keyInfo;
    return 0;
}
static int key_read(const char *k, double *out) {
    SMCKeyInfoData info;
    if (key_info(k, &info) != 0) return -1;
    SMCKeyData in = {0}, o = {0};
    in.key = fourcc(k); in.keyInfo = info; in.data8 = CMD_READ_BYTES;
    if (smc_call(&in, &o) != kIOReturnSuccess || o.result != 0) return -1;
    if (info.dataType == fourcc("flt ") && info.dataSize == 4) { float f; memcpy(&f, o.bytes, 4); *out = f; return 0; }
    if (info.dataSize == 1) { *out = o.bytes[0]; return 0; }
    if (info.dataSize == 2) { *out = (o.bytes[0] << 8) | o.bytes[1]; return 0; }
    return -1;
}
/* запись: сначала key_info (как в Vifty), затем data8=6 с точным размером полезной нагрузки */
static int key_write(const char *k, const uint8_t *bytes, uint32_t n) {
    SMCKeyInfoData info;
    if (key_info(k, &info) != 0) { printf("    write %s: key_info failed\n", k); return -1; }
    if (info.dataSize != n) { printf("    write %s: size mismatch (info=%u want=%u)\n", k, info.dataSize, n); return -1; }
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(k);
    in.keyInfo = info;
    in.keyInfo.dataSize = n;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, n);
    kern_return_t r = smc_call(&in, &out);
    if (r != kIOReturnSuccess) { printf("    write %s: IOConnect 0x%x\n", k, r); return -1; }
    if (out.result != 0) { printf("    write %s: result=%u\n", k, out.result); return -1; }
    return 0;
}
static int write_flt(const char *k, float v) { uint8_t b[4]; memcpy(b, &v, 4); return key_write(k, b, 4); }
static int write_u8(const char *k, uint8_t v) { return key_write(k, &v, 1); }

static void sample(const char *tag) {
    double ac, tg, md, dc, st;
    key_read("F0Ac", &ac); key_read("F0Tg", &tg); key_read("F0Md", &md);
    key_read("F0Dc", &dc); key_read("F0St", &st);
    printf("[%s] F0Ac=%.0f  F0Tg=%.0f  F0Md=%.0f  F0Dc=%.0f  F0St=%.0f\n", tag, ac, tg, md, dc, st);
    fflush(stdout);
}

int main(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { printf("no AppleSMC\n"); return 1; }
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess) { printf("open failed 0x%x\n", r); return 1; }
    printf("uid=%d euid=%d\n", getuid(), geteuid());
    sample("start");

    printf("\n== step1: F0Md=1 (forced) ==\n");
    if (write_u8("F0Md", 1) != 0) printf("    FAILED\n");
    sleep(2); sample("after Md=1");

    printf("\n== step2: F0Tg=1500 ==\n");
    if (write_flt("F0Tg", 1500.0f) != 0) printf("    FAILED\n");
    for (int i = 0; i < 6; i++) { sleep(1); char t[16]; sprintf(t, "t+%ds", i + 1); sample(t); }

    printf("\n== step3: F0Tg=3500 ==\n");
    if (write_flt("F0Tg", 3500.0f) != 0) printf("    FAILED\n");
    for (int i = 0; i < 6; i++) { sleep(1); char t[16]; sprintf(t, "t+%ds", i + 1); sample(t); }

    printf("\n== step4: F0Tg=1200 (min), затем F0Md=0 (auto) ==\n");
    write_flt("F0Tg", 1200.0f);
    sleep(2); sample("Tg=1200");
    if (write_u8("F0Md", 0) != 0) printf("    FAILED\n");
    for (int i = 0; i < 6; i++) { sleep(1); char t[16]; sprintf(t, "auto+%ds", i + 1); sample(t); }

    IOServiceClose(g_conn);
    printf("\nDONE (auto restored)\n");
    return 0;
}
