//
//  WVFLSRegister.m
//  完整移植 TrollStore 的 registerPath / unregisterApplication
//  参考 RootHelper/uicache.m 的 registerPath()
//
//  registerApplicationDictionary: 会把 App 的 entitlements、容器、App Group、
//  PlugIns 一整套重新登记进 LaunchServices，比 LSRegisterURL 更彻底。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// 私有 Security API（用 dlsym 取，缺失时安全返回 nil，避免符号不存在直接崩）
typedef struct __SecCode const *WVFSecStaticCodeRef;
typedef OSStatus (*WVFSecStaticCodeCreateFn)(CFURLRef, uint32_t, CFDictionaryRef, WVFSecStaticCodeRef *);
typedef OSStatus (*WVFSecCopySigningInfoFn)(WVFSecStaticCodeRef, uint32_t, CFDictionaryRef *);

static WVFSecStaticCodeCreateFn wvfSecCreate(void)
{
    static WVFSecStaticCodeCreateFn fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (h) fn = (WVFSecStaticCodeCreateFn)dlsym(h, "SecStaticCodeCreateWithPathAndAttributes");
    }
    return fn;
}

static WVFSecCopySigningInfoFn wvfSecInfo(void)
{
    static WVFSecCopySigningInfoFn fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (h) fn = (WVFSecCopySigningInfoFn)dlsym(h, "SecCodeCopySigningInformation");
    }
    return fn;
}

static id WVFLSWorkspace(void)
{
    static id cached = nil;
    static BOOL tried = NO;
    if (cached) return cached;
    if (tried) return nil;
    tried = YES;

    NSArray *fwPaths = @[
        @"/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore",
        @"/System/Library/Frameworks/CoreServices.framework/CoreServices",
        @"/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
    ];
    for (NSString *p in fwPaths) dlopen(p.fileSystemRepresentation, RTLD_LAZY);

    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return nil;
    @try {
        cached = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(defaultWorkspace));
    } @catch (NSException *e) {
        cached = nil;
    }
    return cached;
}

NSDictionary *WVFDumpEntitlements(NSString *binaryPath)
{
    if (!binaryPath.length) return nil;
    WVFSecStaticCodeCreateFn createFn = wvfSecCreate();
    WVFSecCopySigningInfoFn infoFn = wvfSecInfo();
    if (!createFn || !infoFn) return nil;

    WVFSecStaticCodeRef code = NULL;
    NSURL *url = [NSURL fileURLWithPath:binaryPath];
    OSStatus st = createFn((__bridge CFURLRef)url, 0, NULL, &code);
    if (st != 0 || !code) return nil;

    CFDictionaryRef cfInfo = NULL;
    st = infoFn(code, 1 << 2, &cfInfo);
    if (st != 0 || !cfInfo) return nil;

    NSDictionary *dict = (__bridge_transfer NSDictionary *)cfInfo;
    NSString *key = @"Entitlements";
    id ent = dict[key];
    return [ent isKindOfClass:[NSDictionary class]] ? ent : nil;
}

static NSString *WVFDataContainerPath(NSString *appId)
{
    Class cls = NSClassFromString(@"MCMAppDataContainer");
    if (!cls) return nil;

    SEL sel = NSSelectorFromString(@"containerWithIdentifier:createIfNecessary:existed:error:");
    if (![cls respondsToSelector:sel]) return nil;
    NSMethodSignature *checkSig = [cls methodSignatureForSelector:sel];
    if (!checkSig || checkSig.numberOfArguments < 6) return nil;

    @try {
        NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:cls];
        [inv setSelector:sel];
        NSString *ident = appId;
        BOOL create = YES;
        id existed = nil;
        id error = nil;
        [inv setArgument:&ident atIndex:2];
        [inv setArgument:&create atIndex:3];
        [inv setArgument:&existed atIndex:4];
        [inv setArgument:&error atIndex:5];
        [inv invoke];

        id container = nil;
        [inv getReturnValue:&container];
        if (!container) return nil;

        NSURL *u = [container valueForKey:@"url"];
        return u.path;
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *WVFTeamIdentifier(NSDictionary *entitlements)
{
    if (![entitlements isKindOfClass:[NSDictionary class]]) return nil;
    id t = entitlements[@"com.apple.developer.team-identifier"];
    return [t isKindOfClass:[NSString class]] ? t : nil;
}

static NSDictionary *WVFGroupContainers(NSDictionary *entitlements, BOOL system)
{
    if (![entitlements isKindOfClass:[NSDictionary class]]) return nil;
    NSString *key = system ? @"com.apple.security.application-groups"
                           : @"com.apple.security.application-groups";
    id groups = entitlements[key];
    if (![groups isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id g in groups) {
        if (![g isKindOfClass:[NSString class]]) continue;
        NSString *url = [NSString stringWithFormat:@"/private/var/%@containers/Shared/SystemGroup/%@",
                         system ? "" : "mobile/", g];
        out[g] = url;
    }
    return out.count ? out : nil;
}

/// 完整登记一个 App（对应 uicache.m 的 registerPath(path, NO, forceSystem)）
BOOL WVFRegisterAppPath(NSString *path, BOOL forceSystem, NSMutableString *logOut)
{
    if (!path.length) return NO;
    path = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;

    id ws = WVFLSWorkspace();
    if (!ws) {
        if (logOut) [logOut appendString:@"workspace 不可用；"];
        return NO;
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *appId = info[@"CFBundleIdentifier"];
    if (!appId.length) {
        if (logOut) [logOut appendString:@"Info.plist 无 CFBundleIdentifier；"];
        return NO;
    }

    NSString *execPath = [path stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: @""];
    NSDictionary *entitlements = WVFDumpEntitlements(execPath);

    BOOL isRemovable = [[NSFileManager defaultManager]
        fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appId]];
    BOOL registerAsUser = [path hasPrefix:@"/var/containers"] && !isRemovable && !forceSystem;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (entitlements) dict[@"Entitlements"] = entitlements;

    dict[@"ApplicationType"]        = registerAsUser ? @"User" : @"System";
    dict[@"CFBundleIdentifier"]     = appId;
    dict[@"CodeInfoIdentifier"]     = appId;
    dict[@"CompatibilityState"]     = @0;
    dict[@"IsContainerized"]        = @(entitlements != nil);
    dict[@"Path"]                   = path;
    dict[@"SignerOrganization"]     = @"Apple Inc.";
    dict[@"SignatureVersion"]       = @132352;
    dict[@"SignerIdentity"]         = @"Apple iPhone OS Application Signing";
    dict[@"IsAdHocSigned"]          = @YES;
    dict[@"LSInstallType"]          = @1;
    dict[@"HasMIDBasedSINF"]        = @0;
    dict[@"MissingSINF"]            = @0;
    dict[@"FamilyID"]               = @0;
    dict[@"IsOnDemandInstallCapable"] = @0;

    NSString *containerPath = WVFDataContainerPath(appId);
    if (containerPath) dict[@"Container"] = containerPath;

    NSString *team = WVFTeamIdentifier(entitlements);
    if (team) dict[@"TeamIdentifier"] = team;

    NSDictionary *groups = WVFGroupContainers(entitlements, NO);
    if (groups) {
        dict[@"HasAppGroupContainers"] = @YES;
        dict[@"GroupContainers"] = groups;
    }

    BOOL ok = NO;
    @try {
        ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws,
                @selector(registerApplicationDictionary:), dict);
    } @catch (NSException *e) {
        if (logOut) [logOut appendFormat:@"registerApplicationDictionary 异常:%@；", e.reason];
        return NO;
    }

    if (!ok && logOut) {
        [logOut appendFormat:@"登记失败:%@；", appId];
    }
    return ok;
}

BOOL WVFUnregisterAppPath(NSString *path, NSMutableString *logOut)
{
    id ws = WVFLSWorkspace();
    if (!ws || !path.length) return NO;
    BOOL ok = NO;
    @try {
        ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(unregisterApplication:),
                                                   [NSURL fileURLWithPath:path]);
    } @catch (NSException *e) {
        return NO;
    }
    if (!ok && logOut) [logOut appendFormat:@"注销失败:%@；", path];
    return ok;
}

/// 重新登记所有 TrollStore 安装的 App（带 _TrollStore 标记）
int WVFRefreshTrollStoreApps(NSMutableString *logOut)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";
    int count = 0;

    NSArray *subs = [fm contentsOfDirectoryAtPath:root error:NULL];
    for (NSString *sub in subs) {
        NSString *dir = [root stringByAppendingPathComponent:sub];
        NSArray *inner = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *x in inner) {
            if (![x hasSuffix:@".app"]) continue;
            NSString *appPath = [dir stringByAppendingPathComponent:x];
            NSString *marker = [appPath stringByAppendingPathComponent:@"_TrollStore"];
            BOOL marked = [fm fileExistsAtPath:marker];
            if (!marked) {
                // 有些版本标记在容器目录
                marked = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"_TrollStore"]];
            }
            if (!marked) continue;
            if (WVFRegisterAppPath(appPath, YES, logOut)) count++;
        }
    }
    return count;
}
