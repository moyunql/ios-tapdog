//
//  TDHotkey.m
//  音量键「按下」当作紧急停止。
//
//  为什么需要：脚本回放期间悬浮条虽然停到顶部（没藏），但人在抖音里不一定
//  一眼找到那个 ■。音量键是全局的、闭眼都能摸到，适合当急停。
//
//  怎么实现：系统的 outputVolume 变了就说明用户按了音量键。变小的那一侧
//  （音量减）触发 stop。注意音量已经到 0 时再按不会再变小，所以这只是
//  「多一条路」，主要手段仍然是顶部悬浮条的 ■ 停止按钮。
//

#import "TD.h"
#import <AVFoundation/AVFoundation.h>

static float gLastVolume = -1;
static BOOL gVolArmed = NO;

@interface TDVolWatch : NSObject
@end

@implementation TDVolWatch

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    float v = [AVAudioSession sharedInstance].outputVolume;
    if (gVolArmed && gLastVolume >= 0 && v < gLastVolume - 0.0001) {
        gVolArmed = NO;                 // 只响应一次，连按不会反复触发
        TDLog(@"音量减：急停脚本");
        [[TDEngine shared] stop];
    }
    gLastVolume = v;
}

@end

static TDVolWatch *gVolWatch = nil;

/// 装监听（只装一次）。App 一直在放静音音频，audio session 是活的，
/// 所以键按下的音量变化能被 KVO 收到。
void TDVolumeStopInstall(void) {
    if (gVolWatch) return;
    gVolWatch = [TDVolWatch new];
    gLastVolume = [AVAudioSession sharedInstance].outputVolume;
    [[AVAudioSession sharedInstance] addObserver:gVolWatch
                                      forKeyPath:@"outputVolume"
                                         options:NSKeyValueObservingOptionNew
                                         context:NULL];
}

/// 上膛 / 卸膛。脚本开跑上膛，跑完卸膛 —— 平时按音量键不该有任何副作用。
void TDVolumeStopArm(BOOL on) {
    TDVolumeStopInstall();
    gLastVolume = [AVAudioSession sharedInstance].outputVolume;
    gVolArmed = on;
}
