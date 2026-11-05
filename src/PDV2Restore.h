#import <Foundation/Foundation.h>

// Called by the existing bootstrap only when restore-plan.json is present.
// The original single-directory v1 restore code is not changed.
FOUNDATION_EXPORT BOOL PDV2ApplyPendingRestore(NSString *identifier);
