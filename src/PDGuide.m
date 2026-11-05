#import "PDGuide.h"
#import <QuartzCore/QuartzCore.h>

@interface PDGuideController ()
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIView *topFade;
@property(nonatomic,strong) UIView *bottomFade;
@property(nonatomic,strong) CAGradientLayer *topMask;
@property(nonatomic,strong) CAGradientLayer *bottomMask;
@end

static UILabel *PDGuideLabel(NSString *value, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label=[UILabel new];
    label.text=value;
    label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory=YES;
    label.textColor=color;
    label.numberOfLines=0;
    label.lineBreakMode=NSLineBreakByWordWrapping;
    return label;
}

static UIView *PDGuideStep(NSUInteger index, NSString *heading, NSString *description) {
    UILabel *number=PDGuideLabel([NSString stringWithFormat:@"%lu",(unsigned long)(index+1)],52,
                                  UIFontWeightBold,[UIColor.systemBlueColor colorWithAlphaComponent:0.58]);
    [number.widthAnchor constraintEqualToConstant:58].active=YES;
    UILabel *title=PDGuideLabel(heading,20,UIFontWeightBold,UIColor.labelColor);
    UILabel *body=PDGuideLabel(description,15,UIFontWeightRegular,UIColor.secondaryLabelColor);
    UIStackView *text=[[UIStackView alloc] initWithArrangedSubviews:@[title,body]];
    text.axis=UILayoutConstraintAxisVertical;
    text.alignment=UIStackViewAlignmentFill;
    text.spacing=6;
    UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:@[number,text]];
    row.axis=UILayoutConstraintAxisHorizontal;
    row.alignment=UIStackViewAlignmentTop;
    row.spacing=12;
    return row;
}

@implementation PDGuideController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;

    NSString *appName=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?:
                      NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: @"当前 App";
    NSString *appFolder=[NSString stringWithFormat:@"在我的 iPhone › %@",appName];

    NSArray<NSString *> *headings=@[
        @"受支持的范围",@"先保留备份",@"校验备份",@"暂存恢复",@"核对恢复结果",@"保留与限制"
    ];
    NSArray<NSString *> *descriptions=@[
        @"插件会尝试迁移受支持的应用私有数据，但并非所有目录、凭据和系统服务都能被覆盖。遇到异常时应先保留原安装。",
        [NSString stringWithFormat:@"在卸载之前先完全退出 App。打开「文件」App，找到「%@」，压缩整个 SideloadPersist 文件夹，并将 ZIP 另存至应用文件夹以外。",appFolder],
        @"确认 ZIP 可以在独立位置找到，且没有出现偏好写入故障或目录冲突提示。只有拥有可用的外部备份，才考虑删除原应用。",
        @"重装后通过插件导入 ZIP。不同应用标识或缺少来源信息的旧备份需要你主动核对和确认；导入会先暂存，下一次冷启动才尝试恢复。",
        @"重新打开后检查重要业务数据和恢复收据。暂存成功、恢复事务提交成功，都不等于所有应用功能或登录凭据必然恢复。",
        @"请继续保留原 ZIP 和 Backups。Keychain、App Groups、Caches 等不在当前完整保障范围；不要把备份公开分享。"
    ];

    UILabel *title=PDGuideLabel(@"数据如何保留与恢复",31,UIFontWeightBold,UIColor.labelColor);
    UILabel *lead=PDGuideLabel(@"SideloadPersist 将受支持的应用私有数据映射到可访问的应用文档目录，方便用户自行备份和检查。Preferences 采用 API 读写适配。",
                                16,UIFontWeightRegular,UIColor.secondaryLabelColor);

    NSMutableArray<UIView *> *rows=[NSMutableArray arrayWithObjects:title,lead,nil];
    for (NSUInteger i=0;i<headings.count;i++) {
        [rows addObject:PDGuideStep(i,headings[i],descriptions[i])];
    }
    UILabel *footnote=PDGuideLabel(@"RC 候选版：Application Support、WebKit、Cookies 与部分 App 自建目录使用映射；Preferences 使用 API Hook。不同 App、签名身份及系统服务可能不兼容。必须保留独立 ZIP 并检查恢复结果。",
                                   12,UIFontWeightRegular,UIColor.tertiaryLabelColor);
    [rows addObject:footnote];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.alignment=UIStackViewAlignmentFill;
    stack.spacing=26;
    [stack setCustomSpacing:15 afterView:title];
    [stack setCustomSpacing:46 afterView:lead];
    stack.translatesAutoresizingMaskIntoConstraints=NO;

    UIScrollView *scroll=[UIScrollView new];
    self.scrollView=scroll;
    scroll.delegate=self;
    scroll.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.showsVerticalScrollIndicator=NO;
    scroll.alwaysBounceVertical=YES;
    scroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    // The bottom action stays fixed and uses the *same dynamic background*
    // as the guide. System blur materials tinted this dark page grey.
    UIView *footer=[UIView new];
    footer.backgroundColor=UIColor.systemBackgroundColor;
    footer.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:footer];
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints=NO;
    [back setTitle:@"返回" forState:UIControlStateNormal];
    back.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [back setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    back.backgroundColor=UIColor.systemBlueColor;
    back.layer.cornerRadius=15;
    back.clipsToBounds=YES;
    [back addTarget:self action:@selector(closeGuide) forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:back];

    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:42],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-35],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:27],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-27],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-54],

        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [back.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [back.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [back.topAnchor constraintEqualToAnchor:footer.topAnchor constant:13],
        [back.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [back.heightAnchor constraintEqualToConstant:52],
    ]];

    // Match the scroll boundary to the actual system background instead of
    // using a material blur, which creates a visible grey fringe on OLED black.
    // The two fades are independent of the scrolling content and do not
    // intercept taps or gestures.
    self.topFade=[UIView new];
    self.bottomFade=[UIView new];
    self.topFade.translatesAutoresizingMaskIntoConstraints=NO;
    self.bottomFade.translatesAutoresizingMaskIntoConstraints=NO;
    self.topFade.userInteractionEnabled=NO;
    self.bottomFade.userInteractionEnabled=NO;
    [self.view insertSubview:self.topFade aboveSubview:scroll];
    [self.view insertSubview:self.bottomFade aboveSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [self.topFade.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [self.topFade.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [self.topFade.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [self.topFade.heightAnchor constraintEqualToConstant:28],

        [self.bottomFade.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [self.bottomFade.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [self.bottomFade.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [self.bottomFade.heightAnchor constraintEqualToConstant:44],
    ]];

    CAGradientLayer *top=[CAGradientLayer layer];
    top.startPoint=CGPointMake(0,0);
    top.endPoint=CGPointMake(0,1);
    [self.topFade.layer addSublayer:top];
    self.topMask=top;

    CAGradientLayer *bottom=[CAGradientLayer layer];
    bottom.startPoint=CGPointMake(0,0);
    bottom.endPoint=CGPointMake(0,1);
    [self.bottomFade.layer addSublayer:bottom];
    self.bottomMask=bottom;
    [self updateFadeColors];
}
- (void)updateFadeColors {
    UIColor *base=[UIColor.systemBackgroundColor resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *clear=[base colorWithAlphaComponent:0];
    self.topMask.colors=@[(__bridge id)base.CGColor,(__bridge id)clear.CGColor];
    self.bottomMask.colors=@[(__bridge id)clear.CGColor,(__bridge id)base.CGColor];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateFadeColors];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.topMask.frame=self.topFade.bounds;
    self.bottomMask.frame=self.bottomFade.bounds;
    [CATransaction commit];
    [self updateFade];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self updateFade];
}
- (void)updateFade {
    CGFloat top=MAX(0,self.scrollView.contentOffset.y);
    CGFloat remaining=MAX(0,self.scrollView.contentSize.height -
                           (self.scrollView.contentOffset.y+self.scrollView.bounds.size.height));
    self.topFade.alpha=MIN(1.0,top/24.0);
    self.bottomFade.alpha=MIN(1.0,remaining/36.0);
}
- (void)closeGuide {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
