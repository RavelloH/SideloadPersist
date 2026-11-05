#import <Foundation/Foundation.h>

// Application-owned Library directories not covered by the three built-in
// symlinks are placed inside the existing Application Support backup scope.
// No new top-level ZIP scope or restore-plan format is introduced.
// Call after Application Support has been mounted and after pending restore.
FOUNDATION_EXPORT void PDCustomLibraryMount(void);
FOUNDATION_EXPORT NSArray<NSString *> *PDCustomLibraryVerified(void);
FOUNDATION_EXPORT BOOL PDCustomLibrarySafeName(NSString *name);
