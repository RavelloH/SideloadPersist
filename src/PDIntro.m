#import "PDIntro.h"
#import "PDStorage.h"
#import "PDArchive.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kIntroShown=@"SideloadPersist.IntroAccepted.v2";
static __weak UIViewController *s_presenter=nil;
static BOOL s_presenting=NO;

@interface PDIntroController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *importButton;
@end
@interface PDIntroManager : NSObject
+ (instancetype)shared;
- (void)tryPresent;
@end

@implementation PDIntroManager
+ (instancetype)shared {
    static PDIntroManager *m; static dispatch_once_t once;
    dispatch_once(&once,^{ m=[[self alloc] init]; }); return m;
}
- (void)tryPresent {
    if (s_presenting || [[NSUserDefaults standardUserDefaults] boolForKey:kIntroShown]) return;
    UIApplication *app=UIApplication.sharedApplication;
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState!=UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden || !window.rootViewController) continue;
            UIViewController *top=window.rootViewController;
            while (top.presentedViewController) top=top.presentedViewController;
            if (!top.view.window || top.isBeingPresented || top.isBeingDismissed) continue;
            PDIntroController *intro=[[PDIntroController alloc] init];
            intro.modalPresentationStyle=UIModalPresentationPageSheet;
            if (@available(iOS 15.0,*)) {
                UISheetPresentationController *sheet=intro.sheetPresentationController;
                if (sheet) {
                    sheet.detents=@[[UISheetPresentationControllerDetent mediumDetent],
                                    [UISheetPresentationControllerDetent largeDetent]];
                    sheet.prefersGrabberVisible=YES;
                    sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;
                }
            }
            s_presenting=YES;
            s_presenter=top;
            PDStorageTrace(@"Presenting first-run introduction sheet");
            [top presentViewController:intro animated:YES completion:nil];
            return;
        }
    }
}
@end

void PDIntroInstall(void) {
    PDIntroManager *m=[PDIntroManager shared];
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center addObserver:m selector:@selector(tryPresent) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:m selector:@selector(tryPresent) name:UISceneDidActivateNotification object:nil];
    [center addObserver:m selector:@selector(tryPresent) name:UIWindowDidBecomeKeyNotification object:nil];
    [m tryPresent];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)),
                   dispatch_get_main_queue(),^{ [m tryPresent]; });
}

@implementation PDIntroController
- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *label=[[UILabel alloc] init];
    label.text=text;
    label.font=[UIFont systemFontOfSize:size];
    label.numberOfLines=0;
    label.textColor=color;
    label.textAlignment=NSTextAlignmentCenter;
    return label;
}
- (UIButton *)button:(NSString *)name action:(SEL)action prominent:(BOOL)prominent {
    UIButton *btn=[UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:name forState:UIControlStateNormal];
    btn.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    if (prominent) {
        btn.backgroundColor=UIColor.systemBlueColor;
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    } else btn.backgroundColor=UIColor.tertiarySystemFillColor;
    btn.layer.cornerRadius=12;
    btn.contentEdgeInsets=UIEdgeInsetsMake(12,12,12,12);
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    NSString *appName=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?:
                      NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"当前 App";
    UILabel *heading=[self label:@"SideloadPersist" size:24 color:UIColor.labelColor];
    heading.font=[UIFont boldSystemFontOfSize:24];
    UILabel *intro=[self label:@"已为当前应用准备可在「文件」App 中访问的数据目录。\n后续运行将静默工作，不会反复弹窗。"
                         size:14 color:UIColor.secondaryLabelColor];
    UILabel *path=[self label:[NSString stringWithFormat:@"在我的 iPhone › %@ › SideloadPersist",appName]
                        size:14 color:UIColor.labelColor];
    path.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    path.numberOfLines=0;
    self.status=[self label:[NSString stringWithFormat:@"状态：%@",PDStorageStatusText()]
                       size:13 color:(PDStorageGetState()==PDStorageStateFailed ||
                         PDStorageGetState()==PDStorageStateConflict) ? UIColor.systemRedColor : UIColor.secondaryLabelColor];
    UILabel *hint=[self label:@"签名过期但应用仍安装时，可在「文件」App 中备份此文件夹。\n换证书重新安装后，先打开 App 初始化，再退出；将备份数据恢复到此目录，下次启动时即可恢复映射。\n删除 App 前必须另存副本；卸载会删除本地 Documents。"
                       size:12 color:UIColor.secondaryLabelColor];
    UILabel *warning=[self label:PDStorageIsFileSharingEnabled() ?
        @"文件共享已启用。当前仅重定位 Library/Application Support；Preferences、Keychain 和其他系统数据暂未覆盖。" :
        @"当前 IPA 未同时开启文件共享与原地打开文件。请在签名工具中开启「文件访问」，否则文件夹可能不会显示在「文件」App 中。"
        size:12 color:UIColor.systemOrangeColor];
    UIButton *openFiles=[self button:@"在「文件」App 中打开" action:@selector(openFiles) prominent:NO];
    self.importButton=[self button:@"导入备份 ZIP" action:@selector(chooseImport) prominent:NO];
    UIButton *done=[self button:@"完成 · 以后静默运行" action:@selector(accept) prominent:YES];

    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:
        @[heading,intro,path,openFiles,self.importButton,self.status,warning,hint,done]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=12;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    UIScrollView *scroll=[[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.alwaysBounceVertical=YES;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}
- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:body
                                                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)openFiles {
    NSString *path=PDStorageRoot();
    NSCharacterSet *allowed=[NSCharacterSet URLPathAllowedCharacterSet];
    NSString *encoded=[path stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: path;
    NSURL *url=[NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:encoded]];
    // shareddocuments is an undocumented Files app URL scheme, not a public API.
    // Do not treat success as guaranteed across iOS versions or signing tools.
    if (!url) {
        [self showMessage:@"请手动打开文件 App" body:@"在我的 iPhone → 当前 App → SideloadPersist"];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:@"请手动打开文件 App"
                             body:@"无法直接跳转。请前往「文件」→「浏览」→「在我的 iPhone」→ 当前 App → SideloadPersist。"];
            });
        }
    }];
}
- (void)chooseImport {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"导入备份 ZIP"
        message:@"不会立即覆盖运行中的数据。先验证并暂存，完全退出后再次启动时应用恢复。也可以把 ZIP 放入 SideloadPersist/Inbox，再从此处导入。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从文件选择器导入"
          style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
             initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        picker.delegate=self;
        picker.allowsMultipleSelection=NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"扫描 Inbox 中的 ZIP"
           style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:PDStorageInbox() error:nil];
        NSMutableArray<NSString *> *zips=[NSMutableArray array];
        for (NSString *f in files) if ([f.pathExtension.lowercaseString isEqualToString:@"zip"])
            [zips addObject:f];
        if (zips.count!=1) {
            [self showMessage:@"未找到唯一 ZIP" body:@"请把一个备份 .zip 文件放在「SideloadPersist/Inbox」中，再重试。"];
            return;
        }
        [self stageImport:[NSURL fileURLWithPath:[PDStorageInbox() stringByAppendingPathComponent:zips.firstObject]]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView=self.importButton;
        sheet.popoverPresentationController.sourceRect=self.importButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;
    if (url) [self stageImport:url];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    PDStorageTrace(@"ZIP import picker cancelled");
}
- (void)stageImport:(NSURL *)url {
    self.importButton.enabled=NO;
    self.status.text=@"正在隔离校验 ZIP 数据，请勿退出…";
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error=nil;
        NSString *identifier=PDArchiveStageZIP(url,&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            PDIntroController *strong=weakSelf;
            if (!strong) return;
            strong.importButton.enabled=YES;
            if (identifier) {
                strong.status.text=@"备份已暂存。完全退出当前 App，重新启动后恢复生效。";
                [strong showMessage:@"备份已准备"
                               body:@"当前运行中的数据未被覆盖。请完全退出 App 后重新打开，插件将在主程序启动前替换 Application Support，并将旧数据保留在 SideloadPersist/Backups。"];
            } else {
                strong.status.text=@"导入失败，原有数据未修改。";
                [strong showMessage:@"导入失败" body:error.localizedDescription ?: @"压缩包验证未通过"];
            }
        });
    });
}
- (void)accept {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kIntroShown];
    s_presenting=NO;
    [[PDIntroManager shared] class]; // retain shared manager for observer lifetime
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
