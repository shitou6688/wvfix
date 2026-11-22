//
//  WVFCrash.h
//  崩溃 / 异常采集（把原因写到文件，方便客户回传）
//

#import <Foundation/Foundation.h>

/// 安装异常与信号处理器（App 启动时调用一次）
void WVFCrashInstall(void);

/// 读取上一次的崩溃记录（没有则返回 nil）
NSString *WVFCrashReadLast(void);

/// 清空崩溃记录
void WVFCrashClear(void);
