#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#include <mach/mach_time.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 全局触摸注入：构造 digitizer(hand) + finger 子事件，交给 IOHIDEventSystemClient
// 派发到系统 HID 栈，由 SpringBoard / 前台 App 接收。
// 需要 com.apple.private.hid.client.event-dispatch 权限（见 entitlements.plist）
// ---------------------------------------------------------------------------

static IOHIDEventSystemClientRef gClient = NULL;

// 常见的触摸注入 senderID，系统据此认定事件来自内建触摸屏
static const uint64_t kTDSenderID = 0x8000000817319372ULL;

BOOL TDhidReady(void) {
    if (gClient == NULL) {
        gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    return gClient != NULL;
}

NSString *TDhidStatus(void) {
    return TDhidReady() ? @"HID 就绪" : @"HID 失败:客户端创建不出来";
}

// 构造 hand 父事件（display integrated 必须为 1，否则系统不当作真实触摸）
static IOHIDEventRef TDCreateHand(void) {
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                       mach_absolute_time(),
                                                       kIOHIDDigitizerTransducerTypeHand,
                                                       0, 0, 0, 0,
                                                       0.0, 0.0, 0.0, 0.0, 0.0,
                                                       0, 0, 0);
    if (hand == NULL) return NULL;

    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltX, kIOHIDDigitizerTransducerTypeHand);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerTiltY, 1);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerAltitude, 1);
    return hand;
}

// mask: kIOHIDDigitizerEvent* 位组合；touch: 当前是否接触屏幕
static void TDEmit(uint32_t mask, BOOL touch, CGFloat x, CGFloat y) {
    if (!TDhidReady()) return;

    IOHIDEventRef hand = TDCreateHand();
    if (hand == NULL) return;

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                               mach_absolute_time(),
                                                               1,      // index
                                                               3,      // identity
                                                               mask,
                                                               (IOHIDFloat)x,
                                                               (IOHIDFloat)y,
                                                               0.0f, 0.0f, 0.0f,
                                                               touch ? 1 : 0,   // range
                                                               touch ? 1 : 0,   // touch
                                                               0);
    if (finger != NULL) {
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMajorRadius, 0.04f);
        IOHIDEventSetFloatValue(finger, kIOHIDEventFieldDigitizerMinorRadius, 0.04f);
        IOHIDEventAppendEvent(hand, finger);   // hand 持有 child
        CFRelease(finger);
    }

    IOHIDEventSetSenderID(hand, kTDSenderID);
    IOHIDEventSystemClientDispatchEvent(gClient, hand);
    CFRelease(hand);
}

static const uint32_t kMaskDown = (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);
static const uint32_t kMaskMove = kIOHIDDigitizerEventPosition;
static const uint32_t kMaskUp   = (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);

void TDtap(CGFloat x, CGFloat y) {
    TDEmit(kMaskDown, YES, x, y);
    usleep(30000);                 // 30ms，太短会被系统当抖动丢弃
    TDEmit(kMaskUp, NO, x, y);
}

void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec) {
    TDEmit(kMaskDown, YES, x, y);
    NSTimeInterval d = sec > 0 ? sec : 0.8;
    // 期间补几帧 move，长按更稳（系统会判定 hold）
    NSInteger frames = (NSInteger)(d / 0.12);
    for (NSInteger i = 1; i <= frames; i++) {
        usleep((useconds_t)(0.12 * 1000000));
        TDEmit(kMaskMove, YES, x, y);
    }
    usleep((useconds_t)((d - frames * 0.12) * 1000000));
    TDEmit(kMaskUp, NO, x, y);
}

void TDgesture(NSArray<NSValue *> *points, NSTimeInterval sec) {
    if (points.count < 2) return;

    CGPoint first = [points[0] CGPointValue];
    TDEmit(kMaskDown, YES, first.x, first.y);

    NSTimeInterval total = sec > 0 ? sec : 0.35;
    NSInteger segments = points.count - 1;
    // 每段按距离分配帧数，保证匀速
    CGFloat totalLen = 0;
    for (NSInteger i = 1; i < (NSInteger)points.count; i++) {
        CGPoint a = [points[i - 1] CGPointValue];
        CGPoint b = [points[i] CGPointValue];
        totalLen += hypot(b.x - a.x, b.y - a.y);
    }
    if (totalLen < 1) totalLen = 1;

    for (NSInteger i = 1; i < (NSInteger)points.count; i++) {
        CGPoint a = [points[i - 1] CGPointValue];
        CGPoint b = [points[i] CGPointValue];
        CGFloat len = hypot(b.x - a.x, b.y - a.y);
        NSInteger frames = MAX(2, (NSInteger)round(len / totalLen * total / 0.012));
        for (NSInteger f = 1; f <= frames; f++) {
            CGFloat t = (CGFloat)f / (CGFloat)frames;
            CGFloat x = a.x + (b.x - a.x) * t;
            CGFloat y = a.y + (b.y - a.y) * t;
            TDEmit(kMaskMove, YES, x, y);
            usleep((useconds_t)(total / (frames * MAX(1, segments)) * 1000000));
        }
    }

    CGPoint last = [points.lastObject CGPointValue];
    TDEmit(kMaskUp, NO, last.x, last.y);
}

void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec) {
    TDgesture(@[[NSValue valueWithCGPoint:from], [NSValue valueWithCGPoint:to]], sec);
}
