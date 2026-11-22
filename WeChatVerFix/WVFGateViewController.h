//
//  WVFGateViewController.h
//  激活授权弹窗（模态视图控制器，保证有 VC 祖先，键盘可用）
//

#import <UIKit/UIKit.h>

typedef void (^WVFGateFinishBlock)(void);

@interface WVFGateViewController : UIViewController

@property (nonatomic, copy) NSString *initialMessage;
@property (nonatomic, copy) WVFGateFinishBlock onFinish;   // 激活成功后回调

- (void)setStatusText:(NSString *)text isError:(BOOL)isError;

@end
