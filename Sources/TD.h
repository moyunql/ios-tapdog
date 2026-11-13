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

/// 把「按下去但没抬起来」的手指收回来。
/// up 事件一旦被系统丢掉，屏幕上会留一个幽灵按压点，之后连人工点按都点不动，
/// 只有杀掉 App 才好 —— 这个函数就是用来现场救的。
void TDReleaseStuckTouch(void);
BOOL TDHasStuckTouch(void);
/// 盲扫 identity 1..64 发抬起，清掉可能残留的幽灵手指（启动时用）
void TDReleaseAllTouches(void);

#pragma mark - 真实事件采样（AutoTap 同款思路）

/// 开始监听物理触摸（学到一次真实 down/up 之后才能复制注入）
BOOL TDHIDSampleStart(void);
void TDHIDSampleStop(void);
BOOL TDHIDSampleReady(void);
BOOL TDHIDSampleHasUp(void);
uint64_t TDHIDSampleSenderID(void);
/// 用复制来的真实事件往 p 注入一次点击
void TDHIDReplayTap(CGPoint p);
/// 默认开：学到真实事件后，所有注入都改走「真实事件副本」
BOOL TDUseRealEvents(void);
void TDSetUseRealEvents(BOOL on);

#pragma mark - 注入链路诊断

/// 一次性报告：客户端能否建立、HID 服务数、探到的 senderID、
/// 物理触摸监听状态、回显计数、关键权限是否真的在位。
NSString *TDHIDDiagReport(void);
/// 强制重新探测 senderID（清缓存）
uint64_t TDProbeSenderIDForce(void);
uint64_t TDProbedSenderIDCached(void);
/// 监听到的 digitizer 事件总数（物理 + 回显）
NSInteger TDHIDMonitorCount(void);
/// 本次注入期间回显到的事件数。0 = 事件根本没进 HID 系统。
NSInteger TDHIDMonitorEchoCount(void);
void TDHIDEchoReset(void);
void TDHIDEchoStop(void);

#pragma mark - 注入方案（按可能性排序，含真实 senderID / BKS / 客户端类型）

NSInteger TDInjectPlanCount(void);
NSString *TDInjectPlanDesc(NSInteger i);
void TDApplyInjectPlan(NSInteger i);
/// 走一遍第 i 个方案（会自动选真实副本或合成事件），并开回显计数
void TDRunInjectPlan(NSInteger i, CGPoint p);
/// 用监听学到的真实 senderID 当事件来源（不是猜的，是本机数字转换器的真值）
void TDSetInjectSampleSender(BOOL on);
BOOL TDInjectSampleSenderOn(void);
/// 记住扫描胜出的方案号，下次启动沿用（-1/未设置为没扫过）
void TDSetBestInjectPlan(NSInteger i);
NSInteger TDBestInjectPlan(void);

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

#pragma mark - 录制（全屏取点层，不依赖私有 HID 监听）

@interface TDRecorder : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) NSInteger eventCount;      // 已录到的步骤数
@property (nonatomic, readonly) NSInteger rawEventCount;   // 同上（保留兼容）
@property (nonatomic, copy, nullable) void (^onChange)(void);

/// 把托管窗口铺满全屏、盖上取点层。返回 NO 表示窗口没准备好
- (BOOL)start;
/// 结束录制，存成新脚本（唯一正常的收尾方式）
- (void)finishAndSave;
/// 结束并丢弃
- (void)cancel;
/// 取走步骤并结束（内部用）
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

/// 临时窗口登记（点击反馈圆点用）：不走缓存、不改全局托管状态。
/// 同一个窗口位置变了必须重新调一次，否则 SpringBoard 侧几何还是旧的。
BOOL TDHUDRegisterTransientWindow(UIWindow *w);
void TDHUDUnregisterTransientWindow(UIWindow *w);

#pragma mark - 注入点击反馈

/// 注入时的可视化回调：x/y = 注入的屏幕坐标，down = 是否是按下那一下
typedef void (*TDInjectFeedbackFn)(CGFloat x, CGFloat y, BOOL down);
void TDSetInjectFeedbackHandler(TDInjectFeedbackFn fn);

/// 总开关（默认开），存在 NSUserDefaults 里
BOOL TDInjectFeedbackEnabled(void);
void TDSetInjectFeedbackEnabled(BOOL on);

/// 本次运行累计注入了多少次按下（诊断用）
NSInteger TDInjectCount(void);

#pragma mark - 注入调试（这台机器到底认哪种事件构造）

typedef NS_ENUM(NSInteger, TDInjectVariant) {
    TDInjectVariantNoSender     = 0,   // 不设 senderID（最保守）
    TDInjectVariantHardSender   = 1,   // 硬编码 0x8000000817319372（别的机器的值）
    TDInjectVariantAutoSender   = 2,   // 读本机 HID 服务的真实 senderID
    TDInjectVariantSampleSender = 3,   // 用监听学到的、本机物理触摸的真实 senderID
};

/// 注入坐标用哪个坐标系。事件到底被系统当成哪一种，各机型/系统版本不一样，
/// 表现就是「点中间却落到右下角」这类复位式错位。
typedef NS_ENUM(NSInteger, TDCoordMode) {
    TDCoordModePoint      = 0,   // 414×736 点（UIScreen.bounds，默认）
    TDCoordModeNormalized = 1,   // 归一化 0.0~1.0
    TDCoordModePixel      = 2,   // 物理像素 1242×2208（点 × scale）
};

void TDSetCoordMode(NSInteger m);
NSInteger TDCoordModeCurrent(void);
NSString *TDCoordModeDesc(void);
/// 按当前模式把屏幕点坐标转成「要写进事件的坐标」，标定页用它做反推
CGPoint TDCoordToEventSpace(CGPoint p);
CGPoint TDScreenPointFromEventSpace(CGPoint e);

void TDSetInjectVariant(NSInteger v);
NSInteger TDInjectVariantCurrent(void);
void TDSetInjectBuiltIn(BOOL on);
BOOL TDInjectBuiltInOn(void);
/// BackBoardServices 的 digitizer 信息（可能崩，默认关，每次启动自动复位）
void TDSetInjectBKSDigitizerInfo(BOOL on);
BOOL TDInjectBKSDigitizerInfoOn(void);

/// 父事件坐标回退成 (0,0) 的旧写法。
/// 旧写法在抖音里会被当成「从左上角斜滑过来」的滑动手势；
/// 新写法是干净的 tap。只有在新写法完全点不动时才切回来验证链路。
BOOL TDInjectHandLegacy(void);
void TDSetInjectHandLegacy(BOOL on);

/// 父事件的 eventMask 是否写死成 kIOHIDDigitizerEventTouch（社区参考写法是写死的）
BOOL TDInjectParentMaskConst(void);
void TDSetInjectParentMaskConst(BOOL on);
/// down 与 up 之间是否补一帧静止 move
BOOL TDInjectStillMoveOn(void);
void TDSetInjectStillMove(BOOL on);

/// 事件构造组合：bit0 senderID(0 不设 / 1 硬编码)、bit1 父坐标(0 与子同点 / 1 回退 0,0)、
/// bit2 父 mask(0 透传 / 1 写死 Touch)、bit3 静止 move(0 有 / 1 无)。共 16 组。
void TDApplyInjectCombo(NSInteger combo);
NSString *TDInjectComboDesc(NSInteger combo);
NSInteger TDInjectComboCount(void);

void TDInjectResetToSafeDefaults(void);
uint64_t TDProbedSenderID(void);
NSString *TDInjectVariantDesc(void);

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

/// 托管窗口本体（录制取点层要挂到它的 rootViewController 上）
UIWindow * _Nullable TDFloatWindow(void);
/// 把托管窗口铺满全屏 / 缩回悬浮条（取点录制用）
void TDFloatSetFullScreen(BOOL on);
BOOL TDFloatIsFullScreen(void);

NS_ASSUME_NONNULL_END
