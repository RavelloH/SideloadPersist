#import "PDRedirect.h"
#import "PDDiagnostics.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Entry point for the injected dylib. Do not run UIKit during dyld initialization.
// A full-screen modal gates user interaction but cannot freeze background threads.
// Present in the host app's own window hierarchy; an extra UIWindowLevelAlert
// window could intercept touches intended for the system document picker.
static NSString *const kBookmarkKey = @"SideloadPersist.RootBookmark.v1";
static UIViewController *s_gateController;
static NSURL *s_scopedURL;
static BOOL s_accessStarted = NO;
static BOOL s_bootstrapped = NO;
static BOOL s_choosing = NO;
static BOOL s_validating = NO;

static NSString *PDNormalizeContainerPath(NSString *p) {
    if ([p hasPrefix:@"/private/var/"]) return [p substringFromIndex:8];
    return p ?: @"";
}
static BOOL PDIsInsideOwnSandbox(NSURL *folder) {
    NSString *root = PDNormalizeContainerPath(NSHomeDirectory().stringByStandardizingPath);
    NSString *path = PDNormalizeContainerPath(folder.path.stringByStandardizingPath);
    return [path isEqualToString:root] ||
           [path hasPrefix:[root stringByAppendingString:@"/"]];
}

@interface PDGateController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *chooseButton;
@property(nonatomic,strong) UIButton *compatibilityButton;
@end

@interface PDGateManager : NSObject
+ (instancetype)shared;
- (void)bootstrap;
- (void)tryShowGate;
- (void)closeGate;
- (BOOL)activateFolder:(NSURL *)url persist:(BOOL)persist error:(NSError **)error;
@end

@implementation PDGateManager

+ (instancetype)shared {
    static PDGateManager *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[PDGateManager alloc] init]; });
    return m;
}

- (void)bootstrap {
    if (s_bootstrapped) return;
    s_bootstrapped = YES;
    PDInstallHooks();
    PDLog(@"Dylib startup; bundle=%@ system=%@",NSBundle.mainBundle.bundleIdentifier ?: @"unknown",UIDevice.currentDevice.systemVersion);
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       UISceneDidActivateNotification,
                                       UIWindowDidBecomeKeyNotification]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryShowGate)
                                            name:name object:nil];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self tryShowGate]; });
    NSData *saved = [[NSUserDefaults standardUserDefaults] dataForKey:kBookmarkKey];
    if (saved.length) {
        NSError *err = nil;
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:saved
                                               options:0 relativeToURL:nil
                                     bookmarkDataIsStale:&stale error:&err];
        if (url && [self activateFolder:url persist:stale error:&err]) {
            PDLog(@"Restored external Documents folder.");
            [self tryShowGate];
            return;
        }
        PDLog(@"Bookmark access failed, reauthorization required: %@",err);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBookmarkKey];
    }
    [self tryShowGate];
}

- (BOOL)activateFolder:(NSURL *)url persist:(BOOL)persist error:(NSError **)error {
    PDLog(@"Validating selected directory, url=%@", url);
    if (PDIsInsideOwnSandbox(url)) {
        if (error) *error = [NSError errorWithDomain:@"SideloadPersist" code:4
            userInfo:@{NSLocalizedDescriptionKey:@"不能选择应用自身的目录，请返回位置列表，选择 iCloud Drive 或其他独立存储位置中的文件夹。"}];
        return NO;
    }
    if (!url.isFileURL) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Please choose a local/file-provider folder."}];
        return NO;
    }
    PDLog(@"Requesting security-scoped access");
    if (![url startAccessingSecurityScopedResource]) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Folder security scope denied."}];
        return NO;
    }
    __block NSError *fileError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError = nil;
    PDLog(@"Beginning file coordination");
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging
                                     error:&coordError byAccessor:^(NSURL *newURL) {
        PDLog(@"File coordinator acquired URL=%@",newURL);
        NSURL *docs = [newURL URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:docs
                                     withIntermediateDirectories:YES attributes:nil error:&fileError]) return;
        // Confirm permissions without touching existing user files.
        NSURL *probe = [docs URLByAppendingPathComponent:@".sideloadpersist-write-test"];
        NSData *data = [@"test" dataUsingEncoding:NSUTF8StringEncoding];
        if (![data writeToURL:probe options:NSDataWritingAtomic error:&fileError]) return;
        [[NSFileManager defaultManager] removeItemAtURL:probe error:nil];
    }];
    PDLog(@"File coordination completed: file=%@ coord=%@",fileError,coordError);
    NSError *failure = fileError ?: coordError;
    if (failure) {
        [url stopAccessingSecurityScopedResource];
        if (error) *error=failure;
        return NO;
    }
    // Persist the ORIGINAL selected security-scoped URL, not a bare URL path.
    if (persist) {
        PDLog(@"Saving security-scoped bookmark");
        NSError *bookmarkError = nil;
        NSData *bookmark = [url bookmarkDataWithOptions:0
                         includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];
        if (!bookmark.length) {
            [url stopAccessingSecurityScopedResource];
            if(error) *error = bookmarkError ?: [NSError errorWithDomain:@"SideloadPersist" code:3 userInfo:nil];
            return NO;
        }
        [[NSUserDefaults standardUserDefaults] setObject:bookmark forKey:kBookmarkKey];
    }
    if (s_accessStarted && s_scopedURL) [s_scopedURL stopAccessingSecurityScopedResource];
    s_scopedURL = url;
    s_accessStarted = YES;
    NSURL *docs = [url URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    PDSetExternalDocumentsPath(docs.path);
    PDLog(@"Documents redirected to %@",docs.path);
    return YES;
}

- (void)tryShowGate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryShowGate]; });
        return;
    }
    if (s_choosing) return;
    UIWindow *hostWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.rootViewController && !window.hidden) {
                hostWindow = window;
                break;
            }
        }
        if (hostWindow) break;
    }
    if (!hostWindow) return;
    if (PDIsRedirectActive()) {
        PDInstallDiagnosticsButton(hostWindow);
        return;
    }
    if (s_gateController) return;
    UIViewController *host = hostWindow.rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;
    if (host.isBeingDismissed || host.isBeingPresented || !host.view.window) return;
    PDGateController *gate = [[PDGateController alloc] init];
    gate.modalPresentationStyle = UIModalPresentationFullScreen;
    s_gateController = gate;
    PDLog(@"Presenting full-screen gate in host window: %@", hostWindow);
    [host presentViewController:gate animated:NO completion:^{
        PDLog(@"Gate ready. Awaiting folder selection.");
    }];
}

- (void)closeGate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self closeGate]; });
        return;
    }
    PDLog(@"Folder activated; dismissing gate.");
    [s_gateController dismissViewControllerAnimated:NO completion:^{
        [self tryShowGate];
    }];
    s_gateController = nil;
}
@end

@implementation PDGateController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [[UILabel alloc] init];
    title.text=@"SideloadPersist";
    title.font=[UIFont boldSystemFontOfSize:27];
    title.textAlignment=NSTextAlignmentCenter;
    UILabel *body=[[UILabel alloc] init];
    body.text=@"必须选择外部文件夹，而不是当前 App 自己的文件夹。\n请返回“浏览位置”，在 iCloud Drive 创建或进入一个专用子文件夹，再点击“打开”。";
    body.textColor=UIColor.secondaryLabelColor;
    body.numberOfLines=0;
    body.textAlignment=NSTextAlignmentCenter;
    body.font=[UIFont systemFontOfSize:15];
    self.statusLabel=[[UILabel alloc] init];
    self.statusLabel.text=@"选择目录前，主界面不可操作。";
    self.statusLabel.font=[UIFont systemFontOfSize:13];
    self.statusLabel.textColor=UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines=0;
    self.statusLabel.textAlignment=NSTextAlignmentCenter;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    self.chooseButton=button;
    [button setTitle:@"选择外部文件夹（标准）" forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont boldSystemFontOfSize:18];
    [button addTarget:self action:@selector(chooseFolder) forControlEvents:UIControlEventTouchUpInside];
    UIButton *alternate = [UIButton buttonWithType:UIButtonTypeSystem];
    [alternate setTitle:@"兼容模式重试" forState:UIControlStateNormal];
    alternate.titleLabel.font=[UIFont systemFontOfSize:15];
    [alternate addTarget:self action:@selector(chooseFolderCompatibility) forControlEvents:UIControlEventTouchUpInside];
    self.compatibilityButton = alternate;
    UIButton *diagnostics=[UIButton buttonWithType:UIButtonTypeSystem];
    [diagnostics setTitle:@"查看诊断日志" forState:UIControlStateNormal];
    diagnostics.titleLabel.font=[UIFont systemFontOfSize:15];
    [diagnostics addTarget:self action:@selector(showDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,body,button,alternate,diagnostics,self.statusLabel]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=24;
    stack.alignment=UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24]
    ]];
}
- (void)showDiagnostics {
    PDPresentDiagnostics(self);
}
- (void)chooseFolder {
    [self openFolderPickerUsingCompatibilityMode:NO];
}
- (void)chooseFolderCompatibility {
    [self openFolderPickerUsingCompatibilityMode:YES];
}
- (void)openFolderPickerUsingCompatibilityMode:(BOOL)compatibility {
    if (s_choosing || s_validating) return;
    s_choosing = YES;
    self.statusLabel.text = compatibility ? @"已启动兼容模式，请选择外部文件夹。" : @"请选择 iCloud Drive 或其他独立位置的子目录。";
    // Standard: Apple's documented folder-picker initializer and native presentation.
    // Compatibility: legacy open-mode initializer and over-full-screen presentation,
    // for diagnosing provider-specific or iOS 27 behavior. No sandbox bypass.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = compatibility
      ? [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[UTTypeFolder.identifier]
                                                        inMode:UIDocumentPickerModeOpen]
      : [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
#pragma clang diagnostic pop
    if (!picker) {
        s_choosing = NO;
        self.statusLabel.text = @"文件选择器初始化失败，请打开诊断日志。";
        PDLog(@"Folder picker initialization returned nil, compatibility=%@",compatibility ? @"yes" : @"no");
        return;
    }
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    if (compatibility) picker.modalPresentationStyle=UIModalPresentationOverFullScreen;
    PDLog(@"Opening folder picker; compatibility=%@ presentation=%ld mode=%ld",
          compatibility ? @"yes" : @"no", (long)picker.modalPresentationStyle,
          (long)picker.documentPickerMode);
    [self presentViewController:picker animated:YES completion:^{
        PDLog(@"Directory picker presented; compatibility=%@",compatibility ? @"yes" : @"no");
    }];
    // This does not simulate a button press: UIKit does not expose the native
    // Open button action. It records that the picker is still pending.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf && s_choosing && weakSelf.presentedViewController == picker) {
            PDLog(@"Folder picker still awaiting selection after 15s; no success or cancel callback yet; compatibility=%@",
                  compatibility ? @"yes" : @"no");
        }
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    PDLog(@"Directory picker cancelled; no directory URL granted");
    s_choosing=NO;
    self.statusLabel.text=@"未收到选中目录。如“打开”无反应，请从“浏览位置”进入 iCloud Drive 的具体子文件夹；也可以试试兼容模式。";
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    PDLog(@"Picker returned %lu URL(s)",(unsigned long)urls.count);
    if (!s_choosing || s_validating) return; // tolerate duplicate legacy delegate callbacks
    s_choosing=NO;
    s_validating=YES;
    NSURL *root=urls.firstObject;
    if (!root) { s_validating=NO; self.statusLabel.text=@"未收到目录授权，请重试。"; return; }
    self.chooseButton.enabled=NO;
    self.compatibilityButton.enabled=NO;
    self.statusLabel.text=@"正在验证文件夹访问权限……";
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (s_validating && weakSelf) {
            weakSelf.statusLabel.text=@"文件提供器仍在响应。若持续停留在这里，请记录系统日志中的 [SideloadPersist] 信息。";
        }
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error=nil;
        BOOL ok=[[PDGateManager shared] activateFolder:root persist:YES error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            PDGateController *strongSelf=weakSelf;
            s_validating=NO;
            if (!strongSelf) return;
            if (ok) [[PDGateManager shared] closeGate];
            else {
                PDLog(@"Folder activation failed: %@",error);
                strongSelf.chooseButton.enabled=YES;
                strongSelf.compatibilityButton.enabled=YES;
                strongSelf.statusLabel.text=[NSString stringWithFormat:@"访问失败：%@。请换一个文件夹。",error.localizedDescription ?: @"未知错误"];
            }
        });
    });
}
// Compatibility fallback for providers which use the single-URL delegate.
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    PDLog(@"Picker legacy single URL delegate invoked");
    [self documentPicker:controller didPickDocumentsAtURLs:url ? @[url] : @[]];
}
@end

__attribute__((constructor))
static void PDInitialize(void) {
    // Never block dyld startup or perform UIKit calls in the constructor.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PDGateManager shared] bootstrap];
    });
}
