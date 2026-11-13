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
    NSArray *_currentPlan;      // 当前这一轮要跑的步骤，日志里用来取序号
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

static double TDRand01(void) {
    return (double)arc4random() / 4294967295.0;
}

static double TDRandRange(double a, double b) {
    if (b <= a) return a;
    return a + TDRand01() * (b - a);
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
    _currentPlan = plan;

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

    // ---- 执行概率 ----
    // 「有可能不点」：run < 1 时按概率整步跳过。
    // 跳过只是不动作，间隔照旧（gap 在 engineSteps 里已经展开成独立的 wait 步），
    // 所以节奏不会被抽掉一拍。
    if (st[@"run"]) {
        double run = [st[@"run"] doubleValue];
        if (run < 0.999 && TDRand01() > run) {
            [self logMsg:@"第 %ld 步按概率跳过（run=%.0f%%）",
                   (long)[self stepOrdinal:st], run * 100];
            if ([t isEqualToString:@"wait"]) usleep((useconds_t)([st[@"ms"] doubleValue] * 1000));
            return;
        }
    }

    // ---- 随机化 ----
    // 随机率 p 决定这一步「这一次」要不要变；随机度（px / pr / rd / ms / gap）
    // 决定变多少。没命中随机率就走全局默认偏移，行为跟以前一致。
    NSDictionary *rnd = [st[@"rnd"] isKindOfClass:[NSDictionary class]] ? st[@"rnd"] : nil;
    BOOL hit = NO;
    if (rnd) {
        double p = rnd[@"p"] ? [rnd[@"p"] doubleValue] : 1.0;
        hit = (p >= 0.999) || (TDRand01() < p);
    }

    double jitter = cfg.jitterPx;
    if (hit && rnd[@"px"]) jitter = [rnd[@"px"] doubleValue];

    // 压力 / 触摸半径：只有显式给了范围才动。
    // 默认不动，因为实测这台机器只认「压力 0 / 半径 0.04」，乱改会点不动。
    BOOL hasPhys = NO;
    double pressure = 0.0, radius = 0.04;
    if (hit) {
        NSArray *pr = [rnd[@"pr"] isKindOfClass:[NSArray class]] ? rnd[@"pr"] : nil;
        if (pr.count >= 2) {
            pressure = TDRandRange([pr[0] doubleValue], [pr[1] doubleValue]);
            hasPhys = YES;
        }
        NSArray *rd = [rnd[@"rd"] isKindOfClass:[NSArray class]] ? rnd[@"rd"] : nil;
        if (rd.count >= 2) {
            radius = TDRandRange([rd[0] doubleValue], [rd[1] doubleValue]);
            hasPhys = YES;
        }
    }
    if (hasPhys) TDSetInjectTouchPhysics(pressure, radius, 0.0, 0.0);

    double msScale = 1.0;
    if (hit && rnd[@"ms"]) {
        double k = [rnd[@"ms"] doubleValue];
        msScale = 1.0 + TDRandRange(-k, k);
    }
    double interval = cfg.intervalMs;
    if (hit && rnd[@"gap"]) {
        double k = [rnd[@"gap"] doubleValue];
        interval *= (1.0 + TDRandRange(-k, k));
    }
    if (interval < 0) interval = 0;

    [self execBody:st type:t jitter:jitter interval:interval msScale:msScale];

    if (hasPhys) TDSetInjectTouchPhysics(0.0, 0.04, 0.0, 0.0);
}

/// 真正执行的那一段。拆出来是为了不管走哪个分支，
/// 退出时都能把压力/半径改回安全值（否则后面的步骤会带着随机压力跑）。
- (void)execBody:(NSDictionary *)st type:(NSString *)t
          jitter:(double)jitter interval:(double)interval msScale:(double)msScale {
    TDConfig *cfg = [TDConfig shared];

    if ([t isEqualToString:@"wait"]) {
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : cfg.intervalMs;
        usleep((useconds_t)(MAX(0.0, ms * msScale) * 1000));
        return;
    }

    if ([t isEqualToString:@"tap"]) {
        CGPoint p = TDJitter(CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]), jitter);
        TDtap(p.x, p.y);
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"long"]) {
        CGPoint p = TDJitter(CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]), jitter);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 800;
        TDlongPress(p.x, p.y, MAX(120.0, ms * msScale) / 1000.0);
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"swipe"]) {
        CGPoint a = TDJitter(CGPointMake([st[@"x1"] doubleValue], [st[@"y1"] doubleValue]), jitter);
        CGPoint b = TDJitter(CGPointMake([st[@"x2"] doubleValue], [st[@"y2"] doubleValue]), jitter);
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 400;
        TDswipe(a, b, MAX(120.0, ms * msScale) / 1000.0);
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"gesture"]) {
        NSArray *raw = st[@"pts"];
        NSMutableArray<NSValue *> *pts = [NSMutableArray array];
        for (NSArray *pair in raw) {
            if (pair.count >= 2) {
                CGPoint p = CGPointMake([pair[0] doubleValue], [pair[1] doubleValue]);
                [pts addObject:[NSValue valueWithCGPoint:TDJitter(p, jitter)]];
            }
        }
        if (pts.count >= 2) {
            double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 500;
            TDgesture(pts, MAX(120.0, ms * msScale) / 1000.0);
        }
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"find"]) {
        NSString *name = st[@"tpl"];
        if (name.length == 0) {
            [self logMsg:@"第 %ld 步是识图，但还没选模板", (long)[self stepOrdinal:st]];
            return;
        }
        double th = st[@"th"] ? [st[@"th"] doubleValue] : cfg.threshold;
        double timeoutMs = st[@"to"] ? [st[@"to"] doubleValue] : 0;
        double dx = st[@"dx"] ? [st[@"dx"] doubleValue] : 0;
        double dy = st[@"dy"] ? [st[@"dy"] doubleValue] : 0;

        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        UIImage *tpl = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        if (!tpl) {
            [self logMsg:@"模板文件不见了：%@", name];
            return;
        }

        // 识图本身有一次「等画面稳定」的语义：抖音翻页动画没结束时截到的是糊图，
        // 所以给了超时就在这里轮询，而不是一帧没命中就判死。
        CFTimeInterval deadline = CACurrentMediaTime() + MAX(0.0, timeoutMs) / 1000.0;
        TDMatch *m = nil;
        NSInteger tries = 0;
        BOOL scaledHit = NO;
        while (self->_running) {
            tries++;
            m = TDfindImage(tpl, th, 1.0, 1.0, 1);
            if (m) break;

            // 尺度兜底：从相册导进来的模板像素尺度不一定和这块屏一样
            // （被打包压过、或者干脆是别处裁的图）。原尺度找不到时，
            // 在 ±15% 内再扫一遍 —— 只在没命中时才付这份开销。
            m = TDfindImage(tpl, th, 0.85, 1.15, 7);
            if (m) { scaledHit = YES; break; }

            if (timeoutMs <= 0 || CACurrentMediaTime() >= deadline) break;
            usleep(200 * 1000);
        }

        if (!m) {
            [self logMsg:@"识图没找到 %@（阈值 %.2f，试了 %ld 次）", name, th, (long)tries];
            return;
        }
        if (scaledHit) {
            [self logMsg:@"识图 %@ 是靠尺度扫描命中的（%.2f×），模板像素和屏幕不完全一致", name, m.scale];
        }

        CGPoint p = TDJitter(CGPointMake(m.point.x + dx, m.point.y + dy), jitter);
        double hold = st[@"ms"] ? [st[@"ms"] doubleValue] : 0;
        if (hold > 0) {
            TDlongPress(p.x, p.y, MAX(120.0, hold * msScale) / 1000.0);
        } else {
            TDtap(p.x, p.y);
        }
        [self logMsg:@"识图 %@ %.2f → 点 (%.0f,%.0f)", name, m.score, p.x, p.y];
        usleep((useconds_t)(interval * 1000));
        return;
    }
}

/// 步骤序号（只为日志好读：能对上编辑页里的第几行）
- (NSInteger)stepOrdinal:(NSDictionary *)st {
    return (NSInteger)[self->_currentPlan indexOfObjectIdenticalTo:st] + 1;
}

@end
