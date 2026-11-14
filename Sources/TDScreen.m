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

UIImage *TDscreenshot(void) { return TDscreenshotFmt(0); }

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
