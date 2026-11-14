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

@implementation TDEngine {
    BOOL _running;
    dispatch_queue_t _q;
    NSInteger _loopsDone;
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
    [self startPlan:steps loops:loops failsafe:nil loopGap:0];
}

/// 跑一条脚本：循环次数、每轮间隔、识图失败兜底全部按脚本自己的配置。
- (void)playScript:(TDScript *)script {
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
    [self startPlan:plan loops:loops failsafe:fs loopGap:gap];
}

- (void)startPlan:(NSArray<NSDictionary *> *)steps
            loops:(NSInteger)loops
         failsafe:(NSDictionary *)failsafe
          loopGap:(double)loopGap {
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
    _failsafe = failsafe;
    _failsafeFired = NO;
    _inFailsafe = NO;
    _fbIndex = 0;
    _fsPos = failsafe ? [failsafe[@"pos"] integerValue] : 0;
    if (_fsPos < 0 || _fsPos > 2) _fsPos = 0;
    NSArray *plan = [steps copy];
    _currentPlan = plan;

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
        while (self->_running) {
            // 判断放在「脚本开始」：开跑之前先看一眼画面，
            // 图不在就直接做兜底动作，然后再按原样跑主脚本。
            if (self->_fsPos == 1) { @autoreleasepool { [self failsafeGate:@"脚本开始"]; } }
            if (!self->_running) break;

            for (NSDictionary *st in plan) {
                if (!self->_running) break;
                @autoreleasepool { [self execStep:st]; }
            }
            if (!self->_running) break;

            // 判断放在「脚本末尾」：这一轮跑完了再回头检查，图不在就补一段兜底。
            if (self->_fsPos == 2) { @autoreleasepool { [self failsafeGate:@"脚本末尾"]; } }

            round++;
            self->_loopsDone = round;
            if (loops > 0 && round >= loops) break;
            // 每轮之间歇一下：整段播完立刻从头再点，节奏比人快得多
            if (loopGap > 0) usleep((useconds_t)(MIN(loopGap, 30000.0) * 1000));
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

    // 粘贴：把评论话术塞进「当前有焦点」的输入框。
    // 取文本 → 写剪贴板 → 长按输入框弹菜单再点「粘贴」（或 Cmd+V，看设置）。
    // 输入框位置取「上一次注入的落点」—— 也就是脚本里点评论框那一下。
    if ([t isEqualToString:@"paste"]) {
        NSString *txt = [st[@"text"] isKindOfClass:[NSString class]] ? [st[@"text"] copy] : nil;
        BOOL fromPool = (txt.length == 0);
        if (fromPool) txt = TDCommentPick();
        if (txt.length == 0) {
            [self logMsg:@"%@ 要粘贴，但评论池是空的（去脚本编辑页加几条话术）", [self stepTag:st]];
            return;
        }
        CGPoint anchor = [self pasteAnchorFor:st];
        TDPasteTextAt(txt, anchor);
        NSString *show = txt.length > 12 ? [[txt substringToIndex:12] stringByAppendingString:@"…"] : txt;
        [self logMsg:@"粘贴%@（%@）：%@", fromPool ? @"（池随机）" : @"", TDPasteMethodDesc(), show];
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
            m = TDfindImageSmart(tpl, name, th, &scaledHit);
            if (m) break;
            if (timeoutMs <= 0 || CACurrentMediaTime() >= deadline) break;
            usleep(200 * 1000);
        }

        if (!m) {
            [self logMsg:@"识图没找到 %@（阈值 %.2f，试了 %ld 次）", name, th, (long)tries];
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
        [self logMsg:@"识图 %@ %.2f → 点 (%.0f,%.0f)", name, m.score, p.x, p.y];
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
