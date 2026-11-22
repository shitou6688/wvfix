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
#import <Security/Security.h>
#import <dlfcn.h>
#import <sys/select.h>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>
#import <netdb.h>
#import <sys/socket.h>

static NSString *const kWVFKey       = @"wvf_license_key";
static NSString *const kWVFExpire    = @"wvf_license_expire";
static NSString *const kWVFLastCheck = @"wvf_license_lastcheck";
static NSString *const kWVFDevice    = @"wvf_license_device";
static NSString *const kWVFChainService = @"com.local.wechatverfix.device";

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

#pragma mark - 硬件 UDID（需要 TrollStore 的 platform 权限）

typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef);

- (NSString *)hardwareUDID {
    static NSString *cached;
    static BOOL tried = NO;
    if (tried) return cached;
    tried = YES;

    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!h) return nil;

    MGCopyAnswerFn fn = (MGCopyAnswerFn)dlsym(h, "MGCopyAnswer");
    if (!fn) fn = (MGCopyAnswerFn)dlsym(h, "MGBCopyAnswer");
    if (!fn) return nil;

    const char *keys[] = { "UniqueDeviceID", "SerialNumber" };
    for (int i = 0; i < 2; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
        if (!key) continue;
        CFTypeRef v = fn(key);
        CFRelease(key);
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
            NSString *s = [(__bridge NSString *)v copy];
            CFRelease(v);
            if (s.length >= 8) {
                cached = [s uppercaseString];
                return cached;
            }
        } else if (v) {
            CFRelease(v);
        }
    }
    return nil;
}


- (NSString *)chainDeviceID {
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWVFChainService,
        (__bridge id)kSecAttrAccount: @"device",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) == errSecSuccess && out) {
        NSData *d = (__bridge_transfer NSData *)out;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s.length) return s;
    }
    return nil;
}

- (void)saveChainDeviceID:(NSString *)value {
    NSDictionary *base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWVFChainService,
        (__bridge id)kSecAttrAccount: @"device",
    };
    SecItemDelete((__bridge CFDictionaryRef)base);

    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] =
        (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

- (NSString *)deviceID {
    static NSString *cached;
    if (cached) return cached;

    // 1. 硬件 UDID（刷机不变，换机才变）
    NSString *v = [self hardwareUDID];
    if (v.length) {
        self.deviceIDSource = @"UDID";
        cached = v;
        return cached;
    }

    // 2. Keychain 里持久化的标识（卸载重装仍在）
    v = [self chainDeviceID];
    if (v.length) {
        self.deviceIDSource = @"KEYCHAIN";
        cached = v;
        return cached;
    }

    // 3. 首次运行：用 IDFV 生成并存入 Keychain
    NSString *seed = nil;
    @try {
        seed = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    } @catch (NSException *e) {
        seed = nil;
    }
    if (!seed.length) seed = [[NSUUID UUID] UUIDString];
    v = [[seed stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    [self saveChainDeviceID:v];
    self.deviceIDSource = @"GEN";
    cached = v;
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

#pragma mark - 原始 socket HTTP（绕过 ATS / 可达性判断）

- (NSString *)httpGetViaSocket:(NSString *)urlString body:(NSData **)outBody
{
    if (outBody) *outBody = nil;

    NSURL *u = [NSURL URLWithString:urlString];
    if (!u || !u.host) return @"URL 无效";

    NSString *host = u.host;
    int port = u.port ? u.port.intValue : 80;
    NSString *path = u.path.length ? u.path : @"/";
    if (u.query.length) path = [path stringByAppendingFormat:@"?%@", u.query];

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    int gai = getaddrinfo(host.UTF8String, portStr, &hints, &res);
    if (gai != 0 || !res) {
        return [NSString stringWithFormat:@"解析失败 %s", gai_strerror(gai)];
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return [NSString stringWithFormat:@"socket 失败 errno=%d", errno];
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    if (rc != 0 && errno != EINPROGRESS) {
        int e = errno;
        freeaddrinfo(res);
        close(fd);
        return [NSString stringWithFormat:@"connect 失败 errno=%d (%s)", e, strerror(e)];
    }
    if (rc != 0) {
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(fd, &wset);
        struct timeval tv = { 8, 0 };
        int sel = select(fd + 1, NULL, &wset, NULL, &tv);
        if (sel <= 0) {
            freeaddrinfo(res);
            close(fd);
            return @"connect 超时";
        }
        int soerr = 0;
        socklen_t len = sizeof(soerr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
        if (soerr != 0) {
            freeaddrinfo(res);
            close(fd);
            return [NSString stringWithFormat:@"connect 失败 errno=%d (%s)", soerr, strerror(soerr)];
        }
    }
    freeaddrinfo(res);
    fcntl(fd, F_SETFL, flags);

    NSString *reqStr = [NSString stringWithFormat:
        @"GET %@ HTTP/1.0\r\nHost: %@\r\nUser-Agent: WeChatVerFix\r\nConnection: close\r\n\r\n",
        path, host];
    const char *reqC = reqStr.UTF8String;
    size_t sent = 0, totalLen = strlen(reqC);
    while (sent < totalLen) {
        ssize_t n = write(fd, reqC + sent, totalLen - sent);
        if (n <= 0) { close(fd); return @"发送失败"; }
        sent += (size_t)n;
    }

    NSMutableData *resp = [NSMutableData data];
    char buf[4096];
    while (1) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) { [resp appendBytes:buf length:(NSUInteger)n]; continue; }
        if (n == 0) break;
        if (errno == EAGAIN) { usleep(20000); continue; }
        break;
    }
    close(fd);

    if (!resp.length) return @"无响应";

    NSRange sep = [resp rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding]
                            options:0 range:NSMakeRange(0, resp.length)];
    if (sep.location == NSNotFound) {
        if (outBody) *outBody = resp;
        return @"响应格式异常";
    }
    NSInteger status = 0;
    sscanf((const char *)resp.bytes, "HTTP/%*s %ld", &status);
    if (outBody) {
        *outBody = [resp subdataWithRange:
                    NSMakeRange(sep.location + sep.length, resp.length - sep.location - sep.length)];
    }
    return [NSString stringWithFormat:@"HTTP %ld", (long)status];
}


- (void)diagnoseWithCompletion:(void (^)(NSString *text))completion
{
    NSString *base = [self serverURL];
    if (!base.length) { completion(@"未配置服务器地址"); return; }

    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"?diag=1"]];
    if (!url) { completion(@"服务器地址无效"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion([NSString stringWithFormat:@"失败：%@ (code %ld)\n%@",
                        err.localizedDescription, (long)err.code, base]);
            return;
        }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        NSString *body = data.length ? [[NSString alloc] initWithData:data
                                                             encoding:NSUTF8StringEncoding] : @"";
        if (body.length > 260) body = [body substringToIndex:260];
        completion([NSString stringWithFormat:@"HTTP %ld\n%@", (long)hr.statusCode, body ?: @""]);
    }] resume];
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
            // NSURLSession 失败 → 改用原始 socket 再试（绕过 ATS / 可达性判断）
            NSData *rawBody = nil;
            // https 必须由系统做 TLS 校验，socket 走不了 TLS：直接报错
            if (![urlStr hasPrefix:@"http://"]) {
                completion(-1, nil, 0, [NSString stringWithFormat:@"网络错误(%ld) %@",
                            (long)err.code, err.localizedDescription ?: @""]);
                return;
            }
            NSString *sockResult = [self httpGetViaSocket:urlStr body:&rawBody];
            if (rawBody.length) {
                NSDictionary *json2 = [NSJSONSerialization JSONObjectWithData:rawBody
                                                                     options:0 error:NULL];
                if ([json2 isKindOfClass:[NSDictionary class]]) {
                    NSInteger c2 = [json2[@"code"] integerValue];
                    completion(c2, json2[@"msg"] ?: @{}, 0, nil);
                    return;
                }
            }
            completion(-1, nil, 0, [NSString stringWithFormat:@"网络错误(%ld) %@\nsocket: %@",
                        (long)err.code, err.localizedDescription ?: @"", sockResult ?: @"?"]);
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
