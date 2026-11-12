#import <UIKit/UIKit.h>

// 前向声明：保证链接器保留该类（避免 Release 瘦身时被删掉）
@interface WVFRootViewController : UIViewController
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[WVFRootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
