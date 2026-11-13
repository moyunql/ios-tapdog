#import "TD.h"
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// ---------------------------------------------------------------------------
// 后台保活：UIBackgroundModes=audio + 循环播放静音，切到抖音后进程不被挂起
// ---------------------------------------------------------------------------

static NSString *gAudioStatus = @"未启动";

@interface TDKeepAlive ()
- (void)begin;
@end

@implementation TDKeepAlive {
    AVAudioPlayer *_player;
}

+ (instancetype)shared {
    static TDKeepAlive *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ k = [TDKeepAlive new]; });
    return k;
}

+ (void)start { [[self shared] begin]; }
+ (NSString *)status { return gAudioStatus; }

- (void)begin {
    if (_player) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:&err];
    if (err) { gAudioStatus = [NSString stringWithFormat:@"setCategory 失败 %ld", (long)err.code]; return; }
    err = nil;
    [s setActive:YES error:&err];
    if (err) { gAudioStatus = [NSString stringWithFormat:@"setActive 失败 %ld", (long)err.code]; return; }

    // 1 秒 8kHz 单声道静音 PCM，包成最小 WAV
    const int rate = 8000, secs = 1, ch = 1, bits = 16;
    int dataLen = rate * secs * ch * bits / 8;
    NSMutableData *wav = [NSMutableData data];
    uint32_t u32; uint16_t u16;
    [wav appendBytes:"RIFF" length:4];
    u32 = 36 + dataLen; [wav appendBytes:&u32 length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    u32 = 16; [wav appendBytes:&u32 length:4];
    u16 = 1; [wav appendBytes:&u16 length:2];
    u16 = ch; [wav appendBytes:&u16 length:2];
    u32 = rate; [wav appendBytes:&u32 length:4];
    u32 = rate * ch * bits / 8; [wav appendBytes:&u32 length:4];
    u16 = ch * bits / 8; [wav appendBytes:&u16 length:2];
    u16 = bits; [wav appendBytes:&u16 length:2];
    [wav appendBytes:"data" length:4];
    u32 = dataLen; [wav appendBytes:&u32 length:4];
    [wav appendData:[NSMutableData dataWithLength:dataLen]];

    _player = [[AVAudioPlayer alloc] initWithData:wav error:NULL];
    _player.numberOfLoops = -1;
    _player.volume = 0.02;
    BOOL ok = [_player play];
    gAudioStatus = ok ? @"静音播放中（后台不会被挂起）"
                      : @"播放失败（切到抖音可能被挂起）";
}

@end

// 沙盒探测：能往 /var/mobile/Media 写文件，说明 no-sandbox 真的生效
NSString *TDSandboxStatus(void) {
    const char *path = "/var/mobile/Media/.tapdog_probe";
    int fd = open(path, O_CREAT | O_WRONLY, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(path);
        return @"已绕过（no-sandbox 生效）";
    }
    return [NSString stringWithFormat:@"受限 errno=%d（权限没生效）", errno];
}
