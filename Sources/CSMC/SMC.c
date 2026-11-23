/*
 * SMC.c — доступ к AppleSMC через IOKit (чтение/запись ключей, вентиляторы).
 *
 * Протокол: IOServiceOpen(service, ..., 0, &conn), вызов selector'а 2
 * (IOConnectCallStructMethod) со структурой SMCKeyData_t.
 *   data8 = 9 — key info, 5 — чтение байтов, 6 — запись байтов,
 *   8 — ключ по индексу.
 *
 * Layout структуры проверен эмпирически на MacBookPro18,4 (M1 Max):
 * sizeof == 80, data8 @42, bytes @48 (см. probe/smc_probe.c).
 */
#include "CSMC.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
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

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData layout must be 80 bytes");
_Static_assert(offsetof(SMCKeyData, data8) == 42, "data8 offset");
_Static_assert(offsetof(SMCKeyData, bytes) == 48, "bytes offset");

#define CMD_READ_BYTES   5
#define CMD_WRITE_BYTES  6
#define CMD_READ_INDEX   8
#define CMD_READ_KEYINFO 9
#define KERNEL_INDEX_SMC 2

/* Кэш key info: каждый опрос датчиков делает сотни вызовов, кэш удваивает скорость. */
#define INFO_CACHE_SIZE 512
static struct { uint32_t key; SMCKeyInfoData info; } g_infoCache[INFO_CACHE_SIZE];
static int g_infoCacheCount = 0;

struct smc_conn {
    io_connect_t conn;
};

static char g_error[256] = "";
const char *smc_last_error(void) { return g_error; }
static int fail(const char *fmt, ...) __attribute__((format(printf,1,2)));
static int fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vsnprintf(g_error, sizeof(g_error), fmt, ap); va_end(ap);
    return -1;
}

static kern_return_t smc_call(smc_conn_t *c, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(c->conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData), out, &outSize);
}

static uint32_t fourcc(const char *s) {
    uint32_t v = 0;
    for (int i = 0; i < 4 && s[i]; i++) v = (v << 8) | (uint8_t)s[i];
    return v;
}
static void cc_to_str(uint32_t v, char out[5]) {
    out[0] = (v >> 24) & 0xff; out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8) & 0xff;  out[3] = v & 0xff; out[4] = 0;
}

smc_conn_t *smc_open(void) {
    io_service_t service = 0;
    const char *names[] = { "AppleSMC", "AppleSMCKeysEndpoint", "SMCEndpoint1" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && !service; i++) {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(names[i]));
    }
    if (!service) { fail("SMC service not found"); return NULL; }

    smc_conn_t *c = calloc(1, sizeof(*c));
    if (!c) { IOObjectRelease(service); fail("out of memory"); return NULL; }

    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &c->conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) { free(c); fail("IOServiceOpen failed: 0x%x", kr); return NULL; }
    return c;
}

void smc_close(smc_conn_t *c) {
    if (!c) return;
    if (c->conn) IOServiceClose(c->conn);
    free(c);
}

static int key_info(smc_conn_t *c, uint32_t key, SMCKeyInfoData *info) {
    for (int i = 0; i < g_infoCacheCount; i++) {
        if (g_infoCache[i].key == key) { *info = g_infoCache[i].info; return 0; }
    }
    SMCKeyData in = {0}, out = {0};
    in.key = key;
    in.data8 = CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(c, &in, &out);
    if (kr != KERN_SUCCESS) return fail("keyinfo call failed for 0x%08x: 0x%x", key, kr);
    if (out.result != 0 || out.keyInfo.dataSize == 0)
        return fail("key 0x%08x unavailable (result=%u)", key, out.result);
    *info = out.keyInfo;
    if (g_infoCacheCount < INFO_CACHE_SIZE) {
        g_infoCache[g_infoCacheCount].key = key;
        g_infoCache[g_infoCacheCount].info = out.keyInfo;
        g_infoCacheCount++;
    }
    return 0;
}

int smc_read_raw(smc_conn_t *c, const char key[4], uint8_t *bytes, uint32_t *size, char type[5]) {
    if (!c) return fail("not connected");
    uint32_t kc = fourcc(key);
    SMCKeyInfoData info;
    if (key_info(c, kc, &info) != 0) return -1;

    SMCKeyData in = {0}, out = {0};
    in.key = kc;
    in.keyInfo = info;
    in.data8 = CMD_READ_BYTES;
    kern_return_t kr = smc_call(c, &in, &out);
    if (kr != KERN_SUCCESS) return fail("read call failed for %.4s: 0x%x", key, kr);
    if (out.result != 0) return fail("read %.4s result=%u", key, out.result);

    uint32_t n = info.dataSize < 32 ? info.dataSize : 32;
    if (bytes) memcpy(bytes, out.bytes, n);
    if (size) *size = n;
    if (type) cc_to_str(info.dataType, type);
    return 0;
}

static double decode_by_type(const char *type, const uint8_t *b, uint32_t n) {
    if (strcmp(type, "flt ") == 0 && n >= 4) { float f; memcpy(&f, b, 4); return f; }
    if (strcmp(type, "sp78") == 0 && n >= 2) return (int16_t)((b[0] << 8) | b[1]) / 256.0;
    if (strcmp(type, "fpe2") == 0 && n >= 2) return ((b[0] << 8) | b[1]) / 4.0;
    if (strcmp(type, "fp88") == 0 && n >= 2) return ((b[0] << 8) | b[1]) / 256.0;
    if (strcmp(type, "ui8 ") == 0 && n >= 1) return b[0];
    if (strcmp(type, "ui16") == 0 && n >= 2) return (double)((b[0] << 8) | b[1]);
    if (strcmp(type, "ui32") == 0 && n >= 4)
        return (double)(((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]);
    if (strcmp(type, "si8 ") == 0 && n >= 1) return (int8_t)b[0];
    if (strcmp(type, "si16") == 0 && n >= 2) return (int16_t)((b[0] << 8) | b[1]);
    return (double)NAN;
}

int smc_read_double(smc_conn_t *c, const char key[4], double *out) {
    uint8_t b[32]; uint32_t n; char type[5];
    if (smc_read_raw(c, key, b, &n, type) != 0) return -1;
    double v = decode_by_type(type, b, n);
    if (isnan(v)) return fail("key %.4s type %.4s not decodable", key, type);
    *out = v;
    return 0;
}

int smc_write_raw(smc_conn_t *c, const char key[4], const uint8_t *bytes, uint32_t n) {
    if (!c) return fail("not connected");
    if (n == 0 || n > 32) return fail("bad payload size %u", n);
    uint32_t kc = fourcc(key);

    SMCKeyInfoData info;
    if (key_info(c, kc, &info) != 0) return -1;
    if (info.dataSize != n)
        return fail("write %.4s size mismatch: smc expects %u, got %u", key, info.dataSize, n);

    SMCKeyData in = {0}, out = {0};
    in.key = kc;
    in.keyInfo = info;
    in.keyInfo.dataSize = n;   /* конверт записи обязан объявлять точный размер */
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, n);

    kern_return_t kr = smc_call(c, &in, &out);
    if (kr != KERN_SUCCESS) return fail("write call failed for %.4s: 0x%x (need root?)", key, kr);
    if (out.result != 0) return fail("write %.4s result=%u", key, out.result);
    return 0;
}

int smc_write_double(smc_conn_t *c, const char key[4], double value) {
    uint8_t b[32]; uint32_t n; char type[5];
    if (smc_read_raw(c, key, b, &n, type) != 0) return -1;

    if (strcmp(type, "flt ") == 0 && n == 4) {
        float f = (float)value; memcpy(b, &f, 4);
    } else if (strcmp(type, "fpe2") == 0 && n == 2) {
        if (value < 0 || value * 4 > 65535) return fail("value %.1f out of fpe2 range", value);
        uint16_t raw = (uint16_t)(value * 4);
        b[0] = raw >> 8; b[1] = raw & 0xff;
    } else if (strcmp(type, "ui8 ") == 0 && n == 1) {
        if (value < 0 || value > 255) return fail("value out of ui8 range");
        b[0] = (uint8_t)value;
    } else if (strcmp(type, "ui16") == 0 && n == 2) {
        if (value < 0 || value > 65535) return fail("value out of ui16 range");
        uint16_t raw = (uint16_t)value; b[0] = raw >> 8; b[1] = raw & 0xff;
    } else {
        return fail("write type %.4s/%u not supported", type, n);
    }
    return smc_write_raw(c, key, b, n);
}

int smc_key_count(smc_conn_t *c, uint32_t *out) {
    double v;
    if (smc_read_double(c, "#KEY", &v) != 0) return -1;
    *out = (uint32_t)v;
    return 0;
}

int smc_key_at(smc_conn_t *c, uint32_t index, char key[5]) {
    if (!c) return fail("not connected");
    SMCKeyData in = {0}, out = {0};
    in.data8 = CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t kr = smc_call(c, &in, &out);
    if (kr != KERN_SUCCESS) return fail("index call failed: 0x%x", kr);
    if (out.result != 0) return fail("index %u result=%u", index, out.result);
    cc_to_str(out.key, key);
    return 0;
}

/* ---------- Вентиляторы ---------- */

static char fan_char(int index) {
    return index < 10 ? (char)('0' + index) : (char)('A' + index - 10);
}

int smc_fan_count(smc_conn_t *c, int *out) {
    double v;
    if (smc_read_double(c, "FNum", &v) != 0) return -1;
    *out = (int)v;
    return 0;
}

int smc_read_fans(smc_conn_t *c, smc_fan_t *out, int max, int *count) {
    if (!out || !count || max <= 0) return fail("invalid fan buffer");
    int n;
    if (smc_fan_count(c, &n) != 0) return -1;
    if (n > max) return fail("too many fans: %d (capacity %d)", n, max);
    for (int i = 0; i < n; i++) {
        char k[5] = { 'F', fan_char(i), 0, 0, 0 };
        smc_fan_t f = { .index = i, .mode_forced = -1, .status = -1 };
        k[2] = 'A'; k[3] = 'c'; if (smc_read_double(c, k, &f.actual) != 0) return -1;
        k[2] = 'M'; k[3] = 'n'; if (smc_read_double(c, k, &f.min) != 0) return -1;
        k[2] = 'M'; k[3] = 'x'; if (smc_read_double(c, k, &f.max) != 0) return -1;
        k[2] = 'T'; k[3] = 'g'; if (smc_read_double(c, k, &f.target) != 0) return -1;
        k[2] = 'D'; k[3] = 'c';
        if (smc_read_double(c, k, &f.duty) != 0) f.duty = NAN;
        double st = -1, md = -1;
        k[2] = 'S'; k[3] = 't'; if (smc_read_double(c, k, &st) == 0) f.status = (int)st;
        k[2] = 'M'; k[3] = 'd';
        if (smc_read_double(c, k, &md) == 0) f.mode_forced = (int)md;
        out[i] = f;
    }
    *count = n;
    return 0;
}

int smc_fan_set_forced(smc_conn_t *c, int index, int forced) {
    char key[5] = { 'F', fan_char(index), 'M', 'd', 0 };
    return smc_write_double(c, key, forced ? 1 : 0);
}

int smc_fan_set_target(smc_conn_t *c, int index, double rpm) {
    char key[5] = { 'F', fan_char(index), 'T', 'g', 0 };
    return smc_write_double(c, key, rpm);
}
