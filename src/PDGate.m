#import "PDRedirect.h"
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
    NSData *saved = [[NSUserDefaults standardUserDefaults] dataForKey:kBookmarkKey];
    if (saved.length) {
        NSError *err = nil;
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:saved
                                               options:0 relativeToURL:nil
                                     bookmarkDataIsStale:&stale error:&err];
        if (url && [self activateFolder:url persist:stale error:&err]) {
            NSLog(@"[SideloadPersist] Restored external Documents folder.");
            return;
        }
        NSLog(@"[SideloadPersist] Bookmark access failed, reauthorization required: %@",err);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBookmarkKey];
    }
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       UISceneDidActivateNotification,
                                       UIWindowDidBecomeKeyNotification]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryShowGate)
                                            name:name object:nil];
    }
    [self tryShowGate];
    // The injected constructor may execute before a UIWindowScene is ready.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self tryShowGate]; });
}

- (BOOL)activateFolder:(NSURL *)url persist:(BOOL)persist error:(NSError **)error {
    NSLog(@"[SideloadPersist] Validating selected directory, url=%@", url);
    if (PDIsInsideOwnSandbox(url)) {
        if (error) *error = [NSError errorWithDomain:@"SideloadPersist" code:4
            userInfo:@{NSLocalizedDescriptionKey:@"不能选择应用自身的目录，请返回位置列表，选择 iCloud Drive 或其他独立存储位置中的文件夹。"}];
        return NO;
    }
    if (!url.isFileURL) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Please choose a local/file-provider folder."}];
        return NO;
    }
    NSLog(@"[SideloadPersist] Requesting security-scoped access");
    if (![url startAccessingSecurityScopedResource]) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Folder security scope denied."}];
        return NO;
    }
    __block NSError *fileError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError = nil;
    NSLog(@"[SideloadPersist] Beginning file coordination");
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging
                                     error:&coordError byAccessor:^(NSURL *newURL) {
        NSLog(@"[SideloadPersist] File coordinator acquired URL=%@",newURL);
        NSURL *docs = [newURL URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:docs
                                     withIntermediateDirectories:YES attributes:nil error:&fileError]) return;
        // Confirm permissions without touching existing user files.
        NSURL *probe = [docs URLByAppendingPathComponent:@".sideloadpersist-write-test"];
        NSData *data = [@"test" dataUsingEncoding:NSUTF8StringEncoding];
        if (![data writeToURL:probe options:NSDataWritingAtomic error:&fileError]) return;
        [[NSFileManager defaultManager] removeItemAtURL:probe error:nil];
    }];
    NSLog(@"[SideloadPersist] File coordination completed: file=%@ coord=%@",fileError,coordError);
    NSError *failure = fileError ?: coordError;
    if (failure) {
        [url stopAccessingSecurityScopedResource];
        if (error) *error=failure;
        return NO;
    }
    // Persist the ORIGINAL selected security-scoped URL, not a bare URL path.
    if (persist) {
        NSLog(@"[SideloadPersist] Saving security-scoped bookmark");
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
    NSLog(@"[SideloadPersist] Documents redirected to %@",docs.path);
    return YES;
}

- (void)tryShowGate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self tryShowGate]; });
        return;
    }
    if (PDIsRedirectActive() || s_gateController || s_choosing) return;
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
    UIViewController *host = hostWindow.rootViewController;
    while (host.presentedViewController) host = host.presentedViewController;
    if (host.isBeingDismissed || host.isBeingPresented || !host.view.window) return;
    PDGateController *gate = [[PDGateController alloc] init];
    gate.modalPresentationStyle = UIModalPresentationFullScreen;
    s_gateController = gate;
    NSLog(@"[SideloadPersist] Presenting full-screen gate in host window: %@", hostWindow);
    [host presentViewController:gate animated:NO completion:^{
        NSLog(@"[SideloadPersist] Gate ready. Awaiting folder selection.");
    }];
}

- (void)closeGate {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self closeGate]; });
        return;
    }
    NSLog(@"[SideloadPersist] Folder activated; dismissing gate.");
    [s_gateController dismissViewControllerAnimated:NO completion:nil];
    s_gateController = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    body.text=@"请选择独立于当前 App 的文件夹。\n建议：返回“浏览位置”，在 iCloud Drive 中创建一个专用目录。\n将在其中创建 Documents 子文件夹。";
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
    [button setTitle:@"选择文件夹" forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont boldSystemFontOfSize:18];
    [button addTarget:self action:@selector(chooseFolder) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,body,button,self.statusLabel]];
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
- (void)chooseFolder {
    if (s_choosing || s_validating) return;
    NSLog(@"[SideloadPersist] Opening directory picker");
    s_choosing = YES;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    picker.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:picker animated:YES completion:^{
        NSLog(@"[SideloadPersist] Directory picker presented");
    }];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSLog(@"[SideloadPersist] Directory picker cancelled");
    s_choosing=NO;
    self.statusLabel.text=@"尚未选择文件夹，应用将保持在此页面。";
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSLog(@"[SideloadPersist] Picker returned %lu URL(s)",(unsigned long)urls.count);
    if (!s_choosing || s_validating) return; // tolerate duplicate legacy delegate callbacks
    s_choosing=NO;
    s_validating=YES;
    NSURL *root=urls.firstObject;
    if (!root) { s_validating=NO; self.statusLabel.text=@"未收到目录授权，请重试。"; return; }
    self.chooseButton.enabled=NO;
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
                NSLog(@"[SideloadPersist] Folder activation failed: %@",error);
                strongSelf.chooseButton.enabled=YES;
                strongSelf.statusLabel.text=[NSString stringWithFormat:@"访问失败：%@。请换一个文件夹。",error.localizedDescription ?: @"未知错误"];
            }
        });
    });
}
// Compatibility fallback for providers which use the single-URL delegate.
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    NSLog(@"[SideloadPersist] Picker legacy single URL delegate invoked");
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
