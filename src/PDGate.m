#import "PDRedirect.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Entry point for the injected dylib. Do not run UIKit during dyld initialization.
// The overlay gates user interaction only; it cannot suspend arbitrary startup threads.
static NSString *const kBookmarkKey = @"SideloadPersist.RootBookmark.v1";
static UIWindow *s_gateWindow;
static __weak UIWindow *s_previousKeyWindow;
static NSURL *s_scopedURL;
static BOOL s_accessStarted = NO;
static BOOL s_bootstrapped = NO;
static BOOL s_choosing = NO;

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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tryShowGate)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    [self tryShowGate];
}

- (BOOL)activateFolder:(NSURL *)url persist:(BOOL)persist error:(NSError **)error {
    if (!url.isFileURL) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Please choose a local/file-provider folder."}];
        return NO;
    }
    if (![url startAccessingSecurityScopedResource]) {
        if(error) *error=[NSError errorWithDomain:@"SideloadPersist" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Folder security scope denied."}];
        return NO;
    }
    __block NSError *fileError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordError = nil;
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging
                                     error:&coordError byAccessor:^(NSURL *newURL) {
        NSURL *docs = [newURL URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:docs
                                     withIntermediateDirectories:YES attributes:nil error:&fileError]) return;
        // Confirm permissions without touching existing user files.
        NSURL *probe = [docs URLByAppendingPathComponent:@".sideloadpersist-write-test"];
        NSData *data = [@"test" dataUsingEncoding:NSUTF8StringEncoding];
        if (![data writeToURL:probe options:NSDataWritingAtomic error:&fileError]) return;
        [[NSFileManager defaultManager] removeItemAtURL:probe error:nil];
    }];
    NSError *failure = fileError ?: coordError;
    if (failure) {
        [url stopAccessingSecurityScopedResource];
        if (error) *error=failure;
        return NO;
    }
    // Persist the ORIGINAL selected security-scoped URL, not a bare URL path.
    if (persist) {
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
    if (PDIsRedirectActive() || s_gateWindow || s_choosing) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
             s.activationState == UISceneActivationStateForegroundActive) { scene=(UIWindowScene *)s; break; }
    }
    if (!scene) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:[UIWindowScene class]]) { scene=(UIWindowScene *)s; break; }
    }
    if (!scene) return; // will retry on UIApplicationDidBecomeActive
    for (UIWindow *w in scene.windows) if (w.isKeyWindow) { s_previousKeyWindow = w; break; }
    s_gateWindow = [[UIWindow alloc] initWithWindowScene:scene];
    s_gateWindow.windowLevel = UIWindowLevelAlert + 2;
    s_gateWindow.rootViewController = [[PDGateController alloc] init];
    s_gateWindow.backgroundColor = UIColor.systemBackgroundColor;
    [s_gateWindow makeKeyAndVisible];
}

- (void)closeGate {
    [s_gateWindow.rootViewController dismissViewControllerAnimated:NO completion:nil];
    s_gateWindow.hidden = YES;
    s_gateWindow.rootViewController = nil;
    s_gateWindow = nil;
    [s_previousKeyWindow makeKeyWindow];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
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
    body.text=@"首次启动需要选择一个持久化数据文件夹。\n将在所选目录中创建 Documents 子文件夹。\n重新安装后可以再次选择同一文件夹。";
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
    if (s_choosing) return;
    s_choosing = YES;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    s_choosing=NO;
    self.statusLabel.text=@"尚未选择文件夹，应用将保持在此页面。";
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    s_choosing=NO;
    NSURL *root=urls.firstObject;
    if (!root) { self.statusLabel.text=@"未收到目录授权，请重试。"; return; }
    self.chooseButton.enabled=NO;
    self.statusLabel.text=@"正在验证文件夹访问权限……";
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error=nil;
        BOOL ok=[[PDGateManager shared] activateFolder:root persist:YES error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            PDGateController *strongSelf=weakSelf;
            if (!strongSelf) return;
            if (ok) [[PDGateManager shared] closeGate];
            else {
                strongSelf.chooseButton.enabled=YES;
                strongSelf.statusLabel.text=[NSString stringWithFormat:@"访问失败：%@。请换一个文件夹。",error.localizedDescription ?: @"未知错误"];
            }
        });
    });
}
@end

__attribute__((constructor))
static void PDInitialize(void) {
    // Never block dyld startup or perform UIKit calls in the constructor.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PDGateManager shared] bootstrap];
    });
}
