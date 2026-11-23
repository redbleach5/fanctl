/* hidtemp.c — чтение именованных температур через IOHIDEventSystem (без root).
 * clang hidtemp.c -o hidtemp -framework IOKit -framework CoreFoundation */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

typedef const struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int64_t field);

int main(void) {
    const int appleVendorPage = 0xff00;
    const int temperatureUsage = 0x0005;
    const int64_t temperatureEventType = 15;
    const int64_t temperatureField = temperatureEventType << 16;

    int vp = appleVendorPage, up = temperatureUsage;
    CFStringRef keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    CFNumberRef n1 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vp);
    CFNumberRef n2 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &up);
    CFTypeRef vals[2] = { n1, n2 };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, (const void**)keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(n1); CFRelease(n2);

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) { printf("client create failed\n"); return 1; }
    IOHIDEventSystemClientSetMatching(client, matching);
    CFRelease(matching);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) { printf("no services\n"); return 1; }

    CFIndex count = CFArrayGetCount(services);
    printf("services: %ld\n", (long)count);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, temperatureEventType, 0, 0);
        if (!ev) continue;
        double c = IOHIDEventGetFloatValue(ev, temperatureField);
        CFRelease(ev);
        char name[128] = {0};
        CFTypeRef product = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (product && CFGetTypeID(product) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)product, name, sizeof(name), kCFStringEncodingUTF8);
        if (product) CFRelease(product);
        printf("  %-40s %6.2f C\n", name[0] ? name : "(unnamed)", c);
    }
    CFRelease(services);
    CFRelease(client);
    return 0;
}
