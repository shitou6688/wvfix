//
//  WVFRootViewController.m
//  微信版本伪装 — 一键改写 WeChat.app/Info.plist 的版本号
//  运行环境：TrollStore 安装（依赖 platform-application + no-sandbox 权限）
//

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dispatch/dispatch.h>

extern char **environ;

static NSString *const kDefaultVer = @"8.0.60";

@interface WVFRootViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *pathLabel;
@property (nonatomic, strong) UITextField *verField;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, copy)   NSString *appPath;
@property (nonatomic, copy)   NSString *currentVer;
@end

@implementation WVFRootViewController

#pragma mark - 路径

- (NSArray<NSString *> *)searchRoots {
    return @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application",
    ];
}

- (NSString *)findWeChatApp {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in [self searchRoots]) {
        NSArray *dirs = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *uuid in dirs) {
            NSString *app = [root stringByAppendingPathComponent:
                             [uuid stringByAppendingPathComponent:@"WeChat.app"]];
            NSString *plist = [app stringByAppendingPathComponent:@"Info.plist"];
            if ([fm fileExistsAtPath:plist]) {
                return app;
            }
        }
    }
    return nil;
}

- (NSString *)plistPath {
    return [self.appPath stringByAppendingPathComponent:@"Info.plist"];
}

- (NSString *)backupDir {
    return @"/var/mobile/Documents/WeChatVerFix/backup";
}

#pragma mark - 读写版本号

- (NSString *)readVersion {
    NSData *data = [NSData dataWithContentsOfFile:[self plistPath]];
    if (!data) return nil;
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data
                                                                  options:0
                                                                   format:NULL
                                                                    error:NULL];
    return dict[@"CFBundleShortVersionString"];
}

- (BOOL)writeVersion:(NSString *)newVer error:(NSString **)errOut {
    NSData *data = [NSData dataWithContentsOfFile:[self plistPath]];
    if (!data) {
        if (errOut) *errOut = @"读不到 Info.plist";
        return NO;
    }
    NSError *err = nil;
    NSMutableDictionary *dict =
        [NSPropertyListSerialization propertyListWithData:data
                                                  options:NSPropertyListMutableContainersAndLeaves
                                                   format:NULL
                                                    error:&err];
    if (![dict isKindOfClass:[NSMutableDictionary class]]) {
        if (errOut) *errOut = err.localizedDescription ?: @"plist 解析失败";
        return NO;
    }

    dict[@"CFBundleShortVersionString"] = newVer;

    NSData *out = [NSPropertyListSerialization dataWithPropertyList:dict
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&err];
    if (!out) {
        if (errOut) *errOut = err.localizedDescription ?: @"序列化失败";
        return NO;
    }
    if (![out writeToFile:[self plistPath] atomically:YES]) {
        if (errOut) *errOut = @"写入被拒绝（没有文件系统权限？）";
        return NO;
    }
    return YES;
}

#pragma mark - 备份 / 还原

- (BOOL)backupNow:(NSString **)msgOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:[self backupDir]
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL]) {
        if (msgOut) *msgOut = @"建不了备份目录";
        return NO;
    }
    NSString *ver = [self readVersion] ?: @"unknown";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"Info.plist.%@.%@",
                      ver, [df stringFromDate:[NSDate date]]];
    NSString *dst = [self.backupDir stringByAppendingPathComponent:name];
    NSError *err = nil;
    [fm copyItemAtPath:[self plistPath] toPath:dst error:&err];
    if (err) {
        if (msgOut) *msgOut = err.localizedDescription;
        return NO;
    }
    if (msgOut) *msgOut = name;
    return YES;
}

- (NSArray<NSString *> *)backups {
    NSArray *files = [[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:[self backupDir] error:nil];
    files = [files filteredArrayUsingPredicate:
             [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'Info.plist.'"]];
    return [files sortedArrayUsingSelector:@selector(compare:)];
}

- (BOOL)restoreBackup:(NSString *)name {
    NSString *src = [self.backupDir stringByAppendingPathComponent:name];
    NSData *d = [NSData dataWithContentsOfFile:src];
    if (!d) return NO;
    return [d writeToFile:[self plistPath] atomically:YES];
}

#pragma mark - 杀进程

- (void)killWeChat {
    pid_t pid = 0;
    char *argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    int r = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ);
    [self log:(r == 0 ? @"已结束微信进程" : @"结束进程失败，请手动上滑关掉微信")];
}

#pragma mark - UI

- (void)log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *old = self.logView.text ?: @"";
        self.logView.text = [old stringByAppendingFormat:@"%@\n", line];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    });
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    b.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1.0];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"微信版本伪装";

    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 90;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 26)];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:16];
    self.statusLabel.text = @"正在扫描微信…";
    [self.view addSubview:self.statusLabel];
    y += 30;

    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 40)];
    self.pathLabel.font = [UIFont systemFontOfSize:11];
    self.pathLabel.textColor = [UIColor grayColor];
    self.pathLabel.numberOfLines = 2;
    [self.view addSubview:self.pathLabel];
    y += 48;

    self.verField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w - 32, 40)];
    self.verField.borderStyle = UITextBorderStyleRoundedRect;
    self.verField.placeholder = @"目标版本号，例如 8.0.60";
    self.verField.text = kDefaultVer;
    self.verField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.verField.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.verField];
    y += 52;

    UIButton *doBtn = [self makeButton:@"一键改成这个版本" action:@selector(onPatch)];
    doBtn.frame = CGRectMake(16, y, w - 32, 46);
    doBtn.backgroundColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.35 alpha:1.0];
    [doBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:doBtn];
    y += 56;

    UIButton *restoreBtn = [self makeButton:@"还原到改前的版本" action:@selector(onRestore)];
    restoreBtn.frame = CGRectMake(16, y, w - 32, 44);
    [self.view addSubview:restoreBtn];
    y += 56;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, y, w - 24,
                                                               self.view.bounds.size.height - y - 20)];
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    self.logView.layer.cornerRadius = 8;
    [self.view addSubview:self.logView];

    [self refresh];
}

- (void)refresh {
    self.appPath = [self findWeChatApp];
    if (!self.appPath) {
        self.statusLabel.text = @"没找到 WeChat.app";
        self.pathLabel.text = @"确认微信已安装。若已安装但仍找不到，说明本 app 没有拿到 no-sandbox 权限（TrollStore 安装才会授予）。";
        [self log:@"[x] 扫描失败：/var/containers/Bundle/Application 下没有 WeChat.app"];
        return;
    }
    self.currentVer = [self readVersion];
    self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"未知"];
    self.pathLabel.text = self.appPath;
    [self log:@"[+] 找到微信：%@", self.appPath];
    [self log:@"[i] 当前版本：%@", self.currentVer ?: @"未知"];
    NSArray *bs = [self backups];
    [self log:@"[i] 已有备份 %lu 个", (unsigned long)bs.count];
}

- (void)onPatch {
    if (!self.appPath) {
        [self log:@"[x] 还没找到微信，先检查安装状态"];
        return;
    }
    NSString *ver = [self.verField.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (ver.length < 3) {
        [self log:@"[x] 版本号不合法：%@", ver];
        return;
    }
    NSString *bkName = nil;
    if ([self backupNow:&bkName]) {
        [self log:@"[+] 已备份：%@", bkName];
    } else {
        [self log:@"[!] 备份失败：%@（继续尝试写入）", bkName ?: @"未知"];
    }

    NSString *err = nil;
    if ([self writeVersion:ver error:&err]) {
        self.currentVer = [self readVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"?"];
        [self log:@"[+] 写入成功，现在读到的是 %@", self.currentVer ?: @"?"];
        [self killWeChat];
        [self log:@"[✓] 回桌面点开微信登录即可"];
    } else {
        [self log:@"[x] 写入失败：%@", err ?: @"未知"];
    }
}

- (void)onRestore {
    NSArray *bs = [self backups];
    if (bs.count == 0) {
        [self log:@"[x] 没有备份可还原"];
        return;
    }
    NSString *first = bs.firstObject;   // 最早那份 = 原始版本
    if ([self restoreBackup:first]) {
        self.currentVer = [self readVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"?"];
        [self log:@"[+] 已还原原始备份：%@", first];
        [self killWeChat];
    } else {
        [self log:@"[x] 还原失败：%@", first];
    }
}

@end
