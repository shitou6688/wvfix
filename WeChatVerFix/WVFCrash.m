//
//  WVFCrash.m
//  崩溃采集：未捕获异常 + 信号（SIGSEGV/SIGABRT…）都写进 crash.log
//
//  注意：信号处理器里只能用异步信号安全的调用，这里只用 open/write/close。
//

#import "WVFCrash.h"
#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/sysctl.h>

static NSString *const kCrashDir  = @"/var/mobile/Documents/WeChatVerFix";
static NSString *const kCrashFile = @"/var/mobile/Documents/WeChatVerFix/crash.log";

static NSString *WVFCrashPath(void)
{
    return kCrashFile;
}

static void WVFCrashEnsureDir(void)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:kCrashDir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
}

// ---- 异步信号安全地写文件 ----
static void wvfWriteRaw(const char *s)
{
    if (!s) return;
    int fd = open(kCrashFile, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    write(fd, s, strlen(s));
    close(fd);
}

static void WVFSignalHandler(int sig)
{
    char head[160];
    snprintf(head, sizeof(head), "\n===== SIGNAL %d ====\n", sig);
    wvfWriteRaw(head);

    void *frames[48];
    int n = backtrace(frames, 48);
    backtrace_symbols_fd(frames, n, open(kCrashFile, O_WRONLY | O_CREAT | O_APPEND, 0644));
    wvfWriteRaw("\n");

    signal(sig, SIG_DFL);
    raise(sig);
}

void WVFUncaughtExceptionHandler(NSException *e);\n\n@interface WVFCrashHelper : NSObject
@end

@implementation WVFCrashHelper

+ (void)handleException:(NSException *)e
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"\n===== EXCEPTION =====\n%@\n", [NSDate date]];
    [s appendFormat:@"name  : %@\n", e.name];
    [s appendFormat:@"reason: %@\n", e.reason];
    [s appendString:@"callStack:\n"];
    for (NSString *line in e.callStackSymbols) {
        [s appendFormat:@"  %@\n", line];
    }
    [s appendString:@"===== END =====\n"];

    WVFCrashEnsureDir();
    FILE *fp = fopen(kCrashFile, "a");
    if (fp) {
        fprintf(fp, "%s", s.UTF8String);
        fclose(fp);
    }
}

@end

void WVFCrashInstall(void)
{
    WVFCrashEnsureDir();

    NSSetUncaughtExceptionHandler(&WVFUncaughtExceptionHandler);

    signal(SIGSEGV, WVFSignalHandler);
    signal(SIGABRT, WVFSignalHandler);
    signal(SIGBUS,  WVFSignalHandler);
    signal(SIGILL,  WVFSignalHandler);
    signal(SIGFPE,  WVFSignalHandler);
    signal(SIGTRAP, WVFSignalHandler);
}

void WVFUncaughtExceptionHandler(NSException *e)
{
    [WVFCrashHelper handleException:e];
}

NSString *WVFCrashReadLast(void)
{
    NSString *s = [NSString stringWithContentsOfFile:WVFCrashPath()
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    if (!s.length) return nil;

    // 只取最后 30 行，避免刷屏
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    if (lines.count > 30) {
        lines = [lines subarrayWithRange:NSMakeRange(lines.count - 30, 30)];
    }
    return [lines componentsJoinedByString:@"\n"];
}

void WVFCrashClear(void)
{
    [[NSFileManager defaultManager] removeItemAtPath:WVFCrashPath() error:NULL];
}
