#import "PDDiagnostics.h"
#import "PDRedirect.h"
#include <stdarg.h>

static const NSUInteger kMaxLogBytes = 96 * 1024;
static const NSInteger kDiagnosticsButtonTag = 2750915;

static dispatch_queue_t PDLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.sideloadpersist.diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *PDLogPath(void) {
    // Explicitly outside Documents. Survives normal app restarts, not app deletion.
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/SideloadPersist/diagnostics.log"];
}

static void PDEnsureLogDir(void) {
    NSString *dir = [PDLogPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
}

static NSString *PDTrimLog(NSString *text) {
    if (text.length == 0) return @"";
    while (text.length > 0 && [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kMaxLogBytes) {
        NSRange next = [text rangeOfString:@"\n"];
        if (next.location == NSNotFound) {
            return [text substringFromIndex:text.length / 2];
        }
        text = [text substringFromIndex:NSMaxRange(next)];
    }
    return text;
}

void PDLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SideloadPersist] %@", message);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [formatter stringFromDate:[NSDate date]], message ?: @""];
    dispatch_sync(PDLogQueue(), ^{
        @autoreleasepool {
            PDEnsureLogDir();
            NSString *path = PDLogPath();
            NSMutableData *data = [[NSMutableData alloc] initWithContentsOfFile:path];
            if (!data) data = [NSMutableData data];
            [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            if (data.length > kMaxLogBytes) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (text) {
                    data = [[PDTrimLog(text) dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                } else {
                    data = [[line dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                }
            }
            [data writeToFile:path atomically:YES];
        }
    });
}

NSString *PDLogSnapshot(void) {
    __block NSString *snapshot = nil;
    dispatch_sync(PDLogQueue(), ^{
        snapshot = [NSString stringWithContentsOfFile:PDLogPath()
                                             encoding:NSUTF8StringEncoding error:nil];
    });
    return snapshot ?: @"（暂无 SideloadPersist 日志）\n";
}

void PDLogClear(void) {
    dispatch_sync(PDLogQueue(), ^{
        PDEnsureLogDir();
        [@"" writeToFile:PDLogPath() atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
    });
    PDLog(@"Diagnostic history cleared by user");
}

@interface PDDiagnosticsController : UIViewController
@property(nonatomic,strong) UITextView *logView;
@property(nonatomic,strong) UILabel *statusLabel;
@end

@implementation PDDiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SideloadPersist 日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem = done;
    UIBarButtonItem *copy = [[UIBarButtonItem alloc]
        initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(copyLogs)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc]
        initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClear)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    self.navigationItem.rightBarButtonItems = @[copy, refresh, clear];

    UILabel *status = [[UILabel alloc] init];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    status.numberOfLines = 0;
    status.textColor = UIColor.secondaryLabelColor;
    self.statusLabel = status;
    [self.view addSubview:status];

    UITextView *log = [[UITextView alloc] init];
    log.translatesAutoresizingMaskIntoConstraints = NO;
    log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    log.editable = NO;
    log.selectable = YES;
    log.backgroundColor = UIColor.secondarySystemBackgroundColor;
    log.textColor = UIColor.labelColor;
    log.alwaysBounceVertical = YES;
    self.logView = log;
    [self.view addSubview:log];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"如果点“打开”无响应，请取消文件选择，返回这里点击刷新、复制日志。\n日志保存在当前 App 的 Library 中，App 重启后仍可查看，删除 App 后不会保留。";
    [self.view addSubview:hint];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [status.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [log.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:12],
        [log.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [log.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [hint.topAnchor constraintEqualToAnchor:log.bottomAnchor constant:8],
        [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [hint.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}
- (void)refresh {
    self.logView.text = PDLogSnapshot();
    NSString *mode = PDIsRedirectActive() ? @"已激活 Documents 重定向" : @"等待目录授权";
    self.statusLabel.text = [NSString stringWithFormat:@"状态：%@\n版本：v0.4（目录选择诊断版）", mode];
    NSUInteger length = self.logView.text.length;
    if (length) [self.logView scrollRangeToVisible:NSMakeRange(length-1, 1)];
}
- (void)copyLogs {
    NSString *header = [NSString stringWithFormat:
        @"SideloadPersist v0.4\niOS: %@\nBundle ID: %@\nRedirect: %@\n--- Logs ---\n",
        UIDevice.currentDevice.systemVersion,
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        PDIsRedirectActive() ? @"active" : @"inactive"];
    [UIPasteboard generalPasteboard].string = [header stringByAppendingString:PDLogSnapshot()];
    PDLog(@"Diagnostic log copied to clipboard");
    [self refresh];
}
- (void)confirmClear {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"清空日志？"
         message:@"这只会清除 SideloadPersist 的诊断记录，不会删除任何应用数据。"
         preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                          handler:^(__unused UIAlertAction *action) {
        PDLogClear(); [weakSelf refresh];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

void PDPresentDiagnostics(UIViewController *presenter) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ PDPresentDiagnostics(presenter); });
        return;
    }
    if (!presenter) return;
    UIViewController *top = presenter;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top.view.window) return;
    PDDiagnosticsController *controller = [[PDDiagnosticsController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    PDLog(@"Presenting on-device diagnostics interface");
    [top presentViewController:nav animated:YES completion:nil];
}

@interface PDLauncher : NSObject
+ (instancetype)shared;
- (void)tap:(UIButton *)sender;
@end
@implementation PDLauncher
+ (instancetype)shared {
    static PDLauncher *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[PDLauncher alloc] init]; });
    return shared;
}
- (void)tap:(UIButton *)sender {
    PDPresentDiagnostics(sender.window.rootViewController);
}
@end

void PDInstallDiagnosticsButton(UIWindow *window) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ PDInstallDiagnosticsButton(window); });
        return;
    }
    UIView *root = window.rootViewController.view;
    if (!root || [root viewWithTag:kDiagnosticsButtonTag]) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = kDiagnosticsButtonTag;
    [button setTitle:@"日志" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.88];
    button.layer.cornerRadius = 11;
    button.layer.borderWidth = 1;
    button.layer.borderColor = UIColor.separatorColor.CGColor;
    button.accessibilityLabel = @"SideloadPersist 诊断日志";
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:[PDLauncher shared] action:@selector(tap:)
           forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:button];
    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:46],
        [button.heightAnchor constraintEqualToConstant:32],
        [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [button.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];
    PDLog(@"Added diagnostic launcher to host view");
}
