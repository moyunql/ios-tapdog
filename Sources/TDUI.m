#import "TD.h"
#import <QuartzCore/QuartzCore.h>

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

#pragma mark - 自检页（验证注入是否真的点得动、坐标对不对）

@interface TDSelfTestVC : UIViewController
@end

@implementation TDSelfTestVC {
    UIView *_target;
    UILabel *_hits;
    UILabel *_tip;
    NSInteger _count;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入自检";
    self.view.backgroundColor = TD_BG;

    _hits = [[UILabel alloc] initWithFrame:CGRectZero];
    _hits.text = @"被点中 0 次";
    _hits.textColor = TD_TEXT;
    _hits.font = [UIFont monospacedDigitSystemFontOfSize:20 weight:UIFontWeightBold];
    _hits.textAlignment = NSTextAlignmentCenter;
    _hits.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hits];

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

    // 点目标本身也能计数（手动点 vs 注入点，对比用）
    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hit)];
    [_target addGestureRecognizer:t];

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
    _tip.text = @"3 秒后注入：目标变绿=命中，说明注入和坐标都对。";
    _tip.textColor = TD_DIM;
    _tip.font = [UIFont systemFontOfSize:13];
    _tip.numberOfLines = 0;
    _tip.textAlignment = NSTextAlignmentCenter;
    _tip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tip];

    [NSLayoutConstraint activateConstraints:@[
        [_hits.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_hits.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],

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
    ]];
}

- (void)hit {
    _count++;
    _hits.text = [NSString stringWithFormat:@"被点中 %ld 次", (long)_count];
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
    _tip.text = [NSString stringWithFormat:@"注入 (%.0f, %.0f)…", c.x, c.y];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TDtap(c.x, c.y);
        self->_tip.text = [NSString stringWithFormat:@"已注入 (%.0f, %.0f) · %@", c.x, c.y, TDhidStatus()];
    });
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
                @"注入自检（点得动吗）", @"崩溃日志"];

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
    if (ip.row == 7 || ip.row == 8) {
        c.detailTextLabel.text = ip.row == 7 ? @"验证 HID 注入和坐标映射" : @"点开看上次闪退的堆栈";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 7) {
        [self.navigationController pushViewController:[TDSelfTestVC new] animated:YES];
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
    return s == 0 ? @"脚本（点选，左滑删除）" : @"";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? [TDScriptStore shared].scripts.count : 2;
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
