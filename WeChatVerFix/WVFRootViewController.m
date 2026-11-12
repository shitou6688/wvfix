//
//  WVFRootViewController.m
//  微信版本伪装 — 改写 WeChat.app/Info.plist 的版本相关键
//  v1.0.7
//
//  关键修正：微信登录上报的客户端版本取的是 WeChatBundleVersion（如 8.0.5.34），
//  不是 CFBundleShortVersionString（那只是显示版本）。
//  本版同时改写：
//     CFBundleShortVersionString  显示版本
//     WeChatBundleVersion         实际上报的构建号
//
//  写入仍走内置 root 助手 wvfixd（目标属主 _installd，mobile 写不了）。
//

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/wait.h>
#import <sys/stat.h>

extern char **environ;

static NSString *const kDefaultShortVer  = @"8.0.90";
static NSString *const kDefaultBundleVer = @"8.0.9.99";

#pragma mark - root 通道

typedef int (*persona_np_fn)(posix_spawnattr_t *, int, uint32_t);
typedef int (*persona_id_fn)(posix_spawnattr_t *, id_t);

static persona_np_fn g_setPersona = NULL;
static persona_id_fn g_setPersonaUid = NULL;
static persona_id_fn g_setPersonaGid = NULL;
static BOOL g_personaResolved = NO;
static BOOL g_personaAvailable = NO;

static void resolvePersona(void) {
    if (g_personaResolved) return;
    g_personaResolved = YES;

    void *h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    if (!h) h = dlopen(NULL, RTLD_LAZY);

    g_setPersona    = (persona_np_fn)dlsym(h, "posix_spawnattr_set_persona_np");
    g_setPersonaUid = (persona_id_fn)dlsym(h, "posix_spawnattr_set_persona_uid_np");
    g_setPersonaGid = (persona_id_fn)dlsym(h, "posix_spawnattr_set_persona_gid_np");

    g_personaAvailable = (g_setPersona && g_setPersonaUid && g_setPersonaGid);
}

#define WVF_PERSONA_FLAGS_OVERRIDE 1

static int spawnRootFull(NSString *path, NSArray<NSString *> *args,
                         uint32_t flags, NSString *stdoutPath, int *spawnErr) {
    resolvePersona();
    if (spawnErr) *spawnErr = 0;
    if (!g_personaAvailable) {
        if (spawnErr) *spawnErr = -1;
        return -1000;
    }

    NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:args];

    char **cargv = (char **)calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup([argv[i] UTF8String]);
    cargv[argv.count] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    g_setPersona(&attr, 99, flags);
    g_setPersonaUid(&attr, 0);
    g_setPersonaGid(&attr, 0);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (stdoutPath.length) {
        posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, stdoutPath.UTF8String,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0644);
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, cargv[0], &fa, &attr, cargv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);

    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);

    if (rc != 0) {
        if (spawnErr) *spawnErr = rc;
        return -1100;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

static int spawnRoot(NSString *path, NSArray<NSString *> *args) {
    return spawnRootFull(path, args, WVF_PERSONA_FLAGS_OVERRIDE, nil, NULL);
}

@interface WVFRootViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *pathLabel;
@property (nonatomic, strong) UITextField *shortVerField;
@property (nonatomic, strong) UITextField *bundleVerField;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, copy)   NSString *appPath;
@property (nonatomic, copy)   NSString *currentShortVer;
@property (nonatomic, copy)   NSString *currentBundleVer;
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
            if ([fm fileExistsAtPath:[app stringByAppendingPathComponent:@"Info.plist"]]) {
                return app;
            }
        }
    }
    return nil;
}

- (NSString *)plistPath {
    return [self.appPath stringByAppendingPathComponent:@"Info.plist"];
}

- (NSString *)workDir {
    return @"/var/mobile/Documents/WeChatVerFix";
}

- (NSString *)backupDir {
    return [[self workDir] stringByAppendingPathComponent:@"backup"];
}

- (NSString *)helperPath {
    return [[NSBundle mainBundle] pathForResource:@"wvfixd" ofType:nil];
}

#pragma mark - 读写

- (NSMutableDictionary *)readPlistDict {
    NSData *data = [NSData dataWithContentsOfFile:[self plistPath]];
    if (!data) return nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                      options:NSPropertyListMutableContainersAndLeaves
                                                       format:NULL
                                                        error:NULL];
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : nil;
}

- (NSString *)readVersion {
    NSDictionary *d = [self readPlistDict];
    return d[@"CFBundleShortVersionString"];
}

- (NSString *)readWeChatBundleVersion {
    NSDictionary *d = [self readPlistDict];
    return d[@"WeChatBundleVersion"];
}

- (NSData *)buildPatchedPlistWithShort:(NSString *)shortVer
                                bundle:(NSString *)bundleVer
                                 error:(NSString **)errOut {
    NSMutableDictionary *dict = [self readPlistDict];
    if (!dict) {
        if (errOut) *errOut = @"读不到或解析不了 Info.plist";
        return nil;
    }

    dict[@"CFBundleShortVersionString"] = shortVer;
    dict[@"WeChatBundleVersion"] = bundleVer;

    NSError *err = nil;
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:dict
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&err];
    if (!out && errOut) *errOut = err.localizedDescription ?: @"序列化失败";
    return out;
}

- (BOOL)writeInPlace:(NSData *)data toPath:(NSString *)path {
    int fd = open(path.UTF8String, O_WRONLY | O_TRUNC);
    if (fd < 0) return NO;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n <= 0) { close(fd); return NO; }
        bytes += n;
        left -= (size_t)n;
    }
    fsync(fd);
    close(fd);
    return YES;
}

- (NSString *)describeItem:(NSString *)path {
    NSError *err = nil;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&err];
    if (!a) return [NSString stringWithFormat:@"(%@)", err.localizedDescription];
    return [NSString stringWithFormat:@"owner=%@ group=%@ perm=%@",
            a[NSFileOwnerAccountName], a[NSFileGroupOwnerAccountName],
            a[NSFilePosixPermissions]];
}

- (BOOL)rootWriteViaHelper:(NSData *)data {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[self workDir] withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *helper = [self helperPath];
    if (!helper.length || ![fm fileExistsAtPath:helper]) {
        [self log:@"[!] 找不到 root 助手 wvfixd"];
        return NO;
    }

    NSString *tmp = [[self workDir] stringByAppendingPathComponent:@"patch.tmp.plist"];
    [fm removeItemAtPath:tmp error:NULL];
    if (![data writeToFile:tmp atomically:YES]) {
        [self log:@"[!] 临时文件写入失败"];
        return NO;
    }

    int err = 0;
    int rc = spawnRootFull(helper, @[tmp, [self plistPath]],
                           WVF_PERSONA_FLAGS_OVERRIDE, nil, &err);
    [self log:@"[i] root 助手：rc=%d spawnErr=%d", rc, err];
    return rc == 0;
}

- (void)probeRoot {
    NSString *helper = [self helperPath];
    if (!helper.length) return;
    NSString *out = [[self workDir] stringByAppendingPathComponent:@"uid.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];

    int err = 0;
    int rc = spawnRootFull(helper, @[@"--uid", out], WVF_PERSONA_FLAGS_OVERRIDE, nil, &err);
    NSString *text = [NSString stringWithContentsOfFile:out
                                               encoding:NSUTF8StringEncoding error:NULL];
    if (rc == 0 && text.length) {
        [self log:@"[i] root 自检：%@", [text stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    } else {
        [self log:@"[i] root 自检失败：rc=%d spawnErr=%d", rc, err];
    }
}

- (BOOL)writeShort:(NSString *)shortVer bundle:(NSString *)bundleVer error:(NSString **)errOut {
    NSString *buildErr = nil;
    NSData *out = [self buildPatchedPlistWithShort:shortVer bundle:bundleVer error:&buildErr];
    if (!out) {
        if (errOut) *errOut = buildErr ?: @"生成新 plist 失败";
        return NO;
    }
    NSString *p = [self plistPath];

    if ([self rootWriteViaHelper:out]) {
        [self log:@"[i] 写入方式：root 助手"];
        return YES;
    }

    if ([self writeInPlace:out toPath:p]) {
        [self log:@"[i] 写入方式：就地写"];
        return YES;
    }
    int e1 = errno;
    NSString *e1Text = [NSString stringWithUTF8String:strerror(e1)];
    [self log:@"[!] 就地写失败 errno=%d %@", e1, e1Text];

    NSError *e2 = nil;
    if ([out writeToFile:p options:0 error:&e2]) {
        [self log:@"[i] 写入方式：原子写"];
        return YES;
    }

    NSMutableString *diag = [NSMutableString string];
    [diag appendFormat:@"全部写入方式失败\n文件 %@\n目录 %@",
        [self describeItem:p], [self describeItem:[p stringByDeletingLastPathComponent]]];
    if (errOut) *errOut = diag;
    return NO;
}

#pragma mark - 备份 / 还原

- (BOOL)backupNow:(NSString **)msgOut {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:[self backupDir]
       withIntermediateDirectories:YES attributes:nil error:NULL]) {
        if (msgOut) *msgOut = @"建不了备份目录";
        return NO;
    }

    NSData *cur = [NSData dataWithContentsOfFile:[self plistPath]];
    NSArray *existing = [self backups];
    if (existing.count) {
        NSString *last = [existing lastObject];
        NSData *lastData = [NSData dataWithContentsOfFile:
                            [[self backupDir] stringByAppendingPathComponent:last]];
        if (cur && lastData && [cur isEqualToData:lastData]) {
            if (msgOut) *msgOut = [NSString stringWithFormat:@"%@（内容相同，跳过）", last];
            return YES;
        }
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
    NSString *src = [[self backupDir] stringByAppendingPathComponent:name];
    NSData *d = [NSData dataWithContentsOfFile:src];
    if (!d) return NO;
    if ([self rootWriteViaHelper:d]) return YES;
    return [self writeInPlace:d toPath:[self plistPath]];
}

#pragma mark - 杀进程

- (void)killWeChat {
    if (spawnRoot(@"/usr/bin/killall", @[@"-9", @"WeChat"]) == 0) {
        [self log:@"已结束微信进程（root）"];
        return;
    }
    pid_t pid = 0;
    char *argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    if (posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ) == 0) {
        [self log:@"已结束微信进程"];
        return;
    }
    [self log:@"结束进程失败，请手动上滑关掉微信"];
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
        if (self.logView.text.length > 0) {
            [self.logView scrollRangeToVisible:
                NSMakeRange(self.logView.text.length - 1, 1)];
        }
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

- (void)copyLog {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = self.logView.text ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"已复制"
                         message:@"全部日志已复制到剪贴板"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (UILabel *)makeFieldLabel:(NSString *)text y:(CGFloat)y width:(CGFloat)w {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 18)];
    l.font = [UIFont systemFontOfSize:11];
    l.textColor = [UIColor darkGrayColor];
    l.text = text;
    [self.view addSubview:l];
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"微信版本伪装";

    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 84;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 24)];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:15];
    self.statusLabel.text = @"正在扫描微信…";
    [self.view addSubview:self.statusLabel];
    y += 26;

    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 28)];
    self.pathLabel.font = [UIFont systemFontOfSize:9];
    self.pathLabel.textColor = [UIColor grayColor];
    self.pathLabel.numberOfLines = 2;
    [self.view addSubview:self.pathLabel];
    y += 34;

    [self makeFieldLabel:@"显示版本  CFBundleShortVersionString" y:y width:w];
    y += 20;
    self.shortVerField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w - 32, 38)];
    self.shortVerField.borderStyle = UITextBorderStyleRoundedRect;
    self.shortVerField.placeholder = @"例如 8.0.90";
    self.shortVerField.text = kDefaultShortVer;
    self.shortVerField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.shortVerField.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.shortVerField];
    y += 44;

    [self makeFieldLabel:@"上报版本  WeChatBundleVersion（登录校验看这个）" y:y width:w];
    y += 20;
    self.bundleVerField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w - 32, 38)];
    self.bundleVerField.borderStyle = UITextBorderStyleRoundedRect;
    self.bundleVerField.placeholder = @"例如 8.0.9.99";
    self.bundleVerField.text = kDefaultBundleVer;
    self.bundleVerField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.bundleVerField.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.bundleVerField];
    y += 46;

    UIButton *doBtn = [self makeButton:@"一键改写两个版本号" action:@selector(onPatch)];
    doBtn.frame = CGRectMake(16, y, w - 32, 44);
    doBtn.backgroundColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.35 alpha:1.0];
    [doBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:doBtn];
    y += 50;

    CGFloat half = (w - 32 - 10) / 2.0;
    UIButton *restoreBtn = [self makeButton:@"还原到改前版本" action:@selector(onRestore)];
    restoreBtn.frame = CGRectMake(16, y, half, 38);
    [self.view addSubview:restoreBtn];

    UIButton *copyBtn = [self makeButton:@"复制全部日志" action:@selector(copyLog)];
    copyBtn.frame = CGRectMake(16 + half + 10, y, half, 38);
    copyBtn.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    [self.view addSubview:copyBtn];
    y += 44;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, y, w - 24,
                                                               self.view.bounds.size.height - y - 14)];
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    self.logView.layer.cornerRadius = 8;
    [self.view addSubview:self.logView];

    [self refresh];
}

- (void)refresh {
    self.appPath = [self findWeChatApp];
    if (!self.appPath) {
        self.statusLabel.text = @"没找到 WeChat.app";
        self.pathLabel.text = @"确认微信已安装。";
        [self log:@"[x] 扫描失败：没有 WeChat.app"];
        return;
    }
    self.currentShortVer = [self readVersion];
    self.currentBundleVer = [self readWeChatBundleVersion];
    self.statusLabel.text = [NSString stringWithFormat:@"当前：显示 %@ / 上报 %@",
                             self.currentShortVer ?: @"?",
                             self.currentBundleVer ?: @"(无此键)"];
    self.pathLabel.text = self.appPath;

    [self log:@"[+] 找到微信：%@", self.appPath];
    [self log:@"[i] CFBundleShortVersionString = %@", self.currentShortVer ?: @"(无)"];
    [self log:@"[i] WeChatBundleVersion        = %@", self.currentBundleVer ?: @"(无，写入时会新建)"];
    [self log:@"[i] 文件属性：%@", [self describeItem:[self plistPath]]];

    resolvePersona();
    [self log:@"[i] persona 符号：%@", g_personaAvailable ? @"可用" : @"缺失"];

    [[NSFileManager defaultManager] createDirectoryAtPath:[self workDir]
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([self helperPath]) [self probeRoot];
}

- (void)onPatch {
    if (!self.appPath) {
        [self log:@"[x] 还没找到微信"];
        return;
    }
    NSString *sVer = [self.shortVerField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    NSString *bVer = [self.bundleVerField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    if (sVer.length < 3 || bVer.length < 3) {
        [self log:@"[x] 版本号不合法：%@ / %@", sVer, bVer];
        return;
    }
    [self log:@"---- 改号 -> 显示 %@ / 上报 %@ ----", sVer, bVer];

    NSString *bkName = nil;
    if ([self backupNow:&bkName]) {
        [self log:@"[+] 备份：%@", bkName];
    } else {
        [self log:@"[!] 备份失败：%@", bkName ?: @"未知"];
    }

    NSString *err = nil;
    if ([self writeShort:sVer bundle:bVer error:&err]) {
        self.currentShortVer = [self readVersion];
        self.currentBundleVer = [self readWeChatBundleVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前：显示 %@ / 上报 %@",
                                 self.currentShortVer ?: @"?",
                                 self.currentBundleVer ?: @"(无此键)"];
        [self log:@"[+] 写入成功，现在读到 显示 %@ / 上报 %@",
            self.currentShortVer ?: @"?", self.currentBundleVer ?: @"?"];
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
    NSString *first = bs.firstObject;
    if ([self restoreBackup:first]) {
        self.currentShortVer = [self readVersion];
        self.currentBundleVer = [self readWeChatBundleVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前：显示 %@ / 上报 %@",
                                 self.currentShortVer ?: @"?",
                                 self.currentBundleVer ?: @"(无此键)"];
        [self log:@"[+] 已还原：%@", first];
        [self killWeChat];
    } else {
        [self log:@"[x] 还原失败：%@", first];
    }
}

@end
