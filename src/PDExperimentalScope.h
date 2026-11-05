#import <Foundation/Foundation.h>

// Mount WebKit and Cookies at their original Library paths for all injected
// apps, with their real data under Documents/SideloadPersist/Data.
// ZIP v2 handles multi-directory import and cold-start recovery.
FOUNDATION_EXPORT BOOL PDRelocateWebKitAndCookies(NSString *home, NSString *root);
FOUNDATION_EXPORT BOOL PDInitializeExtraScopes(void);
