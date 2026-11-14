#import "TD.h"

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <objc/message.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 远程调试通道
//
//   手机  →  自己的服务器（PHP 文件接口）  →  我这边的脚本
//
//   设备 → 服务器（POST api.php action=write）
//     ./tapdog/dbg/state.json   状态：版本 / 屏幕 / 引擎 / 录制 / 最近日志
//     ./tapdog/dbg/shot.jpg     截图：被要求时上传，或 auto 模式定时上传
//     ./tapdog/dbg/ack.json     每条命令的执行结果
//
//   服务器 → 设备（GET 静态文件，带 ?t= 破缓存）
//     ./tapdog/dbg/cmd.json     命令
//
// 为什么走「文件」而不是长连接：这台服务器只开放了一个 PHP 文件接口，
// 不保证有 WebSocket / 常驻进程；而命令是覆盖写，天然就是「只执行最新一条」。
// 轮询 1.4 秒一次；命令带 ts，超过 90 秒的旧命令直接丢弃 ——
// 否则设备离线几小时后再上线，会把一条早就过期的点击补执行掉。
// ---------------------------------------------------------------------------

static NSString *const kTDDefaultBase = @"http://211.154.18.252:39888/agent";
static NSString *const kTDDefaultToken = @"123123.aA";

static NSMutableArray<NSString *> *gRing = nil;
static NSLock *gRingLock = nil;
static NSString *gStat = @"未启动";
static NSString *gLastErr = @"";
static double gLastOkAt = 0;
static NSInteger gCmdCount = 0;
static NSInteger gShotCount = 0;

static void TDRemoteNote(NSString *s) {
    gStat = s ?: @"";
}

static void TDRingPush(NSString *line) {
    if (line.length == 0) return;
    if (!gRing) {
        gRing = [NSMutableArray array];
        gRingLock = [NSLock new];
    }
    [gRingLock lock];
    [gRing addObject:line.length > 220 ? [line substringToIndex:220] : line];
    while (gRing.count > 40) [gRing removeObjectAtIndex:0];
    [gRingLock unlock];
}

static NSArray<NSString *> *TDRingCopy(void) {
    if (!gRing) return @[];
    [gRingLock lock];
    NSArray *a = [gRing copy];
    [gRingLock unlock];
    return a;
}

#pragma mark - 配置

NSString *TDRemoteBase(void) {
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"tdRemoteBase"];
    return s.length ? s : kTDDefaultBase;
}

void TDRemoteSetBase(NSString *base) {
    NSString *s = [base stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    [[NSUserDefaults standardUserDefaults] setObject:s forKey:@"tdRemoteBase"];
}

BOOL TDRemoteEnabled(void) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    id v = [u objectForKey:@"tdRemoteEnabled"];
    return v ? [u boolForKey:@"tdRemoteEnabled"] : YES;   // 默认开：自有服务器，开箱即用
}

void TDRemoteSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"tdRemoteEnabled"];
    if (on) TDRemoteStart();
}

NSString *TDRemoteStatus(void) {
    NSString *s = gStat;
    if (gLastOkAt > 0) {
        double ago = [NSDate date].timeIntervalSince1970 - gLastOkAt;
        s = [NSString stringWithFormat:@"%@ · 上行 %.0fs 前 · 命令 %ld 条 · 截图 %ld 张",
             s, ago, (long)gCmdCount, (long)gShotCount];
    }
    if (gLastErr.length) s = [s stringByAppendingFormat:@" · 最近错误：%@", gLastErr];
    return s;
}

#pragma mark - HTTP

/// percent-encode 全部字节（只留 RFC3986 unreserved）。按字节编码，
/// 所以二进制图片也能直接塞进 form 的 content 字段 —— 这是服务器接口唯一支持的上传方式。
static NSString *TDPct(NSData *d) {
    if (d.length == 0) return @"";
    static const char *hex = "0123456789ABCDEF";
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length;
    NSMutableData *out = [NSMutableData dataWithCapacity:n * 3];
    for (NSUInteger i = 0; i < n; i++) {
        uint8_t c = b[i];
        BOOL keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
        if (keep) {
            [out appendBytes:&c length:1];
        } else {
            char t[3] = { '%', hex[c >> 4], hex[c & 0x0F] };
            [out appendBytes:t length:3];
        }
    }
    return [[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding] ?: @"";
}

static NSData *TDhttp(NSString *method, NSString *urlStr, NSData *body, double timeout) {
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) { gLastErr = @"URL 不合法"; return nil; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.timeoutInterval = timeout;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    r.HTTPMethod = method;
    if (body) {
        r.HTTPBody = body;
        [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [r setValue:kTDDefaultToken forHTTPHeaderField:@"X-API-Token"];
    }

    __block NSData *got = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithRequest:r
          completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        got = d;
        err = e;
        dispatch_semaphore_signal(sem);
    }];
    [t resume];
    long w = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                       (int64_t)(timeout * NSEC_PER_SEC)));
    if (w != 0) {
        [t cancel];
        gLastErr = @"超时";
        return nil;
    }
    if (err) {
        gLastErr = [NSString stringWithFormat:@"%@", err.localizedDescription ?: @"网络错误"];
        return nil;
    }
    return got;
}

/// POST 到 PHP 文件接口写一个文件，成功返回 YES（接口回 {"code":200,...}）
static BOOL TDput(NSString *name, NSData *bytes) {
    if (!bytes) return NO;
    NSString *path = [NSString stringWithFormat:@"./tapdog/dbg/%@", name];
    NSString *body = [NSString stringWithFormat:@"action=write&path=%@&content=%@",
                      TDPct([path dataUsingEncoding:NSUTF8StringEncoding]), TDPct(bytes)];
    NSData *resp = TDhttp(@"POST",
                          [TDRemoteBase() stringByAppendingString:@"/api.php"],
                          [body dataUsingEncoding:NSUTF8StringEncoding], 45);
    if (!resp) return NO;
    NSString *s = [[NSString alloc] initWithData:resp encoding:NSUTF8StringEncoding];
    if ([s containsString:@"\"code\":200"]) {
        gLastOkAt = [NSDate date].timeIntervalSince1970;
        gLastErr = @"";
        return YES;
    }
    gLastErr = s.length > 80 ? [s substringToIndex:80] : (s ?: @"响应为空");
    return NO;
}

static BOOL TDputJSON(NSString *name, NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    return TDput(name, d);
}

static NSDictionary *TDgetJSON(NSString *name) {
    NSString *url = [NSString stringWithFormat:@"%@/tapdog/dbg/%@?t=%.0f",
                     TDRemoteBase(), name, [NSDate date].timeIntervalSince1970 * 1000.0];
    NSData *d = TDhttp(@"GET", url, nil, 15);
    if (!d || d.length < 2) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [j isKindOfClass:[NSDictionary class]] ? (NSDictionary *)j : nil;
}

#pragma mark - 截图 / OCR

/// 本次截图用的像素排列（0=自动）。远程排查颜色时才临时改，平时都是 0。
static int gShotFmt = 0;

/// 截当前整屏，缩到指定宽度（0 = 不缩）。TDscreenshot 读的是 framebuffer，
/// 所以哪怕我们在后台、前台是抖音，抓到的也是用户看到的画面。
static UIImage *TDshotScaled(CGFloat maxW) {
    UIImage *img = TDscreenshotFmt(gShotFmt);
    if (!img) return nil;
    if (maxW <= 0 || img.size.width <= maxW) return img;
    CGFloat k = maxW / img.size.width;
    CGSize sz = CGSizeMake(floor(img.size.width * k), floor(img.size.height * k));
    UIGraphicsBeginImageContextWithOptions(sz, NO, 1.0);
    [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

/// 把裁下来的图标压成「黑底白图」。
///
/// 直接截一块图标，模板里必然混进当时的视频画面：换个视频，模板就对不上了 ——
/// 这是以前识图「时灵时不灵」的主要原因。图标本身是纯白的，所以只留亮像素、
/// 其余抹黑，模板就只剩形状，和背景彻底脱钩。
static UIImage *TDMono(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    if (w < 2 || h < 2) return nil;
    uint8_t *buf = calloc((size_t)w * (size_t)h, 1);
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    for (int i = 0; i < w * h; i++) buf[i] = (buf[i] >= 175) ? 255 : 0;
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!out) return nil;
    UIImage *r = [UIImage imageWithCGImage:out scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return r;
}

/// 颜色探针：铺一张 4x2 的纯色色带窗口，再直接读 framebuffer 的原始 4 字节。
///
/// 目的不是「看出来」而是「量出来」——iPhone 的主显示 surface 是 'b3a8'
/// （每通道 10 位挤在 32 位里），光看截图只能知道颜色不对，看不出字节怎么排。
/// 这里喂已知 RGB，把原始 4 字节原封不动带回来，就能反推准确的拆位方式。
/// 注意：画面必须是 TapDog 自己在前台，后台的窗口根本不会渲染到 framebuffer。
static NSDictionary *TDrunPatternProbe(void) {
    __block UIWindow *win = nil;
    __block int rows = 4, cols = 2;
    NSArray<NSString *> *hexes = @[@"FF0000", @"00FF00",
                                   @"0000FF", @"FFFFFF",
                                   @"000000", @"808080",
                                   @"FF8000", @"FF00FF"];
    CGSize scr = [UIScreen mainScreen].bounds.size;

    dispatch_sync(dispatch_get_main_queue(), ^{
        UIWindow *w = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, scr.width, scr.height)];
        w.windowLevel = UIWindowLevelAlert + 100;
        // 这个 App 是老的 AppDelegate 生命周期，没有 Scene 配置，窗口能直接显示；
        // 但万一哪天加了 Scene，不挂 windowScene 的窗口是不会渲染的，先兼容一下。
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)s; break; }
        }
        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = [UIColor blackColor];
        w.rootViewController = root;
        CGFloat cw = scr.width / cols, ch = scr.height / rows;
        for (int i = 0; i < rows * cols; i++) {
            unsigned int v = 0;
            sscanf(hexes[i].UTF8String, "%x", &v);
            UIView *v2 = [[UIView alloc] initWithFrame:CGRectMake((i % cols) * cw,
                                                                 (i / cols) * ch, cw, ch)];
            v2.backgroundColor = [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                                                 green:((v >> 8) & 0xFF) / 255.0
                                                  blue:(v & 0xFF) / 255.0 alpha:1];
            [root.view addSubview:v2];
        }
        w.hidden = NO;
        win = w;
    });

    usleep(600 * 1000);   // 等两帧，framebuffer 里才是新画面

    CGFloat cw = scr.width / cols, ch = scr.height / rows;
    uint32_t fmt = 0; size_t bpr = 0, pw = 0, ph = 0;
    uint8_t probe[4] = {0, 0, 0, 0};
    TDpeekRaw(0, 0, probe, &fmt, &bpr, &pw, &ph);           // 先量一次拿到像素尺寸
    CGFloat k = (pw > 0 && scr.width > 0) ? (pw / scr.width) : 3.0;   // 点 → 像素
    NSMutableArray *samples = [NSMutableArray array];
    for (int i = 0; i < rows * cols; i++) {
        int px = (int)(((i % cols) * cw + cw * 0.5) * k);
        int py = (int)(((i / cols) * ch + ch * 0.5) * k);
        uint8_t b[4] = {0, 0, 0, 0};
        BOOL ok = TDpeekRaw(px, py, b, &fmt, &bpr, &pw, &ph);
        [samples addObject:@{@"want": hexes[i],
                             @"px": @(px), @"py": @(py), @"ok": @(ok),
                             @"raw": ok ? [NSString stringWithFormat:@"%02x%02x%02x%02x",
                                           b[0], b[1], b[2], b[3]] : @"-"}];
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        win.hidden = YES;
        win = nil;
    });

    char fc[5] = { (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, 0 };
    return @{@"fmt": [NSString stringWithFormat:@"%s", fc],
             @"fmtHex": [NSString stringWithFormat:@"0x%08x", fmt],
             @"bpr": @(bpr), @"w": @(pw), @"h": @(ph),
             @"fg": @([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive),
             @"samples": samples,
             @"msg": [NSString stringWithFormat:@"探针完成 · 格式 '%s' %zux%zu bpr %zu", fc, pw, ph, bpr]};
}

static BOOL TDuploadShot(CGFloat maxW, CGFloat quality) {
    UIImage *img = TDshotScaled(maxW);
    if (!img) { gLastErr = [NSString stringWithFormat:@"截屏失败：%@", TDcaptureStatus()]; return NO; }
    NSData *jpg = UIImageJPEGRepresentation(img, quality);
    if (!jpg) { gLastErr = @"JPEG 编码失败"; return NO; }
    BOOL ok = TDput(@"shot.jpg", jpg);
    if (ok) gShotCount++;
    return ok;
}

/// 用 Vision 认字，返回 [{s,x,y,w,h}]（屏幕点）。远程看不见「字」的时候，
/// 靠它找「评论」「说点什么」「发送」这类按钮，比反复截猜坐标靠谱得多。
NSArray<NSDictionary *> *TDocrLines(UIImage *img) {
    if (!img.CGImage) return @[];
    NSMutableArray *out = [NSMutableArray array];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;
    if (@available(iOS 14.0, *)) req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    NSError *err = nil;
    if (![h performRequests:@[req] error:&err]) {
        gLastErr = [NSString stringWithFormat:@"OCR 失败：%@", err.localizedDescription ?: @"?"];
        return @[];
    }
    CGFloat pxW = CGImageGetWidth(img.CGImage);
    CGFloat pxH = CGImageGetHeight(img.CGImage);
    CGFloat ptW = [UIScreen mainScreen].bounds.size.width ?: 414;
    CGFloat k = pxW > 0 ? ptW / pxW : 1;
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *t = [o topCandidates:1].firstObject;
        if (!t.string.length) continue;
        CGRect bb = o.boundingBox;      // 归一化，原点左下
        CGFloat cx = (bb.origin.x + bb.size.width / 2) * pxW * k;
        CGFloat cy = (1.0 - bb.origin.y - bb.size.height / 2) * pxH * k;
        [out addObject:@{@"s": t.string,
                         @"x": @(lround(cx)), @"y": @(lround(cy)),
                         @"w": @(lround(bb.size.width * pxW * k)),
                         @"h": @(lround(bb.size.height * pxH * k))}];
    }
    return out;
}

#pragma mark - 状态

static NSDictionary *TDstateDict(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    CGSize pt = [UIScreen mainScreen].bounds.size;
    // 像素尺寸用换算比反推，不为了报个尺寸去截一张 8MB 的全屏图
    CGFloat ratio = TDscreenScaleRatio();
    if (ratio <= 0) ratio = 1.0 / 3.0;
    CGFloat pxw = pt.width / ratio;
    CGFloat pxh = pt.height / ratio;
    TDEngine *e = [TDEngine shared];
    TDRecorder *r = [TDRecorder shared];
    TDScript *sel = [[TDScriptStore shared] selectedScript];

    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    m[@"v"] = info[@"CFBundleShortVersionString"] ?: @"?";
    m[@"build"] = info[@"CFBundleVersion"] ?: @"?";
    m[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    m[@"dev"] = [[UIDevice currentDevice] name] ?: @"iPhone";
    m[@"sys"] = [NSString stringWithFormat:@"%@ %@", [UIDevice currentDevice].systemName,
                 [UIDevice currentDevice].systemVersion];
    m[@"screen"] = @{@"w": @(lround(pt.width)), @"h": @(lround(pt.height)),
                     @"pxw": @(lround(pxw)), @"pxh": @(lround(pxh)),
                     @"ratio": @(ratio)};
    m[@"engine"] = @{@"running": @(e.running), @"loops": @(e.loopsDone),
                     @"step": @(e.stoppedStep)};
    m[@"rec"] = @{@"on": @(r.recording), @"steps": @(r.eventCount)};
    m[@"script"] = @{@"name": sel.name ?: @"", @"steps": @(sel.steps.count),
                     @"sel": @([[TDScriptStore shared] selected])};
    m[@"cap"] = TDcaptureStatus() ?: @"?";
    m[@"alive"] = [TDKeepAlive status] ?: @"?";
    m[@"sandbox"] = TDSandboxStatus() ?: @"?";
    m[@"inject"] = @(TDInjectCount());
    m[@"floatbar"] = NSStringFromCGRect(TDFloatTouchRect());
    m[@"log"] = TDRingCopy();
    m[@"ncmd"] = @(gCmdCount);
    m[@"nshot"] = @(gShotCount);
    return m;
}

#pragma mark - 命令执行

/// 命令在后台串行队列上执行；只有 openURL 那条自己 dispatch_async 回主线程。
/// 网络（上传截图/状态）和计算（OCR/识图）绝不能占主线程 —— 会被 watchdog 杀掉。
/// 返回值：ok / msg，另有 shot=1 表示「执行完再传一张截图」。
static NSDictionary *TDexecCommand(NSDictionary *cmd) {
    NSString *c = [cmd[@"c"] isKindOfClass:[NSString class]] ? cmd[@"c"] : @"";

    if ([c isEqualToString:@"tap"] || [c isEqualToString:@"long"]) {
        CGFloat x = [cmd[@"x"] doubleValue];
        CGFloat y = [cmd[@"y"] doubleValue];
        if (x < 1 || y < 1) return @{@"ok": @0, @"msg": @"坐标缺失"};
        CGRect fb = TDFloatTouchRect();
        if (CGRectContainsPoint(CGRectInset(fb, -6, -6), CGPointMake(x, y))) {
            return @{@"ok": @0, @"msg": @"落点压在悬浮条上，会点到自己的按钮"};
        }
        if ([c isEqualToString:@"tap"]) {
            TDtap(x, y);
            TDLog(@"远程调试：点 (%.0f,%.0f)", x, y);
            return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"tap %.0f,%.0f", x, y],
                     @"shot": @1};
        }
        double ms = cmd[@"ms"] ? [cmd[@"ms"] doubleValue] : 800;
        TDlongPress(x, y, MAX(150.0, ms) / 1000.0);
        TDLog(@"远程调试：长按 (%.0f,%.0f) %.0fms", x, y, ms);
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"long %.0f,%.0f", x, y], @"shot": @1};
    }

    if ([c isEqualToString:@"swipe"]) {
        CGPoint a = CGPointMake([cmd[@"x1"] doubleValue], [cmd[@"y1"] doubleValue]);
        CGPoint b = CGPointMake([cmd[@"x2"] doubleValue], [cmd[@"y2"] doubleValue]);
        if (a.x < 1 || a.y < 1 || b.x < 1 || b.y < 1) return @{@"ok": @0, @"msg": @"坐标缺失"};
        double ms = cmd[@"ms"] ? [cmd[@"ms"] doubleValue] : 320;
        TDswipe(a, b, MAX(120.0, ms) / 1000.0);
        TDLog(@"远程调试：滑 (%.0f,%.0f)→(%.0f,%.0f)", a.x, a.y, b.x, b.y);
        return @{@"ok": @1, @"msg": @"swipe", @"shot": @1};
    }

    // 从屏幕左边缘往右滑 = 系统返回手势（抖音里就是退出当前页）
    if ([c isEqualToString:@"back"]) {
        CGFloat w = [UIScreen mainScreen].bounds.size.width;
        CGFloat h = [UIScreen mainScreen].bounds.size.height;
        TDswipe(CGPointMake(1, h * 0.5), CGPointMake(MIN(w * 0.75, 320), h * 0.5), 0.25);
        return @{@"ok": @1, @"msg": @"back", @"shot": @1};
    }

    if ([c isEqualToString:@"text"]) {
        NSString *s = [cmd[@"s"] isKindOfClass:[NSString class]] ? cmd[@"s"] : @"";
        if (s.length == 0) return @{@"ok": @0, @"msg": @"文本为空"};
        CGPoint at = CGPointMake([cmd[@"x"] doubleValue], [cmd[@"y"] doubleValue]);
        NSInteger mode = cmd[@"mode"] ? [cmd[@"mode"] integerValue] : -1;
        TDPasteTextAtMode(s, at, mode);      // 写剪贴板 + 按指定方式落字
        TDLog(@"远程调试：输入 %lu 字（方式 %@）", (unsigned long)s.length, @(mode));
        return @{@"ok": @1, @"msg": @"text", @"shot": @1};
    }

    if ([c isEqualToString:@"env"]) {
        // 剪贴板体检：写一次、主线程读、后台读，连 uid 一起带回
        NSDictionary *d = TDclipDiagnose();
        gCmdCount++;
        TDputJSON(@"env.json", d);
        return @{@"ok": @1,
                 @"msg": [NSString stringWithFormat:@"uid=%@ ok=%@ read=%@ items=%@ types=%@",
                          d[@"uid"], d[@"ok"], d[@"readMain"], d[@"items"], d[@"types"]]};
    }

    if ([c isEqualToString:@"clipget"]) {
        // 只读剪贴板内容，确认别的 App 写进去的东西我们看不看得到
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"剪贴板=「%@」",
                                     TDPasteClipboardText()]};
    }

    if ([c isEqualToString:@"clipset"]) {
        // 诊断：抖音在前台（我们处于后台）时，到底能不能写进系统剪贴板
        NSString *s = [cmd[@"s"] isKindOfClass:[NSString class]] ? cmd[@"s"] : @"TDRC探针";
        NSArray<NSString *> *r = TDclipTryWrite(s);
        gCmdCount++;
        TDputJSON(@"clipset.json", @{@"text": s, @"steps": r});
        return @{@"ok": @1, @"msg": [r componentsJoinedByString:@" | "]};
    }

    if ([c isEqualToString:@"kbd"]) {
        // HID 键盘直打（只能打 ASCII）。用来验「键盘通道」到底通不通：
        // 打得出来说明 Cmd+V 那条路也能用，打不出来就只能靠点屏幕输入。
        NSString *s = [cmd[@"s"] isKindOfClass:[NSString class]] ? cmd[@"s"] : @"abc";
        TDtypeASCII(s);
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"kbd %@", s], @"shot": @1};
    }

    if ([c isEqualToString:@"open"]) {
        NSString *u = [cmd[@"url"] isKindOfClass:[NSString class]] ? cmd[@"url"] : @"snssdk1128://";
        NSURL *url = [NSURL URLWithString:u];
        if (!url) return @{@"ok": @0, @"msg": @"url 不合法"};
        // openURL 必须在主线程；用 async 丢过去，不占住主线程等它返回 ——
        // 换成 sync 的话，这里会一直堵到 SpringBoard 把 App 唤起来为止。
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        });
        // openURL 这条在后台常被系统忽略（实测只有自己 active 时才灵），
        // 所以再补一条 LSApplicationWorkspace 强拉：按 bundle id 直接开。
        // 之前远程调试时「open snssdk1128:// 没反应」就是缺这一条。
        NSString *bid = [cmd[@"bid"] isKindOfClass:[NSString class]] ? cmd[@"bid"] : nil;
        if (bid.length == 0) {
            if ([u hasPrefix:@"snssdk1128"]) bid = @"com.ss.iphone.ugc.Aweme";
            else if ([u hasPrefix:@"tapdog"]) bid = @"com.local.tapdog";
        }
        if (bid.length) {
            Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
            if (wsCls) {
                id (*m0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                void (*m1)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                id ws = m0(wsCls, sel_registerName("defaultWorkspace"));
                if (ws) m1(ws, sel_registerName("openApplicationWithBundleID:"), bid);
            }
        }
        TDLog(@"远程调试：打开 %@", u);
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"open %@", u]};
    }

    // 注入通道切换：sender 从哪来（不设 / 学到的 / 指定）+ tap 走哪条投递路径。
    // 现象都一样（点了没反应）但原因完全不同，靠这个几秒钟扫完组合。
    if ([c isEqualToString:@"injmode"]) {
        NSInteger m = cmd[@"s"] ? [cmd[@"s"] integerValue] : 1;
        uint64_t sid = 0;
        if (cmd[@"sid"]) {
            NSString *hx = [cmd[@"sid"] description];
            sid = strtoull(hx.UTF8String, NULL, 0);
        }
        BOOL re = cmd[@"re"] ? ([cmd[@"re"] intValue] != 0) : YES;
        TDInjSetMode(m, sid, re);
        gCmdCount++;
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @1,
                                 @"msg": TDInjModeDesc(), @"ts": @(now)});
        return;
    }

    // 注入链路体检：senderID / 监听到的真实事件 / 回显 / 权限 / 签名，
    // 一条命令看全。之前的「点了没反应」全靠猜，现在有数字可对。
    if ([c isEqualToString:@"diag"]) {
        return @{@"ok": @1, @"msg": TDHIDDiagReport()};
    }

    if ([c isEqualToString:@"paste"]) {
        // 自前台写剪贴板 → 切回目标 App → 点输入框 → ⌘A → ⌘V，一条命令走完
        NSString *s = [cmd[@"s"] isKindOfClass:[NSString class]] ? cmd[@"s"] : @"";
        if (s.length == 0) return @{@"ok": @0, @"msg": @"文本为空"};
        NSString *app = [cmd[@"app"] isKindOfClass:[NSString class]] ? cmd[@"app"] : @"snssdk1128://";
        BOOL needTap = [cmd[@"tap"] boolValue];
        CGPoint at = CGPointMake([cmd[@"x"] doubleValue], [cmd[@"y"] doubleValue]);
        BOOL ok = TDPasteIntoOtherApp(s, app, needTap && at.x > 0 && at.y > 0, at,
                                      [cmd[@"clear"] boolValue]);
        // 调试用：不切 App、只写剪贴板看看写得进去不
        if (![cmd[@"self"] boolValue] && cmd[@"self"]) {
            ok = TDPasteCopyToClipboard(s);
        }
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"paste 剪贴板%@ state=%ld",
                                     ok ? @"✓" : @"✗",
                                     (long)[UIApplication sharedApplication].applicationState],
                 @"shot": @1};
    }

    if ([c isEqualToString:@"putscript"]) {
        // PC 上拼好的脚本推进来：{c:"putscript", name, steps:[…], loop:{on,count,gap}}
        // 调试脚本时不用在手机上一步步点，改一版推一版。
        NSString *name = [cmd[@"name"] isKindOfClass:[NSString class]] ? cmd[@"name"] : @"远程脚本";
        NSArray *steps = [cmd[@"steps"] isKindOfClass:[NSArray class]] ? cmd[@"steps"] : @[];
        TDScriptStore *store = [TDScriptStore shared];
        TDScript *target = nil;
        for (TDScript *sc in store.scripts) {
            if ([sc.name isEqualToString:name]) { target = sc; break; }
        }
        if (!target) {
            target = [store createScript];
            target.name = name;
        }
        [target.steps removeAllObjects];
        for (id st in steps) {
            if ([st isKindOfClass:[NSDictionary class]]) [target.steps addObject:[st mutableCopy]];
        }
        if ([cmd[@"loop"] isKindOfClass:[NSDictionary class]]) {
            target.loop = [cmd[@"loop"] mutableCopy];
        }
        // 顺带能把评论池一起灌进来（一行一条），省得在手机上一条条敲
        if ([cmd[@"pool"] isKindOfClass:[NSArray class]]) {
            NSMutableArray *lines = [NSMutableArray array];
            for (id ln in cmd[@"pool"]) {
                if ([ln isKindOfClass:[NSString class]] && [ln length]) [lines addObject:ln];
            }
            TDCommentPoolSet(lines);
            TDLog(@"远程调试：评论池写入 %lu 条", (unsigned long)lines.count);
        }
        NSInteger idx = (NSInteger)[store.scripts indexOfObjectIdenticalTo:target];
        if (idx >= 0) store.selected = idx;
        [store save];
        TDLog(@"远程调试：写入脚本「%@」%lu 步", name, (unsigned long)target.steps.count);
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"脚本「%@」已写入 %lu 步%s",
                                     name, (unsigned long)target.steps.count,
                                     idx >= 0 ? "，已选中" : ""]};
    }

    if ([c isEqualToString:@"run"] || [c isEqualToString:@"stop"]) {
        TDEngine *e = [TDEngine shared];
        if ([c isEqualToString:@"stop"]) { [e stop]; return @{@"ok": @1, @"msg": @"stopped", @"shot": @1}; }
        TDScript *s = [[TDScriptStore shared] selectedScript];
        if (!s || s.steps.count == 0) return @{@"ok": @0, @"msg": @"没有脚本"};
        [e playScript:s];
        return @{@"ok": @1, @"msg": @"running", @"shot": @1};
    }

    if ([c isEqualToString:@"script"]) {
        TDScriptStore *st = [TDScriptStore shared];
        NSString *name = [cmd[@"name"] isKindOfClass:[NSString class]] ? cmd[@"name"] : nil;
        NSInteger idx = -1;
        if (name.length) {
            for (NSInteger i = 0; i < (NSInteger)st.scripts.count; i++) {
                if ([st.scripts[i].name isEqualToString:name]) { idx = i; break; }
            }
        } else if (cmd[@"i"]) {
            idx = [cmd[@"i"] integerValue];
        }
        if (idx < 0 || idx >= (NSInteger)st.scripts.count) {
            return @{@"ok": @0, @"msg": [NSString stringWithFormat:@"没有这条脚本（%lu 条）",
                                          (unsigned long)st.scripts.count]};
        }
        st.selected = idx;
        [st save];
        [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
        TDFloatRefresh();
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"切到 %@", st.scripts[idx].name]};
    }

    // 从当前画面裁一块存成模板，方便远程「现场造图」再拿去找
    if ([c isEqualToString:@"tpl"]) {
        NSString *name = [cmd[@"name"] isKindOfClass:[NSString class]] ? cmd[@"name"] : @"tpl_remote.png";
        if (![name hasSuffix:@".png"]) name = [name stringByAppendingString:@".png"];
        UIImage *shot = TDscreenshot();
        if (!shot.CGImage) return @{@"ok": @0, @"msg": @"截屏失败"};
        CGFloat k = shot.size.width / [UIScreen mainScreen].bounds.size.width;
        CGRect r = CGRectMake([cmd[@"x"] doubleValue] * k, [cmd[@"y"] doubleValue] * k,
                              [cmd[@"w"] doubleValue] * k, [cmd[@"h"] doubleValue] * k);
        CGImageRef sub = CGImageCreateWithImageInRect(shot.CGImage, r);
        if (!sub) return @{@"ok": @0, @"msg": @"裁剪失败（框出界了？）"};
        UIImage *one = [UIImage imageWithCGImage:sub scale:1 orientation:UIImageOrientationUp];
        CGImageRelease(sub);
        BOOL mono = [cmd[@"mono"] boolValue];
        if (mono) {
            UIImage *bw = TDMono(one);
            if (bw) one = bw;
        }
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject stringByAppendingPathComponent:name];
        NSData *png = UIImagePNGRepresentation(one);
        if (!png || ![png writeToFile:p atomically:YES]) return @{@"ok": @0, @"msg": @"写文件失败"};
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"存了 %@ %.0f×%.0f%@",
                                      name, one.size.width, one.size.height, mono ? @"（黑白）" : @""]};
    }

    // 识图：给了 roi 就只在那块里找
    if ([c isEqualToString:@"find"]) {
        NSString *name = [cmd[@"tpl"] isKindOfClass:[NSString class]] ? cmd[@"tpl"] : @"";
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject stringByAppendingPathComponent:name];
        UIImage *tpl = name.length ? [UIImage imageWithContentsOfFile:p] : nil;
        if (!tpl) return @{@"ok": @0, @"msg": [NSString stringWithFormat:@"读不到模板 %@", name]};
        CGRect roi = CGRectNull;
        if (cmd[@"roi"] && [cmd[@"roi"] count] == 4) {
            NSArray *a = cmd[@"roi"];
            roi = CGRectMake([a[0] doubleValue], [a[1] doubleValue],
                             [a[2] doubleValue], [a[3] doubleValue]);
        }
        double th = cmd[@"th"] ? [cmd[@"th"] doubleValue] : 0.82;
        TDMatch *m = TDfindImageSmartInRect(tpl, name, th, roi, NULL);
        if (!m) return @{@"ok": @0, @"msg": [NSString stringWithFormat:@"没找到 %@（≥%.2f）", name, th],
                         @"shot": @1};
        if ([cmd[@"tap"] boolValue]) TDtap(m.point.x, m.point.y);
        return @{@"ok": @1,
                 @"msg": [NSString stringWithFormat:@"%@ (%.0f,%.0f) 相似度 %.3f · 白掩码 %.2f",
                          name, m.point.x, m.point.y, m.score, m.maskHit],
                 @"x": @(lround(m.point.x)), @"y": @(lround(m.point.y)),
                 @"score": @(m.score), @"mask": @(m.maskHit), @"shot": @1};
    }

    if ([c isEqualToString:@"ocr"]) {
        // 缩小再认：Vision 对分辨率不敏感，1242×2208 缩到 700 宽，速度快几倍。
        // 上一版直接把整屏原图丢给它在主线程认，直接触发 watchdog 把 App 杀了。
        UIImage *shot = TDshotScaled(700);
        NSArray *lines = TDocrLines(shot);
        NSData *d = [NSJSONSerialization dataWithJSONObject:lines options:0 error:NULL];
        TDput(@"ocr.json", d);
        NSString *flat = [[lines valueForKey:@"s"] componentsJoinedByString:@" | "];
        return @{@"ok": @1, @"msg": [NSString stringWithFormat:@"OCR %lu 行", (unsigned long)lines.count],
                 @"text": flat.length > 900 ? [flat substringToIndex:900] : (flat ?: @""),
                 @"shot": @1};
    }

    if ([c isEqualToString:@"info"]) {
        return @{@"ok": @1, @"msg": TDstateDict()[@"cap"] ?: @"", @"shot": @([cmd[@"shot"] boolValue])};
    }

    return @{@"ok": @0, @"msg": [NSString stringWithFormat:@"不认识的命令 %@", c]};
}

#pragma mark - 通道

@interface TDRemote : NSObject
+ (instancetype)shared;
- (void)startIfNeeded;
- (void)loop;
- (void)tick;
- (void)runCommand:(NSDictionary *)cmd;
@end

@implementation TDRemote {
    dispatch_queue_t _q;
    BOOL _started;
    double _autoEvery;          // 自动截图间隔（秒），0 = 关
    double _nextAutoAt;
    double _nextStateAt;
    NSString *_lastCmdId;
}

+ (instancetype)shared {
    static TDRemote *r = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        r = [TDRemote new];
        r->_q = dispatch_queue_create("tapdog.remote", DISPATCH_QUEUE_SERIAL);
    });
    return r;
}

- (void)startIfNeeded {
    if (_started) return;
    _started = YES;

    // 上次执行到哪条命令要接着记：设备重启后服务器上还留着同一条 cmd.json，
    // 不恢复游标就会把上一次的点击原样再执行一遍。
    _lastCmdId = [[NSUserDefaults standardUserDefaults] stringForKey:@"tdRemoteLastCmd"];
    _nextStateAt = 0;      // 一起来就立刻上报一次状态，远端马上能看到在线

    // 日志也回传一份：远程看不到屏幕的时候，日志是最快知道「卡在哪」的东西
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        TDAddLogTap(^(NSString *line) { TDRingPush(line); });
    });

    dispatch_async(_q, ^{ [self loop]; });
}

- (void)loop {
    TDRemoteNote(@"通道已启动，等待服务器命令");
    while (YES) {
        @autoreleasepool {
            if (TDRemoteEnabled()) {
                [self tick];
            } else {
                TDRemoteNote(@"已关闭");
            }
        }
        usleep(1400 * 1000);        // 1.4s 一轮：够快，又不至于把电池啃掉
    }
}

- (void)tick {
    double now = [NSDate date].timeIntervalSince1970;

    NSDictionary *cmd = TDgetJSON(@"cmd.json");
    NSString *cid = [cmd[@"id"] isKindOfClass:[NSString class]] ? cmd[@"id"] : nil;
    if (cid.length && ![cid isEqualToString:_lastCmdId]) {
        _lastCmdId = cid;
        [[NSUserDefaults standardUserDefaults] setObject:cid forKey:@"tdRemoteLastCmd"];
        [self runCommand:cmd];
    }

    if (_autoEvery > 0 && now >= _nextAutoAt) {
        _nextAutoAt = now + _autoEvery;
        TDuploadShot(500, 0.55);
    }

    if (now >= _nextStateAt) {
        _nextStateAt = now + 10.0;
        if (!TDputJSON(@"state.json", TDstateDict())) gLastErr = gLastErr ?: @"state 上传失败";
    }
}

- (void)runCommand:(NSDictionary *)cmd {
    // 过期命令不执行：设备离线一段时间再上线时，服务器上那条旧命令
    // 可能已经是几小时前的点击，照做就是乱点
    double ts = [cmd[@"ts"] doubleValue];
    double now = [NSDate date].timeIntervalSince1970;
    if (ts > 0 && now - ts > 90) {
        TDLog(@"远程调试：丢弃一条 %.0fs 前的过期命令 %@", now - ts, cmd[@"c"] ?: @"?");
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @0,
                                 @"msg": @"命令已过期（设备当时不在线）", @"ts": @(now)});
        return;
    }

    NSString *c = [cmd[@"c"] isKindOfClass:[NSString class]] ? cmd[@"c"] : @"";

    if ([c isEqualToString:@"pat"]) {
        NSDictionary *rep = TDrunPatternProbe();
        gCmdCount++;
        TDputJSON(@"pattern.json", rep);
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @1,
                                 @"msg": rep[@"msg"] ?: @"探针完成", @"ts": @(now)});
        return;
    }

    if ([c isEqualToString:@"pixfmt"]) {
        // 记下拆位方式，之后所有截图（包括 App 内自己裁模板）都走这条路
        int v = cmd[@"v"] ? [cmd[@"v"] intValue] : 0;
        [[NSUserDefaults standardUserDefaults] setInteger:v forKey:@"TDPixLayout"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        gCmdCount++;
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @1,
                                 @"msg": [NSString stringWithFormat:@"拆位方式=%@", @(v)],
                                 @"ts": @(now)});
        return;
    }

    if ([c isEqualToString:@"shot"]) {
        // 截图要整屏原图还是缩略，都行；默认缩到 500 宽，流量小一半
        CGFloat w = cmd[@"full"] ? 0 : 500;
        gShotFmt = cmd[@"fmt"] ? [cmd[@"fmt"] intValue]
                               : (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"TDPixLayout"];
        BOOL ok = TDuploadShot(w, cmd[@"q"] ? [cmd[@"q"] doubleValue] : 0.6);
        uint32_t f = TDcapturePixelFormat();
        char fc[5] = { (char)(f >> 24), (char)(f >> 16), (char)(f >> 8), (char)f, 0 };
        NSString *desc = [NSString stringWithFormat:@"截图已上传 · 格式 '%s' bpr %zu",
                          fc, TDcaptureBytesPerRow()];
        gShotFmt = 0;
        gCmdCount++;
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @(ok),
                                 @"msg": ok ? desc : (gLastErr ?: @"截图失败"),
                                 @"ts": @(now)});
        return;
    }

    if ([c isEqualToString:@"auto"]) {
        _autoEvery = cmd[@"every"] ? MAX(1.0, [cmd[@"every"] doubleValue]) : 3.0;
        if ([cmd[@"off"] boolValue]) _autoEvery = 0;
        _nextAutoAt = 0;
        gCmdCount++;
        TDputJSON(@"ack.json", @{@"id": cmd[@"id"] ?: @"", @"ok": @1,
                                 @"msg": _autoEvery > 0
                                     ? [NSString stringWithFormat:@"每 %.0fs 传一张截图", _autoEvery]
                                     : @"停止自动截图",
                                 @"ts": @(now)});
        return;
    }

    // 命令直接在后台队列上跑，不再 dispatch_sync 到主线程 ——
    // OCR（Vision 整屏识别）和识图（金字塔扫描）都是几百毫秒到几秒的重活，
    // 放在主线程会把 UI 卡死，主线程超时就会被系统 watchdog 直接杀掉：
    // 表现就是「远程发了条 ocr，App 自己闪退，而且永远收不到回执」。
    // 真正需要主线程的只有 openURL，那一条在分支里自己 dispatch_async 过去了。
    NSDictionary *res = TDexecCommand(cmd) ?: @{@"ok": @0, @"msg": @"无返回"};
    gCmdCount++;
    TDRemoteNote([NSString stringWithFormat:@"执行 %@：%@", c, res[@"msg"] ?: @""]);

    if ([res[@"shot"] boolValue]) TDuploadShot(500, 0.6);

    NSMutableDictionary *ack = [NSMutableDictionary dictionaryWithDictionary:@{
        @"id": cmd[@"id"] ?: @"", @"ok": res[@"ok"] ?: @0,
        @"msg": res[@"msg"] ?: @"", @"ts": @([NSDate date].timeIntervalSince1970),
    }];
    if (res[@"x"]) ack[@"x"] = res[@"x"];
    if (res[@"y"]) ack[@"y"] = res[@"y"];
    if (res[@"score"]) ack[@"score"] = res[@"score"];
    if (res[@"mask"]) ack[@"mask"] = res[@"mask"];
    if (res[@"text"]) ack[@"text"] = res[@"text"];
    TDputJSON(@"ack.json", ack);
    TDputJSON(@"state.json", TDstateDict());
}

@end

#pragma mark - 对外

void TDRemoteStart(void) {
    if (!TDRemoteEnabled()) return;
    [[TDRemote shared] startIfNeeded];
}

void TDRemoteKick(void) {
    TDRemote *r = [TDRemote shared];
    [r startIfNeeded];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!TDuploadShot(800, 0.62)) TDLog(@"远程调试：截图上传失败 %@", gLastErr ?: @"?");
        TDputJSON(@"state.json", TDstateDict());
    });
}
