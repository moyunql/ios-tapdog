#import "TD.h"
#import "IOHIDEvent.h"
#import "IOHIDEventTypes.h"
#import "IOHIDEventSystemClient.h"
#import <dlfcn.h>
#import <os/lock.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>

// ===========================================================================
// 录制：系统级触摸监听（display integrated digitizer）
//
// 历史坑位，逐条记着：
//  1) RegisterEventCallback 的回调是 4 个参数：
//     void (*)(void *target, void *refcon, IOHIDEventQueueRef queue, IOHIDEventRef event)
//     少写一个参数 = 把 queue 当 event 读 = 一点录制就 EXC_BAD_ACCESS。
//  2) 回调跑在 HID 的事件线程，里面绝不能发 ObjC 消息 / 读 UIScreen / 改容器。
//     这里只做纯 C 提取 + 加锁写定长数组，解析留给主线程。
//  3) 不要用 kIOHIDEventFieldDigitizerIsDisplayIntegrated 做硬过滤。
//     这个字段在 hand 父事件上有、在 finger 子事件上经常读不到 0；
//     一旦按它过滤，就变成「一个都收不到」——之前「录不到点击」就是这个。
//     现在不过滤，只记录，谁上报就用谁。
//
// 权限：com.apple.private.hid.client.event-monitor / event-filter
// ===========================================================================

#define TD_SAMPLE_MAX 6144

typedef struct {
    uint64_t t;        // mach_absolute_time
    double   x, y;     // 原始上报坐标（可能为点，也可能是像素）
    uint8_t  touching;
} TDSample;

static TDSample gSamples[TD_SAMPLE_MAX];
static volatile int gSampleCount = 0;
static volatile int gArmed = 0;
static os_unfair_lock gSampleLock = OS_UNFAIR_LOCK_INIT;

// 诊断计数（回调里自增，主线程只读）
static volatile int32_t gRawEvents = 0;      // 收到的 digitizer 事件数
static volatile int32_t gPushedEvents = 0;   // 真正存下来的样本数

typedef IOHIDEventSystemClientRef (*TDCreateWithTypeFn)(CFAllocatorRef, uint32_t, CFDictionaryRef);

// !! 4 个参数，第 3 个是 IOHIDEventQueueRef !!
typedef void (*TDEventCallback)(void *target, void *refcon, void *queue, IOHIDEventRef event);
// 老 filter 接口是 3 个参数，且必须把 event 原样返回
typedef IOHIDEventRef (*TDFilterCallback)(void *target, void *refcon, IOHIDEventRef event);

typedef void (*TDRegisterEventFn)(IOHIDEventSystemClientRef, TDEventCallback, void *, void *);
typedef void (*TDRegisterFilterFn)(IOHIDEventSystemClientRef, TDFilterCallback, void *, void *);
typedef void (*TDScheduleFn)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);

static IOHIDEventSystemClientRef gClient = NULL;
static IOHIDEventSystemClientRef gFilterClient = NULL;   // 备用通道
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

static int  gFingerDown = 0;      // 回调线程私有的按下状态
static double gLastPushedX = -1e9, gLastPushedY = -1e9;
static int  gTraceFirst = 0;

// 崩溃定位用的轻量 trace：回调线程里不能发 ObjC 消息，
// 所以路径在 start 时（主线程）就准备好，这里只做 fopen/fprintf。
static char gTracePath[1024] = {0};

static void TDTrace(const char *fmt, ...) {
    if (gTracePath[0] == 0) return;
    FILE *fp = fopen(gTracePath, "a");
    if (!fp) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fp, fmt, ap);
    va_end(ap);
    fputc('\n', fp);
    fclose(fp);
}

static void TDPushSample(double x, double y, int touching) {
    os_unfair_lock_lock(&gSampleLock);
    if (gSampleCount < TD_SAMPLE_MAX) {
        TDSample *s = &gSamples[gSampleCount];
        s->t = mach_absolute_time();
        s->x = x;
        s->y = y;
        s->touching = (uint8_t)(touching ? 1 : 0);
        gSampleCount = gSampleCount + 1;
        __sync_fetch_and_add(&gPushedEvents, 1);
    }
    os_unfair_lock_unlock(&gSampleLock);
}

static void TDHandleRawEvent(IOHIDEventRef event) {
    if (!gArmed || !event) return;
    IOHIDEventType t = IOHIDEventGetType(event);
    if (!gTraceFirst) { gTraceFirst = 1; TDTrace("回调首次触发 type=%d", (int)t); }
    if (t != kIOHIDEventTypeDigitizer) return;

    __sync_fetch_and_add(&gRawEvents, 1);

    CFArrayRef kids = IOHIDEventGetChildren(event);
    CFIndex n = 0;
    if (kids && CFGetTypeID(kids) == CFArrayGetTypeID()) n = CFArrayGetCount(kids);
    if (gTraceFirst == 1) { gTraceFirst = 2; TDTrace("首次 digitizer 事件 kids=%d", (int)n); }

    if (n > 0) {
        // 只取第一根手指；多指手势不支持
        CFTypeRef c0 = CFArrayGetValueAtIndex(kids, 0);
        if (!c0 || CFGetTypeID(c0) != IOHIDEventGetTypeID()) return;

        IOHIDEventRef f = (IOHIDEventRef)c0;
        int touching = (int)IOHIDEventGetIntegerValue(f, kIOHIDEventFieldDigitizerTouch);
        if (!touching) {
            // 子事件明确说没接触，但 collection 里还有它 —— 当作抬起处理
            if (!gFingerDown) return;
            gFingerDown = 0;
            TDPushSample(0, 0, 0);
            gLastPushedX = -1e9;
            return;
        }

        double x = IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerX);
        double y = IOHIDEventGetFloatValue(f, kIOHIDEventFieldDigitizerY);

        gFingerDown = 1;
        // 原地抖动不用每帧都存，省缓冲
        if (fabs(x - gLastPushedX) < 5.0 && fabs(y - gLastPushedY) < 5.0) return;
        gLastPushedX = x;
        gLastPushedY = y;
        TDPushSample(x, y, 1);
        return;
    }

    // collection 里一根手指都没有 = 抬手（只在按下过之后记一次）
    if (!gFingerDown) return;
    gFingerDown = 0;
    gLastPushedX = -1e9;
    TDPushSample(0, 0, 0);
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
- (NSInteger)rawEventCount { return (NSInteger)gRawEvents; }
- (NSString *)status { return gStatus; }

- (BOOL)openMonitor {
    if (gClient) return YES;

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
    TDLog(@"触摸监听已建立：%@", gStatus);
    return YES;
}

/// 备用通道已停用（Filter 类型的 client 会插进系统事件链，
/// 一旦回调有任何问题，整个系统的触摸都会跟着出问题，风险太大）。
- (void)armFallbackTimer { /* 空实现，保留调用点 */ }

- (BOOL)start {
    @try {
        if (self.recording) return YES;
        if ([TDEngine shared].running) [[TDEngine shared] stop];

        // trace 路径要在主线程准备好，回调线程里才敢直接 fopen
        if (gTracePath[0] == 0) {
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                 NSUserDomainMask, YES) firstObject];
            NSString *p = [dir stringByAppendingPathComponent:@"trace.log"];
            snprintf(gTracePath, sizeof(gTracePath), "%s", p.fileSystemRepresentation);
        }
        unlink(gTracePath);
        gTraceFirst = 0;
        TDTrace("start: 准备建立监听");

        if (![self openMonitor]) { TDTrace("openMonitor 失败"); return NO; }
        TDTrace("监听已建立");

        // 切到抖音后要保持进程活着，否则一个事件都收不到
        [TDKeepAlive ensure];
        TDTrace("保活 ok");

        os_unfair_lock_lock(&gSampleLock);
        gSampleCount = 0;
        os_unfair_lock_unlock(&gSampleLock);
        gRawEvents = 0;
        gPushedEvents = 0;
        gFingerDown = 0;
        gLastPushedX = -1e9;
        gLastPushedY = -1e9;

        self.recording = YES;
        gArmed = 1;
        [self armFallbackTimer];
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

    // 备用通道用一次就拆掉，避免下次录制两条通道重复入样
    if (gFilterClient) {
        typedef void (*TDCancelFn)(IOHIDEventSystemClientRef);
        TDCancelFn cancel = (TDCancelFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCancel");
        if (cancel) cancel(gFilterClient);
        CFRelease(gFilterClient);
        gFilterClient = NULL;
    }
    static TDSample buf[TD_SAMPLE_MAX];
    int n = 0;
    os_unfair_lock_lock(&gSampleLock);
    n = gSampleCount;
    if (n > TD_SAMPLE_MAX) n = TD_SAMPLE_MAX;
    if (n > 0) memcpy(buf, gSamples, sizeof(TDSample) * (size_t)n);
    gSampleCount = 0;
    os_unfair_lock_unlock(&gSampleLock);

    TDLog(@"录制停止：系统事件 %d · 采样 %d", (int)gRawEvents, n);

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
        TDLog(@"坐标按像素换算：最大 (%.0f, %.0f) / 屏宽 %.0f = %.3f", maxX, maxY, sb.width, ratio);
    } else {
        TDLog(@"坐标按点处理：最大 (%.0f, %.0f)", maxX, maxY);
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

            // 从屏幕最底部起手往上拖 = 上滑回桌面，别录
            if (sy > sb.height - 44 && moved && ly < sy - 60) {
                lastEnd = s[i].t;
                continue;
            }

            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"gap"] = @((NSInteger)MAX(0.0, TDmsBetween(downT, lastEnd)));

            double cx = MAX(0, MIN(sb.width  - 1, sx));
            double cy = MAX(0, MIN(sb.height - 1, sy));

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

NSString *TDtraceLogText(void) {
    NSString *path = nil;
    if (gTracePath[0] != 0) {
        path = [NSString stringWithUTF8String:gTracePath];
    } else {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                            NSUserDomainMask, YES) firstObject];
        path = [dir stringByAppendingPathComponent:@"trace.log"];
    }
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return s ?: @"";
}

void TDtraceLogClear(void) {
    if (gTracePath[0] != 0) unlink(gTracePath);
}
