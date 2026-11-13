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

TDMatch *TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps) {
    if (!tpl) return nil;

    UIImage *screen = TDscreenshot();
    if (!screen) return nil;

    int sw = 0, sh = 0;
    uint8_t *sg = TDGray(screen, &sw, &sh);
    if (!sg) return nil;

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
                double sc = TDNCC(sg4, sw4, sh4, tg4, tw4, th4, 0, 0, sw4 - tw4, sh4 - th4, &bx, &by);
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
            int bx = 0, by = 0;
            double sc = TDNCC(sg, sw, sh, tg, tw, th,
                              bestX - 8, bestY - 8, bestX + 8, bestY + 8, &bx, &by);
            if (sc > bestScore) {
                bestScore = sc;
                bestX = bx;
                bestY = by;
            }
            // 中心点换算成屏幕「点」坐标
            CGFloat ratio = TDscreenScaleRatio();
            TDMatch *m = [TDMatch new];
            m.score = bestScore;
            m.scale = bestScale;
            m.point = CGPointMake((bestX + tw / 2.0) * ratio, (bestY + th / 2.0) * ratio);
            free(tg);
            free(sg);
            if (bestScore < threshold) return nil;
            return m;
        }
    }

    free(sg);
    return nil;
}
