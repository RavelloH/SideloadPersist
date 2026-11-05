#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SPFullCycle : NSObject <WKNavigationDelegate>
- (instancetype)initWithParent:(UIViewController *)parent
                            log:(void (^)(NSString *message))log
                     completion:(void (^)(void))completion;
- (void)start;
@end
