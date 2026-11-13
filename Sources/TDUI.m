#import "TD.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 后台保活：UIBackgroundModes=audio + 循环播放静音，切到抖音后进程不被挂起
// ---------------------------------------------------------------------------
@interface TDKeepAlive : NSObject
+ (void)start;
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

- (void)begin {
    if (_player) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:NULL];
    [s setActive:YES error:NULL];

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
    _player.volume = 0.0;
    [_player play];
}
@end

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
}

- (void)toggleRun {
    TDEngine *e = [TDEngine shared];
    if (e.running) { [e stop]; }
    else { [e startWithScript:@{}]; }
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
    if (s == 0) return 3;
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
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = @"触摸注入";
            c.detailTextLabel.text = TDhidStatus();
        } else if (ip.row == 1) {
            c.textLabel.text = @"截屏";
            c.detailTextLabel.text = TDcaptureStatus();
        } else {
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

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 2) { [self editSettings]; return; }
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

@interface TDFloatVC : UIViewController
@property (nonatomic, copy) void (^onTap)(void);
- (void)setRunning:(BOOL)run;
@end

@implementation TDFloatVC {
    UIView *_ball;
    UILabel *_label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    _ball.backgroundColor = [UIColor colorWithRed:0.18 green:0.33 blue:0.98 alpha:0.92];
    _ball.layer.cornerRadius = 28;
    _ball.layer.borderWidth = 2;
    _ball.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    _ball.userInteractionEnabled = YES;
    [self.view addSubview:_ball];

    _label = [[UILabel alloc] initWithFrame:_ball.bounds];
    _label.text = @"跑";
    _label.textColor = [UIColor whiteColor];
    _label.font = [UIFont boldSystemFontOfSize:22];
    _label.textAlignment = NSTextAlignmentCenter;
    [_ball addSubview:_label];

    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapBall)];
    [_ball addGestureRecognizer:t];
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    [_ball addGestureRecognizer:p];
}

- (void)tapBall { if (self.onTap) self.onTap(); }

- (void)dragBall:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self.view];
    CGPoint c = CGPointMake(_ball.center.x + d.x, _ball.center.y + d.y);
    _ball.center = c;
    [g setTranslation:CGPointZero inView:self.view];
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
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) TDFloatVC *floatVC;
@end

@implementation TDAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    TDMainVC *root = [TDMainVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    // 悬浮球：entitlement com.apple.springboard.accessibility-window-hosting
    // 让它能盖在别的 App 上面
    CGRect b = [UIScreen mainScreen].bounds;
    self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(b.size.width - 76, b.size.height * 0.5, 56, 56)];
    self.floatWindow.windowLevel = 10000000;
    self.floatWindow.backgroundColor = [UIColor clearColor];
    self.floatWindow.rootViewController = [TDFloatVC new];
    self.floatVC = (TDFloatVC *)self.floatWindow.rootViewController;
    __weak typeof(self) ws = self;
    self.floatVC.onTap = ^{
        TDEngine *e = [TDEngine shared];
        if (e.running) [e stop]; else [e startWithScript:@{}];
        [ws.floatVC setRunning:e.running];
    };
    self.floatWindow.hidden = NO;

    [TDKeepAlive start];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TDAppDelegate class]));
    }
}
