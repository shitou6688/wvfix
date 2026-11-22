//
//  main.m — 图标缓存修复（独立测试工具）
//
//  用途：单独验证「重建图标缓存」到底哪一步生效。
//  特点：所有结果先写文件 + 显示在屏幕上，最后才由你手动决定是否重启桌面。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <string.h>
#import <unistd.h>

#pragma mark - 基础工具

static NSMutableString *gLog = nil;
static NSString *const kLogDir = @"/var/mobile/Documents/IconFix";

static void wvfLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    if (!gLog) gLog = [NSMutableString new];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [[NSDateFormatter new] stringFromDate:[NSDate date]], s];
    [gLog appendString:line];
    NSLog(@"%@", line);

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:kLogDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [kLogDir stringByAppendingPathComponent:@"log.txt"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static int wvfKillSignal(const char *name, int sig)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return -1;
    struct kinfo_proc *procs = malloc(size);
    if (!procs) return -2;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return -3; }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int killed = 0;
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            if (kill(pid, sig) == 0) killed++;
        }
    }
    free(procs);
    return killed;
}

#pragma mark - LaunchServices

static id wvfWorkspace(void)
{
    NSArray *paths = @[
        @"/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore",
        @"/System/Library/Frameworks/CoreServices.framework/CoreServices",
        @"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
    ];
    for (NSString *p in paths) dlopen(p.fileSystemRepresentation, RTLD_LAZY);

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    wvfLog(@"LSApplicationWorkspace 类：%@", cls ? @"已加载" : @"未找到");
    if (!cls) return nil;

    id ws = nil;
    @try {
        ws = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(defaultWorkspace));
    } @catch (NSException *e) {
        wvfLog(@"defaultWorkspace 异常：%@", e.reason);
    }
    wvfLog(@"workspace 实例：%@", ws ? @"OK" : @"nil");
    return ws;
}

static int wvfPurgeMissingApps(id ws)
{
    if (!ws) return -1;
    int removed = 0, total = 0;

    @try {
        NSArray *all = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allApplications));
        total = (int)all.count;
        wvfLog(@"LS 记录总数：%d", total);

        for (id proxy in all) {
            NSURL *url = [proxy valueForKey:@"bundleURL"];
            NSString *path = url.path;
            if (!path.length) continue;
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) continue;

            wvfLog(@"失效记录：%@", path);
            BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws,
                          @selector(unregisterApplication:), url);
            if (ok) removed++;
        }
    } @catch (NSException *e) {
        wvfLog(@"枚举异常：%@", e.reason);
    }
    wvfLog(@"注销失效记录：%d 项（共 %d 条）", removed, total);
    return removed;
}

static BOOL wvfLSRebuild(id ws)
{
    if (!ws) return NO;
    SEL sel = NSSelectorFromString(@"_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:");
    if (![ws respondsToSelector:sel]) {
        wvfLog(@"私有重建方法：不存在");
        return NO;
    }
    @try {
        NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:ws];
        [inv setSelector:sel];
        BOOL yes = YES;
        [inv setArgument:&yes atIndex:2];
        [inv setArgument:&yes atIndex:3];
        [inv setArgument:&yes atIndex:4];
        [inv invoke];
        wvfLog(@"私有重建方法：已调用");
        return YES;
    } @catch (NSException *e) {
        wvfLog(@"私有重建异常：%@", e.reason);
        return NO;
    }
}

static void wvfDeleteIconsCache(void)
{
    NSArray *paths = @[
        @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache",
        @"/var/mobile/Library/Caches/com.apple.IconsCache",
    ];
    for (NSString *p in paths) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:p];
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:p error:&err];
        wvfLog(@"删缓存 %@ → 存在:%d 错误:%@", p.lastPathComponent, exists,
               err.localizedDescription ?: @"无");
    }
}

#pragma mark - 界面

@interface FixVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end

@implementation FixVC

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, w - 32, 30)];
    title.text = @"图标缓存修复 · 测试工具";
    title.font = [UIFont boldSystemFontOfSize:20];
    [self.view addSubview:title];

    self.tv = [[UITextView alloc] initWithFrame:CGRectMake(12, 100, w - 24, h - 300)];
    self.tv.editable = NO;
    self.tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.tv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.tv.layer.cornerRadius = 10;
    [self.view addSubview:self.tv];

    NSArray *titles = @[@"① 只扫描（不动桌面）",
                        @"② 清理残留（不重启桌面）",
                        @"③ 完整重建（最后重启桌面）"];
    for (int i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16, h - 190 + i * 52, w - 32, 44);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        b.backgroundColor = @[[UIColor systemGrayColor],
                              [UIColor systemOrangeColor],
                              [UIColor systemRedColor]][i];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.layer.cornerRadius = 10;
        b.tag = i;
        [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
}

- (void)refresh
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.tv.text = gLog ?: @"";
        [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length, 0)];
    });
}

- (void)onTap:(UIButton *)sender
{
    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        if (sender.tag == 0) {
            id ws = wvfWorkspace();
            wvfPurgeMissingApps(ws);
        } else if (sender.tag == 1) {
            id ws = wvfWorkspace();
            wvfDeleteIconsCache();
            wvfLSRebuild(ws);
            wvfPurgeMissingApps(ws);
        } else {
            id ws = wvfWorkspace();
            wvfDeleteIconsCache();
            wvfLSRebuild(ws);
            wvfPurgeMissingApps(ws);
            wvfLog(@"5 秒后重启桌面（SIGTERM backboardd）");
            sleep(5);
            int n = wvfKillSignal("backboardd", SIGTERM);
            wvfLog(@"已发送 SIGTERM：%d 个进程", n);
        }
        [self refresh];
        dispatch_async(dispatch_get_main_queue(), ^{ sender.enabled = YES; });
    });
    [self refresh];
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts
{
    wvfLog(@"启动，日志文件：%@/log.txt", kLogDir);
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [FixVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
