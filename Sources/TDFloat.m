#import "TD.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 悬浮球
//
// ★ 托管窗口必须是「球那么大」，绝不能铺满全屏：
//   跨进程托管窗口的触摸命中在窗口服务器侧完成，我们进程里 hitTest 返回
//   nil 只是「本进程没人接」，触摸会被这个窗口接住后丢弃，不会转发给下面
//   的抖音。窗口铺满全屏 = 抖音整屏都点不动。
//   窗口只有 76×76，窗口外的触摸压根不归它管。
//
// 交互：
//   点一下 = 播放/停止（录制中则停止录制并保存）
//   长按   = 开始/停止录制
//   拖动   = 挪位置（位置记在 NSUserDefaults）
// ---------------------------------------------------------------------------

NSString * const TDDataChangedNotification = @"TDDataChangedNotification";

static const CGFloat kTDBallSize    = 56.0;
static const CGFloat kTDBallPad     = 10.0;
static const CGFloat kTDOverlaySide = 76.0;

static NSString * const kTDBallPosX = @"tdBallCenterX";
static NSString * const kTDBallPosY = @"tdBallCenterY";

static TDHUDWindow *gBallWindow = nil;
static UILabel *gBallLabel = nil;
static UIView *gBallView = nil;

#pragma mark - 位置

static void TDApplyBallPosition(UIWindow *w) {
    if (!w) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat half = kTDOverlaySide / 2.0;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double cx = [d doubleForKey:kTDBallPosX];
    double cy = [d doubleForKey:kTDBallPosY];
    if (cx <= 0 || cy <= 0) {
        cx = sb.size.width - half - 6;
        cy = sb.size.height * 0.45;
    }
    cx = MAX(half + 2, MIN(sb.size.width  - half - 2, cx));
    cy = MAX(half + 30, MIN(sb.size.height - half - 34, cy));
    w.frame = CGRectMake(cx - half, cy - half, kTDOverlaySide, kTDOverlaySide);
    TDHUDRegisterWindow(w);
}

#pragma mark - 状态刷新

void TDFloatRefresh(void) {
    if (!gBallView) return;
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];

    if (r.recording) {
        gBallView.backgroundColor = [UIColor colorWithRed:1.0 green:0.58 blue:0.10 alpha:0.95];
        gBallLabel.text = @"录";
    } else if (e.running) {
        gBallView.backgroundColor = [UIColor colorWithRed:0.90 green:0.22 blue:0.22 alpha:0.95];
        gBallLabel.text = @"停";
    } else {
        gBallView.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:0.98 alpha:0.95];
        gBallLabel.text = @"跑";
    }
}

#pragma mark - 动作

static void TDFloatToggleRecord(void) {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (r.recording) {
        NSMutableArray<NSDictionary *> *events = [r stop];
        TDScript *s = [[TDScriptStore shared] createScript];
        if (events.count) s.steps = events;
        [[TDScriptStore shared] save];
        TDLog(@"录制结束：%@（%lu 步）", s.name, (unsigned long)s.steps.count);
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
    } else {
        if (e.running) [e stop];
        if (![r start]) {
            TDLog(@"录制不可用：%@", [r status]);
            [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
            return;
        }
        TDLog(@"开始录制，去抖音点几下，再点球停止");
    }
    TDFloatRefresh();
}

static void TDFloatTogglePlay(void) {
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];

    if (r.recording) { TDFloatToggleRecord(); return; }

    if (e.running) {
        [e stop];
    } else {
        TDScript *s = [[TDScriptStore shared] selectedScript];
        if (!s || s.steps.count == 0) {
            TDLog(@"选中的脚本是空的");
        } else {
            [e playSteps:[s engineSteps] loop:[TDConfig shared].loopCount];
        }
    }
    TDFloatRefresh();
}

#pragma mark - 球体视图

@interface TDBallVC : UIViewController
@end

@implementation TDBallVC {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTDOverlaySide, kTDOverlaySide)];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    gBallView = [[UIView alloc] initWithFrame:CGRectMake(kTDBallPad, kTDBallPad, kTDBallSize, kTDBallSize)];
    gBallView.userInteractionEnabled = YES;
    gBallView.layer.cornerRadius = kTDBallSize / 2;
    gBallView.layer.borderWidth = 2;
    gBallView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    gBallView.layer.shadowColor = [UIColor blackColor].CGColor;
    gBallView.layer.shadowOpacity = 0.35;
    gBallView.layer.shadowRadius = 6;
    gBallView.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:gBallView];

    gBallLabel = [[UILabel alloc] initWithFrame:gBallView.bounds];
    gBallLabel.text = @"跑";
    gBallLabel.textColor = [UIColor whiteColor];
    gBallLabel.font = [UIFont boldSystemFontOfSize:21];
    gBallLabel.textAlignment = NSTextAlignmentCenter;
    gBallLabel.userInteractionEnabled = NO;
    [gBallView addSubview:gBallLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap)];
    [gBallView addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
    lp.minimumPressDuration = 0.7;
    [gBallView addGestureRecognizer:lp];
    [tap requireGestureRecognizerToFail:lp];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [gBallView addGestureRecognizer:pan];

    TDFloatRefresh();
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (gBallView) gBallView.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

- (void)onTap { TDFloatTogglePlay(); }

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) TDFloatToggleRecord();
}

/// 屏幕坐标（用 windowScene 坐标系，窗口移动时不会被抵消）
- (CGPoint)screenPoint:(CGPoint)p inWindow:(UIWindow *)w {
    if (w.windowScene) return [w convertPoint:p toCoordinateSpace:w.windowScene.coordinateSpace];
    return p;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIWindow *w = self.view.window;
    if (!w) return;
    CGPoint touch = [self screenPoint:[g locationInView:w] inWindow:w];

    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartCenter = w.center;
        _dragStartTouch = touch;
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat half = kTDOverlaySide / 2.0;
        CGPoint c = CGPointMake(_dragStartCenter.x + touch.x - _dragStartTouch.x,
                                _dragStartCenter.y + touch.y - _dragStartTouch.y);
        c.x = MAX(half + 2, MIN(sb.size.width  - half - 2, c.x));
        c.y = MAX(half + 30, MIN(sb.size.height - half - 34, c.y));
        w.center = c;
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setDouble:w.center.x forKey:kTDBallPosX];
        [d setDouble:w.center.y forKey:kTDBallPosY];
        TDHUDRegisterWindow(w);
    }
}

@end

#pragma mark - 生命周期

void TDFloatInstall(void) {
    if (gBallWindow) return;

    TDHUDWindow *w = [[TDHUDWindow alloc] initWithFrame:CGRectMake(0, 0, kTDOverlaySide, kTDOverlaySide)];
    w.windowLevel = 10000010.0;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [TDBallVC new];
    gBallWindow = w;

    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)s; break; }
    }
    w.hidden = NO;
    TDApplyBallPosition(w);

    // contextID 要等几帧才建出来，隔一会儿重试
    for (int i = 1; i <= 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gBallWindow) TDHUDRegisterWindow(gBallWindow);
            if (i == 8) TDLog(@"悬浮球 %@", TDHUDStatus());
        });
    }
}

void TDFloatSetVisible(BOOL on) {
    if (!gBallWindow) {
        if (on) TDFloatInstall();
        return;
    }
    if (on) {
        gBallWindow.hidden = NO;
        TDApplyBallPosition(gBallWindow);
    } else {
        gBallWindow.hidden = YES;
        TDHUDUnregisterWindow(gBallWindow);
    }
}

BOOL TDFloatVisible(void) { return gBallWindow && !gBallWindow.hidden; }

void TDFloatResetPosition(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kTDBallPosX];
    [d removeObjectForKey:kTDBallPosY];
    TDApplyBallPosition(gBallWindow);
}
