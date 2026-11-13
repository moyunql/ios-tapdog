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

// 内建触摸屏的 senderID；系统据此认定事件来自真实屏幕
static const uint64_t kTDSenderID = 0x8000000817319372ULL;

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
static IOHIDEventRef TDCreateHand(uint32_t mask, uint64_t ts) {
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                       ts,
                                                       kIOHIDDigitizerTransducerTypeHand,
                                                       0, 0,
                                                       kIOHIDDigitizerEventTouch,
                                                       0,
                                                       0.0, 0.0, 0.0, 0.0, 0.0,
                                                       0, true, 0);
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
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

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef hand = TDCreateHand(mask, ts);
    if (!hand) return;

    int isTouch = touch ? 1 : 0;
    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                               ts,
                                                               1,      // index
                                                               3,      // identity
                                                               mask,
                                                               (IOHIDFloat)x,
                                                               (IOHIDFloat)y,
                                                               0.0f, 0.0f, 0.0f,
                                                               isTouch,   // range
                                                               isTouch,   // touch
                                                               0);
    if (finger) {
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerTouch, isTouch);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    IOHIDEventSetSenderID(hand, kTDSenderID);
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
