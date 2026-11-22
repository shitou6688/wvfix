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

static void wvfRefreshOnly(void)
{
    // 删缓存 + 重建 LaunchServices 数据库 + uicache，但不动 backboardd
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *caches = @[
        @"/var/mobile/Library/Caches/com.apple.IconsCache",
        @"/var/mobile/Library/Caches/com.apple.springboard",
    ];
    for (NSString *p in caches) {
        [fm removeItemAtPath:p error:NULL];
    }

    @try {
        wvfCallRebuildLS();
    } @catch (NSException *e) {
        // 忽略
    }

    NSArray *uicaches = @[@"/var/jb/usr/bin/uicache", @"/usr/bin/uicache"];
    for (NSString *c in uicaches) {
        if (wvfSpawn(c, @[@"-a"]) >= 0) break;
    }
}

static void wvfRebuildIconCache(void)
{
    wvfRefreshOnly();
    // 强制重启桌面：屏幕黑一下，但会带走后台 App
    wvfKillByName("backboardd");
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
                    fileExistsAtPath:@"/var/mobile/Library/Caches/com.apple.IconsCache"];
        return has ? @"OK 已刷新（缓存重算中）" : @"OK 已刷新（未重启桌面）";
    }
    if ([line isEqualToString:@"REBUILD"]) {
        BOOL hadCache = [[NSFileManager defaultManager]
                         fileExistsAtPath:@"/var/mobile/Library/Caches/com.apple.IconsCache"];
        wvfRebuildIconCache();
        // 等系统重建：IconsCache 会重新生成
        sleep(4);
        BOOL hasCache = [[NSFileManager defaultManager]
                         fileExistsAtPath:@"/var/mobile/Library/Caches/com.apple.IconsCache"];
        if (hasCache) return @"OK 缓存已重建";
        if (hadCache) return @"OK 仅重启桌面";
        return @"OK 已清缓存，桌面重启中";
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
