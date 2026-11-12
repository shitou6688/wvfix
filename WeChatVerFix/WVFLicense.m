//
//  WVFLicense.m
//  卡密授权客户端
//
//  Info.plist 里需要两个键：
//    WVFLicenseServer   例如 https://your-domain.com/kami
//    WVFLicenseSecret   与服务端 config.json 的 secret 完全一致
//

#import "WVFLicense.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonHMAC.h>

static NSString *const kWVFKey       = @"wvf_license_key";
static NSString *const kWVFExpire    = @"wvf_license_expire";
static NSString *const kWVFLastCheck = @"wvf_license_lastcheck";
static NSString *const kWVFDevice    = @"wvf_license_device";

static const NSTimeInterval kOfflineGrace = 3 * 86400;  // 离线宽限期 3 天

@implementation WVFLicense

+ (instancetype)shared {
    static WVFLicense *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[WVFLicense alloc] init]; });
    return inst;
}

- (NSString *)serverURL {
    NSString *u = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WVFLicenseServer"];
    if (!u.length) return @"";
    while ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    return u;
}

- (NSString *)secret {
    NSString *s = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"WVFLicenseSecret"];
    return s.length ? s : @"";
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
        v = [[NSUserDefaults standardUserDefaults] stringForKey:kVVFDevice];
        if (!v.length) {
            v = [[NSUUID UUID] UUIDString];
            [[NSUserDefaults standardUserDefaults] setObject:v forKey:kVVFDevice];
        }
    }
    cached = [v stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return cached;
}

- (NSString *)activeKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kWVFKey] ?: @"";
}

- (long long)expireAt {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kWVFExpire]
        ? (long long)[[NSUserDefaults standardUserDefaults] doubleForKey:kWVFExpire] : 0;
}

- (BOOL)activated {
    if (![self activeKey].length) return NO;
    long long exp = [self expireAt];
    if (exp == 0) return YES;                       // 永久
    return exp > (long long)[[NSDate date] timeIntervalSince1970];
}

- (NSInteger)remainDays {
    long long exp = [self expireAt];
    if (exp == 0) return -1;
    double diff = (double)exp - [[NSDate date] timeIntervalSince1970];
    if (diff <= 0) return 0;
    return (NSInteger)ceil(diff / 86400.0);
}

- (void)clear {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kWVFKey];
    [d removeObjectForKey:kWVFExpire];
    [d removeObjectForKey:kWVFLastCheck];
}

#pragma mark - 网络

- (NSString *)hmac:(NSString *)text {
    const char *k = [self.secret UTF8String];
    const char *m = [text UTF8String];
    unsigned char out[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCPRFHmacAlgSHA256, k, strlen(k), m, strlen(m), out);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", out[i]];
    }
    return hex;
}

- (void)post:(NSString *)path
        body:(NSDictionary *)body
  completion:(void (^)(NSDictionary *json, NSString *err))completion {
    NSString *base = [self serverURL];
    if (!base.length) {
        completion(nil, @"未配置授权服务器");
        return;
    }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:path]];
    if (!url) {
        completion(nil, @"授权服务器地址无效");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 12;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion(nil, @"网络错误，请检查网络后重试");
            return;
        }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        NSDictionary *json = nil;
        if (data.length) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        }
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, [NSString stringWithFormat:@"服务器返回异常（HTTP %ld）", (long)hr.statusCode]);
            return;
        }
        completion(json, nil);
    }];
    [task resume];
}

- (NSDictionary *)signedBodyFor:(NSString *)action key:(NSString *)key {
    long long ts = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *nonce = [[NSUUID UUID] UUIDString];
    nonce = [nonce stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *raw = [NSString stringWithFormat:@"%@|%@|%@|%lld|%@",
                     action, key, [self deviceID], ts, nonce];
    return @{
        @"action": action,
        @"key": key,
        @"device": [self deviceID],
        @"ts": @(ts),
        @"nonce": nonce,
        @"sig": [self hmac:raw],
    };
}

- (void)storeKey:(NSString *)key expire:(long long)expire {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:key forKey:kWVFKey];
    [d setDouble:(double)expire forKey:kWVFExpire];
    [d setDouble:[[NSDate date] timeIntervalSince1970] forKey:kWVFLastCheck];
}

- (void)activateWithKey:(NSString *)key
             completion:(void (^)(BOOL, NSString *))completion {
    NSString *k = [[key uppercaseString] stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (k.length < 8) {
        completion(NO, @"卡密格式不正确");
        return;
    }
    NSDictionary *body = [self signedBodyFor:@"activate" key:k];
    [self post:@"/api/activate" body:body completion:^(NSDictionary *json, NSString *err) {
        if (err) { completion(NO, err); return; }
        if ([json[@"ok"] boolValue]) {
            long long exp = [json[@"expireAt"] longLongValue];
            [self storeKey:k expire:exp];
            NSString *msg = [json[@"permanent"] boolValue]
                ? @"激活成功，已获永久授权"
                : [NSString stringWithFormat:@"激活成功，剩余 %ld 天", (long)[self remainDays]];
            completion(YES, msg);
        } else {
            completion(NO, json[@"msg"] ?: @"激活失败");
        }
    }];
}

- (void)refreshWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSString *k = [self activeKey];
    if (!k.length) { completion(NO, @"未激活"); return; }

    NSDictionary *body = [self signedBodyFor:@"verify" key:k];
    [self post:@"/api/verify" body:body completion:^(NSDictionary *json, NSString *err) {
        if (err) {
            // 网络不通：看离线宽限期
            NSTimeInterval last = [[NSUserDefaults standardUserDefaults] doubleForKey:kWVFLastCheck];
            BOOL grace = ([[NSDate date] timeIntervalSince1970] - last) < kOfflineGrace;
            if (grace && [self activated]) {
                completion(YES, @"离线校验通过");
            } else {
                completion(NO, @"无法连接授权服务器，请联网后重试");
            }
            return;
        }
        if ([json[@"ok"] boolValue]) {
            long long exp = [json[@"expireAt"] longLongValue];
            [self storeKey:k expire:exp];
            completion(YES, @"校验通过");
        } else {
            [self clear];
            completion(NO, json[@"msg"] ?: @"授权已失效");
        }
    }];
}

@end
