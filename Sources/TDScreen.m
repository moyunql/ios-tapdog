#import "TD.h"
#import <dlfcn.h>

// ---------------------------------------------------------------------------
// 截屏：从主显示器的 IOMobileFramebuffer 取默认 layer 的 IOSurface，直接读像素。
//
// 注意：IOSurface 与 IOMobileFramebuffer 在 iOS SDK 里都没有公开头文件，
// 且 IOSurface.framework 在真机上位于 /System/Library/PrivateFrameworks，
// 直接 -framework IOSurface 链接会让 App 启动时 dyld 找不到库。
// 所以这里全部走 dlopen/dlsym，运行时解析符号。
// 需要 platform-application + iokit-user-client-class(IOMobileFramebufferUserClient)
// ---------------------------------------------------------------------------

typedef struct __IOSurface *IOSurfaceRef;

static const uint32_t kTDIOFBLockReadOnly = 0x00000001;   // kIOSurfaceLockReadOnly

typedef int32_t  (*FnGetMainDisplay)(void **fb);
typedef int32_t  (*FnGetLayerSurface)(void *fb, int layer, IOSurfaceRef *surf);
typedef int32_t  (*FnSurfLock)(IOSurfaceRef s, uint32_t opts, uint32_t *seed);
typedef int32_t  (*FnSurfUnlock)(IOSurfaceRef s, uint32_t opts, uint32_t *seed);
typedef size_t   (*FnSurfSize)(IOSurfaceRef s);
typedef size_t   (*FnSurfWidth)(IOSurfaceRef s);
typedef size_t   (*FnSurfHeight)(IOSurfaceRef s);
typedef void    *(*FnSurfBase)(IOSurfaceRef s);
typedef uint32_t (*FnSurfFormat)(IOSurfaceRef s);

static FnGetMainDisplay  gGetMainDisplay = NULL;
static FnGetLayerSurface gGetLayerSurface = NULL;
static FnSurfLock        gSurfLock = NULL;
static FnSurfUnlock      gSurfUnlock = NULL;
static FnSurfWidth       gSurfGetWidth = NULL;
static FnSurfHeight      gSurfGetHeight = NULL;
static FnSurfSize        gSurfGetBytesPerRow = NULL;
static FnSurfBase        gSurfGetBase = NULL;
static FnSurfFormat      gSurfGetFormat = NULL;

static BOOL gTriedLoad = NO;
static NSString *gCapStatus = @"未初始化";
static CGSize gLastPixelSize = {0, 0};

/// 先查全局符号表（IOMobileFramebuffer 已把 IOSurface 带进进程时可直接命中），
/// 再依次尝试两个已知路径。
static void *TDHIDSym(void *handle, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (handle) return dlsym(handle, name);
    return NULL;
}

static void TDLoadFramebuffer(void) {
    if (gTriedLoad) return;
    gTriedLoad = YES;

    void *h = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                     RTLD_NOW);
    if (!h) {
        gCapStatus = @"IOMobileFramebuffer 打不开";
        return;
    }
    void *hs = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_NOW);
    if (!hs) hs = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);

    gGetMainDisplay  = (FnGetMainDisplay)TDHIDSym(h, "IOMobileFramebufferGetMainDisplay");
    gGetLayerSurface = (FnGetLayerSurface)TDHIDSym(h, "IOMobileFramebufferGetLayerDefaultSurface");
    gSurfLock        = (FnSurfLock)TDHIDSym(hs, "IOSurfaceLock");
    gSurfUnlock      = (FnSurfUnlock)TDHIDSym(hs, "IOSurfaceUnlock");
    gSurfGetWidth    = (FnSurfWidth)TDHIDSym(hs, "IOSurfaceGetWidth");
    gSurfGetHeight   = (FnSurfHeight)TDHIDSym(hs, "IOSurfaceGetHeight");
    gSurfGetBytesPerRow = (FnSurfSize)TDHIDSym(hs, "IOSurfaceGetBytesPerRow");
    gSurfGetBase     = (FnSurfBase)TDHIDSym(hs, "IOSurfaceGetBaseAddress");
    gSurfGetFormat   = (FnSurfFormat)TDHIDSym(hs, "IOSurfaceGetPixelFormat");

    if (!gGetMainDisplay || !gGetLayerSurface) {
        gCapStatus = @"符号缺失(GetMainDisplay/GetLayerDefaultSurface)";
        return;
    }
    if (!gSurfLock || !gSurfGetWidth || !gSurfGetHeight || !gSurfGetBase) {
        gCapStatus = @"IOSurface 符号缺失";
        return;
    }
    gCapStatus = @"符号就绪";
}

static IOSurfaceRef TDGrabSurface(void) {
    TDLoadFramebuffer();
    if (!gGetMainDisplay || !gGetLayerSurface) return NULL;

    void *fb = NULL;
    if (gGetMainDisplay(&fb) != 0 || fb == NULL) {
        gCapStatus = @"GetMainDisplay 失败";
        return NULL;
    }
    IOSurfaceRef surf = NULL;
    if (gGetLayerSurface(fb, 0, &surf) != 0 || surf == NULL) {
        gCapStatus = @"GetLayerDefaultSurface 失败";
        return NULL;
    }
    gCapStatus = @"截屏正常";
    return surf;
}

BOOL TDcaptureReady(void) {
    return TDGrabSurface() != NULL;
}

NSString *TDcaptureStatus(void) { return gCapStatus; }

static uint32_t gLastFmt = 0;
static size_t gLastBpr = 0;

uint32_t TDcapturePixelFormat(void) { return gLastFmt; }
size_t TDcaptureBytesPerRow(void) { return gLastBpr; }

// 下面两个实现在文件后半段（探针那节），这里先声明，供 TDscreenshotFmt 用
static inline void TDunpack10(uint32_t w, int layout, int be, uint8_t *rgb);
static void TDfreeProviderBuf(void *info, const void *data, size_t size);

UIImage *TDscreenshot(void) {
    // 默认走「实测出来的拆位方式」。没测过就是 0（老路径），
    // 测出来之后可以用远程命令 pixfmt 存下来，重启也还在。
    int v = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"TDPixLayout"];
    return TDscreenshotFmt(v);
}

/// variant：0 = 按 IOSurface 报的像素格式自动判断（默认路径），
/// 1..4 = 强制指定字节排列，用来排查「截出来颜色不对」到底该按哪种解。
/// 之所以要这个：iPhone 7 Plus / iOS 15 上读出来的图，白色图标会变成红色、
/// 边缘还有彩色镶边 —— 典型的通道错位。灰度识图还能用，但对比度被拉坏了。
UIImage *TDscreenshotFmt(int variant) {
    IOSurfaceRef surf = TDGrabSurface();
    if (surf == NULL) return nil;

    gSurfLock(surf, kTDIOFBLockReadOnly, NULL);

    size_t w = gSurfGetWidth(surf);
    size_t h = gSurfGetHeight(surf);
    size_t bpr = gSurfGetBytesPerRow ? gSurfGetBytesPerRow(surf) : w * 4;
    void *base = gSurfGetBase(surf);
    uint32_t fmt = gSurfGetFormat ? gSurfGetFormat(surf) : 0;
    if (w == 0 || h == 0 || base == NULL) {
        gSurfUnlock(surf, kTDIOFBLockReadOnly, NULL);
        return nil;
    }

    // variant 11..18：按 10 位打包自己拆位（11..14 小端 layout 0..3，15..18 大端）。
    // 这是 'b3a8' 这类 30 位深色 surface 唯一能正确出图的路子。
    if (variant >= 11 && variant <= 18) {
        int idx = variant - 11;
        int layout = idx & 3, be = idx >> 2;
        size_t bpr8 = w * 4;
        uint8_t *buf = malloc(bpr8 * h);
        if (!buf) { gSurfUnlock(surf, kTDIOFBLockReadOnly, NULL); return nil; }
        const uint8_t *src = (const uint8_t *)base;
        for (size_t yy = 0; yy < h; yy++) {
            const uint8_t *row = src + yy * bpr;
            uint8_t *dst = buf + yy * bpr8;
            for (size_t xx = 0; xx < w; xx++) {
                uint32_t word;
                memcpy(&word, row + xx * 4, 4);
                TDunpack10(word, layout, be, dst + xx * 4);
            }
        }
        gSurfUnlock(surf, kTDIOFBLockReadOnly, NULL);
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(buf, buf, bpr8 * h, TDfreeProviderBuf);
        CGImageRef cg2 = CGImageCreate(w, h, 8, 32, bpr8, cs2,
                                       (CGBitmapInfo)(kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big),
                                       prov, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs2);
        if (!cg2) return nil;
        gLastPixelSize = CGSizeMake((CGFloat)w, (CGFloat)h);
        gLastFmt = fmt;
        gLastBpr = bpr;
        UIImage *im2 = [UIImage imageWithCGImage:cg2 scale:1.0 orientation:UIImageOrientationUp];
        CGImageRelease(cg2);
        return im2;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint32_t info;
    if (variant == 1) {
        info = (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big;      // RGBA
    } else if (variant == 2) {
        info = (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Little;  // BGRA
    } else if (variant == 3) {
        info = (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Little;   // ABGR
    } else if (variant == 4) {
        info = (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Big;     // ARGB
    } else if (fmt == 0x52474241 /* 'RGBA' */) {
        info = (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big;
    } else {
        // 'BGRA'（0x42475241）及未知格式统一按 BGRA 处理
        info = (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Little;
    }

    uint32_t infoTry = info;
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, infoTry);
    if (!ctx) {
        // 声明的排列和实际数据对不上时 CGBitmapContextCreate 会返回 NULL，
        // 退回最常用的 BGRA 再试一次，别让整个截屏功能失效。
        ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                    (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Little);
    }
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    gSurfUnlock(surf, kTDIOFBLockReadOnly, NULL);

    if (!cg) return nil;
    gLastPixelSize = CGSizeMake((CGFloat)w, (CGFloat)h);
    gLastFmt = fmt;
    gLastBpr = bpr;
    UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return img;
}

#pragma mark - 原始字节探针 / 10 位打包解码

/// 直接把 framebuffer 里某像素的 4 个字节原封不动读出来，不做任何色彩解释。
///
/// 为什么需要它：iPhone 的主显示 surface 报的是 'b3a8' —— 30 位深色（每个通道
/// 10 位挤在 32 位里），不是普通的 8 位 RGBA。拿 CGBitmapContext 按 8 位去解释，
/// 出来的就是「白色变紫、灰色变彩」的假彩色图；换 bitmapInfo 的字节顺序只是在
/// 轮换这几个字节，怎么调都不对。要修只能自己拆位，而拆位前得先知道真实排布，
/// 所以留了这个探针：喂已知颜色进去，把原始 4 字节读回来反推。
BOOL TDpeekRaw(int x, int y, uint8_t out4[4],
               uint32_t *fmtOut, size_t *bprOut, size_t *wOut, size_t *hOut) {
    IOSurfaceRef surf = TDGrabSurface();
    if (!surf) return NO;
    gSurfLock(surf, kTDIOFBLockReadOnly, NULL);
    size_t w = gSurfGetWidth(surf);
    size_t h = gSurfGetHeight(surf);
    size_t bpr = gSurfGetBytesPerRow ? gSurfGetBytesPerRow(surf) : w * 4;
    uint8_t *base = (uint8_t *)gSurfGetBase(surf);
    BOOL ok = NO;
    if (base && x >= 0 && y >= 0 && x < (int)w && y < (int)h) {
        memcpy(out4, base + (size_t)y * bpr + (size_t)x * 4, 4);
        ok = YES;
    }
    if (fmtOut) *fmtOut = gSurfGetFormat ? gSurfGetFormat(surf) : 0;
    if (bprOut) *bprOut = bpr;
    if (wOut) *wOut = w;
    if (hOut) *hOut = h;
    gSurfUnlock(surf, kTDIOFBLockReadOnly, NULL);
    return ok;
}

/// 把一个 32 位深色像素按候选排布拆成 8 位 RGB。
/// layout 0/1：低 10 位起依次是 B,G,R / R,G,B，最高 2 位是 alpha；
/// layout 2/3：低 2 位是 alpha，之后依次是 B,G,R / R,G,B（Metal 的 BGR10A2）。
static inline void TDunpack10(uint32_t w, int layout, int be, uint8_t *rgb) {
    if (be) {
        w = ((w & 0xFF) << 24) | ((w & 0xFF00) << 8) | ((w >> 8) & 0xFF00) | ((w >> 24) & 0xFF);
    }
    uint32_t c0, c1, c2;
    if (layout < 2) {
        c0 = w & 0x3FF; c1 = (w >> 10) & 0x3FF; c2 = (w >> 20) & 0x3FF;
    } else {
        c0 = (w >> 2) & 0x3FF; c1 = (w >> 12) & 0x3FF; c2 = (w >> 22) & 0x3FF;
    }
    // layout 偶数是 B,G,R，奇数是 R,G,B
    uint32_t r = (layout % 2) ? c0 : c2;
    uint32_t g = c1;
    uint32_t b = (layout % 2) ? c2 : c0;
    rgb[0] = (uint8_t)((r * 255 + 511) / 1023);
    rgb[1] = (uint8_t)((g * 255 + 511) / 1023);
    rgb[2] = (uint8_t)((b * 255 + 511) / 1023);
}

static void TDfreeProviderBuf(void *info, const void *data, size_t size) {
    free(info);
}

// 点坐标 / 像素坐标 的换算比。iPhone 7 Plus 是 414x736 点、1080x1920 像素，
// 比值不是整数（Plus 机型先按 3x 渲染再降采样），所以必须用实测值。
CGFloat TDscreenScaleRatio(void) {
    CGSize pt = [UIScreen mainScreen].bounds.size;
    if (gLastPixelSize.width < 1) {
        TDscreenshot();   // 触发一次，填上像素尺寸
    }
    if (gLastPixelSize.width < 1 || pt.width < 1) {
        return 1.0 / [UIScreen mainScreen].scale;
    }
    return pt.width / gLastPixelSize.width;
}
