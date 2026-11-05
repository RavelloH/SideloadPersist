#import "PDIntro.h"
#import "PDGuide.h"
#import "PDStorage.h"
#import "PDArchive.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreFoundation/CFPreferences.h>
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
- (void)syncPreferencesBeforeSuspend:(NSNotification *)notification;
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
- (void)syncPreferencesBeforeSuspend:(NSNotification *)notification {
    // Preferences is a cfprefsd-managed domain. Ask the system to flush the
    // app's default domain when it goes to the background, reducing the chance
    // that a Files.app ZIP snapshot is made before asynchronous writes land.
    // This does not guarantee a snapshot of custom suites or other processes.
    [[NSUserDefaults standardUserDefaults] synchronize];
    BOOL result=CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    if(!result) PDStorageTrace(@"System preference synchronization reported failure before suspend");
}
@end

void PDIntroInstall(void) {
    PDIntroManager *manager = [PDIntroManager shared];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:manager selector:@selector(tryPresent) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:manager selector:@selector(tryPresent) name:UISceneDidActivateNotification object:nil];
    [center addObserver:manager selector:@selector(tryPresent) name:UIWindowDidBecomeKeyNotification object:nil];
    [center addObserver:manager selector:@selector(syncPreferencesBeforeSuspend:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:manager selector:@selector(syncPreferencesBeforeSuspend:)
                   name:UIApplicationWillTerminateNotification object:nil];
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
    UILabel *subtitle = PDLabel(@"为受支持的应用私有数据提供备份与恢复能力。", 15,
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
    PDGuideController *guide=[PDGuideController new];
    guide.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:guide animated:YES completion:nil];
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
    NSString *source=nil;
    PDArchiveIdentityState identity=PDArchiveInspectIdentity(url,&source);
    if(identity==PDArchiveIdentityStateInvalid) {
        [self showMessage:@"无法识别备份" body:@"ZIP 损坏或清单不受支持，未修改现有数据。"];
        return;
    }
    if(identity!=PDArchiveIdentityStateMatch) {
        NSString *current=NSBundle.mainBundle.bundleIdentifier ?: @"未知";
        NSString *reason=identity==PDArchiveIdentityStateDifferentApp ?
            [NSString stringWithFormat:@"备份来源：%@\n当前应用：%@\n\n应用标识不同，恢复数据可能无法被当前 App 正确读取。",source ?: @"未知",current] :
            [NSString stringWithFormat:@"此备份未记录原应用标识。\n当前应用：%@\n\n无法自动确认它是否属于当前 App。",current];
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:
            @"无法自动核对备份身份"
            message:[reason stringByAppendingString:
               @"\n\n仅在确信备份属于要恢复的应用、且已保留原数据时，才允许继续。"]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消导入"
            style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"我已核对，仍然导入"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
                [self stageImportApproved:url allowIdentityOverride:YES];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self stageImportApproved:url allowIdentityOverride:NO];
}
- (void)stageImportApproved:(NSURL *)url allowIdentityOverride:(BOOL)approved {
    if(s_importInProgress || self.committed) return;
    s_importInProgress=YES;
    self.importButton.enabled=NO;
    self.statusLabel.text=@"正在验证并暂存备份…";
    // Prevent dismissal while data is still being extracted to a staging directory.
    self.modalInPresentation=YES;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;
        NSString *identifier=PDArchiveStageZIPWithIdentityApproval(url,approved,&error);
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
    UILabel *heading=PDLabel(@"备份已校验并暂存",30,UIFontWeightBold,UIColor.labelColor);
    heading.textAlignment=NSTextAlignmentCenter;
    UILabel *detail=PDLabel(@"备份已暂存，当前应用数据尚未被替换。\n\n请退出并重新打开 App，系统会在启动阶段尝试恢复受支持的数据范围。恢复结果以收据和实际数据检查为准。",16,UIFontWeightRegular,UIColor.secondaryLabelColor);
    detail.textAlignment=NSTextAlignmentCenter;
    UIButton *quit=PDButton(@"退出 App · 完成恢复准备",YES);
    [quit addTarget:self action:@selector(quitNow) forControlEvents:UIControlEventTouchUpInside];
    UILabel *note=PDLabel(@"重新打开后请检查重要数据。恢复失败时请保留备份 ZIP 和 Backups，不要重复覆盖。",12,UIFontWeightRegular,UIColor.tertiaryLabelColor);
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
