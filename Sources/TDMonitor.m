#import "TD.h"
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <math.h>

// ===========================================================================
// 录制：全屏取点层（不碰任何私有 HID 监听接口）
//
// 为什么放弃系统级触摸监听：
//   IOHIDEventSystemClientRegisterEventCallback 的回调原型在不同系统上
//   参数个数不一致，一旦对不上就是 EXC_BAD_ACCESS，且崩在 IOKit 内部，
//   进程里根本拦不住。三轮实测（v1.1.3 点录制就崩、v1.1.4/1.1.5 倒计时后崩）
//   全部落在这个回调里，代价太高，这条路直接弃用。
//
// 现在怎么做：
//   把我们自己的托管窗口（平时是 128×70 的悬浮条）临时铺满全屏，
//   盖一层几乎透明的手势收集层，直接在上面点/滑。
//   这一层在窗口服务器里就是「我们的窗口」，触摸必然投递到本进程，
//   坐标就是屏幕坐标，跟抖音的实际坐标 1:1，不存在点偏。
//   录完把窗口缩回悬浮条，抖音恢复正常。
//
// 代价：录制时抖音自己不响应（触摸被这层接住了），这是取点模式的常态。
// ===========================================================================

#pragma mark - 轻量轨迹日志（排障用）

static char gTracePath[1024] = {0};

static void TDTraceInit(void) {
    if (gTracePath[0] != 0) return;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES) firstObject];
    NSString *p = [dir stringByAppendingPathComponent:@"trace.log"];
    snprintf(gTracePath, sizeof(gTracePath), "%s", p.fileSystemRepresentation);
}

/// 只在主线程调用
static void TDTrace(const char *fmt, ...) {
    TDTraceInit();
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

NSString *TDtraceLogText(void) {
    TDTraceInit();
    NSString *path = gTracePath[0] ? [NSString stringWithUTF8String:gTracePath] : nil;
    if (!path) return @"";
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return s ?: @"";
}

void TDtraceLogClear(void) {
    TDTraceInit();
    if (gTracePath[0] != 0) unlink(gTracePath);
}

#pragma mark - 取点层

#define TD_MARK_R 14.0
#define TD_MOVE_THRESHOLD 12.0

@interface TDPickerView : UIView
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *steps;
@property (nonatomic, copy) void (^onStepsChanged)(void);
@property (nonatomic, copy) void (^onFinish)(void);
@property (nonatomic, copy) void (^onCancel)(void);
- (void)undo;
@end

/// 私有方法先声明，避免「方法定义在使用之后」的编译告警
@interface TDPickerView ()
- (UIButton *)buttonWithTitle:(NSString *)t color:(UIColor *)c sel:(SEL)sel;
- (void)updateTitle;
- (void)onUndo;
- (void)onDone;
- (void)onCancelTap;
- (void)commitWithDuration:(double)durMs;
- (void)drawDot:(CGPoint)p index:(NSInteger)idx color:(UIColor *)color;
@end

@implementation TDPickerView {
    UIView *_panel;
    UILabel *_title;
    UILabel *_hint;
    UIButton *_undoBtn;
    UIButton *_doneBtn;
    UIButton *_cancelBtn;

    BOOL _active;
    BOOL _moved;
    BOOL _live;
    CGPoint _startP;
    CGPoint _lastP;
    CGPoint _curP;
    CFTimeInterval _startT;
    CFTimeInterval _lastEndT;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.10];
    self.multipleTouchEnabled = NO;
    self.opaque = NO;
    self.clipsToBounds = YES;

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    _panel.layer.cornerRadius = 14;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [self addSubview:_panel];

    _title = [[UILabel alloc] initWithFrame:CGRectZero];
    _title.textColor = [UIColor whiteColor];
    _title.font = [UIFont boldSystemFontOfSize:14];
    [_panel addSubview:_title];

    _hint = [[UILabel alloc] initWithFrame:CGRectZero];
    _hint.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    _hint.font = [UIFont systemFontOfSize:11];
    _hint.numberOfLines = 2;
    _hint.text = @"在要点的位置点一下 · 按住不动=长按 · 滑动=滑动";
    [_panel addSubview:_hint];

    _undoBtn = [self buttonWithTitle:@"撤销" color:[UIColor colorWithWhite:0.30 alpha:1] sel:@selector(onUndo)];
    _doneBtn = [self buttonWithTitle:@"完成" color:[UIColor colorWithRed:0.18 green:0.66 blue:0.32 alpha:1] sel:@selector(onDone)];
    _cancelBtn = [self buttonWithTitle:@"取消" color:[UIColor colorWithRed:0.78 green:0.22 blue:0.22 alpha:1] sel:@selector(onCancelTap)];
    [_panel addSubview:_undoBtn];
    [_panel addSubview:_doneBtn];
    [_panel addSubview:_cancelBtn];

    [self updateTitle];
    return self;
}

- (UIButton *)buttonWithTitle:(NSString *)t color:(UIColor *)c sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = c;
    b.layer.cornerRadius = 9;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat top = safe.top > 0 ? safe.top : 26;
    CGFloat pw = w - 20;
    _panel.frame = CGRectMake(10, top + 6, pw, 104);
    _title.frame = CGRectMake(12, 10, pw - 24, 18);
    _hint.frame = CGRectMake(12, 30, pw - 24, 30);

    CGFloat by = 64, bh = 34, gap = 8;
    CGFloat ubw = 62, cbw = 62;
    _undoBtn.frame = CGRectMake(12, by, ubw, bh);
    _cancelBtn.frame = CGRectMake(pw - 12 - cbw, by, cbw, bh);
    _doneBtn.frame = CGRectMake(12 + ubw + gap, by,
                                pw - 24 - ubw - cbw - gap * 2, bh);
}

- (void)updateTitle {
    _title.text = [NSString stringWithFormat:@"取点中 · 已记录 %lu 步",
                   (unsigned long)self.steps.count];
    _undoBtn.alpha = self.steps.count ? 1 : 0.4;
}

- (void)onUndo {
    [self undo];
}

- (void)onDone {
    TDTrace("picker done, steps=%lu", (unsigned long)self.steps.count);
    if (self.onFinish) self.onFinish();
}

- (void)onCancelTap {
    TDTrace("picker cancel");
    if (self.onCancel) self.onCancel();
}

- (void)undo {
    if (self.steps.count == 0) return;
    [self.steps removeLastObject];
    _lastEndT = 0;
    [self updateTitle];
    [self setNeedsDisplay];
    if (self.onStepsChanged) self.onStepsChanged();
}

#pragma mark 触摸

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_active) return;
    UITouch *t = touches.anyObject;
    if (!t) return;

    _active = YES;
    _moved = NO;
    _live = YES;
    _startP = [t locationInView:self];
    _curP = _startP;
    _lastP = _startP;
    _startT = CACurrentMediaTime();
    TDTrace("picker touch began (%.0f,%.0f)", _startP.x, _startP.y);
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    UITouch *t = touches.anyObject;
    if (!t) return;
    _curP = [t locationInView:self];
    _lastP = _curP;
    if (!_moved && hypot(_curP.x - _startP.x, _curP.y - _startP.y) > TD_MOVE_THRESHOLD) {
        _moved = YES;
    }
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    UITouch *t = touches.anyObject;
    if (t) {
        _curP = [t locationInView:self];
        if (!_moved && hypot(_curP.x - _startP.x, _curP.y - _startP.y) > TD_MOVE_THRESHOLD) {
            _moved = YES;
        }
        if (_moved) _lastP = _curP;
    }
    double durMs = (CACurrentMediaTime() - _startT) * 1000.0;
    [self commitWithDuration:durMs];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _active = NO;
    _live = NO;
    [self setNeedsDisplay];
}

- (void)commitWithDuration:(double)durMs {
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 1) sb = self.bounds;

    double gap = _lastEndT > 0 ? (CACurrentMediaTime() - _lastEndT) * 1000.0 : 0;
    gap = MAX(0.0, MIN(60000.0, gap));

    double x = MAX(0.0, MIN(sb.size.width  - 1, _startP.x));
    double y = MAX(0.0, MIN(sb.size.height - 1, _startP.y));

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"gap"] = @((NSInteger)lround(gap));

    double dist = hypot(_lastP.x - _startP.x, _lastP.y - _startP.y);
    if (_moved && dist >= TD_MOVE_THRESHOLD) {
        double x2 = MAX(0.0, MIN(sb.size.width  - 1, _lastP.x));
        double y2 = MAX(0.0, MIN(sb.size.height - 1, _lastP.y));
        d[@"t"] = @"swipe";
        d[@"x1"] = @((NSInteger)lround(x));
        d[@"y1"] = @((NSInteger)lround(y));
        d[@"x2"] = @((NSInteger)lround(x2));
        d[@"y2"] = @((NSInteger)lround(y2));
        d[@"ms"] = @((NSInteger)MAX(80.0, durMs));
    } else if (durMs >= 500) {
        d[@"t"] = @"long";
        d[@"x"] = @((NSInteger)lround(x));
        d[@"y"] = @((NSInteger)lround(y));
        d[@"ms"] = @((NSInteger)MAX(500.0, durMs));
    } else {
        d[@"t"] = @"tap";
        d[@"x"] = @((NSInteger)lround(x));
        d[@"y"] = @((NSInteger)lround(y));
    }

    [self.steps addObject:d];
    TDTrace("picker step %s (%.0f,%.0f) dur=%.0f",
            [d[@"t"] UTF8String], x, y, durMs);

    _lastEndT = CACurrentMediaTime();
    _active = NO;
    _live = NO;
    [self updateTitle];
    [self setNeedsDisplay];
    if (self.onStepsChanged) self.onStepsChanged();

    // 轻微振动反馈（后台可能拿不到，失败就算了）
    @try {
        UIImpactFeedbackGenerator *g =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g prepare];
        [g impactOccurred];
    } @catch (NSException *e) { }
}

#pragma mark 绘制

- (void)drawDot:(CGPoint)p index:(NSInteger)idx color:(UIColor *)color {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:0.92].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(p.x - TD_MARK_R, p.y - TD_MARK_R,
                                               TD_MARK_R * 2, TD_MARK_R * 2));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.85].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(p.x - TD_MARK_R, p.y - TD_MARK_R,
                                                 TD_MARK_R * 2, TD_MARK_R * 2));
    if (idx > 0) {
        NSString *s = [NSString stringWithFormat:@"%ld", (long)idx];
        UIFont *f = [UIFont boldSystemFontOfSize:12];
        CGSize sz = [s sizeWithAttributes:@{NSFontAttributeName: f}];
        [s drawAtPoint:CGPointMake(p.x - sz.width / 2, p.y - sz.height / 2)
        withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.whiteColor}];
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIColor *tapColor  = [UIColor colorWithRed:0.22 green:0.72 blue:0.36 alpha:1];
    UIColor *longColor = [UIColor colorWithRed:1.00 green:0.60 blue:0.10 alpha:1];
    UIColor *swipeColor = [UIColor colorWithRed:0.22 green:0.62 blue:1.00 alpha:1];

    NSInteger i = 0;
    for (NSDictionary *d in self.steps) {
        i++;
        NSString *t = d[@"t"];
        if ([t isEqualToString:@"swipe"]) {
            CGPoint a = CGPointMake([d[@"x1"] doubleValue], [d[@"y1"] doubleValue]);
            CGPoint b = CGPointMake([d[@"x2"] doubleValue], [d[@"y2"] doubleValue]);
            CGContextSetStrokeColorWithColor(ctx, [swipeColor colorWithAlphaComponent:0.9].CGColor);
            CGContextSetLineWidth(ctx, 3);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextMoveToPoint(ctx, a.x, a.y);
            CGContextAddLineToPoint(ctx, b.x, b.y);
            CGContextStrokePath(ctx);
            [self drawDot:a index:i color:swipeColor];
            [self drawDot:b index:0 color:swipeColor];
        } else {
            CGPoint a = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
            [self drawDot:a index:i
                    color:([t isEqualToString:@"long"] ? longColor : tapColor)];
        }
    }

    if (_live) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.75].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextMoveToPoint(ctx, _startP.x, _startP.y);
        CGContextAddLineToPoint(ctx, _curP.x, _curP.y);
        CGContextStrokePath(ctx);
    }
}

@end

#pragma mark - 录制器

static TDPickerView *gPicker = nil;
static NSString *gStatus = @"就绪（全屏取点）";

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

- (NSInteger)eventCount { return (NSInteger)gPicker.steps.count; }
- (NSInteger)rawEventCount { return (NSInteger)gPicker.steps.count; }
- (NSString *)status { return gStatus; }

- (BOOL)start {
    if (self.recording) return YES;
    if ([TDEngine shared].running) [[TDEngine shared] stop];

    TDTraceInit();
    unlink(gTracePath);
    TDTrace("picker: start");

    if (!TDFloatWindow()) TDFloatInstall();
    UIWindow *w = TDFloatWindow();
    if (!w) {
        gStatus = @"悬浮窗没建起来，取点层无处安放";
        return NO;
    }

    // 铺满全屏 —— 这一层就是我们的窗口，触摸一定会投递到本进程
    TDFloatSetFullScreen(YES);

    TDPickerView *p = [[TDPickerView alloc] initWithFrame:w.bounds];
    p.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    p.steps = [NSMutableArray array];

    __weak typeof(self) ws = self;
    p.onStepsChanged = ^{
        typeof(self) ss = ws;
        if (!ss) return;
        if (ss.onChange) ss.onChange();
    };
    p.onFinish = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (ss) [ss finishAndSave];
        });
    };
    p.onCancel = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (ss) [ss cancel];
        });
    };

    [w.rootViewController.view addSubview:p];
    [w.rootViewController.view bringSubviewToFront:p];
    gPicker = p;

    gStatus = @"取点中（窗口已铺满全屏）";
    self.recording = YES;
    TDTrace("picker: mounted, window=%.0fx%.0f", w.bounds.size.width, w.bounds.size.height);
    if (self.onChange) self.onChange();
    return YES;
}

- (void)teardown {
    self.recording = NO;
    TDPickerView *p = gPicker;
    gPicker = nil;
    [p removeFromSuperview];
    TDFloatSetFullScreen(NO);
    gStatus = @"就绪（全屏取点）";
    TDTrace("picker: teardown");
    if (self.onChange) self.onChange();
}

- (void)cancel {
    if (!self.recording) return;
    [self teardown];
    TDLog(@"已取消录制，没有保存");
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

- (void)finishAndSave {
    if (!self.recording) return;
    NSMutableArray<NSDictionary *> *steps = [gPicker.steps mutableCopy] ?: [NSMutableArray array];
    [self teardown];

    TDScript *s = [[TDScriptStore shared] createScript];
    if (steps.count) s.steps = steps;
    [[TDScriptStore shared] save];

    TDLog(@"录制完成：%@（%lu 步）", s.name, (unsigned long)s.steps.count);
    TDTrace("picker: saved %lu steps", (unsigned long)steps.count);
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

- (NSMutableArray<NSDictionary *> *)stop {
    if (!self.recording) return nil;
    NSMutableArray *steps = [gPicker.steps mutableCopy] ?: [NSMutableArray array];
    [self teardown];
    return steps;
}

@end
