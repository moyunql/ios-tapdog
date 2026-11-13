#import "TD.h"
#include <math.h>
#include <stdlib.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// 配置 + 脚本引擎
// 脚本结构（Documents/tapdog.json）：
// { "jitter":4, "hold":30, "interval":200, "threshold":0.85, "loop":0,
//   "steps":[ {"t":"tap","x":207,"y":660},
//             {"t":"wait","ms":800},
//             {"t":"swipe","x1":207,"y1":600,"x2":207,"y2":200,"ms":400},
//             {"t":"gesture","pts":[[100,600],[200,400],[300,600]],"ms":600},
//             {"t":"find","tpl":"tpl_1.png","th":0.85} ] }
// ---------------------------------------------------------------------------

static NSString *TDConfigPath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"tapdog.json"];
}

@implementation TDConfig {
    NSMutableArray<NSMutableDictionary *> *_steps;
}

+ (instancetype)shared {
    static TDConfig *c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [TDConfig new];
        c.jitterPx = 4;
        c.tapHoldMs = 30;
        c.intervalMs = 200;
        c.threshold = 0.85;
        c.loopCount = 0;
        c->_steps = [NSMutableArray array];
        [c load];
    });
    return c;
}

- (NSMutableArray<NSMutableDictionary *> *)steps {
    if (!_steps) _steps = [NSMutableArray array];
    return _steps;
}

- (void)load {
    NSData *d = [NSData dataWithContentsOfFile:TDConfigPath()];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *j = obj;
    if (j[@"jitter"])   self.jitterPx = [j[@"jitter"] doubleValue];
    if (j[@"hold"])     self.tapHoldMs = [j[@"hold"] doubleValue];
    if (j[@"interval"]) self.intervalMs = [j[@"interval"] doubleValue];
    if (j[@"threshold"])self.threshold = [j[@"threshold"] doubleValue];
    if (j[@"loop"])     self.loopCount = [j[@"loop"] integerValue];
    if ([j[@"steps"] isKindOfClass:[NSArray class]]) {
        _steps = [NSMutableArray array];
        for (id s in j[@"steps"]) {
            if ([s isKindOfClass:[NSDictionary class]]) [self.steps addObject:[s mutableCopy]];
        }
    }
}

- (void)save {
    NSDictionary *j = @{ @"jitter": @(self.jitterPx),
                         @"hold": @(self.tapHoldMs),
                         @"interval": @(self.intervalMs),
                         @"threshold": @(self.threshold),
                         @"loop": @(self.loopCount),
                         @"steps": self.steps };
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:NULL];
    [d writeToFile:TDConfigPath() atomically:YES];
}

- (void)addStep:(NSDictionary *)step {
    [[self steps] addObject:[step mutableCopy]];
    [self save];
}

- (void)removeStepAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)[self steps].count) return;
    [[self steps] removeObjectAtIndex:idx];
    [self save];
}

- (void)moveStepFrom:(NSInteger)from to:(NSInteger)to {
    NSMutableArray *s = [self steps];
    if (from < 0 || from >= (NSInteger)s.count) return;
    NSMutableDictionary *o = s[from];
    [s removeObjectAtIndex:from];
    if (to < 0) to = 0;
    if (to > (NSInteger)s.count) to = s.count;
    [s insertObject:o atIndex:to];
    [self save];
}

@end

#pragma mark - 引擎

@implementation TDEngine {
    BOOL _running;
    dispatch_queue_t _q;
    NSInteger _doneCount;
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

- (void)logMsg:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    void (^h)(NSString *) = self.logHandler;
    if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(s); });
}

static CGPoint TDJitter(CGPoint p, double r) {
    if (r <= 0) return p;
    double a = ((double)arc4random() / 4294967295.0) * M_PI * 2.0;
    double d = sqrt((double)arc4random() / 4294967295.0) * r;
    return CGPointMake(p.x + cos(a) * d, p.y + sin(a) * d);
}

- (void)startWithScript:(NSDictionary *)script {
    if (_running) return;
    _running = YES;
    _doneCount = 0;
    TDConfig *cfg = [TDConfig shared];
    NSArray *steps = script[@"steps"] ?: cfg.steps;
    NSInteger loops = script[@"loop"] ? [script[@"loop"] integerValue] : cfg.loopCount;

    [self logMsg:@"开始，共 %lu 步，循环 %@", (unsigned long)steps.count,
                  loops == 0 ? @"无限" : [NSString stringWithFormat:@"%ld 次", (long)loops]];

    dispatch_async(_q, ^{
        NSInteger round = 0;
        while (self->_running) {
            for (NSDictionary *st in steps) {
                if (!self->_running) break;
                @autoreleasepool {
                    [self execStep:st];
                }
            }
            round++;
            if (loops > 0 && round >= loops) break;
            if (!self->_running) break;
        }
        self->_running = NO;
        [self logMsg:@"已停止（执行 %ld 轮）", (long)round];
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
        CGPoint p = CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]);
        CGPoint j = TDJitter(p, cfg.jitterPx);
        TDtap(j.x, j.y);
        [self logMsg:@"点击 (%.0f,%.0f) 偏移%.0f", j.x, j.y, cfg.jitterPx];
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"long"]) {
        CGPoint p = CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]);
        CGPoint j = TDJitter(p, cfg.jitterPx);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 800;
        TDlongPress(j.x, j.y, ms / 1000.0);
        [self logMsg:@"长按 %.0fms (%.0f,%.0f)", ms, j.x, j.y];
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"swipe"]) {
        CGPoint a = CGPointMake([st[@"x1"] doubleValue], [st[@"y1"] doubleValue]);
        CGPoint b = CGPointMake([st[@"x2"] doubleValue], [st[@"y2"] doubleValue]);
        a = TDJitter(a, cfg.jitterPx);
        b = TDJitter(b, cfg.jitterPx);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 400;
        TDswipe(a, b, ms / 1000.0);
        [self logMsg:@"滑动 (%.0f,%.0f)→(%.0f,%.0f) %.0fms", a.x, a.y, b.x, b.y, ms];
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
            [self logMsg:@"轨迹手势 %lu 点 %.0fms", (unsigned long)pts.count, ms];
        }
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    if ([t isEqualToString:@"find"]) {
        NSString *name = st[@"tpl"];
        double th = st[@"th"] ? [st[@"th"] doubleValue] : cfg.threshold;
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *path = [dir stringByAppendingPathComponent:name ?: @""];
        UIImage *tpl = [UIImage imageWithContentsOfFile:path];
        if (!tpl) {
            [self logMsg:@"模板缺失: %@", name];
            return;
        }
        TDMatch *m = TDfindImage(tpl, th, 0.7, 1.3, 4);
        if (!m) {
            [self logMsg:@"未匹配到 %@ (阈值%.2f)", name, th];
            return;
        }
        CGPoint j = TDJitter(m.point, cfg.jitterPx);
        TDtap(j.x, j.y);
        [self logMsg:@"识图命中 %@ 分数%.3f → 点(%.0f,%.0f)", name, m.score, j.x, j.y];
        usleep((useconds_t)(cfg.intervalMs * 1000));
        return;
    }

    [self logMsg:@"未知步骤类型: %@", t];
}

@end
