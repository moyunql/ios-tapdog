#import "TD.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// ---------------------------------------------------------------------------
// 脚本编辑器（混合模式）
//
// 一条脚本 = 一个任务，里面是一串事件。打开就能看到全部事件列表，
// 每一行点进去都能改：坐标 / 识图、长按时长、间隔，以及**这一步的随机化**。
//
// 为什么要「每一步单独随机」：全局那一个偏移半径对付不了真实场景 ——
// 有的按钮点偏 3pt 就点空，有的一整块区域可以撒开 20pt；
// 压力、半径、时长同理。所以随机是按步骤配的：
//   随机率 p  —— 这一步有多大比例「这一次」要变（0 就是永远不变）
//   随机度    —— 变多少：位置半径 / 压力范围 / 半径范围 / 时长抖动 / 间隔抖动
//
// 识图步骤的模板是这个页面上「截一屏 → 拉个框 → 存成 png」拿到的，
// 存 Documents 下，文件名 tpl_xxx.png，回放时由引擎按名字取。
// ---------------------------------------------------------------------------

#define ED_BG     [UIColor colorWithRed:0.043 green:0.067 blue:0.086 alpha:1]
#define ED_CARD   [UIColor colorWithRed:0.078 green:0.110 blue:0.145 alpha:1]
#define ED_LINE   [UIColor colorWithRed:0.125 green:0.169 blue:0.212 alpha:1]
#define ED_TEXT   [UIColor colorWithRed:0.910 green:0.937 blue:0.961 alpha:1]
#define ED_DIM    [UIColor colorWithRed:0.545 green:0.627 blue:0.694 alpha:1]
#define ED_ACCENT [UIColor colorWithRed:0.231 green:0.541 blue:0.980 alpha:1]
#define ED_GREEN  [UIColor colorWithRed:0.235 green:0.749 blue:0.478 alpha:1]
#define ED_RED    [UIColor colorWithRed:0.902 green:0.263 blue:0.263 alpha:1]
#define ED_YELL   [UIColor colorWithRed:0.960 green:0.710 blue:0.290 alpha:1]

#pragma mark - 模板库

static NSString *TDDocsDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return d ?: NSTemporaryDirectory();
}

static NSString *TDTplPath(NSString *name) {
    return [TDDocsDir() stringByAppendingPathComponent:name ?: @""];
}

static NSArray<NSString *> *TDTemplateList(void) {
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:TDDocsDir() error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in all ?: @[]) {
        if ([n hasPrefix:@"tpl_"] && [[n pathExtension].lowercaseString isEqualToString:@"png"]) {
            [out addObject:n];
        }
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

/// tpl_1699880000.png → 尾 6 位，够区分又不占地方
static NSString *TDTplDisplay(NSString *file) {
    if (file.length < 4) return file ?: @"";
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasPrefix:@"tpl_"]) s = [s substringFromIndex:4];
    if (s.length > 6) s = [s substringFromIndex:s.length - 6];
    return s;
}

#pragma mark - 截屏拉框

@interface TDCropVC : UIViewController
@property (nonatomic, strong) UIImage *shot;
@property (nonatomic, copy) void (^onDone)(NSString *tplName);
@end

@implementation TDCropVC {
    UIImageView *_iv;
    UIView *_sel;
    UILabel *_sizeLabel;
    UILabel *_tip;
    CGRect _imgRect;
    CGPoint _start;
    CGRect _rect;
    BOOL _drawing;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"框选要识别的画面";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onCancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave)];

    _iv = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iv.contentMode = UIViewContentModeScaleAspectFit;
    _iv.image = _shot;
    _iv.userInteractionEnabled = NO;
    [self.view addSubview:_iv];

    _sel = [[UIView alloc] initWithFrame:CGRectZero];
    _sel.backgroundColor = [UIColor colorWithRed:0.235 green:0.749 blue:0.478 alpha:0.18];
    _sel.layer.borderColor = ED_GREEN.CGColor;
    _sel.layer.borderWidth = 1.5;
    _sel.hidden = YES;
    [self.view addSubview:_sel];

    _sizeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sizeLabel.textColor = UIColor.whiteColor;
    _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _sizeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _sizeLabel.textAlignment = NSTextAlignmentCenter;
    _sizeLabel.hidden = YES;
    [self.view addSubview:_sizeLabel];

    _tip = [[UILabel alloc] initWithFrame:CGRectZero];
    _tip.text = @"在画面上按住拖动，框住要认的那个图案（越小越准）";
    _tip.textColor = ED_DIM;
    _tip.font = [UIFont systemFontOfSize:13];
    _tip.textAlignment = NSTextAlignmentCenter;
    _tip.numberOfLines = 2;
    [self.view addSubview:_tip];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.view addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _iv.frame = self.view.bounds;
    _tip.frame = CGRectMake(20, self.view.bounds.size.height - 70,
                            self.view.bounds.size.width - 40, 44);
    [self updateImgRect];
}

- (void)updateImgRect {
    if (!_shot) return;
    CGSize ss = _shot.size;
    CGSize vs = self.view.bounds.size;
    if (ss.width < 1 || ss.height < 1) return;
    CGFloat k = MIN(vs.width / ss.width, vs.height / ss.height);
    CGFloat w = ss.width * k, h = ss.height * k;
    _imgRect = CGRectMake((vs.width - w) / 2.0, (vs.height - h) / 2.0, w, h);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _start = p;
        _drawing = YES;
        _rect = CGRectMake(p.x, p.y, 0, 0);
        _sel.hidden = NO;
        _sizeLabel.hidden = NO;
        _tip.hidden = YES;
    } else if (g.state == UIGestureRecognizerStateChanged && _drawing) {
        _rect = CGRectMake(MIN(_start.x, p.x), MIN(_start.y, p.y),
                           fabs(p.x - _start.x), fabs(p.y - _start.y));
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _drawing = NO;
    } else {
        return;
    }

    _sel.frame = _rect;
    CGSize px = [self pixelSize];
    _sizeLabel.text = [NSString stringWithFormat:@"%.0f × %.0f px", px.width, px.height];
    _sizeLabel.frame = CGRectMake(_rect.origin.x, MAX(0, _rect.origin.y - 22), MAX(90, _rect.size.width), 20);
}

/// 当前框选区域换算成图片像素尺寸
- (CGSize)pixelSize {
    if (_imgRect.size.width < 1) return CGSizeZero;
    CGFloat k = _shot.size.width / _imgRect.size.width;
    return CGSizeMake(_rect.size.width * k, _rect.size.height * k);
}

- (void)onCancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSave {
    if (!_shot) { [self alert:@"截屏是空的"]; return; }
    CGRect r = _rect;
    if (r.size.width < 8 || r.size.height < 8) { [self alert:@"框太小了，重新拉一下"]; return; }

    CGFloat k = _shot.size.width / MAX(1.0, _imgRect.size.width);
    CGRect pr = CGRectMake((r.origin.x - _imgRect.origin.x) * k,
                           (r.origin.y - _imgRect.origin.y) * k,
                           r.size.width * k, r.size.height * k);
    pr = CGRectIntegral(pr);
    CGRect imgBounds = CGRectMake(0, 0, _shot.size.width, _shot.size.height);
    pr = CGRectIntersection(pr, imgBounds);
    if (pr.size.width < 6 || pr.size.height < 6) { [self alert:@"框到画面外面了"]; return; }

    CGImageRef sub = CGImageCreateWithImageInRect(_shot.CGImage, pr);
    if (!sub) { [self alert:@"裁剪失败"]; return; }
    UIImage *crop = [UIImage imageWithCGImage:sub scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(sub);

    NSString *name = [NSString stringWithFormat:@"tpl_%lld.png", (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
    NSData *png = UIImagePNGRepresentation(crop);
    if (!png || ![png writeToFile:TDTplPath(name) atomically:YES]) {
        [self alert:@"写模板文件失败"];
        return;
    }

    void (^done)(NSString *) = self.onDone;
    [self dismissViewControllerAnimated:YES completion:^{
        if (done) done(name);
    }];
}

- (void)alert:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:m
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - 单步编辑

typedef NS_ENUM(NSInteger, TDStepKind) { KTap = 0, KLong, KSwipe, KWait };
typedef NS_ENUM(NSInteger, TDRowKind) {
    RKind = 0, RMode, RNum, RTpl, RTest, RPhys, RDelete, RNote
};
typedef NS_ENUM(NSInteger, TDField) {
    F_X = 0, F_Y, F_X1, F_Y1, F_X2, F_Y2, F_MS, F_GAP,
    F_TH, F_DX, F_DY, F_TO,
    F_RP, F_RPX, F_PMIN, F_PMAX, F_RMIN, F_RMAX, F_MSJ, F_GAPJ,
    F_RUN,
    F_COUNT
};

static NSDictionary *RowNum(TDField f, NSString *title, NSString *unit, BOOL dec) {
    return @{@"k": @(RNum), @"f": @(f), @"t": title, @"u": unit ?: @"", @"dec": @(dec)};
}

@interface TDStepEditVC : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithStep:(NSMutableDictionary *)step
                        isNew:(BOOL)isNew
                       onSave:(void (^)(void))onSave
                     onDelete:(void (^)(void))onDelete;
@end

@implementation TDStepEditVC {
    NSMutableDictionary *_d;
    BOOL _isNew;
    void (^_onSave)(void);
    void (^_onDelete)(void);

    TDStepKind _kind;
    BOOL _imgMode;
    NSString *_tpl;
    BOOL _physOn;

    double _v[F_COUNT];
    NSArray<NSArray<NSDictionary *> *> *_plan;
}

- (instancetype)initWithStep:(NSMutableDictionary *)step
                        isNew:(BOOL)isNew
                       onSave:(void (^)(void))onSave
                     onDelete:(void (^)(void))onDelete {
    if (self = [super initWithStyle:UITableViewStyleInsetGrouped]) {
        _d = step;
        _isNew = isNew;
        _onSave = [onSave copy];
        _onDelete = [onDelete copy];
        [self parseStep];
    }
    return self;
}

- (void)parseStep {
    NSString *t = _d[@"t"] ?: @"tap";
    _kind = [t isEqualToString:@"long"] ? KLong
          : [t isEqualToString:@"swipe"] ? KSwipe
          : [t isEqualToString:@"gesture"] ? KSwipe
          : [t isEqualToString:@"wait"] ? KWait
          : KTap;
    _imgMode = [t isEqualToString:@"find"];

    _v[F_X]  = [_d[@"x"] doubleValue];
    _v[F_Y]  = [_d[@"y"] doubleValue];
    _v[F_X1] = [_d[@"x1"] doubleValue];
    _v[F_Y1] = [_d[@"y1"] doubleValue];
    _v[F_X2] = [_d[@"x2"] doubleValue];
    _v[F_Y2] = [_d[@"y2"] doubleValue];
    _v[F_MS] = _d[@"ms"] ? [_d[@"ms"] doubleValue] : (_kind == KWait ? 500 : 0);
    _v[F_GAP] = [_d[@"gap"] doubleValue];

    _tpl = [_d[@"tpl"] isKindOfClass:[NSString class]] ? _d[@"tpl"] : nil;
    _v[F_TH] = _d[@"th"] ? [_d[@"th"] doubleValue] : [TDConfig shared].threshold;
    _v[F_DX] = [_d[@"dx"] doubleValue];
    _v[F_DY] = [_d[@"dy"] doubleValue];
    _v[F_TO] = _d[@"to"] ? [_d[@"to"] doubleValue] : 1500;

    // 没有位置信息的（识图、等待）给个屏幕中心的默认值，方便改
    if (_kind == KTap || _kind == KLong) {
        if (!_d[@"x"] && !_imgMode) {
            CGSize sb = [UIScreen mainScreen].bounds.size;
            _v[F_X] = sb.width / 2.0;
            _v[F_Y] = sb.height * 0.62;
        }
    }
    if (_kind == KSwipe && !_d[@"x1"]) {
        CGSize sb = [UIScreen mainScreen].bounds.size;
        _v[F_X1] = sb.width / 2.0; _v[F_Y1] = sb.height * 0.72;
        _v[F_X2] = sb.width / 2.0; _v[F_Y2] = sb.height * 0.28;
        _v[F_MS] = 400;
    }

    // 随机化：默认全关（随机率 0），要用的人自己拉
    NSDictionary *r = [_d[@"rnd"] isKindOfClass:[NSDictionary class]] ? _d[@"rnd"] : nil;
    _v[F_RP]   = r[@"p"] ? [r[@"p"] doubleValue] : 0.0;
    _v[F_RPX]  = r[@"px"] ? [r[@"px"] doubleValue] : 8.0;
    _v[F_MSJ]  = r[@"ms"] ? [r[@"ms"] doubleValue] : 0.25;
    _v[F_GAPJ] = r[@"gap"] ? [r[@"gap"] doubleValue] : 0.35;
    _v[F_RUN]  = _d[@"run"] ? [_d[@"run"] doubleValue] : 1.0;

    NSArray *pr = [r[@"pr"] isKindOfClass:[NSArray class]] ? r[@"pr"] : nil;
    NSArray *rd = [r[@"rd"] isKindOfClass:[NSArray class]] ? r[@"rd"] : nil;
    _physOn = (pr.count >= 2 || rd.count >= 2);
    _v[F_PMIN] = pr.count >= 2 ? [pr[0] doubleValue] : 0.35;
    _v[F_PMAX] = pr.count >= 2 ? [pr[1] doubleValue] : 0.90;
    _v[F_RMIN] = rd.count >= 2 ? [rd[0] doubleValue] : 0.20;
    _v[F_RMAX] = rd.count >= 2 ? [rd[1] doubleValue] : 0.90;

    [self rebuildPlan];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _isNew ? @"新增事件" : @"编辑事件";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.separatorColor = ED_LINE;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onCancel)];
    self.navigationController.navigationBar.tintColor = ED_GREEN;
    [self.tableView reloadData];
}

- (void)rebuildPlan {
    NSMutableArray *sec0 = [NSMutableArray array];
    [sec0 addObject:@{@"k": @(RKind)}];
    if (_kind == KTap || _kind == KLong) [sec0 addObject:@{@"k": @(RMode)}];

    NSMutableArray *sec1 = [NSMutableArray array];
    if (_imgMode) {
        [sec1 addObject:@{@"k": @(RTpl)}];
        [sec1 addObject:RowNum(F_TH, @"相似度阈值", @"0~1", YES)];
        [sec1 addObject:RowNum(F_DX, @"落点偏移 X", @"点", NO)];
        [sec1 addObject:RowNum(F_DY, @"落点偏移 Y", @"点", NO)];
        [sec1 addObject:RowNum(F_TO, @"找不到时等", @"毫秒", NO)];
        if (_kind == KLong) [sec1 addObject:RowNum(F_MS, @"长按时长", @"毫秒", NO)];
        [sec1 addObject:@{@"k": @(RTest)}];
    } else {
        switch (_kind) {
            case KTap:
                [sec1 addObject:RowNum(F_X, @"X", @"点", NO)];
                [sec1 addObject:RowNum(F_Y, @"Y", @"点", NO)];
                break;
            case KLong:
                [sec1 addObject:RowNum(F_X, @"X", @"点", NO)];
                [sec1 addObject:RowNum(F_Y, @"Y", @"点", NO)];
                [sec1 addObject:RowNum(F_MS, @"长按时长", @"毫秒", NO)];
                break;
            case KSwipe:
                [sec1 addObject:RowNum(F_X1, @"起点 X", @"点", NO)];
                [sec1 addObject:RowNum(F_Y1, @"起点 Y", @"点", NO)];
                [sec1 addObject:RowNum(F_X2, @"终点 X", @"点", NO)];
                [sec1 addObject:RowNum(F_Y2, @"终点 Y", @"点", NO)];
                [sec1 addObject:RowNum(F_MS, @"滑动时长", @"毫秒", NO)];
                break;
            case KWait:
                [sec1 addObject:RowNum(F_MS, @"等待时长", @"毫秒", NO)];
                break;
        }
    }

    NSMutableArray *sec2 = [NSMutableArray array];
    [sec2 addObject:@{@"k": @(RNote), @"t": @"执行概率 = 这一步有多大概率真的去做；随机率 = 做了之后有多大比例带随机"}];
    [sec2 addObject:RowNum(F_RUN, @"执行概率", @"0~1", YES)];
    [sec2 addObject:RowNum(F_RP, @"随机率", @"0~1", YES)];
    [sec2 addObject:RowNum(F_RPX, @"位置随机半径", @"点", NO)];
    [sec2 addObject:@{@"k": @(RPhys)}];
    if (_physOn) {
        [sec2 addObject:RowNum(F_PMIN, @"压力下限", @"0~1", YES)];
        [sec2 addObject:RowNum(F_PMAX, @"压力上限", @"0~1", YES)];
        [sec2 addObject:RowNum(F_RMIN, @"触摸半径下限", @"", YES)];
        [sec2 addObject:RowNum(F_RMAX, @"触摸半径上限", @"", YES)];
    }
    [sec2 addObject:RowNum(F_MSJ, @"时长抖动", @"±比例", YES)];
    [sec2 addObject:RowNum(F_GAPJ, @"间隔抖动", @"±比例", YES)];

    NSMutableArray *sec3 = [NSMutableArray array];
    [sec3 addObject:RowNum(F_GAP, @"与上一步的间隔", @"毫秒", NO)];

    NSMutableArray *sec4 = [NSMutableArray array];
    [sec4 addObject:@{@"k": @(RDelete)}];

    _plan = @[sec0, sec1, sec2, sec3, sec4];
    if (self.isViewLoaded) [self.tableView reloadData];
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_plan.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)_plan[s].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"动作";
        case 1: return _imgMode ? @"识图参数" : @"位置";
        case 2: return @"随机化";
        case 3: return @"节奏";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 2) return @"压力/半径默认关：之前实测这台机器只认「压力 0 / 半径 0.04」，开了可能点不动。";
    if (s == 1 && _imgMode) return @"模板是截屏里框出来的；直播/视频画面会变，尽量框静态按钮。";
    return nil;
}

- (UITableViewCell *)baseCell:(NSString *)reuse {
    UITableViewCell *c = [self.tableView dequeueReusableCellWithIdentifier:reuse];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    c.backgroundColor = ED_CARD;
    c.textLabel.textColor = ED_TEXT;
    c.detailTextLabel.textColor = ED_DIM;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = _plan[ip.section][ip.row];
    TDRowKind k = (TDRowKind)[row[@"k"] integerValue];

    if (k == RKind) {
        UITableViewCell *c = [self baseCell:@"kind"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"点击", @"长按", @"滑动", @"等待"]];
        seg.frame = CGRectMake(0, 0, 232, 30);
        seg.selectedSegmentIndex = _kind;
        seg.tintColor = ED_ACCENT;
        [seg addTarget:self action:@selector(kindChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = seg;
        c.textLabel.text = @"类型";
        return c;
    }

    if (k == RMode) {
        UITableViewCell *c = [self baseCell:@"mode"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"坐标", @"识图"]];
        seg.frame = CGRectMake(0, 0, 150, 30);
        seg.selectedSegmentIndex = _imgMode ? 1 : 0;
        seg.tintColor = ED_GREEN;
        [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = seg;
        c.textLabel.text = @"定位方式";
        return c;
    }

    if (k == RNum) {
        TDField f = (TDField)[row[@"f"] integerValue];
        UITableViewCell *c = [self baseCell:@"num"];
        c.textLabel.text = row[@"t"];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 116, 30)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = ED_GREEN;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.returnKeyType = UIReturnKeyDone;
        tf.delegate = self;
        tf.tag = f;
        tf.text = [self textFor:f];
        tf.placeholder = row[@"u"];
        [tf addTarget:self action:@selector(numChanged:) forControlEvents:UIControlEventEditingChanged];
        c.accessoryView = tf;
        return c;
    }

    if (k == RTpl) {
        UITableViewCell *c = [self baseCell:@"tpl"];
        c.detailTextLabel.text = _tpl.length ? TDTplDisplay(_tpl) : @"未选";
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.textLabel.text = @"模板";
        if (_tpl.length) {
            UIImage *im = [UIImage imageWithContentsOfFile:TDTplPath(_tpl)];
            c.imageView.image = im;
            c.imageView.contentMode = UIViewContentModeScaleAspectFit;
            c.imageView.clipsToBounds = YES;
        } else {
            c.imageView.image = nil;
        }
        return c;
    }

    if (k == RTest) {
        UITableViewCell *c = [self baseCell:@"test"];
        c.textLabel.text = @"试识别一次";
        c.textLabel.textColor = ED_ACCENT;
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }

    if (k == RPhys) {
        UITableViewCell *c = [self baseCell:@"phys"];
        c.textLabel.text = @"随机压力 / 半径";
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectZero];
        sw.on = _physOn;
        sw.onTintColor = ED_YELL;
        [sw addTarget:self action:@selector(physChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    if (k == RDelete) {
        UITableViewCell *c = [self baseCell:@"del"];
        c.textLabel.text = @"删除这个事件";
        c.textLabel.textColor = ED_RED;
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }

    UITableViewCell *c = [self baseCell:@"note"];
    c.textLabel.text = row[@"t"];
    c.textLabel.numberOfLines = 2;
    c.textLabel.font = [UIFont systemFontOfSize:12];
    c.textLabel.textColor = ED_DIM;
    c.textLabel.textAlignment = NSTextAlignmentLeft;
    return c;
}

- (NSString *)textFor:(TDField)f {
    NSString *fmt = [self isDec:f] ? @"%.2f" : @"%.0f";
    return [NSString stringWithFormat:fmt, _v[f]];
}

- (BOOL)isDec:(TDField)f {
    return f == F_TH || f == F_RP || f == F_PMIN || f == F_PMAX ||
           f == F_RMIN || f == F_RMAX || f == F_MSJ || f == F_GAPJ || f == F_RUN;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *v = [super tableView:tv viewForHeaderInSection:s];
    return v;
}

#pragma mark 交互

- (void)kindChanged:(UISegmentedControl *)seg {
    _kind = (TDStepKind)seg.selectedSegmentIndex;
    if (_kind == KSwipe || _kind == KWait) _imgMode = NO;
    if (_kind == KWait && _v[F_MS] < 100) _v[F_MS] = 500;
    [self rebuildPlan];
}

- (void)modeChanged:(UISegmentedControl *)seg {
    _imgMode = (seg.selectedSegmentIndex == 1);
    [self rebuildPlan];
    if (_imgMode && _tpl.length == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self pickTemplate];
        });
    }
}

- (void)physChanged:(UISwitch *)sw {
    _physOn = sw.on;
    [self rebuildPlan];
}

- (void)numChanged:(UITextField *)tf {
    if (tf.tag < 0 || tf.tag >= F_COUNT) return;
    _v[tf.tag] = [tf.text doubleValue];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row = _plan[ip.section][ip.row];
    TDRowKind k = (TDRowKind)[row[@"k"] integerValue];

    if (k == RTpl) { [self pickTemplate]; return; }
    if (k == RTest) { [self runTest]; return; }
    if (k == RDelete) { [self confirmDelete]; return; }
}

- (void)pickTemplate {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"识图模板"
                                                              message:@"截一屏拉个框，或者用已有模板"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"截取当前屏幕" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self captureTemplate]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"从模板库选" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self chooseTemplate]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)captureTemplate {
    UIImage *shot = TDscreenshot();
    if (!shot) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"截屏不可用"
                                                                  message:TDcaptureStatus()
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    TDCropVC *c = [TDCropVC new];
    c.shot = shot;
    __weak typeof(self) ws = self;
    c.onDone = ^(NSString *name) {
        typeof(self) ss = ws;
        if (!ss) return;
        ss->_tpl = [name copy];
        [ss.tableView reloadData];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:c];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)chooseTemplate {
    NSArray<NSString *> *list = TDTemplateList();
    if (list.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没有模板"
                                                                  message:@"先用「截取当前屏幕」做一个"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"选模板"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *n in list) {
        NSString *disp = TDTplDisplay(n);
        [a addAction:[UIAlertAction actionWithTitle:disp style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) {
            self->_tpl = [n copy];
            [self.tableView reloadData];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 160, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)confirmDelete {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除这个事件？"
                                                              message:@"只删这一步，脚本其它步骤不动"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *x) {
        void (^d)(void) = self->_onDelete;
        [self dismissViewControllerAnimated:YES completion:^{ if (d) d(); }];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)runTest {
    if (_tpl.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没选模板"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self.view endEditing:YES];
    NSString *name = [_tpl copy];
    double th = _v[F_TH];
    double dx = _v[F_DX];
    double dy = _v[F_DY];
    __weak typeof(self) ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *tpl = [UIImage imageWithContentsOfFile:TDTplPath(name)];
        TDMatch *m = tpl ? TDfindImage(tpl, th, 1.0, 1.0, 1) : nil;
        NSString *msg;
        if (!tpl) {
            msg = @"模板文件读不出来";
        } else if (!m) {
            msg = [NSString stringWithFormat:@"没找到（阈值 %.2f）。\n可以框小一点，或把阈值调低。", th];
        } else {
            msg = [NSString stringWithFormat:@"命中 %.3f\n屏幕位置 (%.0f, %.0f)\n加偏移后：(%.0f, %.0f)",
                   m.score, m.point.x, m.point.y,
                   m.point.x + dx, m.point.y + dy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (!ss) return;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"试识别"
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [ss presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark 保存

- (void)onCancel {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)onSave {
    [self.view endEditing:YES];

    if (_imgMode && _tpl.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"还没选模板"
                                                                  message:@"识图步骤必须有模板才能保存"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    [self commit];
    void (^s)(void) = _onSave;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (s) s();
    }];
}

- (void)commit {
    [_d removeAllObjects];
    _d[@"gap"] = @((NSInteger)lround(_v[F_GAP]));

    if (_kind == KWait) {
        _d[@"t"] = @"wait";
        _d[@"ms"] = @((NSInteger)MAX(0, lround(_v[F_MS])));
    } else if (_kind == KSwipe) {
        _d[@"t"] = @"swipe";
        _d[@"x1"] = @((NSInteger)lround(_v[F_X1]));
        _d[@"y1"] = @((NSInteger)lround(_v[F_Y1]));
        _d[@"x2"] = @((NSInteger)lround(_v[F_X2]));
        _d[@"y2"] = @((NSInteger)lround(_v[F_Y2]));
        _d[@"ms"] = @((NSInteger)MAX(120, lround(_v[F_MS])));
    } else if (_imgMode) {
        _d[@"t"] = @"find";
        _d[@"tpl"] = _tpl ?: @"";
        _d[@"th"] = @(_v[F_TH]);
        _d[@"dx"] = @((NSInteger)lround(_v[F_DX]));
        _d[@"dy"] = @((NSInteger)lround(_v[F_DY]));
        _d[@"to"] = @((NSInteger)MAX(0, lround(_v[F_TO])));
        if (_kind == KLong) _d[@"ms"] = @((NSInteger)MAX(120, lround(_v[F_MS])));
    } else {
        _d[@"t"] = (_kind == KLong ? @"long" : @"tap");
        _d[@"x"] = @((NSInteger)lround(_v[F_X]));
        _d[@"y"] = @((NSInteger)lround(_v[F_Y]));
        if (_kind == KLong) _d[@"ms"] = @((NSInteger)MAX(120, lround(_v[F_MS])));
    }

    if (_v[F_RUN] < 0.999) _d[@"run"] = @(MAX(0.0, MIN(1.0, _v[F_RUN])));

    if (_v[F_RP] > 0.001) {
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        r[@"p"] = @(MIN(1.0, _v[F_RP]));
        if (_v[F_RPX] > 0.5) r[@"px"] = @((NSInteger)lround(_v[F_RPX]));
        if (_physOn) {
            r[@"pr"] = @[@(_v[F_PMIN]), @(_v[F_PMAX])];
            r[@"rd"] = @[@(_v[F_RMIN]), @(_v[F_RMAX])];
        }
        if (_v[F_MSJ] > 0.001) r[@"ms"] = @(_v[F_MSJ]);
        if (_v[F_GAPJ] > 0.001) r[@"gap"] = @(_v[F_GAPJ]);
        _d[@"rnd"] = r;
    }
}

@end

#pragma mark - 模板库页

@interface TDTplListVC : UITableViewController
@end

@implementation TDTplListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"识图模板";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.rowHeight = 62;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)TDTemplateList().count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"t"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"t"];
    NSString *n = TDTemplateList()[ip.row];
    c.backgroundColor = ED_CARD;
    c.textLabel.textColor = ED_TEXT;
    c.detailTextLabel.textColor = ED_DIM;
    c.textLabel.text = TDTplDisplay(n);
    UIImage *im = [UIImage imageWithContentsOfFile:TDTplPath(n)];
    c.detailTextLabel.text = im ? [NSString stringWithFormat:@"%.0f×%.0f px", im.size.width, im.size.height] : @"读不出来";
    c.imageView.image = im;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;
    c.imageView.clipsToBounds = YES;
    return c;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
 forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *n = TDTemplateList()[ip.row];
    [[NSFileManager defaultManager] removeItemAtPath:TDTplPath(n) error:NULL];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

#pragma mark - 脚本编辑页

@interface TDScriptEditVC : UITableViewController
@property (nonatomic, strong) TDScript *script;
@end

@implementation TDScriptEditVC

- (instancetype)initWithScript:(TDScript *)s {
    if (self = [super initWithStyle:UITableViewStyleInsetGrouped]) {
        _script = s;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _script.name ?: @"脚本";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.separatorColor = ED_LINE;
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onClose)];
    self.navigationController.navigationBar.tintColor = ED_GREEN;
}

- (void)onClose {
    [[TDScriptStore shared] save];
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? (NSInteger)_script.steps.count : 4;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) {
        return [NSString stringWithFormat:@"事件（%lu 个）· 点一行改它",
                (unsigned long)_script.steps.count];
    }
    return @"操作";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.backgroundColor = ED_CARD;
    c.textLabel.textColor = ED_TEXT;
    c.detailTextLabel.textColor = ED_DIM;
    c.imageView.image = nil;

    if (ip.section == 0) {
        NSDictionary *st = _script.steps[ip.row];
        c.textLabel.text = [NSString stringWithFormat:@"%ld  %@", (long)(ip.row + 1),
                            [TDScript describeStep:st]];
        NSString *mode = [st[@"t"] isEqualToString:@"find"] ? @"识图" : @"坐标";
        NSDictionary *r = [st[@"rnd"] isKindOfClass:[NSDictionary class]] ? st[@"rnd"] : nil;
        NSString *rnd = r ? [NSString stringWithFormat:@" · 随机 %.0f%%", [r[@"p"] doubleValue] * 100] : @"";
        NSString *skip = st[@"run"] ? [NSString stringWithFormat:@" · 执行 %.0f%%",
                                       [st[@"run"] doubleValue] * 100] : @"";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 间隔 %.0fms%@%@",
                                  mode, [st[@"gap"] doubleValue], skip, rnd];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        switch (ip.row) {
            case 0:
                c.textLabel.text = @"＋ 加一个事件";
                c.detailTextLabel.text = @"点击 / 长按 / 滑动 / 等待 / 识图";
                break;
            case 1:
                c.textLabel.text = @"▶ 试运行整条脚本";
                c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 3 秒后开始",
                                          [_script summary]];
                break;
            case 2:
                c.textLabel.text = [NSString stringWithFormat:@"识图模板库（%lu）",
                                    (unsigned long)TDTemplateList().count];
                c.detailTextLabel.text = @"查看 / 删除已截的模板";
                break;
            default:
                c.textLabel.text = @"设为当前脚本";
                c.detailTextLabel.text = ([TDScriptStore shared].selectedScript == _script)
                    ? @"已经是当前脚本" : @"悬浮球 ▶ 会跑这一条";
                break;
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self editStepAtIndex:ip.row]; return; }

    switch (ip.row) {
        case 0: [self addStep]; break;
        case 1: [self tryRun]; break;
        case 2: [self.navigationController pushViewController:[TDTplListVC new] animated:YES]; break;
        default: {
            NSInteger idx = (NSInteger)[[TDScriptStore shared].scripts indexOfObjectIdenticalTo:_script];
            if (idx >= 0) {
                [TDScriptStore shared].selected = idx;
                [[TDScriptStore shared] save];
                [tv reloadData];
                TDFloatRefresh();
            }
            break;
        }
    }
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0; }

- (BOOL)tableView:(UITableView *)tv canMoveRowAtIndexPath:(NSIndexPath *)ip { return ip.section == 0; }

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
 forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    [_script.steps removeObjectAtIndex:ip.row];
    [[TDScriptStore shared] save];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tv moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableDictionary *d = _script.steps[from.row];
    [_script.steps removeObjectAtIndex:from.row];
    [_script.steps insertObject:d atIndex:MIN((NSUInteger)to.row, _script.steps.count)];
    [[TDScriptStore shared] save];
}

#pragma mark 单步

- (void)editStepAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_script.steps.count) return;
    NSMutableDictionary *d = _script.steps[idx];
    if (![d isKindOfClass:[NSMutableDictionary class]]) {
        d = [d mutableCopy];
        _script.steps[idx] = d;
    }
    __weak typeof(self) ws = self;
    TDStepEditVC *vc = [[TDStepEditVC alloc] initWithStep:d isNew:NO onSave:^{
        typeof(self) ss = ws;
        [[TDScriptStore shared] save];
        [ss.tableView reloadData];
    } onDelete:^{
        typeof(self) ss = ws;
        if (idx < (NSInteger)ss.script.steps.count) {
            [ss.script.steps removeObjectAtIndex:idx];
            [[TDScriptStore shared] save];
            [ss.tableView reloadData];
        }
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)addStep {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"加什么事件"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"点击（坐标）", @"长按（坐标）", @"滑动", @"等待", @"识图点击"];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) { [self createStepKind:i]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 200, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)createStepKind:(NSInteger)k {
    CGSize sb = [UIScreen mainScreen].bounds.size;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"gap"] = @(300);

    switch (k) {
        case 0:
            d[@"t"] = @"tap";
            d[@"x"] = @((NSInteger)(sb.width / 2));
            d[@"y"] = @((NSInteger)(sb.height * 0.62));
            break;
        case 1:
            d[@"t"] = @"long";
            d[@"x"] = @((NSInteger)(sb.width / 2));
            d[@"y"] = @((NSInteger)(sb.height * 0.62));
            d[@"ms"] = @(800);
            break;
        case 2:
            d[@"t"] = @"swipe";
            d[@"x1"] = @((NSInteger)(sb.width / 2));
            d[@"y1"] = @((NSInteger)(sb.height * 0.72));
            d[@"x2"] = @((NSInteger)(sb.width / 2));
            d[@"y2"] = @((NSInteger)(sb.height * 0.28));
            d[@"ms"] = @(400);
            break;
        case 3:
            d[@"t"] = @"wait";
            d[@"ms"] = @(1000);
            break;
        default:
            d[@"t"] = @"find";
            d[@"tpl"] = @"";
            d[@"th"] = @([TDConfig shared].threshold);
            d[@"dx"] = @0;
            d[@"dy"] = @0;
            d[@"to"] = @(1500);
            break;
    }

    [_script.steps addObject:d];
    NSInteger idx = (NSInteger)_script.steps.count - 1;
    __weak typeof(self) ws = self;
    TDStepEditVC *vc = [[TDStepEditVC alloc] initWithStep:d isNew:YES onSave:^{
        typeof(self) ss = ws;
        [[TDScriptStore shared] save];
        [ss.tableView reloadData];
    } onDelete:^{
        typeof(self) ss = ws;
        if (idx < (NSInteger)ss.script.steps.count) {
            [ss.script.steps removeObjectAtIndex:idx];
            [[TDScriptStore shared] save];
            [ss.tableView reloadData];
        }
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)tryRun {
    if (_script.steps.count == 0) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"试运行"
                                                              message:@"3 秒后开始，现在切到抖音。用当前脚本的循环次数。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        NSArray *plan = [self->_script engineSteps];
        NSInteger loops = [TDConfig shared].loopCount;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[TDEngine shared] playSteps:plan loop:loops];
            TDFloatRefresh();
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - 工厂

UIViewController *TDCreateScriptEditVC(TDScript *script) {
    TDScriptEditVC *vc = [[TDScriptEditVC alloc] initWithScript:script];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = ED_GREEN;
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
        [ap configureWithOpaqueBackground];
        ap.backgroundColor = ED_BG;
        ap.titleTextAttributes = @{NSForegroundColorAttributeName: ED_TEXT};
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
    }
    return nav;
}
