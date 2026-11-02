#import <Foundation/Foundation.h>

extern "C" __attribute__((weak, visibility("hidden"))) int32_t __isOSVersionAtLeast(int32_t major, int32_t minor,
                                                                                     int32_t subminor) {
    NSOperatingSystemVersion version = {major, minor, subminor};
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:version] ? 1 : 0;
}
