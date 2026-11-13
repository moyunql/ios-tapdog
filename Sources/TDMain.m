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

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    TDInstallCrashLogger();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = TDCreateMainVC();
    self.window.backgroundColor = [UIColor blackColor];
    [self.window makeKeyAndVisible];

    [TDKeepAlive start];
    [TDEngine shared].jetsamStatus = TDBypassJetsam();
    TDFloatInstall();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    TDLog(@"启动 | 注入 %@ | 截屏 %@", TDhidStatus(), TDcaptureStatus());
    return YES;
}

- (void)didEnterBackground {
    // 窗口会被 UIKit 藏起来，重新托管一次让 SpringBoard 继续画球
    dispatch_async(dispatch_get_main_queue(), ^{
        TDFloatSetVisible(TDFloatVisible());
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
        TDFloatRefresh();
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([TDAppDelegate class]));
    }
}
