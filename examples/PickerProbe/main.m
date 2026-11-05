#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../../src/PDPickerHostFix.h"

// Independent control app, deliberately NOT injected with SideloadPersist.
// Test on the same iOS device and certificate to compare folder/file picker behavior.
@interface ProbeController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) UITextView *logs;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) NSMutableString *history;
@property(nonatomic,copy) NSString *currentKind;
@property(nonatomic,strong) UISwitch *hostFixSwitch;
@end

@implementation ProbeController
- (void)record:(NSString *)format, ... {
    va_list args; va_start(args,format);
    NSString *message=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line=[NSString stringWithFormat:@"[PickerProbe] %@  %@\n",
                    [NSDate date], message];
    NSLog(@"%@",line);
    if (!self.history) self.history=[NSMutableString string];
    [self.history appendString:line];
    if (self.history.length > 45000)
        [self.history deleteCharactersInRange:NSMakeRange(0,self.history.length-40000)];
    [[NSUserDefaults standardUserDefaults] setObject:self.history forKey:@"PickerProbe.Logs"];
    self.logs.text=self.history;
    if (self.history.length) [self.logs scrollRangeToVisible:NSMakeRange(self.history.length-1,1)];
}
- (UIButton *)button:(NSString *)name action:(SEL)action {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:name forState:UIControlStateNormal];
    b.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *title=[[UILabel alloc] init];
    title.text=@"Folder Picker Probe";
    title.font=[UIFont boldSystemFontOfSize:25];
    title.textAlignment=NSTextAlignmentCenter;
    UILabel *desc=[[UILabel alloc] init];
    desc.text=@"独立 iOS 测试 App，不注入任何 dylib。\n在 iCloud Drive 中选择已有子文件夹，或选择普通文件。";
    desc.numberOfLines=0;
    desc.textAlignment=NSTextAlignmentCenter;
    desc.textColor=UIColor.secondaryLabelColor;
    desc.font=[UIFont systemFontOfSize:14];
    self.status=[[UILabel alloc] init];
    self.status.numberOfLines=0;
    self.status.text=@"等待操作";
    self.status.font=[UIFont systemFontOfSize:14];
    self.status.textAlignment=NSTextAlignmentCenter;
    self.logs=[[UITextView alloc] init];
    self.logs.editable=NO;
    self.logs.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logs.backgroundColor=UIColor.secondarySystemBackgroundColor;
    self.logs.layer.cornerRadius=8;
    self.history=[[[NSUserDefaults standardUserDefaults] stringForKey:@"PickerProbe.Logs"] mutableCopy] ?: [NSMutableString string];
    self.logs.text=self.history;
    UILabel *fixLabel=[[UILabel alloc] init];
    fixLabel.text=@"LiveContainer 式修复（测试开关）";
    fixLabel.font=[UIFont systemFontOfSize:14];
    self.hostFixSwitch=[[UISwitch alloc] init];
    self.hostFixSwitch.on=[[NSUserDefaults standardUserDefaults] boolForKey:@"PickerProbe.HostFixEnabled"];
    [self.hostFixSwitch addTarget:self action:@selector(hostFixChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *fixRow=[[UIStackView alloc] initWithArrangedSubviews:@[fixLabel,self.hostFixSwitch]];
    fixRow.axis=UILayoutConstraintAxisHorizontal;
    fixRow.spacing=10;
    fixRow.distribution=UIStackViewDistributionEqualSpacing;
    UIButton *folder=[self button:@"① 选择外部文件夹" action:@selector(selectFolder)];
    UIButton *file=[self button:@"② 选择普通文件" action:@selector(selectFile)];
    UIButton *copy=[self button:@"复制日志" action:@selector(copyLogs)];
    UIButton *clear=[self button:@"清空日志" action:@selector(clearLogs)];
    UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[copy,clear]];
    row.axis=UILayoutConstraintAxisHorizontal;
    row.distribution=UIStackViewDistributionFillEqually;
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,desc,fixRow,folder,file,self.status,self.logs,row]];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=9;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
       [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
       [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
       [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
       [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
       [self.logs.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];
    __weak typeof(self) weakSelf=self;
    PDPickerHostFixSetLogger(^(NSString *message) { [weakSelf record:@"HostFix: %@",message]; });
    PDPickerHostFixSetEnabled(self.hostFixSwitch.on);
    [self record:@"Probe launched; iOS=%@; bundle=%@; no filesystem hooks; %@",UIDevice.currentDevice.systemVersion,NSBundle.mainBundle.bundleIdentifier,PDPickerHostFixStatus()];
    NSString *signedID = PDPickerHostFixActualBundleID();
    NSString *plistID = NSBundle.mainBundle.bundleIdentifier;
    if (signedID.length && ![signedID isEqualToString:plistID]) {
        self.status.text=@"签名 ID 与 Info.plist ID 不一致！请测试 ID 一致的 IPA。";
        [self record:@"IDENTITY_MISMATCH: signedBundle=%@ plistBundle=%@; file picker may reject app identity",signedID,plistID];
    } else {
        [self record:@"IDENTITY_CHECK: signedBundle and Info.plist bundle MATCH (or entitlement unavailable)"];
    }
}
- (void)hostFixChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:@"PickerProbe.HostFixEnabled"];
    PDPickerHostFixSetEnabled(sender.on);
    if (sender.on) PDPickerHostFixInstallIfAvailable();
    [self record:@"HostFix changed: %@",PDPickerHostFixStatus()];
    self.status.text=sender.on ? @"已开启真实签名身份修复，请重新选择文件/文件夹" : @"修复已关闭（可对照测试）";
}
- (void)selectFolder { [self openType:@[UTTypeFolder] kind:@"folder"]; }
- (void)selectFile { [self openType:@[UTTypeData,UTTypeContent] kind:@"file"]; }
- (void)openType:(NSArray<UTType *> *)types kind:(NSString *)kind {
    self.currentKind=kind;
    if (PDPickerHostFixIsEnabled()) PDPickerHostFixPrepareBeforePicker();
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
    // DOCConfiguration may only be loaded after picker initialization.
    if (PDPickerHostFixIsEnabled()) PDPickerHostFixInstallIfAvailable();
    [self record:@"HostFix status before picker presentation: %@",PDPickerHostFixStatus()];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    [self record:@"Opening picker; type=%@; presentation=%ld",kind,(long)picker.modalPresentationStyle];
    [self presentViewController:picker animated:YES completion:^{
        [self record:@"Picker presented; type=%@",kind];
    }];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self record:@"Picker success callback; type=%@; count=%lu; isFileURL=%@",
        self.currentKind,(unsigned long)urls.count,urls.firstObject.isFileURL?@"yes":@"no"];
    self.status.text=[NSString stringWithFormat:@"%@ 选择成功：%lu URL(s)",self.currentKind,(unsigned long)urls.count];
    // Do not read, copy, or access contents; this is strictly an API callback probe.
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self record:@"Legacy single-URL callback; type=%@",self.currentKind];
    [self documentPicker:controller didPickDocumentsAtURLs:url?@[url]:@[]];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self record:@"Picker cancelled; type=%@",self.currentKind];
    self.status.text=[NSString stringWithFormat:@"%@ 已取消",self.currentKind];
}
- (void)copyLogs {
    UIPasteboard.generalPasteboard.string=self.history;
    self.status.text=@"已复制日志";
}
- (void)clearLogs {
    [self.history setString:@""];
    self.logs.text=@"";
    [[NSUserDefaults standardUserDefaults] setObject:@"" forKey:@"PickerProbe.Logs"];
    [self record:@"Log cleared"];
}
@end

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=[[ProbeController alloc] init];
    [self.window makeKeyAndVisible];
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass([ProbeAppDelegate class])); }
}
