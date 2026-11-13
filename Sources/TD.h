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
/// 屏幕点尺寸 / 像素尺寸 换算比
CGFloat TDscreenScaleRatio(void);

#pragma mark - 识图（模板匹配）

@class TDMatch;

TDMatch * _Nullable TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps);

@interface TDMatch : NSObject
@property (nonatomic) double score;
@property (nonatomic) CGPoint point;   // 匹配中心，屏幕点坐标
@property (nonatomic) CGFloat scale;
@end

#pragma mark - 脚本

/// 一条脚本 = 一串步骤
/// 步骤格式（均带 gap：与上一步之间的间隔毫秒）：
///   {"t":"tap","x":207,"y":660,"gap":0}
///   {"t":"long","x":207,"y":660,"ms":800,"gap":0}
///   {"t":"swipe","x1":207,"y1":600,"x2":207,"y2":200,"ms":400,"gap":0}
///   {"t":"wait","ms":500,"gap":0}
@interface TDScript : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSTimeInterval createdAt;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *steps;

- (instancetype)initWithName:(NSString *)name;
- (NSString *)summary;                        // "12 步 · 0:35"
- (NSTimeInterval)duration;                   // 估算总时长（秒）
- (NSArray<NSDictionary *> *)engineSteps;     // 把 gap 展开成 wait
+ (NSString *)describeStep:(NSDictionary *)st;
@end

@interface TDScriptStore : NSObject
+ (instancetype)shared;
@property (nonatomic, strong, readonly) NSMutableArray<TDScript *> *scripts;
@property (nonatomic) NSInteger selected;
- (TDScript *)createScript;
- (nullable TDScript *)selectedScript;
- (void)removeAtIndex:(NSInteger)idx;
- (void)save;
- (void)load;
@end

#pragma mark - 录制（系统级触摸监听）

@interface TDRecorder : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) NSInteger eventCount;      // 已采到的样本数
@property (nonatomic, readonly) NSInteger rawEventCount;   // 系统投递过来的事件数（诊断用）
@property (nonatomic, copy, nullable) void (^onChange)(void);

/// 返回 NO 表示系统不给监听（权限/接口不可用），此时只能用手动取点
- (BOOL)start;
- (NSMutableArray<NSDictionary *> *)stop;
- (NSString *)status;
@end

#pragma mark - 回放引擎

@interface TDEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) NSInteger loopsDone;
@property (nonatomic, copy, nullable) NSString *jetsamStatus;
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *msg);
@property (nonatomic, copy, nullable) void (^onFinish)(void);

- (void)playSteps:(NSArray<NSDictionary *> *)steps loop:(NSInteger)loops;
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
- (void)save;
@end

#pragma mark - 系统级悬浮窗（SpringBoard 托管，可盖在别的 App 上）

/// 必须用这个类，普通 UIWindow 盖不到别的 App 上面
@interface TDHUDWindow : UIWindow
@end

BOOL TDHUDRegisterWindow(UIWindow *w);
void TDHUDUnregisterWindow(UIWindow *w);
NSString *TDHUDStatus(void);

/// 穿透模式：YES 时悬浮球不接管触摸（球也点不了，但完全不挡下面）
void TDHUDSetPassthrough(BOOL on);
BOOL TDHUDPassthrough(void);

/// 把自己提到 critical jetsam 优先级并禁止冻结
NSString *TDBypassJetsam(void);

#pragma mark - 后台保活 / 环境

@interface TDKeepAlive : NSObject
+ (void)start;
/// 重新激活一次音频会话（被别的 App 抢走后，后台就保不住了）
+ (void)ensure;
+ (NSString *)status;
@end

NSString *TDSandboxStatus(void);

/// 上一次崩溃的堆栈（没有则返回空字符串）
NSString *TDcrashLogText(void);
void TDcrashLogClear(void);

/// 录制链路的执行轨迹（判断崩在回调的哪一步）
NSString *TDtraceLogText(void);
void TDtraceLogClear(void);

#pragma mark - 全局日志通道（UI 订阅用）

void TDLog(NSString *fmt, ...);
void TDSetLogHandler(void (^ _Nullable h)(NSString *));

#pragma mark - 数据变更通知（录制完/脚本改了，UI 和悬浮球都跟着刷）

extern NSString * const TDDataChangedNotification;

#pragma mark - 悬浮球

/// AppDelegate 启动时调用一次：建球 + 交给 SpringBoard 托管
void TDFloatInstall(void);
void TDFloatSetVisible(BOOL on);
BOOL TDFloatVisible(void);
/// 引擎/录制状态变了以后调它，球会换颜色和文字
void TDFloatRefresh(void);
void TDFloatResetPosition(void);

NS_ASSUME_NONNULL_END
