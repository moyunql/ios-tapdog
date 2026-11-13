#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#import <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>

// ---------------------------------------------------------------------------
// 全局触摸注入
//
// iOS 15 上要「点得动别的 App」，必须满足三条：
//   1) IOHIDEventSystemClient 用 admin 类型创建（CreateWithType(…,1,…)）。
//      普通 IOHIDEventSystemClientCreate 建出来的是 monitor 客户端，
//      DispatchEvent 进去要么被丢弃，要么直接在 IOKit 里崩掉 —— 这正是
//      之前「一点开始就闪退」的根源。
//   2) hand 事件 IsDisplayIntegrated=1，坐标用「点」（不是像素）。
//   3) finger 子事件也要带 DisplayIntegrated，且 range/touch 成对切换。
//
// 权限：com.apple.private.hid.client.event-dispatch
// ---------------------------------------------------------------------------

typedef IOHIDEventSystemClientRef (*TDCreateWithTypeFn)(CFAllocatorRef, uint32_t, void *);

static IOHIDEventSystemClientRef gClient = NULL;
static int gClientType = -1;          // 1=admin 0=fallback

// 点击反馈回调（TDFloat 实现），以及本次运行累计按下的次数
static TDInjectFeedbackFn gFeedback = NULL;
static volatile int32_t gInjectCount = 0;

void TDSetInjectFeedbackHandler(TDInjectFeedbackFn fn) { gFeedback = fn; }
NSInteger TDInjectCount(void) { return (NSInteger)gInjectCount; }

// 内建触摸屏的 senderID 前缀；后 32 位是 IORegistryEntryID，每台机器不一样，
// 所以硬编码只可能碰对，碰不对系统就当「来自不存在设备的事件」丢掉。
static const uint64_t kTDDefaultSenderID = 0x8000000817319372ULL;

// 注入参数方案（诊断页可切，见 TDInjectVC）
static NSString * const kInjVariantKey = @"tdInjVariant";
static NSString * const kInjBuiltInKey = @"tdInjBuiltIn";
static NSString * const kInjBKSKey     = @"tdInjBKS";
static NSString * const kCoordModeKey  = @"tdCoordMode";

#pragma mark - 坐标空间

// 事件里的 x/y 该填什么单位，各系统版本不一样。填错的表现非常典型：
// 系统把 207 当成 207.0(归一化) 直接 clamp 到 1.0 —— 于是无论点哪，
// 落点都在屏幕右下角。抖音右下角正好是 tab bar 最右的「我」。
static CGSize TDMainPointSize(void) {
    static CGSize s;
    static BOOL got = NO;
    if (!got) {
        s = [UIScreen mainScreen].bounds.size;
        if (s.width < 1 || s.height < 1) s = CGSizeMake(414, 736);
        got = YES;
    }
    return s;
}

NSInteger TDCoordModeCurrent(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kCoordModeKey] == nil) return TDCoordModePoint;
    return [d integerForKey:kCoordModeKey];
}

void TDSetCoordMode(NSInteger m) {
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:kCoordModeKey];
}

NSString *TDCoordModeDesc(void) {
    CGSize s = TDMainPointSize();
    switch (TDCoordModeCurrent()) {
        case TDCoordModeNormalized:
            return [NSString stringWithFormat:@"归一化 0~1（屏 %.0f×%.0f）", s.width, s.height];
        case TDCoordModePixel:
            return [NSString stringWithFormat:@"物理像素 ×%.0f（%.0f×%.0f）",
                    [UIScreen mainScreen].scale,
                    s.width * [UIScreen mainScreen].scale,
                    s.height * [UIScreen mainScreen].scale];
        default:
            return [NSString stringWithFormat:@"屏幕点 %.0f×%.0f", s.width, s.height];
    }
}

CGPoint TDCoordToEventSpace(CGPoint p) {
    CGSize s = TDMainPointSize();
    switch (TDCoordModeCurrent()) {
        case TDCoordModeNormalized:
            return CGPointMake(s.width > 0 ? p.x / s.width : 0,
                               s.height > 0 ? p.y / s.height : 0);
        case TDCoordModePixel: {
            CGFloat sc = [UIScreen mainScreen].scale;
            if (sc < 1) sc = 1;
            return CGPointMake(p.x * sc, p.y * sc);
        }
        default:
            return p;
    }
}

CGPoint TDScreenPointFromEventSpace(CGPoint e) {
    CGSize s = TDMainPointSize();
    switch (TDCoordModeCurrent()) {
        case TDCoordModeNormalized:
            return CGPointMake(e.x * s.width, e.y * s.height);
        case TDCoordModePixel: {
            CGFloat sc = [UIScreen mainScreen].scale;
            if (sc < 1) sc = 1;
            return CGPointMake(e.x / sc, e.y / sc);
        }
        default:
            return e;
    }
}

static uint64_t gProbedSender = 0;
static BOOL gProbedTried = NO;
static NSInteger gServiceCount = 0;

static IOHIDEventSystemClientRef TDhidClient(void);   // 定义在本文件后面

typedef CFArrayRef (*TDCopyServicesFn)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*TDServiceGetPropFn)(void *service, CFStringRef key);
typedef uint64_t (*TDServiceRegIDFn)(void *service);

static CFArrayRef TDCopyServicesOn(IOHIDEventSystemClientRef c) {
    if (!c) return NULL;
    TDCopyServicesFn fn = (TDCopyServicesFn)dlsym(RTLD_DEFAULT,
                                                 "IOHIDEventSystemClientCopyServices");
    if (!fn) return NULL;
    CFArrayRef a = fn(c);
    if (a && CFGetTypeID(a) != CFArrayGetTypeID()) { CFRelease(a); return NULL; }
    return a;
}

void TDProbeSenderIDReset(void) {
    gProbedSender = 0;
    gProbedTried = NO;
}

uint64_t TDProbedSenderIDCached(void) { return gProbedSender; }
uint64_t TDProbeSenderIDForce(void) {
    TDProbeSenderIDReset();
    return TDProbedSenderID();
}

/// 从 HID 服务列表里读真实 senderID。
///
/// 真机实测（iPhone 7 Plus / iOS 15.8.2）：物理触摸的 senderID 是 `0x10000053e`，
/// 也就是「0x1_00000000 | IORegistryEntryID」。社区流传的
/// `0x8000000817319372` 是别的机器上的值，写死在这台上必然被系统当成
/// 「来自不存在设备的事件」丢掉 —— 这正好解释了 16 组全灭。
uint64_t TDProbedSenderID(void) {
    if (gProbedTried) return gProbedSender;
    gProbedTried = YES;

    IOHIDEventSystemClientRef clients[2] = { TDhidClient(), NULL };
    TDServiceGetPropFn getProp =
        (TDServiceGetPropFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetProperty");
    TDServiceRegIDFn getRegID =
        (TDServiceRegIDFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");

    for (int ci = 0; ci < 2 && gProbedSender == 0; ci++) {
        CFArrayRef services = TDCopyServicesOn(clients[ci]);
        if (!services) continue;
        CFIndex n = CFArrayGetCount(services);
        if (ci == 0) gServiceCount = n;

        CFStringRef keys[] = { CFSTR("SenderID"), CFSTR("HIDSenderID"), CFSTR("senderID") };
        for (CFIndex i = 0; i < n && gProbedSender == 0; i++) {
            void *svc = (void *)CFArrayGetValueAtIndex(services, i);
            if (!svc) continue;
            if (getProp) {
                for (int k = 0; k < 3 && gProbedSender == 0; k++) {
                    CFTypeRef v = getProp(svc, keys[k]);
                    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) continue;
                    long long num = 0;
                    if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &num) && num != 0) {
                        gProbedSender = (uint64_t)num;
                    }
                }
            }
            // 属性读不到就按真机格式拼：0x1_00000000 | IORegistryEntryID
            if (gProbedSender == 0 && getRegID) {
                uint64_t rid = getRegID(svc);
                if (rid) gProbedSender = 0x100000000ULL | (rid & 0xffffffffULL);
            }
        }
        CFRelease(services);
    }
    return gProbedSender;
}

// BackBoardServices 的私有函数：告诉 BackBoard 这个 digitizer 事件属于哪块屏。
// iOS 13 之后没有它，事件进不了 WindowServer 的投递队列（绝大多数「注入了但没反应」就是这个）。
typedef void (*TDBKSSetDigitizerInfoFn)(IOHIDEventRef event,
                                        uint32_t contextID,
                                        uint32_t pathIndex,
                                        BOOL isDisplayIntegrated,
                                        CFStringRef displayUUID,
                                        double minXOrY,
                                        double maxXOrY);

static void TDApplyBKSDigitizerInfo(IOHIDEventRef event) {
    static TDBKSSetDigitizerInfoFn fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
               RTLD_LAZY | RTLD_GLOBAL);
        fn = (TDBKSSetDigitizerInfoFn)dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");
    }
    if (!fn) return;
    // contextID 给 0 = 让 BackBoard 用当前活动显示；displayUUID 给 NULL 同理
    fn(event, 0, 0, YES, NULL, 0.0, 0.0);
}

#pragma mark - 注入调试配置

void TDSetInjectVariant(NSInteger v) {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kInjVariantKey];
}
NSInteger TDInjectVariantCurrent(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // 默认用「监听学到的真实 senderID」：这是本机唯一确定合法的来源。
    // 还没学到时会自动退化成探测值，探测不到就等于不设，不会更糟。
    if ([d objectForKey:kInjVariantKey] == nil) return TDInjectVariantSampleSender;
    return [d integerForKey:kInjVariantKey];
}

void TDSetInjectBuiltIn(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kInjBuiltInKey];
}
BOOL TDInjectBuiltInOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kInjBuiltInKey];
}

void TDSetInjectBKSDigitizerInfo(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kInjBKSKey];
}
BOOL TDInjectBKSDigitizerInfoOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kInjBKSKey];
}

/// App 每次启动都回到「安全默认」：BKS 那步有崩溃风险，
/// 万一是它把 App 弄崩的，重开就自动关掉，不会连环崩。
void TDInjectResetToSafeDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:@"tdMigrated150"]) {
        [d setBool:YES forKey:@"tdMigrated150"];
        if ([d objectForKey:kInjVariantKey] == nil) {
            [d setInteger:TDInjectVariantSampleSender forKey:kInjVariantKey];
        }
    }
    // v1.8.0：真机实测结论 —— 第 2 组（v1.2.3 构造 + 本机真实 senderID）是唯一能点中的。
    // 现场数据：扫 14 组时，1/4/10（不设 sender）全灭；3（加了 BKS）和 9（父 mask 透传）也灭；
    // 2/5/6/7/8 全中，而且**先用手点一下屏幕之后，后面几组不碰屏幕也能中**。
    // 说明 senderID 是必要条件，并且它绑定在「当前 HID 会话」上，会话由物理触摸建立。
    // 所以默认值必须落在第 2 组，同时关掉「真实事件副本」那条路（那是第 14 组，没有 sender）。
    if (![d boolForKey:@"tdMigrated180"]) {
        [d setBool:YES forKey:@"tdMigrated180"];
        [d setInteger:1 forKey:@"tdPlanBest"];      // 1 = 第 2 组
        TDSetUseRealEvents(NO);
    }
    // 扫到过可用方案就沿用它（含 BKS 开关）；没扫过才回到「无 BKS」的保守状态
    if ([d objectForKey:@"tdPlanBest"] == nil) {
        TDSetInjectBKSDigitizerInfo(NO);
    } else {
        TDApplyInjectPlan([d integerForKey:@"tdPlanBest"]);
    }
}

void TDSetBestInjectPlan(NSInteger i) {
    [[NSUserDefaults standardUserDefaults] setInteger:i forKey:@"tdPlanBest"];
}
NSInteger TDBestInjectPlan(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"tdPlanBest"] == nil) return -1;
    return [d integerForKey:@"tdPlanBest"];
}

NSString *TDInjectVariantDesc(void) {
    NSInteger v = TDInjectVariantCurrent();
    NSString *s;
    if (v == TDInjectVariantHardSender) {
        s = @"硬编码 senderID";
    } else if (v == TDInjectVariantSampleSender) {
        uint64_t sid = TDHIDSampleSenderID();
        s = sid ? [NSString stringWithFormat:@"真实 senderID (0x%llx)", sid]
                : @"真实 senderID（还没学到，退化为探测值）";
    } else if (v == TDInjectVariantAutoSender) {
        uint64_t sid = TDProbedSenderID();
        s = sid ? [NSString stringWithFormat:@"自动 senderID (%llx)", sid]
                : @"自动 senderID（没探到，等同不设）";
    } else {
        s = @"不设 senderID";
    }
    if (TDInjectBuiltInOn()) s = [s stringByAppendingString:@" + IsBuiltIn"];
    if (TDInjectBKSDigitizerInfoOn()) s = [s stringByAppendingString:@" + BKS"];
    return s;
}

static void TDApplyInjectOptions(IOHIDEventRef hand) {
    uint64_t sid = 0;
    switch (TDInjectVariantCurrent()) {
        case TDInjectVariantHardSender:
            sid = kTDDefaultSenderID;
            break;
        case TDInjectVariantAutoSender:
            sid = TDProbedSenderID();
            break;
        case TDInjectVariantSampleSender:
            // 监听里抓到的、本机物理触摸的真实 senderID（真机上形如 0x10000053e）
            sid = TDHIDSampleSenderID();
            if (!sid) sid = TDProbedSenderID();
            break;
        default:
            break;
    }
    if (sid) {
        IOHIDEventSetSenderID(hand, sid);
        // 子事件也带上同一来源：部分系统版本按子事件判定「这次触摸是谁报的」
        CFArrayRef kids = IOHIDEventGetChildren(hand);
        if (kids) {
            for (CFIndex i = 0; i < CFArrayGetCount(kids); i++) {
                IOHIDEventSetSenderID((IOHIDEventRef)CFArrayGetValueAtIndex(kids, i), sid);
            }
        }
    }
    if (TDInjectBuiltInOn()) IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldIsBuiltIn, 1);
    if (TDInjectBKSDigitizerInfoOn()) TDApplyBKSDigitizerInfo(hand);
}

static IOHIDEventSystemClientRef TDhidClient(void) {
    if (gClient) return gClient;

    TDCreateWithTypeFn create = (TDCreateWithTypeFn)dlsym(RTLD_DEFAULT,
                                                           "IOHIDEventSystemClientCreateWithType");
    if (create) {
        // 1 = kIOHIDEventSystemClientTypeAdmin
        gClient = create(kCFAllocatorDefault, 1, NULL);
        if (gClient) gClientType = 1;
    }
    if (!gClient) {
        gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (gClient) gClientType = 0;
    }
    return gClient;
}

BOOL TDhidReady(void) { return TDhidClient() != NULL; }

// 普通（非 admin）客户端。admin 客户端可能只被允许「读事件」，
// 真正能 dispatch 的也许是普通客户端 —— 这一维也做成可扫的。
static IOHIDEventSystemClientRef gClientPlain = NULL;
static IOHIDEventSystemClientRef TDPlainClient(void) {
    if (!gClientPlain) gClientPlain = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    return gClientPlain;
}

// 方案指定的 dispatch 通道（NULL = 默认 admin 客户端）
static IOHIDEventSystemClientRef gDispatchClient = NULL;
static IOHIDEventSystemClientRef TDClientForDispatch(void) {
    if (gDispatchClient) return gDispatchClient;
    IOHIDEventSystemClientRef c = TDhidClient();
    return c ? c : TDPlainClient();
}

void TDSetInjectSampleSender(BOOL on) {
    if (on) TDSetInjectVariant(TDInjectVariantSampleSender);
    else if (TDInjectVariantCurrent() == TDInjectVariantSampleSender)
        TDSetInjectVariant(TDInjectVariantNoSender);
}
BOOL TDInjectSampleSenderOn(void) {
    return TDInjectVariantCurrent() == TDInjectVariantSampleSender;
}

NSString *TDhidStatus(void) {
    if (!TDhidClient()) {
        return @"失败：客户端建不起来（检查 HID 权限）";
    }
    return gClientType == 1 ? @"就绪（admin）" : @"就绪（兼容模式）";
}

// hand 父事件
//
// 这一段是照社区验证过的写法对齐的（SimulateTouch / TouchSimulator 系列）：
//   - 补 TiltX / TiltY / Altitude 三个字段，否则 BackBoard 认为这不是屏幕触摸
//   - finger 的 Major/MinorRadius 给 0.04（真实手指量级），给 0 会被当噪声丢掉
//
// 父事件要不要带坐标，两种写法在真机上表现完全不同：
//   带坐标（默认）→ 父与子同点，位移 0，是干净的 tap。
//   带 0,0（legacy）→ 系统拿父事件当起点、finger 当终点，一次 tap 变成
//                      「从左上角斜滑到点击点」，抖音会当滑动手势吃掉。
// 万一新版反过来导致点不动，可以临时切回 legacy 确认链路。
static NSString * const kHandLegacyKey = @"tdHandLegacy";

BOOL TDInjectHandLegacy(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kHandLegacyKey];
}
void TDSetInjectHandLegacy(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kHandLegacyKey];
}

// v1.2.3 是唯一一次「事件真的进到抖音」的版本（表现为点中间却跳到「我的」，
// 也就是一次从 (0,0) 斜滑到目标点的 swipe）。之后几版把它「修对了」，
// 结果反而一点反应都没有。所以这些构造细节全部做成开关，逐条复刻对比：
static BOOL gLegacyParent  = NO;    // 父事件坐标回退 (0,0)
static BOOL gParentRange1  = YES;   // 父事件 range=1（v1.2.3 是 0）
static BOOL gFixedIdentity = NO;    // identity 恒为 3（v1.2.3 是固定 3）
static BOOL gSetTypeField = YES;    // 给 hand/finger 补 DigitizerType（v1.2.3 没补）
static BOOL gExplicitXY   = YES;    // finger 显式 SetFloatValue X/Y（v1.2.3 只靠构造参数）

static NSString * const kParentMaskConstKey = @"tdParentMaskConst";
static NSString * const kStillMoveKey       = @"tdStillMove";

BOOL TDInjectParentMaskConst(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kParentMaskConstKey];
}
void TDSetInjectParentMaskConst(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kParentMaskConstKey];
}
BOOL TDInjectStillMoveOn(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kStillMoveKey] == nil) return YES;   // 默认补一帧
    return [d boolForKey:kStillMoveKey];
}
void TDSetInjectStillMove(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kStillMoveKey];
}

NSInteger TDInjectComboCount(void) { return 16; }

void TDApplyInjectCombo(NSInteger c) {
    TDSetInjectVariant((c & 1) ? TDInjectVariantHardSender : TDInjectVariantNoSender);
    TDSetInjectHandLegacy((c & 2) ? YES : NO);
    TDSetInjectParentMaskConst((c & 4) ? YES : NO);
    TDSetInjectStillMove((c & 8) ? NO : YES);
    // 扫描只动这四个维度，BKS / IsBuiltIn 先关掉，避免互相干扰
    TDSetInjectBKSDigitizerInfo(NO);
    TDSetInjectBuiltIn(NO);
}

NSString *TDInjectComboDesc(NSInteger c) {
    return [NSString stringWithFormat:@"%@ · 父坐标%@ · 父mask%@ · %@",
            (c & 1) ? @"硬senderID" : @"不设senderID",
            (c & 2) ? @"0,0" : @"同点",
            (c & 4) ? @"写死Touch" : @"透传",
            (c & 8) ? @"无move帧" : @"有move帧"];
}

static IOHIDEventRef TDCreateHand(uint32_t mask, uint64_t ts, CGPoint e, BOOL touch,
                                  uint32_t identity) {
    BOOL legacy = TDInjectHandLegacy() || gLegacyParent;
    uint32_t handMask = (legacy || TDInjectParentMaskConst()) ? kIOHIDDigitizerEventTouch : mask;
    // 注意 range / touch 这两个参数在这里**必须恒为 1/true**。
    // hand 是「这只手」，tap 期间手一直在屏幕上；只有 finger 子事件才在 up 时离开。
    // 之前跟着 touch 一起变 0，结果是 up 事件不被系统接受 —— 手指永远释放不掉，
    // 屏幕上留一个幽灵按压点，之后连真人手点都点不动（整机卡住）。
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                       ts,
                                                       kIOHIDDigitizerTransducerTypeHand,
                                                       0, identity,
                                                       legacy ? kIOHIDDigitizerEventTouch : handMask,
                                                       0,
                                                       legacy ? 0.0 : (IOHIDFloat)e.x,
                                                       legacy ? 0.0 : (IOHIDFloat)e.y,
                                                       0.0, 0.0, 0.0,
                                                       gParentRange1 ? 1 : 0,   // range
                                                       true,                    // touch
                                                       0);
    (void)touch;
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    if (gSetTypeField) {
        IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerType,
                                  kIOHIDDigitizerTransducerTypeHand);
    }
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltX,
                              kIOHIDDigitizerTransducerTypeHand);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltY, 1);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerAltitude, 1);
    return hand;
}

// 当前还按在屏幕上的那根手指。up 一旦丢了，靠它把手指收回来。
static volatile uint32_t gActiveIdentity = 0;
static CGFloat gActiveX = 0, gActiveY = 0;

// 每次手势用一个新的 identity。
// 固定 identity 时，只要有一次 up 没被系统收下，后面所有 down 都会被当成
// 「同一根手指继续按着」，于是再也点不动 —— 递增最省事也最接近真实。
static volatile uint32_t gFingerSeq = 1;
static uint32_t TDNextIdentity(void) { return ++gFingerSeq; }

#pragma mark - 触摸物理量（压力 / 半径 / 质量）

// 这几个数决定「这一下像不像真手指」。
// 我们原来一直发 pressure=0、radius=0.04、quality=0、density=0：
// 在系统看来是一根「面积为 0、没有按压力、质量未知」的接触点，
// 完全可以在触摸过滤阶段被当噪声丢掉 —— 表现就是事件发出去了，窗口没收到。
// 真手指大致是 pressure 0.6~1.0、majorRadius 几个单位（视驱动标定）。
static IOHIDFloat gPressPressure = 0.0f;
static IOHIDFloat gPressRadius   = 0.04f;
static IOHIDFloat gPressQuality  = 0.0f;
static IOHIDFloat gPressDensity  = 0.0f;

void TDSetInjectTouchPhysics(CGFloat pressure, CGFloat radius,
                             CGFloat quality, CGFloat density) {
    gPressPressure = pressure;
    gPressRadius   = radius;
    gPressQuality  = quality;
    gPressDensity  = density;
}

NSString *TDInjectTouchPhysicsDesc(void) {
    return [NSString stringWithFormat:@"压力%.2f 半径%.2f 质量%.0f/%.0f",
            (double)gPressPressure, (double)gPressRadius,
            (double)gPressQuality, (double)gPressDensity];
}

// mask: kIOHIDDigitizerEvent* 位组合；touch: 当前是否接触屏幕
static void TDEmit(uint32_t mask, BOOL touch, CGFloat x, CGFloat y, uint32_t identity) {
    if (gFixedIdentity) identity = 3;      // v1.2.3 的写法：identity 恒为 3
    IOHIDEventSystemClientRef client = TDClientForDispatch();
    if (!client) return;

    // 点击反馈挪到手势发完之后（见 TDShowFeedback）：
    // 原来在 down 之前就弹/挪反馈窗口，等于在中间插了一次 SpringBoard 窗口注册，
    // WindowServer 侧的事件队列被打断过，tap 这种对时序敏感的序列就没了。
    BOOL isDown = (mask & kIOHIDDigitizerEventTouch) && touch;
    if (isDown) __sync_fetch_and_add(&gInjectCount, 1);

    // 记下「当前按着的那根手指」，up 丢了随时能收回来
    if (isDown) {
        gActiveIdentity = identity;
        gActiveX = x;
        gActiveY = y;
    } else if (!touch && (mask & kIOHIDDigitizerEventTouch)) {
        gActiveIdentity = 0;
    }

    // 屏幕点 → 事件坐标空间（点 / 归一化 / 像素）
    CGPoint e = TDCoordToEventSpace(CGPointMake(x, y));

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef hand = TDCreateHand(mask, ts, e, touch, identity);
    if (!hand) return;

    int isTouch = touch ? 1 : 0;
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                               ts,
                                                               1,          // index
                                                               identity,   // identity
                                                               mask,
                                                               (IOHIDFloat)e.x,
                                                               (IOHIDFloat)e.y,
                                                               0.0f,             // z
                                                               gPressPressure,   // tipPressure（原来恒 0）
                                                               0.0f,             // twist
                                                               isTouch,   // range
                                                               isTouch,   // touch
                                                               0);
    if (finger) {
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        if (gSetTypeField) {
            IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerType,
                                      kIOHIDDigitizerTransducerTypeFinger);
        }
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerTouch, isTouch);
        if (gExplicitXY) {
            IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerX, (IOHIDFloat)e.x);
            IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerY, (IOHIDFloat)e.y);
        }
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMajorRadius, gPressRadius);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMinorRadius, gPressRadius);
        if (gPressQuality != 0.0f) {
            IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerQuality, gPressQuality);
        }
        if (gPressDensity != 0.0f) {
            IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerDensity, gPressDensity);
        }
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerPressure, gPressPressure);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    TDApplyInjectOptions(hand);
    IOHIDEventSystemClientDispatchEvent(client, hand);
    CFRelease(hand);
}

static const uint32_t kMaskDown = (kIOHIDDigitizerEventTouch |
                                   kIOHIDDigitizerEventRange |
                                   kIOHIDDigitizerEventPosition);
static const uint32_t kMaskMove = kIOHIDDigitizerEventPosition;
static const uint32_t kMaskUp   = (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);

// 手势整段发完之后再画红圈。注入期间屏幕上不能有任何窗口增删，
// 否则 WindowServer 会对正在投递的序列重新排队，down/up 就被拆散了。
static void TDShowFeedback(CGFloat x, CGFloat y) {
    TDInjectFeedbackFn fn = gFeedback;
    if (!fn) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fn(x, y, YES);
    });
}

void TDReleaseStuckTouch(void) {
    uint32_t ident = gActiveIdentity;
    if (ident == 0) return;
    CGFloat x = gActiveX, y = gActiveY;
    // 同一个 identity 连发几次 up，直到系统认下来
    for (int i = 0; i < 3; i++) {
        TDEmit(kMaskUp, NO, x, y, ident);
        usleep(25000);
    }
    gActiveIdentity = 0;
}

BOOL TDHasStuckTouch(void) { return gActiveIdentity != 0; }

// 盲扫一次抬起：把可能残留的「幽灵手指」全部收回来。
// 上一版 up 被系统丢掉时，那根手指会一直按着，整机连真人点按都失灵；
// 重启 App 时不知道当时用的是哪个 identity，只能一个个试。
void TDReleaseAllTouches(void) {
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat cx = s.width / 2, cy = s.height / 2;
    for (uint32_t i = 1; i <= 64; i++) {
        TDEmit(kMaskUp, NO, cx, cy, i);
        usleep(3000);
    }
    gActiveIdentity = 0;
}

// ---------------------------------------------------------------------------
// 真实事件采样（照 AutoTap 的做法）
//
// 逆向 AutoTap_v1.0.3 的二进制，注入链是：
//   IOHIDEventSystemClientRegisterEventFilterBlock / RegisterEventCallback 先监听
//   物理触摸 → IOHIDEventCreateCopy 复制一份 → 改坐标/时间戳 → IOHIDEventSetSenderID
//   → BKSHIDEventSetDigitizerInfo → DispatchEvent。
// 它甚至有个校验方法 senderBelongsToCurrentSession: —— 说明系统会核对
// **senderID 是不是本会话里的真实数字转换器**。自己凭空造的 senderID 必然过不了，
// 这也是我们前面十几版都点不动的原因：事件字段齐不齐是次要的，关键是「来路」。
//
// 所以这里改成：让用户用手在屏幕上点一下，把那次真实事件（down / up）复制下来存档，
// 之后每一次注入都是「真实事件改坐标」，senderID 和全部隐藏字段天然一致。
// ---------------------------------------------------------------------------

static NSString * const kUseRealEventsKey = @"tdUseRealEvents";

BOOL TDUseRealEvents(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kUseRealEventsKey] == nil) return YES;
    return [d boolForKey:kUseRealEventsKey];
}
void TDSetUseRealEvents(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kUseRealEventsKey];
}

static IOHIDEventSystemClientRef gMon = NULL;
static IOHIDEventRef gSampleDown = NULL;
static IOHIDEventRef gSampleUp = NULL;
static uint64_t gSampleSender = 0;
static volatile int gSampleLock = 0;

// 诊断计数器：监听到的 digitizer 事件总数 + 「注入期间回显到的事件数」。
// 这两个数字把失败拆成两类，不用再猜：
//   回显 = 0  → 事件压根没进 HID 系统（dispatch 被拦：权限 / 客户端类型 / senderID 不合法）
//   回显 > 0  → 事件进了系统，但没路由到前台 App（display / context 信息不对）
static volatile int32_t gMonTotal = 0;
static volatile int32_t gEchoCount = 0;
static volatile int gEchoActive = 0;

// 物理按键（音量键）这条路和触摸共用同一个监听客户端。
// 有它就不用去 KVO 音量、也不用真的让音量变化 —— App 在后台照样收得到。
static void (^gKeyHandler)(NSInteger usage) = NULL;
static volatile int32_t gKeyCount = 0;
static volatile int32_t gKeyLastUsage = 0;

void TDSetHIDKeyHandler(void (^h)(NSInteger usage)) {
    gKeyHandler = [h copy];
}
NSInteger TDHIDKeyEventCount(void) { return (NSInteger)gKeyCount; }
NSInteger TDHIDLastKeyUsage(void) { return (NSInteger)gKeyLastUsage; }

void TDHIDEchoReset(void) { gEchoCount = 0; gEchoActive = 1; }
void TDHIDEchoStop(void) { gEchoActive = 0; }
NSInteger TDHIDMonitorEchoCount(void) { return (NSInteger)gEchoCount; }
NSInteger TDHIDMonitorCount(void) { return (NSInteger)gMonTotal; }

static void TDSampleLock(void) { while (__sync_lock_test_and_set(&gSampleLock, 1)) usleep(200); }
static void TDSampleUnlock(void) { __sync_lock_release(&gSampleLock); }

// 父事件下面的第一个数字转换器子事件（手指）
static IOHIDEventRef TDFingerOf(IOHIDEventRef hand) {
    CFArrayRef kids = IOHIDEventGetChildren(hand);
    if (!kids) return NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(kids); i++) {
        IOHIDEventRef k = (IOHIDEventRef)CFArrayGetValueAtIndex(kids, i);
        if (IOHIDEventGetType(k) == kIOHIDEventTypeDigitizer) return k;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// 真实触摸轨迹录制（「穿透录制」的数据源）
//
// 为什么要这条：之前录制靠「把自己的窗口铺满全屏去接触摸」，好处是坐标准，
// 坏处是抖音被我们挡死、录的时候看不见真实的翻页效果。
//
// 现在换一条：蒙版窗口 _ignoresHitTest 恒 YES，触摸全穿透到抖音，
// 用户在抖音里真操作，我们从 HID 监听里把同一批触摸抄下来。
//
// 线程：回调是 ScheduleWithRunLoop(main) 驱动的，和 UI 定时器同一条线程，
// 所以下面的缓冲不需要锁 —— 写只发生在回调里，读只发生在定时器里。
//
// 坐标：原样存。量纲（归一化/点/像素）由读端按「出现过的最大值」判断，
// 和 TDHIDSampleGeometry 用的是同一套规则。
// ---------------------------------------------------------------------------

#define TD_TR_MAX 8192

typedef struct {
    float    x, y;      // 原始值，量纲未定
    uint64_t ts;        // mach_absolute_time
    uint8_t  down;      // 1 = 手指在屏上，0 = 抬起
} TDTrSample;

static TDTrSample gTr[TD_TR_MAX];
static volatile int32_t gTrN = 0;
static volatile int32_t gTrOn = 0;

void TDHIDTraceStart(void) { gTrN = 0; gTrOn = 1; }

void TDHIDTraceStop(void) { gTrOn = 0; }

NSInteger TDHIDTraceCount(void) { return (NSInteger)gTrN; }

BOOL TDHIDTraceAt(NSInteger i, CGFloat *x, CGFloat *y, double *t, BOOL *down) {
    if (i < 0 || i >= (NSInteger)gTrN) return NO;
    TDTrSample s = gTr[i];
    if (x)    *x = (CGFloat)s.x;
    if (y)    *y = (CGFloat)s.y;
    if (t)    *t = (double)s.ts;
    if (down) *down = (s.down != 0);
    return YES;
}

/// mach_absolute_time 的单换算成秒
double TDHIDTraceSeconds(uint64_t t) {
    static double k = 0;
    if (k == 0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        k = (double)tb.numer / (double)tb.denom / 1e9;
    }
    return (double)t * k;
}

/// 纯 C：不碰 ObjC、不动 UIKit
static void TDSampleHandler(void *target, void *refcon, IOHIDEventQueueRef q, IOHIDEventRef e) {
    if (!e) return;

    // 物理按键：音量上 0xE9 / 音量下 0xEA（HID consumer page）。
    // mask 非 0 表示按下；松手那一帧不再触发，免得一次按键算两回。
    if (IOHIDEventGetType(e) == kIOHIDEventTypeButton) {
        uint32_t num  = (uint32_t)IOHIDEventGetIntegerValue(e, kIOHIDEventFieldButtonNumber);
        uint32_t mask = (uint32_t)IOHIDEventGetIntegerValue(e, kIOHIDEventFieldButtonMask);
        gKeyLastUsage = (int32_t)num;
        if (mask != 0) {
            __sync_fetch_and_add(&gKeyCount, 1);
            void (^h)(NSInteger) = gKeyHandler;
            if (h) h((NSInteger)num);
        }
        return;
    }

    if (IOHIDEventGetType(e) != kIOHIDEventTypeDigitizer) return;
    __sync_fetch_and_add(&gMonTotal, 1);
    if (gEchoActive) __sync_fetch_and_add(&gEchoCount, 1);
    IOHIDEventRef finger = TDFingerOf(e);
    if (!finger) return;

    int touching = IOHIDEventGetIntegerValue(finger, kIOHIDEventFieldDigitizerTouch);
    IOHIDEventRef copy = IOHIDEventCreateCopy(kCFAllocatorDefault, e);
    if (!copy) return;

    TDSampleLock();
    if (touching) {
        if (gSampleDown) CFRelease(gSampleDown);
        gSampleDown = copy;
    } else {
        if (gSampleUp) CFRelease(gSampleUp);
        gSampleUp = copy;
    }
    gSampleSender = IOHIDEventGetSenderID(e);
    TDSampleUnlock();

    // 轨迹录制：手指停着不动时 120Hz 也在刷同样的坐标，全存下来几秒就灌满 8192，
    // 所以位置和接触状态都没变就跳过（抬手那一下状态一定变，不会被跳掉）。
    if (!gTrOn) return;
    float tx = (float)IOHIDEventGetFloatValue(finger, kIOHIDEventFieldDigitizerX);
    float ty = (float)IOHIDEventGetFloatValue(finger, kIOHIDEventFieldDigitizerY);
    int i = gTrN;
    if (i > 0) {
        TDTrSample prev = gTr[i - 1];
        if (prev.x == tx && prev.y == ty && prev.down == (touching ? 1 : 0)) return;
    }
    if (i >= TD_TR_MAX) return;
    gTr[i].x = tx;
    gTr[i].y = ty;
    gTr[i].ts = IOHIDEventGetTimeStamp(e);
    gTr[i].down = touching ? 1 : 0;
    gTrN = i + 1;
}


BOOL TDHIDSampleStart(void) {
    if (gMon) return YES;
    gMon = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gMon) return NO;
    IOHIDEventSystemClientRegisterEventCallback(gMon, TDSampleHandler, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gMon, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    return YES;
}

void TDHIDSampleStop(void) {
    if (!gMon) return;
    IOHIDEventSystemClientUnregisterEventCallback(gMon);
    IOHIDEventSystemClientUnscheduleWithRunLoop(gMon, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(gMon);
    gMon = NULL;
}

BOOL TDHIDSampleReady(void) {
    TDSampleLock();
    BOOL ok = (gSampleDown != NULL);
    TDSampleUnlock();
    return ok;
}

BOOL TDHIDSampleHasUp(void) {
    TDSampleLock();
    BOOL ok = (gSampleUp != NULL);
    TDSampleUnlock();
    return ok;
}

uint64_t TDHIDSampleSenderID(void) { return gSampleSender; }

NSInteger TDHIDSampleSpace(void) {
    TDSampleLock();
    IOHIDEventRef down = gSampleDown ? (IOHIDEventRef)CFRetain(gSampleDown) : NULL;
    TDSampleUnlock();
    if (!down) return -1;
    IOHIDEventRef f = TDFingerOf(down);
    IOHIDFloat fx = f ? IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerX) : 0;
    IOHIDFloat fy = f ? IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerY) : 0;
    CFRelease(down);
    if (fx == 0 && fy == 0) return -1;

    CGSize scr = TDMainPointSize();
    CGFloat m = MAX((CGFloat)fx, (CGFloat)fy);
    if (m <= 1.001f) return 0;                                   // 归一化
    if (m <= MAX(scr.width, scr.height) + 1) return 1;           // 点
    return 2;                                                    // 像素
}

/// 把存档的真实事件复制一份，换掉坐标和时间戳再发出去
static void TDReplayOne(IOHIDEventRef tmpl, CGFloat x, CGFloat y, BOOL down) {
    if (!tmpl) return;
    IOHIDEventRef e = IOHIDEventCreateCopy(kCFAllocatorDefault, tmpl);
    if (!e) return;

    uint64_t ts = mach_absolute_time();
    IOHIDEventSetTimeStamp(e, ts);
    IOHIDEventSetFloatValue(e, kIOHIDEventFieldDigitizerX, (IOHIDFloat)x);
    IOHIDEventSetFloatValue(e, kIOHIDEventFieldDigitizerY, (IOHIDFloat)y);
    IOHIDEventSetIntegerValue(e, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    CFArrayRef kids = IOHIDEventGetChildren(e);
    if (kids) {
        for (CFIndex i = 0; i < CFArrayGetCount(kids); i++) {
            IOHIDEventRef k = (IOHIDEventRef)CFArrayGetValueAtIndex(kids, i);
            IOHIDEventSetTimeStamp(k, ts);
            IOHIDEventSetFloatValue(k, kIOHIDEventFieldDigitizerX, (IOHIDFloat)x);
            IOHIDEventSetFloatValue(k, kIOHIDEventFieldDigitizerY, (IOHIDFloat)y);
            IOHIDEventSetIntegerValue(k, kIOHIDEventFieldDigitizerTouch, down ? 1 : 0);
            IOHIDEventSetIntegerValue(k, kIOHIDEventFieldDigitizerRange, down ? 1 : 0);
            IOHIDEventSetIntegerValue(k, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        }
    }

    // 父事件：「手」始终在屏幕上（和真实触摸一致），否则 up 会被拒、手指卡死
    IOHIDEventSetIntegerValue(e, kIOHIDEventFieldDigitizerTouch, 1);
    IOHIDEventSetIntegerValue(e, kIOHIDEventFieldDigitizerRange, 1);

    if (gSampleSender) IOHIDEventSetSenderID(e, gSampleSender);
    if (TDInjectBKSDigitizerInfoOn()) TDApplyBKSDigitizerInfo(e);

    IOHIDEventSystemClientRef c = TDClientForDispatch();
    if (c) IOHIDEventSystemClientDispatchEvent(c, e);
    CFRelease(e);
}

void TDHIDReplayTap(CGPoint p) {
    TDSampleLock();
    IOHIDEventRef down = gSampleDown ? (IOHIDEventRef)CFRetain(gSampleDown) : NULL;
    IOHIDEventRef up = gSampleUp ? (IOHIDEventRef)CFRetain(gSampleUp) : (down ? (IOHIDEventRef)CFRetain(down) : NULL);
    TDSampleUnlock();
    if (!down) return;

    TDReplayOne(down, p.x, p.y, YES);
    usleep(45000);
    TDReplayOne(up, p.x, p.y, NO);

    CFRelease(down);
    if (up) CFRelease(up);
}

// 自己拼出来的事件（hand + finger）。方案扫描和兜底都走这里。
static void TDSynthTap(CGFloat x, CGFloat y) {
    uint32_t ident = TDNextIdentity();
    TDEmit(kMaskDown, YES, x, y, ident);
    // 一帧静止 move：真实触摸在按住期间 HID 也会持续上报位置，
    // 完全不给 move 帧时部分版本认不出这是一次 tap。
    usleep(30000);
    if (TDInjectStillMoveOn()) TDEmit(kMaskMove, YES, x, y, ident);
    usleep(50000);
    TDEmit(kMaskUp, NO, x, y, ident);
}

// 上一次注入点下去的位置。
// 粘贴（长按弹菜单那种）需要一个「落点」——输入框在哪儿。脚本里点评论框那一下
// 就是最好的锚点，所以每注入一次就记一下，粘贴步骤直接拿来用。
static CGPoint gLastTapPt = {0, 0};
static BOOL gLastTapOK = NO;

CGPoint TDLastTapPoint(void) { return gLastTapPt; }
BOOL TDLastTapPointReady(void) { return gLastTapOK; }
void TDSetLastTapPoint(CGPoint p) { gLastTapPt = p; gLastTapOK = YES; }

void TDtap(CGFloat x, CGFloat y) {
    gLastTapPt = CGPointMake(x, y);
    gLastTapOK = YES;
    // 学到过真实触摸时优先走「真实事件副本」这条路：
    // 物理事件的字段（senderID、quality、pressure、display 信息…）全都齐，
    // 系统不会当成伪造输入丢掉；我们自己拼的那份永远缺东西。
    if (TDHIDSampleReady() && TDUseRealEvents()) {
        TDHIDReplayTap(CGPointMake(x, y));
        TDShowFeedback(x, y);
        return;
    }
    TDSynthTap(x, y);
    TDShowFeedback(x, y);
}

void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec) {
    gLastTapPt = CGPointMake(x, y);
    gLastTapOK = YES;
    uint32_t ident = TDNextIdentity();
    TDEmit(kMaskDown, YES, x, y, ident);
    NSTimeInterval d = sec > 0 ? sec : 0.8;
    NSInteger frames = (NSInteger)(d / 0.12);
    for (NSInteger i = 1; i <= frames; i++) {
        usleep((useconds_t)(0.12 * 1000000));
        TDEmit(kMaskMove, YES, x, y, ident);
    }
    NSTimeInterval rest = d - frames * 0.12;
    if (rest > 0) usleep((useconds_t)(rest * 1000000));
    TDEmit(kMaskUp, NO, x, y, ident);
    TDShowFeedback(x, y);
}

void TDgesture(NSArray<NSValue *> *points, NSTimeInterval sec) {
    NSInteger n = (NSInteger)points.count;
    if (n < 2) return;

    CGSize sb = [UIScreen mainScreen].bounds.size;
    if (sb.width < 1 || sb.height < 1) return;

    // 累计弧长：多点轨迹按「已经走过的距离」采样。
    // 旧写法是每段各自算帧数、段内 sleep 又除以段数，多点时实际总时长
    // 会缩水一大半，手感像被弹了一下。
    CGFloat *acc = (CGFloat *)calloc((size_t)n, sizeof(CGFloat));
    if (!acc) return;
    for (NSInteger i = 1; i < n; i++) {
        CGPoint a = [points[i - 1] CGPointValue];
        CGPoint b = [points[i] CGPointValue];
        acc[i] = acc[i - 1] + (CGFloat)hypot(b.x - a.x, b.y - a.y);
    }
    CGFloat totalLen = acc[n - 1];
    if (totalLen < 3) { free(acc); return; }   // 基本没动，按点击处理更合适

    // 时长太短会被当成「轻扫」判无效，太长又像拖拽。真实翻页 0.2~0.6s。
    NSTimeInterval total = sec;
    if (!(total > 0)) total = 0.35;
    total = MAX(0.15, MIN(1.2, total));

    const NSTimeInterval kFrame = 0.008;       // 125Hz，贴近真实触摸采样率
    NSInteger frames = (NSInteger)(total / kFrame + 0.5);
    frames = MAX(8, MIN(150, frames));

    uint32_t ident = TDNextIdentity();
    CGPoint first = [points[0] CGPointValue];
    TDEmit(kMaskDown, YES, first.x, first.y, ident);

    // 按下后的十几毫秒手指其实没动。补一帧原地 move，
    // 让系统先建立「这根手指处于移动中」的序列，再开始跳坐标。
    usleep(16000);
    TDEmit(kMaskMove, YES, first.x, first.y, ident);

    // 速度曲线：前 22% 加速，其余匀速。
    // 末端绝不能减速到 0 —— 抖音靠抬手瞬间的位移速度判翻页，
    // 一停就变成「拖到一半松手」，页面只会回弹。
    // 所以最后一帧停在 97%，剩下 3% 交给 up 那一下完成。
    const CGFloat kAccel = 0.22f;
    const CGFloat kEndP  = 0.97f;

    for (NSInteger f = 1; f <= frames; f++) {
        CGFloat t = (CGFloat)f / (CGFloat)frames;
        CGFloat p;
        if (t <= kAccel) {
            CGFloat u = t / kAccel;
            p = kAccel * u * u;
        } else {
            p = kAccel + (1.0f - kAccel) * ((t - kAccel) / (1.0f - kAccel));
        }
        if (p > kEndP) p = kEndP;

        CGFloat want = totalLen * p;
        NSInteger seg = 1;
        while (seg < n - 1 && acc[seg] < want) seg++;
        CGFloat segLen = acc[seg] - acc[seg - 1];
        CGFloat k = segLen > 0.5f ? (want - acc[seg - 1]) / segLen : 1.0f;
        CGPoint a = [points[seg - 1] CGPointValue];
        CGPoint b = [points[seg] CGPointValue];

        CGFloat x = a.x + (b.x - a.x) * k;
        CGFloat y = a.y + (b.y - a.y) * k;
        x = MAX(0, MIN(sb.width  - 1, x));
        y = MAX(0, MIN(sb.height - 1, y));

        TDEmit(kMaskMove, YES, x, y, ident);
        usleep((useconds_t)(kFrame * 1000000));
    }

    CGPoint last = [points[n - 1] CGPointValue];
    last.x = MAX(0, MIN(sb.width  - 1, last.x));
    last.y = MAX(0, MIN(sb.height - 1, last.y));
    TDEmit(kMaskUp, NO, last.x, last.y, ident);
    free(acc);

    TDShowFeedback(last.x, last.y);
}

void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec) {
    TDgesture(@[[NSValue valueWithCGPoint:from], [NSValue valueWithCGPoint:to]], sec);
}


// ---------------------------------------------------------------------------
// 键盘事件（粘贴评论用）
//
// 抖音的评论框是别的进程，改不到它的 UITextView；但「硬件键盘」这条通道是系统级的：
// 只要前台 App 的输入框有焦点，一条 Cmd+V 就会被 UIKit 翻成 paste:，把剪贴板贴进去。
// 所以我们只做两件事：写剪贴板 + 发 Cmd+V，剩下的交给系统。
//
// 构造用 IOHIDEventCreateKeyboardEvent(page=0x07, usage)，修饰键单独发一条
// （0xE3 = 左 Command），就像真键盘一样成对按下/抬起 —— 只发 v 是打不出粘贴的。
// ---------------------------------------------------------------------------

static NSString * const kPasteVariantKey = @"tdPasteVariant";

NSInteger TDPasteVariant(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteVariantKey] == nil) return 0;
    return [d integerForKey:kPasteVariantKey];
}

void TDSetPasteVariant(NSInteger v) {
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:kPasteVariantKey];
}

NSString *TDPasteVariantDesc(void) {
    switch (TDPasteVariant()) {
        case 1:  return @"真实触摸来源";
        case 2:  return @"探测来源";
        default: return @"不设来源";
    }
}

void TDsendKey(uint16_t usage, BOOL down) {
    IOHIDEventSystemClientRef c = TDClientForDispatch();
    if (!c) return;
    uint64_t ts = mach_absolute_time();
    IOHIDEventRef e = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, ts,
                                                    0x07, usage, down ? true : false, 0);
    if (!e) return;

    // 来源：先不设（真键盘事件本来就不属于触摸屏那个 sender），
    // 认不了就在评论池页切成 1/2 再试 —— 这台机器上哪条通只有试了才知道。
    NSInteger v = TDPasteVariant();
    uint64_t sid = 0;
    if (v == 1)      sid = TDHIDSampleSenderID();
    else if (v == 2) sid = TDProbedSenderID();
    if (sid) IOHIDEventSetSenderID(e, sid);
    if (TDInjectBuiltInOn()) IOHIDEventSetIntegerValue(e, kIOHIDEventFieldIsBuiltIn, 1);

    IOHIDEventSystemClientDispatchEvent(c, e);
    CFRelease(e);
}

void TDsendCmdV(void) {
    TDsendKey(0xE3, YES);     // 左 Command 按下
    usleep(12000);
    TDsendKey(0x19, YES);     // v 按下
    usleep(25000);
    TDsendKey(0x19, NO);      // v 抬起
    usleep(10000);
    TDsendKey(0xE3, NO);      // Command 抬起
}


// ---------------------------------------------------------------------------
// 注入方案表
//
// 上一版 16 组之所以全灭，是因为那张表里 senderID 只有两个选项：
// 「不设」和「硬编码 0x8000000817319372」。后者是别的机器的值，
// 本机真机实测物理触摸的 senderID 是 0x10000053e（= 0x1_00000000 | IORegistryEntryID），
// 所以那 16 组实际上等于「全部用错来源」，怎么组合都进不去。
//
// 这张新表把「从本机学到的真实 senderID」放在第一位，并把
// BKS digitizer info / 客户端类型 / 真实事件副本 一起编进来。
// ---------------------------------------------------------------------------

typedef struct {
    const char *name;
    NSInteger variant;      // TDInjectVariant
    BOOL legacyParent;      // 父事件坐标回退 (0,0)
    BOOL parentMaskConst;   // 父事件 mask 写死 Touch
    BOOL parentRange1;      // 父事件 range=1（v1.2.3 是 0）
    BOOL fixedIdentity;     // identity 恒为 3（v1.2.3）
    BOOL setTypeField;      // 补 DigitizerType（v1.2.3 没补）
    BOOL explicitXY;        // finger 显式写 X/Y（v1.2.3 只靠构造参数）
    BOOL stillMove;         // down/up 之间补一帧静止 move
    BOOL bks;               // BKSHIDEventSetDigitizerInfo
    BOOL builtIn;           // 补 IsBuiltIn
    BOOL real;              // 走真实事件副本
    BOOL plainClient;       // 用普通客户端 dispatch
    NSInteger coordMode;    // -1 = 不动；0 点 / 1 归一化 / 2 像素
} TDPlan;

// 第一组必须和 v1.2.3 逐字段一致 —— 那是唯一一次确认「事件真的到过抖音」的版本。
// 它当时的表现是「点中间却跳到我的」：一次 tap 被系统当成从 (0,0) 滑过来，
// 或者坐标被当成 0~1 归一化后 clamp 到右下角。两种解释都能用后面的方案区分。
static const TDPlan kPlans[] = {
    //  name                              variant                      legacy pMask range1 fixId type xy  move bks  bi   real plain coord
    {"v1.2.3 原样",                       TDInjectVariantNoSender,     YES,   YES,  NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 + 真实senderID",             TDInjectVariantSampleSender, YES,   YES,  NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 + 真sender + BKS",           TDInjectVariantSampleSender, YES,   YES,  NO,   YES,  NO,  NO, NO,  YES, NO,  NO,  NO,  -1},
    {"v1.2.3 但父坐标=目标点",             TDInjectVariantNoSender,     NO,    YES,  NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 父=目标 + 真sender",          TDInjectVariantSampleSender, NO,    YES,  NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 但父range=1",                TDInjectVariantSampleSender, YES,   YES,  YES,  YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 但identity递增",              TDInjectVariantSampleSender, YES,   YES,  NO,   NO,   NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 但补move帧",                  TDInjectVariantSampleSender, YES,   YES,  NO,   YES,  NO,  NO, YES, NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 但父mask透传",                TDInjectVariantSampleSender, YES,   NO,   NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  -1},
    {"v1.2.3 原样 + 归一化坐标",            TDInjectVariantNoSender,     YES,   YES,  NO,   YES,  NO,  NO, NO,  NO,  NO,  NO,  NO,  1},
    {"v1.3+ 现构造（对照）",               TDInjectVariantSampleSender, NO,    NO,   YES,  NO,   YES, YES, YES, NO,  NO,  NO,  NO,  -1},
    {"v1.3+ 现构造 + 归一化坐标",          TDInjectVariantSampleSender, NO,    NO,   YES,  NO,   YES, YES, YES, NO,  NO,  NO,  NO,  1},
    {"v1.3+ 现构造 + BKS",                TDInjectVariantSampleSender, NO,    NO,   YES,  NO,   YES, YES, YES, YES, NO,  NO,  NO,  -1},
    {"真实事件副本",                       TDInjectVariantNoSender,     NO,    NO,   YES,  NO,   YES, YES, YES, NO,  NO,  YES, NO,  -1},
};

static NSInteger TDPlanCount(void) {
    return (NSInteger)(sizeof(kPlans) / sizeof(kPlans[0]));
}
NSInteger TDInjectPlanCount(void) { return TDPlanCount(); }

NSString *TDInjectPlanDesc(NSInteger i) {
    if (i < 0 || i >= TDPlanCount()) return @"";
    const TDPlan *p = &kPlans[i];
    if (p->real) {
        return [NSString stringWithFormat:@"%@%@",
                [NSString stringWithUTF8String:p->name],
                TDHIDSampleReady() ? @"" : @"（未学到·会退化为合成）"];
    }
    return [NSString stringWithUTF8String:p->name];
}

void TDApplyInjectPlan(NSInteger i) {
    if (i < 0 || i >= TDPlanCount()) return;
    const TDPlan *p = &kPlans[i];
    if (!p->real) TDSetInjectVariant(p->variant);
    TDSetInjectParentMaskConst(p->parentMaskConst);
    TDSetInjectStillMove(p->stillMove);
    TDSetInjectBKSDigitizerInfo(p->bks);
    TDSetInjectBuiltIn(p->builtIn);
    gLegacyParent  = p->legacyParent;
    gParentRange1  = p->parentRange1;
    gFixedIdentity = p->fixedIdentity;
    gSetTypeField  = p->setTypeField;
    gExplicitXY    = p->explicitXY;
    gDispatchClient = p->plainClient ? TDPlainClient() : NULL;
    if (p->coordMode >= 0) TDSetCoordMode(p->coordMode);
}

void TDRunInjectPlan(NSInteger i, CGPoint p) {
    if (i < 0 || i >= TDPlanCount()) return;
    const TDPlan *it = &kPlans[i];
    TDApplyInjectPlan(i);
    TDHIDEchoReset();              // 开始统计这一轮的回显
    if (it->real && TDHIDSampleReady()) TDHIDReplayTap(p);
    else                                TDSynthTap(p.x, p.y);
}

#pragma mark - 链路诊断报告

/// 运行时读自己的签名权限。ldid 假签名如果没生效，这里会全 ✗ ——
/// 那种情况下 HID 这条路根本不用再试。
static int TDHasEntitlement(CFStringRef key) {
    static void *(*createFromSelf)(CFAllocatorRef) = NULL;
    static CFTypeRef (*copyEnt)(void *, CFStringRef, CFErrorRef *) = NULL;
    static void *task = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        createFromSelf = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
        copyEnt = dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
        if (createFromSelf) task = createFromSelf(kCFAllocatorDefault);
    }
    if (!copyEnt || !task) return -1;
    CFTypeRef v = copyEnt(task, key, NULL);
    if (!v) return 0;
    int ok = 0;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID()) {
        ok = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    } else if (t == CFNumberGetTypeID()) {
        int n = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
        ok = n != 0;
    } else {
        ok = 1;
    }
    CFRelease(v);
    return ok;
}

static NSString *TDEntitlementSummary(void) {
    struct { const char *label; CFStringRef key; } items[] = {
        {"hiddispatch", CFSTR("com.apple.private.hid.client.event-dispatch")},
        {"hidmonitor",  CFSTR("com.apple.private.hid.client.event-monitor")},
        {"backboard",   CFSTR("com.apple.backboard.client")},
        {"platform",    CFSTR("platform-application")},
        {"nosandbox",   CFSTR("com.apple.private.security.no-sandbox")},
    };
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 5; i++) {
        int v = TDHasEntitlement(items[i].key);
        [s appendFormat:@"%s%@  ", items[i].label,
            v < 0 ? @"?" : (v ? @"✓" : @"✗")];
    }
    return s;
}

/// 内核眼里的签名状态。
///
/// 为什么必须看这个：SecTask 里能读到 hid-event-dispatch 权限，只说明
/// **签名文件里写着**这条权限；内核放不放行还要看 code signing flags。
/// TrollStore + ldid 的假签名如果只写了 entitlements 却没把 binary 标成
/// 平台二进制（CS_PLATFORM_BINARY），私有接口会「静默失败」——
/// 不报错、不崩溃、事件就是凭空消失，正好是我们现在的症状。
/// 这一段在越狱机上另说，巨魔装出来的 App 应该看到 platform ✓。
extern int csops(pid_t pid, unsigned int ops, void *addr, size_t size);

#define TD_CS_OPS_STATUS       0
#define TD_CS_GET_TASK_ALLOW   0x00000004
#define TD_CS_HARD             0x00000100
#define TD_CS_RESTRICT         0x00000800
#define TD_CS_PLATFORM_BINARY  0x04000000

NSString *TDCodeSignReport(void) {
    uint32_t flags = 0;
    int r = csops(getpid(), TD_CS_OPS_STATUS, &flags, sizeof(flags));
    if (r != 0) {
        return [NSString stringWithFormat:@"签名 ?（csops 失败 errno=%d） euid:%d",
                errno, (int)geteuid()];
    }
    BOOL platform = (flags & TD_CS_PLATFORM_BINARY) != 0;
    BOOL taskAllow = (flags & TD_CS_GET_TASK_ALLOW) != 0;
    return [NSString stringWithFormat:@"签名 platform:%@ task:%@ euid:%d cs:0x%08x%@",
            platform ? @"✓" : @"✗",
            taskAllow ? @"✓" : @"✗",
            (int)geteuid(), flags,
            platform ? @"" : @"  ← 内核没当平台二进制"];
}

/// 从学到的那次**真实**物理触摸里，把坐标原样读出来。
///
/// 这条比任何注入实验都值钱：它直接告诉我们这台机器的 digitizer 事件里
/// x/y 到底用什么量纲（点 / 归一化 / 像素）。有了真值就不用再猜，
/// 也就不用再拿 14 组构造去盲试。
NSString *TDHIDSampleGeometry(void) {
    TDSampleLock();
    IOHIDEventRef down = gSampleDown ? (IOHIDEventRef)CFRetain(gSampleDown) : NULL;
    TDSampleUnlock();
    if (!down) return @"真实事件：未学到（先在方块上点一下）";

    IOHIDEventRef f = TDFingerOf(down);
    IOHIDFloat hx = IOHIDEventGetFloatValue(down, kIOHIDEventFieldDigitizerX);
    IOHIDFloat hy = IOHIDEventGetFloatValue(down, kIOHIDEventFieldDigitizerY);
    IOHIDFloat fx = f ? IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerX) : 0;
    IOHIDFloat fy = f ? IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerY) : 0;
    long ident = f ? (long)IOHIDEventGetIntegerValue(f, kIOHIDEventFieldDigitizerIdentity) : -1;
    long disp = (long)IOHIDEventGetIntegerValue(down, kIOHIDEventFieldDigitizerIsDisplayIntegrated);
    long kids = IOHIDEventGetChildren(down) ? (long)CFArrayGetCount(IOHIDEventGetChildren(down)) : 0;
    CFRelease(down);

    CGSize scr = TDMainPointSize();
    CGFloat sc = [UIScreen mainScreen].scale;
    // 用最大值判量纲：<=1 只能是归一化；<=短边 基本是点；再大就是像素
    IOHIDFloat m = MAX(fx, fy);
    const char *space = (m <= 1.001f) ? "归一化"
                     : (m <= MAX(scr.width, scr.height) + 1) ? "点"
                     : "像素";
    return [NSString stringWithFormat:
            @"真实事件 finger(%.1f,%.1f) 手(%.1f,%.1f)\n"
            @"  → 量纲 %s · id %ld · 子事件 %ld · disp %ld · 屏 %.0f×%.0f @%.0fx",
            (double)fx, (double)fy, (double)hx, (double)hy,
            space, ident, kids, disp, scr.width, scr.height, sc];
}

NSString *TDHIDDiagReport(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"客户端  admin:%@ 普通:%@\n",
        TDhidClient() ? @"ok" : @"nil", TDPlainClient() ? @"ok" : @"nil"];

    uint64_t probed = TDProbedSenderID();
    [s appendFormat:@"HID服务 %ld 个 · 探测sender:%@\n", (long)gServiceCount,
        probed ? [NSString stringWithFormat:@"0x%llx", probed] : @"无"];

    uint64_t real = TDHIDSampleSenderID();
    [s appendFormat:@"监听 事件%ld · down:%@ up:%@ · sender:%@\n",
        (long)gMonTotal,
        gSampleDown ? @"✓" : @"✗",
        gSampleUp ? @"✓" : @"✗",
        real ? [NSString stringWithFormat:@"0x%llx", real] : @"无"];

    [s appendFormat:@"权限 %@\n", TDEntitlementSummary()];
    [s appendFormat:@"%@\n", TDCodeSignReport()];
    [s appendFormat:@"%@\n", TDHIDSampleGeometry()];
    // 音量键这条路：一直为 0 说明 button 事件不进这个客户端，只能靠音量 KVO 兜底
    [s appendFormat:@"%@\n", TDKeysStatus()];
    // 回显只能证明「监听到了物理转换器自己发的事件」，看不到本进程 dispatch 的；
    // 所以这个数字是 0 时不能反推「事件被拦」，只能反推「没有回环」。
    [s appendFormat:@"回显 %ld 个（监听侧看不到本进程 dispatch，0 不代表被拦）",
        (long)gEchoCount];
    return s;
}
