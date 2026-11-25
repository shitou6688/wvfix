#import <UIKit/UIKit.h>
#import "WVFLicense.h"

// 前向声明：保证链接器保留该类（避免 Release 瘦身时被删掉）
@interface WVFRootViewController : UIViewController
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 【关键】启动瞬间发轻量请求，让系统「允许无线数据」弹窗
    // 在 App 打开时就出现，而不是等用户点激活才弹。
    [[WVFLicense shared] warmUpNetwork];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[WVFRootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
