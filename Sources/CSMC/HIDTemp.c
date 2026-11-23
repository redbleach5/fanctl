/*
 * HIDTemp.c — именованные температуры через IOHIDEventSystemClient.
 * Работает без root; сенсоры имеют имена вроде "NAND CH0 temp",
 * "gas gauge battery", "PMU tdie1".
 *
 * Используемые API не публичны в заголовках, но стабильны с 10.x
 * (тот же подход применяют TG Pro и подобные утилиты).
 */
#include "CSMC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <math.h>
#include <string.h>

typedef const struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int64_t field);

int hid_read_temps(hid_temp_t *out, int max) {
    if (!out || max <= 0) return 0;

    const int vendorPage = 0xff00;      /* AppleVendor */
    const int tempUsage = 0x0005;
    const int64_t eventType = 15;       /* kIOHIDEventTypeTemperature */
    const int64_t field = eventType << 16;

    int vp = vendorPage, up = tempUsage;
    CFNumberRef n1 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vp);
    CFNumberRef n2 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &up);
    if (!n1 || !n2) { if (n1) CFRelease(n1); if (n2) CFRelease(n2); return 0; }

    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { n1, n2 };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(n1); CFRelease(n2);
    if (!matching) return 0;

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) { CFRelease(matching); return 0; }
    IOHIDEventSystemClientSetMatching(client, matching);
    CFRelease(matching);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { CFRelease(client); return 0; }

    int written = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && written < max; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!svc) continue;
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, eventType, 0, 0);
        if (!ev) continue;
        double c = IOHIDEventGetFloatValue(ev, field);
        CFRelease(ev);
        if (!isfinite(c) || c <= 0.0 || c >= 130.0) continue;

        char name[64] = {0};
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (product && CFGetTypeID(product) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)product, name, sizeof(name), kCFStringEncodingUTF8);
        if (product) CFRelease(product);
        if (!name[0]) snprintf(name, sizeof(name), "Sensor %d", written + 1);

        strncpy(out[written].name, name, sizeof(out[written].name) - 1);
        out[written].name[sizeof(out[written].name) - 1] = '\0';
        out[written].celsius = c;
        written++;
    }
    CFRelease(services);
    CFRelease(client);
    return written;
}
