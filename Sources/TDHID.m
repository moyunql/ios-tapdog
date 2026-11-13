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
//   - 父事件的 eventMask 给 kIOHIDDigitizerEventTouch，不能是 0
//   - 补 TiltX / TiltY / Altitude 三个字段，否则 BackBoard 认为这不是屏幕触摸
//   - finger 的 Major/MinorRadius 给 0.04（真实手指量级），给 0 会被当噪声丢掉
static IOHIDEventRef TDCreateHand(uint32_t mask, uint64_t ts, CGPoint e) {
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                       ts,
                                                       kIOHIDDigitizerTransducerTypeHand,
                                                       0, 0,
                                                       kIOHIDDigitizerEventTouch,
                                                       0,
                                                       (IOHIDFloat)e.x, (IOHIDFloat)e.y,
                                                       0.0, 0.0, 0.0,
                                                       mask & kIOHIDDigitizerEventTouch ? 1 : 0,
                                                       true, 0);
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerType,
                              kIOHIDDigitizerTransducerTypeHand);
    // 父事件的坐标也补上：有些系统版本只读父事件的位置
    IOHIDEventSetFloatValue(hand, kIOHIDEventFieldDigitizerX, (IOHIDFloat)e.x);
    IOHIDEventSetFloatValue(hand, kIOHIDEventFieldDigitizerY, (IOHIDFloat)e.y);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltX,
                              kIOHIDDigitizerTransducerTypeHand);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltY, 1);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerAltitude, 1);
    return hand;
}

// mask: kIOHIDDigitizerEvent* 位组合；touch: 当前是否接触屏幕
static void TDEmit(uint32_t mask, BOOL touch, CGFloat x, CGFloat y) {
    IOHIDEventSystemClientRef client = TDhidClient();
    if (!client) return;

    // 点击反馈：把「正要往哪点」画出来，能不能点动是另一回事，位置对不对一眼就看得到
    BOOL isDown = (mask & kIOHIDDigitizerEventTouch) && touch;
    if (isDown) __sync_fetch_and_add(&gInjectCount, 1);
    if (gFeedback) gFeedback(x, y, isDown);

    // 屏幕点 → 事件坐标空间（点 / 归一化 / 像素）
    CGPoint e = TDCoordToEventSpace(CGPointMake(x, y));

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef hand = TDCreateHand(mask, ts, e);
    if (!hand) return;

    int isTouch = touch ? 1 : 0;
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                               ts,
                                                               1,      // index
                                                               3,      // identity
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

void TDtap(CGFloat x, CGFloat y) {
    TDEmit(kMaskDown, YES, x, y);
    usleep(50000);                 // 50ms，接近真人点按，太短会被当抖动丢掉
    TDEmit(kMaskUp, NO, x, y);
}

void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec) {
    TDEmit(kMaskDown, YES, x, y);
    NSTimeInterval d = sec > 0 ? sec : 0.8;
    NSInteger frames = (NSInteger)(d / 0.12);
    for (NSInteger i = 1; i <= frames; i++) {
        usleep((useconds_t)(0.12 * 1000000));
        TDEmit(kMaskMove, YES, x, y);
    }
    NSTimeInterval rest = d - frames * 0.12;
    if (rest > 0) usleep((useconds_t)(rest * 1000000));
    TDEmit(kMaskUp, NO, x, y);
}

void TDgesture(NSArray<NSValue *> *points, NSTimeInterval sec) {
    if (points.count < 2) return;

    CGPoint first = [points[0] CGPointValue];
    TDEmit(kMaskDown, YES, first.x, first.y);

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
            TDEmit(kMaskMove, YES, a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
            usleep((useconds_t)(total / (frames * MAX(1, segments)) * 1000000));
        }
    }

    CGPoint last = [points.lastObject CGPointValue];
    TDEmit(kMaskUp, NO, last.x, last.y);
}

void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec) {
    TDgesture(@[[NSValue valueWithCGPoint:from], [NSValue valueWithCGPoint:to]], sec);
}
