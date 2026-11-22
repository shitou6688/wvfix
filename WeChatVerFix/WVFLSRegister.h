//
//  WVFLSRegister.h
//

#import <Foundation/Foundation.h>

NSDictionary *WVFDumpEntitlements(NSString *binaryPath);
BOOL WVFRegisterAppPath(NSString *path, BOOL forceSystem, NSMutableString *logOut);
BOOL WVFUnregisterAppPath(NSString *path, NSMutableString *logOut);
int  WVFRefreshTrollStoreApps(NSMutableString *logOut);
