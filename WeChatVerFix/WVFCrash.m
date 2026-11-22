//
//  WVFCrash.m
//  崩溃采集：未捕获异常 + 信号（SIGSEGV/SIGABRT…）都写进 crash.log
//
//  信号处理器里只能用 C 调用（异步信号安全），所以路径全部用 C 字符串。
//

#import "WVFCrash.h"
#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <sys/stat.h>

static const char *kCrashDirC  = "/var/mobile/Documents/WeChatVerFix";
static const char *kCrashFileC = "/var/mobile/Documents/WeChatVerFix/crash.log";

void WVFUncaughtExceptionHandler(NSException *e);

static void wvfEnsureDir(void)
{
    mkdir(kCrashDirC, 0755);
}

static void wvfAppend(const char *s)
{
    if (!s) return;
    int fd = open(kCrashFileC, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, s, strlen(s));
    close(fd);
}

static void WVFSignalHandler(int sig)
{
    char head[128];
    snprintf(head, sizeof(head), "\n===== SIGNAL %d =====\n", sig);
    wvfAppend(head);

    void *frames[48];
    int n = backtrace(frames, 48);
    int fd = open(kCrashFileC, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    wvfAppend("\n");

    signal(sig, SIG_DFL);
    raise(sig);
}

void WVFUncaughtExceptionHandler(NSException *e)
{
    wvfEnsureDir();

    NSMutableString *s = [NSMutableString string];
    [s appendString:@"\n===== EXCEPTION =====\n"];
    [s appendFormat:@"name  : %@\n", e.name ?: @"?"];
    [s appendFormat:@"reason: %@\n", e.reason ?: @"?"];
    [s appendString:@"callStack:\n"];
    for (NSString *line in e.callStackSymbols) {
        [s appendFormat:@"  %@\n", line];
    }
    [s appendString:@"===== END =====\n"];

    wvfAppend(s.UTF8String);
}

void WVFCrashInstall(void)
{
    wvfEnsureDir();
    NSSetUncaughtExceptionHandler(&WVFUncaughtExceptionHandler);

    signal(SIGSEGV, WVFSignalHandler);
    signal(SIGABRT, WVFSignalHandler);
    signal(SIGBUS,  WVFSignalHandler);
    signal(SIGILL,  WVFSignalHandler);
    signal(SIGFPE,  WVFSignalHandler);
    signal(SIGTRAP, WVFSignalHandler);
}

NSString *WVFCrashReadLast(void)
{
    NSString *path = [NSString stringWithUTF8String:kCrashFileC];
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s.length) return nil;

    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    if (lines.count > 40) {
        lines = [lines subarrayWithRange:NSMakeRange(lines.count - 40, 40)];
    }
    return [lines componentsJoinedByString:@"\n"];
}

void WVFCrashClear(void)
{
    NSString *path = [NSString stringWithUTF8String:kCrashFileC];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}
