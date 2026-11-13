#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#import <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>

// ---------------------------------------------------------------------------
// 录制：监听系统级触摸事件（display integrated digitizer）
//
// 用 IOHIDEventSystemClientCreateWithType(…, 2 = Monitor, …) 建客户端，再挂
// event filter 回调，就能在别的 App（抖音）里拿到「真人手指」的坐标，而
// 不需要用户回 TapDog 取点。回到本 App 时自动停止，把录到的触摸序列
// 转换成 tap / long / swipe 步骤。
//
// 权限：com.apple.private.hid.client.event-monitor
//       com.apple.private.hid.client.event-filter
// ---------------------------------------------------------------------------

typedef IOHIDEventRef (*TDFilterCallback)(void *target, void *refcon, IOHIDEventRef event);
typedef IOHIDEventSystemClientRef (*TDCreateWithTypeFn)(CFAllocatorRef, uint32_t, void *);
typedef void (*TDRegisterFilterFn)(IOHIDEventSystemClientRef, TDFilterCallback, void *, void *);
typedef void (*TDScheduleFn)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef void (*TDUnscheduleFn)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef void (*TDCancelFn)(IOHIDEventSystemClientRef);

static IOHIDEventSystemClientRef gMonitor = NULL;
static TDUnscheduleFn gUnschedule = NULL;
static TDCancelFn gCancel = NULL;
static NSString *gMonitorStatus = @"未启动";

static double TDMStoMs(uint64_t delta) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)delta * (double)tb.numer / (double)tb.denom / 1000000.0;
}

/// HID 上报的坐标可能是像素，也可能是点；明显超过屏幕宽度就按像素处理
static CGPoint TDnormalizePoint(CGFloat x, CGFloat y) {
    static CGFloat sw = 0;
    static CGFloat sc = 1;
    if (sw == 0) {
        sw = [UIScreen mainScreen].bounds.size.width;
        sc = [UIScreen mainScreen].nativeScale;
        if (sc < 1) sc = 1;
    }
    if (x > sw + 4) return CGPointMake(x / sc, y / sc);
    return CGPointMake(x, y);
}

@interface TDRecorder ()
- (void)handleEvent:(IOHIDEventRef)event;
@end

static IOHIDEventRef TDMonitorCallback(void *target, void *refcon, IOHIDEventRef event) {
    @autoreleasepool {
        TDRecorder *r = (__bridge TDRecorder *)target;
        if (r) [r handleEvent:event];
    }
    return event;   // 原样放行，不影响正常操作
}

@implementation TDRecorder {
    NSMutableArray<NSDictionary *> *_events;
    BOOL _down;
    CGPoint _start;
    CGPoint _last;
    uint64_t _downTime;
    uint64_t _lastEnd;
    BOOL _moved;
}

+ (instancetype)shared {
    static TDRecorder *r = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [TDRecorder new]; });
    return r;
}

- (BOOL)recording { return _events != nil; }
- (NSInteger)eventCount { return (NSInteger)_events.count; }
- (NSString *)status { return gMonitorStatus; }

- (BOOL)start {
    if (_events) return YES;
    if (!gMonitor) {
        TDCreateWithTypeFn create = (TDCreateWithTypeFn)dlsym(RTLD_DEFAULT,
                                                               "IOHIDEventSystemClientCreateWithType");
        if (!create) { gMonitorStatus = @"失败：系统无监听接口"; return NO; }

        IOHIDEventSystemClientRef c = create(kCFAllocatorDefault, 2 /*Monitor*/, NULL);
        if (!c) { gMonitorStatus = @"失败：监听客户端建不起来（权限）"; return NO; }

        TDFilterCallback cb = TDMonitorCallback;
        TDRegisterFilterFn reg = (TDRegisterFilterFn)dlsym(RTLD_DEFAULT,
                                                           "IOHIDEventSystemClientRegisterEventFilterCallback");
        TDScheduleFn sched = (TDScheduleFn)dlsym(RTLD_DEFAULT,
                                                 "IOHIDEventSystemClientScheduleWithRunLoop");
        if (!reg || !sched) {
            gMonitorStatus = @"失败：回调接口缺失";
            return NO;
        }
        reg(c, cb, (__bridge void *)[TDRecorder shared], NULL);
        sched(c, CFRunLoopGetMain(), kCFRunLoopCommonModes);

        gUnschedule = (TDUnscheduleFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientUnscheduleWithRunLoop");
        gCancel = (TDCancelFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCancel");
        gMonitor = c;
        gMonitorStatus = @"已连接（系统级触摸监听）";
    }

    _events = [NSMutableArray array];
    _down = NO;
    _moved = NO;
    _lastEnd = mach_absolute_time();
    if (self.onChange) self.onChange();
    return YES;
}

- (NSMutableArray<NSDictionary *> *)stop {
    if (!_events) return nil;
    NSMutableArray *out = _events;
    _events = nil;
    _down = NO;
    if (self.onChange) self.onChange();
    return out;
}

#pragma mark - 事件解析

- (void)handleEvent:(IOHIDEventRef)event {
    if (!_events || !event) return;
    if (IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;

    CFArrayRef kids = IOHIDEventGetChildren(event);
    CFIndex n = kids ? CFArrayGetCount(kids) : 0;
    if (n > 1) return;   // 多指手势不录

    IOHIDEventRef src = (n == 1) ? (IOHIDEventRef)CFArrayGetValueAtIndex(kids, 0) : event;

    int integrated = IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated);
    if (!integrated) integrated = IOHIDEventGetIntegerValue(src, kIOHIDEventFieldDigitizerIsDisplayIntegrated);
    if (!integrated) return;

    int touching = IOHIDEventGetIntegerValue(src, kIOHIDEventFieldDigitizerTouch);
    CGFloat rawX = IOHIDEventGetFloatValue(src, kIOHIDEventFieldDigitizerX);
    CGFloat rawY = IOHIDEventGetFloatValue(src, kIOHIDEventFieldDigitizerY);
    CGPoint p = TDnormalizePoint(rawX, rawY);
    uint64_t now = mach_absolute_time();

    if (touching && !_down) {
        _down = YES;
        _moved = NO;
        _start = p;
        _last = p;
        _downTime = now;
        return;
    }
    if (touching && _down) {
        _last = p;
        if (!_moved && hypot(p.x - _start.x, p.y - _start.y) > 12) _moved = YES;
        return;
    }
    if (!touching && _down) {
        _down = NO;

        // 屏幕最底部那条是「上滑回桌面」的手势，别录进去
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        if (_start.y > sh - 44) {
            _lastEnd = now;
            return;
        }

        double durMs = TDMStoMs(now - _downTime);
        double gapMs = TDMStoMs(_downTime > _lastEnd ? _downTime - _lastEnd : 0);

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"gap"] = @((NSInteger)MAX(0, gapMs));

        if (!_moved && durMs < 450) {
            d[@"t"] = @"tap";
            d[@"x"] = @((NSInteger)lround(_start.x));
            d[@"y"] = @((NSInteger)lround(_start.y));
        } else if (!_moved) {
            d[@"t"] = @"long";
            d[@"x"] = @((NSInteger)lround(_start.x));
            d[@"y"] = @((NSInteger)lround(_start.y));
            d[@"ms"] = @((NSInteger)MAX(300, durMs));
        } else {
            d[@"t"] = @"swipe";
            d[@"x1"] = @((NSInteger)lround(_start.x));
            d[@"y1"] = @((NSInteger)lround(_start.y));
            d[@"x2"] = @((NSInteger)lround(_last.x));
            d[@"y2"] = @((NSInteger)lround(_last.y));
            d[@"ms"] = @((NSInteger)MAX(80, durMs));
        }
        [_events addObject:d];
        _lastEnd = now;
        if (self.onChange) self.onChange();
    }
}

@end
