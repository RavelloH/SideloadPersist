#import "PDGuide.h"
#import <QuartzCore/QuartzCore.h>

@interface PDGuideController ()
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIVisualEffectView *topFade;
@property(nonatomic,strong) UIVisualEffectView *bottomFade;
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
        @"正常使用",@"签名过期时",@"重新安装",@"恢复备份",@"大功告成！",@"更多可能…"
    ];
    NSArray<NSString *> *descriptions=@[
        @"无需任何操作，插件会自动将应用中受支持的私有数据转移到可访问的持久化目录。",
        [NSString stringWithFormat:@"先不要卸载 App。打开「文件」App，前往「%@」，压缩「SideloadPersist」文件夹，再将 ZIP 转存到该 App 文件夹之外的安全位置。",appFolder],
        [NSString stringWithFormat:@"现在可以删除并重新安装 App。删除前，请确认刚保存的 ZIP 确实位于「%@」之外，例如 iCloud Drive。",appFolder],
        @"打开 App，选择「导入备份 ZIP」，待校验完成后按提示退出，再手动打开 App 完成恢复。",
        @"您备份的应用数据已完成迁移。妥善保存备份，以后不必再担心签名过期导致这些数据丢失。",
        @"在 App 关闭的情况下，您可以通过「SideloadPersist」直接读写已迁出的应用私有数据，无需越狱。更多可能性等您来发现！"
    ];

    UILabel *title=PDGuideLabel(@"数据如何保留与恢复",31,UIFontWeightBold,UIColor.labelColor);
    UILabel *lead=PDGuideLabel(@"只需一次备份，便可以在更换签名后继续使用已保存的数据。",
                                16,UIFontWeightRegular,UIColor.secondaryLabelColor);

    NSMutableArray<UIView *> *rows=[NSMutableArray arrayWithObjects:title,lead,nil];
    for (NSUInteger i=0;i<headings.count;i++) {
        [rows addObject:PDGuideStep(i,headings[i],descriptions[i])];
    }
    UILabel *footnote=PDGuideLabel(@"目前仅自动重定位 Application Support 等已验证的数据；Preferences、Keychain、WebKit 等仍在研究中。删除 App 前，必须确认备份已经放在 App 目录外。",
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

    // A native blur material stays fixed at the bottom, including the home
    // indicator area. The action is never part of the scrolling content.
    UIBlurEffect *material=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *footer=[[UIVisualEffectView alloc] initWithEffect:material];
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
    [footer.contentView addSubview:back];

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
        [back.leadingAnchor constraintEqualToAnchor:footer.contentView.leadingAnchor constant:24],
        [back.trailingAnchor constraintEqualToAnchor:footer.contentView.trailingAnchor constant:-24],
        [back.topAnchor constraintEqualToAnchor:footer.contentView.topAnchor constant:13],
        [back.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
        [back.heightAnchor constraintEqualToConstant:52],
    ]];

    // Blur the scrolling edges instead of abruptly clipping text. These
    // overlays are noninteractive and their gradient alpha changes as the
    // user approaches the start or end of the guide.
    self.topFade=[[UIVisualEffectView alloc] initWithEffect:
                  [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    self.bottomFade=[[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
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
    top.colors=@[(id)UIColor.blackColor.CGColor,(id)UIColor.clearColor.CGColor];
    top.startPoint=CGPointMake(0,0);
    top.endPoint=CGPointMake(0,1);
    self.topFade.layer.mask=top;
    self.topMask=top;

    CAGradientLayer *bottom=[CAGradientLayer layer];
    bottom.colors=@[(id)UIColor.clearColor.CGColor,(id)UIColor.blackColor.CGColor];
    bottom.startPoint=CGPointMake(0,0);
    bottom.endPoint=CGPointMake(0,1);
    self.bottomFade.layer.mask=bottom;
    self.bottomMask=bottom;
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
