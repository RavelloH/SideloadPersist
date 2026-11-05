#import <Foundation/Foundation.h>

// Initial research implementation: redirects the current application's
// NSUserDefaults and ordinary (non-App-Group) suite APIs to live plist files.
// CoreFoundation CFPreferences is handled separately through imported symbols.
FOUNDATION_EXPORT BOOL PDPreferencesInstallHook(void);
FOUNDATION_EXPORT BOOL PDPreferencesHookActive(void);
FOUNDATION_EXPORT NSString *PDPreferencesHookStatus(void);
