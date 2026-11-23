/*
 * senscan.c — опрос всех температурных ключей SMC с агрегацией по группам.
 * Позволяет методом нагрузки определить, какой ключ к чему относится.
 *
 * clang senscan.c -o senscan -framework IOKit
 * ./senscan <seconds> <interval_ms>  (interval_ms=1000 по умолчанию)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPowerLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPowerLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

#define CMD_READ_BYTES 5
#define CMD_READ_INDEX 8
#define CMD_READ_KEYINFO 9

static io_connect_t g_conn = 0;
static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t n = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(SMCKeyData), out, &n);
}
static uint32_t fourcc(const char *s) {
    uint32_t v = 0;
    for (int i = 0; i < 4 && s[i]; i++) v = (v << 8) | (uint8_t)s[i];
    return v;
}
static void ccstr(uint32_t v, char out[5]) {
    out[0]=(v>>24)&0xff; out[1]=(v>>16)&0xff; out[2]=(v>>8)&0xff; out[3]=v&0xff; out[4]=0;
}
static int key_read_raw(const char *k, uint8_t *bytes, uint32_t *size) {
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(k); in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize == 0) return -1;
    SMCKeyInfoData info = out.keyInfo;
    SMCKeyData rin = {0}, rout = {0};
    rin.key = fourcc(k); rin.keyInfo = info; rin.data8 = CMD_READ_BYTES;
    if (smc_call(&rin, &rout) != kIOReturnSuccess || rout.result != 0) return -1;
    uint32_t n = info.dataSize < 32 ? info.dataSize : 32;
    memcpy(bytes, rout.bytes, n);
    *size = n;
    return 0;
}
static int key_read_f(const char *k, double *out) {
    SMCKeyData in = {0}, o = {0};
    in.key = fourcc(k); in.data8 = CMD_READ_KEYINFO;
    if (smc_call(&in, &o) != kIOReturnSuccess || o.result != 0 || o.keyInfo.dataSize == 0) return -1;
    SMCKeyInfoData info = o.keyInfo;
    SMCKeyData rin = {0}, rout = {0};
    rin.key = fourcc(k); rin.keyInfo = info; rin.data8 = CMD_READ_BYTES;
    if (smc_call(&rin, &rout) != kIOReturnSuccess || rout.result != 0) return -1;
    if (info.dataType == fourcc("flt ") && info.dataSize == 4) { float f; memcpy(&f, rout.bytes, 4); *out = f; return 0; }
    return -1;
}

#define MAXK 400
static char keys[MAXK][5];
static int nkeys = 0;

static void collect(void) {
    uint8_t b[32]; uint32_t n;
    if (key_read_raw("#KEY", b, &n) != 0 || n < 4) return;
    uint32_t total = ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    for (uint32_t i = 0; i < total && nkeys < MAXK; i++) {
        SMCKeyData ii = {0}, oo = {0};
        ii.data8 = CMD_READ_INDEX; ii.data32 = i;
        if (smc_call(&ii, &oo) != kIOReturnSuccess || oo.result != 0) continue;
        char k[5]; ccstr(oo.key, k);
        if (k[0] != 'T') continue;
        double v;
        if (key_read_f(k, &v) != 0) continue;
        if (v < 5.0 || v > 120.0) continue;   /* отсекаем нулевые (Tz, Ta) и мусор */
        memcpy(keys[nkeys], k, 5);
        nkeys++;
    }
}

typedef struct { char group[4]; int count; double max; double sum; char maxkey[5]; } Group;

static int cmp_group(const void *a, const void *b) {
    const Group *ga = a, *gb = b;
    if (ga->max < gb->max) return 1;
    if (ga->max > gb->max) return -1;
    return 0;
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 10;
    int interval_ms = argc > 2 ? atoi(argv[2]) : 1000;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { printf("no AppleSMC\n"); return 1; }
    if (IOServiceOpen(service, mach_task_self(), 0, &g_conn) != kIOReturnSuccess) { printf("open failed\n"); return 1; }
    IOObjectRelease(service);

    collect();
    printf("# keys=%d, duration=%ds, interval=%dms\n", nkeys, seconds, interval_ms);
    printf("# group = вторая буква ключа; max/avg по группе, макс. ключ\n");
    fflush(stdout);

    int ticks = seconds * 1000 / interval_ms;
    for (int t = 0; t < ticks; t++) {
        Group groups[64]; int ng = 0;
        double global_max = -1; char global_key[5] = "?";
        for (int i = 0; i < nkeys; i++) {
            double v;
            if (key_read_f(keys[i], &v) != 0) continue;
            char gname[3] = { keys[i][1], 0, 0 };
            int gi = -1;
            for (int j = 0; j < ng; j++) if (groups[j].group[0] == gname[0]) { gi = j; break; }
            if (gi < 0) { gi = ng++; memset(&groups[gi], 0, sizeof(Group)); groups[gi].group[0] = gname[0]; }
            groups[gi].count++;
            groups[gi].sum += v;
            if (v > groups[gi].max) { groups[gi].max = v; memcpy(groups[gi].maxkey, keys[i], 5); }
            if (v > global_max) { global_max = v; memcpy(global_key, keys[i], 5); }
        }
        qsort(groups, ng, sizeof(Group), cmp_group);
        time_t now = time(NULL);
        struct tm tm; localtime_r(&now, &tm);
        printf("%02d:%02d:%02d MAX=%5.1f(%s) |", tm.tm_hour, tm.tm_min, tm.tm_sec, global_max, global_key);
        for (int j = 0; j < ng && j < 14; j++)
            printf(" %c:%4.1f/%4.1f(%s,%d)", groups[j].group[0], groups[j].max,
                   groups[j].sum / (groups[j].count ? groups[j].count : 1), groups[j].maxkey, groups[j].count);
        printf("\n");
        fflush(stdout);
        if (t + 1 < ticks) usleep(interval_ms * 1000);
    }
    IOServiceClose(g_conn);
    return 0;
}
