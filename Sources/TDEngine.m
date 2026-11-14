#import "TD.h"
#include <math.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <pthread.h>

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

// 额外订阅者。悬浮窗的日志面板靠它拿日志 ——
// 单独的 logHandler 只有一个位置，被主界面占了，再覆盖就会互相顶掉。
static NSMutableArray *gLogTaps = nil;

void TDAddLogTap(void (^h)(NSString *)) {
    if (!h) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogTaps = [NSMutableArray array]; });
    [gLogTaps addObject:[h copy]];
}

void TDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [[TDEngine shared] logMsg:@"%@", s];
}

/// 回放的这一下会不会砸到我们自己的悬浮条上。
///
/// 悬浮条是一个真实的 SystemWide 窗口（级别比抖音高），注入的触摸落进它的矩形里，
/// 命中的就是我们的 ▶ / ● / ■，不是抖音。用户看到的两件怪事都是它：
///   · 落在 ● → 一路走 TDFloatStartLiveRecord →「播着播着变成录制了」；
///   · 落在 ■ → 当场 [engine stop] → 下次 ▶ 又从第 0 步起 →「每次都从 0 开始」。
/// 所以回放阶段凡是落点压在悬浮条上的步骤，一律跳过并明确告诉用户。
static BOOL TDHitsFloatBar(CGPoint p) {
    CGRect r = TDFloatTouchRect();
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return NO;
    return CGRectContainsPoint(CGRectInset(r, -4, -4), p);
}

/// 评论面板开没开：OCR 找面板上特有的字样。
/// 为什么不用亮度：白底视频、浅灰界面都能把亮度判据骗过去；文字骗不了。
/// 「下一步」那种灰按钮、视频里的字幕，都不会出现「条评论」这三个字。
static BOOL TDCommentPanelOpen(NSString **hit) {
    if (hit) *hit = nil;
    for (NSDictionary *ln in TDocrLines(TDscreenshot())) {
        NSString *sv = ln[@"s"];
        if (![sv isKindOfClass:[NSString class]] || sv.length == 0) continue;
        if ([sv containsString:@"条评论"] || [sv containsString:@"期待你的评论"] ||
            [sv containsString:@"大家都在搜"] || [sv containsString:@"留下你的精彩评论"]) {
            if (hit) *hit = sv;
            return YES;
        }
    }
    return NO;
}

@implementation TDEngine {
    volatile BOOL _running;
    dispatch_queue_t _q;
    NSInteger _loopsDone;
    // 每一轮运行一个「凭证」。旧线程收尾时只能清自己那一轮的 _running，
    // 否则「按 ■ 立刻再按 ▶」会被上一个线程尾巴上的 _running = NO 直接掐死。
    volatile NSUInteger _gen;
    NSInteger _curIndex;        // 当前跑到 plan 的第几步（0 起，-1 = 不在步骤里）
    NSInteger _stoppedAt;       // 上一次被用户停在第几步（-1 = 没被中断）
    BOOL _floatBarWarned;       // 悬浮条压点只提示一次，别刷屏
    NSString *_jetsamStatus;
    NSArray *_currentPlan;      // 当前这一轮要跑的步骤，日志里用来取序号
    NSDictionary *_failsafe;    // 本次运行的「判断」配置（nil = 关）
    BOOL _failsafeFired;        // 这次运行有没有已经兜过底（once 用）
    BOOL _inFailsafe;           // 正在跑兜底动作（防止兜底里再套兜底）
    NSInteger _fbIndex;         // 兜底动作跑到第几步（只为日志）
    NSInteger _fsPos;           // 判断的位置：0 当场 / 1 每轮开始 / 2 每轮末尾
}

+ (instancetype)shared {
    static TDEngine *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        e = [TDEngine new];
        e->_q = dispatch_queue_create("tapdog.engine", DISPATCH_QUEUE_SERIAL);
        e->_stoppedAt = -1;
        e->_curIndex = -1;
    });
    return e;
}

- (BOOL)running { return _running; }
- (NSInteger)loopsDone { return _loopsDone; }
- (NSInteger)stoppedStep { return _stoppedAt; }
- (NSInteger)curStep { return _curIndex; }
- (NSInteger)planCount { return (NSInteger)_currentPlan.count; }
- (NSString *)jetsamStatus { return _jetsamStatus; }
- (void)setJetsamStatus:(NSString *)s { _jetsamStatus = [s copy]; }

// ---------------------------------------------------------------------------
// 日志环形缓冲：崩溃时唯一能带走现场的东西
//
// 为什么需要：日志原本只会 dispatch 到主队列显示，进程一崩就全丢了 ——
// 上次崩溃只知道「跑完第 0 步就没了」，具体死在哪一行无从判断，只能靠猜。
// 这里用一块固定大小的静态缓冲区，每次 logMsg 同步写一份（不经过任何队列），
// 崩溃处理器进去把它整块写进 crash.log，于是「最后一条日志」就是现场。
// 固定大小 + 覆盖写，不会因为日志多而吃内存。
// ---------------------------------------------------------------------------
#define kTDRingCap 8192
static char gRing[kTDRingCap];
static int  gRingLen = 0;          // 已用字节（到顶后一直等于 cap）
static int  gRingPos = 0;          // 下一个写入位置
static pthread_mutex_t gRingLock = PTHREAD_MUTEX_INITIALIZER;

void TDlogRingAppend(const char *line) {
    if (!line) return;
    size_t n = strlen(line);
    if (n == 0) return;
    if (n > kTDRingCap - 1) { line += n - (kTDRingCap - 1); n = kTDRingCap - 1; }
    pthread_mutex_lock(&gRingLock);
    for (size_t i = 0; i < n; i++) {
        gRing[gRingPos] = line[i];
        gRingPos = (gRingPos + 1) % kTDRingCap;
    }
    gRing[gRingPos] = 0;
    if (gRingLen < kTDRingCap - 1) gRingLen += (int)n;
    if (gRingLen > kTDRingCap - 1) gRingLen = kTDRingCap - 1;
    pthread_mutex_unlock(&gRingLock);
}

// 按时间顺序取出全部内容；返回实际长度
size_t TDlogRingDump(char *out, size_t cap) {
    if (!out || cap == 0) return 0;
    pthread_mutex_lock(&gRingLock);
    int len = gRingLen;
    if (len > (int)cap - 1) {
        // 只留最后 cap-1 个字符
        int skip = len - (int)cap + 1;
        for (int i = 0; i < (int)cap - 1; i++) {
            int idx = (gRingPos - (len - skip) + i + kTDRingCap * 2) % kTDRingCap;
            out[i] = gRing[idx];
        }
        len = (int)cap - 1;
        out[len] = 0;
        pthread_mutex_unlock(&gRingLock);
        return (size_t)len;
    }
    int start = (gRingPos - len + kTDRingCap * 2) % kTDRingCap;
    for (int i = 0; i < len; i++) out[i] = gRing[(start + i) % kTDRingCap];
    out[len] = 0;
    pthread_mutex_unlock(&gRingLock);
    return (size_t)len;
}

- (void)logMsg:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 先同步进环形缓冲：崩溃时主队列上那些还没显示的就全丢了，这里不会。
    {
        time_t now = time(NULL);
        struct tm tmv;
        localtime_r(&now, &tmv);
        char hhmmss[16];
        strftime(hhmmss, sizeof(hhmmss), "%H:%M:%S", &tmv);
        const char *body = s.UTF8String ?: "";
        size_t need = strlen(body) + 32;
        char *one = (char *)malloc(need);
        if (one) {
            snprintf(one, need, "[%s] %s\n", hhmmss, body);
            TDlogRingAppend(one);
            free(one);
        }
    }
    void (^h)(NSString *) = self.logHandler;
    NSArray *taps = gLogTaps.count ? [gLogTaps copy] : nil;
    if (h || taps.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (h) h(s);
            for (void (^t)(NSString *) in taps) t(s);
        });
    }
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
    [self startPlan:steps loops:loops failsafe:nil loopGap:0 from:0];
}

/// 跑一条脚本：循环次数、每轮间隔、识图失败兜底全部按脚本自己的配置。
- (void)playScript:(TDScript *)script {
    [self playScript:script fromStep:0];
}

/// fromStep 只影响第一轮：从第几步开始跑。0 = 老行为（从头）。
/// 调试某一步、或者「接着上次停的地方」都用它，第二轮以后照样从 0 起。
- (void)playScript:(TDScript *)script fromStep:(NSInteger)startIndex {
    if (!script) {
        [self logMsg:@"没有选中的脚本"];
        return;
    }
    NSArray *plan = [script engineSteps];
    NSInteger loops = 1;
    double gap = 0;
    if ([script.loop[@"on"] boolValue]) {
        // count：0 或负数 = 无限，和悬浮球那边的约定一致
        loops = [script.loop[@"count"] integerValue];
        if (loops < 0) loops = 0;
        gap = MAX(0.0, [script.loop[@"gap"] doubleValue]);
    }
    NSDictionary *fs = [script failsafeEnabled] ? script.failsafe : nil;
    [self startPlan:plan loops:loops failsafe:fs loopGap:gap from:startIndex];
}

- (void)startPlan:(NSArray<NSDictionary *> *)steps
            loops:(NSInteger)loops
         failsafe:(NSDictionary *)failsafe
          loopGap:(double)loopGap
             from:(NSInteger)startIndex {
    if (_running) {
        [self logMsg:@"已经在跑了"];
        return;
    }
    if (steps.count == 0) {
        [self logMsg:@"脚本是空的，先录一遍"];
        return;
    }
    _running = YES;
    _gen++;
    NSUInteger gen = _gen;
    // 悬浮条 164×74 浮在左上角，正好盖住评论编辑区的「图片」按钮和相册的选图
    // 圆圈。回放期间挪到屏幕最顶上（不隐藏 —— 用户要能按 ■ 随时停），跑完归位。
    dispatch_async(dispatch_get_main_queue(), ^{ TDFloatParkTop(); });
    // 音量减 = 急停（悬浮条在顶部是主要手段，这是闭着眼也能摸到的备用）
    TDVolumeStopArm(YES);
    // 回放期间把每次识图的整屏画面留一份：编辑页的「框选区域」拿它当底图，
    // 否则在编辑页里只能截到我们自己的界面，框了也没意义。
    TDSetShotCacheEnabled(YES);
    _loopsDone = 0;
    _curIndex = 0;
    _floatBarWarned = NO;
    _failsafe = failsafe;
    _failsafeFired = NO;
    _inFailsafe = NO;
    _fbIndex = 0;
    _fsPos = failsafe ? [failsafe[@"pos"] integerValue] : 0;
    if (_fsPos < 0 || _fsPos > 2) _fsPos = 0;
    NSArray *plan = [steps copy];
    _currentPlan = plan;

    NSInteger firstFrom = MAX(0, MIN(startIndex, (NSInteger)plan.count - 1));
    if (startIndex > 0 && firstFrom > 0) {
        [self logMsg:@"从第 %ld 步开始跑（共 %lu 步）", (long)firstFrom + 1, (unsigned long)plan.count];
    }
    if (_stoppedAt >= 0) {
        [self logMsg:@"上次停在第 %ld 步，这次仍从第 %ld 步起", (long)_stoppedAt + 1, (long)firstFrom + 1];
        _stoppedAt = -1;
    }

    [self logMsg:@"开始：%lu 步，循环 %@%@", (unsigned long)plan.count,
                  loops == 0 ? @"无限" : [NSString stringWithFormat:@"%ld 次", (long)loops],
                  loopGap > 0 ? [NSString stringWithFormat:@"，每轮间隔 %.0fms", loopGap] : @""];
    if (failsafe) {
        NSArray *fsteps = failsafe[@"steps"];
        NSString *tpl = [failsafe[@"tpl"] isKindOfClass:[NSString class]] ? failsafe[@"tpl"] : @"";
        [self logMsg:@"判断已开：%@找不到时跑 %lu 步兜底动作（%@，%@）",
                      tpl.length ? tpl : @"任意",
                      (unsigned long)fsteps.count,
                      [failsafe[@"once"] boolValue] ? @"只第一次触发" : @"每次都触发",
                      [self failsafePosDesc]];
    }

    dispatch_async(_q, ^{
        NSInteger round = 0;
        NSInteger from = firstFrom;
        while (self->_running && self->_gen == gen) {
            // 判断放在「脚本开始」：开跑之前先看一眼画面，
            // 图不在就直接做兜底动作，然后再按原样跑主脚本。
            if (self->_fsPos == 1) { @autoreleasepool { [self failsafeGate:@"脚本开始"]; } }
            if (!self->_running || self->_gen != gen) break;

            for (NSInteger i = from; i < (NSInteger)plan.count; i++) {
                if (!self->_running || self->_gen != gen) break;
                self->_curIndex = i;
                @autoreleasepool { [self execStep:plan[i]]; }
            }
            from = 0;                       // 只有第一轮认起点，后面都从头
            self->_curIndex = -1;

            // 判断放在「脚本末尾」：这一轮跑完了再回头检查，图不在就补一段兜底。
            if (self->_fsPos == 2) { @autoreleasepool { [self failsafeGate:@"脚本末尾"]; } }
            if (self->_gen != gen) return;  // 已经开了新一轮，收尾不归我

            round++;
            self->_loopsDone = round;
            if (loops > 0 && round >= loops) break;
            // 每轮之间歇一下：整段播完立刻从头再点，节奏比人快得多
            if (loopGap > 0) usleep((useconds_t)(MIN(loopGap, 30000.0) * 1000));
        }

        // 只清理自己这一轮：用户「按 ■ 立刻再按 ▶」时，新线程已经接管了 _running，
        // 老线程的尾巴绝对不能再写它（否则新的一轮刚起来就被掐死）。
        if (self->_gen != gen) return;
        // 还在「跑」的状态下走到这儿 = 正常跑完 / 轮次用完；
        // 已经是 NO 了 = 被用户按 ■ 打断 —— 记下停在哪一步，下次日志里说出来。
        BOOL userStopped = !self->_running;
        self->_stoppedAt = (userStopped && self->_curIndex >= 0) ? self->_curIndex : -1;
        self->_running = NO;
        self->_curIndex = -1;
        // 收尾就关掉：留在内存里的最后一张才是「抖音画面」，
        // 再开着的话，App 里的试识别会把这张换成我们自己的界面。
        TDSetShotCacheEnabled(NO);
        // 悬浮条归位（回放期间停到顶部过），急停卸膛
        dispatch_async(dispatch_get_main_queue(), ^{ TDFloatUnpark(); });
        TDVolumeStopArm(NO);
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
            [self logMsg:@"%@按概率跳过（run=%.0f%%）", [self stepTag:st], run * 100];
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

/// 落点压在悬浮条上就否决这一步。
/// 悬浮条是比抖音更高的真实窗口，注入的触摸落进去命中的是我们自己的球：
/// 落在 ● 上会一路开始录制（用户看到的「播放变成录制」），落在 ■ 上会当场停脚本
/// （用户看到的「每次播都从 0 开始」）。所以宁可跳过并说清楚，也不能让它砸上去。
/// 返回 YES = 这一步被拦下了。
- (BOOL)vetoFloatBarAt:(CGPoint)p step:(NSDictionary *)st {
    if (!TDHitsFloatBar(p)) return NO;
    if (!_floatBarWarned) {
        _floatBarWarned = YES;
        CGRect r = TDFloatTouchRect();
        [self logMsg:@"%@ 落点 (%.0f,%.0f) 压在悬浮条 (%.0f,%.0f %.0f×%.0f) 上，已跳过 —— 把悬浮条拖到别处再跑",
                      [self stepTag:st], p.x, p.y, r.origin.x, r.origin.y, r.size.width, r.size.height];
    }
    return YES;
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
        if ([self vetoFloatBarAt:p step:st]) {
            usleep((useconds_t)(interval * 1000));
            return;
        }
        TDtap(p.x, p.y);
        usleep((useconds_t)(interval * 1000));
        return;
    }

    // 粘贴：把评论话术塞进「当前有焦点」的输入框。
    // 取文本 → 写剪贴板（写完回读校验）→ 双击输入框 → 识图点「粘贴」气泡（认不到按偏移点）。
    // 输入框位置取「上一次注入的落点」—— 也就是脚本里点评论框那一下。
    if ([t isEqualToString:@"paste"]) {
        NSString *txt = [st[@"text"] isKindOfClass:[NSString class]] ? [st[@"text"] copy] : nil;
        BOOL fromPool = (txt.length == 0);
        if (fromPool) txt = TDCommentPick();
        if (txt.length == 0) {
            [self logMsg:@"%@ 要粘贴，但评论池是空的（去脚本编辑页加几条话术）", [self stepTag:st]];
            return;
        }
        // 有 x/y 就用脚本给的锚点；没有就退回「上一次点击的落点」
        CGPoint anchor = st[@"x"]
            ? CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue])
            : [self pasteAnchorFor:st];
        BOOL tapAnchor = st[@"tap"] ? [st[@"tap"] boolValue] : (anchor.x > 0 && anchor.y > 0);
        BOOL clearFirst = st[@"clear"] ? [st[@"clear"] boolValue] : YES;
        // 走「自前台写剪贴板 → 切回 app → ⌘A → ⌘V」：抖音那种自定义输入框
        // 没有「粘贴」菜单，只有这条能进去。
        BOOL ok = TDPasteIntoOtherApp(txt, st[@"app"], tapAnchor, anchor, clearFirst);
        NSString *show = txt.length > 12 ? [[txt substringToIndex:12] stringByAppendingString:@"…"] : txt;
        [self logMsg:@"%@ 粘贴%@：%@（剪贴板%@）", [self stepTag:st], fromPool ? @"（池随机）" : @"",
                      show, ok ? @"✓" : @"✗"];
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"long"]) {
        CGPoint p = TDJitter(CGPointMake([st[@"x"] doubleValue], [st[@"y"] doubleValue]), jitter);
        if ([self vetoFloatBarAt:p step:st]) {
            usleep((useconds_t)(interval * 1000));
            return;
        }
        double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 800;
        TDlongPress(p.x, p.y, MAX(120.0, ms * msScale) / 1000.0);
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"swipe"]) {
        CGPoint a = TDJitter(CGPointMake([st[@"x1"] doubleValue], [st[@"y1"] doubleValue]), jitter);
        CGPoint b = TDJitter(CGPointMake([st[@"x2"] doubleValue], [st[@"y2"] doubleValue]), jitter);
        // 滑动只看起点：起点压在悬浮条上，这一笔会被我们自己吃掉，抖音收不到。
        if ([self vetoFloatBarAt:a step:st]) {
            usleep((useconds_t)(interval * 1000));
            return;
        }
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
            if ([self vetoFloatBarAt:[pts.firstObject CGPointValue] step:st]) {
                usleep((useconds_t)(interval * 1000));
                return;
            }
            double ms = st[@"ms"] ? [st[@"ms"] doubleValue] : 500;
            TDgesture(pts, MAX(120.0, ms * msScale) / 1000.0);
        }
        usleep((useconds_t)(interval * 1000));
        return;
    }

    // 点赞：先看心是白的还是红的，红了就跳过 —— 保证重复跑不会把赞取消掉
    if ([t isEqualToString:@"like"]) {
        double x = st[@"x"] ? [st[@"x"] doubleValue] : 379;
        double y = st[@"y"] ? [st[@"y"] doubleValue] : 328;
        // 心形就在评论气泡正上方 74pt。同一竖列一起浮动，所以拿评论气泡的
        // 模板反推心形位置，比另做一套心形模板省事，也不怕「已赞变红」。
        {
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            UIImage *ct = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"tpl_comment.png"]];
            if (ct) {
                TDMatch *m = TDfindImageSmartInRect(ct, @"tpl_comment", 0.70,
                                                    CGRectMake(330, 240, 84, 440), NULL);
                if (m) { x = m.point.x; y = m.point.y - 69; }
            }
        }
        CGRect box = CGRectMake(x - 15, y - 15, 30, 30);
        double l = 0, c = 0, red0 = 0, d = 0;
        if (!TDregionStats(box, &l, &c, &red0, &d)) {
            [self logMsg:@"%@ 点赞：读不到画面，跳过", [self stepTag:st]];
            return;
        }
        if (red0 > 0.12) {
            [self logMsg:@"%@ 点赞：已经是红的（%.2f），跳过", [self stepTag:st], red0];
            return;
        }
        TDtap(x, y);
        usleep(1300 * 1000);                 // 等红心动画走完再判，早了会误判
        double red1 = 0;
        TDregionStats(box, &l, &c, &red1, &d);
        // 用「变红多少」而不是「红不红」：视频本身偏红也不会误判
        if (red1 > 0.12 || red1 > red0 + 0.06) {
            [self logMsg:@"%@ 点赞：成功（红 %.2f→%.2f）", [self stepTag:st], red0, red1];
        } else {
            [self logMsg:@"%@ 点赞：点完没变红（%.2f→%.2f），不重试（重试会把已赞的取消）",
                          [self stepTag:st], red0, red1];
        }
        usleep((useconds_t)(interval * 1000));
        return;
    }

    // 评论（带本机多图）：按固定顺序一条龙，每一步都校验，任一环不过就不发送。
    //   点评论气泡 → 点输入框(弹键盘) → 点图片 → 点「多选」→ 点前几张图的圆圈
    //   → 点「下一步」→ ⌘A+⌘V 贴池里的话术 → 发送 → 校验 → 关面板
    //
    // 为什么要先点输入框：评论面板刚打开、键盘没弹的时候，底部输入条上只有
    // 「@」和「表情」两个图标，压根没有图片按钮；键盘一弹，编辑区顶上来，
    // 图片/@/表情/发送 才排成一行出现。顺序搞反就点进 @ 面板了。
    if ([t isEqualToString:@"comment"]) {
        NSString *tag = [self stepTag:st];
        double cx = st[@"cx"] ? [st[@"cx"] doubleValue] : 385;   // 评论气泡（模板兜底）
        double cy = st[@"cy"] ? [st[@"cy"] doubleValue] : 397;
        double ix = st[@"ix"] ? [st[@"ix"] doubleValue] : 150;   // 无键盘时的输入条
        double iy = st[@"iy"] ? [st[@"iy"] doubleValue] : 695;
        double ux = st[@"ux"] ? [st[@"ux"] doubleValue] : 373;   // 相册右上「多选」
        double uy = st[@"uy"] ? [st[@"uy"] doubleValue] : 46;
        double nx = st[@"nx"] ? [st[@"nx"] doubleValue] : 207;   // 底部「下一步(n)」
        double ny = st[@"ny"] ? [st[@"ny"] doubleValue] : 697;
        double sx = st[@"sx"] ? [st[@"sx"] doubleValue] : 377;   // 键盘弹起后的「发送」
        double sy = st[@"sy"] ? [st[@"sy"] doubleValue] : 403;
        NSString *app = [st[@"app"] isKindOfClass:[NSString class]] ? st[@"app"] : @"snssdk1128://";
        NSString *txt = [st[@"text"] isKindOfClass:[NSString class]] ? st[@"text"] : nil;
        if (txt.length == 0) txt = TDCommentPick();
        if (txt.length == 0) { [self logMsg:@"%@ 评论池是空的（先加几条话术）", tag]; return; }
        NSArray *cells = [st[@"cells"] isKindOfClass:[NSArray class]] ? st[@"cells"]
                          : @[@[@86, @282], @[@190, @282], @[@295, @282]];

        void (^closePanel)(void) = ^{
            TDswipe(CGPointMake(207, 250), CGPointMake(207, 700), 0.30);
            usleep(900 * 1000);
        };
        double l = 0, c = 0, r = 0, d = 0;

        // 1) 定位评论气泡再点。
        //    右侧这一竖排图标会随视频文案长短整体上下浮动（文案三行时比一行
        //    低 20pt），写死坐标迟早点空。用模板找，找不到才退回默认坐标。
        CGPoint bubble = CGPointMake(cx, cy);
        {
            NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            UIImage *ct = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"tpl_comment.png"]];
            if (ct) {
                TDMatch *m = TDfindImageSmartInRect(ct, @"tpl_comment", 0.70,
                                                    CGRectMake(330, 240, 84, 440), NULL);
                if (m) {
                    bubble = m.point;
                    [self logMsg:@"%@ 评论气泡认在 (%.0f,%.0f)，相似度 %.2f", tag, bubble.x, bubble.y, m.score];
                } else {
                    [self logMsg:@"%@ 没认出评论气泡，用默认坐标 (%.0f,%.0f)", tag, cx, cy];
                }
            }
        }
        TDtap(bubble.x, bubble.y);
        usleep(1600 * 1000);
        NSString *hit = nil;
        BOOL open = TDCommentPanelOpen(&hit);
        if (!open) {
            [self logMsg:@"%@ 面板没开（OCR 没看到评论字样），再点一次", tag];
            TDtap(bubble.x, bubble.y);
            usleep(1800 * 1000);
            open = TDCommentPanelOpen(&hit);
        }
        if (!open) { [self logMsg:@"%@ 评论面板打不开，这条跳过", tag]; return; }
        [self logMsg:@"%@ 面板已开（OCR：「%@」）", tag, hit ?: @"?"];

        // 2) 点一下输入条把键盘叫起来。
        //    「键盘起来了」的证据 = 底部这行冒出「图片」小图标（没弹键盘时只有 @ 和表情）。
        //    顺手用模板把这个图标的位置量出来 —— 面板高度变了也能跟着走。
        NSString *dirP = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        UIImage *picTpl = [UIImage imageWithContentsOfFile:[dirP stringByAppendingPathComponent:@"tpl_pic.png"]];
        CGRect picROI = CGRectMake(0, 340, 180, 130);
        TDMatch *mp = picTpl ? TDfindImageSmartInRect(picTpl, @"tpl_pic", 0.72, picROI, NULL) : nil;
        if (!mp) {
            TDtap(ix, iy);
            usleep(1300 * 1000);
            mp = picTpl ? TDfindImageSmartInRect(picTpl, @"tpl_pic", 0.72, picROI, NULL) : nil;
        }
        if (!mp) {
            [self logMsg:@"%@ 键盘没起来（底部没出现「图片」按钮），这条跳过", tag];
            closePanel();
            return;
        }
        [self logMsg:@"%@ 键盘已弹起，「图片」在 (%.0f,%.0f)", tag, mp.point.x, mp.point.y];

        // 3) 点「图片」→ 相册
        TDtap(mp.point.x, mp.point.y);
        usleep(2400 * 1000);
        double la = 0, ca = 0, ra = 0, da = 0;
        BOOL album = TDregionStats(CGRectMake(300, 36, 80, 20), &la, &ca, &ra, &da)
                     && la > 170 && ca < 12;
        if (!album) {
            [self logMsg:@"%@ 相册没打开（亮 %.0f 彩 %.0f），再点一次", tag, la, ca];
            TDtap(mp.point.x, mp.point.y);
            usleep(2400 * 1000);
            album = TDregionStats(CGRectMake(300, 36, 80, 20), &la, &ca, &ra, &da)
                    && la > 170 && ca < 12;
        }
        if (!album) { [self logMsg:@"%@ 相册打不开，这条跳过", tag]; closePanel(); return; }

        // 4) 切多选：相册右上角那颗胶囊按钮。
        //    多选态和单选态长得差不多，唯一确凿的差别是勾完图底部才冒红色
        //    「下一步(n)」—— 所以切完先别急着信，勾完图再验。
        TDtap(ux, uy);
        usleep(1300 * 1000);

        // 5) 挨个点格子右上角的小圆圈。
        //    这个版本的相册在多选态下，点格子本体是进大图预览、不是勾选，
        //    只有点右上角那个圆圈才算勾上 —— 所以坐标给的是圆圈中心。
        NSInteger picked = 0;
        for (NSArray *pt in cells) {
            if (![pt isKindOfClass:[NSArray class]] || pt.count < 2) continue;
            TDtap([pt[0] doubleValue], [pt[1] doubleValue]);
            picked++;
            usleep(700 * 1000);
        }
        if (picked == 0) { [self logMsg:@"%@ 没给要选哪几张图，这条跳过", tag]; closePanel(); return; }

        // 6) 勾上的证据：底部那条红色「下一步(n)」
        double l5 = 0, c5 = 0, red5 = 0, d5 = 0;
        BOOL multi = TDregionStats(CGRectMake(30, 688, 354, 26), &l5, &c5, &red5, &d5)
                     && red5 > 0.35;
        if (!multi) {
            [self logMsg:@"%@ 没勾上（底部没有红色下一步，红 %.2f）—— 多半是没进多选，这条跳过",
                          tag, red5];
            closePanel();
            return;
        }
        [self logMsg:@"%@ 已勾 %ld 张，点下一步", tag, (long)picked];
        TDtap(nx, ny);
        usleep(2400 * 1000);

        // 7) 回到编辑框：缩略图挂上了，键盘可能被收起 —— 用「图片」图标判断，
        //    没弹就再点一下输入条。贴文案前必须让它重新弹起来。
        TDMatch *mp2 = picTpl ? TDfindImageSmartInRect(picTpl, @"tpl_pic", 0.72, picROI, NULL) : nil;
        if (!mp2) {
            TDtap(ix, iy);
            usleep(1300 * 1000);
            mp2 = picTpl ? TDfindImageSmartInRect(picTpl, @"tpl_pic", 0.72, picROI, NULL) : nil;
        }
        [self logMsg:@"%@ 缩略图已挂上，键盘%@", tag, mp2 ? @"已弹起" : @"没起来"];

        // 8) 贴话术：切前台写剪贴板 → 切回抖音 → ⌘A 全选 → ⌘V。
        //    键盘还弹着就别再点输入框了（会点到键盘上），光标本来就在里面。
        BOOL kbdNow = (mp2 != nil);
        BOOL wrote = TDPasteIntoOtherApp(txt, app, !kbdNow, CGPointMake(ix, iy), YES);
        usleep(900 * 1000);

        // 9) 校验文字落进去了：OCR 找文案前 4 个字。
        //    挂了 3 张缩略图之后编辑区整体上移，靠「某块区域有黑字」这种亮度判据
        //    会漂；OCR 直接看字，位置变了也认得出。
        NSString *probe = txt.length > 4 ? [txt substringToIndex:4] : txt;
        BOOL landed = NO;
        for (int i = 0; i < 6 && !landed; i++) {
            for (NSDictionary *ln in TDocrLines(TDscreenshot())) {
                NSString *sv = ln[@"s"];
                if ([sv isKindOfClass:[NSString class]] && sv.length &&
                    [sv containsString:probe]) { landed = YES; break; }
            }
            if (!landed) usleep(400 * 1000);
        }
        if (!wrote || !landed) {
            [self logMsg:@"%@ 文字没落进输入框（剪贴板%@，OCR%@看到「%@」），不发送",
                          tag, wrote ? @"✓" : @"✗", landed ? @"" : @"没", probe];
            closePanel();
            return;                          // 绝不发空评论
        }
        [self logMsg:@"%@ 文案已落进编辑框：%@", tag, txt];

        // 10) 发送
        TDtap(sx, sy);
        usleep(2400 * 1000);

        // 11) 校验：面板里应该看得到刚发出去的文案
        BOOL seen = NO;
        NSString *key = txt.length > 6 ? [txt substringToIndex:6] : txt;
        for (int i = 0; i < 2 && !seen; i++) {
            NSArray *lines = TDocrLines(TDscreenshot());
            for (NSDictionary *ln in lines) {
                NSString *str = [ln[@"s"] isKindOfClass:[NSString class]] ? ln[@"s"] : @"";
                if (str.length && [str containsString:key]) { seen = YES; break; }
            }
            if (!seen) usleep(700 * 1000);
        }
        [self logMsg:@"%@ 评论%@：%@", tag, seen ? @"已发出" : @"未确认（OCR 没看到）", txt];

        // 12) 返回（下拉收面板）
        closePanel();
        usleep((useconds_t)(interval * 1000));
        return;
    }

    if ([t isEqualToString:@"find"]) {
        NSString *name = st[@"tpl"];
        if (name.length == 0) {
            [self logMsg:@"%@是识图，但还没选模板", [self stepTag:st]];
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
            // 判断放在首/尾时，失败当场不兜底 —— 那一轮的首尾会自己检查
            if (self->_fsPos == 0) [self runFailsafeFor:name];
            return;
        }

        // 识别区域：每个识图事件可以单独框一块，只在框里找。
        // 判定按「模板中心落在框内」，框比模板小也能用（只框住按钮的一角）。
        CGRect roi = CGRectNull;
        NSArray *ra = st[@"roi"];
        if ([ra isKindOfClass:[NSArray class]] && ra.count >= 4) {
            roi = CGRectMake([ra[0] doubleValue], [ra[1] doubleValue],
                             [ra[2] doubleValue], [ra[3] doubleValue]);
            if (roi.size.width < 2 || roi.size.height < 2) roi = CGRectNull;
        }

        // 识图本身有一次「等画面稳定」的语义：抖音翻页动画没结束时截到的是糊图，
        // 所以给了超时就在这里轮询，而不是一帧没命中就判死。
        CFTimeInterval deadline = CACurrentMediaTime() + MAX(0.0, timeoutMs) / 1000.0;
        TDMatch *m = nil;
        NSInteger tries = 0;
        BOOL scaledHit = NO;
        while (self->_running) {
            tries++;
            // smart 查找内部按「记住的尺度 → 原尺度 → 尺度扫描」逐级退让：
            // 内置的小图标（38px）第一次会扫出真正的倍数并记住，之后就走窄扫。
            m = TDfindImageSmartInRect(tpl, name, th, roi, &scaledHit);
            if (m) break;
            if (timeoutMs <= 0 || CACurrentMediaTime() >= deadline) break;
            usleep(200 * 1000);
        }

        if (!m) {
            if (CGRectIsNull(roi)) {
                [self logMsg:@"识图没找到 %@（阈值 %.2f，试了 %ld 次）", name, th, (long)tries];
            } else {
                [self logMsg:@"识图没找到 %@（阈值 %.2f，只在框 (%.0f,%.0f %.0f×%.0f) 里找，试了 %ld 次）",
                              name, th, roi.origin.x, roi.origin.y,
                              roi.size.width, roi.size.height, (long)tries];
            }
            if (self->_fsPos == 0) [self runFailsafeFor:name];
            return;
        }
        if (scaledHit) {
            [self logMsg:@"识图 %@ 靠尺度扫描命中（%.2f×），已记住这个倍数", name, m.scale];
        }

        CGPoint p = TDJitter(CGPointMake(m.point.x + dx, m.point.y + dy), jitter);
        double hold = st[@"ms"] ? [st[@"ms"] doubleValue] : 0;
        if (hold > 0) {
            TDlongPress(p.x, p.y, MAX(120.0, hold * msScale) / 1000.0);
        } else {
            TDtap(p.x, p.y);
        }
        [self logMsg:@"识图 %@ %.2f → 点 (%.0f,%.0f)%@", name, m.score, p.x, p.y,
                      CGRectIsNull(roi) ? @"" : @"（框内命中）"];
        usleep((useconds_t)(interval * 1000));
        return;
    }
}

/// 粘贴要用的「输入框在哪儿」。
/// 优先用刚刚注入过的落点（脚本里点评论框那一下就是它）；
/// 没有就往前翻最近的点击步骤（脚本刚启动、还没点过任何东西时用得上）。
/// 两者都没有就返回 (0,0)，粘贴那边会退回 Cmd+V，绝不瞎长按屏幕。
- (CGPoint)pasteAnchorFor:(NSDictionary *)st {
    if (TDLastTapPointReady()) return TDLastTapPoint();
    NSInteger idx = (NSInteger)[_currentPlan indexOfObjectIdenticalTo:st];
    for (NSInteger i = idx - 1; i >= 0; i--) {
        NSDictionary *p = _currentPlan[i];
        NSString *pt = p[@"t"];
        if ([pt isEqualToString:@"tap"] || [pt isEqualToString:@"long"]) {
            return CGPointMake([p[@"x"] doubleValue], [p[@"y"] doubleValue]);
        }
    }
    return CGPointZero;
}

/// 判断的位置说成人话（日志里用）
- (NSString *)failsafePosDesc {
    switch (_fsPos) {
        case 1:  return @"位置＝每轮脚本开始";
        case 2:  return @"位置＝每轮脚本末尾";
        default: return @"位置＝识图失败当场";
    }
}

/// 这条判断到底在判断哪张图：
/// 指定了模板就用它；没指定就取脚本里第一个识图步骤的模板。
/// 两个都没有 = 没东西可判断（首/尾这种「主动看一眼」的模式就没法做）。
- (NSString *)failsafeSubjectTpl {
    NSString *want = [_failsafe[@"tpl"] isKindOfClass:[NSString class]] ? _failsafe[@"tpl"] : @"";
    if (want.length) return want;
    for (NSDictionary *st in _currentPlan) {
        if (![[st[@"t"] description] isEqualToString:@"find"]) continue;
        NSString *n = [st[@"tpl"] isKindOfClass:[NSString class]] ? st[@"tpl"] : @"";
        if (n.length) return n;
    }
    return nil;
}

/// 首/尾判断的闸门：主动截一屏看目标图在不在。
/// 在 → 什么都不做；不在 → 跑兜底动作（走 runFailsafeFor，所以 once / 模板匹配照常生效）。
- (void)failsafeGate:(NSString *)where {
    NSDictionary *fs = _failsafe;
    if (!fs || _inFailsafe || !_running) return;
    if (![fs[@"on"] boolValue]) return;

    NSString *tplName = [self failsafeSubjectTpl];
    if (tplName.length == 0) {
        [self logMsg:@"判断设在「%@」，但没选模板、脚本里也没有识图步骤 → 没法判断，跳过", where];
        return;
    }
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    UIImage *img = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:tplName]];
    if (!img) {
        [self logMsg:@"判断（%@）：模板 %@ 不在，直接兜底", where, tplName];
        [self runFailsafeFor:tplName];
        return;
    }

    double th = [TDConfig shared].threshold;
    TDMatch *m = TDfindImageSmart(img, tplName, th, NULL);
    if (m) {
        [self logMsg:@"判断（%@）：%@ 在（%.2f）→ 不用兜底", where, tplName, m.score];
        return;
    }
    [self logMsg:@"判断（%@）：%@ 不在（阈值 %.2f）", where, tplName, th];
    [self runFailsafeFor:tplName];
}

/// 步骤序号（只为日志好读：能对上编辑页里的第几行）。
/// 兜底动作不在主计划里，单独编号，免得日志里冒出「第 1 步」这种误导。
- (NSString *)stepTag:(NSDictionary *)st {
    if (_inFailsafe) return [NSString stringWithFormat:@"兜底第 %ld 步", (long)_fbIndex];
    return [NSString stringWithFormat:@"第 %ld 步", (long)[self stepOrdinal:st]];
}

/// 判断：识图找不到时做什么。
///
/// 只在「配置开 + 模板对得上（空=任意）+ 没超次数」时执行；
/// 兜底动作本身也走 execStep，所以每一步的随机率、位置半径、压力范围全都照常生效 ——
/// 录完以后在编辑页里给这几步加随机，就等于「兜底操作也带随机屏幕参数」。
- (void)runFailsafeFor:(NSString *)tpl {
    NSDictionary *fs = _failsafe;
    if (!fs || _inFailsafe || !_running) return;
    if (![fs[@"on"] boolValue]) return;

    NSString *want = [fs[@"tpl"] isKindOfClass:[NSString class]] ? fs[@"tpl"] : @"";
    // 「检查哪张图」只用来限制「识图失败当场」这一种：那时是某一步的模板失败了，
    // 选的图对不上就不该乱兜底。首尾两种是闸门自己判定过的，再卡一次会变成
    // 「点了脚本末尾却永远不触发」。
    if (_fsPos == 0 && want.length && ![want isEqualToString:tpl]) {
        [self logMsg:@"判断只对 %@ 生效，这次失败的是 %@", want, tpl];
        return;
    }
    if ([fs[@"once"] boolValue] && _failsafeFired) {
        [self logMsg:@"判断设了「只触发一次」，已经用过就不再兜底"];
        return;
    }
    NSArray *steps = [fs[@"steps"] isKindOfClass:[NSArray class]] ? fs[@"steps"] : nil;
    if (steps.count == 0) {
        [self logMsg:@"判断命中了，但兜底动作是空的（去「判断编辑」里录一段）"];
        return;
    }

    _failsafeFired = YES;
    _inFailsafe = YES;
    [self logMsg:@"判断触发：%@ 没找到 → 执行 %lu 步兜底动作",
                  tpl.length ? tpl : @"识图", (unsigned long)steps.count];

    _fbIndex = 0;
    for (NSDictionary *st in steps) {
        if (!_running) break;
        _fbIndex++;
        // 兜底步骤的 gap 没人帮它展开（engineSteps 只处理主计划），这里自己歇
        double g = [st[@"gap"] doubleValue];
        if (g > 30) usleep((useconds_t)(MIN(g, 8000.0) * 1000));
        @autoreleasepool { [self execStep:st]; }
    }
    _fbIndex = 0;
    _inFailsafe = NO;
    [self logMsg:@"兜底动作跑完，回到主脚本"];
}

/// 步骤序号（只为日志好读：能对上编辑页里的第几行）
- (NSInteger)stepOrdinal:(NSDictionary *)st {
    return (NSInteger)[self->_currentPlan indexOfObjectIdenticalTo:st] + 1;
}

@end
