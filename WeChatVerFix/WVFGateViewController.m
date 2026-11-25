//
//  WVFGateViewController.m
//  激活授权弹窗 —— 纯 UIKit + 内置数字键盘
//
//  设计原则（针对"点输入框闪退/无响应"）：
//  1. 全程不唤起系统键盘 —— 用自绘键盘，彻底避开键盘相关崩溃
//  2. 卡密显示用 UILabel（不是 UITextField），不可能触发 firstResponder
//  3. 真正的 UIViewController 由主界面 present，responder chain 完整
//  4. 所有 UI 构建在 viewDidLoad 一次完成，无动态增删视图
//

#import "WVFGateViewController.h"
#import "WVFLicense.h"
#import <objc/runtime.h>

#define G_CLR_GREEN  [UIColor colorWithRed:0.07 green:0.72 blue:0.42 alpha:1.0]
#define G_CLR_BLUE   [UIColor colorWithRed:0.20 green:0.55 blue:0.90 alpha:1.0]
#define G_CLR_GRAY   [UIColor colorWithRed:0.52 green:0.57 blue:0.62 alpha:1.0]
#define G_CLR_RED    [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1.0]
#define G_CLR_TEXT   [UIColor colorWithRed:0.13 green:0.16 blue:0.20 alpha:1.0]
#define G_CLR_SUB    [UIColor colorWithRed:0.47 green:0.52 blue:0.57 alpha:1.0]

@interface WVFGateViewController ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *keyLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *activateButton;
@property (nonatomic, strong) NSMutableString *input;
@end

@implementation WVFGateViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.input = [NSMutableString string];

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat cw = w - 48;
    if (cw > 340) cw = 340;

    // ---- 卡片尺寸 ----
    CGFloat pad = 20;
    CGFloat inner = cw - pad * 2;
    CGFloat titleH = 26;
    CGFloat subH = 18;
    CGFloat dispH = 44;
    CGFloat keyH = 44;
    CGFloat keyGap = 6;
    CGFloat keypadH = keyH * 4 + keyGap * 3;
    CGFloat btnH = 44;
    CGFloat statusH = 34;
    CGFloat footH = 16;
    CGFloat vGap = 12;

    CGFloat ch = pad + titleH + 6 + subH + vGap + dispH + vGap + keypadH
              + vGap + btnH + 8 + statusH + 6 + footH + pad;

    CGFloat cy = (h - ch) / 2;
    if (cy < 24) cy = 24;
    if (cy + ch > h - 24) cy = h - ch - 24;
    if (cy < 0) cy = 0;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((w - cw) / 2, cy, cw, ch)];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 18;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.22;
    card.layer.shadowRadius = 18;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    [self.view addSubview:card];
    self.card = card;

    CGFloat y = pad;

    // ---- 标题 ----
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, inner, titleH)];
    title.text = @"激活授权";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:19];
    title.textColor = G_CLR_TEXT;
    [card addSubview:title];
    y += titleH + 6;

    // ---- 副标题 ----
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, inner, subH)];
    sub.text = @"一机一码，激活后可在本机使用";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = G_CLR_SUB;
    [card addSubview:sub];
    y += subH + vGap;

    // ---- 卡密显示（UILabel，不可能触发键盘）----
    UILabel *disp = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, inner, dispH)];
    disp.backgroundColor = [UIColor colorWithRed:0.95 green:0.97 blue:0.98 alpha:1.0];
    disp.layer.cornerRadius = 10;
    disp.layer.borderWidth = 1;
    disp.layer.borderColor = [UIColor colorWithRed:0.88 green:0.91 blue:0.93 alpha:1].CGColor;
    disp.clipsToBounds = YES;
    disp.textAlignment = NSTextAlignmentCenter;
    disp.textColor = G_CLR_TEXT;
    disp.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    disp.text = @"";
    disp.adjustsFontSizeToFitWidth = YES;
    disp.minimumScaleFactor = 0.6;
    [card addSubview:disp];
    self.keyLabel = disp;
    y += dispH + vGap;

    // ---- 内置数字键盘（3×4）----
    UIView *keypad = [[UIView alloc] initWithFrame:CGRectMake(pad, y, inner, keypadH)];
    keypad.backgroundColor = [UIColor clearColor];

    // 4 行 × 3 列：1-9 / ⌫ 0 （末格留空）
    NSArray *rows = @[
        @[@"1", @"2", @"3"],
        @[@"4", @"5", @"6"],
        @[@"7", @"8", @"9"],
        @[@"⌫", @"0", @""],
    ];
    CGFloat kw = (inner - keyGap * 2) / 3.0;

    for (NSUInteger r = 0; r < rows.count; r++) {
        NSArray *cols = rows[r];
        for (NSUInteger c = 0; c < cols.count; c++) {
            NSString *t = cols[c];
            if (!t.length) continue;   // 末格留空

            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(c * (kw + keyGap), r * (keyH + keyGap), kw, keyH);
            [b setTitle:t forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:19];
            [b setTitleColor:G_CLR_TEXT forState:UIControlStateNormal];

            if ([t isEqualToString:@"⌫"]) {
                b.backgroundColor = [UIColor colorWithRed:0.96 green:0.94 blue:0.94 alpha:1.0];
                [b setTitleColor:G_CLR_RED forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:20];
                [b addTarget:self action:@selector(onBackspace)
                    forControlEvents:UIControlEventTouchUpInside];
            } else {
                b.backgroundColor = [UIColor whiteColor];
                b.layer.borderWidth = 1.0;
                b.layer.borderColor = [UIColor colorWithRed:0.90 green:0.92 blue:0.94 alpha:1.0].CGColor;
                [b addTarget:self action:@selector(onKeyTap:)
                    forControlEvents:UIControlEventTouchUpInside];
            }
            b.layer.cornerRadius = 9;
            // 按下反馈
            [b addTarget:self action:@selector(onKeyDown:) forControlEvents:UIControlEventTouchDown];
            [b addTarget:self action:@selector(onKeyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [keypad addSubview:b];
        }
    }
    [card addSubview:keypad];
    y += keypadH + vGap;

    // ---- 粘贴卡密 / 激活卡密（并排）----
    CGFloat halfW = (inner - 10) / 2.0;

    UIButton *paste = [UIButton buttonWithType:UIButtonTypeCustom];
    paste.frame = CGRectMake(pad, y, halfW, btnH);
    [paste setTitle:@"粘贴卡密" forState:UIControlStateNormal];
    [paste setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    paste.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    paste.backgroundColor = [UIColor colorWithRed:0.52 green:0.57 blue:0.62 alpha:1.0];
    paste.layer.cornerRadius = 10;
    [paste addTarget:self action:@selector(onPaste) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:paste];

    UIButton *activate = [UIButton buttonWithType:UIButtonTypeCustom];
    activate.frame = CGRectMake(pad + halfW + 10, y, halfW, btnH);
    [activate setTitle:@"激活卡密" forState:UIControlStateNormal];
    [activate setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    activate.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    activate.backgroundColor = G_CLR_GREEN;
    activate.layer.cornerRadius = 10;
    [activate addTarget:self action:@selector(onActivate) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:activate];
    self.activateButton = activate;
    y += btnH + 8;


    // ---- 状态 ----
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, inner, statusH)];
    self.statusLabel.text = self.initialMessage ?: @"请输入卡密";
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:11.5];
    self.statusLabel.textColor = G_CLR_RED;
    [card addSubview:self.statusLabel];
    y += statusH + 6;

    // ---- 底部提示 ----
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, inner, footH)];
    foot.text = @"可直接「粘贴卡密」，或用上方键盘输入";
    foot.textAlignment = NSTextAlignmentCenter;
    foot.font = [UIFont systemFontOfSize:10.5];
    foot.textColor = G_CLR_SUB;
    foot.adjustsFontSizeToFitWidth = YES;
    foot.minimumScaleFactor = 0.8;
    [card addSubview:foot];

    // 点击空白收起（无键盘时仅作视觉反馈）
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapBlank)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (UIButton *)smallButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.backgroundColor = color;
    b.layer.cornerRadius = 9;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}


- (UIButton *)button:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 输入

- (void)refreshKeyLabel {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.keyLabel.text = self.input.length ? self.input : @"";
        if (!self.input.length) {
            self.keyLabel.textColor = G_CLR_SUB;
            self.keyLabel.text = @"请用下方键盘输入";
        } else {
            self.keyLabel.textColor = G_CLR_TEXT;
        }
    });
}

- (void)onKeyDown:(UIButton *)sender {
    UIColor *c = sender.backgroundColor;
    sender.backgroundColor = [UIColor colorWithRed:0.88 green:0.91 blue:0.94 alpha:1.0];
    sender.layer.borderColor = [UIColor colorWithRed:0.70 green:0.75 blue:0.80 alpha:1.0].CGColor;
    objc_setAssociatedObject(sender, "wvf_orig_bg", c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onKeyUp:(UIButton *)sender {
    UIColor *c = objc_getAssociatedObject(sender, "wvf_orig_bg");
    if ([c isKindOfClass:[UIColor class]]) {
        sender.backgroundColor = c;
    }
    sender.layer.borderColor = [UIColor colorWithRed:0.90 green:0.92 blue:0.94 alpha:1.0].CGColor;
}

- (void)onKeyTap:(UIButton *)sender {
    NSString *t = sender.currentTitle ?: @"";
    if (!t.length) return;
    if (self.input.length >= 32) return;
    [self.input appendString:t];
    [self setStatusText:@"" isError:NO];
    [self refreshKeyLabel];
}

- (void)onBackspace {
    if (!self.input.length) return;
    [self.input deleteCharactersInRange:NSMakeRange(self.input.length - 1, 1)];
    [self refreshKeyLabel];
}

- (void)onTapBlank {
    // 无系统键盘，无需收起；保留手势避免点击穿透
}

#pragma mark - 操作

- (void)setStatusText:(NSString *)text isError:(BOOL)isError {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.textColor = isError ? G_CLR_RED : G_CLR_SUB;
        self.statusLabel.text = text ?: @"";
    });
}

- (void)onPaste {
    NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 只保留数字和字母，去掉 WVF- 之类的分隔符
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
            [clean appendFormat:@"%C", c];
        }
    }
    if (!clean.length) {
        [self setStatusText:@"剪贴板是空的，请先复制卡密" isError:YES];
        return;
    }
    [self.input setString:[clean uppercaseString]];
    [self refreshKeyLabel];
    [self setStatusText:@"已粘贴，点「确定」" isError:NO];
}

- (void)onActivate {
    NSString *k = [self.input copy];
    k = [k stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!k.length) {
        [self setStatusText:@"请先输入或粘贴卡密" isError:YES];
        return;
    }

    self.activateButton.enabled = NO;
    [self setStatusText:@"正在验证…" isError:NO];

    __weak typeof(self) weakSelf = self;
    [[WVFLicense shared] activateWithKey:k completion:^(BOOL ok, NSString *msg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.activateButton.enabled = YES;
            if (ok) {
                [weakSelf setStatusText:msg isError:NO];
                WVFGateFinishBlock finish = weakSelf.onFinish;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (finish) finish();
                });
            } else {
                [weakSelf setStatusText:msg ?: @"激活失败" isError:YES];
            }
        });
    }];
}

@end
