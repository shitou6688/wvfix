//
//  WVFGateViewController.m
//  激活授权弹窗
//
//  关键：这是一个真正的 UIViewController，由主界面 present 出来，
//  因此系统键盘有完整的 responder chain（iOS 14 上裸 UIView 加在 UIWindow
//  上唤键盘会被杀掉，这里用模态 VC 规避）。
//

#import "WVFGateViewController.h"
#import "WVFLicense.h"

#define G_CLR_GREEN  [UIColor colorWithRed:0.07 green:0.72 blue:0.42 alpha:1.0]
#define G_CLR_BLUE   [UIColor colorWithRed:0.20 green:0.55 blue:0.90 alpha:1.0]
#define G_CLR_GRAY   [UIColor colorWithRed:0.52 green:0.57 blue:0.62 alpha:1.0]
#define G_CLR_RED    [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1.0]
#define G_CLR_TEXT   [UIColor colorWithRed:0.13 green:0.16 blue:0.20 alpha:1.0]
#define G_CLR_SUB    [UIColor colorWithRed:0.47 green:0.52 blue:0.57 alpha:1.0]

@interface WVFGateViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *activateButton;
@end

@implementation WVFGateViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];

    CGFloat w = self.view.bounds.size.width;
    CGFloat cw = w - 56;
    if (cw > 330) cw = 330;

    CGFloat ch = 306;
    UIView *card = [[UIView alloc] initWithFrame:
                    CGRectMake((w - cw) / 2,
                               (self.view.bounds.size.height - ch) / 2, cw, ch)];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 18;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.22;
    card.layer.shadowRadius = 20;
    card.layer.shadowOffset = CGSizeMake(0, 8);
    [self.view addSubview:card];
    self.card = card;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 24, cw - 40, 26)];
    title.text = @"激活授权";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:19];
    title.textColor = G_CLR_TEXT;
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 52, cw - 40, 18)];
    sub.text = @"一机一码，激活后可在本机使用";
    sub.textAlignment = NSTextAlignmentCenter;
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = G_CLR_SUB;
    [card addSubview:sub];

    self.keyField = [[UITextField alloc] initWithFrame:CGRectMake(20, 84, cw - 40, 44)];
    self.keyField.placeholder = @"WVF-XXXXX-XXXXX-XXXXX";
    self.keyField.textAlignment = NSTextAlignmentCenter;
    self.keyField.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.keyField.textColor = G_CLR_TEXT;
    self.keyField.backgroundColor = [UIColor colorWithRed:0.95 green:0.97 blue:0.98 alpha:1.0];
    self.keyField.layer.cornerRadius = 10;
    self.keyField.layer.borderWidth = 1;
    self.keyField.layer.borderColor = [UIColor colorWithRed:0.88 green:0.91 blue:0.93 alpha:1].CGColor;
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.keyField.returnKeyType = UIReturnKeyDone;
    self.keyField.delegate = self;
    [card addSubview:self.keyField];

    CGFloat halfW = (cw - 40 - 10) / 2.0;
    UIButton *paste = [self button:@"粘贴卡密" color:G_CLR_GRAY action:@selector(onPaste)];
    paste.frame = CGRectMake(20, 138, halfW, 40);
    paste.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [card addSubview:paste];

    self.activateButton = [self button:@"激活" color:G_CLR_BLUE action:@selector(onActivate)];
    self.activateButton.frame = CGRectMake(20 + halfW + 10, 138, halfW, 40);
    self.activateButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [card addSubview:self.activateButton];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 190, cw - 40, 34)];
    self.statusLabel.text = self.initialMessage ?: @"";
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:11.5];
    self.statusLabel.textColor = G_CLR_RED;
    [card addSubview:self.statusLabel];

    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(20, 232, cw - 40, 48)];
    foot.text = @"卡密可先在微信里复制，再点「粘贴卡密」\n激活成功后本页自动关闭";
    foot.numberOfLines = 2;
    foot.textAlignment = NSTextAlignmentCenter;
    foot.font = [UIFont systemFontOfSize:10.5];
    foot.textColor = G_CLR_SUB;
    [card addSubview:foot];

    // 长按「激活」按钮 → 网络诊断（把服务器返回原文显示出来）
    self.activateButton.userInteractionEnabled = YES;
    [self.activateButton addGestureRecognizer:
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onDiagnose)]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapBlank)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
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

- (void)onTapBlank {
    [self.view endEditing:YES];
}

- (void)setStatusText:(NSString *)text isError:(BOOL)isError {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.textColor = isError ? G_CLR_RED : G_CLR_SUB;
        self.statusLabel.text = text ?: @"";
    });
}

- (void)onDiagnose {
    [self setStatusText:@"正在诊断服务器…" isError:NO];

    __weak typeof(self) weakSelf = self;
    [[WVFLicense shared] diagnoseWithCompletion:^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:@"服务器诊断"
                                 message:text
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                                   style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:ac animated:YES completion:nil];
            [weakSelf setStatusText:@"诊断完成" isError:NO];
        });
    }];
}

- (void)onPaste {
    NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) {
        [self setStatusText:@"剪贴板是空的，请先复制卡密" isError:YES];
        return;
    }
    self.keyField.text = [s uppercaseString];
    [self setStatusText:@"已粘贴，点「激活」" isError:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self onActivate];
    return YES;
}

- (void)onActivate {
    NSString *k = [self.keyField.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!k.length) {
        [self setStatusText:@"请先输入或粘贴卡密" isError:YES];
        return;
    }

    self.activateButton.enabled = NO;
    [self setStatusText:@"正在验证…" isError:NO];
    [self.view endEditing:YES];

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
