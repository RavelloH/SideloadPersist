#import <Foundation/Foundation.h>

// Mount WebKit and Cookies at their original Library paths for all injected
// apps, with their real data under Documents/SideloadPersist/Data.
// ZIP v2 handles multi-directory import and cold-start recovery.
FOUNDATION_EXPORT BOOL PDRelocateExtendedScopes(NSString *home, NSString *root);
FOUNDATION_EXPORT BOOL PDInitializeExtraScopes(void);

// Move a selected app-owned Library/<name> directory into an Application
// Support-owned location, while leaving unrelated/system-managed paths alone.
FOUNDATION_EXPORT BOOL PDRelocateLibraryDirectory(NSString *name, NSString *home,
                                                   NSString *target, NSString **reason);
