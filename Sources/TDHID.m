#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#import <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

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

static IOHIDEventSystemClientRef TDhidClient(void);   // 定义在本文件后面

typedef CFArrayRef (*TDCopyServicesFn)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*TDServiceGetPropFn)(void *service, CFStringRef key);

/// 从 IOHIDEventSystemClient 的服务列表里读真实 senderID。
/// 读不到就返回 0（调用方会退化成「不设 senderID」）。
uint64_t TDProbedSenderID(void) {
    if (gProbedTried) return gProbedSender;
    gProbedTried = YES;

    IOHIDEventSystemClientRef c = TDhidClient();
    if (!c) return 0;

    TDCopyServicesFn copyServices =
        (TDCopyServicesFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    TDServiceGetPropFn getProp =
        (TDServiceGetPropFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetProperty");
    if (!copyServices || !getProp) return 0;

    CFArrayRef services = copyServices(c);
    if (!services) return 0;
    if (CFGetTypeID(services) != CFArrayGetTypeID()) { CFRelease(services); return 0; }

    CFStringRef keys[] = { CFSTR("SenderID"), CFSTR("HIDSenderID"), CFSTR("senderID") };
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n && gProbedSender == 0; i++) {
        void *svc = (void *)CFArrayGetValueAtIndex(services, i);
        if (!svc) continue;
        for (int k = 0; k < 3 && gProbedSender == 0; k++) {
            CFTypeRef v = getProp(svc, keys[k]);
            if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) continue;
            long long num = 0;
            if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &num) && num != 0) {
                gProbedSender = (uint64_t)num;
            }
        }
    }
    CFRelease(services);
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
    if ([d objectForKey:kInjVariantKey] == nil) return TDInjectVariantNoSender;   // 默认最保守
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
    TDSetInjectBKSDigitizerInfo(NO);
}

NSString *TDInjectVariantDesc(void) {
    NSInteger v = TDInjectVariantCurrent();
    NSString *s;
    if (v == TDInjectVariantHardSender) {
        s = @"硬编码 senderID";
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
        case TDInjectVariantHardSender: sid = kTDDefaultSenderID; break;
        case TDInjectVariantAutoSender: sid = TDProbedSenderID(); break;
        default: break;
    }
    if (sid) IOHIDEventSetSenderID(hand, sid);
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
    BOOL legacy = TDInjectHandLegacy();
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
                                                       1,                 // range：手始终在感应范围内
                                                       true,              // touch：手始终在屏幕上
                                                       0);
    (void)touch;
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
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

// mask: kIOHIDDigitizerEvent* 位组合；touch: 当前是否接触屏幕
static void TDEmit(uint32_t mask, BOOL touch, CGFloat x, CGFloat y, uint32_t identity) {
    IOHIDEventSystemClientRef client = TDhidClient();
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
                                                               0.0f, 0.0f, 0.0f,
                                                               isTouch,   // range
                                                               isTouch,   // touch
                                                               0);
    if (finger) {
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerType,
                                  kIOHIDDigitizerTransducerTypeFinger);
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerTouch, isTouch);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerX, (IOHIDFloat)e.x);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerY, (IOHIDFloat)e.y);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
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

void TDtap(CGFloat x, CGFloat y) {
    uint32_t ident = TDNextIdentity();
    TDEmit(kMaskDown, YES, x, y, ident);
    // 一帧静止 move：真实触摸在按住期间 HID 也会持续上报位置，
    // 完全不给 move 帧时部分版本认不出这是一次 tap。
    usleep(30000);
    if (TDInjectStillMoveOn()) TDEmit(kMaskMove, YES, x, y, ident);
    usleep(50000);
    TDEmit(kMaskUp, NO, x, y, ident);
    TDShowFeedback(x, y);
}

void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec) {
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
    if (points.count < 2) return;

    uint32_t ident = TDNextIdentity();
    CGPoint first = [points[0] CGPointValue];
    TDEmit(kMaskDown, YES, first.x, first.y, ident);

    NSTimeInterval total = sec > 0 ? sec : 0.35;
    NSInteger segments = (NSInteger)points.count - 1;
    CGFloat totalLen = 0;
    for (NSUInteger i = 1; i < points.count; i++) {
        CGPoint a = [points[i - 1] CGPointValue];
        CGPoint b = [points[i] CGPointValue];
        totalLen += hypot(b.x - a.x, b.y - a.y);
    }
    if (totalLen < 1) totalLen = 1;

    for (NSUInteger i = 1; i < points.count; i++) {
        CGPoint a = [points[i - 1] CGPointValue];
        CGPoint b = [points[i] CGPointValue];
        CGFloat len = hypot(b.x - a.x, b.y - a.y);
        NSInteger frames = MAX(2, (NSInteger)round(len / totalLen * total / 0.012));
        for (NSInteger f = 1; f <= frames; f++) {
            CGFloat t = (CGFloat)f / (CGFloat)frames;
            TDEmit(kMaskMove, YES, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, ident);
            usleep((useconds_t)(total / (frames * MAX(1, segments)) * 1000000));
        }
    }

    CGPoint last = [points.lastObject CGPointValue];
    TDEmit(kMaskUp, NO, last.x, last.y, ident);
    TDShowFeedback(last.x, last.y);
}

void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec) {
    TDgesture(@[[NSValue valueWithCGPoint:from], [NSValue valueWithCGPoint:to]], sec);
}
