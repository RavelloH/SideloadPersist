#import "PDIntro.h"
#import "PDStorage.h"
#import "PDArchive.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdlib.h>

static NSString *const kIntroShown = @"SideloadPersist.IntroAccepted.v3";
static BOOL s_presenting = NO;
static BOOL s_importInProgress = NO;
static BOOL PDInboxHasBackup(void) {
    NSArray<NSString *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:PDStorageInbox() error:nil];
    for (NSString *name in files) if ([name.pathExtension.lowercaseString isEqualToString:@"zip"]) return YES;
    return NO;
}

static UIColor *PDAccent(void) { return [UIColor colorWithRed:0.20 green:0.57 blue:0.95 alpha:1]; }
static UIColor *PDSecondaryBackground(void) { return UIColor.secondarySystemGroupedBackgroundColor; }

@interface PDWelcomeController : UIViewController <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic,strong) UIButton *importButton;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIView *bodyContainer;
@property(nonatomic,assign) BOOL committed;
- (void)presentCompletion;
@end

@interface PDCompleteController : UIViewController
@end

@interface PDIntroManager : NSObject
+ (instancetype)shared;
- (void)tryPresent;
@end

@implementation PDIntroManager
+ (instancetype)shared {
    static PDIntroManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [PDIntroManager new]; });
    return manager;
}
- (void)tryPresent {
    if (s_presenting) return;
    BOOL pending = PDArchivePendingID().length > 0;
    BOOL seen = [[NSUserDefaults standardUserDefaults] boolForKey:kIntroShown];
    if (seen && !pending && !PDInboxHasBackup()) return;
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden || !window.rootViewController) continue;
            UIViewController *presenter = window.rootViewController;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            if (!presenter.view.window || presenter.isBeingPresented || presenter.isBeingDismissed) continue;
            PDWelcomeController *controller = [PDWelcomeController new];
            controller.modalPresentationStyle = UIModalPresentationPageSheet;
            if (@available(iOS 15.0, *)) {
                UISheetPresentationController *sheet = controller.sheetPresentationController;
                // One tall resting position: plenty of room without a nested
                // scrolling region, and no second detent for upward expansion.
                if (@available(iOS 16.0, *)) {
                    UISheetPresentationControllerDetentIdentifier identifier = @"sideloadpersist.welcome";
                    sheet.detents = @[[UISheetPresentationControllerDetent
                        customDetentWithIdentifier:identifier
                        resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                            CGFloat maximum = context.maximumDetentValue;
                            return MIN(maximum, MAX(640.0, maximum * 0.84));
                        }]];
                    sheet.selectedDetentIdentifier = identifier;
                } else {
                    // iOS 15 has no custom detents; use large rather than an
                    // undersized medium sheet. Users can still dismiss downward.
                    sheet.detents = @[[UISheetPresentationControllerDetent largeDetent]];
                }
                sheet.prefersGrabberVisible = YES;
                sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
                sheet.preferredCornerRadius = 28;
            }
            controller.presentationController.delegate=controller;
            s_presenting = YES;
            PDStorageTrace(@"Showing first-run sheet; pending restore=%@",pending?@"yes":@"no");
            [presenter presentViewController:controller animated:YES completion:^{
                if (pending) [controller presentCompletion];
            }];
            return;
        }
    }
}
@end

void PDIntroInstall(void) {
    PDIntroManager *manager = [PDIntroManager shared];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:manager selector:@selector(tryPresent) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:manager selector:@selector(tryPresent) name:UISceneDidActivateNotification object:nil];
    [center addObserver:manager selector:@selector(tryPresent) name:UIWindowDidBecomeKeyNotification object:nil];
    [manager tryPresent];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [manager tryPresent]; });
}

static UILabel *PDLabel(NSString *message, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}
static UIButton *PDButton(NSString *title, BOOL filled) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 15;
    button.clipsToBounds = YES;
    button.backgroundColor = filled ? PDAccent() : PDSecondaryBackground();
    [button setTitleColor:filled ? UIColor.whiteColor : UIColor.labelColor forState:UIControlStateNormal];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:49].active = YES;
    return button;
}
static void PDAddSymbol(UIView *container, NSString *name, CGFloat size, UIColor *color) {
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:symbolConfig]];
    icon.tintColor = color;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
}

@implementation PDWelcomeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIView *icon = [UIView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.backgroundColor = [PDAccent() colorWithAlphaComponent:0.13];
    icon.layer.cornerRadius = 22;
    [icon.widthAnchor constraintEqualToConstant:67].active=YES;
    [icon.heightAnchor constraintEqualToConstant:67].active=YES;
    PDAddSymbol(icon, @"externaldrive.fill", 30, PDAccent());

    UILabel *heading = PDLabel(@"SideloadPersist", 31, UIFontWeightBold, UIColor.labelColor);
    heading.textAlignment = NSTextAlignmentCenter;
    UILabel *subtitle = PDLabel(@"让侧载应用的数据不再被签名有效期束缚。", 15,
                                UIFontWeightRegular, UIColor.secondaryLabelColor);
    subtitle.textAlignment = NSTextAlignmentCenter;

    NSString *name = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?:
                     NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"当前 App";
    UILabel *pathTitle = PDLabel(@"持久化目录", 12, UIFontWeightMedium, UIColor.secondaryLabelColor);
    UILabel *path = PDLabel([NSString stringWithFormat:@"在我的 iPhone  ›  %@  ›  SideloadPersist",name],
                             13, UIFontWeightSemibold, UIColor.labelColor);
    path.numberOfLines = 2;
    UIView *pathCard = [UIView new];
    pathCard.backgroundColor=PDSecondaryBackground();
    pathCard.layer.cornerRadius=17;
    UIStackView *pathStack=[[UIStackView alloc] initWithArrangedSubviews:@[pathTitle,path]];
    pathStack.axis=UILayoutConstraintAxisVertical;
    pathStack.spacing=5;
    pathStack.translatesAutoresizingMaskIntoConstraints=NO;
    [pathCard addSubview:pathStack];
    [NSLayoutConstraint activateConstraints:@[
        [pathStack.leadingAnchor constraintEqualToAnchor:pathCard.leadingAnchor constant:15],
        [pathStack.trailingAnchor constraintEqualToAnchor:pathCard.trailingAnchor constant:-15],
        [pathStack.topAnchor constraintEqualToAnchor:pathCard.topAnchor constant:12],
        [pathStack.bottomAnchor constraintEqualToAnchor:pathCard.bottomAnchor constant:-12]
    ]];

    UIButton *files = PDButton(@"在「文件」App 中查看", NO);
    [files addTarget:self action:@selector(openFiles) forControlEvents:UIControlEventTouchUpInside];
    self.importButton = PDButton(@"导入备份 ZIP", NO);
    [self.importButton addTarget:self action:@selector(chooseImport) forControlEvents:UIControlEventTouchUpInside];
    UIButton *guide = PDButton(@"使用与恢复指南", NO);
    [guide addTarget:self action:@selector(showGuide) forControlEvents:UIControlEventTouchUpInside];
    UIButton *github = [UIButton buttonWithType:UIButtonTypeSystem];
    [github setTitle:@"GitHub  ·  RavelloH" forState:UIControlStateNormal];
    github.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [github addTarget:self action:@selector(openRepository) forControlEvents:UIControlEventTouchUpInside];
    UIButton *done = PDButton(@"开始使用", YES);
    [done addTarget:self action:@selector(accept) forControlEvents:UIControlEventTouchUpInside];

    self.statusLabel = PDLabel([NSString stringWithFormat:@"● %@", PDStorageStatusText()],11,
                               UIFontWeightMedium,UIColor.tertiaryLabelColor);
    self.statusLabel.textAlignment=NSTextAlignmentCenter;

    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:
       @[icon,heading,subtitle,pathCard,files,self.importButton,guide,github,self.statusLabel,done]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.alignment=UIStackViewAlignmentFill;
    stack.spacing=10;
    [stack setCustomSpacing:17 afterView:subtitle];
    [stack setCustomSpacing:13 afterView:pathCard];
    // Align the logo while keeping other controls full-width.
    UIView *iconRow=[UIView new];
    [icon removeFromSuperview];
    icon.translatesAutoresizingMaskIntoConstraints=NO;
    [iconRow addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.topAnchor constraintEqualToAnchor:iconRow.topAnchor],
        [icon.bottomAnchor constraintEqualToAnchor:iconRow.bottomAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:iconRow.centerXAnchor],
    ]];
    [stack insertArrangedSubview:iconRow atIndex:0];

    // Deliberately no UIScrollView in the onboarding sheet. Adapt the sheet
    // height to fit the entire content and keep all buttons simultaneously visible.
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22],
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:18],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-18]
    ]];
    self.bodyContainer=stack;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (!self.committed && !s_importInProgress) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kIntroShown];
        s_presenting=NO;
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (PDArchivePendingID().length && !self.committed) [self presentCompletion];
}
- (void)showMessage:(NSString *)title body:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title
         message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)openFiles {
    NSString *encoded=[PDStorageRoot() stringByAddingPercentEncodingWithAllowedCharacters:
                       NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url=[NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:encoded ?: @""]];
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL worked) {
        if (!worked) dispatch_async(dispatch_get_main_queue(),^{
            [self showMessage:@"在「文件」App 中查找"
                         body:@"打开「浏览」→「在我的 iPhone」→ 当前应用 → SideloadPersist。"];
        });
    }];
}
- (void)openRepository {
    NSURL *url=[NSURL URLWithString:@"https://github.com/RavelloH/SideloadPersist"];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
- (void)showGuide {
    UIViewController *guide=[UIViewController new];
    guide.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *title=PDLabel(@"数据如何保留与恢复",28,UIFontWeightBold,UIColor.labelColor);
    UILabel *lead=PDLabel(@"只需一次备份，便可以在更换签名后继续使用已保存的数据。",15,UIFontWeightRegular,UIColor.secondaryLabelColor);
    NSMutableArray *views=[NSMutableArray arrayWithObjects:title,lead,nil];
    NSString *appName=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?:
                      NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"当前 App";
    NSString *appFolder=[NSString stringWithFormat:@"在我的 iPhone › %@",appName];
    NSArray *heads=@[@"正常使用",@"签名过期时",@"重新安装",@"恢复备份",@"大功告成！",@"更多可能…"];
    NSArray *details=@[
        @"无需任何操作，插件会自动将应用中受支持的私有数据转移到可访问的持久化目录。",
        [NSString stringWithFormat:@"先不要卸载 App。打开「文件」App，前往「%@」，压缩「SideloadPersist」文件夹，再将 ZIP 转存到这个 App 文件夹之外的安全位置。",appFolder],
        [NSString stringWithFormat:@"现在可以删除并重新安装 App。删除前，请确认刚保存的 ZIP 确实位于「%@」文件夹之外，例如 iCloud Drive。",appFolder],
        @"打开 App，选择「导入备份 ZIP」，待校验完成后按提示退出，再手动打开 App 完成恢复。",
        @"您备份的应用数据已完成迁移——妥善保存备份，以后不必再担心签名过期导致这些数据丢失。",
        @"在 App 关闭的情况下，您可以通过「SideloadPersist」直接读写已经迁出的应用私有数据，无需越狱。更多的可能性等您来发现！"];
    for(NSUInteger i=0;i<heads.count;i++){
        UILabel *number=PDLabel([NSString stringWithFormat:@"%lu", (unsigned long)(i+1)],54,UIFontWeightBold,[PDAccent() colorWithAlphaComponent:0.55]);
        [number.widthAnchor constraintEqualToConstant:60].active=YES;
        UILabel *header=PDLabel(heads[i],19,UIFontWeightSemibold,UIColor.labelColor);
        UILabel *detail=PDLabel(details[i],14,UIFontWeightRegular,UIColor.secondaryLabelColor);
        UIStackView *text=[[UIStackView alloc] initWithArrangedSubviews:@[header,detail]];
        text.axis=UILayoutConstraintAxisVertical; text.spacing=4;
        UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[number,text]];
        row.axis=UILayoutConstraintAxisHorizontal; row.alignment=UIStackViewAlignmentTop;
        row.spacing=12;
        [views addObject:row];
    }
    UILabel *footnote=PDLabel(@"目前仅自动重定位 Application Support 等已支持的数据；Preferences、Keychain、WebKit 等仍在研究中。删除 App 前务必确认备份已放在 App 目录外。",12,UIFontWeightRegular,UIColor.tertiaryLabelColor);
    [views addObject:footnote];
    UIButton *finish=PDButton(@"返回",YES);
    [finish addTarget:self action:@selector(closeGuide) forControlEvents:UIControlEventTouchUpInside];
    [views addObject:finish];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=26;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;
    [guide.view addSubview:scroll];[scroll addSubview:stack];
    UILayoutGuide *safe=guide.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:44],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-56]
    ]];
    guide.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:guide animated:YES completion:nil];
}
- (void)closeGuide {
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
}
- (void)chooseImport {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"导入备份"
      message:@"文件将先经过检查，完成后进入待恢复状态；不会立刻覆盖运行中的数据库。"
      preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"选择 ZIP 文件"
     style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        picker.delegate=self;
        [self presentViewController:picker animated:YES completion:nil];
     }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从 Inbox 导入 ZIP"
     style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:PDStorageInbox() error:nil];
        NSMutableArray *zips=[NSMutableArray array];
        for(NSString *file in files) if([file.pathExtension.lowercaseString isEqualToString:@"zip"]) [zips addObject:file];
        if(zips.count != 1) {
            [self showMessage:@"未找到唯一备份" body:@"请先将一个 .zip 文件复制至 SideloadPersist/Inbox，再重试。"];
            return;
        }
        [self stageImport:[NSURL fileURLWithPath:[PDStorageInbox() stringByAppendingPathComponent:zips.firstObject]]];
     }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(sheet.popoverPresentationController){
        sheet.popoverPresentationController.sourceView=self.importButton;
        sheet.popoverPresentationController.sourceRect=self.importButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(urls.firstObject) [self stageImport:urls.firstObject];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    PDStorageTrace(@"User cancelled backup import");
}
- (void)stageImport:(NSURL *)url {
    if(s_importInProgress || self.committed) return;
    s_importInProgress=YES;
    self.importButton.enabled=NO;
    self.statusLabel.text=@"正在验证并暂存备份…";
    // Prevent dismissal while data is still being extracted to a staging directory.
    self.modalInPresentation=YES;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;
        NSString *identifier=PDArchiveStageZIP(url,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            PDWelcomeController *strong=weakSelf;
            s_importInProgress=NO;
            if(!strong) return;
            if(identifier) {
                // Keep the user-owned ZIP, but remove it from the Inbox top
                // level so future launches do not repeatedly offer import.
                NSString *inbox=PDStorageInbox();
                NSString *parent=[url.path stringByDeletingLastPathComponent];
                if ([parent.stringByStandardizingPath isEqualToString:inbox.stringByStandardizingPath]) {
                    NSString *archiveFolder=[inbox stringByAppendingPathComponent:@"Imported"];
                    [NSFileManager.defaultManager createDirectoryAtPath:archiveFolder withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *dest=[archiveFolder stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@-%@",identifier,url.lastPathComponent ?: @"backup.zip"]];
                    NSError *moveError=nil;
                    if (![NSFileManager.defaultManager moveItemAtPath:url.path toPath:dest error:&moveError])
                        PDStorageTrace(@"Preserved Inbox ZIP in place (archive move failed): %@",moveError);
                }
                strong.committed=YES;
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kIntroShown];
                PDStorageTrace(@"Backup validated and staged; awaiting explicit process restart");
                [strong presentCompletion];
            } else {
                strong.modalInPresentation=NO;
                strong.importButton.enabled=YES;
                strong.statusLabel.text=@"导入失败，原数据未更改。";
                [strong showMessage:@"无法导入" body:error.localizedDescription ?: @"备份校验失败。"];
            }
        });
    });
}
- (void)presentCompletion {
    UIViewController *existing=self.presentedViewController;
    if ([existing isKindOfClass:PDCompleteController.class]) return;
    if (existing) {
        // The document picker/action sheet may still be dismissing when ZIP
        // extraction completes; transition only after it has fully closed.
        [existing dismissViewControllerAnimated:NO completion:^{ [self presentCompletion]; }];
        return;
    }
    self.committed=YES;
    self.modalInPresentation=YES;
    if(@available(iOS 15.0,*)) {
        UISheetPresentationController *sheet=self.sheetPresentationController;
        if(sheet) [sheet animateChanges:^{
            sheet.detents=@[[UISheetPresentationControllerDetent largeDetent]];
            sheet.selectedDetentIdentifier=UISheetPresentationControllerDetentIdentifierLarge;
            sheet.prefersGrabberVisible=NO;
        }];
    }
    PDCompleteController *screen=[PDCompleteController new];
    screen.modalPresentationStyle=UIModalPresentationFullScreen;
    screen.modalInPresentation=YES;
    [self presentViewController:screen animated:YES completion:nil];
}
- (void)accept {
    if (self.committed || s_importInProgress || PDArchivePendingID().length) return;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kIntroShown];
    s_presenting=NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

@implementation PDCompleteController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.modalInPresentation=YES;
    UIView *circle=[UIView new];
    circle.backgroundColor=[UIColor systemGreenColor];
    circle.layer.cornerRadius=49;
    circle.translatesAutoresizingMaskIntoConstraints=NO;
    [circle.widthAnchor constraintEqualToConstant:98].active=YES;
    [circle.heightAnchor constraintEqualToConstant:98].active=YES;
    PDAddSymbol(circle,@"checkmark",48,UIColor.whiteColor);
    UILabel *heading=PDLabel(@"备份已安全导入",30,UIFontWeightBold,UIColor.labelColor);
    heading.textAlignment=NSTextAlignmentCenter;
    UILabel *detail=PDLabel(@"文件已校验并暂存，当前运行中的数据尚未被覆盖。\n\n需要彻底退出并重新打开 App，插件才能在启动阶段完成恢复。",16,UIFontWeightRegular,UIColor.secondaryLabelColor);
    detail.textAlignment=NSTextAlignmentCenter;
    UIButton *quit=PDButton(@"退出 App · 完成恢复准备",YES);
    [quit addTarget:self action:@selector(quitNow) forControlEvents:UIControlEventTouchUpInside];
    UILabel *note=PDLabel(@"退出后请手动点击 App 图标重新打开。原有数据将保留在 Backups，便于回退。",12,UIFontWeightRegular,UIColor.tertiaryLabelColor);
    note.textAlignment=NSTextAlignmentCenter;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[circle,heading,detail,quit,note]];
    stack.axis=UILayoutConstraintAxisVertical;stack.spacing=20;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
       [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
       [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
       [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28]
    ]];
    UIView *circleRow=[UIView new];
    [circle removeFromSuperview]; [circleRow addSubview:circle];
    [stack insertArrangedSubview:circleRow atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
       [circle.topAnchor constraintEqualToAnchor:circleRow.topAnchor],
       [circle.bottomAnchor constraintEqualToAnchor:circleRow.bottomAnchor],
       [circle.centerXAnchor constraintEqualToAnchor:circleRow.centerXAnchor]
    ]];
    stack.alpha=0;
    [UIView animateWithDuration:0.45 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{stack.alpha=1;} completion:nil];
}
- (void)quitNow {
    if (!PDArchivePendingID().length) return;
    // iOS has no public self-relaunch API. This is a user-initiated exit of an
    // already-staged restore; the next manual launch applies it in the constructor.
    PDStorageTrace(@"User explicitly requested exit after staged restore; process terminating");
    fflush(NULL);
    exit(0);
}
@end
