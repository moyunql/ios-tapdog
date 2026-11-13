#import "TD.h"
#include <math.h>
#include <stdlib.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 配置 + 回放引擎
// ---------------------------------------------------------------------------

static NSString *TDConfigPath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"tapdog.json"];
}

@implementation TDConfig

+ (instancetype)shared {
    static TDConfig *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [TDConfig new];
        [c load];
    });
    return c;
}

- (instancetype)init {
    if (self = [super init]) {
        _jitterPx = 3;
        _tapHoldMs = 50;
        _intervalMs = 150;
        _threshold = 0.85;
        _loopCount = 1;
    }
    return self;
}

- (void)load {
    NSData *d = [NSData dataWithContentsOfFile:TDConfigPath()];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *j = obj;
    if (j[@"jitter"])   _jitterPx = [j[@"jitter"] doubleValue];
    if (j[@"hold"])     _tapHoldMs = [j[@"hold"] doubleValue];
    if (j[@"interval"]) _intervalMs = [j[@"interval"] doubleValue];
    if (j[@"threshold"])_threshold = [j[@"threshold"] doubleValue];
    if (j[@"loop"])     _loopCount = [j[@"loop"] integerValue];
}

- (void)save {
    NSDictionary *j = @{@"jitter": @(_jitterPx),
                        @"hold": @(_tapHoldMs),
                        @"interval": @(_intervalMs),
                        @"threshold": @(_threshold),
                        @"loop": @(_loopCount)};
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:NULL];
    [d writeToFile:TDConfigPath() atomically:YES];
}

@end

#pragma mark - 引擎

void TDSetLogHandler(void (^h)(NSString *)) {
    [TDEngine shared].logHandler = h;
}

void TDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [[TDEngine shared] logMsg:@"%@", s];
}

@implementation TDEngine {
    BOOL _running;
    dispatch_queue_t _q;
    NSInteger _loopsDone;
    NSString *_jetsamStatus;
}

+ (instancetype)shared {
    static TDEngine *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        e = [TDEngine new];
        e->_q = dispatch_queue_create("tapdog.engine", DISPATCH_QUEUE_SERIAL);
    });
    return e;
}

- (BOOL)running { return _running; }
- (NSInteger)loopsDone { return _loopsDone; }
- (NSString *)jetsamStatus { return _jetsamStatus; }
- (void)setJetsamStatus:(NSString *)s { _jetsamStatus = [s copy]; }

- (void)logMsg:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^h)(NSString *) = self.logHandler;
    if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(s); });
#ifdef DEBUG
    NSLog(@"[tapdog] %@", s);
#endif
}

static CGPoint TDJitter(CGPoint p, double r) {
    if (r <= 0) return p;
    double a = ((double)arc4random() / 4294967295.0) * M_PI * 2.0;
    double d = sqrt((double)arc4random() / 4294967295.0) * r;
    return CGPointMake(p.x + cos(a) * d, p.y + sin(a) * d);
}

- (void)playSteps:(NSArray<NSDictionary *> *)steps loop:(NSInteger)loops {
    if (_running) {
        [self logMsg:@"已经在跑了"];
        return;
    }
    if (steps.count == 0) {
        [self logMsg:@"脚本是空的，先录一遍"];
        return;
    }
    _running = YES;
    _loopsDone = 0;
    NSArray *plan = [steps copy];

    [self logMsg:@"开始：%lu 步，循环 %@", (unsigned long)plan.count,
                  loops == 0 ? @"无限" : [NSString stringWithFormat:@"%ld 次", (long)loops]];

    dispatch_async(_q, ^{
        NSInteger round = 0;
        while (self->_running) {
            for (NSDictionary *st in plan) {
                if (!self->_running) break;
                @autoreleasepool { [self execStep:st]; }
            }
            if (!self->_running) break;
            round++;
            self->_loopsDone = round;
            if (loops > 0 && round >= loops) break;
        }
        self->_running = NO;
        [self logMsg:@"结束，跑了 %ld 轮", (long)round];
        void (^f)(void) = self.onFinish;
        if (f) dispatch_async(dispatch_get_main_queue(), ^{ f(); });
    });
}

- (void)stop { _running = NO; }

- (void)execStep:(NSDictionary *)st {
    TDConfig *cfg = [TDConfig shared];
    NSString *t = st[@"t"] ?: @"wait";

    if ([t isEqualToString:@"wait"]) {
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : cfg.intervalMs;
        usleep((useconds_t)(ms * 1000));
        return;
    }

    if ([t isEqualToString:@"tap"]) {
        CGPoint p = TDJitter(CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]), cfg.jitterPx);
        TDtap(p.x, p.y);
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"long"]) {
        CGPoint p = TDJitter(CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]), cfg.jitterPx);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 800;
        TDlongPress(p.x, p.y, ms / 1000.0);
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"swipe"]) {
        CGPoint a = TDJitter(CGPointMake([st[@"x1"] doubleValue], [st[@"y1"] doubleValue]), cfg.jitterPx);
        CGPoint b = TDJitter(CGPointMake([st[@"x2"] doubleValue], [st[@"y2"] doubleValue]), cfg.jitterPx);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 400;
        TDswipe(a, b, ms / 1000.0);
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"gesture"]) {
        NSArray *raw = st[@"pts"];
        NSMutableArray<NSValue *> *pts = [NSMutableArray array];
        for (NSArray *pair in raw) {
            if (pair.count >= 2) {
                CGPoint p = CGPointMake([pair[0] doubleValue], [pair[1] doubleValue]);
                [pts addObject:[NSValue valueWithCGPoint:TDJitter(p, cfg.jitterPx)]];
            }
        }
        if (pts.count >= 2) {
            double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 500;
            TDgesture(pts, ms / 1000.0);
        }
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"find"]) {
        NSString *name = st[@"tpl"];
        double th = st[@"th"] ? [st[@"th"] doubleValue] : cfg.threshold;
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        UIImage *tpl = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:name ?: @""]];
        if (!tpl) {
            [self logMsg:@"模板缺失: %@", name];
            return;
        }
        TDMatch *m = TDfindImage(tpl, th, 0.7, 1.3, 4);
        if (!m) {
            [self logMsg:@"没找到 %@ (阈值%.2f)", name, th];
            return;
        }
        CGPoint p = TDJitter(m.point, cfg.jitterPx);
        TDtap(p.x, p.y);
        [self logMsg:@"识图 %.2f → (%.0f,%.0f)", m.score, p.x, p.y];
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }
}

@end
