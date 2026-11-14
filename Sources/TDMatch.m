#import "TD.h"
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdlib.h>

@implementation TDMatch
@end

// ---------------------------------------------------------------------------
// 模板匹配：灰度化 + 4 倍金字塔粗搜 + 原分辨率精修
// 相似度用零均值归一化互相关(NCC)，对亮度变化不敏感，0~1 之间
// ---------------------------------------------------------------------------

static uint8_t *TDGray(UIImage *img, int *outW, int *outH) {
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w == 0 || h == 0) return NULL;

    uint8_t *buf = (uint8_t *)calloc(w * h, 1);
    if (!buf) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);

    *outW = (int)w;
    *outH = (int)h;
    return buf;
}

// 盒式降采样到 1/f
static uint8_t *TDDownscale(const uint8_t *src, int sw, int sh, int f, int *dw, int *dh) {
    int ow = sw / f, oh = sh / f;
    if (ow < 1 || oh < 1) return NULL;
    uint8_t *out = (uint8_t *)calloc((size_t)ow * oh, 1);
    if (!out) return NULL;
    for (int y = 0; y < oh; y++) {
        for (int x = 0; x < ow; x++) {
            int sum = 0;
            for (int j = 0; j < f; j++) {
                const uint8_t *row = src + (size_t)(y * f + j) * sw + x * f;
                for (int i = 0; i < f; i++) sum += row[i];
            }
            out[(size_t)y * ow + x] = (uint8_t)(sum / (f * f));
        }
    }
    *dw = ow;
    *dh = oh;
    return out;
}

// NCC 搜索，返回最佳分数并输出左上角坐标
static double TDNCC(const uint8_t *img, int iw, int ih,
                    const uint8_t *tpl, int tw, int th,
                    int x0, int y0, int x1, int y1,
                    int *bestX, int *bestY) {
    if (tw < 2 || th < 2 || tw > iw || th > ih) return 0;

    // 模板去均值 + 范数
    double tsum = 0;
    for (int i = 0; i < tw * th; i++) tsum += tpl[i];
    double tmean = tsum / (tw * th);
    double tnorm = 0;
    for (int i = 0; i < tw * th; i++) {
        double d = tpl[i] - tmean;
        tnorm += d * d;
    }
    tnorm = sqrt(tnorm);
    if (tnorm < 1e-6) return 0;

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > iw - tw) x1 = iw - tw;
    if (y1 > ih - th) y1 = ih - th;
    if (x1 < x0 || y1 < y0) return 0;

    double best = -1;
    int bx = x0, by = y0;

    for (int y = y0; y <= y1; y++) {
        for (int x = x0; x <= x1; x++) {
            double ssum = 0, s2 = 0, cross = 0;
            for (int j = 0; j < th; j++) {
                const uint8_t *ir = img + (size_t)(y + j) * iw + x;
                const uint8_t *tr = tpl + (size_t)j * tw;
                for (int i = 0; i < tw; i++) {
                    double v = ir[i];
                    ssum += v;
                    s2 += v * v;
                    cross += v * (tr[i] - tmean);
                }
            }
            double n = tw * th;
            double svar = s2 - ssum * ssum / n;
            if (svar < 1e-6) continue;
            double score = cross / (sqrt(svar) * tnorm);
            if (score > best) { best = score; bx = x; by = y; }
        }
    }
    *bestX = bx;
    *bestY = by;
    return best < 0 ? 0 : best;
}

static UIImage *TDResizeImage(UIImage *img, CGFloat scale) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    size_t w = (size_t)MAX(2, round(CGImageGetWidth(cg) * scale));
    size_t h = (size_t)MAX(2, round(CGImageGetHeight(cg) * scale));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) return nil;
    UIImage *r = [UIImage imageWithCGImage:out scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return r;
}

// ---------------------------------------------------------------------------
// 「上次识图时的那一帧」
//
// 编辑页要让人在抖音画面上拉框，但编辑页在前台时截到的是我们自己的界面，
// 没法当底图。所以回放期间每识别一次就留一份整屏图 —— 那才是用户想框的那个画面。
// 只在回放时开：一张 1080×1920 是 8MB，平时没必要占着。
// ---------------------------------------------------------------------------

static UIImage *gLastShot = nil;
static CGSize gLastShotPx = CGSizeZero;
static volatile int32_t gShotCacheOn = 0;

void TDSetShotCacheEnabled(BOOL on) { gShotCacheOn = on ? 1 : 0; }
UIImage *TDLastTargetShot(void) { return gLastShot; }
CGSize TDLastTargetShotPixelSize(void) { return gLastShotPx; }

CGFloat TDLastTargetShotRatio(void) {
    CGSize pt = [UIScreen mainScreen].bounds.size;
    if (gLastShotPx.width < 1 || pt.width < 1) return TDscreenScaleRatio();
    return pt.width / gLastShotPx.width;
}

// ---------------------------------------------------------------------------
// 搜索范围
//
// roi 用「屏幕点」，判定标准是**模板中心落在框内**：
// 框比模板小的时候（比如只框住评论按钮的一小块）左上角语义会直接把范围算成空，
// 中心语义不会 —— 允许模板溢出框，只要中心在里头。
// ---------------------------------------------------------------------------

/// 把「中心必须落在 ROI 内」换算成「左上角允许的范围」，并对齐到当前层（粗搜是 1/4）
static void TDBoundsForROI(int *x0, int *y0, int *x1, int *y1,
                           CGRect rpx, int tw, int th, double f, int iw, int ih) {
    int rx0 = (int)floor(rpx.origin.x / f);
    int ry0 = (int)floor(rpx.origin.y / f);
    int rx1 = (int)ceil((rpx.origin.x + rpx.size.width) / f);
    int ry1 = (int)ceil((rpx.origin.y + rpx.size.height) / f);

    int cx0 = rx0 - tw / 2, cx1 = rx1 - tw / 2;
    int cy0 = ry0 - th / 2, cy1 = ry1 - th / 2;

    if (cx0 < 0) cx0 = 0;
    if (cy0 < 0) cy0 = 0;
    int mx = iw - tw, my = ih - th;
    if (mx < 0) mx = 0;
    if (my < 0) my = 0;
    if (cx1 > mx) cx1 = mx;
    if (cy1 > my) cy1 = my;

    *x0 = cx0; *y0 = cy0; *x1 = cx1; *y1 = cy1;
}

/// 真正干活的：roi 传 CGRectNull 或宽高 < 2 就是全屏找
static TDMatch *TDFindCore(UIImage *tpl, CGRect roi, double threshold,
                           double minScale, double maxScale, int scaleSteps) {
    if (!tpl) return nil;

    UIImage *screen = TDscreenshot();
    if (!screen) return nil;

    if (gShotCacheOn) {
        gLastShot = screen;                 // 后一张覆盖前一张，不留历史
        gLastShotPx = screen.size;
    }

    int sw = 0, sh = 0;
    uint8_t *sg = TDGray(screen, &sw, &sh);
    if (!sg) return nil;

    // ROI：屏幕点 → 画面像素
    CGFloat ratio = TDscreenScaleRatio();   // 点 / 像素
    if (!(ratio > 0)) ratio = 1;
    BOOL limit = (!CGRectIsNull(roi) && roi.size.width >= 2 && roi.size.height >= 2);
    CGRect rpx = CGRectZero;
    if (limit) {
        rpx = CGRectMake(roi.origin.x / ratio, roi.origin.y / ratio,
                         roi.size.width / ratio, roi.size.height / ratio);
        CGRect clip = CGRectMake(0, 0, sw, sh);
        rpx = CGRectIntersection(rpx, clip);
        if (CGRectIsNull(rpx) || rpx.size.width < 2 || rpx.size.height < 2) limit = NO;
    }

    int sw4 = 0, sh4 = 0;
    uint8_t *sg4 = TDDownscale(sg, sw, sh, 4, &sw4, &sh4);

    if (scaleSteps < 1) scaleSteps = 1;
    double bestScore = 0;
    int bestX = 0, bestY = 0;
    CGFloat bestScale = 1.0;
    int btw = 0, bth = 0;

    for (int k = 0; k < scaleSteps; k++) {
        CGFloat s = (scaleSteps == 1) ? 1.0
                                      : (CGFloat)(minScale + (maxScale - minScale) * k / (scaleSteps - 1));
        UIImage *ts = TDResizeImage(tpl, s);
        if (!ts) continue;

        int tw = 0, th = 0;
        uint8_t *tg = TDGray(ts, &tw, &th);
        if (!tg) continue;

        if (sg4 && sw4 > 0) {
            int tw4 = 0, th4 = 0;
            uint8_t *tg4 = TDDownscale(tg, tw, th, 4, &tw4, &th4);
            if (tg4 && tw4 >= 3 && th4 >= 3 && tw4 <= sw4 && th4 <= sh4) {
                int bx = 0, by = 0;
                int q0 = 0, r0 = 0, q1 = sw4 - tw4, r1 = sh4 - th4;
                if (limit) {
                    TDBoundsForROI(&q0, &r0, &q1, &r1, rpx, tw4, th4, 4.0, sw4, sh4);
                }
                double sc = TDNCC(sg4, sw4, sh4, tg4, tw4, th4, q0, r0, q1, r1, &bx, &by);
                if (sc > bestScore) {
                    bestScore = sc;
                    bestX = bx * 4;
                    bestY = by * 4;
                    bestScale = s;
                    btw = tw; bth = th;
                }
                free(tg4);
            }
        }
        free(tg);
    }

    free(sg4);

    // 原分辨率精修：在粗搜结果附近 ±8 像素
    if (btw > 0 && bth > 0) {
        UIImage *tsBest = TDResizeImage(tpl, bestScale);
        int tw = 0, th = 0;
        uint8_t *tg = tsBest ? TDGray(tsBest, &tw, &th) : NULL;
        if (tg) {
            int fx0 = bestX - 8, fy0 = bestY - 8, fx1 = bestX + 8, fy1 = bestY + 8;
            if (limit) {
                // 精修也不能跑到框外去：同样的「中心在框内」条件
                int cx0 = (int)floor(rpx.origin.x) - tw / 2;
                int cy0 = (int)floor(rpx.origin.y) - th / 2;
                int cx1 = (int)ceil(rpx.origin.x + rpx.size.width) - tw / 2;
                int cy1 = (int)ceil(rpx.origin.y + rpx.size.height) - th / 2;
                fx0 = MAX(fx0, cx0);
                fy0 = MAX(fy0, cy0);
                fx1 = MIN(fx1, cx1);
                fy1 = MIN(fy1, cy1);
            }
            int bx = bestX, by = bestY;
            double sc = 0;
            if (fx1 >= fx0 && fy1 >= fy0) {
                sc = TDNCC(sg, sw, sh, tg, tw, th, fx0, fy0, fx1, fy1, &bx, &by);
            }
            if (sc > bestScore) {
                bestScore = sc;
                bestX = bx;
                bestY = by;
            }
            // 中心点换算成屏幕「点」坐标
            CGFloat ratio2 = TDscreenScaleRatio();
            TDMatch *m = [TDMatch new];
            m.score = bestScore;
            m.scale = bestScale;
            m.point = CGPointMake((bestX + tw / 2.0) * ratio2, (bestY + th / 2.0) * ratio2);
            free(tg);
            free(sg);
            if (bestScore < threshold) return nil;
            return m;
        }
    }

    free(sg);
    return nil;
}

TDMatch *TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps) {
    return TDFindCore(tpl, CGRectNull, threshold, minScale, maxScale, scaleSteps);
}

TDMatch *TDfindImageInRect(UIImage *tpl, CGRect roi, double threshold,
                           double minScale, double maxScale, int scaleSteps) {
    return TDFindCore(tpl, roi, threshold, minScale, maxScale, scaleSteps);
}

// ---------------------------------------------------------------------------
// 带尺度策略的识图
//
// 为什么需要这一层：模板的像素尺度不一定等于屏幕上的实际尺寸。
//   · 内置的点赞/评论/收藏是从素材上取的小图（38px 左右），抖音里那个图标将近 100px；
//   · 从相册导的截图可能被转发压过；
//   · 截图裁出来的那些才是 1:1。
// 全范围扫描每次几百毫秒，回放里每步都扫不现实，所以命中一次就把尺度记下来，
// 下次只在它附近窄扫。界面没变的时候几乎零成本，变了会自动退回全扫描。
// ---------------------------------------------------------------------------

static NSString *TDScaleHintKey(NSString *name) {
    return [@"tdScaleHint_" stringByAppendingString:name ?: @""];
}

double TDScaleHint(NSString *name) {
    if (name.length == 0) return 0;
    NSNumber *n = [[NSUserDefaults standardUserDefaults] objectForKey:TDScaleHintKey(name)];
    return n ? n.doubleValue : 0;
}

void TDSetScaleHint(NSString *name, double s) {
    if (name.length == 0 || s <= 0.05) return;
    [[NSUserDefaults standardUserDefaults] setObject:@(s) forKey:TDScaleHintKey(name)];
}

TDMatch *TDfindImageSmartInRect(UIImage *tpl, NSString *tplName, double threshold,
                                CGRect roi, BOOL *scanned) {
    if (scanned) *scanned = NO;
    if (!tpl) return nil;

    // 1. 有记忆尺度：窄扫三档。失败说明画面/图标尺寸变了，落到下面重来
    double hint = TDScaleHint(tplName);
    if (hint > 0.05) {
        TDMatch *m = TDfindImageInRect(tpl, roi, threshold, hint * 0.94, hint * 1.06, 3);
        if (m) { TDSetScaleHint(tplName, m.scale); return m; }
    }

    // 2. 原尺度（截屏裁出来的模板走这条，命中率最高也最快）
    TDMatch *m = TDfindImageInRect(tpl, roi, threshold, 1.0, 1.0, 1);
    if (m) { TDSetScaleHint(tplName, 1.0); return m; }

    // 3. 尺度扫描。小模板（内置图标 / 相册小图）可能差好几倍，范围放宽到 0.6~3.2
    BOOL small = MIN(tpl.size.width, tpl.size.height) < 70;
    double lo = small ? 0.60 : 0.85;
    double hi = small ? 3.20 : 1.15;
    int steps = small ? 9 : 7;
    m = TDfindImageInRect(tpl, roi, threshold, lo, hi, steps);
    if (m) {
        TDSetScaleHint(tplName, m.scale);
        if (scanned) *scanned = YES;
    }
    return m;
}

TDMatch *TDfindImageSmart(UIImage *tpl, NSString *tplName, double threshold, BOOL *scanned) {
    return TDfindImageSmartInRect(tpl, tplName, threshold, CGRectNull, scanned);
}
