#import "TD.h"
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>

// ---------------------------------------------------------------------------
// 截屏：从主显示器的 IOMobileFramebuffer 取默认 layer 的 IOSurface，
// 直接读像素。比 CARenderServer 路径更稳，且拿到的是真实全屏内容。
// 需要 platform-application + iokit-user-client-class(IOMobileFramebufferUserClient)
// ---------------------------------------------------------------------------

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef int32_t (*FnGetMainDisplay)(IOMobileFramebufferRef *fb);
typedef int32_t (*FnGetLayerSurface)(IOMobileFramebufferRef fb, int layer, IOSurfaceRef *surf);

static FnGetMainDisplay gGetMainDisplay = NULL;
static FnGetLayerSurface gGetLayerSurface = NULL;
static BOOL gTriedLoad = NO;
static NSString *gCapStatus = @"未初始化";

static CGSize gLastPixelSize = CGSizeZero;

static void TDLoadFramebuffer(void) {
    if (gTriedLoad) return;
    gTriedLoad = YES;

    void *h = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                     RTLD_NOW);
    if (!h) {
        gCapStatus = @"IOMobileFramebuffer 打不开";
        return;
    }
    gGetMainDisplay = (FnGetMainDisplay)dlsym(h, "IOMobileFramebufferGetMainDisplay");
    gGetLayerSurface = (FnGetLayerSurface)dlsym(h, "IOMobileFramebufferGetLayerDefaultSurface");
    if (!gGetMainDisplay || !gGetLayerSurface) {
        gCapStatus = @"符号缺失(GetMainDisplay/GetLayerDefaultSurface)";
        return;
    }
    gCapStatus = @"符号就绪";
}

static IOSurfaceRef TDGrabSurface(void) {
    TDLoadFramebuffer();
    if (!gGetMainDisplay || !gGetLayerSurface) return NULL;

    IOMobileFramebufferRef fb = NULL;
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
    IOSurfaceRef s = TDGrabSurface();
    return s != NULL;
}

NSString *TDcaptureStatus(void) { return gCapStatus; }

UIImage *TDscreenshot(void) {
    IOSurfaceRef surf = TDGrabSurface();
    if (surf == NULL) return nil;

    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);

    size_t w = IOSurfaceGetWidth(surf);
    size_t h = IOSurfaceGetHeight(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    void *base = IOSurfaceGetBaseAddress(surf);
    uint32_t fmt = IOSurfaceGetPixelFormat(surf);
    if (w == 0 || h == 0 || base == NULL) {
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
        return nil;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint32_t info;
    if (fmt == 0x52474241 /* 'RGBA' */) {
        info = (uint32_t)kCGImageAlphaNoneSkipLast | (uint32_t)kCGBitmapByteOrder32Big;
    } else {
        // 'BGRA' 及未知格式统一按 BGRA 处理
        info = (uint32_t)kCGImageAlphaNoneSkipFirst | (uint32_t)kCGBitmapByteOrder32Little;
    }

    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, info);
    CGImageRef cg = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);

    if (!cg) return nil;
    gLastPixelSize = CGSizeMake((CGFloat)w, (CGFloat)h);
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
