//
//  WVFRootViewController.m
//  微信版本伪装 — 一键改写 WeChat.app/Info.plist 的版本号
//  v1.0.1
//   - 移除 platform-application（它会让系统把本 app 当系统应用，反而限制写用户 app bundle）
//   - 优先就地写入（不动 inode、不依赖目录写权限，避免 rename 被拒）
//   - 两级 root 兜底：persona spawn 的 /bin/cp、/usr/bin/plutil
//   - 失败时打印文件/目录属主与 errno，便于定位
//

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/wait.h>

extern char **environ;

static NSString *const kDefaultVer = @"8.0.90";

#pragma mark - 以 root 身份执行（依赖 com.apple.private.persona-mgmt）

static int spawnPersonaRoot(NSString *path, NSArray<NSString *> *args) {
    NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:args];

    char **cargv = (char **)calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) {
        cargv[i] = strdup([argv[i] UTF8String]);
    }
    cargv[argv.count] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, cargv[0], NULL, &attr, cargv, environ);
    posix_spawnattr_destroy(&attr);

    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);

    if (rc != 0) return -1000 - rc;

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

static BOOL fileExistsAt(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

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

- (NSData *)buildPatchedPlist:(NSString *)newVer error:(NSString **)errOut {
    NSData *data = [NSData dataWithContentsOfFile:[self plistPath]];
    if (!data) {
        if (errOut) *errOut = @"读不到 Info.plist";
        return nil;
    }
    NSError *err = nil;
    NSMutableDictionary *dict =
        [NSPropertyListSerialization propertyListWithData:data
                                                  options:NSPropertyListMutableContainersAndLeaves
                                                   format:NULL
                                                    error:&err];
    if (![dict isKindOfClass:[NSMutableDictionary class]]) {
        if (errOut) *errOut = err.localizedDescription ?: @"plist 解析失败";
        return nil;
    }
    dict[@"CFBundleShortVersionString"] = newVer;

    NSData *out = [NSPropertyListSerialization dataWithPropertyList:dict
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&err];
    if (!out && errOut) *errOut = err.localizedDescription ?: @"序列化失败";
    return out;
}

// 就地写：只要求文件本身可写，不需要目录写权限（原子写的 rename 才需要）
- (BOOL)writeInPlace:(NSData *)data toPath:(NSString *)path {
    int fd = open(path.UTF8String, O_WRONLY | O_TRUNC);
    if (fd < 0) return NO;

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n <= 0) {
            close(fd);
            return NO;
        }
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
    return [NSString stringWithFormat:@"owner=%@ group=%@ perm=%o",
            a[NSFileOwnerAccountName], a[NSFileGroupOwnerAccountName],
            (unsigned int)[a[NSFilePosixPermissions] shortValue]];
}

// root 兜底之一：先写到可写目录，再 root cp 覆盖目标
- (BOOL)rootCopyFallback:(NSData *)data {
    NSString *tmp = [[self workDir] stringByAppendingPathComponent:@"patch.tmp.plist"];
    if (![data writeToFile:tmp atomically:YES]) return NO;
    if (!fileExistsAt(@"/bin/cp")) return NO;
    int rc = spawnPersonaRoot(@"/bin/cp", @[tmp, [self plistPath]]);
    [self log:@"[i] root cp 兜底：rc=%d", rc];
    return rc == 0;
}

// root 兜底之二：plutil 直接改键（老系统可能不支持 -replace）
- (BOOL)rootPlutilFallback:(NSString *)newVer {
    if (!fileExistsAt(@"/usr/bin/plutil")) return NO;
    int rc = spawnPersonaRoot(@"/usr/bin/plutil",
                              @[@"-replace", @"CFBundleShortVersionString",
                                @"-string", newVer, [self plistPath]]);
    [self log:@"[i] root plutil 兜底：rc=%d", rc];
    return rc == 0;
}

- (BOOL)writeVersion:(NSString *)newVer error:(NSString **)errOut {
    NSString *buildErr = nil;
    NSData *out = [self buildPatchedPlist:newVer error:&buildErr];
    if (!out) {
        if (errOut) *errOut = buildErr ?: @"生成新 plist 失败";
        return NO;
    }
    NSString *p = [self plistPath];

    // 1) 就地写
    if ([self writeInPlace:out toPath:p]) {
        [self log:@"[i] 写入方式：就地写"];
        return YES;
    }
    int e1 = errno;
    [self log:@"[!] 就地写失败 errno=%d (%s)", e1, strerror(e1)];

    // 2) 原子写
    NSError *e2 = nil;
    if ([out writeToFile:p options:0 error:&e2]) {
        [self log:@"[i] 写入方式：原子写"];
        return YES;
    }
    [self log:@"[!] 原子写失败：%@", e2.localizedDescription ?: @"?"];

    // 3) root 兜底
    if ([self rootCopyFallback:out]) {
        [self log:@"[i] 写入方式：root cp"];
        return YES;
    }
    if ([self rootPlutilFallback:newVer]) {
        [self log:@"[i] 写入方式：root plutil"];
        return YES;
    }

    // 4) 诊断
    NSMutableString *diag = [NSMutableString string];
    [diag appendFormat:@"全部写入方式失败\n文件 %@\n目录 %@\n",
        [self describeItem:p], [self describeItem:[p stringByDeletingLastPathComponent]]];
    if (errOut) *errOut = diag;
    return NO;
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
    NSString *src = [self.backupDir stringByAppendingPathComponent:name];
    NSData *d = [NSData dataWithContentsOfFile:src];
    if (!d) return NO;
    if ([self writeInPlace:d toPath:[self plistPath]]) return YES;
    if ([d writeToFile:[self plistPath] options:0 error:NULL]) return YES;
    return [self rootCopyFallback:d];
}

#pragma mark - 杀进程

- (void)killWeChat {
    NSArray *cands = @[@[@"/usr/bin/killall", @"-9", @"WeChat"],
                       @[@"/bin/kill", @"-9", @"WeChat"]];
    for (NSArray *argv in cands) {
        NSString *tool = argv[0];
        if (!fileExistsAt(tool)) continue;
        NSArray *args = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
        if (spawnPersonaRoot(tool, args) == 0) {
            [self log:@"已结束微信进程"];
            return;
        }
        pid_t pid = 0;
        char *cargv[4] = {(char *)[tool UTF8String], (char *)"-9",
                          (char *)"WeChat", NULL};
        if (posix_spawn(&pid, cargv[0], NULL, NULL, cargv, environ) == 0) {
            [self log:@"已结束微信进程（当前用户）"];
            return;
        }
        break;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"微信版本伪装";

    CGFloat w = self.view.bounds.size.width;
    CGFloat y = 88;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 26)];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:16];
    self.statusLabel.text = @"正在扫描微信…";
    [self.view addSubview:self.statusLabel];
    y += 30;

    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 32, 40)];
    self.pathLabel.font = [UIFont systemFontOfSize:10];
    self.pathLabel.textColor = [UIColor grayColor];
    self.pathLabel.numberOfLines = 2;
    [self.view addSubview:self.pathLabel];
    y += 46;

    self.verField = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w - 32, 40)];
    self.verField.borderStyle = UITextBorderStyleRoundedRect;
    self.verField.placeholder = @"目标版本号";
    self.verField.text = kDefaultVer;
    self.verField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.verField.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.verField];
    y += 50;

    UIButton *doBtn = [self makeButton:@"一键改成这个版本" action:@selector(onPatch)];
    doBtn.frame = CGRectMake(16, y, w - 32, 46);
    doBtn.backgroundColor = [UIColor colorWithRed:0.13 green:0.65 blue:0.35 alpha:1.0];
    [doBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:doBtn];
    y += 54;

    UIButton *restoreBtn = [self makeButton:@"还原到改前的版本" action:@selector(onRestore)];
    restoreBtn.frame = CGRectMake(16, y, w - 32, 42);
    [self.view addSubview:restoreBtn];
    y += 52;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(12, y, w - 24,
                                                               self.view.bounds.size.height - y - 16)];
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
        self.pathLabel.text = @"确认微信已安装。若已安装仍找不到，说明本 app 没拿到 no-sandbox 权限。";
        [self log:@"[x] 扫描失败：没有 WeChat.app"];
        return;
    }
    self.currentVer = [self readVersion];
    self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"未知"];
    self.pathLabel.text = self.appPath;
    [self log:@"[+] 找到微信：%@", self.appPath];
    [self log:@"[i] 当前版本：%@", self.currentVer ?: @"未知"];
    [self log:@"[i] 文件属性：%@", [self describeItem:[self plistPath]]];
    [self log:@"[i] 目录属性：%@",
        [self describeItem:[[self plistPath] stringByDeletingLastPathComponent]]];
}

- (void)onPatch {
    if (!self.appPath) {
        [self log:@"[x] 还没找到微信"];
        return;
    }
    NSString *ver = [self.verField.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
    if (ver.length < 3) {
        [self log:@"[x] 版本号不合法：%@", ver];
        return;
    }
    [self log:@"---- 开始改号 -> %@ ----", ver];

    NSString *bkName = nil;
    if ([self backupNow:&bkName]) {
        [self log:@"[+] 备份：%@", bkName];
    } else {
        [self log:@"[!] 备份失败：%@", bkName ?: @"未知"];
    }

    NSString *err = nil;
    if ([self writeVersion:ver error:&err]) {
        self.currentVer = [self readVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"?"];
        [self log:@"[+] 写入成功，现在读到 %@", self.currentVer ?: @"?"];
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
        self.currentVer = [self readVersion];
        self.statusLabel.text = [NSString stringWithFormat:@"当前版本：%@", self.currentVer ?: @"?"];
        [self log:@"[+] 已还原：%@", first];
        [self killWeChat];
    } else {
        [self log:@"[x] 还原失败：%@", first];
    }
}

@end
