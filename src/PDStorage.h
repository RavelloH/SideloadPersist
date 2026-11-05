#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PDStorageState) {
    PDStorageStateUnknown = 0,
    PDStorageStateReady,
    PDStorageStateRecovered,
    PDStorageStateConflict,
    PDStorageStateFailed
};

FOUNDATION_EXPORT PDStorageState PDStorageBootstrap(void);
FOUNDATION_EXPORT PDStorageState PDStorageGetState(void);
FOUNDATION_EXPORT NSString *PDStorageStatusText(void);
FOUNDATION_EXPORT NSString *PDStorageRoot(void);
FOUNDATION_EXPORT NSString *PDStorageTarget(void);
FOUNDATION_EXPORT NSString *PDStorageSource(void);
FOUNDATION_EXPORT NSString *PDStorageDocuments(void);
FOUNDATION_EXPORT BOOL PDStorageIsLinked(void);
FOUNDATION_EXPORT BOOL PDStorageIsFileSharingEnabled(void);
FOUNDATION_EXPORT NSString *PDStorageInbox(void);
FOUNDATION_EXPORT void PDStorageTrace(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);

// Refresh discovered app-owned Library mappings; used by diagnostic probes.
FOUNDATION_EXPORT void PDStorageRefreshOptionalMappings(void);
