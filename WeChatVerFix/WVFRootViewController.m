//
//  WVFRootViewController.m
//  微信版本伪装 — 一键改写 WeChat.app/Info.plist 的版本号
//  v1.0.3
//
//  实测结论：目标文件属主是 _installd、0644，目录 _installd 0755，
//  普通 mobile 进程无论如何都写不进去（需要 root）。
//  因此本版增加 root 通道：persona spawn（uid/gid=0）执行 /bin/cp 覆盖。
//  私有符号用 dlsym 动态解析，缺失时只降级、不会因链接失败而闪退。
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

static NSString *const kDefaultVer = @"8.0.90";

#pragma mark - root 通道（dlsym，符号缺失也不会崩）

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

// 以 uid/gid=0 执行一个外部程序，返回 exit code；<0 表示根本没起来
static int spawnRootFlags(NSString *path, NSArray<NSString *> *args, uint32_t flags) {
    resolvePersona();
    if (!g_personaAvailable) return -1;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return -2;

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

    pid_t pid = 0;
    int rc = posix_spawn(&pid, cargv[0], NULL, &attr, cargv, environ);
    posix_spawnattr_destroy(&attr);

    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);

    if (rc != 0) return -1000 - rc;

    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -3;
}

static int spawnRoot(NSString *path, NSArray<NSString *> *args) {
    return spawnRootFlags(path, args, WVF_PERSONA_FLAGS_OVERRIDE);
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

// 把内容写到 mobile 可写的目录，再由 root 覆盖目标
- (BOOL)rootCopyFallback:(NSData *)data {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[self workDir] withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *tmp = [[self workDir] stringByAppendingPathComponent:@"patch.tmp.plist"];
    [fm removeItemAtPath:tmp error:NULL];
    if (![data writeToFile:tmp atomically:YES]) {
        [self log:@"[!] 临时文件写入失败"];
        return NO;
    }
    [self log:@"[i] 临时文件已写：%@", tmp];

    // 优先 cp，其次 cat
    NSArray *cands = @[
        @[@"/bin/cp", tmp, [self plistPath]],
        @[@"/usr/bin/cp", tmp, [self plistPath]],
        @[@"/bin/cat", tmp],
    ];

    for (NSArray *c in cands) {
        NSString *tool = c[0];
        if (![fm fileExistsAtPath:tool]) continue;

        if ([tool hasSuffix:@"cat"]) {
            // cat 需要 shell 重定向，iOS 无 sh，跳过
            continue;
        }
        NSArray *args = [c subarrayWithRange:NSMakeRange(1, c.count - 1)];
        int rc = spawnRoot(tool, args);
        [self log:@"[i] root %@：rc=%d", [tool lastPathComponent], rc];
        if (rc == 0) return YES;
    }
    return NO;
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
        [self log:@"[i] 写入方式：就地写（当前用户）"];
        return YES;
    }
    int e1 = errno;
    [self log:@"[!] 就地写失败 errno=%d (%s)", e1, strerror(e1)];

    // 2) root 通道
    if ([self rootCopyFallback:out]) {
        [self log:@"[i] 写入方式：root cp"];
        return YES;
    }

    // 3) 诊断
    NSMutableString *diag = [NSMutableString string];
    [diag appendFormat:@"就地写与 root 通道均失败\n文件 %@\n目录 %@\npersona 符号=%d",
        [self describeItem:p],
        [self describeItem:[p stringByDeletingLastPathComponent]],
        g_personaAvailable ? 1 : 0];
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
    NSString *src = [self.backupDir stringByAppendingPathComponent:name];
    NSData *d = [NSData dataWithContentsOfFile:src];
    if (!d) return NO;
    if ([self writeInPlace:d toPath:[self plistPath]]) return YES;
    return [self rootCopyFallback:d];
}

#pragma mark - 杀进程

- (void)killWeChat {
    int rc = spawnRoot(@"/usr/bin/killall", @[@"-9", @"WeChat"]);
    if (rc == 0) {
        [self log:@"已结束微信进程"];
        return;
    }
    pid_t pid = 0;
    char *argv[] = { (char *)"killall", (char *)"-9", (char *)"WeChat", NULL };
    if (posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, argv, environ) == 0) {
        [self log:@"已结束微信进程（当前用户）"];
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

    resolvePersona();
    [self log:@"[i] persona 符号：%@", g_personaAvailable ? @"可用" : @"缺失"];
    [self runDiagnostics];
}

- (void)runDiagnostics {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"==== WeChatVerFix 诊断 ====\n"];
    [s appendFormat:@"uid=%d euid=%d gid=%d\n", getuid(), geteuid(), getgid()];
    [s appendFormat:@"persona symbols=%d\n", g_personaAvailable ? 1 : 0];
    [s appendFormat:@"plist=%s\n", [[self plistPath] UTF8String]];

    struct stat st;
    if (stat([[self plistPath] UTF8String], &st) == 0) {
        [s appendFormat:@"plist mode=%o uid=%d gid=%d\n", st.st_mode & 07777, st.st_uid, st.st_gid];
    } else {
        [s appendFormat:@"plist stat errno=%d %s\n", errno, strerror(errno)];
    }

    int rc1 = spawnRootFlags(@"/bin/ls", @[@"/"], 1);
    [s appendFormat:@"spawn(/bin/ls, flags=1)=%d\n", rc1];
    int rc0 = spawnRootFlags(@"/bin/ls", @[@"/"], 0);
    [s appendFormat:@"spawn(/bin/ls, flags=0)=%d\n", rc0];

    errno = 0;
    int ch = chmod([[self plistPath] UTF8String], 0666);
    [s appendFormat:@"chmod(plist,0666)=%d errno=%d %s\n", ch, errno, ch == 0 ? "ok" : strerror(errno)];

    errno = 0;
    int fd = open([[self plistPath] UTF8String], O_WRONLY);
    [s appendFormat:@"open(O_WRONLY)=%d errno=%d %s\n", fd, errno, fd >= 0 ? "ok" : strerror(errno));
    if (fd >= 0) close(fd);

    [s appendString:@"==== end ====\n"];

    NSString *diagPath = [[self workDir] stringByAppendingPathComponent:@"diag.txt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[self workDir]
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [s writeToFile:diagPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        if (line.length) [self log:@"%@", line];
    }
    [self log:@"[i] 诊断已存盘：%@", diagPath];
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
