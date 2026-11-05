#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PDArchiveIdentityState) {
    PDArchiveIdentityStateMatch = 0,
    PDArchiveIdentityStateLegacyUnknown = 1,
    PDArchiveIdentityStateDifferentApp = 2,
    PDArchiveIdentityStateInvalid = 3
};

// Inspect a ZIP's SideloadPersist manifest, without extracting user data.
// The bundle ID is only a consistency hint, not cryptographic authentication.
FOUNDATION_EXPORT PDArchiveIdentityState PDArchiveInspectIdentity(NSURL *zipURL, NSString **sourceBundleID);

// Mismatched or legacy archives require an explicit, user-confirmed override.
FOUNDATION_EXPORT NSString *PDArchiveStageZIPWithIdentityApproval(NSURL *zipURL,
                                                                  BOOL userApprovedException,
                                                                  NSError **error);

// Import a .zip from a local/provider URL. All extraction occurs into an isolated
// new staging directory; active Application Support is never overwritten here.
// On success a pending ID is saved; the next cold start applies it atomically.
FOUNDATION_EXPORT NSString *PDArchiveStageZIP(NSURL *zipURL, NSError **error);
FOUNDATION_EXPORT NSString *PDArchivePendingID(void);
