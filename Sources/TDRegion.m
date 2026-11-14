#import "TD.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 框选「识别区域」
//
// 底图优先用回放时抓到的那一帧（TDLastTargetShot）：编辑页在前台时截屏只能截到
// 我们自己的界面，拿它当底图框出来的坐标是错的 —— 框选必须对着抖音的画面才有意义。
// 没有底图就画一张等屏幕比例的空白画布，让人凭位置感框，再用手动输入微调。
//
// 全程以**屏幕点**为准：底图是像素图（1080×1920），手指拖的是视图坐标，
// 中间要过两次换算，最后存进步骤里的永远是点 —— 和 x/y 坐标同一套量纲。
// ---------------------------------------------------------------------------

typedef void (^TDRegionDone)(CGRect roi, BOOL ok);

@interface TDRegionVC : UIViewController
@property (nonatomic, strong) UIImage *shot;
@property (nonatomic) CGRect initialRoi;      // 屏幕点；CGRectNull = 还没框
@property (nonatomic, copy) TDRegionDone onDone;
@end

static TDRegionVC *gRegionVC = nil;           // 防止被提前释放

@implementation TDRegionVC {
    UIImageView *_iv;
    UIView *_dim;                             // 压暗层，中间挖一个洞
    CAShapeLayer *_hole;
    UIView *_sel;                             // 框的边框
    UILabel *_size;                           // 框的尺寸
    UILabel *_tip;
    UIButton *_fullBtn;
    CGRect _imgRect;                          // 底图在视图里的实际矩形
    CGRect _rect;                             // 当前框（视图坐标）
    CGPoint _start;
    BOOL _drawing;
    BOOL _hasRect;
    CGSize _canvas;                           // 底图尺寸；没有底图时 = 屏幕点尺寸
    CGFloat _ratio;                           // 底图单位 → 屏幕点
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"框选识别区域";

    _canvas = _shot ? _shot.size : [UIScreen mainScreen].bounds.size;
    if (_canvas.width < 1) _canvas = CGSizeMake(414, 736);
    // 有底图：屏幕点 = 像素 × 换算比；没底图：画布本身就是点
    _ratio = _shot ? TDLastTargetShotRatio() : 1.0;
    if (!(_ratio > 0)) _ratio = 1.0;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onCancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"确定" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave)];

    _iv = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iv.contentMode = UIViewContentModeScaleAspectFit;
    _iv.image = _shot;
    _iv.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    _iv.userInteractionEnabled = NO;
    _iv.clipsToBounds = YES;
    [self.view addSubview:_iv];

    _dim = [[UIView alloc] initWithFrame:CGRectZero];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.52];
    _dim.userInteractionEnabled = NO;
    [self.view addSubview:_dim];

    _hole = [CAShapeLayer layer];
    _hole.fillRule = kCAFillRuleEvenOdd;
    _hole.fillColor = UIColor.blackColor.CGColor;
    _dim.layer.mask = _hole;

    _sel = [[UIView alloc] initWithFrame:CGRectZero];
    _sel.backgroundColor = [UIColor colorWithRed:0.235 green:0.749 blue:0.478 alpha:0.10];
    _sel.layer.borderColor = [UIColor colorWithRed:0.235 green:0.749 blue:0.478 alpha:1].CGColor;
    _sel.layer.borderWidth = 1.5;
    _sel.hidden = YES;
    _sel.userInteractionEnabled = NO;
    [self.view addSubview:_sel];

    _size = [[UILabel alloc] initWithFrame:CGRectZero];
    _size.textColor = UIColor.whiteColor;
    _size.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _size.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
    _size.textAlignment = NSTextAlignmentCenter;
    _size.layer.cornerRadius = 4;
    _size.clipsToBounds = YES;
    _size.hidden = YES;
    [self.view addSubview:_size];

    _tip = [[UILabel alloc] initWithFrame:CGRectZero];
    _tip.textColor = [UIColor colorWithWhite:1 alpha:0.66];
    _tip.font = [UIFont systemFontOfSize:12.5];
    _tip.textAlignment = NSTextAlignmentCenter;
    _tip.numberOfLines = 3;
    _tip.text = _shot
        ? @"在画面上拖动，框住「只在这里找」的范围。\n框内找不到才会走兜底；再拖一次可以重画。\n判定按「模板中心落在框内」，框比图标小也能用"
        : @"还没有抖音的画面。先回放一次脚本，再来框选最准。\n现在看到的是按屏幕比例画的空白画布，可以拖，但只能凭位置感。";
    [self.view addSubview:_tip];

    _fullBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_fullBtn setTitle:@"全屏（不限区域）" forState:UIControlStateNormal];
    _fullBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [_fullBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.92] forState:UIControlStateNormal];
    _fullBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    _fullBtn.layer.borderWidth = 1;
    _fullBtn.layer.cornerRadius = 8;
    [_fullBtn addTarget:self action:@selector(onFull) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_fullBtn];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.view addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat sb = self.view.safeAreaInsets.bottom;
    CGFloat bar = 132 + sb;                       // 底部控制区

    _iv.frame = CGRectMake(0, 0, W, H - bar);
    _dim.frame = self.view.bounds;

    _tip.frame = CGRectMake(16, H - bar + 6, W - 32, 52);
    _fullBtn.frame = CGRectMake((W - 190) / 2.0, H - sb - 46, 190, 36);

    [self updateImgRect];
    if (!_hasRect && !CGRectIsNull(_initialRoi) && !CGRectIsEmpty(_initialRoi)) {
        CGRect r = [self viewRectFromRoi:_initialRoi];
        if (!CGRectIsNull(r) && r.size.width >= 6 && r.size.height >= 6) {
            _rect = r;
            _hasRect = YES;
        }
    }
    [self refreshShape];
}

- (void)updateImgRect {
    CGSize cs = _canvas;
    CGRect area = _iv.bounds;
    if (cs.width < 1 || cs.height < 1 || area.size.width < 1) { _imgRect = CGRectZero; return; }
    CGFloat k = MIN(area.size.width / cs.width, area.size.height / cs.height);
    CGFloat w = cs.width * k, h = cs.height * k;
    _imgRect = CGRectMake(area.origin.x + (area.size.width - w) / 2.0,
                          area.origin.y + (area.size.height - h) / 2.0, w, h);
}

#pragma mark - 坐标换算

/// 视图矩形 → 屏幕点矩形
- (CGRect)roiFromViewRect:(CGRect)r {
    if (_imgRect.size.width < 1 || _imgRect.size.height < 1) return CGRectNull;
    CGFloat k = _canvas.width / _imgRect.size.width;      // 视图 → 底图单位
    CGRect c = CGRectMake((r.origin.x - _imgRect.origin.x) * k,
                          (r.origin.y - _imgRect.origin.y) * k,
                          r.size.width * k, r.size.height * k);
    CGRect s = CGRectMake(c.origin.x * _ratio, c.origin.y * _ratio,
                          c.size.width * _ratio, c.size.height * _ratio);

    CGSize scr = [UIScreen mainScreen].bounds.size;
    s = CGRectIntersection(s, CGRectMake(0, 0, scr.width, scr.height));
    if (CGRectIsNull(s) || s.size.width < 2 || s.size.height < 2) return CGRectNull;
    return CGRectIntegral(s);
}

/// 屏幕点矩形 → 视图矩形
- (CGRect)viewRectFromRoi:(CGRect)roi {
    if (_imgRect.size.width < 1) return CGRectNull;
    CGFloat k = _imgRect.size.width / _canvas.width;      // 底图单位 → 视图
    return CGRectMake(_imgRect.origin.x + roi.origin.x / _ratio * k,
                      _imgRect.origin.y + roi.origin.y / _ratio * k,
                      roi.size.width / _ratio * k,
                      roi.size.height / _ratio * k);
}

#pragma mark - 手势

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    // 手指落在底部控制区上：不算画框
    if (g.state == UIGestureRecognizerStateBegan && !CGRectContainsPoint(_iv.frame, p)) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        _start = p;
        _drawing = YES;
        _rect = CGRectMake(p.x, p.y, 0, 0);
        _hasRect = NO;
        _sel.hidden = NO;
        _size.hidden = NO;
    } else if (g.state == UIGestureRecognizerStateChanged && _drawing) {
        _rect = CGRectMake(MIN(_start.x, p.x), MIN(_start.y, p.y),
                           fabs(p.x - _start.x), fabs(p.y - _start.y));
        if (_rect.size.width > 4 && _rect.size.height > 4) _hasRect = YES;
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        _drawing = NO;
        if (_rect.size.width < 8 || _rect.size.height < 8) {
            _hasRect = NO;
            _sel.hidden = YES;
            _size.hidden = YES;
        }
    } else {
        return;
    }
    [self refreshShape];
}

- (void)refreshShape {
    _sel.frame = _rect;

    UIBezierPath *path = [UIBezierPath bezierPathWithRect:_dim.bounds];
    if (_hasRect) [path appendPath:[UIBezierPath bezierPathWithRect:_rect]];
    _hole.path = path.CGPath;

    if (!_hasRect) { _size.hidden = YES; return; }

    CGRect roi = [self roiFromViewRect:_rect];
    if (CGRectIsNull(roi)) { _size.text = @"框太小"; }
    else {
        CGSize scr = [UIScreen mainScreen].bounds.size;
        _size.text = [NSString stringWithFormat:@"%@（占屏 %.0f%%）",
                      TDRegionDesc(roi),
                      roi.size.width * roi.size.height / MAX(1.0, scr.width * scr.height) * 100.0];
    }
    _size.hidden = NO;
    CGSize fit = [_size sizeThatFits:CGSizeMake(self.view.bounds.size.width - 24, 20)];
    CGFloat w = MAX(120, fit.width + 16);
    _size.frame = CGRectMake(MAX(8, MIN(self.view.bounds.size.width - w - 8,
                                        _rect.origin.x + (_rect.size.width - w) / 2.0)),
                             MAX(4, _rect.origin.y - 24), w, 20);
}

#pragma mark - 按钮

- (void)onCancel {
    void (^cb)(CGRect, BOOL) = self.onDone;
    self.onDone = nil;
    gRegionVC = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(CGRectNull, NO); }];
}

- (void)onFull {
    void (^cb)(CGRect, BOOL) = self.onDone;
    self.onDone = nil;
    gRegionVC = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(CGRectNull, YES); }];
}

- (void)onSave {
    CGRect roi = _hasRect ? [self roiFromViewRect:_rect] : CGRectNull;
    if (CGRectIsNull(roi)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没框好"
                                                                  message:@"在画面上拖一个框出来，或者点「全屏」不限制区域"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    void (^cb)(CGRect, BOOL) = self.onDone;
    self.onDone = nil;
    gRegionVC = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(roi, YES); }];
}

@end

#pragma mark - 对外

NSString *TDRegionDesc(CGRect roi) {
    if (CGRectIsNull(roi) || roi.size.width < 2 || roi.size.height < 2) return @"全屏";
    return [NSString stringWithFormat:@"%.0f,%.0f · %.0f×%.0f",
            roi.origin.x, roi.origin.y, roi.size.width, roi.size.height];
}

void TDPickRegion(UIViewController *host, UIImage *shot, CGRect initial,
                  void (^done)(CGRect roi, BOOL ok)) {
    if (!host) { if (done) done(CGRectNull, NO); return; }
    TDRegionVC *vc = [TDRegionVC new];
    vc.shot = shot;
    vc.initialRoi = initial;
    vc.onDone = done;
    gRegionVC = vc;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:nav animated:YES completion:nil];
}
