#import "TD.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 悬浮窗（v1.14：三个按钮 + 一扇日志窗）
//
// ● 录制  点一次开始穿透录制，再点一次结束并保存（和音量上/下是同一个开关）
// ▶ 播放  开始执行选中脚本；录制中按它等于结束录制
// ■ 停止  停回放 / 停录制
// ▤ 日志  按钮条顶上那条 17pt 的把手，开关右边那扇日志窗
//
// 日志窗显示最近三行回放日志：识图命中/没找到、判断有没有触发、粘没粘贴、第几轮。
// 它为什么单独开一个窗口：
//   ★ 跨进程托管窗口会吞掉命中区域里的触摸（下面这条铁律）。
//   按钮窗只有 156×66，挡住的区域有限；日志窗 252×86，如果它也接收触摸，
//   回放时目标点落在它下面就会「点得到但没反应」。
//   所以日志窗和录制蒙版一样 _ignoresHitTest 恒 YES —— 只画，不吃触摸。
//
// ★ 托管窗口必须贴合按钮本身，绝不能铺满全屏：
//   跨进程托管窗口的触摸命中在窗口服务器侧完成，我们进程里 hitTest 返回
//   nil 只是「本进程没人接」，触摸会被这个窗口接住后丢弃，不会转发给下面
//   的抖音。窗口铺满全屏 = 抖音整屏都点不动。
//
// 交互（从左到右：▶ ● ■）：
//   点 ▶  = 开始执行选中脚本（录制中则结束录制并保存）
//   点 ●  = 开始 / 结束录制（穿透录制，抖音照常能点）
//   点 ■  = 停止执行 / 停止录制并保存
//   长按 ● = 全屏取点录制（先弹确认，因为这一层会把抖音挡住）
//   长按 ▶ / ■ = 不做事（以前长按 ▶ 直接进取点录制，手按久一点就被当成"开始录制"）
//   拖动  = 挪位置（位置记在 NSUserDefaults；取点模式下自动禁用，否则会把取点层拖走）
// ---------------------------------------------------------------------------

NSString * const TDDataChangedNotification = @"TDDataChangedNotification";

// 三个球：● 录 / ▶ 播放 / ■ 停止。44pt 刚好排成一条。
static const CGFloat kTDBallSize  = 44.0;
static const CGFloat kTDBallGap   = 4.0;
static const CGFloat kTDStripH    = 17.0;   // 顶部「▤ 日志」把手
static const CGFloat kTDOverlayW  = 156.0;  // 7 + 44×3 + 4×2 + 7
static const CGFloat kTDOverlayH  = 66.0;   // 17 把手 + 44 球 + 5
static const CGFloat kTDLogW      = 252.0;  // 日志窗
static const CGFloat kTDLogH      = 86.0;

static NSString * const kTDBallPosX = @"tdBallCenterX";
static NSString * const kTDBallPosY = @"tdBallCenterY";
static NSString * const kTDLogOpenKey = @"tdFloatLogOpen";

static TDHUDWindow *gBallWindow = nil;
static BOOL gFullScreen = NO;      // 取点模式下窗口铺满全屏
static UIPanGestureRecognizer *gPan = nil;   // 拖动悬浮条；取点模式下必须关掉
static UIView *gRecView = nil;     // ● 录制（点一次开始 / 再点一次结束）
static UILabel *gRecLabel = nil;
static UIView *gStartView = nil;
static UILabel *gStartLabel = nil;
static UIView *gStopView = nil;
static UILabel *gStopLabel = nil;

static UIView *gLogPanel = nil;
static UILabel *gLogHead = nil;
static UILabel *gLogBody = nil;
static UIView *gToggleView = nil;
static UILabel *gToggleLabel = nil;
static BOOL gLogOpen = YES;

static void TDFloatLayoutBalls(void);
static void TDFloatPlaceLogWindow(void);
static void TDFloatSetLogVisible(BOOL on);

/// 日志窗必须是「只画不吃触摸」的窗口。
///
/// 这是这一版最关键的一条：按钮窗只有 156×66，挡住的区域有限；
/// 日志窗有 252×86，如果它也接收触摸，抖音那一大片就点不动了 ——
/// 回放时目标点正好落在日志下面，就会出现「点得到但没反应」。
/// 所以它和录制蒙版一样，_ignoresHitTest 恒 YES，纯粹是块显示屏。
@interface TDLogWindow : TDHUDWindow
@end

@implementation TDLogWindow
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static TDLogWindow *gLogWindow = nil;

static void TDFloatLayoutBalls(void) {
    if (!gStartView || !gStopView) return;
    CGFloat y = kTDStripH + 4;
    // 顺序必须和老版本一致：▶ 在最左、■ 在最右，● 录制塞中间。
    // 上一版把 ● 排到最左，结果点「播放」点成了「开始录制」——
    // 手指记的是位置，不是图标。谁再改顺序，先想想这条。
    UIView *balls[3] = { gStartView, gRecView, gStopView };
    UILabel *labels[3] = { gStartLabel, gRecLabel, gStopLabel };
    for (int i = 0; i < 3; i++) {
        UIView *b = balls[i];
        if (!b) continue;
        b.frame = CGRectMake(7 + i * (kTDBallSize + kTDBallGap), y,
                             kTDBallSize, kTDBallSize);
        b.layer.cornerRadius = kTDBallSize / 2.0;
        UILabel *lb = labels[i];
        lb.frame = b.bounds;
        lb.font = [UIFont boldSystemFontOfSize:17];
    }
}

/// 把日志窗贴着按钮窗放：优先放上面，上面没地方就放下面，横向右对齐并夹进屏幕。
/// 拖动按钮时也要跟着重算，不然会各走各的。
static void TDFloatPlaceLogWindow(void) {
    if (!gLogWindow || gLogWindow.hidden || !gBallWindow) return;
    if (gFullScreen) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGRect bf = gBallWindow.frame;

    CGFloat x = CGRectGetMaxX(bf) - kTDLogW;
    x = MAX(6, MIN(sb.size.width - kTDLogW - 6, x));
    CGFloat y = bf.origin.y - kTDLogH - 6;
    if (y < 22) y = CGRectGetMaxY(bf) + 6;
    y = MAX(22, MIN(sb.size.height - kTDLogH - 8, y));

    gLogWindow.frame = CGRectMake(round(x), round(y), kTDLogW, kTDLogH);
    TDHUDRegisterWindow(gLogWindow);
}

/// 日志最多留 3 行（面板就那么高），新的在最上面
static NSMutableArray<NSString *> *gLogLines = nil;
static void TDFloatAppendLog(NSString *msg);

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
    TDFloatPlaceLogWindow();
}

#pragma mark - 状态刷新

/// 面板顶上那行状态：空闲 / 运行中（第几轮第几步） / 录制中
static NSTimer *gHeadTimer = nil;

static void TDFloatRefreshHead(void);

/// 回放时 0.5s 刷一次头部：脚步在走、数字就应该在动。
/// 停在第 1 步不动 = 被什么打断了，一眼就看出来。
static void TDFloatStartHeadTimer(void) {
    if (gHeadTimer) return;
    gHeadTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        if (![TDEngine shared].running) {
            [t invalidate];
            gHeadTimer = nil;
        }
        TDFloatRefreshHead();
    }];
}

static void TDFloatRefreshHead(void) {
    if (!gLogHead) return;
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];
    UIColor *c;
    NSString *state;
    if (r.recording) {
        state = @"录制中";
        c = [UIColor colorWithRed:0.85 green:0.45 blue:0.02 alpha:1];
    } else if (e.running) {
        // 把「跑到第几步」写出来：一直停在第 1 步 = 被什么东西打断了，
        // 数字往前走 = 正常按顺序跑，用不着猜。
        NSInteger i = e.curStep, n = e.planCount;
        if (i >= 0 && n > 0) {
            state = [NSString stringWithFormat:@"运行中 · 第 %ld 轮 · %ld/%ld 步",
                                               (long)MAX(1, e.loopsDone), (long)i + 1, (long)n];
        } else {
            state = [NSString stringWithFormat:@"运行中 · 第 %ld 轮", (long)MAX(1, e.loopsDone)];
        }
        c = [UIColor colorWithRed:0.06 green:0.52 blue:0.25 alpha:1];
    } else {
        state = @"空闲";
        c = [UIColor colorWithWhite:0.46 alpha:1];
    }
    gLogHead.attributedText = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"● %@", state]
            attributes:@{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11
                                                                           weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: c}];
    if (gToggleLabel) gToggleLabel.text = gLogOpen ? @"▤ 日志 ▾" : @"▤ 日志 ▸";
}

void TDFloatRefresh(void) {
    if (!gStartView || !gStopView) return;
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];

    // ● 录制球：没录时暗红，录制中亮红 —— 点一次开始、再点一次结束，
    // 和音量上/下是同一个开关，两条路都指向 TDRecorder，不会打架。
    //
    // 回放期间这颗球直接「点不动」（userInteractionEnabled = NO）：
    // 回放的注入触摸落点如果压在这颗球上，它会被当成真手指按下 →
    // 一路开始穿透录制，用户看到的就是「点 ▶ 变成了录制」。
    // 位置不能改（手指记的是位置），能从根上掐断的就是这一行。
    if (gRecView) {
        BOOL lockedByPlay = (e.running && !r.recording);
        gRecView.userInteractionEnabled = !lockedByPlay;
        gRecView.alpha = lockedByPlay ? 0.32 : 1.0;
        gRecLabel.text = @"●";
        if (r.recording) {
            gRecView.backgroundColor = [UIColor colorWithRed:1.00 green:0.26 blue:0.26 alpha:0.98];
            gRecLabel.textColor = UIColor.whiteColor;
            gRecView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        } else {
            gRecView.backgroundColor = [UIColor colorWithRed:0.34 green:0.15 blue:0.16 alpha:0.94];
            gRecLabel.textColor = [UIColor colorWithRed:1.00 green:0.42 blue:0.42 alpha:1];
            gRecView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
        }
    }

    if (r.recording) {
        // 录制中：▶ 让位（点它也只是结束录制），真正在闪的是中间那个 ●
        gStartView.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.32 alpha:0.95];
        gStartLabel.text = @"▶";
        gStartView.alpha = 0.35;
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
    TDFloatRefreshHead();
    if (e.running) TDFloatStartHeadTimer();
}

#pragma mark - 日志面板内容
//
// 为什么把悬浮条改成日志窗：回放的时候人在抖音里，看不清到底「识别到了没有」。
// 只放两个按钮等于闭着眼睛跑 —— 识图命中/没找到、判断有没有触发、粘没粘贴，
// 这些都得能当场看见。所以这里接一份引擎日志，最近三行常驻显示。

/// 按内容上色，一眼分得清：命中=绿，没命中=红，判断/兜底=黄，粘贴=蓝，其它=灰
static UIColor *TDFloatLogColor(NSString *m) {
    if ([m containsString:@"没找到"] || [m containsString:@"不见了"] ||
        [m containsString:@"起不来"] || [m containsString:@"空的"]) {
        return [UIColor colorWithRed:0.78 green:0.13 blue:0.12 alpha:1];
    }
    if ([m containsString:@"→ 点"] || [m containsString:@"命中"] ||
        [m containsString:@"靠尺度扫描"]) {
        return [UIColor colorWithRed:0.05 green:0.47 blue:0.24 alpha:1];
    }
    if ([m containsString:@"判断"] || [m containsString:@"兜底"]) {
        return [UIColor colorWithRed:0.62 green:0.40 blue:0.00 alpha:1];
    }
    if ([m containsString:@"粘贴"]) {
        return [UIColor colorWithRed:0.09 green:0.36 blue:0.78 alpha:1];
    }
    return [UIColor colorWithWhite:0.30 alpha:1];
}

static void TDFloatRenderLog(void) {
    if (!gLogBody) return;
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:@""];
    NSInteger n = MIN(3, (NSInteger)gLogLines.count);
    for (NSInteger i = 0; i < n; i++) {
        NSString *line = gLogLines[i];
        if ([line containsString:@"： "]) line = [line stringByReplacingOccurrencesOfString:@"： " withString:@"："];
        NSAttributedString *one = [[NSAttributedString alloc]
            initWithString:(i == 0 ? line : [@"\n" stringByAppendingString:line])
                attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9.5
                                                                                weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: TDFloatLogColor(line)}];
        [as appendAttributedString:one];
    }
    if (n == 0) {
        [as appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"（还没开始跑，点 ▶ 后这里会显示识图结果）"
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:9.5],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:0.50 alpha:1]}]];
    }
    gLogBody.attributedText = as;
}

static void TDFloatAppendLog(NSString *msg) {
    if (!msg.length) return;
    if (!gLogLines) gLogLines = [NSMutableArray array];
    [gLogLines insertObject:msg atIndex:0];
    while (gLogLines.count > 30) [gLogLines removeLastObject];
    TDFloatRenderLog();
}

#pragma mark - 日志窗（独立、不吃触摸）

static void TDFloatEnsureLogWindow(void) {
    if (gLogWindow) return;
    CGRect r = CGRectMake(0, 0, kTDLogW, kTDLogH);
    TDLogWindow *w = [[TDLogWindow alloc] initWithFrame:r];
    w.windowLevel = 10000011.0;      // 比按钮窗高一档，视觉上连成一块
    w.backgroundColor = [UIColor clearColor];
    w.hidden = YES;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.frame = r;
    w.rootViewController = vc;

    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)s; break; }
    }

    gLogPanel = [[UIView alloc] initWithFrame:r];
    gLogPanel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.94];
    gLogPanel.layer.cornerRadius = 12;
    gLogPanel.layer.borderWidth = 1;
    gLogPanel.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.13].CGColor;
    gLogPanel.userInteractionEnabled = NO;
    [vc.view addSubview:gLogPanel];

    gLogHead = [[UILabel alloc] initWithFrame:CGRectMake(12, 7, kTDLogW - 24, 15)];
    gLogHead.numberOfLines = 1;
    [gLogPanel addSubview:gLogHead];

    gLogBody = [[UILabel alloc] initWithFrame:CGRectMake(11, 25, kTDLogW - 20, 54)];
    gLogBody.numberOfLines = 3;
    gLogBody.lineBreakMode = NSLineBreakByTruncatingTail;
    [gLogPanel addSubview:gLogBody];

    gLogWindow = w;
    TDFloatRenderLog();
}

static void TDFloatSetLogVisible(BOOL on) {
    gLogOpen = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kTDLogOpenKey];
    if (on) TDFloatEnsureLogWindow();
    if (!gLogWindow) return;

    if (!on) {
        gLogWindow.hidden = YES;
        TDHUDUnregisterWindow(gLogWindow);
        return;
    }
    gLogWindow.hidden = NO;
    TDFloatRenderLog();
    TDFloatPlaceLogWindow();

    // 跨进程窗口的几何注册有时候要等几帧才生效（和蒙版一个道理）
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gLogWindow && !gLogWindow.hidden) TDFloatPlaceLogWindow();
        });
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
    if (e.running) {
        TDLog(@"已经在跑了（■ 停止，日志窗里能看到跑到哪一步）");
        TDFloatRefresh();
        return;
    }

    TDScript *s = [[TDScriptStore shared] selectedScript];
    if (!s || s.steps.count == 0) {
        TDLog(@"选中的脚本是空的，先长按悬浮条录一段");
        TDFloatRefresh();
        return;
    }
    [e playScript:s];
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
/// 这是「边操作边录」的那个入口 —— 点 ●。
static void TDFloatStartLiveRecord(void) {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (r.recording) { TDFloatFinishRecording(); TDFloatRefresh(); return; }

    // 回放中按 ● 一律不理会。
    // 以前这里是「先停回放再开始录」，但回放的触摸落点偶尔就压在 ● 上，
    // 于是用户看到的怪事是「播着播着变成录制了」，脚本还被顺带掐断 ——
    // 下回再点 ▶ 又从第 0 步起，看着像「每次都从头跑」。
    // 录制本来就要在空闲态开始，正在跑就明确拒绝，别偷偷接管。
    if (e.running) {
        TDLog(@"正在回放，● 不响应 —— 先按 ■ 停下来再录");
        TDFloatRefresh();
        return;
    }

    if (![r startLive]) {
        TDLog(@"穿透录制起不来：%@", [r status]);
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
        TDFloatRefresh();
        return;
    }
    TDLog(@"穿透录制开始：直接在抖音里点/滑，再点一次 ● 或按音量下结束");
    TDFloatRefresh();
}

#pragma mark - 球体视图

@interface TDBallVC : UIViewController <UIGestureRecognizerDelegate>
- (void)buildToggle;
- (void)refreshToggle;
- (void)onToggleLog;
- (void)confirmPointRecord;
@end

@implementation TDBallVC {
    CGPoint _dragStartCenter;
    CGPoint _dragStartTouch;
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTDOverlayW, kTDOverlayH)];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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

    // 日志窗默认开着：用户要的是「能看见识别到没有」。
    // 关掉只剩三个球，位置和状态都会记住（▤ 日志 开关）。
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gLogOpen = ([d objectForKey:kTDLogOpenKey] == nil) ? YES : [d boolForKey:kTDLogOpenKey];

    [self buildToggle];

    gStartView = [self makeBallAtX:0];
    gStartLabel = (UILabel *)gStartView.subviews.firstObject;
    gStartView.tag = 1;
    gStartLabel.text = @"▶";

    gStopView = [self makeBallAtX:0];
    gStopLabel = (UILabel *)gStopView.subviews.firstObject;
    gStopView.tag = 2;
    gStopLabel.text = @"■";

    // ● 录制球：点一次开始穿透录制，再点一次结束并保存。
    // 以前录制只能靠音量键或长按 ▶，手边没按键时很别扭。
    gRecView = [self makeBallAtX:0];
    gRecLabel = (UILabel *)gRecView.subviews.firstObject;
    gRecView.tag = 3;
    gRecLabel.text = @"●";

    // 拖动挪位置。这一条只在「悬浮条」形态下成立：
    // 取点模式窗口是铺满全屏的，pan 会认全屏任意一处滑动，把整个窗口
    // 连同取点层一起拖走（用户看到的「滑动时悬浮窗跟着滑」就是这个）。
    // 所以 delegate + enabled 双保险，全屏时彻底关掉。
    gPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    gPan.delegate = self;
    gPan.enabled = !gFullScreen;
    [self.view addGestureRecognizer:gPan];

    TDFloatLayoutBalls();
    TDFloatSetLogVisible(gLogOpen);
    TDFloatRefresh();
}

#pragma mark 日志开关

/// 顶部那条 17pt 的把手：只负责开/关日志窗，不承载别的操作
- (void)buildToggle {
    gToggleView = [[UIView alloc] initWithFrame:CGRectZero];
    gToggleView.userInteractionEnabled = YES;
    gToggleView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.94];
    gToggleView.layer.cornerRadius = 8;
    gToggleView.layer.borderWidth = 1;
    gToggleView.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.13].CGColor;
    [gToggleView addGestureRecognizer:
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onToggleLog)]];
    [self.view addSubview:gToggleView];

    gToggleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    gToggleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    gToggleLabel.textColor = [UIColor colorWithWhite:0.24 alpha:1];
    gToggleLabel.textAlignment = NSTextAlignmentCenter;
    gToggleLabel.userInteractionEnabled = NO;
    [gToggleView addSubview:gToggleLabel];

    [self refreshToggle];
}

- (void)refreshToggle {
    gToggleView.frame = CGRectMake(0, 0, kTDOverlayW, kTDStripH);
    gToggleLabel.frame = gToggleView.bounds;
    gToggleLabel.text = gLogOpen ? @"▤ 日志 ▾" : @"▤ 日志 ▸";
    gToggleLabel.textColor = gLogOpen ? [UIColor colorWithWhite:0.20 alpha:1]
                                      : [UIColor colorWithWhite:0.45 alpha:1];
}

- (void)onToggleLog {
    TDFloatSetLogVisible(!gLogOpen);
    [self refreshToggle];
    TDFloatRefresh();
}

- (void)onTap:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    if (v.tag == 1) TDFloatDoStart();
    else if (v.tag == 2) TDFloatDoStop();
    else if (v.tag == 3) TDFloatStartLiveRecord();   // ● 录：一次开始，再点一次结束
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;

    // 录制中长按任何一个球 = 结束录制（这时屏幕上主要就剩这几个球可点）
    if ([TDRecorder shared].recording) { TDFloatFinishRecording(); TDFloatRefresh(); return; }

    // 长按 ● = 全屏取点录制。要确认一次：这一层会把抖音整个挡住，
    // 被误触的话人就懵了（"我点播放怎么屏幕不动了"）。
    if (g.view.tag == 3) { [self confirmPointRecord]; return; }

    // 长按 ▶ / ■ 什么都不做。以前长按 ▶ 就直接进取点录制，
    // 点播放时手指压久了一点就变成"开始录制"，这个坑不能再留。
}

- (void)confirmPointRecord {
    if ([TDEngine shared].running) {
        TDLog(@"正在回放，先按 ■ 停掉再录");
        TDFloatRefresh();
        return;
    }
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"全屏取点录制？"
                         message:@"这一层会盖住抖音（点不动），只适合坐在那儿手工标点。\n"
                                  "边刷边录请直接点 ●。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        TDFloatToggleRecord();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
        // 拖的过程中日志窗跟着走，松手前也能看见自己拖到哪儿了
        TDFloatPlaceLogWindow();
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setDouble:w.center.x forKey:kTDBallPosX];
        [d setDouble:w.center.y forKey:kTDBallPosY];
        TDHUDRegisterWindow(w);
        TDFloatPlaceLogWindow();
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

    // 引擎日志分一路到悬浮窗：识别到没有、判断触发没有、粘没粘贴，当场就能看见。
    // 用 log tap 而不是 TDSetLogHandler，是因为那个位置已经被主界面的日志框占着了。
    static BOOL tapAdded = NO;
    if (!tapAdded) {
        tapAdded = YES;
        TDAddLogTap(^(NSString *m) { TDFloatAppendLog(m); });
    }

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
    TDFloatSetLogVisible(gLogOpen);

    // contextID 要等几帧才建出来，隔一会儿重试
    for (int i = 1; i <= 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * i * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gBallWindow) TDHUDRegisterWindow(gBallWindow);
            TDFloatPlaceLogWindow();
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
        TDFloatSetLogVisible(gLogOpen);
    } else {
        gBallWindow.hidden = YES;
        TDHUDUnregisterWindow(gBallWindow);
        if (gLogWindow) {
            gLogWindow.hidden = YES;
            TDHUDUnregisterWindow(gLogWindow);
        }
    }
}

/// 脚本回放期间把悬浮条临时停到屏幕最顶上。
///
/// 为什么不是「隐藏」：藏起来用户就没法中途按 ■ 停止了，脚本卡住只能杀 App。
/// 为什么是「最顶上」：悬浮条 164×74，本来浮在左上角，正好盖住评论编辑区的
/// 「图片」按钮 (28,396) 和相册第一行的选图圆圈 (79/183,386) —— 脚本连按钮
/// 都点不到。挪到顶部中间 (y≈26..100) 后，视频页那只盖住「直播/团购」标签，
/// 评论面板盖住「大家都在搜」横幅，相册盖住相册名 —— 这三处脚本都不点。
static CGRect gParkSaved;
static BOOL gParked = NO;

void TDFloatParkTop(void) {
    if (!gBallWindow || gBallWindow.hidden || gParked) return;
    gParkSaved = gBallWindow.frame;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = gBallWindow.frame.size.width, h = gBallWindow.frame.size.height;
    gBallWindow.frame = CGRectMake((sb.size.width - w) / 2.0, 26, w, h);
    TDHUDRegisterWindow(gBallWindow);       // 窗口动了要重新托管给 SpringBoard
    TDFloatPlaceLogWindow();
    gParked = YES;
}

void TDFloatUnpark(void) {
    if (!gBallWindow || !gParked) return;
    gBallWindow.frame = gParkSaved;
    TDHUDRegisterWindow(gBallWindow);
    TDFloatPlaceLogWindow();
    gParked = NO;
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
        gRecView.hidden = YES;
        // 取点层要全屏接触摸，日志面板和把手都必须让开
        if (gLogWindow) { gLogWindow.hidden = YES; TDHUDUnregisterWindow(gLogWindow); }
        gToggleView.hidden = YES;
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
        gRecView.hidden = NO;
        if (gLogWindow && !gLogOpen) gLogWindow.hidden = YES;
        if (gLogWindow && gLogOpen) { gLogWindow.hidden = NO; TDFloatPlaceLogWindow(); }
        gToggleView.hidden = NO;
        TDApplyBallPosition(gBallWindow);
        [gBallWindow layoutIfNeeded];
        TDFloatLayoutBalls();
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
