//
//  WVFRootViewController.m
//  微版助手 — 改写 WeChat.app/Info.plist 的版本字段
//  v1.5.0
//
//  布局：紧凑卡片（两列输入 + 一行三按钮 + 结果提示条）
//        下方常驻教程面板；完整日志仍收在右上角「日志」小窗
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <spawn.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdio.h>
#import <sys/wait.h>
#import <sys/stat.h>

extern char **environ;

static NSString *const kDefaultShortVer  = @"8.0.90";
static NSString *const kDefaultBundleVer = @"8.0.99.99";

#define CLR_GREEN   [UIColor colorWithRed:0.07 green:0.72 blue:0.42 alpha:1.0]
#define CLR_ORANGE  [UIColor colorWithRed:0.93 green:0.58 blue:0.10 alpha:1.0]
#define CLR_GRAY    [UIColor colorWithRed:0.52 green:0.57 blue:0.62 alpha:1.0]
#define CLR_BLUE    [UIColor colorWithRed:0.20 green:0.55 blue:0.90 alpha:1.0]
#define CLR_RED     [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1.0]
#define CLR_TEXT    [UIColor colorWithRed:0.13 green:0.16 blue:0.20 alpha:1.0]
#define CLR_SUB     [UIColor colorWithRed:0.47 green:0.52 blue:0.57 alpha:1.0]

#pragma mark - 版本字段工具

static BOOL isVersionLikeString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    if (s.length == 0 || s.length > 24) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
    return [[s stringByTrimmingCharactersInSet:allowed] length] == 0;
}

static BOOL shouldSkipVersionKey(NSString *key) {
    NSString *l = key.lowercaseString;
    if ([l containsString:@"minimum"]) return YES;
    if ([l containsString:@"compatible"]) return YES;
    return NO;
}

static NSString *bumpLastComponent(NSString *v) {
    NSMutableArray *parts = [[v componentsSeparatedByString:@"."] mutableCopy];
    if (parts.count == 0) return v;
    NSUInteger idx = parts.count - 1;
    long long n = [parts[idx] longLongValue];
    parts[idx] = [NSString stringWithFormat:@"%lld", n + 100];
    return [parts componentsJoinedByString:@"."];
}

static NSArray<NSNumber *> *numComponents(NSString *v) {
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *p in [v componentsSeparatedByString:@"."]) {
        [r addObject:@([p longLongValue])];
    }
    return r;
}

static NSString *maxComponentwise(NSString *current, NSString *tpl) {
    NSArray *c = numComponents(current);
    NSArray *t = numComponents(tpl);
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < c.count; i++) {
        long long cv = [c[i] longLongValue];
        long long tv = (i < t.count) ? [t[i] longLongValue] : cv;
        long long m = cv > tv ? cv : tv;
        [out addObject:[NSString stringWithFormat:@"%lld", m]];
    }
    return [out componentsJoinedByString:@"."];
}

static BOOL versionAtLeast(NSString *newV, NSString *oldV) {
    NSArray *a = numComponents(newV);
    NSArray *b = numComponents(oldV);
    NSUInteger n = a.count > b.count ? a.count : b.count;
    for (NSUInteger i = 0; i < n; i++) {
        long long av = (i < a.count) ? [a[i] longLongValue] : 0;
        long long bv = (i < b.count) ? [b[i] longLongValue] : 0;
        if (av != bv) return av > bv;
    }
    return YES;
}

#pragma mark - root 通道

typedef int (*persona_np_fn)(posix_spawnattr_t *, int, uint32_t);
typedef int (*persona_id_fn)(posix_spawnattr_t *, int);

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

@interface WVFRootViewController : UIViewController
@property (nonatomic) dispatch_queue_t workQueue;
@property (nonatomic, strong) CAGradientLayer *bgLayer;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *resultBanner;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UITextField *shortVerField;
@property (nonatomic, strong) UITextField *bundleVerField;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIView *logWindow;
@property (nonatomic, strong) NSMutableString *logBuffer;
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

- (NSString *)plistPath { return [self.appPath stringByAppendingPathComponent:@"Info.plist"]; }
- (NSString *)workDir { return @"/var/mobile/Documents/WeChatVerFix"; }
- (NSString *)backupDir { return [[self workDir] stringByAppendingPathComponent:@"backup"]; }
- (NSString *)helperPath { return [[NSBundle mainBundle] pathForResource:@"wvfixd" ofType:nil]; }

- (NSString *)trollStoreHelperPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in [self searchRoots]) {
        for (NSString *d in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *hp = [[root stringByAppendingPathComponent:d]
                            stringByAppendingPathComponent:@"TrollStore.app/trollstorehelper"];
            if ([fm fileExistsAtPath:hp]) return hp;
        }
    }
    NSArray *fixed = @[
        @"/var/jb/Applications/TrollStore.app/trollstorehelper",
        @"/Applications/TrollStore.app/trollstorehelper",
    ];
    for (NSString *p in fixed) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
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

- (NSString *)readVersion { return [self readPlistDict][@"CFBundleShortVersionString"]; }
- (NSString *)readWeChatBundleVersion { return [self readPlistDict][@"WeChatBundleVersion"]; }

- (NSArray<NSString *> *)versionKeyInventory:(NSDictionary *)dict {
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *keys = [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *k in keys) {
        if (![k isKindOfClass:[NSString class]]) continue;
        if (![k.lowercaseString containsString:@"version"]) continue;
        NSString *skip = shouldSkipVersionKey(k) ? @"  [跳过:最低系统要求]" : @"";
        [lines addObject:[NSString stringWithFormat:@"%@ = %@%@", k, dict[k], skip]];
    }
    return lines;
}

- (NSData *)buildPatchedPlistWithShort:(NSString *)shortVer
                                bundle:(NSString *)bundleVer
                                 error:(NSString **)errOut {
    NSMutableDictionary *dict = [self readPlistDict];
    if (!dict) {
        if (errOut) *errOut = @"读不到或解析不了 Info.plist";
        return nil;
    }

    NSArray *keys = [[dict allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger changed = 0;

    for (NSString *k in keys) {
        if (![k isKindOfClass:[NSString class]]) continue;
        if (![k.lowercaseString containsString:@"version"]) continue;
        if (shouldSkipVersionKey(k)) {
            [self log:@"  · %@ = %@（跳过）", k, dict[k]];
            continue;
        }

        id old = dict[k];
        id newVal = nil;

        if ([k isEqualToString:@"CFBundleShortVersionString"]) {
            newVal = shortVer;
        } else if ([k isEqualToString:@"WeChatBundleVersion"]) {
            newVal = bundleVer;
        } else if (isVersionLikeString(old)) {
            newVal = bumpLastComponent(old);
        } else if ([old isKindOfClass:[NSNumber class]]) {
            newVal = @([old longLongValue] + 1000);
        } else {
            [self log:@"  · %@ = %@（非版本格式，跳过）", k, old];
            continue;
        }

        dict[k] = newVal;
        changed++;
        [self log:@"  · %@ : %@ -> %@", k, old, newVal];
    }

    if (!dict[@"WeChatBundleVersion"]) {
        dict[@"WeChatBundleVersion"] = bundleVer;
        changed++;
        [self log:@"  · WeChatBundleVersion : (新建) -> %@", bundleVer];
    }

    [self log:@"[i] 共改写 %lu 个字段", (unsigned long)changed];

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

#pragma mark - 动作

- (void)setResult:(NSString *)text color:(UIColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.resultLabel.text = text;
        self.resultLabel.textColor = color;
        self.resultBanner.backgroundColor = [color colorWithAlphaComponent:0.12];
        self.resultBanner.layer.borderColor = [color colorWithAlphaComponent:0.35].CGColor;
        [UIView animateWithDuration:0.12 animations:^{
            self.resultBanner.alpha = 1.0;
        }];
    });
}

- (void)killWeChat {
    NSString *helper = [self helperPath];
    if (!helper.length) {
        [self log:@"[!] 没有 wvfixd，无法结束微信进程"];
        return;
    }
    int err = 0;
    int rc = spawnRootFull(helper, @[@"--kill", @"WeChat"],
                           WVF_PERSONA_FLAGS_OVERRIDE, nil, &err);
    [self log:@"[i] 结束微信进程：rc=%d spawnErr=%d", rc, err];
}

- (void)onPatch {
    if (!self.appPath) {
        [self setResult:@"没找到微信" color:CLR_RED];
        return;
    }
    NSString *sVer = [self.shortVerField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    NSString *bVer = [self.bundleVerField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    if (sVer.length < 3 || bVer.length < 3) {
        [self log:@"[x] 版本号不合法：%@ / %@", sVer, bVer];
        [self setResult:@"版本号格式不对，请检查两个输入框" color:CLR_RED];
        return;
    }

    self.view.userInteractionEnabled = NO;
    [self setResult:@"正在改写…" color:CLR_ORANGE];
    [self log:@"---- 开始改写 ----"];
    [self log:@"[i] 显示版本 -> %@ | 上报版本 -> %@", sVer, bVer];
    if (self.currentBundleVer.length) {
        if (versionAtLeast(bVer, self.currentBundleVer)) {
            [self log:@"[i] 上报版本 %@ >= 当前 %@，方向正确", bVer, self.currentBundleVer];
        } else {
            [self log:@"[!] 上报版本 %@ 比当前 %@ 小，服务端可能仍判旧", bVer, self.currentBundleVer];
        }
    }

    dispatch_async(self.workQueue, ^{
        NSString *bkName = nil;
        if ([self backupNow:&bkName]) {
            [self log:@"[+] 备份：%@", bkName];
        } else {
            [self log:@"[!] 备份失败：%@", bkName ?: @"未知"];
        }

        NSString *err = nil;
        if ([self writeShort:sVer bundle:bVer error:&err]) {
            NSString *rs = [self readVersion];
            NSString *rb = [self readWeChatBundleVersion];
            self.currentShortVer = rs;
            self.currentBundleVer = rb;
            [self log:@"[+] 写入成功，回读：显示 %@ / 上报 %@", rs ?: @"?", rb ?: @"?"];
            [self killWeChat];
            [self log:@"[i] 已生效。若桌面图标点不动，点「重建缓存」"];
            [self setResult:[NSString stringWithFormat:@"✓ 改写成功 · 显示 %@ · 上报 %@",
                             rs ?: @"?", rb ?: @"?"] color:CLR_GREEN];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = [NSString stringWithFormat:@"显示 %@ · 上报 %@",
                                         rs ?: @"?", rb ?: @"?"];
            });
        } else {
            [self log:@"[x] 写入失败：%@", err ?: @"未知"];
            [self setResult:@"✗ 写入失败，点右上角「日志」查看原因" color:CLR_RED];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.view.userInteractionEnabled = YES;
        });
    });
}

- (void)onRestore {
    NSArray *bs = [self backups];
    if (bs.count == 0) {
        [self log:@"[x] 没有备份可还原"];
        [self setResult:@"没有可用的备份" color:CLR_RED];
        return;
    }
    NSString *first = bs.firstObject;
    self.view.userInteractionEnabled = NO;
    [self setResult:@"正在还原…" color:CLR_ORANGE];
    [self log:@"[i] 还原：%@", first];
    dispatch_async(self.workQueue, ^{
        if ([self restoreBackup:first]) {
            NSString *rs = [self readVersion];
            NSString *rb = [self readWeChatBundleVersion];
            self.currentShortVer = rs;
            self.currentBundleVer = rb;
            [self log:@"[+] 已还原，当前：显示 %@ / 上报 %@", rs ?: @"?", rb ?: @"?"];
            [self log:@"[i] 已登录的微信不受影响；还原后请勿重启微信"];
            [self setResult:[NSString stringWithFormat:@"✓ 已还原 · 显示 %@ · 登录状态不受影响",
                             rs ?: @"?"] color:CLR_GREEN];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = [NSString stringWithFormat:@"显示 %@ · 上报 %@",
                                         rs ?: @"?", rb ?: @"?"];
            });
        } else {
            [self log:@"[x] 还原失败"];
            [self setResult:@"✗ 还原失败，点右上角「日志」查看原因" color:CLR_RED];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.view.userInteractionEnabled = YES;
        });
    });
}

- (void)onRebuildIconCache {
    self.view.userInteractionEnabled = NO;
    [self setResult:@"正在重建图标缓存，5 秒后黑屏…" color:CLR_ORANGE];
    [self log:@"[i] 即将重建图标缓存，桌面会黑屏一下并自动回来"];
    dispatch_async(self.workQueue, ^{
        for (int i = 5; i >= 1; i--) {
            [self log:@"[i] 倒计时 %d 秒…", i];
            [self setResult:[NSString stringWithFormat:@"即将黑屏，倒计时 %d 秒…", i]
                      color:CLR_ORANGE];
            sleep(1);
        }

        NSString *h = [self trollStoreHelperPath];
        if (!h) {
            [self log:@"[!] 没找到 trollstorehelper"];
            [self setResult:@"✗ 没找到 trollstorehelper，请在 TrollStore 里手动重建" color:CLR_RED];
        } else {
            [self log:@"[i] 执行 refresh-all（删 IconsCache → 重建 LS 数据库 → 重新登记）"];
            int err = 0;
            int rc = spawnRootFull(h, @[@"refresh-all"], WVF_PERSONA_FLAGS_OVERRIDE, nil, &err);
            [self log:@"[i] refresh-all：rc=%d spawnErr=%d", rc, err];
            if (rc == 0) {
                [self setResult:@"✓ 重建完成 · 黑屏后从后台进入微信登录" color:CLR_GREEN];
            } else {
                [self setResult:@"✗ 重建失败，点右上角「日志」查看原因" color:CLR_RED];
            }
        }
        [self log:@"[i] 黑屏结束后，从后台进入微信登录即可"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.view.userInteractionEnabled = YES;
        });
    });
}

#pragma mark - 日志

- (void)log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    if (!self.logBuffer) self.logBuffer = [NSMutableString string];
    [self.logBuffer appendFormat:@"%@\n", line];

    NSString *dir = [self workDir];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    FILE *fp = fopen([[dir stringByAppendingPathComponent:@"last.log"] UTF8String], "a");
    if (fp) {
        fprintf(fp, "%s\n", line.UTF8String);
        fclose(fp);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UITextView *tv = self.logView;
        if (!tv) return;
        tv.text = self.logBuffer;
        if (tv.text.length > 0) {
            [tv scrollRangeToVisible:NSMakeRange(tv.text.length - 1, 1)];
        }
    });
}

- (void)showLogWindow {
    if (self.logWindow) return;
    UIWindow *win = self.view.window ?: [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    UIView *dim = [[UIView alloc] initWithFrame:win.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    dim.alpha = 0.0;
    self.logWindow = dim;

    CGFloat cw = win.bounds.size.width - 40;
    CGFloat ch = win.bounds.size.height * 0.64;
    UIView *card = [[UIView alloc] initWithFrame:
                    CGRectMake(20, (win.bounds.size.height - ch) / 2, cw, ch)];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 18;
    card.clipsToBounds = YES;
    [dim addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 14, cw - 90, 22)];
    title.text = @"运行日志";
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textColor = CLR_TEXT;
    [card addSubview:title];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(18, 34, cw - 90, 16)];
    hint.text = @"长按可复制";
    hint.font = [UIFont systemFontOfSize:10];
    hint.textColor = CLR_SUB;
    [card addSubview:hint];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(cw - 74, 12, 62, 32);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:CLR_GREEN forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [close addTarget:self action:@selector(hideLogWindow) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(12, 56, cw - 24, ch - 68)];
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    tv.textColor = [UIColor colorWithRed:0.22 green:0.26 blue:0.30 alpha:1.0];
    tv.backgroundColor = [UIColor colorWithRed:0.97 green:0.98 blue:0.99 alpha:1.0];
    tv.layer.cornerRadius = 12;
    tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    tv.text = self.logBuffer ?: @"";
    [card addSubview:tv];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(copyLog)];
    [tv addGestureRecognizer:lp];

    [win addSubview:dim];
    [UIView animateWithDuration:0.2 animations:^{ dim.alpha = 1.0; }];
}

- (void)hideLogWindow {
    UIView *v = self.logWindow;
    if (!v) return;
    self.logWindow = nil;
    [UIView animateWithDuration:0.16 animations:^{ v.alpha = 0.0; }
                     completion:^(BOOL finished) { [v removeFromSuperview]; }];
}

- (void)copyLog {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = self.logBuffer ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"已复制日志" message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                           style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - UI

- (UIButton *)smallButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)tinyLabel:(NSString *)text frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    l.textColor = CLR_SUB;
    l.text = text;
    return l;
}

- (UITextField *)compactField:(CGRect)frame placeholder:(NSString *)ph {
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.placeholder = ph;
    f.textAlignment = NSTextAlignmentCenter;
    f.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    f.textColor = CLR_TEXT;
    f.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    f.backgroundColor = [UIColor colorWithRed:0.95 green:0.97 blue:0.98 alpha:1.0];
    f.layer.cornerRadius = 9;
    f.layer.borderWidth = 1.0;
    f.layer.borderColor = [UIColor colorWithRed:0.88 green:0.91 blue:0.93 alpha:1.0].CGColor;
    return f;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.workQueue) {
        self.workQueue = dispatch_queue_create("com.local.wvfix.patch", DISPATCH_QUEUE_SERIAL);
    }
    if (!self.logBuffer) self.logBuffer = [NSMutableString string];

    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"微版助手";

    self.bgLayer = [CAGradientLayer layer];
    self.bgLayer.colors = @[
        (id)[UIColor colorWithRed:0.96 green:0.98 blue:0.97 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.89 green:0.96 blue:0.92 alpha:1.0].CGColor,
    ];
    self.bgLayer.startPoint = CGPointMake(0, 0);
    self.bgLayer.endPoint = CGPointMake(1, 1);
    [self.view.layer insertSublayer:self.bgLayer atIndex:0];

    UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [logBtn setTitle:@"日志" forState:UIControlStateNormal];
    [logBtn setTitleColor:CLR_GREEN forState:UIControlStateNormal];
    logBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    logBtn.frame = CGRectMake(0, 0, 44, 32);
    [logBtn addTarget:self action:@selector(showLogWindow) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:logBtn];

    CGFloat w = self.view.bounds.size.width;
    CGFloat cw = w - 32;
    CGFloat inner = cw - 32;

    CGFloat iw = cw - 32;

    // 先算两块卡片的内容高度，取较大者作为统一高度（上下等高）
    CGFloat topPad = 14, titleH = 20, capH = 14, fieldH = 40, btnH = 42, bannerH = 38;
    CGFloat g1 = 8, g2 = 2, g3 = 10, g4 = 10, botPad = 10;

    CGFloat tTop = 10, tHead = 18, tRowH = 28, tRowGap = 5, tNoteH = 44, tBot = 10;

    CGFloat cardNatural = topPad + titleH + g1 + capH + g2 + fieldH + g3
                        + btnH + g4 + bannerH + botPad;
    CGFloat tutNatural  = tTop + tHead + 6 + (4 * tRowH + 3 * tRowGap) + 8 + tNoteH + tBot;
    CGFloat boxH = cardNatural > tutNatural ? cardNatural : tutNatural;

    CGFloat extraCard = boxH - cardNatural;
    CGFloat extraTut  = boxH - tutNatural;

    g1 += extraCard / 4.0;
    g2 += extraCard / 4.0;
    g3 += extraCard / 4.0;
    g4 += extraCard / 4.0;

    CGFloat tHeadGap = 6 + extraTut / 2.0;
    CGFloat tRowGapF  = tRowGap + extraTut / 6.0;

    // ---- 顶部卡片 ----
    CGFloat topMargin = 28;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, topMargin, cw, boxH)];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 16;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.08;
    card.layer.shadowRadius = 12;
    card.layer.shadowOffset = CGSizeMake(0, 5);
    [self.view addSubview:card];
    self.cardView = card;

    CGFloat by = topPad;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, by, inner, titleH)];
    t.text = @"微信版本伪装";
    t.font = [UIFont boldSystemFontOfSize:14];
    t.textColor = CLR_TEXT;
    [card addSubview:t];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, by, inner, titleH)];
    self.statusLabel.text = @"扫描中…";
    self.statusLabel.textAlignment = NSTextAlignmentRight;
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.textColor = CLR_SUB;
    [card addSubview:self.statusLabel];
    by += titleH + g1;

    CGFloat half = (inner - 10) / 2.0;
    [card addSubview:[self tinyLabel:@"显示版本" frame:CGRectMake(16, by, half, capH)]];
    [card addSubview:[self tinyLabel:@"上报版本（登录看这个）"
                               frame:CGRectMake(16 + half + 10, by, half, capH)]];
    by += capH + g2;

    self.shortVerField = [self compactField:CGRectMake(16, by, half, fieldH) placeholder:@"8.0.90"];
    self.shortVerField.text = kDefaultShortVer;
    [card addSubview:self.shortVerField];

    self.bundleVerField = [self compactField:CGRectMake(16 + half + 10, by, half, fieldH)
                                placeholder:@"8.0.99.99"];
    self.bundleVerField.text = kDefaultBundleVer;
    [card addSubview:self.bundleVerField];
    by += fieldH + g3;

    CGFloat bw = (inner - 16) / 3.0;
    UIButton *b1 = [self smallButton:@"改写版本" color:CLR_GREEN action:@selector(onPatch)];
    b1.frame = CGRectMake(16, by, bw, btnH);
    [card addSubview:b1];

    UIButton *b2 = [self smallButton:@"重建缓存" color:CLR_ORANGE action:@selector(onRebuildIconCache)];
    b2.frame = CGRectMake(16 + bw + 8, by, bw, btnH);
    [card addSubview:b2];

    UIButton *b3 = [self smallButton:@"还原版本" color:CLR_GRAY action:@selector(onRestore)];
    b3.frame = CGRectMake(16 + (bw + 8) * 2, by, bw, btnH);
    [card addSubview:b3];
    by += btnH + g4;

    self.resultBanner = [[UIView alloc] initWithFrame:CGRectMake(16, by, inner, bannerH)];
    self.resultBanner.backgroundColor = [CLR_GRAY colorWithAlphaComponent:0.12];
    self.resultBanner.layer.cornerRadius = 9;
    self.resultBanner.layer.borderWidth = 1.0;
    self.resultBanner.layer.borderColor = [CLR_GRAY colorWithAlphaComponent:0.35].CGColor;
    self.resultBanner.alpha = 1.0;
    [card addSubview:self.resultBanner];

    self.resultLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, inner - 20, bannerH)];
    self.resultLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    self.resultLabel.textColor = CLR_SUB;
    self.resultLabel.textAlignment = NSTextAlignmentCenter;
    self.resultLabel.numberOfLines = 2;
    [self.resultBanner addSubview:self.resultLabel];
    self.resultLabel.text = @"等待操作";

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLogWindow)];
    [self.resultBanner addGestureRecognizer:tap];

    // ---- 底部教程（与上框等高） ----
    CGFloat tutY = self.view.bounds.size.height - 16 - boxH;
    UIScrollView *tut = [[UIScrollView alloc] initWithFrame:CGRectMake(16, tutY, cw, boxH)];
    tut.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    tut.layer.cornerRadius = 16;
    tut.showsVerticalScrollIndicator = NO;
    [self.view addSubview:tut];

    NSArray *steps = @[
        @[@"1", @"点「改写版本」（绿色）", CLR_GREEN],
        @[@"2", @"点「重建缓存」（橙色），黑屏刷新几秒属正常", CLR_ORANGE],
        @[@"3", @"黑屏结束后，从后台进入微信，正常登录", CLR_BLUE],
        @[@"4", @"确认登录成功后，才点「还原版本」（灰色）", CLR_GRAY],
    ];

    CGFloat cy = tTop;

    UILabel *tTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, cy, iw * 0.55, tHead)];
    tTitle.text = @"使用教程";
    tTitle.font = [UIFont boldSystemFontOfSize:13.5];
    tTitle.textColor = CLR_TEXT;
    [tut addSubview:tTitle];

    UILabel *tSub = [[UILabel alloc] initWithFrame:CGRectMake(16 + iw * 0.55, cy, iw * 0.45, tHead)];
    tSub.text = @"全程保持微信在后台";
    tSub.textAlignment = NSTextAlignmentRight;
    tSub.font = [UIFont systemFontOfSize:10];
    tSub.textColor = CLR_SUB;
    [tut addSubview:tSub];
    cy += tHead + tHeadGap;

    for (NSArray *s in steps) {
        UIView *row = [self tutorialRow:s[0] text:s[1] y:cy width:iw height:tRowH color:s[2]];
        [tut addSubview:row];
        cy += tRowH + tRowGapF;
    }

    UIView *note = [[UIView alloc] initWithFrame:CGRectMake(16, cy, iw, tNoteH)];
    note.backgroundColor = [UIColor colorWithRed:0.98 green:0.96 blue:0.90 alpha:1.0];
    note.layer.cornerRadius = 10;
    [tut addSubview:note];

    UILabel *noteText = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, iw - 20, tNoteH - 12)];
    noteText.text = @"还原只改回版本号，已登录的微信不受影响，且图标恢复正常。"
                    @"微信被系统回收或手动关闭后，重新登录会提示版本过低，届时重做第 1、2 步。";
    noteText.numberOfLines = 0;
    noteText.font = [UIFont systemFontOfSize:10];
    noteText.textColor = [UIColor colorWithRed:0.55 green:0.42 blue:0.10 alpha:1.0];
    [note addSubview:noteText];
    cy += tNoteH + tBot;
    tut.contentSize = CGSizeMake(cw, cy);

    // ---- 中间日志（夹在两框之间，垂直居中） ----
    CGFloat logY = card.frame.origin.y + card.frame.size.height + 12;
    CGFloat logH = tutY - 12 - logY;

    UIView *logPanel = [[UIView alloc] initWithFrame:CGRectMake(16, logY, cw, logH)];
    logPanel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    logPanel.layer.cornerRadius = 16;
    [self.view addSubview:logPanel];

    UILabel *logTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, inner * 0.5, 18)];
    logTitle.text = @"运行日志";
    logTitle.font = [UIFont boldSystemFontOfSize:13];
    logTitle.textColor = CLR_TEXT;
    [logPanel addSubview:logTitle];

    UILabel *logHint = [[UILabel alloc] initWithFrame:CGRectMake(16 + inner * 0.5, 10, inner * 0.5, 18)];
    logHint.text = @"点此查看全部 ›";
    logHint.textAlignment = NSTextAlignmentRight;
    logHint.font = [UIFont systemFontOfSize:10];
    logHint.textColor = CLR_GREEN;
    [logPanel addSubview:logHint];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(10, 32, cw - 20, logH - 42)];
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:9.5] ?: [UIFont systemFontOfSize:9.5];
    tv.textColor = [UIColor colorWithRed:0.28 green:0.32 blue:0.36 alpha:1.0];
    tv.backgroundColor = [UIColor colorWithRed:0.96 green:0.98 blue:0.97 alpha:1.0];
    tv.layer.cornerRadius = 10;
    tv.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    tv.text = self.logBuffer ?: @"";
    [logPanel addSubview:tv];
    self.logView = tv;

    UITapGestureRecognizer *logTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showLogWindow)];
    [logPanel addGestureRecognizer:logTap];


    [self refresh];
}

- (UIView *)tutorialRow:(NSString *)index text:(NSString *)text
                       y:(CGFloat)y width:(CGFloat)w height:(CGFloat)h color:(UIColor *)color {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(16, y, w, h)];

    UILabel *dot = [[UILabel alloc] initWithFrame:CGRectMake(0, (h - 18) / 2.0, 18, 18)];
    dot.text = index;
    dot.textAlignment = NSTextAlignmentCenter;
    dot.font = [UIFont boldSystemFontOfSize:10];
    dot.textColor = [UIColor whiteColor];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 9;
    dot.clipsToBounds = YES;
    [row addSubview:dot];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(26, 0, w - 26, h)];
    l.text = text;
    l.numberOfLines = 1;
    l.font = [UIFont systemFontOfSize:11.5];
    l.textColor = CLR_TEXT;
    [row addSubview:l];

    return row;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.bgLayer.frame = self.view.bounds;
}

- (void)refresh {
    self.appPath = [self findWeChatApp];
    if (!self.appPath) {
        self.statusLabel.text = @"没找到微信";
        [self log:@"[x] 扫描失败：没有 WeChat.app"];
        [self setResult:@"没找到微信，请确认已安装" color:CLR_RED];
        return;
    }
    self.currentShortVer = [self readVersion];
    self.currentBundleVer = [self readWeChatBundleVersion];
    if (self.currentBundleVer.length) {
        NSString *suggested = maxComponentwise(self.currentBundleVer, @"8.0.99.99");
        self.bundleVerField.text = suggested;
        [self log:@"[i] 当前上报版本 %@，建议 %@", self.currentBundleVer, suggested];
    }
    self.statusLabel.text = [NSString stringWithFormat:@"当前 显示 %@ · 上报 %@",
                             self.currentShortVer ?: @"?",
                             self.currentBundleVer ?: @"(无)"];

    [self log:@"[+] 微信：%@", self.appPath];
    [self log:@"[i] 属性：%@", [self describeItem:[self plistPath]]];

    NSMutableDictionary *dict = [self readPlistDict];
    NSArray *inv = [self versionKeyInventory:dict];
    [self log:@"[i] 版本类字段 %lu 个：", (unsigned long)inv.count];
    for (NSString *line in inv) {
        [self log:@"    %@", line];
    }

    resolvePersona();
    [self log:@"[i] persona：%@", g_personaAvailable ? @"可用" : @"缺失"];
    [self log:@"[i] trollstorehelper：%@", [self trollStoreHelperPath] ? @"已找到" : @"未找到"];

    [[NSFileManager defaultManager] createDirectoryAtPath:[self workDir]
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([self helperPath]) [self probeRoot];
}

@end
