//
//  TDHUD.m
//  TapDog
//
//  系统级悬浮窗：把自己的 UIWindow 交给 SpringBoard 托管，
//  这样切到抖音（或任何 App）之后，悬浮球依然显示在最上层。
//
//  关键三步（缺一不可）：
//   1) 窗口类实现 _isSystemWindow=YES、_isWindowServerHostingManaged=NO —— 让 UIKit 不再按普通 App 窗口管理它
//   2) 拿到窗口的 CGS contextID（私有方法 -[UIWindow _contextId]）
//   3) 调 SBSAccessibilityWindowHostingController
//      -registerWindowWithContextID:atLevel: 把 context 委托给 SpringBoard 渲染
//  权限：com.apple.springboard.accessibility-window-hosting（TrollStore 自签可携带）
//

#import "TD.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <string.h>

// ---------------------------------------------------------------------------
// UIWindow 私有接口
// ---------------------------------------------------------------------------
@interface UIWindow (TDCGSContext)
- (unsigned int)_contextId;
@end

// SpringBoardServices 私有类，运行时才存在，因此用 NSObject 分类声明方法签名
@interface NSObject (TDWindowHosting)
- (void)registerWindowWithContextID:(unsigned int)contextID atLevel:(double)level;
- (void)unregisterWindowWithContextID:(unsigned int)contextID;
@end

// ---------------------------------------------------------------------------
// 穿透开关：为 YES 时整个悬浮窗不参与触摸命中，手动刷抖音不会被球挡住
// ---------------------------------------------------------------------------
static BOOL gTDPassthrough = NO;

void TDHUDSetPassthrough(BOOL on);
void TDHUDSetPassthrough(BOOL on) { gTDPassthrough = on; }
BOOL TDHUDPassthrough(void);
BOOL TDHUDPassthrough(void) { return gTDPassthrough; }

// ---------------------------------------------------------------------------
// 系统窗口
// ---------------------------------------------------------------------------
@implementation TDHUDWindow

// 标记成系统窗口：不参与 App 快照、不被 App 生命周期隐藏
+ (BOOL)_isSystemWindow { return YES; }
// 关键：告诉 UIKit 这个窗口的 surface 不由本 App 托管（由 SpringBoard 托管）
- (BOOL)_isWindowServerHostingManaged { return NO; }
// 不影响状态栏
- (BOOL)_canAffectStatusBarAppearance { return NO; }
// 不抢 key window，避免抢走自己主界面的输入
- (BOOL)canBecomeKeyWindow { return NO; }
// 悬浮窗不进截图/录屏（避免识图时把自己的球截进去）
// 注意：安全窗口在部分系统上托管后会渲染成黑块，这里保持关闭，可靠性优先
- (BOOL)_isSecure { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
// 穿透开关生效点
- (BOOL)_ignoresHitTest { return gTDPassthrough; }

@end

// ---------------------------------------------------------------------------
// 托管状态
// ---------------------------------------------------------------------------
static id gHostingController = nil;
static unsigned int gRegisteredContext = 0;
static double gRegisteredLevel = 0;
static BOOL gHostingClassAvailable = NO;
static BOOL gFrameworkLoaded = NO;

static BOOL TDLoadHostingFramework(void) {
    if (gFrameworkLoaded) return gHostingClassAvailable;
    gFrameworkLoaded = YES;
    // SpringBoardServices 在 PrivateFrameworks 里，SDK 没有 tbd，只能 dlopen
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
           RTLD_LAZY | RTLD_GLOBAL);
    gHostingClassAvailable = (objc_getClass("SBSAccessibilityWindowHostingController") != Nil);
    return gHostingClassAvailable;
}

BOOL TDHUDRegisterWindow(UIWindow *w) {
    if (!w) return NO;
    if (!TDLoadHostingFramework()) return NO;

    unsigned int cid = 0;
    if ([w respondsToSelector:@selector(_contextId)]) {
        cid = [w _contextId];
    }
    if (cid == 0) return NO;   // 还没建出 surface，等下一轮

    if (!gHostingController) {
        Class C = objc_getClass("SBSAccessibilityWindowHostingController");
        if (!C) return NO;
        gHostingController = [[C alloc] init];
    }
    if (![gHostingController respondsToSelector:@selector(registerWindowWithContextID:atLevel:)]) {
        return NO;
    }

    double level = w.windowLevel;
    if (cid == gRegisteredContext && fabs(level - gRegisteredLevel) < 0.001) {
        return YES;   // 已注册，别重复打扰 SpringBoard
    }
    [gHostingController registerWindowWithContextID:cid atLevel:level];
    gRegisteredContext = cid;
    gRegisteredLevel = level;
    return YES;
}

void TDHUDUnregisterWindow(UIWindow *w) {
    if (!w || !gHostingController || gRegisteredContext == 0) return;
    unsigned int cid = [w respondsToSelector:@selector(_contextId)] ? [w _contextId] : 0;
    if (cid == 0) cid = gRegisteredContext;
    if ([gHostingController respondsToSelector:@selector(unregisterWindowWithContextID:)]) {
        [gHostingController unregisterWindowWithContextID:cid];
    }
    gRegisteredContext = 0;
}

NSString *TDHUDStatus(void) {
    if (!gFrameworkLoaded) TDLoadHostingFramework();
    if (!gHostingClassAvailable) {
        return @"失败：SpringBoardServices 未加载";
    }
    if (gRegisteredContext == 0) {
        return @"未托管（等窗口就绪后重试）";
    }
    return [NSString stringWithFormat:@"已托管 ctx=%u L=%.0f", gRegisteredContext, gRegisteredLevel];
}

// ---------------------------------------------------------------------------
// 后台保活辅助：把自己提到 critical jetsam 优先级，且禁止被系统冻结
// 需要 com.apple.private.memorystatus / com.apple.private.kernel.jetsam
// ---------------------------------------------------------------------------
typedef struct {
    int32_t  priority;
    uint64_t user_data;
} TDMemStatusProps;

typedef int (*TDFnMemoryStatusControl)(int cmd, pid_t pid, uint32_t flags, void *buffer, size_t size);

NSString *TDBypassJetsam(void) {
    static TDFnMemoryStatusControl fn = NULL;
    static NSString *cached = nil;
    if (cached) return cached;

    if (!fn) fn = (TDFnMemoryStatusControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!fn) { cached = @"不可用（符号缺失）"; return cached; }

    pid_t me = getpid();
    TDMemStatusProps props = { 19 /* JETSAM_PRIORITY_CRITICAL */, 0 };

    int r1 = fn(2, me, 0, &props, sizeof(props));   // SET_PRIORITY_PROPERTIES
    int r2 = fn(5, me, (uint32_t)-1, NULL, 0);      // SET_JETSAM_HIGH_WATER_MARK
    int r3 = fn(6, me, 0, NULL, 0);                 // SET_JETSAM_TASK_LIMIT
    int r4 = fn(16, me, 0, NULL, 0);                // SET_PROCESS_IS_MANAGED = false
    int r5 = fn(18, me, 0, NULL, 0);                // SET_PROCESS_IS_FREEZABLE = false

    if (r1 == 0) {
        cached = @"critical（防挂起已生效）";
    } else {
        cached = [NSString stringWithFormat:@"失败 rc=%d(%s) r2=%d r3=%d r4=%d r5=%d",
                  r1, strerror(errno), r2, r3, r4, r5];
    }
    return cached;
}
