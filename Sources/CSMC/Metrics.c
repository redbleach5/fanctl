/*
 * Metrics.c — системные метрики: загрузка CPU, загрузка GPU, память, swap.
 * Всё без root.
 */
#include "CSMC.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <libproc.h>
#include <IOKit/IOKitLib.h>

/* ---------- CPU ---------- */

static uint64_t prev_total = 0;
static uint64_t prev_busy = 0;
static int cpu_primed = 0;

static int cpu_ticks(uint64_t *busy, uint64_t *total) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS)
        return -1;
    uint64_t user = info.cpu_ticks[CPU_STATE_USER];
    uint64_t sys  = info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t idle = info.cpu_ticks[CPU_STATE_IDLE];
    uint64_t nice = info.cpu_ticks[CPU_STATE_NICE];
    *busy = user + sys + nice;
    *total = *busy + idle;
    return 0;
}

/* ---------- GPU ---------- */

static double gpu_util(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AGXAccelerator"));
    if (!svc) return -1.0;

    CFTypeRef stats = IORegistryEntryCreateCFProperty(svc, CFSTR("PerformanceStatistics"),
                                                      kCFAllocatorDefault, 0);
    IOObjectRelease(svc);
    if (!stats) return -1.0;

    double result = -1.0;
    if (CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
        CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)stats, CFSTR("Device Utilization %"));
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            int pct = -1;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &pct);
            if (pct >= 0) result = (double)pct;
        }
    }
    CFRelease(stats);
    return result;
}

/* ---------- Память ---------- */

static double total_ram_gb(void) {
    uint64_t mem = 0;
    size_t len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) != 0) return 0.0;
    return (double)mem / (1024.0 * 1024.0 * 1024.0);
}

static double gib(uint64_t bytes) {
    return (double)bytes / (1024.0 * 1024.0 * 1024.0);
}

static double pages_gib(uint64_t pages) {
    return gib(pages * (uint64_t)vm_page_size);
}

static int memory_metrics(sys_metrics_t *out) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
        return -1;

    out->mem_app_gb = pages_gib(vm.internal_page_count);
    out->mem_wired_gb = pages_gib(vm.wire_count);
    out->mem_compressed_gb = pages_gib(vm.compressor_page_count);
    out->mem_cached_gb = pages_gib((uint64_t)vm.external_page_count + vm.purgeable_count);
    out->mem_free_gb = pages_gib(vm.free_count);
    out->mem_used_gb = out->mem_app_gb + out->mem_wired_gb + out->mem_compressed_gb;
    out->mem_top_used_gb = pages_gib((uint64_t)vm.active_count + vm.inactive_count +
        vm.speculative_count + vm.wire_count + vm.compressor_page_count);

    int available = 0;
    size_t len = sizeof(available);
    out->mem_available_percent = sysctlbyname("kern.memorystatus_level", &available, &len, NULL, 0) == 0
        ? (double)available : -1.0;
    return 0;
}

static int swap_metrics(sys_metrics_t *out) {
    struct xsw_usage xs;
    size_t len = sizeof(xs);
    if (sysctlbyname("vm.swapusage", &xs, &len, NULL, 0) != 0) return -1;
    out->swap_used_gb = gib(xs.xsu_used);
    out->swap_total_gb = gib(xs.xsu_total);
    return 0;
}

/* ---------- Публичный API ---------- */

int metrics_sample(sys_metrics_t *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));

    uint64_t busy, total;
    if (cpu_ticks(&busy, &total) == 0) {
        if (!cpu_primed || total < prev_total) {
            out->cpu_percent = -1.0;
            cpu_primed = 1;
        } else {
            uint64_t dt = total - prev_total;
            uint64_t db = busy - prev_busy;
            out->cpu_percent = dt > 0 ? 100.0 * (double)db / (double)dt : 0.0;
            if (out->cpu_percent < 0) out->cpu_percent = 0;
            if (out->cpu_percent > 100) out->cpu_percent = 100;
        }
        prev_total = total;
        prev_busy = busy;
    } else {
        out->cpu_percent = -1.0;
    }

    out->gpu_percent = gpu_util();
    out->mem_total_gb = total_ram_gb();
    out->mem_used_gb = -1.0;
    out->mem_top_used_gb = -1.0;
    out->mem_app_gb = -1.0;
    out->mem_wired_gb = -1.0;
    out->mem_compressed_gb = -1.0;
    out->mem_cached_gb = -1.0;
    out->mem_free_gb = -1.0;
    out->mem_available_percent = -1.0;
    out->swap_used_gb = -1.0;
    out->swap_total_gb = -1.0;
    memory_metrics(out);
    swap_metrics(out);
    return 0;
}

static int compare_process_memory(const void *a, const void *b) {
    const process_memory_t *pa = a;
    const process_memory_t *pb = b;
    if (pa->memory_bytes < pb->memory_bytes) return 1;
    if (pa->memory_bytes > pb->memory_bytes) return -1;
    return (pa->pid > pb->pid) - (pa->pid < pb->pid);
}

int metrics_top_processes(process_memory_t *out, int max) {
    if (!out || max <= 0) return -1;
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return -1;
    pid_t *pids = malloc((size_t)capacity * sizeof(*pids));
    process_memory_t *items = malloc((size_t)capacity * sizeof(*items));
    if (!pids || !items) { free(pids); free(items); return -1; }

    int pid_count = proc_listallpids(pids, capacity * (int)sizeof(*pids));
    int count = 0;
    for (int i = 0; i < pid_count; i++) {
        if (pids[i] <= 0) continue;
        struct rusage_info_v2 usage;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0 ||
            usage.ri_phys_footprint == 0) continue;

        process_memory_t item = { .pid = pids[i], .memory_bytes = usage.ri_phys_footprint };
        if (proc_name(pids[i], item.name, sizeof(item.name)) <= 0)
            snprintf(item.name, sizeof(item.name), "pid %d", pids[i]);
        if (proc_pidpath(pids[i], item.path, sizeof(item.path)) <= 0)
            snprintf(item.path, sizeof(item.path), "%s", item.name);
        items[count++] = item;
    }
    qsort(items, (size_t)count, sizeof(*items), compare_process_memory);
    if (count > max) count = max;
    memcpy(out, items, (size_t)count * sizeof(*items));
    free(pids);
    free(items);
    return count;
}
