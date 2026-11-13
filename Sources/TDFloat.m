#import "TD.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 悬浮条（两个按钮：▶ 开始执行 / ■ 停止执行）
//
// ◎ 那个注入自检球已经去掉：录制改用音量键（上录下停），按键验证有注入自检页，
// 它在屏幕上只剩「被误点」这一个作用，留着反而碍事。
//
// ★ 托管窗口必须贴合按钮本身，绝不能铺满全屏：
//   跨进程托管窗口的触摸命中在窗口服务器侧完成，我们进程里 hitTest 返回
//   nil 只是「本进程没人接」，触摸会被这个窗口接住后丢弃，不会转发给下面
//   的抖音。窗口铺满全屏 = 抖音整屏都点不动。
//   现在窗口只有 128×70，窗口外的触摸压根不归它管。
//
// 交互：
//   点 ▶  = 开始执行选中脚本（录制中则结束录制并保存）
//   点 ■  = 停止执行 / 停止录制并保存
//   长按 ▶ = 穿透录制：蒙版不拦触摸，边刷抖音边录（推荐）
//   长按 ■ = 取点录制：全屏取样，抖音会被挡住，纯标点用
//   拖动  = 挪位置（位置记在 NSUserDefaults；取点模式下自动禁用，否则会把取点层拖走）
// ---------------------------------------------------------------------------

NSString * const TDDataChangedNotification = @"TDDataChangedNotification";

static const CGFloat kTDBallSize = 54.0;
static const CGFloat kTDBallGap  = 5.0;
static const CGFloat kTDOverlayW = 128.0;   // 7 + 54 + 5 + 54 + 8
static const CGFloat kTDOverlayH = 70.0;    // 8 + 54 + 8

static NSString * const kTDBallPosX = @"tdBallCenterX";
static NSString * const kTDBallPosY = @"tdBallCenterY";

static TDHUDWindow *gBallWindow = nil;
static BOOL gFullScreen = NO;      // 取点模式下窗口铺满全屏
static UIPanGestureRecognizer *gPan = nil;   // 拖动悬浮条；取点模式下必须关掉
static UIView *gStartView = nil;
static UILabel *gStartLabel = nil;
static UIView *gStopView = nil;
static UILabel *gStopLabel = nil;

#pragma mark - 位置

static void TDApplyBallPosition(UIWindow *w) {
    if (!w) return;
    // 取点模式下窗口是故意铺满全屏的，任何「回默认位置」都不能把它缩回去
    if (gFullScreen) {
        TDHUDRegisterWindow(w);
        return;
    }
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat hw = kTDOverlayW / 2.0;
    CGFloat hh = kTDOverlayH / 2.0;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double cx = [d doubleForKey:kTDBallPosX];
    double cy = [d doubleForKey:kTDBallPosY];
    if (cx <= 0 || cy <= 0) {
        cx = sb.size.width - hw - 6;
        cy = sb.size.height * 0.45;
    }
    cx = MAX(hw + 2, MIN(sb.size.width  - hw - 2, cx));
    cy = MAX(hh + 30, MIN(sb.size.height - hh - 34, cy));
    w.frame = CGRectMake(cx - hw, cy - hh, kTDOverlayW, kTDOverlayH);
    TDHUDRegisterWindow(w);
}

#pragma mark - 状态刷新

void TDFloatRefresh(void) {
    if (!gStartView || !gStopView) return;
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];

    if (r.recording) {
        // 录制中：左球变橙显示「录」，右球是「停止录制并保存」
        gStartView.backgroundColor = [UIColor colorWithRed:1.00 green:0.58 blue:0.10 alpha:0.95];
        gStartLabel.text = @"录";
        gStartView.alpha = 1;
        gStopView.backgroundColor = [UIColor colorWithRed:0.90 green:0.22 blue:0.22 alpha:0.95];
        gStopLabel.text = @"■";
        gStopView.alpha = 1;
    } else if (e.running) {
        gStartView.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.32 alpha:0.95];
        gStartLabel.text = @"▶";
        gStartView.alpha = 0.45;
        gStopView.backgroundColor = [UIColor colorWithRed:0.90 green:0.22 blue:0.22 alpha:0.95];
        gStopLabel.text = @"■";
        gStopView.alpha = 1;
    } else {
        gStartView.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.32 alpha:0.95];
        gStartLabel.text = @"▶";
        gStartView.alpha = 1;
        gStopView.backgroundColor = [UIColor colorWithRed:0.90 green:0.22 blue:0.22 alpha:0.95];
        gStopLabel.text = @"■";
        gStopView.alpha = 0.45;
    }
}

#pragma mark - 动作

/// 结束录制并存成新脚本
static void TDFloatFinishRecording(void) {
    if (![TDRecorder shared].recording) return;
    [[TDRecorder shared] finishAndSave];
    TDFloatRefresh();
}

static void TDFloatDoStart(void) {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (r.recording) { TDFloatFinishRecording(); TDFloatRefresh(); return; }
    if (e.running) return;

    TDScript *s = [[TDScriptStore shared] selectedScript];
    if (!s || s.steps.count == 0) {
        TDLog(@"选中的脚本是空的，先长按悬浮条录一段");
        TDFloatRefresh();
        return;
    }
    [e playSteps:[s engineSteps] loop:[TDConfig shared].loopCount];
    TDFloatRefresh();
}

static void TDFloatDoStop(void) {
    if ([TDRecorder shared].recording) TDFloatFinishRecording();
    [[TDEngine shared] stop];
    TDFloatRefresh();
}

static void TDFloatToggleRecord(void) {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (r.recording) {
        TDFloatFinishRecording();
    } else {
        if (e.running) [e stop];
        if (![r start]) {
            TDLog(@"录制不可用：%@", [r status]);
            [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
            return;
        }
        TDLog(@"取点录制开始：抖音会被这一层挡住，纯取点用；要边刷边录就用长按 ▶");
    }
    TDFloatRefresh();
}

/// 穿透录制：蒙版不接触摸，触摸直通抖音，靠监听抄真实触摸。
/// 这是「边操作边录」的那个入口 —— 长按 ▶。
static void TDFloatStartLiveRecord(void) {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (r.recording) { TDFloatFinishRecording(); TDFloatRefresh(); return; }
    if (e.running) [e stop];

    if (![r startLive]) {
        TDLog(@"穿透录制起不来：%@", [r status]);
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
        TDFloatRefresh();
        return;
    }
    TDLog(@"穿透录制开始：直接在抖音里点/滑，录完点 ■ 或再长按 ▶");
    TDFloatRefresh();
}

#pragma mark - 球体视图

@interface TDBallVC : UIViewController <UIGestureRecognizerDelegate>
@end

@implementation TDBallVC {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTDOverlayW, kTDOverlayH)];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}

- (UIView *)makeBallAtX:(CGFloat)x {
    UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(x, 8, kTDBallSize, kTDBallSize)];
    ball.userInteractionEnabled = YES;
    ball.layer.cornerRadius = kTDBallSize / 2;
    ball.layer.borderWidth = 2;
    ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    ball.layer.shadowColor = [UIColor blackColor].CGColor;
    ball.layer.shadowOpacity = 0.35;
    ball.layer.shadowRadius = 6;
    ball.layer.shadowOffset = CGSizeMake(0, 2);
    [self.view addSubview:ball];

    UILabel *lb = [[UILabel alloc] initWithFrame:ball.bounds];
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont boldSystemFontOfSize:22];
    lb.textAlignment = NSTextAlignmentCenter;
    lb.userInteractionEnabled = NO;
    [ball addSubview:lb];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    [ball addGestureRecognizer:tap];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
    lp.minimumPressDuration = 0.7;
    [ball addGestureRecognizer:lp];
    [tap requireGestureRecognizerToFail:lp];

    return ball;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    gStartView = [self makeBallAtX:7];
    gStartLabel = (UILabel *)gStartView.subviews.firstObject;
    gStartView.tag = 1;
    gStartLabel.text = @"▶";

    gStopView = [self makeBallAtX:7 + kTDBallSize + kTDBallGap];
    gStopLabel = (UILabel *)gStopView.subviews.firstObject;
    gStopView.tag = 2;
    gStopLabel.text = @"■";

    // 拖动挪位置。这一条只在「悬浮条」形态下成立：
    // 取点模式窗口是铺满全屏的，pan 会认全屏任意一处滑动，把整个窗口
    // 连同取点层一起拖走（用户看到的「滑动时悬浮窗跟着滑」就是这个）。
    // 所以 delegate + enabled 双保险，全屏时彻底关掉。
    gPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    gPan.delegate = self;
    gPan.enabled = !gFullScreen;
    [self.view addGestureRecognizer:gPan];

    TDFloatRefresh();
}

- (void)onTap:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    if (v.tag == 1) TDFloatDoStart();
    else if (v.tag == 2) TDFloatDoStop();
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;

    // 录制中长按任何一个球 = 结束录制（这时屏幕上主要就剩这三个球可点）
    if ([TDRecorder shared].recording) { TDFloatFinishRecording(); TDFloatRefresh(); return; }

    // ▶ = 穿透录制（边操作边录，推荐）
    // ■ = 取点录制（全屏取样，抖音会被挡住）
    NSInteger tag = g.view.tag;
    if (tag == 1)      TDFloatStartLiveRecord();
    else if (tag == 2) TDFloatToggleRecord();
}

/// 屏幕坐标（用 windowScene 坐标系，窗口移动时不会被抵消）
- (CGPoint)screenPoint:(CGPoint)p inWindow:(UIWindow *)w {
    if (w.windowScene) return [w convertPoint:p toCoordinateSpace:w.windowScene.coordinateSpace];
    return p;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    // 取点模式下屏幕上的每一次滑动都是「要录的滑动」，不是拖窗口
    if (g == gPan && gFullScreen) return NO;
    return YES;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (gFullScreen) return;          // 再挡一次：enabled 来不及生效时不至于拖走
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
        CGFloat hw = kTDOverlayW / 2.0;
        CGFloat hh = kTDOverlayH / 2.0;
        CGPoint c = CGPointMake(_dragStartCenter.x + touch.x - _dragStartTouch.x,
                                _dragStartCenter.y + touch.y - _dragStartTouch.y);
        c.x = MAX(hw + 2, MIN(sb.size.width  - hw - 2, c.x));
        c.y = MAX(hh + 30, MIN(sb.size.height - hh - 34, c.y));
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

#pragma mark - 注入点击反馈（200ms 红圈）
//
// 目的：回放的时候能直接看见「它到底点在哪儿」，用不着猜。
// 做法：一个 64×64 的托管小窗口，每次注入按下就挪到那个点，画一圈涟漪 200ms 后消失。
//
// 两个必须守住的点：
//   1) 窗口不许铺满全屏 —— 跨进程托管窗口会吞掉命中区域内的触摸，
//      铺满全屏就是之前「抖音整屏点不动」的原因。它只有 64pt。
//   2) 它必须「只画不吃触摸」—— _ignoresHitTest 恒 YES，
//      否则脚本连点同一片区域时，反馈窗口会把自己下一次点击挡掉。

static const CGFloat kTDFbSize = 64.0;
static NSString * const kFbEnabledKey = @"tdInjectFeedback";

@interface TDFeedbackWindow : TDHUDWindow
@end

@implementation TDFeedbackWindow
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static TDFeedbackWindow *gFbWindow = nil;
static UIView *gFbRing = nil;
static UIView *gFbCore = nil;
static NSInteger gFbToken = 0;

BOOL TDInjectFeedbackEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kFbEnabledKey] == nil) return YES;   // 默认开
    return [d boolForKey:kFbEnabledKey];
}

void TDSetInjectFeedbackEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kFbEnabledKey];
    if (!on && gFbWindow) {
        gFbToken++;
        gFbWindow.hidden = YES;
        gFbRing.alpha = 0;
        gFbCore.alpha = 0;
    }
}

static void TDFeedbackEnsureWindow(void) {
    if (gFbWindow) return;

    TDFeedbackWindow *w = [[TDFeedbackWindow alloc]
        initWithFrame:CGRectMake(-kTDFbSize, -kTDFbSize, kTDFbSize, kTDFbSize)];
    w.windowLevel = 10000009.0;          // 比悬浮条(10000010)低，不挡按钮
    w.backgroundColor = [UIColor clearColor];
    w.hidden = YES;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.frame = CGRectMake(0, 0, kTDFbSize, kTDFbSize);
    w.rootViewController = vc;

    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)s; break; }
    }

    // 外圈：红色圆环，从 0.5 倍撑到 1 倍并淡出 —— 一眼就看得到点在哪儿
    gFbRing = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTDFbSize, kTDFbSize)];
    gFbRing.backgroundColor = [UIColor colorWithRed:1.0 green:0.24 blue:0.24 alpha:0.28];
    gFbRing.layer.cornerRadius = kTDFbSize / 2;
    gFbRing.layer.borderWidth = 3;
    gFbRing.layer.borderColor = [UIColor colorWithRed:1.0 green:0.30 blue:0.30 alpha:0.95].CGColor;
    gFbRing.userInteractionEnabled = NO;
    gFbRing.alpha = 0;
    [vc.view addSubview:gFbRing];

    // 中心那个小黄点：标出精确坐标，判断「有没有点偏」就靠它
    CGFloat cs = 9.0;
    gFbCore = [[UIView alloc] initWithFrame:CGRectMake((kTDFbSize - cs) / 2,
                                                      (kTDFbSize - cs) / 2, cs, cs)];
    gFbCore.backgroundColor = [UIColor colorWithRed:1.0 green:0.96 blue:0.25 alpha:1.0];
    gFbCore.layer.cornerRadius = cs / 2;
    gFbCore.userInteractionEnabled = NO;
    gFbCore.alpha = 0;
    [vc.view addSubview:gFbCore];

    gFbWindow = w;
}

static void TDFeedbackShowMain(CGFloat x, CGFloat y, BOOL down) {
    if (!TDInjectFeedbackEnabled()) return;
    TDFeedbackEnsureWindow();
    if (!gFbWindow) return;

    CGFloat half = kTDFbSize / 2.0;
    CGRect f = CGRectMake(round(x - half), round(y - half), kTDFbSize, kTDFbSize);

    // 位置变了必须重新登记：SpringBoard 那边不重新认一遍，画面还是停在旧位置
    if (!CGRectEqualToRect(gFbWindow.frame, f)) {
        gFbWindow.frame = f;
        TDHUDRegisterTransientWindow(gFbWindow);
    }
    gFbWindow.hidden = NO;

    gFbToken++;
    NSInteger token = gFbToken;

    [gFbRing.layer removeAllAnimations];
    gFbRing.transform = CGAffineTransformMakeScale(0.5, 0.5);
    gFbRing.alpha = 1.0;
    gFbCore.alpha = 1.0;

    [UIView animateWithDuration:0.20
                          delay:0
                        options:(UIViewAnimationOptionBeginFromCurrentState |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        gFbRing.transform = CGAffineTransformMakeScale(1.0, 1.0);
        gFbRing.alpha = 0.0;
    } completion:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != gFbToken) return;      // 又来了一次点击，交给新的那次收尾
        gFbWindow.hidden = YES;
        gFbCore.alpha = 0;
        gFbRing.alpha = 0;
    });
}

/// TDhid 注入时回调进来（跑在引擎队列，不是主线程）
static void TDFeedbackShow(CGFloat x, CGFloat y, BOOL down) {
    if (!TDInjectFeedbackEnabled()) return;
    if ([NSThread isMainThread]) {
        TDFeedbackShowMain(x, y, down);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            TDFeedbackShowMain(x, y, down);
        });
    }
}

#pragma mark - 生命周期

void TDFloatInstall(void) {
    // 注入 → 圆点反馈，一直挂着（有开关控制，关掉就不画）
    TDSetInjectFeedbackHandler(TDFeedbackShow);

    if (gBallWindow) return;

    TDHUDWindow *w = [[TDHUDWindow alloc] initWithFrame:CGRectMake(0, 0, kTDOverlayW, kTDOverlayH)];
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
            if (i == 8) TDLog(@"悬浮条 %@", TDHUDStatus());
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

/// 悬浮条在屏幕上占的那块地方（屏幕坐标）。
/// 录制时要拿它过滤触摸：用户按 ■ 停止那一下落在这块里，
/// 不过滤就会被录成脚本最后一步 —— 这就是「点停止也录进去了」。
CGRect TDFloatTouchRect(void) {
    if (!gBallWindow || gBallWindow.hidden) return CGRectNull;
    if (gFullScreen) return CGRectNull;     // 全屏是取点层本身，不能过滤
    return CGRectInset(gBallWindow.frame, -4, -4);
}

void TDFloatResetPosition(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:kTDBallPosX];
    [d removeObjectForKey:kTDBallPosY];
    TDApplyBallPosition(gBallWindow);
}

#pragma mark - 全屏取点模式

UIWindow *TDFloatWindow(void) { return gBallWindow; }

BOOL TDFloatIsFullScreen(void) { return gFullScreen; }

/// 取点录制时把窗口铺满全屏：这一层就变成「我们的全屏窗口」，
/// 触摸必然投递到本进程，坐标即屏幕坐标。录完必须收回悬浮条尺寸，
/// 否则全屏窗口会把抖音整屏的触摸都吞掉。
void TDFloatSetFullScreen(BOOL on) {
    if (!gBallWindow) return;
    if (on == gFullScreen) return;
    gFullScreen = on;

    // 全屏 = 每一处滑动都属于取点层，拖动必须让位
    gPan.enabled = !on;
    if (on && gPan && gBallWindow.rootViewController.view) {
        [gPan setTranslation:CGPointZero inView:gBallWindow.rootViewController.view];
    }

    if (on) {
        gStartView.hidden = YES;
        gStopView.hidden = YES;
        // 换一个 level，逼 TDHUD 重新向 SpringBoard 注册新几何
        gBallWindow.windowLevel = 10000012.0;
        gBallWindow.frame = [UIScreen mainScreen].bounds;
        [gBallWindow layoutIfNeeded];   // 让 rootViewController.view 立刻跟着变成全屏
        TDHUDRegisterWindow(gBallWindow);
        TDLog(@"进入取点模式（窗口铺满全屏）");
    } else {
        gBallWindow.windowLevel = 10000010.0;
        gStartView.hidden = NO;
        gStopView.hidden = NO;
        TDApplyBallPosition(gBallWindow);
        [gBallWindow layoutIfNeeded];
        TDLog(@"退出取点模式");
    }
    TDFloatRefresh();
}

#pragma mark - 穿透录制蒙版
//
// 和「取点层」的根本区别：
//   取点层是把我们的窗口铺满全屏去接触摸 —— 坐标准，但抖音被挡死，
//   录的时候看不到翻页到底成没成。
//   这一层 _ignoresHitTest 恒 YES，触摸原样穿到下面的抖音，用户是真的在刷，
//   我们只是把系统监听抄下来的同一批触摸画成轨迹。
//
// 铁律：这一层和它的所有子视图都不能接收触摸。
// 一旦哪里 userInteractionEnabled 变回 YES，抖音整屏就点不动 —— 之前踩过。

@interface TDMaskWindow : TDHUDWindow
@end

@implementation TDMaskWindow
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface TDMaskView : UIView
@property (nonatomic, strong) NSArray<NSDictionary *> *steps;
@property (nonatomic, copy) NSString *hint;
@property (nonatomic) CGPoint livePoint;
@property (nonatomic) BOOL live;
@end

@implementation TDMaskView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.userInteractionEnabled = NO;
    return self;
}

- (void)setSteps:(NSArray<NSDictionary *> *)steps {
    _steps = steps;
    [self setNeedsDisplay];
}

- (void)setHint:(NSString *)hint {
    _hint = [hint copy];
    [self setNeedsDisplay];
}

- (void)setLive:(BOOL)live {
    _live = live;
    [self setNeedsDisplay];
}

- (void)setLivePoint:(CGPoint)livePoint {
    _livePoint = livePoint;
    if (_live) [self setNeedsDisplay];
}

- (void)drawDotIn:(CGContextRef)ctx at:(CGPoint)p index:(NSInteger)idx
            color:(UIColor *)c radius:(CGFloat)r {
    CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.85].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(p.x - r, p.y - r, r * 2, r * 2));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.8].CGColor);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(p.x - r, p.y - r, r * 2, r * 2));
    if (idx > 0) {
        NSString *s = [NSString stringWithFormat:@"%ld", (long)idx];
        UIFont *f = [UIFont boldSystemFontOfSize:11];
        CGSize sz = [s sizeWithAttributes:@{NSFontAttributeName: f}];
        [s drawAtPoint:CGPointMake(p.x - sz.width / 2, p.y - sz.height / 2)
        withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.whiteColor}];
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIColor *tapC   = [UIColor colorWithRed:0.22 green:0.72 blue:0.36 alpha:1];
    UIColor *longC  = [UIColor colorWithRed:1.00 green:0.60 blue:0.10 alpha:1];
    UIColor *swipeC = [UIColor colorWithRed:0.22 green:0.62 blue:1.00 alpha:1];

    // 已录轨迹
    NSInteger i = 0;
    for (NSDictionary *d in _steps) {
        i++;
        NSString *t = d[@"t"];
        if ([t isEqualToString:@"swipe"]) {
            CGPoint a = CGPointMake([d[@"x1"] doubleValue], [d[@"y1"] doubleValue]);
            CGPoint b = CGPointMake([d[@"x2"] doubleValue], [d[@"y2"] doubleValue]);
            CGContextSetStrokeColorWithColor(ctx, [swipeC colorWithAlphaComponent:0.85].CGColor);
            CGContextSetLineWidth(ctx, 3);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            CGContextMoveToPoint(ctx, a.x, a.y);
            CGContextAddLineToPoint(ctx, b.x, b.y);
            CGContextStrokePath(ctx);
            [self drawDotIn:ctx at:a index:i color:swipeC radius:9];
            [self drawDotIn:ctx at:b index:0 color:swipeC radius:6];
        } else if ([t isEqualToString:@"gesture"]) {
            NSArray *pts = d[@"pts"];
            if (pts.count >= 2) {
                CGContextSetStrokeColorWithColor(ctx, [swipeC colorWithAlphaComponent:0.85].CGColor);
                CGContextSetLineWidth(ctx, 3);
                CGContextSetLineCap(ctx, kCGLineCapRound);
                BOOL first = YES;
                for (NSArray *pair in pts) {
                    if (pair.count < 2) continue;
                    CGPoint p = CGPointMake([pair[0] doubleValue], [pair[1] doubleValue]);
                    if (first) { CGContextMoveToPoint(ctx, p.x, p.y); first = NO; }
                    else CGContextAddLineToPoint(ctx, p.x, p.y);
                }
                CGContextStrokePath(ctx);
                NSArray *p0 = pts.firstObject, *p1 = pts.lastObject;
                if (p0.count >= 2) [self drawDotIn:ctx at:CGPointMake([p0[0] doubleValue], [p0[1] doubleValue])
                                            index:i color:swipeC radius:9];
                if (p1.count >= 2) [self drawDotIn:ctx at:CGPointMake([p1[0] doubleValue], [p1[1] doubleValue])
                                            index:0 color:swipeC radius:6];
            }
        } else {
            CGPoint a = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
            [self drawDotIn:ctx at:a index:i
                     color:([t isEqualToString:@"long"] ? longC : tapC) radius:9];
        }
    }

    // 正在滑的那一笔
    if (_live) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.35].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(_livePoint.x - 13, _livePoint.y - 13, 26, 26));
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(_livePoint.x - 13, _livePoint.y - 13, 26, 26));
    }

    // 顶部状态胶囊：只写状态，不放按钮 —— 按钮会接收触摸，就穿不过去了
    NSString *txt = _hint.length ? _hint
        : [NSString stringWithFormat:@"● 录制中 · %lu 步", (unsigned long)_steps.count];
    UIFont *bf = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    CGSize ts = [txt sizeWithAttributes:@{NSFontAttributeName: bf}];
    CGFloat padX = 14, bh = 30;
    CGFloat bw = ts.width + padX * 2;
    CGFloat safeTop = self.safeAreaInsets.top;
    if (safeTop <= 0) safeTop = 26;
    CGRect br = CGRectMake((self.bounds.size.width - bw) / 2, safeTop + 6, bw, bh);

    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.62].CGColor);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:br cornerRadius:bh / 2];
    [bp fill];

    // 左侧红点表示正在录
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(br.origin.x + 9, br.origin.y + bh / 2 - 3, 6, 6));

    [txt drawInRect:CGRectMake(br.origin.x + 20, br.origin.y + (bh - ts.height) / 2,
                               ts.width, ts.height)
     withAttributes:@{NSFontAttributeName: bf, NSForegroundColorAttributeName: UIColor.whiteColor}];
}

@end

static TDMaskWindow *gMaskWindow = nil;
static TDMaskView *gMaskView = nil;

void TDMaskShow(void) {
    if (gMaskWindow) {
        gMaskWindow.hidden = NO;
        TDHUDRegisterWindow(gMaskWindow);
        return;
    }
    CGRect sb = [UIScreen mainScreen].bounds;

    TDMaskWindow *w = [[TDMaskWindow alloc] initWithFrame:sb];
    w.windowLevel = 10000008.0;          // 比悬浮条低，悬浮条要能点到
    w.backgroundColor = [UIColor clearColor];
    w.hidden = YES;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.frame = sb;
    w.rootViewController = vc;

    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)s; break; }
    }

    TDMaskView *v = [[TDMaskView alloc] initWithFrame:sb];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:v];

    gMaskWindow = w;
    gMaskView = v;
    w.hidden = NO;
    TDHUDRegisterWindow(w);

    // 窗口服务器的注册有时候要等几帧
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gMaskWindow && !gMaskWindow.hidden) TDHUDRegisterWindow(gMaskWindow);
        });
    }
}

void TDMaskHide(void) {
    if (!gMaskWindow) return;
    gMaskView.steps = nil;
    gMaskView.live = NO;
    gMaskWindow.hidden = YES;
    TDHUDUnregisterWindow(gMaskWindow);
    gMaskWindow.rootViewController = nil;
    gMaskWindow = nil;
    gMaskView = nil;
}

void TDMaskSetSteps(NSArray<NSDictionary *> *steps) {
    if (gMaskView) gMaskView.steps = steps;
}

void TDMaskSetHint(NSString *hint) {
    if (gMaskView) gMaskView.hint = hint;
}

void TDMaskSetLive(CGPoint p, BOOL on) {
    if (!gMaskView) return;
    gMaskView.livePoint = p;
    gMaskView.live = on;
}

BOOL TDMaskVisible(void) { return gMaskWindow && !gMaskWindow.hidden; }
