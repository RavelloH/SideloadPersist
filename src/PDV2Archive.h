#import <Foundation/Foundation.h>

// New multi-directory layout uses Incoming/<id>/Data/<scope> and a restore-plan.
// The legacy Application Support-only layout continues through PDArchive.m.
FOUNDATION_EXPORT BOOL PDV2ZIPHasExtraScopes(NSURL *url);
FOUNDATION_EXPORT BOOL PDV2ZIPHasUnsupportedScopes(NSURL *url);
FOUNDATION_EXPORT NSString *PDV2StageZIP(NSURL *url, NSError **error);
FOUNDATION_EXPORT BOOL PDV2AllowsExtraScopes(void);
