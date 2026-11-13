#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 触摸注入（IOHIDEvent 全局注入）

BOOL TDhidReady(void);
NSString *TDhidStatus(void);

void TDtap(CGFloat x, CGFloat y);
void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec);
void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec);
/// 多点轨迹手势，points 为 NSValue(CGPoint)，sec 为总时长
void TDgesture(NSArray<NSValue *> *points, NSTimeInterval sec);

#pragma mark - 截屏

BOOL TDcaptureReady(void);
NSString *TDcaptureStatus(void);
UIImage * _Nullable TDscreenshot(void);

#pragma mark - 识图（模板匹配）

@class TDMatch;

/// 在当前屏幕上查找模板图，返回最佳匹配；score 为归一化相关度(0~1)
TDMatch * _Nullable TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps);

@interface TDMatch : NSObject
@property (nonatomic) double score;
@property (nonatomic) CGPoint point;   // 匹配中心，屏幕点坐标
@property (nonatomic) CGFloat scale;
@end

#pragma mark - 脚本引擎

@class TDEngine;

@interface TDEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, copy, nullable) NSString *jetsamStatus;
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *msg);
- (void)startWithScript:(NSDictionary *)script;
- (void)stop;
- (void)logMsg:(NSString *)fmt, ...;
@end

#pragma mark - 配置

@interface TDConfig : NSObject
@property (nonatomic) double jitterPx;      // 点击随机偏移半径(点)
@property (nonatomic) double tapHoldMs;     // 按下保持毫秒
@property (nonatomic) double intervalMs;    // 步骤间基础间隔
@property (nonatomic) double threshold;     // 识图相似度阈值
@property (nonatomic) NSInteger loopCount;  // 0=无限
+ (instancetype)shared;
- (NSMutableArray<NSMutableDictionary *> *)steps;
- (void)save;
- (void)load;
- (void)addStep:(NSDictionary *)step;
- (void)removeStepAtIndex:(NSInteger)idx;
- (void)moveStepFrom:(NSInteger)from to:(NSInteger)to;
@end

/// 屏幕点尺寸 / 像素尺寸 换算比（用于把截图像素坐标转成点击点坐标）
CGFloat TDscreenScaleRatio(void);

#pragma mark - 系统级悬浮窗（SpringBoard 托管，可盖在别的 App 上）

/// 必须用这个类，普通 UIWindow 盖不到别的 App 上面
@interface TDHUDWindow : UIWindow
@end

/// 把窗口的 context 交给 SpringBoard 渲染；返回 NO 表示还没就绪，可稍后重试
BOOL TDHUDRegisterWindow(UIWindow *w);
void TDHUDUnregisterWindow(UIWindow *w);
NSString *TDHUDStatus(void);

/// 穿透模式：YES 时悬浮窗完全不接管触摸，手动滑动抖音时打开
void TDHUDSetPassthrough(BOOL on);
BOOL TDHUDPassthrough(void);

/// 把自己提升到 critical jetsam 优先级并禁止冻结，切到别的 App 后不被回收
NSString *TDBypassJetsam(void);

NS_ASSUME_NONNULL_END
