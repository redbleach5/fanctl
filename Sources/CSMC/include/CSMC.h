#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------- AppleSMC ---------- */

typedef struct smc_conn smc_conn_t;

/* Открыть соединение с SMC. NULL при ошибке (см. smc_last_error). */
smc_conn_t *smc_open(void);
void smc_close(smc_conn_t *c);
const char *smc_last_error(void);

/* Чтение сырого значения ключа. type — четырёхсимвольный код типа (напр. "flt "). */
int smc_read_raw(smc_conn_t *c, const char key[4], uint8_t *bytes, uint32_t *size, char type[5]);
/* Чтение ключа как double (поддерживает flt / sp78 / fpe2 / fp88 / ui8 / ui16 / ui32 / si8 / si16). */
int smc_read_double(smc_conn_t *c, const char key[4], double *out);

/* Запись (требует root). Контролирует, что размер и тип совпадают с ожиданиями SMC. */
int smc_write_raw(smc_conn_t *c, const char key[4], const uint8_t *bytes, uint32_t n);
int smc_write_double(smc_conn_t *c, const char key[4], double value);

/* Перечисление ключей (для обнаружения датчиков). */
int smc_key_count(smc_conn_t *c, uint32_t *out);
int smc_key_at(smc_conn_t *c, uint32_t index, char key[5]);

/* ---------- Вентиляторы ---------- */

typedef struct {
    int index;
    double actual;      /* F{n}Ac — текущие обороты */
    double min;         /* F{n}Mn */
    double max;         /* F{n}Mx */
    double target;      /* F{n}Tg */
    double duty;        /* F{n}Dc — % ШИМ (0 на Apple Silicon) */
    int mode_forced;    /* F{n}Md: 1 = forced, 0 = auto, -1 = недоступно */
    int status;         /* F{n}St */
} smc_fan_t;

int smc_fan_count(smc_conn_t *c, int *out);
int smc_read_fans(smc_conn_t *c, smc_fan_t *out, int max, int *count);
/* Принудительный (1) или auto (0) режим. */
int smc_fan_set_forced(smc_conn_t *c, int index, int forced);
/* Установить целевые обороты (записывается в F{n}Tg, работает при mode_forced=1). */
int smc_fan_set_target(smc_conn_t *c, int index, double rpm);

/* ---------- HID-температуры (именованные, без root) ---------- */

typedef struct {
    char name[64];
    double celsius;
} hid_temp_t;

int hid_read_temps(hid_temp_t *out, int max);

/* ---------- Системные метрики ---------- */

typedef struct {
    double cpu_percent;     /* busy % с последнего вызова (0..100) */
    double gpu_percent;     /* Device Utilization % (-1 если недоступно) */
    double mem_used_gb;     /* App + wired + compressed, приближение к Activity Monitor */
    double mem_top_used_gb; /* active + inactive + speculative + wired + compressed */
    double mem_app_gb;
    double mem_wired_gb;
    double mem_compressed_gb;
    double mem_cached_gb;
    double mem_free_gb;
    double mem_available_percent;
    double mem_total_gb;
    double swap_used_gb;
    double swap_total_gb;
} sys_metrics_t;

/* Первый вызов инициализирует базовые значения и возвращает cpu_percent = -1. */
int metrics_sample(sys_metrics_t *out);

#define METRICS_PROCESS_PATH_MAX 1024
typedef struct {
    int32_t pid;
    uint64_t memory_bytes;
    char name[64];
    char path[METRICS_PROCESS_PATH_MAX];
} process_memory_t;

int metrics_top_processes(process_memory_t *out, int max);

#ifdef __cplusplus
}
#endif
#endif
