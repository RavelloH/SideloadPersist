#import "PDPickerHostFix.h"
#import <objc/runtime.h>
#import <Security/Security.h>
#import <stdatomic.h>
#import <stdarg.h>

static _Atomic(BOOL) s_enabled = NO;
static _Atomic(BOOL) s_hooked = NO;
static void (*s_originalSetHostIdentifier)(id, SEL, NSString *) = NULL;
static PDPickerHostFixLogger s_logger = nil;
static NSString *s_actualSignedBundleID = nil;

static void PDHostMessage(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *str = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SideloadPersist HostFix] %@",str);
    PDPickerHostFixLogger callback = s_logger;
    if (callback) callback(str);
}

NSString *PDPickerHostFixActualBundleID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFErrorRef error = NULL;
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task) {
            PDHostMessage(@"Unable to create SecTask from current process");
            return;
        }
        CFTypeRef value = SecTaskCopyValueForEntitlement(
            task, CFSTR("application-identifier"), &error);
        CFRelease(task);
        if (value) {
            if (CFGetTypeID(value) == CFStringGetTypeID()) {
                NSString *raw = (__bridge NSString *)value;
                NSRange dot = [raw rangeOfString:@"."];
                if (dot.location != NSNotFound && dot.location + 1 < raw.length) {
                    s_actualSignedBundleID = [raw substringFromIndex:dot.location + 1];
                } else {
                    s_actualSignedBundleID = [raw copy];
                }
            }
            CFRelease(value);
        }
        if (error) {
            PDHostMessage(@"Reading application-identifier failed: %@", (__bridge NSError *)error);
            CFRelease(error);
        }
    });
    return s_actualSignedBundleID;
}

static void PDReplacementSetHostIdentifier(id object, SEL selector, NSString *identifier) {
    NSString *actual = PDPickerHostFixActualBundleID();
    BOOL enabled = atomic_load_explicit(&s_enabled, memory_order_relaxed);
    BOOL replace = enabled && actual.length > 0;
    NSString *target = replace ? actual : identifier;
    // Never synthesize an identity: only use the value actually granted by
    // the code signature's application-identifier entitlement.
    PDHostMessage(@"DOCConfiguration hostIdentifier: source=%@ target=%@ fixEnabled=%@ usedEntitlement=%@",
                  identifier ?: @"<nil>", target ?: @"<nil>",
                  enabled ? @"yes" : @"no", replace ? @"yes" : @"no");
    if (s_originalSetHostIdentifier) {
        s_originalSetHostIdentifier(object, selector, target);
    }
}

void PDPickerHostFixSetLogger(PDPickerHostFixLogger logger) {
    s_logger = [logger copy];
}

void PDPickerHostFixSetEnabled(BOOL enabled) {
    atomic_store_explicit(&s_enabled, enabled, memory_order_release);
    PDHostMessage(@"Fix File Picker setting=%@; signed bundle=%@; Info.plist bundle=%@",
                  enabled ? @"on" : @"off",
                  PDPickerHostFixActualBundleID() ?: @"<missing entitlement>",
                  NSBundle.mainBundle.bundleIdentifier ?: @"<missing>");
}

BOOL PDPickerHostFixIsEnabled(void) {
    return atomic_load_explicit(&s_enabled, memory_order_acquire);
}

BOOL PDPickerHostFixInstallIfAvailable(void) {
    if (![NSThread isMainThread]) {
        PDHostMessage(@"Host fix installer must be invoked on main thread");
        return atomic_load_explicit(&s_hooked, memory_order_acquire);
    }
    if (atomic_load_explicit(&s_hooked, memory_order_acquire)) return YES;
    Class config = NSClassFromString(@"DOCConfiguration");
    if (!config) {
        PDHostMessage(@"DOCConfiguration class not loaded; will retry after picker initialization");
        return NO;
    }
    SEL selector = NSSelectorFromString(@"setHostIdentifier:");
    Method method = class_getInstanceMethod(config, selector);
    if (!method) {
        PDHostMessage(@"DOCConfiguration.setHostIdentifier: unavailable on this iOS version");
        return NO;
    }
    IMP old = method_getImplementation(method);
    if (!old || old == (IMP)PDReplacementSetHostIdentifier) {
        PDHostMessage(@"Unexpected DOCConfiguration setter implementation");
        return NO;
    }
    s_originalSetHostIdentifier = (void (*)(id, SEL, NSString *))old;
    method_setImplementation(method, (IMP)PDReplacementSetHostIdentifier);
    atomic_store_explicit(&s_hooked, YES, memory_order_release);
    PDHostMessage(@"Installed DOCConfiguration hostIdentifier hook; signed bundle=%@",
                  PDPickerHostFixActualBundleID() ?: @"unavailable");
    return YES;
}

NSString *PDPickerHostFixStatus(void) {
    return [NSString stringWithFormat:@"enabled=%@ installed=%@ signedBundle=%@ plistBundle=%@",
      PDPickerHostFixIsEnabled() ? @"yes" : @"no",
      atomic_load_explicit(&s_hooked, memory_order_acquire) ? @"yes" : @"no",
      PDPickerHostFixActualBundleID() ?: @"unavailable",
      NSBundle.mainBundle.bundleIdentifier ?: @"unavailable"];
}
