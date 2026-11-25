//
//  WVFLicense.h
//  卡密授权客户端
//

#import <Foundation/Foundation.h>

@interface WVFLicense : NSObject

/// 当前设备标识来源：UDID / KEYCHAIN / GEN
@property (nonatomic, copy) NSString *deviceIDSource;

+ (instancetype)shared;

/// 设备唯一标识（用于绑定）
- (NSString *)deviceID;

/// 本地是否处于已授权状态
- (BOOL)activated;

/// 剩余天数；-1 表示永久
- (NSInteger)remainDays;

/// 当前卡密
- (NSString *)activeKey;

/// 激活（首次）
/// 服务器诊断：把 ?diag=1 的返回原文取回来（长按「激活」触发）
- (NSString *)httpGetViaSocket:(NSString *)urlString body:(NSData **)outBody;

- (void)resetActivation;

- (NSDictionary *)daemonFetch:(NSString *)urlStr;

- (void)diagnoseWithCompletion:(void (^)(NSString *text))completion;

- (void)activateWithKey:(NSString *)key
             completion:(void (^)(BOOL ok, NSString *msg))completion;

/// 校验（每次启动调用；失败且超出离线宽限期则视为失效）
- (void)refreshWithCompletion:(void (^)(BOOL ok, NSString *msg))completion;

/// 当前应用 ID
- (NSString *)appID;

/// 临时覆盖应用 ID（调试用，长按激活标题可设置）
- (void)setOverrideAppID:(NSString *)appid;

/// 清空本地授权（调试用）
- (void)clear;

/// 上报设备信息（写 trollstore_devices 表，让后台显示"已激活"）
- (void)registerDeviceWithKey:(NSString *)key
                   completion:(void (^)(BOOL ok, NSString *msg))completion;

@end
