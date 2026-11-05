#import <Foundation/Foundation.h>

// Research-only relocation of WebKit and Cookies inside the disposable StorageProbe.
// Never enabled for ordinary injected apps. Incompatible with ZIP restoring these
// directories until a new multi-directory archive format is implemented.
FOUNDATION_EXPORT BOOL PDExperimentalRelocateWebKitAndCookies(NSString *home, NSString *root);
FOUNDATION_EXPORT void PDExperimentalTryFromStorageProbe(void);
