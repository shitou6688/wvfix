//
//  wvfdaemon — 微版助手的 root 守护进程
//
//  由 launchd 以 root 常驻，监听 /var/mobile/Documents/WeChatVerFix/wvf.sock。
//  App（mobile 身份）通过 unix socket 请求它做需要 root 的事：
//    PING                  → OK
//    UID                   → UID 0
//    WRITE <src> <dst>     → 用 src 覆盖 dst
//    KILL <进程名>          → SIGKILL
//    UICACHE               → 刷新图标缓存
//
//  这样在 rootful（checkra1n/unc0ver）和 rootless（Dopamine）下都可用，
//  不依赖 setuid，也不依赖 TrollStore 的 persona 通道。
//

#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <spawn.h>
#include <dlfcn.h>

extern char **environ;

static id wvfLSWorkspace(void);
static int wvfPurgeMissingApps(void);
static BOOL wvfRebuildLSDatabase(void);
static void wvfCleanRestrictions(void);
static BOOL wvfShouldRegisterAsUser(void);
static void wvfRefreshAppRegistrations(void);
static BOOL wvfLSRegisterURL(NSString *path);


static const char *kSockDir  = "/var/mobile/Documents/WeChatVerFix";
static const char *kSockPath = "/var/mobile/Documents/WeChatVerFix/wvf.sock";

static int wvfKillByName(const char *name)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return -2;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return -3; }

    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t self = getpid();
    int killed = 0;
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0 || pid == self) continue;
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            if (kill(pid, SIGKILL) == 0) killed++;
        }
    }
    free(procs);
    return killed;
}

static int wvfCopy(const char *src, const char *dst)
{
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_TRUNC);
    if (out < 0) { close(in); return -2; }

    char buf[8192];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w <= 0) { close(in); close(out); return -3; }
            off += w;
        }
    }
    fsync(out);
    close(in);
    close(out);
    return n < 0 ? -4 : 0;
}

static int wvfSpawn(NSString *path, NSArray<NSString *> *args)
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return -1;
    NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
    [argv addObjectsFromArray:args];
    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup([argv[i] UTF8String]);
    cargv[argv.count] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, cargv[0], NULL, NULL, cargv, environ);
    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);
    if (rc != 0) return -2;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -3;
}

static NSString *wvfHTTPGetSync(NSString *urlStr, NSError **outErr)
{
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (outErr) *outErr = [NSError errorWithDomain:@"wvf" code:1 userInfo:nil];
        return nil;
    }

    __block NSData *result = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        result = data;
        error = err;
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_SEC)));
    if (outErr) *outErr = error;
    return result ? [[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding] : nil;
}

#pragma mark - 图标缓存重建（不依赖 TrollStore）

static void wvfCallRebuildLS(void)
{
    // LSApplicationWorkspace 的私有方法：
    //   -_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:
    void *handle = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    }
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    }
    if (!handle) return;

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return;
    id ws = [cls performSelector:@selector(defaultWorkspace)];
    if (!ws) return;

    SEL sel = NSSelectorFromString(@"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
    if (![ws respondsToSelector:sel]) return;

    NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ws];
    [inv setSelector:sel];
    BOOL yes = YES;
    [inv setArgument:&yes atIndex:2];
    [inv setArgument:&yes atIndex:3];
    [inv setArgument:&yes atIndex:4];
    [inv invoke];
}

static void wvfKillByNameSignal(const char *name, int sig)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return; }

    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            kill(pid, sig);
        }
    }
    free(procs);
}

// 让 SpringBoard 重新加载桌面图标（不重启桌面）
static void wvfReloadIconsViaSpringBoard(void)
{
    void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!sb) return;
    Class cls = NSClassFromString(@"SBSHomeScreenService");
    if (!cls) return;
    @try {
        id svc = [[cls alloc] init];
        SEL sel = NSSelectorFromString(@"reloadIcons");
        if ([svc respondsToSelector:sel]) {
            [svc performSelector:sel];
        }
    } @catch (NSException *e) {
        // 忽略
    }
}

// 与 TrollStore 的 refresh-all 完全一致的清理：删图标缓存 + 重建 LS 数据库
static void wvfCoreRefresh(void)
{
    // TrollStore 用的真实路径
    NSString *iconsCache = @"/var/containers/Shared/SystemGroup/"
                            "systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache";
    [[NSFileManager defaultManager] removeItemAtPath:iconsCache error:NULL];

    // 兼容旧路径（有些系统版本这里也有一份）
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/com.apple.IconsCache"
                                               error:NULL];

    // 重建 LaunchServices 应用数据库（TrollStore 同款私有方法）
    BOOL lsOK = wvfRebuildLSDatabase();
    NSLog(@"[wvfix] LS rebuild = %d", lsOK);

    // 若有 uicache 再补一遍
    NSArray *uicaches = @[@"/var/jb/usr/bin/uicache", @"/usr/bin/uicache"];
    for (NSString *c in uicaches) {
        if (wvfSpawn(c, @[@"-a"]) >= 0) break;
    }
}

// 轻量：只刷新状态，不重启桌面、不杀后台
static void wvfRefreshOnly(void)
{
    wvfCoreRefresh();
    wvfReloadIconsViaSpringBoard();
}

// 完整：与 TrollStore refresh-all 等价（会重启桌面）
static void wvfRebuildIconCache(void)
{
    // 与 TrollStore refresh-all 完全一致的顺序
    wvfCleanRestrictions();
    int purged = wvfPurgeMissingApps();
    NSLog(@"[wvfix] purge missing apps = %d", purged);
    wvfCoreRefresh();
    if (!wvfShouldRegisterAsUser()) {
        wvfRefreshAppRegistrations();
    }
    // TrollStore 用 SIGTERM（softly=YES），不是 SIGKILL
    wvfKillByNameSignal("backboardd", SIGTERM);
}

#pragma mark - 从 TrollStore RootHelper 移植

// 可删除的系统 App 判定（TrollStore 同款）
static BOOL wvfIsRemovableSystemApp(NSString *appId)
{
    return [[NSFileManager defaultManager]
            fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appId]];
}

// 清理 ClientTruth.plist 里"已移除系统 App"的残留记录
static void wvfCleanRestrictions(void)
{
    NSString *clientTruthPath = @"/private/var/containers/Shared/SystemGroup/"
                                 "systemgroup.com.apple.configurationprofiles/Library/"
                                 "ConfigurationProfiles/ClientTruth.plist";
    NSURL *url = [NSURL fileURLWithPath:clientTruthPath];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfURL:url];
    if (!dict) return;

    NSArray *valuesArr = nil;
    NSDictionary *lsdAppRemoval = dict[@"com.apple.lsd.appremoval"];
    if ([lsdAppRemoval isKindOfClass:NSDictionary.class]) {
        NSDictionary *cr = lsdAppRemoval[@"clientRestrictions"];
        if ([cr isKindOfClass:NSDictionary.class]) {
            NSDictionary *uni = cr[@"union"];
            if ([uni isKindOfClass:NSDictionary.class]) {
                NSDictionary *removed = uni[@"removedSystemAppBundleIDs"];
                if ([removed isKindOfClass:NSDictionary.class]) {
                    valuesArr = removed[@"values"];
                }
            }
        }
    }
    if (!valuesArr.count) return;

    NSMutableArray *arr = valuesArr.mutableCopy;
    __block BOOL changed = NO;
    [arr enumerateObjectsWithOptions:NSEnumerationReverse
                          usingBlock:^(NSString *value, NSUInteger idx, BOOL *stop) {
        if (![value isKindOfClass:NSString.class] || !wvfIsRemovableSystemApp(value)) {
            [arr removeObjectAtIndex:idx];
            changed = YES;
        }
    }];
    if (!changed) return;

    NSMutableDictionary *mut = (__bridge_transfer NSMutableDictionary *)
        CFPropertyListCreateDeepCopy(kCFAllocatorDefault,
                                     (__bridge CFDictionaryRef)dict,
                                     kCFPropertyListMutableContainersAndLeaves);
    mut[@"com.apple.lsd.appremoval"][@"clientRestrictions"][@"union"]
       [@"removedSystemAppBundleIDs"][@"values"] = arr;
    [mut writeToURL:url error:nil];

    // profiled 需要重启才生效（TrollStore 用 SIGKILL）
    wvfKillByNameSignal("profiled", SIGKILL);
}

// 是否应"以用户身份登记"（装了 AppSync 时为真）
static BOOL wvfShouldRegisterAsUser(void)
{
    NSArray *cands = @[
        @"/var/jb/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-FrontBoard.dylib",
        @"/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-FrontBoard.dylib",
    ];
    for (NSString *p in cands) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return YES;
    }
    return NO;
}

// 重新登记所有已安装 App（对应 TrollStore 的 refreshAppRegistrations）
static void wvfRefreshAppRegistrations(void)
{
    NSMutableArray *roots = [NSMutableArray arrayWithObjects:
        @"/var/containers/Bundle/Application",
        @"/Applications",
        @"/var/jb/Applications", nil];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSArray *subs = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *sub in subs) {
            NSString *dir = [root stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;

            if ([sub hasSuffix:@".app"]) {
                wvfLSRegisterURL(dir);
                continue;
            }
            // /var/containers/Bundle/Application/<uuid>/App.app
            NSArray *inner = [fm contentsOfDirectoryAtPath:dir error:NULL];
            for (NSString *x in inner) {
                if (![x hasSuffix:@".app"]) continue;
                wvfLSRegisterURL([dir stringByAppendingPathComponent:x]);
            }
        }
    }
}

#pragma mark - LaunchServices 工作区（关键：类在 CoreServicesStore 里）

static id wvfLSWorkspace(void)
{
    static id cached = nil;
    static BOOL tried = NO;
    if (cached) return cached;
    if (tried) return nil;
    tried = YES;

    NSArray *paths = @[
        @"/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore",
        @"/System/Library/Frameworks/CoreServices.framework/CoreServices",
        @"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
    ];
    for (NSString *p in paths) {
        dlopen(p.fileSystemRepresentation, RTLD_LAZY);
    }

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return nil;

    @try {
        cached = [cls performSelector:@selector(defaultWorkspace)];
    } @catch (NSException *e) {
        cached = nil;
    }
    return cached;
}

// 注销所有"指向已不存在 App"的记录（灰图标/残留图标就是这么清的）
static int wvfPurgeMissingApps(void)
{
    id ws = wvfLSWorkspace();
    if (!ws) return -1;

    int removed = 0;
    @try {
        NSArray *all = nil;
        SEL selAll = NSSelectorFromString(@"allApplications");
        if ([ws respondsToSelector:selAll]) {
            all = [ws performSelector:selAll];
        }
        for (id proxy in all) {
            NSURL *url = [proxy valueForKey:@"bundleURL"];
            if (!url) continue;
            NSString *path = url.path;
            if (!path.length) continue;
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) continue;

            SEL unreg = NSSelectorFromString(@"unregisterApplication:");
            if ([ws respondsToSelector:unreg]) {
                [ws performSelector:unreg withObject:url];
                removed++;
            }
        }
    } @catch (NSException *e) {
    }
    return removed;
}

// 调用私有重建方法；返回是否成功
static BOOL wvfRebuildLSDatabase(void)
{
    id ws = wvfLSWorkspace();
    if (!ws) return NO;

    SEL sel = NSSelectorFromString(@"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
    if (![ws respondsToSelector:sel]) return NO;

    @try {
        NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
        if (!sig) return NO;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:ws];
        [inv setSelector:sel];
        BOOL yes = YES;
        [inv setArgument:&yes atIndex:2];
        [inv setArgument:&yes atIndex:3];
        [inv setArgument:&yes atIndex:4];
        [inv invoke];
    } @catch (NSException *e) {
        return NO;
    }
    return YES;
}

// 让系统重新登记某个 App bundle（刷新 lsd 里存的版本等信息）
static BOOL wvfLSRegisterURL(NSString *path)
{
    wvfLSWorkspace();   // 确保 CoreServicesStore 已加载

    typedef Boolean (*RegFn)(CFURLRef, Boolean);
    RegFn fn = (RegFn)dlsym(RTLD_DEFAULT, "LSRegisterURL");
    if (!fn) return NO;

    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
    return fn(url, true) ? YES : NO;
}

// 读取系统登记里某个 bundle 的显示版本
static NSString *wvfLSVersionOf(NSString *bundleID)
{
    void *h = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    if (!h) return nil;

    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (!cls) return nil;

    @try {
        id proxy = [cls performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
        if (!proxy) return nil;
        id v = [proxy valueForKey:@"shortVersionString"];
        id bv = [proxy valueForKey:@"bundleVersion"];
        if (!v) return nil;
        if (bv) return [NSString stringWithFormat:@"%@|%@", v, bv];
        return [v description];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *wvfHandle(NSString *line)
{
    if ([line hasPrefix:@"HTTPGET "]) {
        NSString *urlStr = [line substringFromIndex:8];
        NSError *err = nil;
        NSString *body = wvfHTTPGetSync(urlStr, &err);
        if (!body) {
            return [NSString stringWithFormat:@"ERR %@", err.localizedDescription ?: @"请求失败"];
        }
        // 单行返回：把换行压成 \\n 转义，避免破坏协议
        NSString *flat = [body stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        return [NSString stringWithFormat:@"OK %@", flat];
    }
    if ([line isEqualToString:@"REBUILDSOFT"]) {
        // 只刷新状态，不动 backboardd，后台 App 保持存活
        wvfRefreshOnly();
        sleep(1);
        BOOL has = [[NSFileManager defaultManager]
                    fileExistsAtPath:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache"];
        return has ? @"OK 已刷新（缓存重算中）" : @"OK 已刷新（未重启桌面）";
    }
    if ([line isEqualToString:@"REBUILD"]) {
        int purgeCount = wvfPurgeMissingApps();
        BOOL hadCache = [[NSFileManager defaultManager]
                         fileExistsAtPath:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache"];
        wvfRebuildIconCache();
        // 等系统重建：IconsCache 会重新生成
        sleep(4);
        BOOL hasCache = [[NSFileManager defaultManager]
                         fileExistsAtPath:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache"];
        NSString *extra = [NSString stringWithFormat:@"（清理残留 %d 项）", purgeCount];
        if (hasCache) return [NSString stringWithFormat:@"OK 缓存已重建%@", extra];
        if (hadCache) return [NSString stringWithFormat:@"OK 仅重启桌面%@", extra];
        return [NSString stringWithFormat:@"OK 已清缓存，桌面重启中%@", extra];
    }
    if ([line hasPrefix:@"LSREGISTER "]) {
        NSString *path = [line substringFromIndex:11];
        BOOL ok = wvfLSRegisterURL(path);
        return ok ? @"OK 已登记" : @"ERR 登记失败";
    }
    if ([line hasPrefix:@"LSVER "]) {
        NSString *bid = [line substringFromIndex:6];
        NSString *v = wvfLSVersionOf(bid);
        return v ? [NSString stringWithFormat:@"OK %@", v] : @"ERR 查不到";
    }
    if ([line hasPrefix:@"UICACHEP "]) {
        NSString *path = [line substringFromIndex:9];
        NSArray *cands = @[@"/var/jb/usr/bin/uicache", @"/usr/bin/uicache"];
        for (NSString *c in cands) {
            if (wvfSpawn(c, @[@"-p", path]) >= 0) {
                return @"OK 已刷新该应用登记";
            }
        }
        return @"ERR 没有 uicache";
    }
    if ([line isEqualToString:@"PING"]) return @"OK";
    if ([line isEqualToString:@"UID"]) {
        return [NSString stringWithFormat:@"UID %d", getuid()];
    }
    if ([line isEqualToString:@"UICACHE"]) {
        NSArray *cands = @[@"/var/jb/usr/bin/uicache", @"/usr/bin/uicache"];
        for (NSString *c in cands) {
            int rc = wvfSpawn(c, @[@"-a"]);
            if (rc >= 0) return @"OK";
        }
        return @"ERR no uicache";
    }
    if ([line hasPrefix:@"KILL "]) {
        NSString *name = [line substringFromIndex:5];
        int n = wvfKillByName([name UTF8String]);
        if (n < 0) return @"ERR kill failed";
        return [NSString stringWithFormat:@"OK %d", n];
    }
    if ([line hasPrefix:@"WRITE "]) {
        NSString *rest = [line substringFromIndex:6];
        NSRange sp = [rest rangeOfString:@" "];
        if (sp.location == NSNotFound) return @"ERR need src dst";
        NSString *src = [rest substringToIndex:sp.location];
        NSString *dst = [rest substringFromIndex:sp.location + 1];
        int rc = wvfCopy(src.UTF8String, dst.UTF8String);
        if (rc != 0) {
            return [NSString stringWithFormat:@"ERR copy %d (%s)", rc, strerror(errno)];
        }
        return @"OK";
    }
    return @"ERR unknown";
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        mkdir(kSockDir, 0755);
        unlink(kSockPath);

        int srv = socket(AF_UNIX, SOCK_STREAM, 0);
        if (srv < 0) return 1;

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, kSockPath, sizeof(addr.sun_path) - 1);

        if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
            return 2;
        }
        chmod(kSockPath, 0666);
        listen(srv, 8);

        for (;;) {
            int c = accept(srv, NULL, NULL);
            if (c < 0) continue;

            char buf[2048] = {0};
            ssize_t n = read(c, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = 0;
                char *nl = strchr(buf, '\n');
                if (nl) *nl = 0;

                NSString *line = [NSString stringWithUTF8String:buf] ?: @"";
                NSString *reply = wvfHandle(line);
                NSString *out = [reply stringByAppendingString:@"\n"];
                write(c, out.UTF8String, strlen(out.UTF8String));
            }
            close(c);
        }
    }
    return 0;
}
