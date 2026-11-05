#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Durable on-device diagnostics. Logs are stored in the original Library,
// not the externally mapped Documents directory.
FOUNDATION_EXPORT void PDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
FOUNDATION_EXPORT NSString *PDLogSnapshot(void);
FOUNDATION_EXPORT void PDLogClear(void);
FOUNDATION_EXPORT void PDPresentDiagnostics(UIViewController *presenter);
FOUNDATION_EXPORT void PDInstallDiagnosticsButton(UIWindow *window);
