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

#pragma mark - 真实触摸轨迹（穿透录制的数据源）

/// 开始收集真实触摸轨迹。蒙版不收触摸，用户是在抖音里真操作，我们从监听里抄。
void TDHIDTraceStart(void);
void TDHIDTraceStop(void);
/// 已收集的样本数（含按下与抬起两种状态）
NSInteger TDHIDTraceCount(void);
/// 取第 i 个样本。坐标是原始值，量纲由调用方判定
BOOL TDHIDTraceAt(NSInteger i, CGFloat *x, CGFloat *y, double *t, BOOL *down);
/// mach_absolute_time 换算成秒（用于算手势时长）
double TDHIDTraceSeconds(uint64_t t);
/// 用已学到的真实事件判断坐标量纲：0 归一化 / 1 点 / 2 像素 / -1 未知
NSInteger TDHIDSampleSpace(void);

#pragma mark - 注入链路诊断

/// 一次性报告：客户端能否建立、HID 服务数、探到的 senderID、
/// 物理触摸监听状态、回显计数、关键权限是否真的在位。
NSString *TDHIDDiagReport(void);
/// 内核眼里的签名状态（platform 标志 / euid / csflags）。
/// entitlements 里有权限 ≠ 内核会放行，这一项是把两者分开看的唯一手段。
NSString *TDCodeSignReport(void);
/// 学到的那次真实触摸的坐标量纲（点 / 归一化 / 像素）+ identity + displayIntegrated。
/// 用真值替代猜测：不知道量纲就改注入，等于闭着眼睛调参。
NSString *TDHIDSampleGeometry(void);
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

#pragma mark - 触摸物理量（压力 / 半径 / 质量）

/// 改的是 finger 事件的 tipPressure / majorRadius / quality / density。
/// 发 pressure=0 等于告诉系统「一个没有按压力、面积为 0 的接触点」，
/// 很可能在过滤阶段就被当噪声丢掉。这一组参数可以单独扫，用来验证这个猜测。
void TDSetInjectTouchPhysics(CGFloat pressure, CGFloat radius,
                             CGFloat quality, CGFloat density);
NSString *TDInjectTouchPhysicsDesc(void);
/// 用监听学到的真实 senderID 当事件来源（不是猜的，是本机数字转换器的真值）
void TDSetInjectSampleSender(BOOL on);
BOOL TDInjectSampleSenderOn(void);
/// 记住扫描胜出的方案号，下次启动沿用（-1/未设置为没扫过）
void TDSetBestInjectPlan(NSInteger i);
NSInteger TDBestInjectPlan(void);

#pragma mark - 硬件按键（音量键）

/// 物理按键回调。usage: 0xE9 = 音量上，0xEA = 音量下。
/// 走的是 HID 监听（和触摸同一条），所以 App 在后台也收得到。
void TDSetHIDKeyHandler(void (^ _Nullable h)(NSInteger usage));
/// 收到过多少次按键事件（诊断用：一直是 0 说明这条路没通，得靠音量 KVO 兜底）
NSInteger TDHIDKeyEventCount(void);
NSInteger TDHIDLastKeyUsage(void);

/// 接管音量键：上 = 开始录制，下 = 停止并保存；同时把音量钉在接管时的值。
void TDKeysInstall(void);
NSString *TDKeysStatus(void);

#pragma mark - 键盘注入（粘贴用）

/// 发一个键盘事件。usage 用 HID keyboard page(0x07) 的 usage：
/// 0x19='v'，0xE3=左 Command，0xE1=左 Shift。
/// 走的是和触摸同一个 admin 客户端，所以前台 App 的「硬件键盘」通道能收到。
void TDsendKey(uint16_t usage, BOOL down);
/// Cmd+V：按下 Command → 按 v → 松 v → 松 Command。
/// 作用是把剪贴板内容粘进「当前有键盘焦点的输入框」（抖音评论框）。
void TDsendCmdV(void);
/// 键盘事件的「来源」用哪一种：0 不设 / 1 学到的真实触摸 senderID / 2 探测到的 senderID。
/// 这台机器的 HID 校验很严，哪个认就留哪个（评论池页可以现场切着试）。
NSInteger TDPasteVariant(void);
void TDSetPasteVariant(NSInteger v);
NSString *TDPasteVariantDesc(void);

#pragma mark - 评论池（话术）

/// 评论池存 Documents/comment_pool.txt，一行一条。读出来的都是去空白后的非空行。
NSArray<NSString *> *TDCommentPool(void);
void TDCommentPoolSet(NSArray<NSString *> *lines);
NSInteger TDCommentPoolCount(void);
/// 随机取一条。会尽量避免和上一条重复（连着发两句一样的话最像机器人）。
NSString *TDCommentPick(void);
/// 写剪贴板 → 等系统把剪贴板刷新出去 → 发 Cmd+V。
void TDPasteText(NSString *text);

#pragma mark - 内置模板
/// 把 bundle 里的内置识图模板（点赞 / 评论 / 收藏）装到 Documents。
/// 只在目标文件不存在时拷贝：用户删掉的不会被硬塞回来，但每版都会补新内置项。
void TDInstallBuiltinTemplates(void);

/// 这个模板是不是内置的（内置模板在库里排前面、显示中文名）
BOOL TDTplIsBuiltin(NSString * _Nullable file);

#pragma mark - 截屏

BOOL TDcaptureReady(void);
NSString *TDcaptureStatus(void);
UIImage * _Nullable TDscreenshot(void);
/// 屏幕点尺寸 / 像素尺寸 换算比
CGFloat TDscreenScaleRatio(void);

#pragma mark - 识图（模板匹配）

@class TDMatch;

TDMatch * _Nullable TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps);

/// 带尺度策略的识图：先按记住的尺度窄扫，再按原尺度，最后才做尺度扫描。
/// 模板像素和屏幕实际尺寸不一致时（内置小图标、相册压过的截图）靠这一层兜住。
/// tplName 用于记住/取回尺度，可传 nil（纯一次性匹配）；scanned 回填是否靠扫描命中。
TDMatch * _Nullable TDfindImageSmart(UIImage *tpl, NSString * _Nullable tplName,
                                    double threshold, BOOL * _Nullable scanned);

/// 读/写某个模板记住的尺度（1.0 = 原尺度，0 = 没记过）
double TDScaleHint(NSString * _Nullable tplName);
void TDSetScaleHint(NSString * _Nullable tplName, double scale);

@interface TDMatch : NSObject
@property (nonatomic) double score;
@property (nonatomic) CGPoint point;   // 匹配中心，屏幕点坐标
@property (nonatomic) CGFloat scale;
@end

#pragma mark - 脚本

/// 一条脚本 = 一串步骤，可以是「坐标步骤 + 识图步骤」混在一起的混合模式
/// 步骤格式（均带 gap：与上一步之间的间隔毫秒）：
///   {"t":"tap","x":207,"y":660,"gap":0}
///   {"t":"long","x":207,"y":660,"ms":800,"gap":0}
///   {"t":"swipe","x1":207,"y1":600,"x2":207,"y2":200,"ms":400,"gap":0}
///   {"t":"wait","ms":500,"gap":0}
///   {"t":"find","tpl":"tpl_1699.png","th":0.85,"dx":0,"dy":0,
///    "to":1500,"ms":0,"gap":0}        // 识图点击；ms>0 则按长按执行，to=超时毫秒
/// 每个步骤都可以带随机化参数：
///   {"rnd":{"p":1.0,"px":8,"pr":[0.3,1.0],"rd":[0.2,1.2],"ms":0.25,"gap":0.4}}
///   p  = 随机率 0~1（这一步有多大比例启用随机）
///   px = 位置随机半径（点，0 表示不随机）
///   pr = 压力范围（不开就不写这个键）
///   rd = 触摸半径范围（同上）
///   ms = 时长抖动比例（±ms×100%）
///   gap = 间隔抖动比例
/// 步骤本身还可以带 "run"：执行概率 0~1（小于 1 时这一步有机会整步跳过、不点）
///
/// v1.14 新增：
///   {"t":"paste","text":"","gap":300}   粘贴步骤。text 留空 = 从「评论池」里随机取一条，
///                                       走「写剪贴板 + Cmd+V」，所以前面的步骤要先点开输入框。
///
/// 脚本级还有两块配置（都可选，缺省等于关）：
///   loop     {"on":1,"count":5,"gap":800}   整套脚本循环几次（count=0 无限），每轮之间歇多久
///   failsafe {"on":1,"tpl":"","once":1,     判断：识图找不到时做什么
///             "steps":[ …同普通步骤… ]}      tpl 空 = 任意识图失败都算；steps 可带随机参数
@interface TDScript : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSTimeInterval createdAt;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *steps;
/// 识图找不到时的兜底动作
@property (nonatomic, strong) NSMutableDictionary *failsafe;
/// 整个脚本的循环设置
@property (nonatomic, strong) NSMutableDictionary *loop;

- (instancetype)initWithName:(NSString *)name;
- (NSString *)summary;                        // "12 步 · 0:35"
- (NSTimeInterval)duration;                   // 估算总时长（秒）
- (NSArray<NSDictionary *> *)engineSteps;     // 把 gap 展开成 wait
+ (NSString *)describeStep:(NSDictionary *)st;

- (BOOL)failsafeEnabled;
- (NSArray<NSDictionary *> *)failsafeSteps;
/// "不循环" / "循环 5 次" / "无限循环"
- (NSString *)loopDesc;
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

/// 脚本编辑页（混合模式）：一条脚本的全部步骤列成表，
/// 每行可改坐标、可切成识图、可单独设随机率与随机度。
/// 返回的是导航控制器，直接 present 即可。
UIViewController *TDCreateScriptEditVC(TDScript *script);

#pragma mark - 录制（全屏取点层，不依赖私有 HID 监听）

@interface TDRecorder : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) NSInteger eventCount;      // 已录到的步骤数
@property (nonatomic, readonly) NSInteger rawEventCount;   // 同上（保留兼容）
@property (nonatomic, copy, nullable) void (^onChange)(void);

/// 把托管窗口铺满全屏、盖上取点层。返回 NO 表示窗口没准备好
- (BOOL)start;
/// 穿透录制：不铺全屏、不拦触摸，靠监听抄真实触摸。边操作抖音边录
- (BOOL)startLive;
/// 结束录制，存成新脚本（唯一正常的收尾方式）
- (void)finishAndSave;
/// 录完不存成新脚本，直接把步骤交给这个回调 —— 「判断里录一段兜底动作」用它。
/// 只生效一次，回调完自动清空，之后的录制还是照常存成新脚本。
@property (nonatomic, copy, nullable) void (^onStepsReady)(NSArray<NSDictionary *> *steps);
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
/// 跑一条完整脚本：循环次数/每轮间隔/识图失败兜底 都按脚本自己的配置来。
/// 悬浮球 ▶、App 里 ▶、编辑页「试运行」全部走这一条。
- (void)playScript:(TDScript *)script;
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
/// 额外挂一路日志消费者（主界面日志框、悬浮窗日志面板各占一路）。
/// 和 TDSetLogHandler 是并存的：谁先挂都行，互不覆盖。
void TDAddLogTap(void (^ _Nullable h)(NSString *));

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
/// 悬浮条在屏幕上的可点区域。录制时用它把「按停止那一下」过滤掉，
/// 否则停止录制这个触摸本身会被录成脚本的最后一步。
CGRect TDFloatTouchRect(void);
/// 把托管窗口铺满全屏 / 缩回悬浮条（取点录制用）
void TDFloatSetFullScreen(BOOL on);
BOOL TDFloatIsFullScreen(void);

#pragma mark - 穿透录制蒙版

/// 全屏、完全不接触摸的叠加层：触摸原样穿到抖音，只把录到的轨迹画出来。
/// 它和取点层是两条路：取点层坐标准但挡住抖音，蒙版能边操作边看真实效果。
void TDMaskShow(void);
void TDMaskHide(void);
BOOL TDMaskVisible(void);
void TDMaskSetSteps(NSArray<NSDictionary *> * _Nullable steps);
void TDMaskSetHint(NSString * _Nullable hint);
void TDMaskSetLive(CGPoint p, BOOL on);

NS_ASSUME_NONNULL_END
