//
//  WVFLicense.m
//  卡密授权客户端 —— 对接「忆惜验证系统」
//
//  服务端接口（GET）：
//    {base}/api.php?api=kmlogon&app={appid}&kami={kami}&markcode={device}
//  返回：
//    {"code":200,"msg":{"kami":"WVF-...","vip":"1760000000"},"time":...,"check":"..."}
//     vip >= 4102243200 视为永久
//
//  Info.plist 配置：
//    WVFLicenseServer   例如 http://124.221.171.80
//    WVFLicenseAppID    应用 ID（跑完 add_wechat_app.php 后得到）
//

#import "WVFLicense.h"
#import <UIKit/UIKit.h>

static NSString *const kWVFKey       = @"wvf_license_key";
static NSString *const kWVFExpire    = @"wvf_license_expire";
static NSString *const kWVFLastCheck = @"wvf_license_lastcheck";
static NSString *const kWVFDevice    = @"wvf_license_device";
static NSString *const kWVFAppID     = @"wvf_license_appid_override";

static const long long kPermanentExpire = 4102243200LL;
static const NSTimeInterval kOfflineGrace = 3 * 86400;

@implementation WVFLicense

+ (instancetype)shared {
    static WVFLicense *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[WVFLicense alloc] init]; });
    return inst;
}

#pragma mark - 配置

- (NSString *)serverURL {
    NSString *u = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WVFLicenseServer"];
    if (!u.length) return @"";
    while ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    return u;
}

- (NSString *)appID {
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:kWVFAppID];
    if (override.length) return override;
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WVFLicenseAppID"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return v.length ? v : @"";
}

- (void)setOverrideAppID:(NSString *)appid {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (appid.length) [d setObject:appid forKey:kWVFAppID];
    else [d removeObjectForKey:kWVFAppID];
}

- (NSString *)deviceID {
    static NSString *cached;
    if (cached) return cached;

    NSString *v = nil;
    @try {
        v = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    } @catch (NSException *e) {
        v = nil;
    }
    if (!v.length) {
        v = [[NSUserDefaults standardUserDefaults] stringForKey:kWVFDevice];
        if (!v.length) {
            v = [[NSUUID UUID] UUIDString];
            [[NSUserDefaults standardUserDefaults] setObject:v forKey:kWVFDevice];
        }
    }
    cached = [v stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return cached;
}

#pragma mark - 本地状态

- (NSString *)activeKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kWVFKey] ?: @"";
}

- (long long)expireAt {
    return (long long)[[NSUserDefaults standardUserDefaults] doubleForKey:kWVFExpire];
}

- (BOOL)permanent {
    return [self expireAt] >= kPermanentExpire;
}

- (BOOL)activated {
    if (![self activeKey].length) return NO;
    if ([self permanent]) return YES;
    return [self expireAt] > (long long)[[NSDate date] timeIntervalSince1970];
}

- (NSInteger)remainDays {
    if (![self activeKey].length) return 0;
    if ([self permanent]) return -1;
    double diff = (double)[self expireAt] - [[NSDate date] timeIntervalSince1970];
    if (diff <= 0) return 0;
    return (NSInteger)ceil(diff / 86400.0);
}

- (void)clear {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kWVFKey];
    [d removeObjectForKey:kWVFExpire];
    [d removeObjectForKey:kWVFLastCheck];
}

- (void)storeKey:(NSString *)key expire:(long long)expire {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:key forKey:kWVFKey];
    [d setDouble:(double)expire forKey:kWVFExpire];
    [d setDouble:[[NSDate date] timeIntervalSince1970] forKey:kWVFLastCheck];
}

#pragma mark - 网络

- (NSString *)messageForCode:(NSInteger)code fallback:(NSString *)fallback {
    switch (code) {
        case 101: return @"应用不存在，请联系客服";
        case 102: return @"应用已关闭";
        case 105: return @"请求已过期，请检查手机时间";
        case 106: return @"签名有误，请联系客服";
        case 112: return @"缺少设备标识";
        case 148: return @"请输入卡密";
        case 149: return @"卡密不存在";
        case 150: return @"卡密已在其他设备使用";
        case 151: return @"卡密已被禁用";
        case 169: return @"网络环境变化，请关闭代理后重试";
        case 201: return fallback.length ? fallback : @"验证失败";
        default:  return fallback.length ? fallback : [NSString stringWithFormat:@"验证失败（%ld）", (long)code];
    }
}

- (void)callKami:(NSString *)kami
          action:(NSString *)action
      completion:(void (^)(NSInteger code, NSDictionary *msg, long long vip, NSString *err))completion {

    NSString *base = [self serverURL];
    NSString *appid = [self appID];
    if (!base.length) {
        completion(-1, nil, 0, @"未配置授权服务器");
        return;
    }
    if (!appid.length) {
        completion(-1, nil, 0, @"未配置应用 ID");
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:
        @"%@?api=%@&app=%@&kami=%@&markcode=%@",
        base, action,
        [appid stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]],
        [kami stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]],
        [self deviceID]];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        completion(-1, nil, 0, @"授权服务器地址无效");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion(-1, nil, 0, @"网络错误，请检查网络后重试");
            return;
        }
        NSDictionary *json = nil;
        if (data.length) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
            completion(-1, nil, 0, [NSString stringWithFormat:@"服务器返回异常（HTTP %ld）",
                                    (long)hr.statusCode]);
            return;
        }

        NSInteger code = [json[@"code"] integerValue];
        id msg = json[@"msg"];
        NSDictionary *msgDict = [msg isKindOfClass:[NSDictionary class]] ? msg : nil;
        NSString *msgStr = [msg isKindOfClass:[NSString class]] ? msg : @"";

        if (code == 200) {
            long long vip = 0;
            if (msgDict) {
                id v = msgDict[@"vip"];
                if ([v isKindOfClass:[NSString class]]) vip = [(NSString *)v longLongValue];
                else if ([v isKindOfClass:[NSNumber class]]) vip = [v longLongValue];
            }
            completion(200, msgDict, vip, nil);
        } else {
            completion(code, msgDict, 0, [self messageForCode:code fallback:msgStr]);
        }
    }] resume];
}

#pragma mark - 对外

- (void)activateWithKey:(NSString *)key
             completion:(void (^)(BOOL, NSString *))completion {
    NSString *k = [[key uppercaseString] stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (k.length < 6) {
        completion(NO, @"卡密格式不正确");
        return;
    }

    [self callKami:k action:@"kmlogon" completion:^(NSInteger code, NSDictionary *msg,
                                                   long long vip, NSString *err) {
        if (code != 200) {
            completion(NO, err ?: @"激活失败");
            return;
        }
        [self storeKey:k expire:vip];
        NSString *text = [self permanent]
            ? @"激活成功，已获永久授权"
            : [NSString stringWithFormat:@"激活成功，剩余 %ld 天", (long)[self remainDays]];
        completion(YES, text);
    }];
}

- (void)refreshWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSString *k = [self activeKey];
    if (!k.length) { completion(NO, @"未激活"); return; }

    [self callKami:k action:@"kmlogon" completion:^(NSInteger code, NSDictionary *msg,
                                                   long long vip, NSString *err) {
        if (code == 200) {
            [self storeKey:k expire:vip];
            completion(YES, @"校验通过");
            return;
        }
        if (code < 0) {
            // 网络类错误：看离线宽限期
            NSTimeInterval last = [[NSUserDefaults standardUserDefaults] doubleForKey:kWVFLastCheck];
            BOOL grace = ([[NSDate date] timeIntervalSince1970] - last) < kOfflineGrace;
            if (grace && [self activated]) {
                completion(YES, @"离线校验通过");
            } else {
                completion(NO, err ?: @"无法连接授权服务器");
            }
            return;
        }
        [self clear];
        completion(NO, err ?: @"授权已失效");
    }];
}

@end
