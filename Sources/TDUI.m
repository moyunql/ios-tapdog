#import "TD.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// ---------------------------------------------------------------------------
// 后台保活：UIBackgroundModes=audio + 循环播放静音，切到抖音后进程不被挂起
// ---------------------------------------------------------------------------
static NSString *gAudioStatus = @"未启动";

// 切到别的 App（TapDog 进后台）时自动开跑，省得再去点悬浮球
static BOOL TDAutoStartGet(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"tdAutoStartOnBackground"];
    return v == nil ? YES : [v boolValue];
}
static void TDAutoStartSet(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"tdAutoStartOnBackground"];
}

@interface TDKeepAlive : NSObject
+ (void)start;
+ (NSString *)status;
@end

@implementation TDKeepAlive {
    AVAudioPlayer *_player;
}
+ (instancetype)shared {
    static TDKeepAlive *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ k = [TDKeepAlive new]; });
    return k;
}
+ (void)start { [[self shared] begin]; }
+ (NSString *)status { return gAudioStatus; }

- (void)begin {
    if (_player) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
    if (err) { gAudioStatus = [NSString stringWithFormat:@"setCategory 失败 %ld", (long)err.code]; return; }
    err = nil;
    [s setActive:YES error:&err];
    if (err) { gAudioStatus = [NSString stringWithFormat:@"setActive 失败 %ld", (long)err.code]; return; }

    // 生成 1 秒 8kHz 单声道静音 PCM，包成最小 WAV
    const int rate = 8000, secs = 1, ch = 1, bits = 16;
    int dataLen = rate * secs * ch * bits / 8;
    NSMutableData *wav = [NSMutableData data];
    uint32_t u32; uint16_t u16;
    [wav appendBytes:"RIFF" length:4];
    u32 = 36 + dataLen; [wav appendBytes:&u32 length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    u32 = 16; [wav appendBytes:&u32 length:4];
    u16 = 1; [wav appendBytes:&u16 length:2];
    u16 = ch; [wav appendBytes:&u16 length:2];
    u32 = rate; [wav appendBytes:&u32 length:4];
    u32 = rate * ch * bits / 8; [wav appendBytes:&u32 length:4];
    u16 = ch * bits / 8; [wav appendBytes:&u16 length:2];
    u16 = bits; [wav appendBytes:&u16 length:2];
    [wav appendBytes:"data" length:4];
    u32 = dataLen; [wav appendBytes:&u32 length:4];
    [wav appendData:[NSMutableData dataWithLength:dataLen]];

    _player = [[AVAudioPlayer alloc] initWithData:wav error:NULL];
    _player.numberOfLoops = -1;
    _player.volume = 0.02;
    BOOL ok = [_player play];
    gAudioStatus = ok ? @"静音播放中（后台不会被挂起）"
                      : @"播放失败（切到抖音可能被挂起）";
}
@end

// 沙盒探测：能往 /var/mobile/Media 写文件，说明 no-sandbox 权限真的生效了。
static NSString *TDSandboxStatus(void) {
    const char *path = "/var/mobile/Media/.tapdog_probe";
    int fd = open(path, O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(path);
        return @"已绕过（no-sandbox 生效）";
    }
    return [NSString stringWithFormat:@"受限 errno=%d（权限没生效）", errno];
}

static const CGFloat kTDBallSize    = 56.0;   // 球直径
static const CGFloat kTDBallPad     = 10.0;   // 窗口相对球留的一圈余量
static const CGFloat kTDOverlaySide = 76.0;   // 托管窗口边长 = 56 + 10*2

static NSString * const kTDBallPosX = @"tdBallCenterX";
static NSString * const kTDBallPosY = @"tdBallCenterY";

/// 主界面要用它开关悬浮球，AppDelegate 创建后赋值
static UIWindow *gTDOverlayWindow = nil;

/// 把窗口放到「上次拖到的位置」；没有记录就放右侧中部
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
    cy = MAX(half + 30, MIN(sb.size.height - half - 34, cy));   // 让开状态栏和 Home 条
    w.frame = CGRectMake(cx - half, cy - half, kTDOverlaySide, kTDOverlaySide);

    // 位置变了要重新让 SpringBoard 认一遍（surface 几何变化）
    TDHUDRegisterWindow(w);
}

#pragma mark - 取点面板

typedef NS_ENUM(NSInteger, TDPickerMode) {
    TDPickerTap,
    TDPickerLong,
    TDPickerSwipe,
    TDPickerRect
};

@interface TDPickerVC : UIViewController
@property (nonatomic) TDPickerMode mode;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) void (^onTapPoint)(CGPoint p);
@property (nonatomic, copy) void (^onLongPoint)(CGPoint p);
@property (nonatomic, copy) void (^onSwipe)(CGPoint a, CGPoint b, NSTimeInterval dur);
@property (nonatomic, copy) void (^onRect)(CGRect pixelRect);
@end

@implementation TDPickerVC {
    UIImageView *_iv;
    UILabel *_hud;
    UIView *_mark;
    CGPoint _rectStart;
    BOOL _hasStart;
    CGPoint _panStart;
    CFTimeInterval _panT0;
    BOOL _panning;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _iv = [[UIImageView alloc] initWithImage:_image];
    _iv.frame = self.view.bounds;
    _iv.contentMode = UIViewContentModeScaleToFill;
    _iv.userInteractionEnabled = NO;
    [self.view addSubview:_iv];

    _hud = [[UILabel alloc] initWithFrame:CGRectMake(0, 54, self.view.bounds.size.width, 26)];
    _hud.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.7 alpha:1];
    _hud.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    _hud.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_hud];

    _mark = [[UIView alloc] initWithFrame:CGRectZero];
    _mark.layer.borderColor = [UIColor colorWithRed:0.4 green:1 blue:0.7 alpha:1].CGColor;
    _mark.layer.borderWidth = 1.5;
    _mark.backgroundColor = [UIColor colorWithRed:0.3 green:1 blue:0.6 alpha:0.18];
    _mark.hidden = YES;
    [self.view addSubview:_mark];

    NSString *tip = @{@(TDPickerTap): @"点哪加哪（点击）",
                      @(TDPickerLong): @"长按屏幕任意处（长按）",
                      @(TDPickerSwipe): @"按住拖一条线（滑动）",
                      @(TDPickerRect): @"点两下框出目标图（识图）"}[@(_mode)];
    self.title = tip;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self.view addGestureRecognizer:tap];

    if (_mode == TDPickerLong) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLong:)];
        lp.minimumPressDuration = 0.5;
        [self.view addGestureRecognizer:lp];
        [tap requireGestureRecognizerToFail:lp];
    }
    if (_mode == TDPickerSwipe) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.view addGestureRecognizer:pan];
    }
}

- (CGPoint)imgPixel:(CGPoint)p {
    CGSize b = self.view.bounds.size;
    CGFloat sx = _image.size.width / b.width;
    CGFloat sy = _image.size.height / b.height;
    return CGPointMake(p.x * sx, p.y * sy);
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    _hud.text = [NSString stringWithFormat:@"%.0f, %.0f", p.x, p.y];

    if (_mode == TDPickerTap) {
        if (self.onTapPoint) self.onTapPoint(p);
        [self flashAt:p];
    } else if (_mode == TDPickerRect) {
        if (!_hasStart) {
            _rectStart = p; _hasStart = YES;
            _mark.hidden = NO;
            _mark.frame = CGRectMake(p.x, p.y, 1, 1);
        } else {
            _hasStart = NO;
            CGPoint a = [self imgPixel:_rectStart];
            CGPoint b = [self imgPixel:p];
            CGRect r = CGRectMake(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
            if (r.size.width > 8 && r.size.height > 8 && self.onRect) self.onRect(r);
            _mark.hidden = YES;
        }
    }
}

- (void)handleLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:self.view];
    _hud.text = [NSString stringWithFormat:@"长按 %.0f, %.0f", p.x, p.y];
    if (self.onLongPoint) self.onLongPoint(p);
    [self flashAt:p];
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _panStart = p; _panT0 = CACurrentMediaTime(); _panning = YES;
        _mark.hidden = NO;
        _mark.frame = CGRectMake(p.x - 6, p.y - 6, 12, 12);
        _mark.layer.cornerRadius = 6;
    } else if (g.state == UIGestureRecognizerStateChanged && _panning) {
        _hud.text = [NSString stringWithFormat:@"%.0f,%.0f → %.0f,%.0f", _panStart.x, _panStart.y, p.x, p.y];
        CGFloat x = MIN(_panStart.x, p.x), y = MIN(_panStart.y, p.y);
        _mark.layer.cornerRadius = 0;
        _mark.frame = CGRectMake(x, y, fabs(p.x - _panStart.x), fabs(p.y - _panStart.y));
    } else if ((g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) && _panning) {
        _panning = NO;
        _mark.hidden = YES;
        NSTimeInterval dur = MAX(0.15, CACurrentMediaTime() - _panT0);
        if (hypot(p.x - _panStart.x, p.y - _panStart.y) > 20 && self.onSwipe) {
            self.onSwipe(_panStart, p, dur);
        }
    }
}

- (void)flashAt:(CGPoint)p {
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(p.x - 16, p.y - 16, 32, 32)];
    d.layer.cornerRadius = 16;
    d.backgroundColor = [UIColor colorWithRed:0.3 green:1 blue:0.6 alpha:0.55];
    [self.view addSubview:d];
    [UIView animateWithDuration:0.45 animations:^{ d.alpha = 0; d.transform = CGAffineTransformMakeScale(1.6, 1.6); }
                     completion:^(BOOL f) { [d removeFromSuperview]; }];
}

@end

#pragma mark - 主界面

@interface TDMainVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation TDMainVC {
    UITableView *_tv;
    UITextView *_logView;
    UIButton *_runBtn;
    UIBarButtonItem *_runItem;
    UILabel *_countdown;
    NSTimer *_countTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TapDog 识图连点";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tv.dataSource = self;
    _tv.delegate = self;
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_tv];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _logView.layer.cornerRadius = 8;
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_logView];

    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:_logView.topAnchor constant:-6],

        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],
        [_logView.heightAnchor constraintEqualToConstant:110],
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"开始"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(toggleRun)];

    [TDEngine shared].logHandler = ^(NSString *m) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *old = self->_logView.text ?: @"";
            NSArray *lines = [old componentsSeparatedByString:@"\n"];
            NSMutableArray *keep = [NSMutableArray array];
            NSUInteger start = lines.count > 60 ? lines.count - 60 : 0;
            for (NSUInteger i = start; i < lines.count; i++) [keep addObject:lines[i]];
            [keep addObject:m];
            self->_logView.text = [keep componentsJoinedByString:@"\n"];
            [self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.text.length, 0)];
        });
    };

    [TDKeepAlive start];
    [[TDEngine shared] logMsg:@"HID: %@ | 截屏: %@", TDhidStatus(), TDcaptureStatus()];

    // 倒计时大字：点「开始」后给 3 秒切到抖音
    _countdown = [[UILabel alloc] initWithFrame:CGRectZero];
    _countdown.font = [UIFont monospacedDigitSystemFontOfSize:96 weight:UIFontWeightBold];
    _countdown.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.6 alpha:1];
    _countdown.textAlignment = NSTextAlignmentCenter;
    _countdown.hidden = YES;
    _countdown.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_countdown];
    [NSLayoutConstraint activateConstraints:@[
        [_countdown.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_countdown.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)startWithCountdown {
    if (_countTimer) return;
    __block NSInteger left = 3;
    _countdown.text = @"3";
    _countdown.hidden = NO;
    [[TDEngine shared] logMsg:@"3 秒后开始，现在切到抖音"];
    __weak typeof(self) ws = self;
    _countTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        typeof(self) ss = ws;
        if (!ss) { [tm invalidate]; return; }
        left--;
        if (left <= 0) {
            [tm invalidate];
            ss->_countTimer = nil;
            ss->_countdown.hidden = YES;
            [[TDEngine shared] startWithScript:@{}];
            [ss refreshRunBtn];
            [ss->_tv reloadData];
        } else {
            ss->_countdown.text = [NSString stringWithFormat:@"%ld", (long)left];
        }
    }];
}

- (void)toggleRun {
    TDEngine *e = [TDEngine shared];
    if (e.running) {
        [e stop];
        if (_countTimer) { [_countTimer invalidate]; _countTimer = nil; }
        _countdown.hidden = YES;
    } else {
        [self startWithCountdown];
    }
    [self refreshRunBtn];
    [_tv reloadData];
}

- (void)refreshRunBtn {
    self.navigationItem.rightBarButtonItem.title = [TDEngine shared].running ? @"停止" : @"开始";
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"状态", @"脚本步骤", @"添加"][s];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 8;
    if (s == 1) return [TDConfig shared].steps.count;
    return 4;
}

- (NSString *)stepTitle:(NSDictionary *)st {
    NSString *t = st[@"t"];
    if ([t isEqualToString:@"tap"])   return [NSString stringWithFormat:@"点击 (%.0f, %.0f)", [st[@"x"] doubleValue], [st[@"y"] doubleValue]];
    if ([t isEqualToString:@"long"])  return [NSString stringWithFormat:@"长按 (%.0f, %.0f) %.0fms", [st[@"x"] doubleValue], [st[@"y"] doubleValue], [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%.0f,%.0f)→(%.0f,%.0f) %.0fms",
                                              [st[@"x1"] doubleValue], [st[@"y1"] doubleValue],
                                              [st[@"x2"] doubleValue], [st[@"y2"] doubleValue], [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"wait"])  return [NSString stringWithFormat:@"等待 %.0fms", [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"find"])  return [NSString stringWithFormat:@"识图 %@ ≥%.2f", st[@"tpl"], [st[@"th"] doubleValue]];
    if ([t isEqualToString:@"gesture"]) return @"轨迹手势";
    return t ?: @"?";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.accessoryType = UITableViewCellAccessoryNone;
    c.accessoryView = nil;
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = @"触摸注入";
            c.detailTextLabel.text = TDhidStatus();
        } else if (ip.row == 1) {
            c.textLabel.text = @"截屏";
            c.detailTextLabel.text = TDcaptureStatus();
        } else if (ip.row == 2) {
            c.textLabel.text = @"沙盒 / 权限";
            c.detailTextLabel.text = TDSandboxStatus();
        } else if (ip.row == 3) {
            c.textLabel.text = @"后台保活";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                                      [TDKeepAlive status],
                                      [TDEngine shared].jetsamStatus ?: @"jetsam 未设置"];
        } else if (ip.row == 4) {
            c.textLabel.text = @"悬浮窗（盖在其他 App 上）";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 76×76 小球（点这里可关闭/回位）", TDHUDStatus()];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 5) {
            c.textLabel.text = @"穿透模式（手动刷抖音时打开）";
            c.detailTextLabel.text = TDHUDPassthrough() ? @"开：悬浮球不接管触摸" : @"关：可拖动悬浮球";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = TDHUDPassthrough();
            [sw addTarget:self action:@selector(togglePassthrough:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else if (ip.row == 6) {
            c.textLabel.text = @"切到抖音自动开始";
            c.detailTextLabel.text = TDAutoStartGet() ? @"开：进入后台即开跑" : @"关：需手动点开始";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = TDAutoStartGet();
            [sw addTarget:self action:@selector(toggleAutoStart:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else {
            c.accessoryView = nil;
            c.textLabel.text = @"随机偏移 / 阈值 / 循环";
            c.detailTextLabel.text = [NSString stringWithFormat:@"±%.0fpt   %.2f   %@",
                                      [TDConfig shared].jitterPx, [TDConfig shared].threshold,
                                      [TDConfig shared].loopCount == 0 ? @"无限" : [NSString stringWithFormat:@"%ld次", (long)[TDConfig shared].loopCount]];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return c;
    }

    if (ip.section == 1) {
        NSDictionary *st = [TDConfig shared].steps[ip.row];
        c.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)ip.row + 1, [self stepTitle:st]];
        c.detailTextLabel.text = @"左滑删除";
        return c;
    }

    c.textLabel.text = @[@"＋ 点击（取点）", @"＋ 长按（长按取点）", @"＋ 滑动（拖一条线）", @"＋ 识图点击（框选目标）"][ip.row];
    c.detailTextLabel.text = @"";
    return c;
}

- (void)togglePassthrough:(UISwitch *)sw {
    TDHUDSetPassthrough(sw.isOn);
    [[TDEngine shared] logMsg:@"穿透模式：%@", sw.isOn ? @"开" : @"关"];
    [_tv reloadData];
}

- (void)toggleAutoStart:(UISwitch *)sw {
    TDAutoStartSet(sw.isOn);
    [[TDEngine shared] logMsg:@"切后台自动开始：%@", sw.isOn ? @"开" : @"关"];
    [_tv reloadData];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 7) { [self editSettings]; return; }
    if (ip.section == 0 && ip.row == 4) { [self floatActions]; return; }
    if (ip.section != 2) return;

    TDPickerMode mode = (ip.row == 0) ? TDPickerTap : (ip.row == 1) ? TDPickerLong : (ip.row == 2) ? TDPickerSwipe : TDPickerRect;

    UIImage *shot = TDscreenshot();
    if (!shot) {
        [[TDEngine shared] logMsg:@"截屏失败：%@", TDcaptureStatus()];
        return;
    }

    TDPickerVC *p = [TDPickerVC new];
    p.mode = mode;
    p.image = shot;

    __weak typeof(self) weakSelf = self;
    p.onTapPoint = ^(CGPoint pt) {
        [[TDConfig shared] addStep:@{@"t": @"tap", @"x": @(pt.x), @"y": @(pt.y)}];
        [weakSelf reload];
    };
    p.onLongPoint = ^(CGPoint pt) {
        [[TDConfig shared] addStep:@{@"t": @"long", @"x": @(pt.x), @"y": @(pt.y), @"ms": @800}];
        [weakSelf reload];
    };
    p.onSwipe = ^(CGPoint a, CGPoint b, NSTimeInterval dur) {
        [[TDConfig shared] addStep:@{@"t": @"swipe", @"x1": @(a.x), @"y1": @(a.y),
                                    @"x2": @(b.x), @"y2": @(b.y), @"ms": @(dur * 1000)}];
        [weakSelf reload];
    };
    p.onRect = ^(CGRect px) {
        [weakSelf saveTemplateFromImage:shot rect:px];
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:p];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)saveTemplateFromImage:(UIImage *)img rect:(CGRect)px {
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, px);
    if (!cg) { [[TDEngine shared] logMsg:@"截图裁剪失败"]; return; }
    UIImage *crop = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);

    NSData *png = UIImagePNGRepresentation(crop);
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSInteger idx = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"tpl_%ld.png", (long)idx]]]) idx++;
    NSString *name = [NSString stringWithFormat:@"tpl_%ld.png", (long)idx];
    [png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];

    [[TDConfig shared] addStep:@{@"t": @"find", @"tpl": name, @"th": @([TDConfig shared].threshold)}];
    [[TDEngine shared] logMsg:@"模板已保存 %@  %.0fx%.0f", name, crop.size.width, crop.size.height];
    [self reload];
}

/// 悬浮球管理：万一球卡在屏幕上了，回 TapDog 点这里就能关掉或复位
- (void)floatActions {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"悬浮球"
                                                              message:TDHUDStatus()
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    BOOL visible = (gTDOverlayWindow && !gTDOverlayWindow.hidden);

    [a addAction:[UIAlertAction actionWithTitle:(visible ? @"关闭悬浮球" : @"打开悬浮球")
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        if (!gTDOverlayWindow) return;
        if (visible) {
            gTDOverlayWindow.hidden = YES;
            TDHUDUnregisterWindow(gTDOverlayWindow);
            [[TDEngine shared] logMsg:@"悬浮球已关闭"];
        } else {
            gTDOverlayWindow.hidden = NO;
            TDApplyBallPosition(gTDOverlayWindow);
            [[TDEngine shared] logMsg:@"悬浮球：%@", TDHUDStatus()];
        }
        [self reload];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"回到默认位置（右侧中部）"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTDBallPosX];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kTDBallPosY];
        TDApplyBallPosition(gTDOverlayWindow);
        [self reload];
    }]];

    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 上 actionSheet 必须有锚点；这里给个兜底，避免崩溃
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)editSettings {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"参数" message:@"随机偏移防检测 / 识图阈值 / 循环次数(0=无限)" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"偏移(点)"; t.text = @([TDConfig shared].jitterPx).stringValue; t.keyboardType = UIKeyboardTypeDecimalPad; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"阈值0.5~0.99"; t.text = @([TDConfig shared].threshold).stringValue; t.keyboardType = UIKeyboardTypeDecimalPad; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"循环(0无限)"; t.text = @([TDConfig shared].loopCount).stringValue; t.keyboardType = UIKeyboardTypeNumberPad; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [TDConfig shared].jitterPx = [a.textFields[0].text doubleValue];
        [TDConfig shared].threshold = [a.textFields[1].text doubleValue];
        [TDConfig shared].loopCount = [a.textFields[2].text integerValue];
        [[TDConfig shared] save];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)reload {
    [_tv reloadData];
    [self refreshRunBtn];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 1; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete && ip.section == 1) {
        [[TDConfig shared] removeStepAtIndex:ip.row];
        [tv reloadData];
    }
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    if (from.section == 1 && to.section == 1) {
        [[TDConfig shared] moveStepFrom:from.row to:to.row];
    }
}

@end

#pragma mark - 悬浮球
//
//  ★ 关键设计（v1.0.16 修正）★
//  托管窗口必须是「球那么大」，绝不能铺满全屏。
//  原因：跨进程托管窗口的触摸命中在窗口服务器侧完成，我们进程里的
//  hitTest 返回 nil 只是让本进程没人接这个触摸 —— 触摸会被这个窗口
//  「接住后丢弃」，并不会转发给下面抖音的窗口。所以窗口铺满全屏 =
//  整个屏幕都点不动。窗口只有 76×76，则窗口外的触摸压根不归它管，
//  抖音正常操作，只有球那一小块被占用（可拖动挪开）。
//

@interface TDFloatVC : UIViewController
@property (nonatomic, copy) void (^onTap)(void);
- (void)setRunning:(BOOL)run;
@end

@implementation TDFloatVC {
    UIView *_ball;
    UILabel *_label;
    CGPoint _dragStartCenter;   // 拖动开始时窗口中心（屏幕坐标）
    CGPoint _dragStartTouch;    // 拖动开始时手指位置（屏幕坐标，与窗口无关）
}

- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kTDOverlaySide, kTDOverlaySide)];
    v.backgroundColor = [UIColor clearColor];
    v.clipsToBounds = NO;
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _ball = [[UIView alloc] initWithFrame:CGRectMake(kTDBallPad, kTDBallPad, kTDBallSize, kTDBallSize)];
    _ball.backgroundColor = [UIColor colorWithRed:0.18 green:0.33 blue:0.98 alpha:0.92];
    _ball.layer.cornerRadius = kTDBallSize / 2;
    _ball.layer.borderWidth = 2;
    _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    _ball.userInteractionEnabled = YES;
    [self.view addSubview:_ball];

    _label = [[UILabel alloc] initWithFrame:_ball.bounds];
    _label.text = @"跑";
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont boldSystemFontOfSize:22];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.userInteractionEnabled = NO;
    [_ball addSubview:_label];

    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapBall)];
    [_ball addGestureRecognizer:t];
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    [_ball addGestureRecognizer:p];
    [t requireGestureRecognizerToFail:p];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _ball.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

- (void)tapBall { if (self.onTap) self.onTap(); }

/// 取「不随窗口移动而变化的屏幕坐标」，否则窗口一挪 translation 就被抵消，球会原地抖
- (CGPoint)screenPointOf:(CGPoint)p inWindow:(UIWindow *)w {
    if (w.windowScene) return [w convertPoint:p toCoordinateSpace:w.windowScene.coordinateSpace];
    return p;
}

- (void)dragBall:(UIPanGestureRecognizer *)g {
    UIWindow *w = self.view.window;
    if (!w) return;
    CGPoint touch = [self screenPointOf:[g locationInView:w] inWindow:w];

    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStartCenter = w.center;
        _dragStartTouch  = touch;
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
        TDHUDRegisterWindow(w);   // 几何变了，重挂一次更稳
    }
}

- (void)setRunning:(BOOL)run {
    _label.text = run ? @"停" : @"跑";
    _ball.backgroundColor = run ? [UIColor colorWithRed:0.85 green:0.24 blue:0.24 alpha:0.92]
                                : [UIColor colorWithRed:0.18 green:0.33 blue:0.98 alpha:0.92];
}

@end

#pragma mark - AppDelegate

@interface TDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) TDHUDWindow *floatWindow;
@property (nonatomic, strong) TDFloatVC *floatVC;
@end

@implementation TDAppDelegate {
    BOOL _autoStarted;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    TDMainVC *root = [TDMainVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 悬浮球：TDHUDWindow 是「系统窗口」，配合 SBSAccessibilityWindowHostingController
    // 把 context 托管给 SpringBoard 渲染，所以切到抖音后依然浮在最上层、还能拖、还能点。
    // ★ 窗口只做 76×76（球那么大），铺满全屏会吞掉整块屏幕的触摸（抖音全点不动）。
    TDHUDWindow *fw = [[TDHUDWindow alloc] initWithFrame:CGRectMake(0, 0, kTDOverlaySide, kTDOverlaySide)];
    fw.windowLevel = 10000010.0;          // 高于状态栏/键盘/系统弹窗
    fw.backgroundColor = [UIColor clearColor];
    fw.rootViewController = [TDFloatVC new];
    self.floatWindow = fw;
    self.floatVC = (TDFloatVC *)fw.rootViewController;
    gTDOverlayWindow = fw;
    TDApplyBallPosition(fw);              // 恢复上次拖动的位置
    __weak typeof(self) ws = self;
    self.floatVC.onTap = ^{
        TDEngine *e = [TDEngine shared];
        if (e.running) [e stop]; else [e startWithScript:@{}];
        [ws.floatVC setRunning:e.running];
    };

    // 挂到当前 scene 上才会有 CGS context
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { fw.windowScene = (UIWindowScene *)s; break; }
    }
    fw.hidden = NO;

    [self registerOverlayWithRetry:0];

    // 回到前台 / scene 重新激活时 context 可能变了，重挂一次
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneReactivated)
                                                 name:UISceneDidActivateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sceneReactivated)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    // 进入后台后再确认一次托管关系，防止被系统悄悄摘掉
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [TDKeepAlive start];
    [TDEngine shared].jetsamStatus = TDBypassJetsam();

    BOOL ok = TDHUDRegisterWindow(fw);
    [[TDEngine shared] logMsg:@"悬浮窗: %@", ok ? TDHUDStatus() : @"等待窗口就绪…"];
    return YES;
}

/// 窗口的 context 是异步建出来的，前几帧拿不到，需要重试几次
- (void)registerOverlayWithRetry:(NSInteger)n {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * n * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) ss = ws;
        if (!ss.floatWindow) return;
        if (TDHUDRegisterWindow(ss.floatWindow)) {
            [[TDEngine shared] logMsg:@"悬浮窗: %@", TDHUDStatus()];
            return;
        }
        // 兜底：某些情况下只有 makeKeyAndVisible 才会真正建出 CGS context
        if (n == 2) {
            [ss.floatWindow makeKeyAndVisible];
            [ss.window makeKeyWindow];
            if (TDHUDRegisterWindow(ss.floatWindow)) {
                [[TDEngine shared] logMsg:@"悬浮窗: %@（makeKey 兜底）", TDHUDStatus()];
                return;
            }
        }
        if (n < 8) [ss registerOverlayWithRetry:n + 1];
        else [[TDEngine shared] logMsg:@"悬浮窗: 托管失败 %@", TDHUDStatus()];
    });
}

- (void)sceneReactivated {
    // 回到 TapDog 就停手，免得在自己界面上乱点
    if (_autoStarted) {
        _autoStarted = NO;
        [[TDEngine shared] stop];
        [[TDEngine shared] logMsg:@"回到前台，已自动停止"];
    }
    if (self.floatWindow) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TDHUDRegisterWindow(self.floatWindow);
        });
    }
}

- (void)appDidBackground {
    // 进后台时窗口会被 UIKit 藏起来，这里重新托管一次，让 SpringBoard 继续画
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.floatWindow) return;
        self.floatWindow.hidden = NO;
        // 兜底：万一窗口被谁改成全屏，立刻缩回小球大小，否则抖音整个屏幕都点不动
        if (self.floatWindow.frame.size.width > kTDOverlaySide + 1 ||
            self.floatWindow.frame.size.height > kTDOverlaySide + 1) {
            TDApplyBallPosition(self.floatWindow);
        } else {
            TDHUDRegisterWindow(self.floatWindow);
        }

        if (TDAutoStartGet() && [TDConfig shared].steps.count > 0 && ![TDEngine shared].running) {
            self->_autoStarted = YES;
            [[TDEngine shared] startWithScript:@{}];
        }
        [[TDEngine shared] logMsg:@"后台：保活 %@ | 悬浮窗 %@", [TDKeepAlive status], TDHUDStatus()];
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TDAppDelegate class]));
    }
}
