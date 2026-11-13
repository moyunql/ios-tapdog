#import "TD.h"
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
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

#define ED_BG     [UIColor colorWithRed:0.957 green:0.965 blue:0.973 alpha:1]
#define ED_CARD   [UIColor colorWithRed:1.000 green:1.000 blue:1.000 alpha:1]
#define ED_LINE   [UIColor colorWithRed:0.851 green:0.871 blue:0.890 alpha:1]
#define ED_TEXT   [UIColor colorWithRed:0.106 green:0.125 blue:0.149 alpha:1]
#define ED_DIM    [UIColor colorWithRed:0.420 green:0.451 blue:0.482 alpha:1]
#define ED_ACCENT [UIColor colorWithRed:0.129 green:0.447 blue:0.918 alpha:1]
#define ED_GREEN  [UIColor colorWithRed:0.094 green:0.549 blue:0.302 alpha:1]
#define ED_RED    [UIColor colorWithRed:0.812 green:0.165 blue:0.165 alpha:1]
#define ED_YELL   [UIColor colorWithRed:0.741 green:0.494 blue:0.047 alpha:1]

#pragma mark - 模板库

static NSString *TDDocsDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return d ?: NSTemporaryDirectory();
}

static NSString *TDTplPath(NSString *name) {
    return [TDDocsDir() stringByAppendingPathComponent:name ?: @""];
}

// 内置模板（点赞 / 评论 / 收藏）
//
// build.sh 把 Resources/tpl 打进 bundle 的 tpl/ 目录，这里在每次启动时补拷到 Documents：
// 只在「文件不存在」且「没被用户主动删过」时拷 —— 首次安装能开箱即用，
// 用户真不想要就删，删了记进黑名单，不会再被塞回来。
// 文件名前缀 tpl_lib_ 是标记：库里显示中文名、排最前。
static NSDictionary<NSString *, NSString *> *TDBuiltinNames(void) {
    static NSDictionary *m = nil;
    if (!m) {
        m = @{@"tpl_lib_like.png":    @"点赞",
              @"tpl_lib_comment.png": @"评论",
              @"tpl_lib_star.png":    @"收藏"};
    }
    return m;
}

BOOL TDTplIsBuiltin(NSString *file) {
    return file.length > 0 && TDBuiltinNames()[file] != nil;
}

static NSMutableArray<NSString *> *TDBuiltinHidden(void) {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:@"tdLibTplHidden"];
    return [a mutableCopy] ?: [NSMutableArray array];
}

static void TDHideBuiltin(NSString *name) {
    NSMutableArray *a = TDBuiltinHidden();
    if ([a containsObject:name]) return;
    [a addObject:name];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:@"tdLibTplHidden"];
}

void TDInstallBuiltinTemplates(void) {
    NSString *dir = TDDocsDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *hidden = TDBuiltinHidden();

    NSInteger copied = 0;
    for (NSString *name in TDBuiltinNames()) {
        if ([hidden containsObject:name]) continue;
        NSString *dst = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:dst]) continue;
        NSString *src = [[NSBundle mainBundle] pathForResource:[name stringByDeletingPathExtension]
                                                        ofType:@"png"
                                                   inDirectory:@"tpl"];
        if (!src) continue;
        if ([fm copyItemAtPath:src toPath:dst error:NULL]) copied++;
    }
    if (copied > 0) TDLog(@"内置识图模板已装入 %ld 个（点赞/评论/收藏）", (long)copied);
}

static NSArray<NSString *> *TDTemplateList(void) {
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:TDDocsDir() error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in all ?: @[]) {
        if ([n hasPrefix:@"tpl_"] && [[n pathExtension].lowercaseString isEqualToString:@"png"]) {
            [out addObject:n];
        }
    }
    // 内置模板永远排最前，后面才是用户自己截的（按文件名即时间序）
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL ba = TDTplIsBuiltin(a), bb = TDTplIsBuiltin(b);
        if (ba != bb) return ba ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    return out;
}

/// 重画成 .up 方向、scale=1、像素尺寸 = 原图像素尺寸。
///
/// 相册里的图几乎都带 orientation（相机拍的是 .right，截图倒可能是别的），
/// 而 CGImageCreateWithImageInRect 是按「未旋转」的像素裁的：
/// 不先摊平，框出来会是横的或者错位。所以进来的图一律先过这一道。
static UIImage *TDImageUpright(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 1 || h < 1) return nil;
    if (img.imageOrientation == UIImageOrientationUp && fabs(img.scale - 1.0) < 0.001) return img;

    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1.0;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, w, h)];
    }];
}

/// 相册图 → 屏幕像素尺度。mode: 0 本来就一致 / 1 已缩放 / 2 宽高比不像同一块屏
///
/// 模板匹配是单尺度的：模板里的像素必须和屏幕上那块的实际像素一样大，
/// 差 10% 就几乎不可能过阈值。相册里现成的图多是被转发压过的（比如 828×1472），
/// 所以先量一下屏幕真实像素尺寸，宽高比一致就等比缩回去。
/// 注意不能用 414×736×3 = 1242×2208：Plus 机型是 3x 渲染后再降采样到 1080×1920，
/// 直接乘 scale 会差 13%，必须用截屏实测。
static UIImage *TDImageToScreenScale(UIImage *img, NSInteger *mode) {
    if (mode) *mode = 0;
    UIImage *up = TDImageUpright(img);
    if (!up) return nil;
    CGSize src = up.size;

    UIImage *probe = TDscreenshot();
    CGSize dst = probe ? probe.size : CGSizeZero;
    if (dst.width < 1 || src.width < 1) return up;

    CGFloat arSrc = src.width / MAX(1.0, src.height);
    CGFloat arDst = dst.width / MAX(1.0, dst.height);
    if (fabs(arSrc - arDst) > 0.02) {
        if (mode) *mode = 2;
        return up;
    }
    if (fabs(src.width - dst.width) < 1.5 && fabs(src.height - dst.height) < 1.5) return up;

    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1.0;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:dst format:f];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [up drawInRect:CGRectMake(0, 0, dst.width, dst.height)];
    }];
    if (out && mode) *mode = 1;
    return out;
}

/// tpl_1699880000.png → 尾 6 位，够区分又不占地方
static NSString *TDTplDisplay(NSString *file) {
    NSString *nice = TDBuiltinNames()[file];
    if (nice) return [nice stringByAppendingString:@"（内置）"];
    if (file.length < 4) return file ?: @"";
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasPrefix:@"tpl_"]) s = [s substringFromIndex:4];
    if (s.length > 6) s = [s substringFromIndex:s.length - 6];
    return s;
}

// 相册选图。
//
// 用 PHPicker（iOS 14+）：它在独立进程里挑图，**不需要相册权限**，
// 也就不会在 TrollStore 签名的包上卡在权限弹窗。老系统退回 UIImagePickerController，
// 那条路要 NSPhotoLibraryUsageDescription（Info.plist 里已经有了）。
// 选择期间必须有人强持有 self，否则 block 回调时对象已经没了。
static NSMutableArray *gPhotoPicks = nil;

@interface TDPhotoPick : NSObject <PHPickerViewControllerDelegate,
                                  UIImagePickerControllerDelegate,
                                  UINavigationControllerDelegate>
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, copy) void (^onImage)(UIImage *img);
- (void)presentFrom:(UIViewController *)host;
@end

@implementation TDPhotoPick

- (void)presentFrom:(UIViewController *)host {
    self.host = host;
    if (!gPhotoPicks) gPhotoPicks = [NSMutableArray array];
    [gPhotoPicks addObject:self];

    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.filter = [PHPickerFilter imagesFilter];
        cfg.selectionLimit = 1;
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pk.delegate = self;
        [host presentViewController:pk animated:YES completion:nil];
    } else {
        UIImagePickerController *ip = [[UIImagePickerController alloc] init];
        ip.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        ip.delegate = self;
        [host presentViewController:ip animated:YES completion:nil];
    }
}

- (void)finishWith:(UIImage *)img {
    void (^cb)(UIImage *) = self.onImage;
    self.onImage = nil;
    [gPhotoPicks removeObject:self];
    if (cb) cb(img);
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) { [self finishWith:nil]; return; }

    NSItemProvider *it = results.firstObject.itemProvider;
    if (![it canLoadObjectOfClass:[UIImage class]]) { [self finishWith:nil]; return; }

    __weak typeof(self) ws = self;
    [it loadObjectOfClass:[UIImage class] completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        UIImage *img = [obj isKindOfClass:[UIImage class]] ? (UIImage *)obj : nil;
        // 回调在后台队列，UI 一律回主线程
        dispatch_async(dispatch_get_main_queue(), ^{ [ws finishWith:img]; });
    }];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{ [self finishWith:img]; }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{ [self finishWith:nil]; }];
}

@end

#pragma mark - 截屏拉框

@interface TDCropVC : UIViewController
@property (nonatomic, strong) UIImage *shot;
/// 来源说明，比如「来自相册（已缩放到屏幕尺度）」，会显示在顶部和提示里
@property (nonatomic, copy) NSString *note;
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
    self.title = _note.length ? @"框选（相册图）" : @"框选要识别的画面";
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
    _tip.text = _note.length
        ? [NSString stringWithFormat:@"%@\n在画面上按住拖动，框住要认的那个图案（越小越准）", _note]
        : @"在画面上按住拖动，框住要认的那个图案（越小越准）";
    _tip.textColor = ED_DIM;
    _tip.font = [UIFont systemFontOfSize:13];
    _tip.textAlignment = NSTextAlignmentCenter;
    _tip.numberOfLines = 3;
    [self.view addSubview:_tip];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.view addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _iv.frame = self.view.bounds;
    _tip.frame = CGRectMake(20, self.view.bounds.size.height - 92,
                            self.view.bounds.size.width - 40, 66);
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

typedef NS_ENUM(NSInteger, TDStepKind) { KTap = 0, KLong, KSwipe, KWait, KPaste };
typedef NS_ENUM(NSInteger, TDRowKind) {
    RKind = 0, RMode, RNum, RTpl, RTest, RPhys, RDelete, RNote, RText, RPool, RPasteTest
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

/// 私有方法前向声明：这些在定义之前就被调用（比如按钮 action → pickTemplate），
/// 不声明只是警告，但警告一多真正的问题就看不见了。
@interface TDStepEditVC ()
- (void)pickTemplate;
- (void)captureTemplate;
- (void)importFromPhotos;
- (void)afterPhotoPick:(UIImage *)img;
- (void)chooseTemplate;
- (void)runTest;
- (void)confirmDelete;
- (void)poolModeChanged:(UISegmentedControl *)seg;
- (void)textChanged:(UITextField *)tf;
- (void)tryPaste;
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
    // 粘贴步骤：文本为空 = 从评论池随机取
    NSString *_pasteText;
    BOOL _pasteFixed;          // YES = 用下面这句写死的话，NO = 池里随机

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
          : [t isEqualToString:@"paste"] ? KPaste
          : KTap;
    _imgMode = [t isEqualToString:@"find"];
    _pasteText = [_d[@"text"] isKindOfClass:[NSString class]] ? [_d[@"text"] copy] : @"";
    _pasteFixed = (_pasteText.length > 0);

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
    if (_kind == KPaste) {
        // 粘贴：文本从评论池随机取，或者写死一句
        [sec1 addObject:@{@"k": @(RPool)}];
        if (_pasteFixed) [sec1 addObject:@{@"k": @(RText)}];
        [sec1 addObject:@{@"k": @(RPasteTest)}];
    } else if (_imgMode) {
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
        case 1: return _kind == KPaste ? @"粘贴内容" : (_imgMode ? @"识图参数" : @"位置");
        case 2: return @"随机化";
        case 3: return @"节奏";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 2) return @"压力/半径默认关：之前实测这台机器只认「压力 0 / 半径 0.04」，开了可能点不动。";
    if (s == 1 && _kind == KPaste)
        return @"「粘贴」是写剪贴板 + 发 Cmd+V，所以前面必须先有一步把评论框点开（获取焦点）。"
                "文本留空就用评论池里随机的一条 —— 话术池在脚本编辑页的「评论池」里维护。";
    if (s == 1 && _imgMode)
        return @"模板可以截屏框选，也可以从相册传一张截图；画面会变的（直播/视频）尽量框静态按钮。";
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
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"点击", @"长按", @"滑动", @"等待", @"粘贴"]];
        seg.frame = CGRectMake(0, 0, 246, 30);
        seg.selectedSegmentIndex = _kind;
        seg.tintColor = ED_ACCENT;
        [seg setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11.5]}
                           forState:UIControlStateNormal];
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
        if (_tpl.length == 0) c.detailTextLabel.text = @"未选 · 可截屏或从相册导入";
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

    if (k == RPool) {
        UITableViewCell *c = [self baseCell:@"pool"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"评论池随机", @"固定一句"]];
        seg.frame = CGRectMake(0, 0, 190, 30);
        seg.selectedSegmentIndex = _pasteFixed ? 1 : 0;
        seg.tintColor = ED_GREEN;
        [seg addTarget:self action:@selector(poolModeChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = seg;
        c.textLabel.text = @"文本来源";
        c.detailTextLabel.text = [NSString stringWithFormat:@"池里 %ld 条", (long)TDCommentPoolCount()];
        return c;
    }

    if (k == RText) {
        UITableViewCell *c = [self baseCell:@"text"];
        c.textLabel.text = @"话术";
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 190, 30)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = ED_GREEN;
        tf.font = [UIFont systemFontOfSize:14];
        tf.returnKeyType = UIReturnKeyDone;
        tf.delegate = self;
        tf.tag = -1;                       // -1 = 话术输入框（不是数值）
        tf.text = _pasteText;
        tf.placeholder = @"要粘贴的这句话";
        [tf addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
        c.accessoryView = tf;
        return c;
    }

    if (k == RPasteTest) {
        UITableViewCell *c = [self baseCell:@"ptest"];
        c.textLabel.text = [NSString stringWithFormat:@"试粘贴一次（%@）", TDPasteMethodDesc()];
        c.textLabel.textColor = ED_ACCENT;
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
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
    if (_kind == KSwipe || _kind == KWait || _kind == KPaste) _imgMode = NO;
    if (_kind == KWait && _v[F_MS] < 100) _v[F_MS] = 500;
    [self rebuildPlan];
}

- (void)poolModeChanged:(UISegmentedControl *)seg {
    if (seg.selectedSegmentIndex == 1) {
        _pasteFixed = YES;
        [self rebuildPlan];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 让输入框直接进入编辑状态，省一次点击
            for (UITableViewCell *c in self.tableView.visibleCells) {
                if ([c.accessoryView isKindOfClass:[UITextField class]] &&
                    c.accessoryView.tag == -1) {
                    [c.accessoryView becomeFirstResponder];
                    break;
                }
            }
        });
    } else {
        _pasteFixed = NO;
        _pasteText = @"";
        [self rebuildPlan];
    }
}

- (void)textChanged:(UITextField *)tf {
    if (tf.tag == -1) _pasteText = [tf.text copy] ?: @"";
}

/// 现场试一次粘贴：把这句话写进剪贴板再发 Cmd+V。
/// 让用户在抖音评论框里先点开输入框，回来按这个，看字有没有进去 ——
/// 这一步能把「键盘通道通不通」和「脚本写错没错」彻底分开。
- (void)tryPaste {
    [self.view endEditing:YES];
    NSString *txt = _pasteText.length ? _pasteText : TDCommentPick();
    if (txt.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没有可粘的内容"
                                                                  message:@"评论池是空的，先写死一句，或者去「评论池」里加几条"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    TDPasteText(txt);
    NSString *msg = [NSString stringWithFormat:
                     @"已写好剪贴板，按「%@」发了一次：\n「%@」\n\n"
                      "想在抖音里看效果：用「▶ 试运行整条脚本」，前面要有一步先点开评论框。\n"
                      "「长按 + 点菜单 / 识图」这两种必须在抖音里做，在这里按不出效果。",
                     TDPasteMethodDesc(), txt];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已尝试粘贴"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
    if (k == RPasteTest) { [self tryPaste]; return; }
    if (k == RDelete) { [self confirmDelete]; return; }
}

- (void)pickTemplate {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"识图模板"
                                                              message:@"截一屏拉个框、从相册传一张，或者用已有模板"
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"截取当前屏幕" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self captureTemplate]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"从相册选图" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) { [self importFromPhotos]; }]];
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

/// 从相册挑一张，进同一个拉框页。
/// 为什么还要拉框：整张截图当模板太大，匹配既慢又容易被相似区域骗；
/// 而且用户往往是「截了图，只关心其中某个按钮」，框一下才准。
- (void)importFromPhotos {
    __weak typeof(self) ws = self;
    TDPhotoPick *pk = [TDPhotoPick new];
    pk.onImage = ^(UIImage *img) { [ws afterPhotoPick:img]; };
    [pk presentFrom:self];
}

- (void)afterPhotoPick:(UIImage *)img {
    if (!img) {
        // 用户取消时也会走到这里，静默返回；真读不出来才提示
        return;
    }
    NSInteger mode = 0;
    UIImage *fixed = TDImageToScreenScale(img, &mode);
    if (!fixed) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"这张图读不出来"
                                                                  message:@"换一张试试，png / jpg 都行"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSString *note;
    if (mode == 1) {
        note = [NSString stringWithFormat:@"来自相册 · 已缩放到屏幕像素 %.0f×%.0f",
                fixed.size.width, fixed.size.height];
    } else if (mode == 2) {
        // 宽高比对不上有两种情况：一是裁好的局部小图（可用），二是别的机型/别的缩放的截图
        // （尺度不对，多半匹配不上）。不拦，交给下面的「试识别一次」去判。
        note = @"来自相册 · 宽高比与屏幕不同，模板按本机像素才对，框完先用「试识别一次」验一下";
    } else {
        note = [NSString stringWithFormat:@"来自相册 · %.0f×%.0f，与屏幕像素一致",
                fixed.size.width, fixed.size.height];
    }

    TDCropVC *c = [TDCropVC new];
    c.shot = fixed;
    c.note = note;
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
        BOOL scaled = NO;
        // 和回放完全同一条路：记住的尺度 → 原尺度 → 尺度扫描
        TDMatch *m = tpl ? TDfindImageSmart(tpl, name, th, &scaled) : nil;
        NSString *msg;
        if (!tpl) {
            msg = @"模板文件读不出来";
        } else if (!m) {
            msg = [NSString stringWithFormat:
                   @"没找到（阈值 %.2f，连 ±15%% 尺度扫描也没有）。\n"
                    "模板 %.0f×%.0f px —— 如果比屏幕上那个图案大很多/小很多，"
                    "说明这张图的尺度和本机不匹配，换一张本机截屏最稳。",
                   th, tpl.size.width, tpl.size.height];
        } else {
            msg = [NSString stringWithFormat:@"命中 %.3f%@\n模板 %.0f×%.0f px\n屏幕位置 (%.0f, %.0f)\n加偏移后：(%.0f, %.0f)",
                   m.score,
                   scaled ? [NSString stringWithFormat:@"（靠尺度扫描 %.2f×）", m.scale] : @"",
                   tpl.size.width, tpl.size.height,
                   m.point.x, m.point.y,
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
    } else if (_kind == KPaste) {
        _d[@"t"] = @"paste";
        // 不写 text 键 = 从评论池随机取（引擎就是这么判的）
        if (_pasteFixed && _pasteText.length) _d[@"text"] = [_pasteText copy];
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

@interface TDTplListVC ()
- (void)onImport;
- (void)onResetScale;
- (void)afterImport:(UIImage *)img;
- (void)flashSaved:(NSString *)name;
@end

@implementation TDTplListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"识图模板";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.rowHeight = 62;
    // 模板也可以直接从这里进相册导入，然后框选保存
    UIBarButtonItem *add =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(onImport)];
    // 尺度记忆存在 NSUserDefaults 里，换界面/换图标尺寸后要能清掉重来
    UIBarButtonItem *reset =
        [[UIBarButtonItem alloc] initWithTitle:@"↺" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onResetScale)];
    self.navigationItem.rightBarButtonItems = @[add, reset];
}

- (void)onResetScale {
    for (NSString *n in TDTemplateList()) TDSetScaleHint(n, 0);
    [self.tableView reloadData];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已清掉记住的倍数"
                                                              message:@"下次识图会从原尺度开始重新找。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onImport {
    __weak typeof(self) ws = self;
    TDPhotoPick *pk = [TDPhotoPick new];
    pk.onImage = ^(UIImage *img) { [ws afterImport:img]; };
    [pk presentFrom:self];
}

- (void)afterImport:(UIImage *)img {
    if (!img) return;
    NSInteger mode = 0;
    UIImage *fixed = TDImageToScreenScale(img, &mode);
    if (!fixed) return;

    TDCropVC *c = [TDCropVC new];
    c.shot = fixed;
    c.note = mode == 1
        ? [NSString stringWithFormat:@"来自相册 · 已缩放到屏幕像素 %.0f×%.0f",
           fixed.size.width, fixed.size.height]
        : (mode == 2 ? @"来自相册 · 宽高比与屏幕不同，框完先用「试识别一次」验一下"
                     : [NSString stringWithFormat:@"来自相册 · %.0f×%.0f，与屏幕像素一致",
                        fixed.size.width, fixed.size.height]);

    __weak typeof(self) ws = self;
    c.onDone = ^(NSString *name) {
        typeof(self) ss = ws;
        if (!ss) return;
        [ss.tableView reloadData];
        [ss flashSaved:name];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:c];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

/// 存好了给个回执：模板页没有「选中」这个动作，不给反馈会以为没成功
- (void)flashSaved:(NSString *)name {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已存成模板"
                                                              message:[NSString stringWithFormat:@"%@（%.0f×%.0f）",
                                                                       TDTplDisplay(name),
                                                                       [UIImage imageWithContentsOfFile:TDTplPath(name)].size.width,
                                                                       [UIImage imageWithContentsOfFile:TDTplPath(name)].size.height]
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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
    double hint = TDScaleHint(n);
    NSString *scaleNote = hint > 0.05 ? [NSString stringWithFormat:@" · 识别倍数 %.2f×", hint] : @"";
    c.detailTextLabel.text = im
        ? [NSString stringWithFormat:@"%.0f×%.0f px%@", im.size.width, im.size.height, scaleNote]
        : @"读不出来";
    c.imageView.image = im;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;
    c.imageView.clipsToBounds = YES;
    return c;
}

/// 底部说明。两件事要说清：内置模板是「素材图」，尺度和屏幕不一样，
/// 第一次识图会自动找倍数；以及想让它重找一遍该点哪。
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (TDTemplateList().count == 0) return nil;
    return @"内置的点赞 / 评论 / 收藏是素材图，像素比屏幕上小，第一次识图会自动找出倍数并记住（显示在上面那行）。"
            "点右上角「↺」可以清掉记住的倍数，让它重新找一遍。";
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
 forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *n = TDTemplateList()[ip.row];
    if (TDTplIsBuiltin(n)) TDHideBuiltin(n);   // 删了就真删，重启不会再塞回来
    [[NSFileManager defaultManager] removeItemAtPath:TDTplPath(n) error:NULL];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

#pragma mark - 通用：新建步骤 / 打开单步编辑

static NSArray<NSString *> *TDStepKindTitles(void) {
    return @[@"点击（坐标）", @"长按（坐标）", @"滑动", @"等待", @"识图点击", @"粘贴话术"];
}

/// 按类型造一个默认步骤。k 的序号和上面的标题一一对应。
/// 主脚本编辑页和「判断」页共用同一套默认值，免得两处各写一份、改了一处忘另一处。
static NSMutableDictionary *TDNewStepOfKind(NSInteger k) {
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
        case 5:
            // 粘贴：不写 text = 从评论池随机取一条
            d[@"t"] = @"paste";
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
    return d;
}

static void TDPresentStepEditor(UIViewController *host, NSMutableDictionary *d, BOOL isNew,
                                void (^onSave)(void), void (^onDelete)(void)) {
    TDStepEditVC *vc = [[TDStepEditVC alloc] initWithStep:d isNew:isNew
                                                   onSave:onSave onDelete:onDelete];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [host presentViewController:nav animated:YES completion:nil];
}

/// 弹「加什么事件」，选完回调类型序号（取消不回调）
static void TDPresentKindSheet(UIViewController *host, NSString *title, void (^pick)(NSInteger k)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *titles = TDStepKindTitles();
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [a addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *x) { if (pick) pick(i); }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = host.view;
    a.popoverPresentationController.sourceRect =
        CGRectMake(host.view.bounds.size.width / 2, 200, 1, 1);
    [host presentViewController:a animated:YES completion:nil];
}

/// 兜底动作的默认随机：位置撒 8pt、时长抖 20%、间隔抖 30%。
/// 录出来的动作坐标是死的，同一个位置连点几十次最容易被看出来，
/// 所以判断里录完就自动把它加上，用户不用一步步去开。
static NSDictionary *TDDefaultFailsafeRnd(void) {
    return @{@"p": @1.0, @"px": @8, @"ms": @0.2, @"gap": @0.3};
}

#pragma mark - 循环设置

@interface TDLoopVC : UITableViewController
@property (nonatomic, strong) TDScript *script;
@end

@implementation TDLoopVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"循环";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.separatorColor = ED_LINE;
    self.navigationController.navigationBar.tintColor = ED_GREEN;
}

- (void)commit {
    [[TDScriptStore shared] save];
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"循环 0 = 一直跑，直到手动停。\n"
            "「每轮间隔」是整条脚本跑完一遍后歇多久再从头开始。\n"
            "循环关掉 = 只跑一遍。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"c"];
    c.backgroundColor = ED_CARD;
    c.textLabel.textColor = ED_TEXT;
    c.detailTextLabel.textColor = ED_DIM;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    NSMutableDictionary *lp = self.script.loop;
    if (ip.row == 0) {
        c.textLabel.text = @"循环整个脚本";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [lp[@"on"] boolValue];
        sw.onTintColor = ED_GREEN;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if (ip.row == 1) {
        c.textLabel.text = @"循环次数";
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 110, 30)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = ED_GREEN;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.tag = 1;
        tf.text = [NSString stringWithFormat:@"%ld", (long)[lp[@"count"] integerValue]];
        tf.placeholder = @"0 = 无限";
        [tf addTarget:self action:@selector(numChanged:) forControlEvents:UIControlEventEditingChanged];
        c.accessoryView = tf;
    } else {
        c.textLabel.text = @"每轮间隔";
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 110, 30)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.textColor = ED_GREEN;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.tag = 2;
        tf.text = [NSString stringWithFormat:@"%.0f", [lp[@"gap"] doubleValue]];
        tf.placeholder = @"毫秒";
        [tf addTarget:self action:@selector(numChanged:) forControlEvents:UIControlEventEditingChanged];
        c.accessoryView = tf;
    }
    return c;
}

- (void)switchChanged:(UISwitch *)sw {
    self.script.loop[@"on"] = @(sw.on);
    [self commit];
    [self.tableView reloadData];
}

- (void)numChanged:(UITextField *)tf {
    if (tf.tag == 1) self.script.loop[@"count"] = @([tf.text integerValue]);
    else             self.script.loop[@"gap"] = @(MAX(0, [tf.text doubleValue]));
    [self commit];
}

@end

#pragma mark - 判断编辑（识图找不到时做什么）

@interface TDFailsafeVC : UITableViewController
@property (nonatomic, strong) TDScript *script;
@end

@implementation TDFailsafeVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"判断";
    self.tableView.backgroundColor = ED_BG;
    self.tableView.separatorColor = ED_LINE;
    self.navigationController.navigationBar.tintColor = ED_GREEN;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onDataChanged)
                                                 name:TDDataChangedNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 留着回调没清，下一次「正常录制」会把步骤喂给一个已经没了的页面，
    // 结果就是录完什么都没存下来。没在录 = 这个回调一定是废的。
    TDRecorder *r = [TDRecorder shared];
    if (r.onStepsReady && !r.recording) r.onStepsReady = nil;
}

- (void)onDataChanged {
    // 录兜底动作是在抖音里结束的，回来这一页要自己刷新
    [self.tableView reloadData];
}

- (NSMutableDictionary *)fs { return self.script.failsafe; }
- (BOOL)on { return [[self fs][@"on"] boolValue]; }
- (NSInteger)pos { return [[self fs][@"pos"] integerValue]; }

- (NSMutableArray *)steps {
    id a = [self fs][@"steps"];
    if (![a isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *m = [NSMutableArray array];
        [self fs][@"steps"] = m;
        return m;
    }
    return a;
}

- (void)commit {
    [[TDScriptStore shared] save];
    [self.tableView reloadData];
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;              // 启用 + 只触发一次 + 在哪儿判断
    if (s == 1) return [self on] ? 3 : 0;
    return [self on] ? (NSInteger)[self steps].count : 0;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"判断";
    if (s == 1) return @"找不到图时做这些（兜底动作）";
    return [self steps].count ? @"兜底步骤 · 点一行改它，左滑删" : nil;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) {
        return @"「找不到自定义识图图片」时不再只是跳过：会先跑一遍下面的兜底动作，再继续主脚本。\n"
                "目标模板留空 = 任何一个识图失败都算。\n\n"
                "在哪判断：\n"
                "· 识图失败 → 跑到那一步发现没图上，当场做兜底（原来的行为）\n"
                "· 脚本开始 → 每轮开跑前先看一眼画面，图不在就先做兜底再跑主脚本\n"
                "· 脚本末尾 → 每轮跑完再检查，图不在就补一段兜底（刷完一条再判断用这个）";
    }
    if (s == 1) {
        return @"兜底动作就是你录下来的真实操作，录完会自动带上随机（位置 ±8pt / 时长 ±20% / 间隔 ±30%）。\n"
                "录的时候按音量上开始、音量下结束，人在抖音里正常做动作就行。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.backgroundColor = ED_CARD;
    c.textLabel.textColor = ED_TEXT;
    c.detailTextLabel.textColor = ED_DIM;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = @"启用判断";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [self on];
            sw.onTintColor = ED_GREEN;
            [sw addTarget:self action:@selector(onChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else if (ip.row == 1) {
            c.textLabel.text = @"只触发一次";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[self fs][@"once"] boolValue];
            sw.onTintColor = ED_YELL;
            [sw addTarget:self action:@selector(onceChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.detailTextLabel.text = @"关 = 每次找不到都兜底";
        } else {
            c.textLabel.text = @"在哪判断";
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:
                                       @[@"识图失败", @"脚本开始", @"脚本末尾"]];
            seg.frame = CGRectMake(0, 0, 208, 30);
            if (@available(iOS 13.0, *)) {
                seg.selectedSegmentTintColor = ED_CARD;
                [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: ED_TEXT}
                                   forState:UIControlStateSelected];
                [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: ED_DIM}
                                   forState:UIControlStateNormal];
            }
            seg.tintColor = ED_ACCENT;
            seg.selectedSegmentIndex = MIN(2, MAX(0, [self pos]));
            [seg addTarget:self action:@selector(posChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = seg;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return c;
    }

    if (ip.section == 1) {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (ip.row == 0) {
            c.textLabel.text = @"● 录一段兜底动作";
            c.textLabel.textColor = ED_RED;
            c.detailTextLabel.text = [NSString stringWithFormat:
                                      @"音量上开始 / 音量下结束 · 现在 %lu 步",
                                      (unsigned long)[self steps].count];
        } else if (ip.row == 1) {
            c.textLabel.text = @"＋ 手动加一步";
            c.detailTextLabel.text = @"比如「上滑一条」「点评论按钮」";
        } else {
            c.textLabel.text = @"⚡ 全部加随机";
            c.textLabel.textColor = ED_YELL;
            c.detailTextLabel.text = @"位置 ±8pt · 时长 ±20% · 间隔 ±30%";
        }
        return c;
    }

    // 兜底步骤
    NSDictionary *st = [self steps][ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%ld  %@", (long)(ip.row + 1),
                        [TDScript describeStep:st]];
    NSDictionary *r = [st[@"rnd"] isKindOfClass:[NSDictionary class]] ? st[@"rnd"] : nil;
    NSString *rnd = r ? [NSString stringWithFormat:@" · 随机 %.0f%%", [r[@"p"] doubleValue] * 100] : @" · 无随机";
    c.detailTextLabel.text = [NSString stringWithFormat:@"间隔 %.0fms%@", [st[@"gap"] doubleValue], rnd];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    return c;
}

- (void)onChanged:(UISwitch *)sw {
    [self fs][@"on"] = @(sw.on);
    [self commit];
}

- (void)onceChanged:(UISwitch *)sw {
    [self fs][@"once"] = @(sw.on);
    [self commit];
}

- (void)posChanged:(UISegmentedControl *)seg {
    [self fs][@"pos"] = @(MAX(0, seg.selectedSegmentIndex));
    [self commit];
    NSString *where = @[@"识图失败当场", @"每轮脚本开始", @"每轮脚本末尾"][MIN(2, seg.selectedSegmentIndex)];
    TDLog(@"判断位置：%@", where);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        if (ip.row == 0) [self recordAction];
        else if (ip.row == 1) [self addStep];
        else [self randomizeAll];
        return;
    }
    if (ip.section == 2) { [self editStepAtIndex:ip.row]; return; }
}

- (void)alertTitle:(NSString *)t message:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/// 录兜底动作：走穿透录制，录完不建新脚本，直接填进这里
- (void)recordAction {
    TDRecorder *r = [TDRecorder shared];
    if (r.recording) { [self alertTitle:@"正在录" message:@"先按音量下结束当前这次录制"]; return; }
    if ([TDEngine shared].running) [[TDEngine shared] stop];

    __weak typeof(self) ws = self;
    r.onStepsReady = ^(NSArray<NSDictionary *> *steps) {
        typeof(self) ss = ws;
        if (!ss) return;
        [ss appendRecorded:steps];
    };
    if (![r startLive]) {
        r.onStepsReady = nil;
        [self alertTitle:@"录制起不来" message:[r status]];
        return;
    }
    [self alertTitle:@"开始录兜底动作"
             message:@"现在切到抖音，把「找不到图时该做的事」做一遍（比如上滑一条、点一下评论），"
                      "做完按音量下结束。\n\n录完会自动填进这里，并带上随机偏移。"];
}

- (void)appendRecorded:(NSArray<NSDictionary *> *)steps {
    if (steps.count == 0) return;
    NSMutableArray *arr = [self steps];
    for (NSDictionary *d in steps) {
        NSMutableDictionary *m = [d mutableCopy];
        if (![m[@"rnd"] isKindOfClass:[NSDictionary class]]) m[@"rnd"] = TDDefaultFailsafeRnd();
        [arr addObject:m];
    }
    [self commit];
    TDLog(@"兜底动作已更新：%lu 步", (unsigned long)arr.count);
}

- (void)addStep {
    __weak typeof(self) ws = self;
    TDPresentKindSheet(self, @"加一步兜底动作", ^(NSInteger k) {
        typeof(self) ss = ws;
        if (!ss) return;
        NSMutableDictionary *d = TDNewStepOfKind(k);
        d[@"rnd"] = TDDefaultFailsafeRnd();
        [ss.steps addObject:d];
        NSInteger idx = (NSInteger)[ss steps].count - 1;
        TDPresentStepEditor(ss, d, YES, ^{
            [[TDScriptStore shared] save];
            [ss.tableView reloadData];
        }, ^{
            if (idx < (NSInteger)[ss steps].count) {
                [[ss steps] removeObjectAtIndex:idx];
                [[TDScriptStore shared] save];
                [ss.tableView reloadData];
            }
        });
    });
}

- (void)randomizeAll {
    NSMutableArray *arr = [self steps];
    if (arr.count == 0) { [self alertTitle:@"还没有兜底步骤" message:nil]; return; }
    for (NSMutableDictionary *d in arr) {
        if (![d isKindOfClass:[NSMutableDictionary class]]) continue;
        NSDictionary *old = [d[@"rnd"] isKindOfClass:[NSDictionary class]] ? d[@"rnd"] : nil;
        NSMutableDictionary *r = old ? [old mutableCopy] : [NSMutableDictionary dictionary];
        if (!r[@"p"]) r[@"p"] = @1.0;
        if ([r[@"px"] doubleValue] < 1) r[@"px"] = @8;
        if (!r[@"ms"]) r[@"ms"] = @0.2;
        if (!r[@"gap"]) r[@"gap"] = @0.3;
        d[@"rnd"] = r;
    }
    [self commit];
    [self alertTitle:@"已加随机" message:@"位置 ±8pt、时长 ±20%、间隔 ±30%。想更细可以点进单步改。"];
}

- (void)editStepAtIndex:(NSInteger)idx {
    NSMutableArray *arr = [self steps];
    if (idx < 0 || idx >= (NSInteger)arr.count) return;
    NSMutableDictionary *d = arr[idx];
    if (![d isKindOfClass:[NSMutableDictionary class]]) {
        d = [d mutableCopy];
        arr[idx] = d;
    }
    __weak typeof(self) ws = self;
    TDPresentStepEditor(self, d, NO, ^{
        typeof(self) ss = ws;
        [[TDScriptStore shared] save];
        [ss.tableView reloadData];
    }, ^{
        typeof(self) ss = ws;
        if (idx < (NSInteger)[ss steps].count) {
            [[ss steps] removeObjectAtIndex:idx];
            [[TDScriptStore shared] save];
            [ss.tableView reloadData];
        }
    });
}

@end

#pragma mark - 评论池

@interface TDPoolVC : UIViewController
@end

@implementation TDPoolVC {
    UITextView *_tv;
    UILabel *_hint;
    UIButton *_tryBtn;
    UIButton *_modeBtn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"评论池";
    self.view.backgroundColor = ED_BG;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(onSave)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onClose)];

    _hint = [[UILabel alloc] initWithFrame:CGRectZero];
    _hint.text = @"一行一条，回放时随机取一条。以 # 开头的行当备注，不参与随机。";
    _hint.font = [UIFont systemFontOfSize:12];
    _hint.textColor = ED_DIM;
    _hint.numberOfLines = 2;
    [self.view addSubview:_hint];

    _tv = [[UITextView alloc] initWithFrame:CGRectZero];
    _tv.backgroundColor = ED_CARD;
    _tv.textColor = ED_TEXT;
    _tv.font = [UIFont systemFontOfSize:15];
    _tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    _tv.layer.cornerRadius = 10;
    _tv.clipsToBounds = YES;
    _tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tv.text = [TDCommentPool() componentsJoinedByString:@"\n"];
    [self.view addSubview:_tv];

    _tryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_tryBtn setTitle:@"试粘贴一条" forState:UIControlStateNormal];
    [_tryBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _tryBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _tryBtn.backgroundColor = ED_ACCENT;
    _tryBtn.layer.cornerRadius = 10;
    [_tryBtn addTarget:self action:@selector(onTry) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_tryBtn];

    _modeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_modeBtn setTitleColor:ED_TEXT forState:UIControlStateNormal];
    _modeBtn.titleLabel.font = [UIFont systemFontOfSize:12.5];
    _modeBtn.titleLabel.numberOfLines = 2;
    _modeBtn.backgroundColor = ED_CARD;
    _modeBtn.layer.cornerRadius = 10;
    _modeBtn.layer.borderWidth = 1;
    _modeBtn.layer.borderColor = ED_LINE.CGColor;
    [_modeBtn addTarget:self action:@selector(onCycleMode) forControlEvents:UIControlEventTouchUpInside];
    // 点一下切方式；长按调「菜单偏移」—— 菜单没点准就靠这个救
    [_modeBtn addGestureRecognizer:
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onOffset:)]];
    [self.view addSubview:_modeBtn];
    [self refreshModeBtn];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets sa = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) sa = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat top = sa.top + 8;
    CGFloat bottom = h - sa.bottom;

    _hint.frame = CGRectMake(16, top, w - 32, 34);
    CGFloat tvTop = CGRectGetMaxY(_hint.frame) + 6;
    CGFloat barH = 46;
    _tv.frame = CGRectMake(14, tvTop, w - 28, bottom - barH - 14 - tvTop);

    _tryBtn.frame = CGRectMake(14, bottom - barH - 4, 140, barH);
    _modeBtn.frame = CGRectMake(162, bottom - barH - 4, w - 176, barH);
}

- (void)refreshModeBtn {
    NSString *extra = @"";
    if (TDPasteMethod() != 0) {
        CGPoint off = TDPasteMenuOffset();
        extra = [NSString stringWithFormat:@"  偏移 %.0f,%.0f", off.x, off.y];
    }
    [_modeBtn setTitle:[NSString stringWithFormat:@"粘贴方式：%@%@\n（点切换 · 长按调偏移）",
                        TDPasteMethodDesc(), extra]
              forState:UIControlStateNormal];
}

- (void)onCycleMode {
    NSInteger v = (TDPasteMethod() + 1) % 3;
    TDSetPasteMethod(v);
    [self refreshModeBtn];
    TDLog(@"粘贴方式切到：%@", TDPasteMethodDesc());
}

/// 长按「粘贴方式」：调编辑菜单的落点偏移（相对长按位置）
- (void)onOffset:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint off = TDPasteMenuOffset();

    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"菜单偏移"
                         message:@"长按输入框后系统弹出的「粘贴」菜单，相对长按点的位置。\n"
                                  "默认 0 / -62（正上方 62pt）。点偏了就往上下左右调几 pt。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"dx（左右，正数往右）";
        tf.text = [NSString stringWithFormat:@"%.0f", off.x];
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"dy（上下，负数往上）";
        tf.text = [NSString stringWithFormat:@"%.0f", off.y];
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        double dx = [a.textFields[0].text doubleValue];
        double dy = [a.textFields[1].text doubleValue];
        TDPasteSetMenuOffset((CGFloat)dx, (CGFloat)dy);
        [self refreshModeBtn];
        TDLog(@"菜单偏移改成 %.0f / %.0f", dx, dy);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSArray<NSString *> *)linesFromTV {
    NSMutableArray *out = [NSMutableArray array];
    [_tv.text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *s = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length) [out addObject:s];
    }];
    return out;
}

- (void)savePool {
    TDCommentPoolSet([self linesFromTV]);
}

- (void)onSave {
    [self.view endEditing:YES];
    [self savePool];
    [self alertTitle:@"已保存" message:[NSString stringWithFormat:@"池里现在 %ld 条可用话术。",
                                       (long)TDCommentPoolCount()]];
}

- (void)onClose {
    [self.view endEditing:YES];
    [self savePool];
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)onTry {
    [self.view endEditing:YES];
    [self savePool];
    NSString *txt = TDCommentPick();
    if (txt.length == 0) {
        [self alertTitle:@"池是空的" message:@"先写一条话术再试"];
        return;
    }

    NSString *show = txt.length > 16 ? [[txt substringToIndex:16] stringByAppendingString:@"…"] : txt;

    // Cmd+V 那种随时可点；长按菜单那种必须在抖音里做，所以给 4 秒切 App 的时间
    if (TDPasteMethod() == 0) {
        TDPasteText(txt);
        [self alertTitle:@"已发了一次 Cmd+V"
                 message:[NSString stringWithFormat:@"「%@」\n\n先切到抖音、点开输入框再来试，否则字没地方落。", show]];
        return;
    }
    if (!TDLastTapPointReady()) {
        [self alertTitle:@"还没有可用的落点"
                 message:@"长按菜单这种方式要知道输入框在哪儿。\n\n"
                          "先在抖音里跑一次脚本（哪怕只跑一步「点评论框」），"
                          "落点就记住了，再来试就有地方落。"];
        return;
    }

    __weak typeof(self) ws = self;
    [self alertTitle:@"4 秒后粘贴"
             message:[NSString stringWithFormat:@"「%@」\n\n现在切到抖音、把评论框点开（光标在框里），"
                       "4 秒后会在上次的落点上长按并点「粘贴」。", show]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) ss = ws;
        if (ss) TDPasteTextAt(txt, TDLastTapPoint());
    });
}

- (void)alertTitle:(NSString *)t message:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 循环 / 判断 / 评论池 都是子页面改的，回来要重新读一遍
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return (NSInteger)_script.steps.count;
    if (s == 1) return 3;      // 循环 / 判断 / 评论池
    return 4;                  // 加事件 / 试运行 / 模板库 / 设为当前
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) {
        return [NSString stringWithFormat:@"事件（%lu 个）· 点一行改它，左滑可插入/删除",
                (unsigned long)_script.steps.count];
    }
    if (s == 1) return @"脚本设置";
    return @"操作";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) {
        return @"判断：识图找不到图时，先跑一段兜底动作再继续。\n"
                "循环：整条脚本跑几遍、每轮之间歇多久。\n"
                "评论池：粘贴步骤随机取的话术。";
    }
    return nil;
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
        NSString *t = st[@"t"];
        NSString *mode = [t isEqualToString:@"find"] ? @"识图"
                       : [t isEqualToString:@"paste"] ? @"粘贴" : @"坐标";
        NSDictionary *r = [st[@"rnd"] isKindOfClass:[NSDictionary class]] ? st[@"rnd"] : nil;
        NSString *rnd = r ? [NSString stringWithFormat:@" · 随机 %.0f%%", [r[@"p"] doubleValue] * 100] : @"";
        NSString *skip = st[@"run"] ? [NSString stringWithFormat:@" · 执行 %.0f%%",
                                       [st[@"run"] doubleValue] * 100] : @"";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 间隔 %.0fms%@%@",
                                  mode, [st[@"gap"] doubleValue], skip, rnd];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSInteger fsn = (NSInteger)[_script failsafeSteps].count;
        if (ip.row == 0) {
            c.textLabel.text = @"⟳ 循环整个脚本";
            c.detailTextLabel.text = [_script loopDesc];
        } else if (ip.row == 1) {
            c.textLabel.text = @"⚖ 判断（识图找不到时）";
            NSInteger pos = [_script.failsafe[@"pos"] integerValue];
            NSString *where = @[@"当场", @"脚本开始", @"脚本末尾"][MIN(2, MAX(0, pos))];
            c.detailTextLabel.text = [_script failsafeEnabled]
                ? [NSString stringWithFormat:@"开 · %@判断 · 兜底 %ld 步 · %@", where, (long)fsn,
                   [_script.failsafe[@"once"] boolValue] ? @"只触发一次" : @"每次触发"]
                : @"关";
            c.textLabel.textColor = [_script failsafeEnabled] ? ED_YELL : ED_TEXT;
        } else {
            c.textLabel.text = @"💬 评论池";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%ld 条话术",
                                      (long)TDCommentPoolCount()];
        }
    } else {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        switch (ip.row) {
            case 0:
                c.textLabel.text = @"＋ 加一个事件（末尾）";
                c.detailTextLabel.text = @"点击 / 长按 / 滑动 / 等待 / 识图 / 粘贴 · 想插中间就左滑某一行";
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

    if (ip.section == 1) {
        if (ip.row == 0) {
            TDLoopVC *vc = [TDLoopVC new];
            vc.script = _script;
            [self.navigationController pushViewController:vc animated:YES];
        } else if (ip.row == 1) {
            TDFailsafeVC *vc = [TDFailsafeVC new];
            vc.script = _script;
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            TDPoolVC *vc = [TDPoolVC new];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [self presentViewController:nav animated:YES completion:nil];
        }
        return;
    }

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

/// 左滑：插入 / 删除。插入是「插到这一行的后面」——
/// 录完一整条再想补一步时，不用把后面的都重新弄一遍。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0) return nil;
    __weak typeof(self) ws = self;

    UIContextualAction *ins =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                title:@"插入"
                                              handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        typeof(self) ss = ws;
        if (ss) [ss insertStepAfter:ip.row];
        done(YES);
    }];
    ins.backgroundColor = ED_ACCENT;

    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        typeof(self) ss = ws;
        if (ss) [ss deleteStepAtIndex:ip.row];
        done(YES);
    }];

    return [UISwipeActionsConfiguration configurationWithActions:@[del, ins]];
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
    __weak typeof(self) ws = self;
    TDPresentKindSheet(self, @"加什么事件（加到末尾）", ^(NSInteger k) {
        typeof(self) ss = ws;
        if (ss) [ss insertStepAtIndex:(NSInteger)ss.script.steps.count kind:k];
    });
}

- (void)insertStepAfter:(NSInteger)idx {
    NSString *title = [NSString stringWithFormat:@"在第 %ld 步后面插入",
                       (long)(idx + 1)];
    __weak typeof(self) ws = self;
    TDPresentKindSheet(self, title, ^(NSInteger k) {
        typeof(self) ss = ws;
        if (ss) [ss insertStepAtIndex:idx + 1 kind:k];
    });
}

/// 在 pos 位置插一步，并立刻打开编辑页。取消编辑就算「没加」——
/// 不然列表里会留下一个用户根本没确认过的默认步骤。
- (void)insertStepAtIndex:(NSInteger)pos kind:(NSInteger)k {
    NSMutableDictionary *d = TDNewStepOfKind(k);
    if (pos < 0 || pos > (NSInteger)_script.steps.count) pos = (NSInteger)_script.steps.count;
    [_script.steps insertObject:d atIndex:(NSUInteger)pos];
    [[TDScriptStore shared] save];
    [self.tableView reloadData];

    __weak typeof(self) ws = self;
    TDPresentStepEditor(self, d, YES, ^{
        typeof(self) ss = ws;
        [[TDScriptStore shared] save];
        [ss.tableView reloadData];
    }, ^{
        typeof(self) ss = ws;
        [ss deleteStepAtIndex:pos];
    });
}

- (void)deleteStepAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_script.steps.count) return;
    [_script.steps removeObjectAtIndex:idx];
    [[TDScriptStore shared] save];
    [self.tableView reloadData];
}

- (void)tryRun {
    if (_script.steps.count == 0) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"试运行"
                                                              message:@"3 秒后开始，现在切到抖音。\n按这条脚本自己的循环 / 判断设置跑。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *x) {
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) ss = ws;
            if (!ss) return;
            [[TDEngine shared] playScript:ss.script];
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
    nav.navigationBar.barStyle = UIBarStyleDefault;
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
