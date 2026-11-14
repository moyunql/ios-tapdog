#import "TD.h"
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// 启动、崩溃捕获、前后台生命周期
// ---------------------------------------------------------------------------

#pragma mark - 崩溃日志

static char gCrashPath[1024] = {0};

NSString *TDcrashLogText(void) {
    NSString *p = [NSString stringWithUTF8String:gCrashPath];
    if (!p.length) return @"";
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    if (!s) return @"";
    if (s.length > 6000) s = [s substringFromIndex:s.length - 6000];
    return s;
}

void TDcrashLogClear(void) {
    if (!gCrashPath[0]) return;
    unlink(gCrashPath);
}

static void TDSignalHandler(int sig) {
    if (gCrashPath[0]) {
        int fd = open(gCrashPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            char line[128];
            int n = snprintf(line, sizeof(line), "\n=== 崩溃 signal %d ===\n", sig);
            if (n > 0) write(fd, line, (size_t)n);
            void *frames[64];
            int cnt = backtrace(frames, 64);
            if (cnt > 0) backtrace_symbols_fd(frames, cnt, fd);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TDUncaughtHandler(NSException *e) {
    if (!gCrashPath[0]) return;
    NSString *text = [NSString stringWithFormat:@"\n=== ObjC 异常 %@: %@\n%@\n",
                      e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    FILE *fp = fopen(gCrashPath, "a");
    if (fp) { fputs(text.UTF8String, fp); fclose(fp); }
}

static void TDInstallCrashLogger(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [dir stringByAppendingPathComponent:@"crash.log"];
    snprintf(gCrashPath, sizeof(gCrashPath), "%s", path.fileSystemRepresentation);

    // 太大就清掉，别把磁盘写满
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if ([attr fileSize] > 32 * 1024) unlink(gCrashPath);

    int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};
    for (int i = 0; i < (int)(sizeof(sigs) / sizeof(sigs[0])); i++) {
        signal(sigs[i], TDSignalHandler);
    }
    NSSetUncaughtExceptionHandler(&TDUncaughtHandler);
}

#pragma mark - AppDelegate

extern UIViewController *TDCreateMainVC(void);

@interface TDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TDAppDelegate

// openURL 回调：Info.plist 里有 LSSupportsOpeningDocumentsInPlace 时，系统要求
// delegate 必须实现这个方法，否则一收到 URL 就直接抛 NSInternalInconsistencyException。
// 实测表现就是「远程调一次 open tapdog:// ，App 立刻闪退」，查了半天才在崩溃日志里看到。
// 实现里什么都不用做，收到就返回 YES，App 正常回到前台即可。
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    TDLog(@"openURL：%@", url.absoluteString);
    return YES;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    TDInstallCrashLogger();

    // 内置识图模板（点赞 / 评论 / 收藏）落到 Documents，模板库里开箱就能选。
    // 必须早于任何界面构建：编辑页一打开就会扫模板列表。
    TDInstallBuiltinTemplates();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = TDCreateMainVC();
    self.window.backgroundColor = [UIColor blackColor];
    [self.window makeKeyAndVisible];

    // 注入参数回到安全默认（BKS 那一步可能崩，每次启动先关掉，不连环崩）
    TDInjectResetToSafeDefaults();

    // 上次如果留下幽灵手指（up 丢了），整机连真人点按都会失灵。
    // 启动后盲扫一遍抬起，把手指收回来 —— 这样用户不用重启手机。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TDReleaseAllTouches();
    });

    [TDKeepAlive start];
    [TDEngine shared].jetsamStatus = TDBypassJetsam();
    TDFloatInstall();

    // 音量键接管：上 = 开始录制，下 = 停止并保存。
    // 这里会顺手把 HID 监听从常驻打开 —— 按键事件和触摸走的是同一个客户端，
    // 监听不跑就收不到按键，只能退回音量 KVO 兜底。
    TDKeysInstall();

    // 远程调试通道：把截图/状态/日志写到中转站，从上面取命令执行。
    // 开关默认开，关了这里就什么都不做（连线程都不起）。
    TDRemoteStart();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    TDLog(@"启动 | 注入 %@ (%@) | 截屏 %@",
          TDhidStatus(), TDInjectVariantDesc(), TDcaptureStatus());
    return YES;
}

- (void)didEnterBackground {
    // 窗口会被 UIKit 藏起来，重新托管一次让 SpringBoard 继续画球
    dispatch_async(dispatch_get_main_queue(), ^{
        TDFloatSetVisible(TDFloatVisible());
        // 穿透录制的蒙版同理：切到抖音之后它还得盖在上面显示轨迹
        if (TDMaskVisible()) TDMaskShow();
        TDFloatRefresh();
    });
}

- (void)didBecomeActive {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 回来自动停：取点结束并落盘，回放也停，免得在自己界面上乱点
        TDRecorder *r = [TDRecorder shared];
        if (r.recording) {
            [r finishAndSave];
            TDLog(@"回到 App，取点已结束并保存");
        }
        if ([TDEngine shared].running) {
            [[TDEngine shared] stop];
            TDLog(@"回到 App，已停止回放");
        }
        // 回放中途被打断时，最后一次 up 可能没发出去 —— 手指会一直「按着」，
        // 表现为整个屏幕连人手都点不动。回来先把它抬起来。
        if (TDHasStuckTouch()) {
            TDReleaseStuckTouch();
            TDLog(@"回到 App，已释放卡住的触摸");
        }
        // 取点/标定中途退出时，托管窗口可能还留在全屏状态，
        // 那一层盖在 App 上也同样会吞掉所有触摸，缩回去。
        if (TDFloatIsFullScreen()) {
            TDFloatSetFullScreen(NO);
            TDLog(@"回到 App，托管窗口已从全屏缩回");
        }
        TDFloatRefresh();
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TDAppDelegate class]));
    }
}
