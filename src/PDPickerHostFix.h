#import <Foundation/Foundation.h>

// Experimental LiveContainer-inspired compatibility fix.
// DOCConfiguration is a private DocumentManager class; availability may vary.
// Does not change entitlements, signatures, sandbox permissions, or file contents.
typedef void (^PDPickerHostFixLogger)(NSString *message);
FOUNDATION_EXPORT void PDPickerHostFixSetLogger(PDPickerHostFixLogger logger);
FOUNDATION_EXPORT void PDPickerHostFixSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL PDPickerHostFixIsEnabled(void);
FOUNDATION_EXPORT BOOL PDPickerHostFixInstallIfAvailable(void);
FOUNDATION_EXPORT NSString *PDPickerHostFixStatus(void);
FOUNDATION_EXPORT NSString *PDPickerHostFixActualBundleID(void);
