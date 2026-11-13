#import "TD.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 悬浮条（两个按钮：▶ 开始执行 / ■ 停止执行）
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
//   长按  = 开始/停止录制
//   拖动  = 挪位置（位置记在 NSUserDefaults）
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
        TDLog(@"开始录制，去抖音点几下，再点悬浮条停止");
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

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.view addGestureRecognizer:pan];

    TDFloatRefresh();
}

- (void)onTap:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    if (v.tag == 1) TDFloatDoStart();
    else if (v.tag == 2) TDFloatDoStop();
}

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

#pragma mark - 生命周期

void TDFloatInstall(void) {
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
