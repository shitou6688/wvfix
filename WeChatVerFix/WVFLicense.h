//
//  WVFLicense.h
//  卡密授权客户端
//

#import <Foundation/Foundation.h>

@interface WVFLicense : NSObject

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
- (void)activateWithKey:(NSString *)key
             completion:(void (^)(BOOL ok, NSString *msg))completion;

/// 校验（每次启动调用；失败且超出离线宽限期则视为失效）
- (void)refreshWithCompletion:(void (^)(BOOL ok, NSString *msg))completion;

/// 清空本地授权（调试用）
- (void)clear;

@end
