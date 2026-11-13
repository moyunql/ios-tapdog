#import "TD.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

// ---------------------------------------------------------------------------
// 音量键接管
//
// 为什么要它：录制时人是站在抖音里操作的，回 App 点「停止」这一步本身也是
// 一次屏幕触摸 —— 以前这一下会被录进脚本最后一步。现在改成：
//   音量上 = 开始录制（穿透录制）
//   音量下 = 停止并保存
// 手不离屏、不切 App，也就不可能把自己那一下录进去。
//
// 检测两条路，谁先报算谁的（0.7 秒去抖）：
//   1) HID 监听里的 button 事件 —— 后台也收得到，不依赖音量是否变化；
//   2) 音量 KVO —— 万一 button 事件不进这个客户端，用它兜底。
//
// 「禁用音量键」的做法：记住接管那一刻的音量，每次检测到按键就把它写回去。
// 不用私有 API，只用 MPVolumeView 里的那个 slider。
// ---------------------------------------------------------------------------

static void *kTDVolCtx = &kTDVolCtx;

@interface TDKeys : NSObject
@property (nonatomic) float baseVolume;
@property (nonatomic) CFTimeInterval lastKeyAt;
@property (nonatomic) NSInteger hits;
@property (nonatomic, copy) NSString *lastSource;
@property (nonatomic, copy) NSString *lastAction;
@property (nonatomic, strong) MPVolumeView *volView;
@property (nonatomic, strong) UISlider *volSlider;
@end

static TDKeys *gKeys = nil;

@implementation TDKeys

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gKeys = [TDKeys new];
        gKeys.baseVolume = 0.4f;
    });
    return gKeys;
}

#pragma mark 音量钉住

- (void)ensureVolumeView {
    if (self.volView) return;
    NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
    UIWindow *w = nil;
    for (UIWindow *x in wins) {
        if (x.isKeyWindow) { w = x; break; }
    }
    if (!w) w = wins.firstObject;
    if (!w) return;

    MPVolumeView *v = [[MPVolumeView alloc] initWithFrame:CGRectMake(-80, -80, 40, 40)];
    v.alpha = 0.01;
    v.userInteractionEnabled = NO;
    [w addSubview:v];
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UISlider class]]) {
            self.volSlider = (UISlider *)sub;
            break;
        }
    }
    self.volView = v;
}

- (void)restoreVolume {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureVolumeView];
        UISlider *s = self.volSlider;
        if (!s) return;
        if (fabsf(s.value - self.baseVolume) < 0.005f) return;
        s.value = self.baseVolume;
        [s sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

#pragma mark 按键分发

- (void)handleUsage:(NSInteger)usage source:(NSString *)src {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastKeyAt < 0.7) return;   // 两条检测路会同时报，去抖
    self.lastKeyAt = now;
    self.hits += 1;
    self.lastSource = src ?: @"?";

    [self restoreVolume];                      // 音量键不真的改音量

    dispatch_async(dispatch_get_main_queue(), ^{
        [self performUsage:usage];
    });
}

- (void)performUsage:(NSInteger)usage {
    TDRecorder *r = [TDRecorder shared];
    TDEngine *e = [TDEngine shared];

    if (usage == 0xE9) {                       // 音量上 = 开始录制
        if (r.recording) {
            TDLog(@"音量上：已经在录了");
            self.lastAction = @"已在录";
        } else {
            if (e.running) [e stop];
            if ([r startLive]) {
                TDLog(@"音量上：开始录制 — 直接在抖音里点/滑，按音量下结束");
                self.lastAction = @"开始录制";
            } else {
                TDLog(@"音量上：录制起不来（%@）", [r status]);
                self.lastAction = @"启动失败";
            }
        }
    } else if (usage == 0xEA) {                // 音量下 = 停止
        if (r.recording) {
            [r finishAndSave];
            TDLog(@"音量下：录制结束，已保存");
            self.lastAction = @"保存录制";
        } else if (e.running) {
            [e stop];
            TDLog(@"音量下：已停止回放");
            self.lastAction = @"停止回放";
        } else {
            TDLog(@"音量下：当前没在录，也没在跑");
            self.lastAction = @"空闲";
        }
    } else {
        TDLog(@"音量键：未识别的 usage 0x%lX", (long)usage);
        self.lastAction = @"未知键";
    }

    TDFloatRefresh();
    [[NSNotificationCenter defaultCenter] postNotificationName:TDDataChangedNotification object:nil];
}

#pragma mark 音量 KVO 兜底

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                       change:(NSDictionary *)change context:(void *)ctx {
    if (ctx != kTDVolCtx) {
        [super observeValueForKeyPath:kp ofObject:obj change:change context:ctx];
        return;
    }
    float v = [change[NSKeyValueChangeNewKey] floatValue];
    float d = v - self.baseVolume;
    if (fabsf(d) < 0.02f) return;
    [self handleUsage:(d > 0 ? 0xE9 : 0xEA) source:@"音量KVO"];
}

@end

#pragma mark - 对外

void TDKeysInstall(void) {
    TDKeys *k = [TDKeys shared];

    AVAudioSession *ses = [AVAudioSession sharedInstance];
    float v = ses.outputVolume;
    if (v > 0.001f) k.baseVolume = v;

    // 监听得先跑起来，否则 button 事件根本不会回调到我们
    TDHIDSampleStart();

    TDSetHIDKeyHandler(^(NSInteger usage) {
        [[TDKeys shared] handleUsage:usage source:@"HID按键"];
    });

    @try {
        [ses addObserver:k forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:kTDVolCtx];
    } @catch (NSException *e) {
        TDLog(@"音量 KVO 挂不上：%@", e.reason);
    }

    [k ensureVolumeView];
    TDLog(@"音量键已接管：上=录制 下=停止（音量钉在 %.0f%%）", k.baseVolume * 100);
}

NSString *TDKeysStatus(void) {
    TDKeys *k = [TDKeys shared];
    return [NSString stringWithFormat:@"音量键 %ld 次 · 上次来源 %@ · 上次动作 %@\nHID 按键事件 %ld 个（0 说明只能靠音量KVO兜底，最近 usage 0x%lX）",
            (long)k.hits, k.lastSource ?: @"-", k.lastAction ?: @"-",
            (long)TDHIDKeyEventCount(), (long)TDHIDLastKeyUsage()];
}
