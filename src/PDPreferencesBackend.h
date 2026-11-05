#import <Foundation/Foundation.h>

// One canonical plist per managed preferences domain.
// This is a live key/value store: writes go directly to Data/Preferences.
// No periodic snapshots, and no renaming the system-owned Library/Preferences.
FOUNDATION_EXPORT NSString *PDPreferencesRoot(void);
FOUNDATION_EXPORT NSString *PDPreferencesDomainFile(NSString *domain);
FOUNDATION_EXPORT BOOL PDPreferencesEnsureDomain(NSString *domain, NSDictionary *initial, NSError **error);
FOUNDATION_EXPORT id PDPreferencesValue(NSString *domain, NSString *key, BOOL *present, BOOL *removed);
FOUNDATION_EXPORT NSDictionary *PDPreferencesValues(NSString *domain);
FOUNDATION_EXPORT NSArray<NSString *> *PDPreferencesRemovedKeys(NSString *domain);
FOUNDATION_EXPORT BOOL PDPreferencesWriteValue(NSString *domain, NSString *key, id value, NSError **error);
FOUNDATION_EXPORT BOOL PDPreferencesReplaceDomain(NSString *domain, NSDictionary *values, NSError **error);
FOUNDATION_EXPORT BOOL PDPreferencesRemoveDomain(NSString *domain, NSError **error);
FOUNDATION_EXPORT BOOL PDPreferencesDomainExists(NSString *domain);
// Only app-owned preference domains can be backed up; system/framework domains
// and absolute filesystem-style domain names always stay native.
FOUNDATION_EXPORT BOOL PDPreferencesShouldManageDomain(NSString *domain);
// Non-destructively move legacy system-domain copies out of exported Documents.
// On failure, callers must not advertise Preferences as fully managed.
FOUNDATION_EXPORT BOOL PDPreferencesQuarantineUnmanagedDomains(NSUInteger *count, NSError **error);
// A failed managed-domain mutation can fall back to native defaults and leave
// the exported copy stale. Record this as a sticky, visible backup blocker.
FOUNDATION_EXPORT void PDPreferencesMarkIntegrityFailure(NSString *operation);
FOUNDATION_EXPORT BOOL PDPreferencesIntegrityOK(void);
FOUNDATION_EXPORT NSString *PDPreferencesIntegrityWarning(void);
FOUNDATION_EXPORT NSDictionary *PDPreferencesHealth(void);
FOUNDATION_EXPORT BOOL PDPreferencesValidateDirectory(NSString *directory, NSString **reason);
