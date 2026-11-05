#import "PDStorage.h"
#import "PDIntro.h"
#import <UIKit/UIKit.h>

// The constructor runs before UIApplicationMain when the binary is loaded as a
// startup dependency. Only filesystem-safe operations happen synchronously.
// UI is scheduled for the first active scene; no App UI thread is blocked
// waiting for the picker or a network request.
__attribute__((constructor))
static void SideloadPersistEntry(void) {
    @autoreleasepool {
        PDStorageBootstrap();
        dispatch_async(dispatch_get_main_queue(), ^{
            PDIntroInstall();
        });
    }
}
