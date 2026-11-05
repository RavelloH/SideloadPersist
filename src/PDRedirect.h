#import <Foundation/Foundation.h>

// File access shim. Only Documents is redirected in v0.1.
// Returns an autoreleased NSString. Never rewrite Library, tmp or Keychain.
FOUNDATION_EXPORT NSString *PDTranslatedPath(NSString *path);
FOUNDATION_EXPORT char *PDTranslatedCString(const char *path); // malloc result, caller frees; NULL = unchanged
FOUNDATION_EXPORT void PDSetExternalDocumentsPath(NSString *path);
FOUNDATION_EXPORT BOOL PDIsRedirectActive(void);
FOUNDATION_EXPORT void PDInstallHooks(void);
