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
// 12pt 太灵敏：手指按下时的轻微滚动会被记成一次「滑动」，回放时抖音只会抖一下。
// 16pt 大约是手指垫的宽度，超过它才真的算要滑。
#define TD_MOVE_THRESHOLD 16.0
// 滑动时长下限。录时有人的手很快，80ms 的一划系统会当成轻扫丢掉，
// 回放出来抖音原地不动；拉到 160ms 依然像"快速一划"，但能被认。
#define TD_SWIPE_MIN_MS 160.0

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
    // 完全透明：录制滑动要靠眼睛看画面定起点，10% 的灰罩会让颜色发闷。
    // 透明背景不影响 hitTest（view.alpha 仍是 1），触摸照收。
    self.backgroundColor = [UIColor clearColor];
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
        d[@"ms"] = @((NSInteger)MAX(TD_SWIPE_MIN_MS, durMs));
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
        // 手指还按着：把「从哪起手、现在到哪、走了多远」实时画出来。
        // 之前只画一根白线，滑动时看不出自己滑了多长，经常录出 20pt 的「假滑动」。
        CGFloat dist = (CGFloat)hypot(_curP.x - _startP.x, _curP.y - _startP.y);
        BOOL moving = dist > TD_MOVE_THRESHOLD;
        UIColor *c = moving ? swipeColor : tapColor;

        CGContextSetStrokeColorWithColor(ctx, [c colorWithAlphaComponent:0.85].CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextMoveToPoint(ctx, _startP.x, _startP.y);
        CGContextAddLineToPoint(ctx, _curP.x, _curP.y);
        CGContextStrokePath(ctx);

        // 起点留个小空心圈，方便看这次是从哪里起手的
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.7].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(_startP.x - 8, _startP.y - 8, 16, 16));

        // 当前指尖
        CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.5].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(_curP.x - 11, _curP.y - 11, 22, 22));
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(_curP.x - 11, _curP.y - 11, 22, 22));

        NSString *s = moving ? [NSString stringWithFormat:@"滑动 %.0fpt", dist] : @"按住";
        UIFont *f = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        CGSize sz = [s sizeWithAttributes:@{NSFontAttributeName: f}];
        CGPoint tp = CGPointMake(_curP.x - sz.width / 2, _curP.y - 34);
        tp.x = MAX(6, MIN(self.bounds.size.width - sz.width - 6, tp.x));
        tp.y = MAX(6, MIN(self.bounds.size.height - sz.height - 6, tp.y));
        [s drawAtPoint:tp withAttributes:@{NSFontAttributeName: f,
                                           NSForegroundColorAttributeName: UIColor.whiteColor}];
    }
}

@end

#pragma mark - 录制器
//
// 两种模式：
//   取点（start）     —— 把窗口铺满全屏，坐在抖音上面接住触摸。
//                        坐标准、不依赖任何私有接口，但录的时候抖音是死的。
//   穿透（startLive）  —— 蒙版完全不碰触摸，用户在抖音里真操作，
//                        我们从 HID 监听里抄同一批触摸。能边刷边录，
//                        而且录到的就是「抖音真的翻页了」的那一刻。

static TDPickerView *gPicker = nil;
static NSString *gStatus = @"就绪（全屏取点）";

#define TD_LIVE_TICK   0.05     // 消费轨迹的节拍
#define TD_LIVE_MOVE   16.0     // 位移超过它才算「滑」
#define TD_LIVE_CURVE  14.0     // 偏离起终点连线超过它 → 记成轨迹而不是两点滑动

@interface TDRecorder () {
    BOOL _live;                             // 当前是不是穿透录制
    NSInteger _liveCursor;                  // 已经消费到第几个样本
    NSMutableArray<NSValue *> *_liveTrack;  // 这根手指走过的点（已转屏幕坐标）
    double _liveStartTs;                    // 按下时刻（秒）
    CFTimeInterval _liveLastEnd;            // 上一次手势结束的时刻
    NSInteger _liveSpace;                   // -1 未知 / 0 归一化 / 1 点 / 2 像素
    NSTimer *_liveTimer;
    NSMutableArray<NSDictionary *> *_liveSteps;
    BOOL _liveIgnore;                       // 这一笔落在我们自己身上（悬浮条/本 App），不录
}
@property (nonatomic, readwrite) BOOL recording;
- (void)liveTick;
- (void)liveFlush;
- (void)liveFinishTrackAt:(CGPoint)p time:(double)sec;
- (NSArray *)liveSampleTrack:(NSArray<NSValue *> *)track to:(CGPoint)end;
@end

@implementation TDRecorder

+ (instancetype)shared {
    static TDRecorder *r = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [TDRecorder new]; });
    return r;
}

- (NSInteger)eventCount {
    return _live ? (NSInteger)_liveSteps.count : (NSInteger)gPicker.steps.count;
}
- (NSInteger)rawEventCount { return [self eventCount]; }
- (NSString *)status { return gStatus; }

#pragma mark 取点模式

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

    _live = NO;
    gStatus = @"取点中（窗口已铺满全屏）";
    self.recording = YES;
    TDTrace("picker: mounted, window=%.0fx%.0f", w.bounds.size.width, w.bounds.size.height);
    if (self.onChange) self.onChange();
    return YES;
}

#pragma mark 穿透模式

- (BOOL)startLive {
    if (self.recording) return YES;
    if ([TDEngine shared].running) [[TDEngine shared] stop];

    // 监听必须先在跑。没学到过真实触摸也能录（轨迹照样抄得到），
    // 只是量纲要靠第一帧自己猜，所以这里不因为没学到就拒绝启动。
    if (!TDHIDSampleStart()) {
        gStatus = @"HID 监听起不来，穿透录制不可用";
        return NO;
    }

    TDHIDTraceStart();

    // 录制时人是在抖音里，我们的进程必须在后台继续跑：
    // 一旦被挂起，HID 监听回调不执行、消费定时器也停，录出来就是空的。
    [TDKeepAlive ensure];

    _live = YES;
    _liveCursor = 0;
    _liveTrack = nil;
    _liveSteps = [NSMutableArray array];
    _liveLastEnd = 0;
    _liveSpace = TDHIDSampleSpace();

    TDMaskShow();
    TDMaskSetSteps(_liveSteps);
    TDMaskSetHint(nil);
    TDMaskSetLive(CGPointZero, NO);

    gStatus = @"穿透录制中（触摸直通抖音）";
    self.recording = YES;
    TDTrace("live: start, space=%ld", (long)_liveSpace);

    __weak typeof(self) ws = self;
    _liveTimer = [NSTimer scheduledTimerWithTimeInterval:TD_LIVE_TICK
                                                 repeats:YES
                                                   block:^(NSTimer *t) { [ws liveTick]; }];
    if (self.onChange) self.onChange();
    return YES;
}

- (void)liveTick {
    if (!_live) return;

    NSInteger total = TDHIDTraceCount();
    if (total <= _liveCursor) return;

    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGFloat sc = [UIScreen mainScreen].scale;
    if (scr.width < 1 || sc < 1) sc = 1;

    // 人在自己 App 里的时候，屏幕上所有触摸都是我们的按钮 —— 一律不录。
    // 切到抖音后 App 变 inactive，录制照常。
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        _liveCursor = total;
        _liveTrack = nil;
        _liveIgnore = NO;
        return;
    }
    CGRect selfRect = TDFloatTouchRect();

    for (NSInteger i = _liveCursor; i < total; i++) {
        CGFloat rx = 0, ry = 0;
        double ts = 0;
        BOOL down = NO;
        if (!TDHIDTraceAt(i, &rx, &ry, &ts, &down)) break;

        if (_liveSpace < 0) {
            CGFloat m = MAX(rx, ry);
            if (m > MAX(scr.width, scr.height) + 1) _liveSpace = 2;
            else if (m > 1.001f) _liveSpace = 1;
            else _liveSpace = 0;
        }

        CGFloat x = rx, y = ry;
        if (_liveSpace == 0)      { x = rx * scr.width;  y = ry * scr.height; }
        else if (_liveSpace == 2) { x = rx / sc;         y = ry / sc; }
        x = MAX(0, MIN(scr.width  - 1, x));
        y = MAX(0, MIN(scr.height - 1, y));

        double sec = TDHIDTraceSeconds((uint64_t)ts);

        CGPoint pt = CGPointMake(x, y);

        if (down) {
            if (_liveIgnore) continue;
            if (!_liveTrack) {
                // 落在悬浮条上的按下（用户按 ■ 停止那一下）不算一步
                if (!CGRectIsNull(selfRect) && CGRectContainsPoint(selfRect, pt)) {
                    _liveIgnore = YES;
                    continue;
                }
                _liveTrack = [NSMutableArray array];
                _liveStartTs = sec;
            }
            [_liveTrack addObject:[NSValue valueWithCGPoint:pt]];
            TDMaskSetLive(pt, YES);
        } else {
            if (_liveIgnore) {
                _liveIgnore = NO;
                _liveTrack = nil;
                continue;
            }
            [self liveFinishTrackAt:pt time:sec];
        }
    }
    _liveCursor = total;
}

/// 一根手指离开屏幕：把这段轨迹切成一步
- (void)liveFinishTrackAt:(CGPoint)p time:(double)sec {
    if (!_liveTrack.count) return;
    if (!(sec > _liveStartTs)) sec = _liveStartTs + 0.05;
    [_liveTrack addObject:[NSValue valueWithCGPoint:p]];

    NSInteger n = (NSInteger)_liveTrack.count;
    CGPoint a = [_liveTrack[0] CGPointValue];

    // 抬手前手指常常会往回带一点，直接用最后一点会把 400pt 的滑动
    // 记成 60pt。用「离起点最远的那一点」当终点稳得多。
    CGFloat maxD = 0;
    CGPoint far = a;
    for (NSInteger i = 1; i < n; i++) {
        CGPoint q = [_liveTrack[i] CGPointValue];
        CGFloat d = (CGFloat)hypot(q.x - a.x, q.y - a.y);
        if (d > maxD) { maxD = d; far = q; }
    }

    double durMs = (sec - _liveStartTs) * 1000.0;
    if (!(durMs >= 0)) durMs = 0;

    CFTimeInterval now = CACurrentMediaTime();
    double gap = _liveLastEnd > 0 ? (now - _liveLastEnd) * 1000.0 : 0;
    gap = MAX(0.0, MIN(60000.0, gap));
    _liveLastEnd = now;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"gap"] = @((NSInteger)lround(gap));

    if (maxD < TD_LIVE_MOVE) {
        if (durMs >= 500) {
            d[@"t"] = @"long";
            d[@"x"] = @((NSInteger)lround(a.x));
            d[@"y"] = @((NSInteger)lround(a.y));
            d[@"ms"] = @((NSInteger)MAX(500.0, durMs));
        } else {
            d[@"t"] = @"tap";
            d[@"x"] = @((NSInteger)lround(a.x));
            d[@"y"] = @((NSInteger)lround(a.y));
        }
    } else {
        // 弯曲度：所有点到「起点→最远点」这条直线的最大偏离。
        // 直上直下就存成两点滑动（回放更像人），明显走弧线才存整条轨迹。
        CGFloat dev = 0;
        CGFloat dx = far.x - a.x, dy = far.y - a.y;
        CGFloat len = (CGFloat)hypot(dx, dy);
        if (len < 1) len = 1;
        for (NSValue *v in _liveTrack) {
            CGPoint q = v.CGPointValue;
            CGFloat c2 = (CGFloat)fabs((dx * (q.y - a.y) - dy * (q.x - a.x)) / len);
            if (c2 > dev) dev = c2;
        }

        NSInteger ms = (NSInteger)MAX(TD_SWIPE_MIN_MS, durMs);
        if (n >= 5 && dev > TD_LIVE_CURVE) {
            d[@"t"] = @"gesture";
            d[@"pts"] = [self liveSampleTrack:_liveTrack to:far];
            d[@"ms"] = @(ms);
        } else {
            d[@"t"] = @"swipe";
            d[@"x1"] = @((NSInteger)lround(a.x));
            d[@"y1"] = @((NSInteger)lround(a.y));
            d[@"x2"] = @((NSInteger)lround(far.x));
            d[@"y2"] = @((NSInteger)lround(far.y));
            d[@"ms"] = @(ms);
        }
    }

    TDTrace("live step %s (%.0f,%.0f)→(%.0f,%.0f) dur=%.0f",
            [d[@"t"] UTF8String], a.x, a.y, far.x, far.y, durMs);

    [_liveSteps addObject:d];
    _liveTrack = nil;

    TDMaskSetSteps(_liveSteps);
    TDMaskSetLive(CGPointZero, NO);
    if (self.onChange) self.onChange();
}

/// 轨迹抽样成最多 12 个点，保留形状又不让脚本膨胀
- (NSArray *)liveSampleTrack:(NSArray<NSValue *> *)track to:(CGPoint)end {
    NSInteger n = (NSInteger)track.count;
    NSInteger want = MIN(12, n);
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < want; i++) {
        NSInteger idx = (want <= 1) ? 0 : (NSInteger)llround((double)i * (n - 1) / (want - 1));
        if (idx >= n) idx = n - 1;
        CGPoint p = [track[idx] CGPointValue];
        [out addObject:@[@((NSInteger)lround(p.x)), @((NSInteger)lround(p.y))]];
    }
    if (out.count) {
        out[out.count - 1] = @[@((NSInteger)lround(end.x)), @((NSInteger)lround(end.y))];
    }
    return out;
}

/// 收尾：把还没抬手的这一笔也结算掉（否则点停止时最后一滑会丢）
- (void)liveFlush {
    [self liveTick];
    if (_liveTrack.count) {
        CGPoint last = [_liveTrack.lastObject CGPointValue];
        [self liveFinishTrackAt:last time:_liveStartTs + 0.2];
    }
}

#pragma mark 收尾

- (void)teardown {
    if (_liveTimer) { [_liveTimer invalidate]; _liveTimer = nil; }

    if (_live) {
        TDHIDTraceStop();
        TDMaskHide();
        _live = NO;
        _liveTrack = nil;
        _liveIgnore = NO;
    }

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
    // 录兜底动作时挂的回调要跟着一起作废，否则下一次普通录制
    // 也会被塞进「判断」里（而且不会新建脚本）。
    self.onStepsReady = nil;
    _liveSteps = nil;
    TDLog(@"已取消录制，没有保存");
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

/// 末尾若干步如果正好落在悬浮条上，说明是「按停止」那一下，
/// 逐帧过滤偶尔会漏（按下和抬起之间窗口移动/重建），这里再兜一次。
static void TDDropTrailingSelfTaps(NSMutableArray<NSDictionary *> *steps) {
    CGRect r = TDFloatTouchRect();
    if (CGRectIsNull(r)) return;
    NSInteger guard = 0;
    while (steps.count > 0 && guard++ < 4) {
        NSDictionary *d = steps.lastObject;
        NSString *t = d[@"t"];
        CGPoint p = CGPointZero;
        if ([t isEqualToString:@"tap"] || [t isEqualToString:@"long"]) {
            p = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
        } else if ([t isEqualToString:@"swipe"]) {
            p = CGPointMake([d[@"x1"] doubleValue], [d[@"y1"] doubleValue]);
        } else if ([t isEqualToString:@"gesture"]) {
            NSArray *pts = d[@"pts"];
            NSArray *last = pts.lastObject;
            if (last.count >= 2) p = CGPointMake([last[0] doubleValue], [last[1] doubleValue]);
        } else {
            break;
        }
        if (!CGRectContainsPoint(r, p)) break;
        [steps removeLastObject];
    }
}

- (void)finishAndSave {
    if (!self.recording) return;

    if (_live) [self liveFlush];

    NSMutableArray<NSDictionary *> *steps = nil;
    if (_live) {
        steps = [_liveSteps mutableCopy] ?: [NSMutableArray array];
    } else {
        steps = [gPicker.steps mutableCopy] ?: [NSMutableArray array];
    }
    TDDropTrailingSelfTaps(steps);
    [self teardown];
    _liveSteps = nil;

    // 「判断编辑」里录兜底动作走这条：录完直接交给回调，
    // 不新建脚本 —— 否则每录一次兜底就多出一条垃圾脚本。
    void (^ready)(NSArray<NSDictionary *> *) = self.onStepsReady;
    if (ready) {
        self.onStepsReady = nil;
        TDLog(@"录制完成：%lu 步 → 已填进判断的兜底动作", (unsigned long)steps.count);
        ready([steps copy]);
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
        return;
    }

    TDScript *s = [[TDScriptStore shared] createScript];
    if (steps.count) s.steps = steps;
    [[TDScriptStore shared] save];

    TDLog(@"录制完成：%@（%lu 步）", s.name, (unsigned long)s.steps.count);
    TDTrace("picker: saved %lu steps", (unsigned long)steps.count);
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

- (NSMutableArray<NSDictionary *> *)stop {
    if (!self.recording) return nil;
    if (_live) [self liveFlush];

    NSMutableArray *steps = nil;
    if (_live) steps = [_liveSteps mutableCopy] ?: [NSMutableArray array];
    else steps = [gPicker.steps mutableCopy] ?: [NSMutableArray array];

    [self teardown];
    _liveSteps = nil;
    return steps;
}

@end

