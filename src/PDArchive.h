#import <Foundation/Foundation.h>

// Import a .zip from a local/provider URL. All extraction occurs into an isolated
// new staging directory; active Application Support is never overwritten here.
// On success a pending ID is saved; the next cold start applies it atomically.
FOUNDATION_EXPORT NSString *PDArchiveStageZIP(NSURL *zipURL, NSError **error);
FOUNDATION_EXPORT NSString *PDArchivePendingID(void);
