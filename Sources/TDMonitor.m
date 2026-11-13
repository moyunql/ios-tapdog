#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#import <dlfcn.h>
#import <os/lock.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

// ===========================================================================
// 录制：系统级触摸监听（display integrated digitizer）
//
// 上一版「点录制就闪退」的两个原因，这次全部改掉：
//
//  1) 用 Monitor(2) 类型的 client 去注册 RegisterEventFilterCallback。
//     这个 filter 接口只对 Filter(3) 类型成立，Apple 内部会断言失败直接
//     SIGABRT。iOS 13 起 Monitor 类型必须用 RegisterEventCallback（回调返回
//     void，不是 IOHIDEventRef）。现在优先用 EventCallback，没有才退回 filter。
//
//  2) 回调跑在 HID 的事件线程上，里面发 ObjC 消息、读 UIScreen、还往
//     NSMutableArray 里 addObject，主线程同时在 reloadData —— 后台线程碰
//     UIKit + 并发改容器，必崩。
//     现在回调里只做「纯 C 提取 + 加锁写定长数组」：不发 ObjC 消息、不碰
//     UIKit、不分配内存。解析和 UI 刷新全留到主线程 stop 时做。
//
// 权限：com.apple.private.hid.client.event-monitor / event-filter
// ===========================================================================

#define TD_SAMPLE_MAX 4096

typedef struct {
    uint64_t t;        // mach_absolute_time
    double   x, y;     // 原始上报坐标（可能为点，也可能是像素）
    uint8_t  touching;
} TDSample;

static TDSample gSamples[TD_SAMPLE_MAX];
static volatile int gSampleCount = 0;
static volatile int gArmed = 0;
static os_unfair_lock gSampleLock = OS_UNFAIR_LOCK_INIT;

typedef IOHIDEventSystemClientRef (*TDCreateWithTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);

// !! 注意：RegisterEventCallback 的回调是 4 个参数 !!
// typedef void(*)(void *target, void *refcon, IOHIDEventQueueRef queue, IOHIDEventRef event)
// 少写一个参数的话，系统会把 queue 当成 event 递进来，一取字段就 EXC_BAD_ACCESS。
typedef void (*TDEventCallback)(void *target, void *refcon, void *queue, IOHIDEventRef event);
// Filter 版（老接口）是 3 个参数，且必须把 event 原样返回
typedef IOHIDEventRef (*TDFilterCallback)(void *target, void *refcon, IOHIDEventRef event);

typedef void (*TDRegisterEventFn)(IOHIDEventSystemClientRef, TDEventCallback, void *, void *);
typedef void (*TDRegisterFilterFn)(IOHIDEventSystemClientRef, TDFilterCallback, void *, void *);
typedef void (*TDScheduleFn)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);

static IOHIDEventSystemClientRef gClient = NULL;
static NSString *gStatus = @"未启动";
static NSString *gApi = nil;

static double TDmsBetween(uint64_t a, uint64_t b) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    if (a <= b) return 0;
    return (double)(a - b) * (double)tb.numer / (double)tb.denom / 1000000.0;
}

// ---------------------------------------------------------------------------
// HID 线程：只允许纯 C 操作
// ---------------------------------------------------------------------------

static void TDPushSample(double x, double y, int touching) {
    os_unfair_lock_lock(&gSampleLock);
    if (gSampleCount < TD_SAMPLE_MAX) {
        TDSample *s = &gSamples[gSampleCount];
        s->t = mach_absolute_time();
        s->x = x;
        s->y = y;
        s->touching = (uint8_t)(touching ? 1 : 0);
        gSampleCount = gSampleCount + 1;
    }
    os_unfair_lock_unlock(&gSampleLock);
}

static void TDHandleRawEvent(IOHIDEventRef event) {
    if (!gArmed || !event) return;
    if (IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;

    CFArrayRef kids = IOHIDEventGetChildren(event);
    CFIndex n = 0;
    if (kids && CFGetTypeID(kids) == CFArrayGetTypeID()) n = CFArrayGetCount(kids);

    int integrated = 0;
    int touching = 0;
    double x = 0, y = 0;

    if (n > 0) {
        // 只取第一根手指；多指手势录不了，忽略其余
        CFTypeRef c0 = CFArrayGetValueAtIndex(kids, 0);
        if (c0 && CFGetTypeID(c0) == IOHIDEventGetTypeID()) {
            IOHIDEventRef f = (IOHIDEventRef)c0;
            integrated = (int)IOHIDEventGetIntegerValue(f, kIOHIDEventFieldDigitizerIsDisplayIntegrated);
            touching = (int)IOHIDEventGetIntegerValue(f, kIOHIDEventFieldDigitizerTouch);
            if (touching) {
                x = IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerX);
                y = IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerY);
            }
        } else {
            integrated = 1;
            touching = 1;
        }
    } else {
        // collection 里一根手指都没有 = 抬手
        integrated = (int)IOHIDEventGetIntegerValue(event, kIOHIDEventFieldDigitizerIsDisplayIntegrated);
        touching = 0;
    }

    if (!integrated) return;   // 不是屏幕上的触摸（外接设备等）
    TDPushSample(x, y, touching);
}

// 返回 void 的那个（Monitor 类型专用，4 参数）
static void TDEventCB(void *target, void *refcon, void *queue, IOHIDEventRef event) {
    TDHandleRawEvent(event);
}

// 返回 IOHIDEventRef 的那个（Filter 类型专用，必须原样放行）
static IOHIDEventRef TDFilterCB(void *target, void *refcon, IOHIDEventRef event) {
    TDHandleRawEvent(event);
    return event;
}

// ---------------------------------------------------------------------------
// 录制器
// ---------------------------------------------------------------------------

@interface TDRecorder ()
@property (nonatomic, readwrite) BOOL recording;
@end

@implementation TDRecorder

+ (instancetype)shared {
    static TDRecorder *r = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [TDRecorder new]; });
    return r;
}

- (NSInteger)eventCount { return (NSInteger)gSampleCount; }
- (NSString *)status { return gStatus; }

- (BOOL)start {
    @try {
        if (self.recording) return YES;
        if ([TDEngine shared].running) [[TDEngine shared] stop];

        if (!gClient) {
            TDCreateWithTypeFn create = (TDCreateWithTypeFn)dlsym(RTLD_DEFAULT,
                                                                   "IOHIDEventSystemClientCreateWithType");
            if (create) {
                CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                                                        &kCFTypeDictionaryKeyCallBacks,
                                                                        &kCFTypeDictionaryValueCallBacks);
                // 2 = kIOHIDEventSystemClientTypeMonitor
                gClient = create(kCFAllocatorDefault, 2, props);
                if (props) CFRelease(props);
            }
            if (!gClient) gClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!gClient) {
                gStatus = @"失败：监听客户端建不起来（HID 权限）";
                return NO;
            }

            // iOS 13+：Monitor 类型配 RegisterEventCallback
            TDRegisterEventFn regEv = (TDRegisterEventFn)dlsym(RTLD_DEFAULT,
                                                               "IOHIDEventSystemClientRegisterEventCallback");
            if (regEv) {
                regEv(gClient, TDEventCB, NULL, NULL);
                gApi = @"event-callback";
            } else {
                TDRegisterFilterFn regF = (TDRegisterFilterFn)dlsym(RTLD_DEFAULT,
                                                                    "IOHIDEventSystemClientRegisterEventFilterCallback");
                if (regF) { regF(gClient, TDFilterCB, NULL, NULL); gApi = @"filter"; }
            }
            if (!gApi) {
                CFRelease(gClient);
                gClient = NULL;
                gStatus = @"失败：系统没有触摸回调接口";
                return NO;
            }

            TDScheduleFn sched = (TDScheduleFn)dlsym(RTLD_DEFAULT,
                                                     "IOHIDEventSystemClientScheduleWithRunLoop");
            if (!sched) {
                gStatus = @"失败：监听器挂不上 runloop";
                return NO;
            }
            sched(gClient, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            gStatus = [NSString stringWithFormat:@"已连接（%@）", gApi];
        }

        os_unfair_lock_lock(&gSampleLock);
        gSampleCount = 0;
        os_unfair_lock_unlock(&gSampleLock);

        self.recording = YES;
        gArmed = 1;
        if (self.onChange) self.onChange();
        return YES;
    } @catch (NSException *e) {
        gStatus = [NSString stringWithFormat:@"异常：%@", e.reason ?: @"未知"];
        self.recording = NO;
        gArmed = 0;
        return NO;
    }
}

- (NSMutableArray<NSDictionary *> *)stop {
    if (!self.recording) return nil;
    gArmed = 0;
    self.recording = NO;

    static TDSample buf[TD_SAMPLE_MAX];
    int n = 0;
    os_unfair_lock_lock(&gSampleLock);
    n = gSampleCount;
    if (n > TD_SAMPLE_MAX) n = TD_SAMPLE_MAX;
    if (n > 0) memcpy(buf, gSamples, sizeof(TDSample) * (size_t)n);
    gSampleCount = 0;
    os_unfair_lock_unlock(&gSampleLock);

    NSMutableArray *steps = [self parseSamples:buf count:n];
    if (self.onChange) self.onChange();
    return steps;
}

#pragma mark - 样本 → 步骤（全在主线程）

- (NSMutableArray<NSDictionary *> *)parseSamples:(TDSample *)s count:(int)n {
    NSMutableArray *out = [NSMutableArray array];
    if (n <= 0) return out;

    CGSize sb = [UIScreen mainScreen].bounds.size;
    if (sb.width < 1 || sb.height < 1) sb = CGSizeMake(414, 736);

    // 坐标体系判定：HID 有时报点、有时报像素。
    // 只要出现过超出屏幕点尺寸的坐标，就说明这套样本是像素坐标，整段统一换算
    // （逐点换算会导致一半点缩放、一半不缩放，位置全乱）。
    double maxX = 0, maxY = 0;
    for (int i = 0; i < n; i++) {
        if (!s[i].touching) continue;
        if (s[i].x > maxX) maxX = s[i].x;
        if (s[i].y > maxY) maxY = s[i].y;
    }
    CGFloat ratio = 1.0;
    if (maxX > sb.width + 2 || maxY > sb.height + 2) {
        ratio = TDscreenScaleRatio();
        if (ratio < 1.2 || ratio > 4.0) ratio = [UIScreen mainScreen].nativeScale;
        if (ratio < 1.2 || ratio > 4.0) ratio = 1.0;
        TDLog(@"录制坐标按像素处理：原始最大 (%.0f, %.0f) 屏宽 %.0f 换算比 %.3f",
              maxX, maxY, sb.width, ratio);
    } else {
        TDLog(@"录制坐标最大 (%.0f, %.0f)，按点处理", maxX, maxY);
    }

    BOOL down = NO, moved = NO;
    uint64_t downT = 0, lastEnd = s[0].t;
    double sx = 0, sy = 0, lx = 0, ly = 0;
    const double moveThresh = 12.0;

    for (int i = 0; i < n; i++) {
        double x = s[i].x / ratio;
        double y = s[i].y / ratio;

        if (s[i].touching && !down) {
            down = YES;
            moved = NO;
            sx = x; sy = y; lx = x; ly = y;
            downT = s[i].t;
            continue;
        }
        if (s[i].touching && down) {
            lx = x; ly = y;
            if (!moved && hypot(x - sx, y - sy) > moveThresh) moved = YES;
            continue;
        }
        if (!s[i].touching && down) {
            down = NO;
            double durMs = TDmsBetween(s[i].t, downT);

            // 从屏幕最底部起手往上拖 = 上滑回桌面，别录进去
            if (sy > sb.height - 44 && moved && ly < sy - 60) {
                lastEnd = s[i].t;
                continue;
            }

            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"gap"] = @((NSInteger)MAX(0.0, TDmsBetween(downT, lastEnd)));

            double cx = sx, cy = sy;
            cx = MAX(0, MIN(sb.width  - 1, cx));
            cy = MAX(0, MIN(sb.height - 1, cy));

            if (!moved && durMs < 450) {
                d[@"t"] = @"tap";
                d[@"x"] = @((NSInteger)lround(cx));
                d[@"y"] = @((NSInteger)lround(cy));
            } else if (!moved) {
                d[@"t"] = @"long";
                d[@"x"] = @((NSInteger)lround(cx));
                d[@"y"] = @((NSInteger)lround(cy));
                d[@"ms"] = @((NSInteger)MAX(300.0, durMs));
            } else {
                double ex = MAX(0, MIN(sb.width  - 1, lx));
                double ey = MAX(0, MIN(sb.height - 1, ly));
                if (hypot(ex - cx, ey - cy) < moveThresh) {
                    d[@"t"] = @"tap";
                    d[@"x"] = @((NSInteger)lround(cx));
                    d[@"y"] = @((NSInteger)lround(cy));
                } else {
                    d[@"t"] = @"swipe";
                    d[@"x1"] = @((NSInteger)lround(cx));
                    d[@"y1"] = @((NSInteger)lround(cy));
                    d[@"x2"] = @((NSInteger)lround(ex));
                    d[@"y2"] = @((NSInteger)lround(ey));
                    d[@"ms"] = @((NSInteger)MAX(80.0, durMs));
                }
            }
            [out addObject:d];
            lastEnd = s[i].t;
        }
    }

    return out;
}

@end
