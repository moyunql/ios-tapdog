#import "TD.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <stdarg.h>

// ---------------------------------------------------------------------------
// 主界面（按键精灵式：录制 / 播放 / 停止 + 脚本列表 + 诊断）
// ---------------------------------------------------------------------------

#define TD_BG      [UIColor colorWithRed:0.043 green:0.067 blue:0.086 alpha:1]
#define TD_CARD    [UIColor colorWithRed:0.078 green:0.110 blue:0.145 alpha:1]
#define TD_LINE    [UIColor colorWithRed:0.125 green:0.169 blue:0.212 alpha:1]
#define TD_TEXT    [UIColor colorWithRed:0.910 green:0.937 blue:0.961 alpha:1]
#define TD_DIM     [UIColor colorWithRed:0.545 green:0.627 blue:0.694 alpha:1]
#define TD_ACCENT  [UIColor colorWithRed:0.231 green:0.541 blue:0.980 alpha:1]
#define TD_RED     [UIColor colorWithRed:0.902 green:0.263 blue:0.263 alpha:1]
#define TD_GREEN   [UIColor colorWithRed:0.235 green:0.749 blue:0.478 alpha:1]

#pragma mark - 任意触摸捕获层

// 这一层铺满全屏，唯一的职责是**记下落点**。
//
// 之前它只数次数，判据是「有没有触摸」，结果是四种完全不同的失败
// 在我们眼里长得一模一样：事件被内核拒了、被当成滑动、坐标被缩放了、
// 落到 (0,0)。四种都显示 ✗，于是只能靠猜。
//
// 现在把坐标记下来：
//   没触摸      → 事件根本没进本进程（内核/投递层的问题）
//   落点=(0,0)  → 父事件坐标没传下去
//   落点=目标/3 → 量纲错了（点 vs 像素）
//   落点=右下角 → 被当成归一化后 clamp 到 1.0（v1.2.3 那次「跳到我的」）
//   落点=目标   → 链路完全通
@interface TDTouchCatcher : UIView
@property (nonatomic, copy) void (^onTouch)(CGPoint p);
@property (nonatomic) NSInteger hits;
@property (nonatomic) CGPoint lastPoint;     // 本层坐标，未收到过即为 NAN
@property (nonatomic) CGPoint lastScreen;    // 窗口坐标（＝屏幕坐标，全屏无偏移）
@property (nonatomic) CGPoint minPoint;      // 本次采样范围
@property (nonatomic) CGPoint maxPoint;
@end

@implementation TDTouchCatcher
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.lastPoint = CGPointMake(NAN, NAN);
        self.minPoint = CGPointMake(NAN, NAN);
        self.maxPoint = CGPointMake(NAN, NAN);
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)resetTrail {
    self.hits = 0;
    self.lastPoint = CGPointMake(NAN, NAN);
    self.minPoint = CGPointMake(NAN, NAN);
    self.maxPoint = CGPointMake(NAN, NAN);
}

- (void)record:(NSSet<UITouch *> *)touches {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self];
    self.hits += 1;
    self.lastPoint = p;
    self.lastScreen = [t locationInView:nil];
    if (isnan(self.minPoint.x)) {
        self.minPoint = p;
        self.maxPoint = p;
    } else {
        self.minPoint = CGPointMake(MIN(self.minPoint.x, p.x), MIN(self.minPoint.y, p.y));
        self.maxPoint = CGPointMake(MAX(self.maxPoint.x, p.x), MAX(self.maxPoint.y, p.y));
    }
    if (self.onTouch) self.onTouch(p);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self record:touches];
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // move 不算新的一次触摸，但要更新「最后落点」——滑动被 clamp 的情况全靠它暴露
    UITouch *t = touches.anyObject;
    if (t) {
        self.lastPoint = [t locationInView:self];
        self.lastScreen = [t locationInView:nil];
    }
    [super touchesMoved:touches withEvent:event];
}
@end

#pragma mark - 自检页（验证注入是否真的点得动、坐标对不对）

@interface TDSelfTestVC : UIViewController
@end

@interface TDSelfTestVC ()
- (void)hit;
- (void)fire;
- (void)updateHits;
- (void)handleTouchAt:(CGPoint)p;
- (void)startScan;
- (void)scanStep;
- (void)finishScan;
- (void)startProbe;
- (void)probeStep;
- (void)finishProbe;
@end

@implementation TDSelfTestVC {
    UIView *_target;
    UILabel *_hits;
    UILabel *_land;
    UILabel *_status;
    UILabel *_tip;
    UILabel *_scanLog;
    UIButton *_scanBtn;
    UIButton *_probeBtn;
    NSInteger _count;
    TDTouchCatcher *_catcher;
    // 自动扫描：一组一组试注入构造，哪组命中由程序自己判断，不靠人眼看
    NSInteger _scanIdx;
    NSInteger _prevCount;
    NSInteger _prevHits;
    NSMutableArray<NSNumber *> *_scanHits;
    NSMutableArray<NSNumber *> *_scanEcho;
    NSTimer *_scanTimer;
    NSTimer *_sampleTimer;
    // 坐标空间探针：同一目标点，三种量纲各打一次，看落点对不对
    NSInteger _probeIdx;
    NSTimer *_probeTimer;
    NSInteger _probeSavedCoord;
    NSInteger _probeBaseHits;
    CGPoint _probeAsked;
    NSMutableArray<NSString *> *_probeLines;
    BOOL _fbWasOn;
    BOOL _reWasOn;
    BOOL _scanRunning;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入自检";
    self.view.backgroundColor = TD_BG;

    _catcher = [[TDTouchCatcher alloc] initWithFrame:self.view.bounds];
    _catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _catcher.backgroundColor = [UIColor clearColor];
    __weak typeof(self) wsc = self;
    _catcher.onTouch = ^(CGPoint p) { [wsc handleTouchAt:p]; };
    [self.view addSubview:_catcher];

    _hits = [[UILabel alloc] initWithFrame:CGRectZero];
    _hits.text = @"目标 0 次 · 任意触摸 0 次";
    _hits.textColor = TD_TEXT;
    _hits.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightBold];
    _hits.textAlignment = NSTextAlignmentCenter;
    _hits.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hits];

    _land = [[UILabel alloc] initWithFrame:CGRectZero];
    _land.text = @"落点 –（还没收到任何触摸）";
    _land.textColor = TD_DIM;
    _land.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    _land.textAlignment = NSTextAlignmentCenter;
    _land.numberOfLines = 2;
    _land.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_land];

    _status = [[UILabel alloc] initWithFrame:CGRectZero];
    _status.text = @"真实事件：未学到";
    _status.textColor = TD_DIM;
    _status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 2;
    _status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_status];

    _target = [[UIView alloc] initWithFrame:CGRectZero];
    _target.backgroundColor = [UIColor colorWithRed:0.25 green:0.30 blue:0.36 alpha:1];
    _target.layer.cornerRadius = 14;
    _target.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_target];

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectZero];
    tl.text = @"目标";
    tl.textColor = TD_DIM;
    tl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    tl.textAlignment = NSTextAlignmentCenter;
    tl.translatesAutoresizingMaskIntoConstraints = NO;
    [_target addSubview:tl];
    [NSLayoutConstraint activateConstraints:@[
        [tl.centerXAnchor constraintEqualToAnchor:_target.centerXAnchor],
        [tl.centerYAnchor constraintEqualToAnchor:_target.centerYAnchor],
    ]];

    // 方块只当靶子，不再自己收触摸：所有触摸统一由铺满全屏的 catcher 记录，
    // 这样「落在方块内」和「落在方块外」都能拿到精确坐标。
    _target.userInteractionEnabled = NO;

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    [go setTitle:@"注入一次点击到目标中心" forState:UIControlStateNormal];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    go.backgroundColor = TD_ACCENT;
    go.layer.cornerRadius = 12;
    go.translatesAutoresizingMaskIntoConstraints = NO;
    [go addTarget:self action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];

    _tip = [[UILabel alloc] initWithFrame:CGRectZero];
    _tip.text = @"① 手指在方块上点一下（学一次真实触摸）② 点「坐标探针」看落点 ③ 不对再扫 14 组";
    _tip.textColor = TD_DIM;
    _tip.font = [UIFont systemFontOfSize:13];
    _tip.numberOfLines = 0;
    _tip.textAlignment = NSTextAlignmentCenter;
    _tip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tip];

    // 自动扫描：14 组构造依次注入，命中与否由程序判定
    _scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_scanBtn setTitle:@"扫描 14 组" forState:UIControlStateNormal];
    [_scanBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _scanBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _scanBtn.backgroundColor = [UIColor colorWithRed:0.36 green:0.30 blue:0.62 alpha:1];
    _scanBtn.layer.cornerRadius = 12;
    _scanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_scanBtn addTarget:self action:@selector(startScan) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_scanBtn];

    // 坐标空间探针：只改量纲，别的都不动。
    // 这是唯一能把「坐标算错」和「事件被拒」分开的实验。
    _probeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_probeBtn setTitle:@"坐标探针" forState:UIControlStateNormal];
    [_probeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _probeBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _probeBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.44 blue:0.46 alpha:1];
    _probeBtn.layer.cornerRadius = 12;
    _probeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_probeBtn addTarget:self action:@selector(startProbe) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_probeBtn];

    _scanLog = [[UILabel alloc] initWithFrame:CGRectZero];
    _scanLog.text = @"";
    _scanLog.textColor = TD_DIM;
    _scanLog.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _scanLog.numberOfLines = 0;
    _scanLog.textAlignment = NSTextAlignmentLeft;
    _scanLog.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scanLog];

    [NSLayoutConstraint activateConstraints:@[
        [_hits.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_hits.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],

        [_land.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_land.topAnchor constraintEqualToAnchor:_hits.bottomAnchor constant:4],
        [_land.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
        [_land.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],

        [_status.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_status.topAnchor constraintEqualToAnchor:_land.bottomAnchor constant:6],
        [_status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_target.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_target.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40],
        [_target.widthAnchor constraintEqualToConstant:200],
        [_target.heightAnchor constraintEqualToConstant:90],

        [go.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [go.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [go.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-90],
        [go.heightAnchor constraintEqualToConstant:52],

        [_tip.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [_tip.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [_tip.bottomAnchor constraintEqualToAnchor:go.topAnchor constant:-18],

        [_scanBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_scanBtn.topAnchor constraintEqualToAnchor:go.bottomAnchor constant:10],
        [_scanBtn.heightAnchor constraintEqualToConstant:44],

        [_probeBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_probeBtn.topAnchor constraintEqualToAnchor:go.bottomAnchor constant:10],
        [_probeBtn.heightAnchor constraintEqualToConstant:44],
        [_probeBtn.leadingAnchor constraintEqualToAnchor:_scanBtn.trailingAnchor constant:10],
        [_probeBtn.widthAnchor constraintEqualToAnchor:_scanBtn.widthAnchor],

        [_scanLog.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_scanLog.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_scanLog.topAnchor constraintEqualToAnchor:_target.bottomAnchor constant:16],
        [_scanLog.bottomAnchor constraintEqualToAnchor:_tip.topAnchor constant:-8],
    ]];

    // 开监听：等着用户用手点一下方块，把那次真实触摸复制下来
    TDHIDSampleStart();
    __weak typeof(self) ws0 = self;
    _sampleTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
        [ws0 refreshSampleStatus];
    }];
    [self refreshSampleStatus];
}

- (void)refreshSampleStatus {
    // 扫描/探针期间别覆盖日志区
    if (!_scanRunning && !_probeTimer) _scanLog.text = TDHIDDiagReport();
    if (!TDHIDSampleReady()) {
        _status.textColor = TD_DIM;
        _status.text = @"真实事件：未学到\n请用手指在这个灰色方块上点一下";
        return;
    }
    uint64_t sid = TDHIDSampleSenderID();
    _status.textColor = TD_GREEN;
    _status.text = [NSString stringWithFormat:@"真实事件：已学到%@\nsenderID 0x%llx",
                    TDHIDSampleHasUp() ? @" down+up" : @" down（缺 up）",
                    sid];
}

#pragma mark - 自动扫描

- (void)startScan {
    if (_scanTimer) return;
    _scanIdx = 0;
    _prevCount = _count;
    _prevHits = _catcher.hits;
    _scanHits = [NSMutableArray array];
    _scanEcho = [NSMutableArray array];
    _scanLog.text = @"";
    _scanRunning = YES;
    _scanBtn.enabled = NO;
    _scanBtn.alpha = 0.5;
    [_scanBtn setTitle:@"扫描中…（约 15 秒）" forState:UIControlStateNormal];
    _tip.textColor = TD_DIM;
    _tip.text = @"每组注一次：变绿 = 命中，~回显 = 进了系统但没到窗口";
    // 扫描期间关掉红圈反馈：连续挪托管窗口会干扰注入序列
    _fbWasOn = TDInjectFeedbackEnabled();
    TDSetInjectFeedbackEnabled(NO);
    // TDRunInjectPlan 自己决定走合成还是真实副本，这里只是别让 TDtap 抢道
    _reWasOn = TDUseRealEvents();
    TDSetUseRealEvents(NO);
    [self scanStep];
}

- (void)scanStep {
    _scanTimer = nil;

    // 先结算上一组。判据分三层，比原来只看「有没有触摸」精确：
    //   命中   = 落点进了方块
    //   到窗口 = 本进程收到了触摸，但不在方块里（跟着落点就能看出偏到哪了）
    //   没到   = 本进程一个触摸都没收到（事件没进来，或者进了别的进程）
    if (_scanIdx > 0) {
        NSInteger echo = TDHIDMonitorEchoCount();
        BOOL ok = (_count - _prevCount) > 0;
        BOOL arrived = (_catcher.hits - _prevHits) > 0;
        [_scanHits addObject:@(ok)];
        [_scanEcho addObject:@(echo)];
        NSString *mark;
        if (ok) {
            mark = @"✓命中";
        } else if (arrived) {
            CGPoint g = _catcher.lastPoint;
            mark = [NSString stringWithFormat:@"~到窗口 (%.0f,%.0f)", g.x, g.y];
        } else {
            mark = echo > 0 ? [NSString stringWithFormat:@"~回显%ld", (long)echo] : @"✗没到";
        }
        NSString *line = [NSString stringWithFormat:@"%2ld %@  %@",
                          (long)_scanIdx, TDInjectPlanDesc(_scanIdx - 1), mark];
        _scanLog.text = _scanLog.text.length ? [_scanLog.text stringByAppendingFormat:@"\n%@", line] : line;
    }

    if (_scanIdx >= TDInjectPlanCount()) {
        [self finishScan];
        return;
    }

    TDReleaseStuckTouch();

    CGPoint c = [_target.superview convertPoint:_target.center toView:nil];
    _prevCount = _count;
    _prevHits = _catcher.hits;
    _tip.textColor = TD_DIM;
    _tip.text = [NSString stringWithFormat:@"第 %ld/%ld 组：%@",
                 (long)(_scanIdx + 1), (long)TDInjectPlanCount(),
                 TDInjectPlanDesc(_scanIdx)];
    TDRunInjectPlan(_scanIdx, c);
    _scanIdx++;

    __weak typeof(self) ws = self;
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:0.95 repeats:NO block:^(NSTimer *t) {
        [ws scanStep];
    }];
}

- (void)finishScan {
    if (_scanTimer) { [_scanTimer invalidate]; _scanTimer = nil; }
    TDSetInjectFeedbackEnabled(_fbWasOn);
    TDSetUseRealEvents(_reWasOn);
    _scanBtn.enabled = YES;
    _scanBtn.alpha = 1;
    [_scanBtn setTitle:@"再扫一遍" forState:UIControlStateNormal];

    NSInteger best = -1;
    for (NSInteger i = 0; i < (NSInteger)_scanHits.count; i++) {
        if (_scanHits[i].boolValue) { best = i; break; }
    }
    NSInteger echoSum = 0;
    NSInteger echoGroups = 0;
    for (NSNumber *n in _scanEcho) {
        echoSum += n.integerValue;
        if (n.integerValue > 0) echoGroups++;
    }

    if (best >= 0) {
        TDApplyInjectPlan(best);
        TDSetBestInjectPlan(best);
        _tip.textColor = TD_GREEN;
        _tip.text = [NSString stringWithFormat:@"第 %ld 组能点动：%@（已设为当前构造）",
                     (long)(best + 1), TDInjectPlanDesc(best)];
    } else if (echoGroups > 0) {
        _tip.textColor = TD_RED;
        _tip.text = [NSString stringWithFormat:
                     @"事件进了系统（%ld 组有回显共 %ld 个）但没到窗口 → 投递目标不对，不是权限",
                     (long)echoGroups, (long)echoSum];
    } else {
        _tip.textColor = TD_RED;
        _tip.text = @"14 组全无命中：往下看每组后面是「~到窗口」还是「✗没到」";
    }
    // 把这一轮的诊断信息也留在下面，方便截图
    _scanRunning = NO;
    _scanLog.text = [_scanLog.text stringByAppendingFormat:@"\n────\n%@", TDHIDDiagReport()];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_scanTimer) { [_scanTimer invalidate]; _scanTimer = nil; }
    if (_probeTimer) { [_probeTimer invalidate]; _probeTimer = nil; }
    if (_sampleTimer) { [_sampleTimer invalidate]; _sampleTimer = nil; }
    if (_scanBtn && !_scanBtn.enabled) TDSetInjectFeedbackEnabled(_fbWasOn);
}

#pragma mark - 坐标空间探针

static NSString *TDCoordModeName(NSInteger m) {
    switch (m) {
        case TDCoordModeNormalized: return @"归一化";
        case TDCoordModePixel:      return @"像素  ";
        default:                    return @"点    ";
    }
}

// 同一目标点，只改量纲，连打三次。
// 判读方法（落点栏会直接写出来）：
//   某一档 Δ≈0        → 量纲就是它，之前打不中纯粹是坐标算错
//   三档全「无触摸」   → 量纲不是问题，事件根本没进来（转去看签名的 platform 标志）
//   三档都落在同一个错位置 → 坐标没被采纳，系统用的还是父事件/上次的坐标
- (void)startProbe {
    if (_probeTimer || _scanTimer) return;
    _probeIdx = 0;
    _probeLines = [NSMutableArray array];
    _probeSavedCoord = TDCoordModeCurrent();
    _fbWasOn = TDInjectFeedbackEnabled();
    TDSetInjectFeedbackEnabled(NO);
    _reWasOn = TDUseRealEvents();
    TDSetUseRealEvents(NO);

    NSInteger plan = TDBestInjectPlan();
    if (plan < 0) plan = 0;
    TDApplyInjectPlan(plan);

    _scanLog.text = [NSString stringWithFormat:@"坐标探针 · 构造 #%ld %@\n目标点用「屏幕点」写，三档只换算量纲\n",
                     (long)(plan + 1), TDInjectPlanDesc(plan)];
    _probeBtn.enabled = NO;
    _scanBtn.enabled = NO;
    _probeBtn.alpha = 0.5;
    [_probeBtn setTitle:@"探针中…" forState:UIControlStateNormal];
    [self probeStep];
}

- (void)probeStep {
    _probeTimer = nil;

    if (_probeIdx > 0) {
        NSInteger mode = _probeIdx - 1;
        BOOL arrived = (_catcher.hits - _probeBaseHits) > 0;
        NSString *res;
        if (!arrived) {
            res = @"无触摸 ← 事件没进本进程";
        } else {
            CGPoint g = _catcher.lastPoint;
            CGPoint w = _probeAsked;
            res = [NSString stringWithFormat:@"落点 (%.0f,%.0f) Δ(%+.0f,%+.0f) %@",
                   g.x, g.y, g.x - w.x, g.y - w.y,
                   (fabs(g.x - w.x) < 12 && fabs(g.y - w.y) < 12) ? @"✓对" : @"✗偏"];
        }
        NSString *line = [NSString stringWithFormat:@"%@ 请求(%.0f,%.0f) → %@",
                          TDCoordModeName(mode), _probeAsked.x, _probeAsked.y, res];
        [_probeLines addObject:line];
        _scanLog.text = [_scanLog.text stringByAppendingFormat:@"%@\n", line];
    }

    if (_probeIdx >= 3) {
        [self finishProbe];
        return;
    }

    TDReleaseStuckTouch();
    TDSetCoordMode(_probeIdx);
    // 目标中心换算成屏幕点，三档都从同一个屏幕点出发
    CGPoint c = [_target.superview convertPoint:_target.center toView:nil];
    _probeAsked = c;
    _probeBaseHits = _catcher.hits;
    TDtap(c.x, c.y);
    _probeIdx++;

    __weak typeof(self) ws = self;
    _probeTimer = [NSTimer scheduledTimerWithTimeInterval:0.9 repeats:NO block:^(NSTimer *t) {
        [ws probeStep];
    }];
}

- (void)finishProbe {
    if (_probeTimer) { [_probeTimer invalidate]; _probeTimer = nil; }
    TDSetCoordMode(_probeSavedCoord);
    TDSetInjectFeedbackEnabled(_fbWasOn);
    TDSetUseRealEvents(_reWasOn);
    _probeBtn.enabled = YES;
    _scanBtn.enabled = YES;
    _probeBtn.alpha = 1;
    [_probeBtn setTitle:@"坐标探针" forState:UIControlStateNormal];

    NSInteger good = -1;
    BOOL anyArrived = NO;
    for (NSInteger i = 0; i < (NSInteger)_probeLines.count; i++) {
        if ([_probeLines[i] containsString:@"✓对"] && good < 0) good = i;
        if (![_probeLines[i] containsString:@"无触摸"]) anyArrived = YES;
    }
    if (good >= 0) {
        _tip.textColor = TD_GREEN;
        _tip.text = [NSString stringWithFormat:@"量纲 = %@（已恢复原设置，去注入页改成它）",
                     TDCoordModeName(good)];
    } else if (anyArrived) {
        _tip.textColor = TD_RED;
        _tip.text = @"事件能进窗口但三档落点都不对 → 坐标没被采纳，不是量纲问题";
    } else {
        _tip.textColor = TD_RED;
        _tip.text = @"三档都没触摸：跟坐标无关，事件根本没进来（看下面签名的 platform）";
    }
    _scanLog.text = [_scanLog.text stringByAppendingFormat:@"────\n%@", TDHIDDiagReport()];
}

- (void)updateHits {
    _hits.text = [NSString stringWithFormat:@"目标 %ld 次 · 任意触摸 %ld 次",
                  (long)_count, (long)_catcher.hits];

    if (isnan(_catcher.lastPoint.x)) {
        _land.textColor = TD_DIM;
        _land.text = @"落点 –（还没收到任何触摸）";
        return;
    }
    CGPoint got = _catcher.lastPoint;
    CGPoint want = _target.center;
    CGFloat dx = got.x - want.x, dy = got.y - want.y;
    BOOL inside = CGRectContainsPoint(_target.frame, got);
    _land.textColor = inside ? TD_GREEN : TD_RED;
    NSString *head = [NSString stringWithFormat:
                      @"落点 (%.0f,%.0f)  目标 (%.0f,%.0f)  Δ(%+.0f,%+.0f)",
                      got.x, got.y, want.x, want.y, dx, dy];
    NSString *tail = [NSString stringWithFormat:
                      @"共 %ld 次 · x %.0f~%.0f  y %.0f~%.0f",
                      (long)_catcher.hits,
                      _catcher.minPoint.x, _catcher.maxPoint.x,
                      _catcher.minPoint.y, _catcher.maxPoint.y];
    _land.text = [NSString stringWithFormat:@"%@\n%@", head, tail];
}

- (void)handleTouchAt:(CGPoint)p {
    if (CGRectContainsPoint(_target.frame, p)) {
        _count++;
        [self hit];
    }
    [self updateHits];
}

- (void)hit {
    [self refreshSampleStatus];
    [UIView animateWithDuration:0.18 animations:^{
        self->_target.backgroundColor = TD_GREEN;
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.25 animations:^{
            self->_target.backgroundColor = [UIColor colorWithRed:0.25 green:0.30 blue:0.36 alpha:1];
        }];
    }];
}

- (void)fire {
    // 目标中心换算成屏幕坐标
    CGPoint c = [_target.superview convertPoint:_target.center toView:nil];
    BOOL real = TDHIDSampleReady() && TDUseRealEvents();
    _tip.text = [NSString stringWithFormat:@"%@ (%.0f, %.0f)… 3 秒后注入",
                 real ? @"用真实事件副本" : @"（没学到真实事件）用合成事件", c.x, c.y];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TDtap(c.x, c.y);
        self->_tip.text = [NSString stringWithFormat:@"已注入 (%.0f, %.0f) · %@",
                           c.x, c.y, real ? @"真实事件副本" : TDhidStatus()];
    });
}

@end

@interface TDInjectVC : UITableViewController
@end

#pragma mark - 坐标标定
//
// 「点中间却跳到我的」＝注入生效了，但坐标被系统按另一种空间解释了。
// 这里把三种可能的空间各注一次，用自己的窗口当靶子接住，直接读出落点。

@interface TDCalibVC : UIViewController
@end

static const NSInteger kCalibModes[] = { TDCoordModePoint, TDCoordModeNormalized, TDCoordModePixel };
static NSString *TDCalibModeName(NSInteger m) {
    return m == TDCoordModeNormalized ? @"归一化" : (m == TDCoordModePixel ? @"像素" : @"点坐标");
}

@interface TDCalibVC ()
- (void)start;
- (void)say:(NSString *)fmt, ...;
- (void)runFrom:(NSInteger)modeIdx got:(NSInteger)gotIdx notes:(NSMutableArray<NSString *> *)notes;
- (void)probeAt:(CGPoint)p done:(void (^)(BOOL, CGPoint))done;
- (void)finishWith:(NSMutableArray<NSString *> *)notes;
@end

@implementation TDCalibVC {
    UILabel   *_log;
    UIButton  *_go;
    UIView    *_catcher;
    BOOL       _running;
    BOOL       _floatWasVisible;

    NSInteger  _token;
    BOOL       _probeGot;
    CGPoint    _probePt;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"坐标标定";
    self.view.backgroundColor = TD_BG;

    _log = [[UILabel alloc] initWithFrame:CGRectZero];
    _log.textColor = TD_TEXT;
    _log.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _log.numberOfLines = 0;
    _log.text = @"点「开始标定」：会依次用三种坐标空间各点两次，\n"
                 "看哪一组落点跟期望一致。\n\n"
                 "标定期间悬浮球会暂时藏起来（它盖在上面会挡靶子）。";
    _log.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_log];

    _go = [UIButton buttonWithType:UIButtonTypeSystem];
    [_go setTitle:@"开始标定" forState:UIControlStateNormal];
    [_go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _go.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _go.backgroundColor = TD_ACCENT;
    _go.layer.cornerRadius = 12;
    _go.translatesAutoresizingMaskIntoConstraints = NO;
    [_go addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_go];

    [NSLayoutConstraint activateConstraints:@[
        [_log.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_log.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],
        [_log.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],

        [_go.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [_go.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [_go.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [_go.heightAnchor constraintEqualToConstant:52],
    ]];
}

// 标定中途返回时把现场还原（不然悬浮球就一直藏着，窗口状态也可能没恢复）
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_running) {
        _running = NO;
        _token++;
        [_catcher removeFromSuperview];
        _catcher = nil;
        if (_floatWasVisible) TDFloatSetVisible(YES);
        TDSetCoordMode(TDCoordModePoint);   // 半截的标定结果不作数
    }
}

- (void)say:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    _log.text = s;
}

// 靶子：铺满全屏接住注入进来的触摸
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    if (!t) return;
    CGPoint p = [t locationInView:self.view];
    _probeGot = YES;
    _probePt = p;

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(p.x - 6, p.y - 6, 12, 12)];
    dot.backgroundColor = TD_GREEN;
    dot.layer.cornerRadius = 6;
    dot.userInteractionEnabled = NO;
    [self.view addSubview:dot];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [dot removeFromSuperview]; });
}

- (void)start {
    if (_running) return;
    _running = YES;
    _go.enabled = NO;

    // 悬浮球是全屏托管窗口，会挡在靶子上面，先藏起来
    _floatWasVisible = TDFloatVisible();
    if (_floatWasVisible) TDFloatSetVisible(NO);

    // 透明接球层，盖住按钮和文字，保证触摸都落到 self.view
    _catcher = [[UIView alloc] initWithFrame:self.view.bounds];
    _catcher.backgroundColor = [UIColor colorWithWhite:0 alpha:0.001];
    _catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_catcher];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self runFrom:0 got:0 notes:[NSMutableArray array]];
    });
}

// 每个模式两个采样点：中心（判断整体）+ 左上（判断有没有缩放）
- (void)runFrom:(NSInteger)modeIdx got:(NSInteger)gotIdx notes:(NSMutableArray<NSString *> *)notes {
    if (modeIdx >= 3) { [self finishWith:notes]; return; }

    NSInteger mode = kCalibModes[modeIdx];
    TDSetCoordMode(mode);

    CGSize s = [UIScreen mainScreen].bounds.size;
    // block 里不能引用局部数组，拆成两个标量
    CGPoint ptCenter = CGPointMake(s.width * 0.5, s.height * 0.5);
    CGPoint ptCorner = CGPointMake(s.width * 0.25, s.height * 0.3);
    CGPoint want = (gotIdx == 0) ? ptCenter : ptCorner;

    __weak typeof(self) ws = self;
    [self probeAt:want done:^(BOOL ok, CGPoint at) {
        TDCalibVC *ss = ws;
        if (!ss) return;

        if (ok) {
            CGFloat d = hypot(at.x - want.x, at.y - want.y);
            [notes addObject:[NSString stringWithFormat:@"%@ (%.0f,%.0f) → (%.0f,%.0f) 偏差%.0f %@",
                              TDCalibModeName(mode),
                              want.x, want.y, at.x, at.y, d, d < 15 ? @"✓" : @"✗"]];
        } else {
            [notes addObject:[NSString stringWithFormat:@"%@ (%.0f,%.0f) → 没接到",
                              TDCalibModeName(mode),
                              want.x, want.y]];
        }
        [ss say:@"%@", [notes componentsJoinedByString:@"\n"]];

        NSInteger nextMode = (gotIdx == 0) ? modeIdx : modeIdx + 1;
        NSInteger nextGot  = (gotIdx == 0) ? 1 : 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ss runFrom:nextMode got:nextGot notes:notes];
        });
    }];
}

- (void)probeAt:(CGPoint)p done:(void (^)(BOOL, CGPoint))done {
    _token++;
    NSInteger tk = _token;
    _probeGot = NO;
    _probePt = CGPointMake(-1, -1);

    // TDtap 里有 usleep，挪到后台队列，别卡主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TDtap(p.x, p.y);
    });

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TDCalibVC *ss = ws;
        if (!ss || tk != ss->_token) return;
        done(ss->_probeGot, ss->_probePt);
    });
}

- (void)finishWith:(NSMutableArray<NSString *> *)notes {
    if (notes.count < 6) {                 // 中途被打断，别越界
        _running = NO;
        _go.enabled = YES;
        [_catcher removeFromSuperview];
        _catcher = nil;
        if (_floatWasVisible) TDFloatSetVisible(YES);
        [self say:@"标定被打断了，重新点一次「开始标定」。"];
        return;
    }

    // 统计哪种模式两个点都命中
    NSInteger best = -1;
    for (NSInteger i = 0; i < 3; i++) {
        NSString *a = notes[i * 2];
        NSString *b = notes[i * 2 + 1];
        if ([a hasSuffix:@"✓"] && [b hasSuffix:@"✓"]) { best = kCalibModes[i]; break; }
    }

    NSMutableString *out = [notes componentsJoinedByString:@"\n"].mutableCopy;
    if (best >= 0) {
        TDSetCoordMode(best);
        [out appendFormat:@"\n\n→ 采用「%@」：两次都落在期望位置。", TDCalibModeName(best)];
    } else {
        // 找到「接到了但偏了」的模式，把偏移量算出来
        NSInteger anyGot = -1;
        for (NSInteger i = 0; i < 3; i++) {
            if (![notes[i * 2] hasSuffix:@"没接到"]) { anyGot = kCalibModes[i]; break; }
        }
        if (anyGot >= 0) {
            [out appendFormat:@"\n\n→ 只有「%@」能落到自己 App 上，但位置偏了。"
                                "把这三行发我，我按偏移量修。", TDCalibModeName(anyGot)];
        } else {
            [out appendString:@"\n\n→ 三种都没接到：注入到本 App 的路径没通。"
                           "先在抖音里实测一次，把落点位置告诉我。"];
        }
    }

    [self say:@"%@", out];
    _running = NO;
    _go.enabled = YES;
    [_catcher removeFromSuperview];
    _catcher = nil;
    if (_floatWasVisible) TDFloatSetVisible(YES);
}

@end

#pragma mark - 诊断页

@interface TDDiagVC : UIViewController <UITableViewDataSource>
@end

@implementation TDDiagVC {
    UITableView *_tv;
    NSArray<NSString *> *_titles;
    NSMutableArray<NSString *> *_values;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断";
    self.view.backgroundColor = TD_BG;

    _titles = @[@"触摸注入", @"截屏", @"悬浮球托管", @"录制（全屏取点）",
                @"后台保活", @"沙盒 / 权限", @"点击偏移 / 循环",
                @"注入自检（点得动吗）", @"崩溃日志", @"点击反馈（200ms 红圈）",
                @"注入调试（点不动就试这个）", @"坐标标定（点偏了用这个）"];

    _tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tv.dataSource = self;
    _tv.backgroundColor = TD_BG;
    _tv.separatorColor = TD_LINE;
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tv];
    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self refresh];
}

- (void)refresh {
    _values = [@[ TDhidStatus(),
                  TDcaptureStatus(),
                  TDHUDStatus(),
                  [NSString stringWithFormat:@"%@", [[TDRecorder shared] status]],
                  [NSString stringWithFormat:@"%@ · %@", [TDKeepAlive status],
                   [TDEngine shared].jetsamStatus ?: @"jetsam 未设置"],
                  TDSandboxStatus(),
                  [NSString stringWithFormat:@"±%.0fpt · 循环 %@", [TDConfig shared].jitterPx,
                   [TDConfig shared].loopCount == 0 ? @"无限" : [NSString stringWithFormat:@"%ld", (long)[TDConfig shared].loopCount]] ] mutableCopy];
    [_tv reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _titles.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"d"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
    c.backgroundColor = TD_CARD;
    c.textLabel.textColor = TD_TEXT;
    c.detailTextLabel.textColor = TD_DIM;
    c.textLabel.text = _titles[ip.row];
    c.detailTextLabel.text = ip.row < (NSInteger)_values.count ? _values[ip.row] : @"";
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.row == 0) {
        // 第 1 行兼做「救急」：up 丢了会留一根幽灵手指，整机连人工点按都失灵
        if (TDHasStuckTouch()) {
            c.detailTextLabel.text = @"⚠️ 有手指卡在屏幕上 · 点这里释放";
            c.detailTextLabel.textColor = TD_RED;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (ip.row == 7) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"已注入 %ld 次 · 验证注入和坐标",
                                  (long)TDInjectCount()];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.row == 8) {
        c.detailTextLabel.text = @"点开看上次闪退的堆栈";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.row == 9) {
        BOOL on = TDInjectFeedbackEnabled();
        c.detailTextLabel.text = on ? @"开 · 每次点击冒一个红圈，能看清点在哪"
                                    : @"关 · 回放时不显示任何标记";
    } else if (ip.row == 10) {
        c.detailTextLabel.text = TDInjectVariantDesc();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.row == 11) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@", TDCoordModeDesc()];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 0) {
        BOOL had = TDHasStuckTouch();
        TDReleaseStuckTouch();
        TDReleaseAllTouches();
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"释放触摸"
                             message:(had ? @"已把卡住的那根手指抬起来，现在手点应该恢复正常。"
                                          : @"当前没有检测到卡住的手指。")
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        [self refresh];
        return;
    }
    if (ip.row == 7) {
        [self.navigationController pushViewController:[TDSelfTestVC new] animated:YES];
    } else if (ip.row == 9) {
        TDSetInjectFeedbackEnabled(!TDInjectFeedbackEnabled());
        [tv reloadData];
    } else if (ip.row == 10) {
        [self.navigationController pushViewController:[TDInjectVC new] animated:YES];
    } else if (ip.row == 11) {
        [self.navigationController pushViewController:[TDCalibVC new] animated:YES];
    } else if (ip.row == 8) {
        NSString *log = TDcrashLogText();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"崩溃日志"
                                                                  message:(log.length ? log : @"没有崩溃记录")
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            TDcrashLogClear();
            [self refresh];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

#pragma mark - 注入调试

/// 「点得动吗」手术台：把事件构造的几种可能拆成开关，
/// 一次安装就能在这台机器上把组合试完，不用每轮都重新出包。
@implementation TDInjectVC {
    NSInteger _trialLeft;
    NSTimer   *_trialTimer;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入调试";
    self.view.backgroundColor = TD_BG;
    self.tableView.backgroundColor = TD_BG;
    self.tableView.separatorColor = TD_LINE;
    TDProbedSenderID();          // 先把真实 ID 探出来，界面上直接显示结果
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"① 事件里的 senderID 怎么给",
             @"② 再补哪些字段",
             @"③ 坐标用哪个空间",
             @"④ 试一次"][s];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) {
        uint64_t sid = TDProbedSenderID();
        return [NSString stringWithFormat:@"当前：%@\n本机真实 senderID：%@",
                TDInjectVariantDesc(),
                sid ? [NSString stringWithFormat:@"0x%llx", sid] : @"读不到（不设也不影响）"];
    }
    if (s == 1) {
        return @"BackBoard digitizer info 是 iOS 13 之后的关键一步，"
               @"但参数不对会直接闪退。每次启动 App 都会自动关掉它。";
    }
    if (s == 2) {
        return @"屏幕坐标填进去，系统按哪种空间解释，各版本不一样。"
               @"填错时坐标会被 clamp 到边界：点中间落到右下角 = 抖音的「我」。"
               @"拿不准就点诊断页的「坐标标定」自动扫一遍。";
    }
    return @"点一下 → 5 秒后往屏幕正中注入一次。这时按 Home 切到抖音等着："
            "红圈冒出来而且视频暂停/继续，就说明这个组合对了。";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;
    if (s == 1) return 3;
    if (s == 2) return 3;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"i"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"i"];
    c.backgroundColor = TD_CARD;
    c.textLabel.textColor = TD_TEXT;
    c.detailTextLabel.textColor = TD_DIM;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = UITableViewCellAccessoryNone;

    if (ip.section == 0) {
        NSArray<NSString *> *names = @[@"不设 senderID（最保守）",
                                       @"硬编码 0x8000000817319372",
                                       @"读本机真实 senderID"];
        NSArray<NSString *> *subs = @[@"让 admin 客户端自己填，不会被当成外来设备",
                                      @"社区流传的那个值，机型不对就被丢掉",
                                      @"从 HID 服务列表里读，理论上最准"];
        c.textLabel.text = names[ip.row];
        c.detailTextLabel.text = subs[ip.row];
        if (TDInjectVariantCurrent() == ip.row) {
            c.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = @"补 IsBuiltIn = 1";
            c.detailTextLabel.text = @"声明成内建事件，有的系统只认带这个的";
            if (TDInjectBuiltInOn()) c.accessoryType = UITableViewCellAccessoryCheckmark;
        } else if (ip.row == 1) {
            c.textLabel.text = @"补 BackBoard digitizer info";
            c.detailTextLabel.text = @"告诉 BackBoard 这事件属于哪块屏（⚠️ 可能闪退）";
            if (TDInjectBKSDigitizerInfoOn()) c.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            c.textLabel.text = @"父事件坐标回退 (0,0)";
            c.detailTextLabel.text = @"旧写法。会变成「从左上角滑过来」，抖音当滑动吃掉；"
                                      "只有新写法完全点不动时才用来验证链路";
            if (TDInjectHandLegacy()) c.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (ip.section == 2) {
        NSArray<NSString *> *names = @[@"屏幕点（414×736，常规）",
                                       @"归一化 0~1",
                                       @"物理像素（×3）"];
        NSArray<NSString *> *subs = @[@"UIScreen.bounds 的坐标，多数注入实现用这个",
                                      @"x÷宽、y÷高，超范围会被截断到 1.0",
                                      @"点坐标乘屏幕 scale，Retina 屏上偶见"];
        c.textLabel.text = names[ip.row];
        c.detailTextLabel.text = subs[ip.row];
        if (TDCoordModeCurrent() == (TDCoordMode)ip.row) {
            c.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else {
        if (_trialLeft > 0) {
            c.textLabel.text = [NSString stringWithFormat:@"%ld 秒后注入… 现在切抖音", (long)_trialLeft];
            c.textLabel.textColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.15 alpha:1.0];
            c.detailTextLabel.text = @"按 Home 切过去等着";
        } else {
            c.textLabel.text = @"5 秒后往屏幕中间注入一次";
            c.textLabel.textColor = [UIColor colorWithRed:0.24 green:0.80 blue:0.42 alpha:1.0];
            c.detailTextLabel.text = @"看到红圈 + 视频暂停 = 这个组合对了";
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0) {
        TDSetInjectVariant(ip.row);
        [tv reloadData];
        return;
    }
    if (ip.section == 1) {
        if (ip.row == 0) {
            TDSetInjectBuiltIn(!TDInjectBuiltInOn());
            [tv reloadData];
            return;
        }
        if (ip.row == 2) {
            TDSetInjectHandLegacy(!TDInjectHandLegacy());
            [tv reloadData];
            return;
        }
        if (TDInjectBKSDigitizerInfoOn()) {
            TDSetInjectBKSDigitizerInfo(NO);
            [tv reloadData];
            return;
        }
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"可能闪退"
                             message:@"这一项会调用系统私有函数 BKSHIDEventSetDigitizerInfo。"
                                      "参数对就通了，不对会当场闪退。闪退后重开 App 会自动关掉它，"
                                      "不会连崩。\n\n继续吗？"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
            TDSetInjectBKSDigitizerInfo(YES);
            [tv reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"算了" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (ip.section == 2) {
        TDSetCoordMode(ip.row);
        [tv reloadData];
        return;
    }
    if (ip.section == 3) {
        [self startTrial];
        return;
    }
    [self startTrial];
}

- (void)startTrial {
    [_trialTimer invalidate];
    _trialLeft = 5;
    [self refreshTrialSection];

    CGSize sb = [UIScreen mainScreen].bounds.size;
    // 注入用 GCD 定时，不依赖主线程 runloop 的 tick（后台更稳）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TDtap(sb.width / 2.0, sb.height * 0.45);
        TDLog(@"已注入一次（%@）", TDInjectVariantDesc());
    });

    __weak typeof(self) ws = self;
    _trialTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *tm) {
        typeof(self) ss = ws;
        if (!ss) { [tm invalidate]; return; }
        ss->_trialLeft--;
        if (ss->_trialLeft <= 0) {
            [tm invalidate];
            ss->_trialTimer = nil;
            ss->_trialLeft = 0;
        }
        [ss refreshTrialSection];
    }];
}

- (void)refreshTrialSection {
    if (self.tableView.numberOfSections < 4) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3]
                  withRowAnimation:UITableViewRowAnimationNone];
}

@end

#pragma mark - 主界面

@interface TDMainVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation TDMainVC {
    UITableView *_tv;
    UILabel *_log;
    UIButton *_recBtn;
    UIButton *_playBtn;
    UIButton *_stopBtn;
    UIView *_mask;
    UILabel *_countdown;
    NSInteger _countLeft;
    NSTimer *_countTimer;
    NSTimer *_liveTimer;
    BOOL _pendingRecord;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TapDog";
    self.view.backgroundColor = TD_BG;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"诊断" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(openDiag)];

    _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.backgroundColor = TD_BG;
    _tv.separatorColor = TD_LINE;
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tv];

    _log = [[UILabel alloc] initWithFrame:CGRectZero];
    _log.textColor = TD_DIM;
    _log.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _log.numberOfLines = 2;
    _log.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_log];

    // 底部三个大按钮
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.backgroundColor = TD_CARD;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    _recBtn = [self barButton:@"● 录制" color:TD_RED action:@selector(onRecord)];
    _playBtn = [self barButton:@"▶ 播放" color:TD_GREEN action:@selector(onPlay)];
    _stopBtn = [self barButton:@"■ 停止" color:[UIColor colorWithWhite:0.35 alpha:1] action:@selector(onStop)];
    [bar addSubview:_recBtn];
    [bar addSubview:_playBtn];
    [bar addSubview:_stopBtn];

    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:_log.topAnchor constant:-4],

        [_log.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],
        [_log.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],
        [_log.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-8],
        [_log.heightAnchor constraintEqualToConstant:30],

        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:92],

        [_recBtn.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [_playBtn.leadingAnchor constraintEqualToAnchor:_recBtn.trailingAnchor constant:10],
        [_stopBtn.leadingAnchor constraintEqualToAnchor:_playBtn.trailingAnchor constant:10],
        [_stopBtn.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-14],
        [_recBtn.widthAnchor constraintEqualToAnchor:_playBtn.widthAnchor],
        [_playBtn.widthAnchor constraintEqualToAnchor:_stopBtn.widthAnchor],
    ]];
    for (UIView *b in @[_recBtn, _playBtn, _stopBtn]) {
        [b.topAnchor constraintEqualToAnchor:bar.topAnchor constant:12].active = YES;
        [b.heightAnchor constraintEqualToConstant:56].active = YES;
    }

    // 倒计时遮罩
    _mask = [[UIView alloc] initWithFrame:CGRectZero];
    _mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    _mask.hidden = YES;
    _mask.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_mask];
    [NSLayoutConstraint activateConstraints:@[
        [_mask.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_mask.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_mask.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_mask.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    _countdown = [[UILabel alloc] initWithFrame:CGRectZero];
    _countdown.font = [UIFont monospacedDigitSystemFontOfSize:104 weight:UIFontWeightBold];
    _countdown.textColor = TD_GREEN;
    _countdown.textAlignment = NSTextAlignmentCenter;
    _countdown.translatesAutoresizingMaskIntoConstraints = NO;
    [_mask addSubview:_countdown];
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = @"现在切到抖音";
    hint.textColor = TD_TEXT;
    hint.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.tag = 99;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [_mask addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [_countdown.centerXAnchor constraintEqualToAnchor:_mask.centerXAnchor],
        [_countdown.centerYAnchor constraintEqualToAnchor:_mask.centerYAnchor constant:-30],
        [hint.centerXAnchor constraintEqualToAnchor:_mask.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:_countdown.bottomAnchor constant:6],
    ]];

    __weak typeof(self) ws = self;
    TDSetLogHandler(^(NSString *m) {
        typeof(self) ss = ws;
        if (!ss) return;
        ss->_log.text = m;
        [ss refreshButtons];
    });
    [TDEngine shared].onFinish = ^{
        typeof(self) ss = ws;
        [ss refreshButtons];
        TDFloatRefresh();
    };

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dataChanged)
                                                 name:TDDataChangedNotification object:nil];
    [self refreshButtons];
}

- (UIButton *)barButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    b.backgroundColor = color;
    b.layer.cornerRadius = 14;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // 上次若崩了，主动把它摆到脸上，别让用户再去翻诊断页
    static BOOL once = NO;
    if (once) return;
    once = YES;

    NSString *crash = TDcrashLogText();
    if (crash.length == 0) return;

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:[crash substringToIndex:MIN((NSUInteger)700, crash.length)]];
    NSString *trace = TDtraceLogText();
    if (trace.length) {
        [msg appendFormat:@"\n— 录制轨迹 —\n%@",
                          [trace substringToIndex:MIN((NSUInteger)400, trace.length)]];
    }

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"上次是异常退出的"
                                                             message:msg
                                                      preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        TDcrashLogClear();
        TDtraceLogClear();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_tv reloadData];
    [self refreshButtons];
}

- (void)dataChanged {
    [_tv reloadData];
    [self refreshButtons];
    TDFloatRefresh();
}

- (void)refreshButtons {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];
    _recBtn.alpha = 1;
    [_recBtn setTitle:(r.recording ? @"■ 停止录制" : @"● 录制") forState:UIControlStateNormal];
    [_playBtn setTitle:(e.running ? @"▶ 运行中" : @"▶ 播放") forState:UIControlStateNormal];
    _playBtn.alpha = e.running ? 0.55 : 1;
    _stopBtn.alpha = (e.running || r.recording) ? 1 : 0.45;
}

#pragma mark 动作

- (void)openDiag {
    [self.navigationController pushViewController:[TDDiagVC new] animated:YES];
}

- (void)onRecord {
    TDRecorder *r = [TDRecorder shared];
    if (r.recording) {
        [self finishRecording];
        return;
    }
    // 录制要等倒计时结束才开始，否则倒计时这段时间的操作会被录进去
    _pendingRecord = YES;
    [self startCountdown];
}

- (void)onPlay {
    TDEngine *e = [TDEngine shared];
    if (e.running) return;
    TDScript *s = [[TDScriptStore shared] selectedScript];
    if (!s || s.steps.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"脚本是空的"
                                                                  message:@"先点「录制」，去抖音点几下，再回来停止"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    _pendingRecord = NO;
    [self startCountdown];
}

- (void)onStop {
    [self stopLiveCounter];
    [[TDEngine shared] stop];
    if ([TDRecorder shared].recording) [self finishRecording];
    [self refreshButtons];
    TDFloatRefresh();
}

- (void)startCountdown {
    if (_countTimer) return;
    _countLeft = 3;
    _countdown.text = @"3";
    _countdown.textColor = _pendingRecord ? TD_RED : TD_GREEN;
    UILabel *hint = [_mask viewWithTag:99];
    hint.text = _pendingRecord ? @"切到抖音 · 倒计时结束后出现取点面板"
                               : @"现在切到抖音，马上开始回放";
    _mask.hidden = NO;
    [self.view bringSubviewToFront:_mask];

    __weak typeof(self) ws = self;
    _countTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        typeof(self) ss = ws;
        if (!ss) { [tm invalidate]; return; }
        ss->_countLeft--;
        if (ss->_countLeft <= 0) {
            [tm invalidate];
            ss->_countTimer = nil;
            ss->_mask.hidden = YES;
            [ss fire];
        } else {
            ss->_countdown.text = [NSString stringWithFormat:@"%ld", (long)ss->_countLeft];
        }
    }];
}

- (void)fire {
    if (_pendingRecord) {
        TDRecorder *r = [TDRecorder shared];
        if (!r.recording && ![r start]) {
            TDLog(@"取点层启动失败：%@", [r status]);
            return;
        }
        TDLog(@"取点中：切到抖音，点要执行的位置，最后点面板上的「完成」");
        [self startLiveCounter];
    } else {
        TDScript *s = [[TDScriptStore shared] selectedScript];
        if (!s) return;
        [[TDEngine shared] playSteps:[s engineSteps] loop:[TDConfig shared].loopCount];
    }
    [self refreshButtons];
    TDFloatRefresh();
}

/// 取点时实时显示已经录了几步
- (void)startLiveCounter {
    [self stopLiveCounter];
    __weak typeof(self) ws = self;
    _liveTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *tm) {
        typeof(self) ss = ws;
        if (!ss) { [tm invalidate]; return; }
        TDRecorder *r = [TDRecorder shared];
        if (!r.recording) { [ss stopLiveCounter]; return; }
        ss->_log.text = [NSString stringWithFormat:@"取点中 · 已记录 %ld 步（面板上点「完成」保存）",
                         (long)r.eventCount];
    }];
}

- (void)stopLiveCounter {
    if (_liveTimer) { [_liveTimer invalidate]; _liveTimer = nil; }
}

- (void)finishRecording {
    [self stopLiveCounter];
    TDRecorder *r = [TDRecorder shared];
    if (!r.recording) return;
    NSInteger n = r.eventCount;
    [r finishAndSave];
    TDLog(@"录制结束：%ld 步", (long)n);
    [_tv reloadData];
    [self refreshButtons];
    TDFloatRefresh();
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) {
        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        return [NSString stringWithFormat:@"脚本（%@ · build %@）",
                info[@"CFBundleShortVersionString"] ?: @"?",
                info[@"CFBundleVersion"] ?: @"?"];
    }
    return @"工具";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? [TDScriptStore shared].scripts.count : 3;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"s"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
    c.backgroundColor = TD_CARD;
    c.textLabel.textColor = TD_TEXT;
    c.detailTextLabel.textColor = TD_DIM;
    c.contentView.backgroundColor = TD_CARD;

    if (ip.section == 0) {
        TDScript *s = [TDScriptStore shared].scripts[ip.row];
        c.textLabel.text = s.name;
        c.detailTextLabel.text = [s summary];
        c.accessoryType = (ip.row == [TDScriptStore shared].selected)
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        c.tintColor = TD_GREEN;
    } else {
        if (ip.row == 0) {
            c.textLabel.text = @"＋ 新建脚本";
            c.detailTextLabel.text = @"从空白开始，用录制往里加步骤";
        } else if (ip.row == 1) {
            c.textLabel.text = @"注入自检";
            c.detailTextLabel.text = [NSString stringWithFormat:@"点得动吗 · 已注入 %ld 次",
                                      (long)TDInjectCount()];
        } else {
            TDConfig *cfg = [TDConfig shared];
            c.textLabel.text = @"循环次数 / 点击偏移";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 偏移 ±%.0fpt",
                                      cfg.loopCount == 0 ? @"无限循环" : [NSString stringWithFormat:@"循环 %ld 次", (long)cfg.loopCount],
                                      cfg.jitterPx];
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        [TDScriptStore shared].selected = ip.row;
        [[TDScriptStore shared] save];
        [tv reloadData];
        [self refreshButtons];
        TDFloatRefresh();
    } else if (ip.row == 0) {
        [[TDScriptStore shared] createScript];
        [tv reloadData];
        [self refreshButtons];
    } else if (ip.row == 1) {
        [self.navigationController pushViewController:[TDSelfTestVC new] animated:YES];
    } else {
        [self editSettings];
    }
}

- (void)editSettings {
    TDConfig *cfg = [TDConfig shared];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"循环 / 偏移"
                                                              message:@"循环 0 = 无限；偏移是每次点击的随机抖动半径（防检测）"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"循环次数(0=无限)";
        t.text = [NSString stringWithFormat:@"%ld", (long)cfg.loopCount];
        t.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"偏移(点)";
        t.text = [NSString stringWithFormat:@"%.0f", cfg.jitterPx];
        t.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        cfg.loopCount = [a.textFields[0].text integerValue];
        cfg.jitterPx = [a.textFields[1].text doubleValue];
        [cfg save];
        [self->_tv reloadData];
        [self refreshButtons];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete && ip.section == 0) {
        [[TDScriptStore shared] removeAtIndex:ip.row];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
        [tv reloadData];
        [self refreshButtons];
    }
}

@end

#pragma mark - 工厂

UIViewController *TDCreateMainVC(void) {
    TDMainVC *root = [TDMainVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = TD_ACCENT;
    nav.navigationBar.translucent = YES;
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = TD_BG;
        ap.titleTextAttributes = @{NSForegroundColorAttributeName: TD_TEXT};
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
    }
    return nav;
}
