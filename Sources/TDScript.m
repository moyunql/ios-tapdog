#import "TD.h"
#include <math.h>

// ---------------------------------------------------------------------------
// 脚本存储：Documents/scripts.json
// {"selected":0,"scripts":[{"name":"脚本1","created":1699…,"steps":[…]}]}
// ---------------------------------------------------------------------------

static NSString *TDScriptsPath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [dir stringByAppendingPathComponent:@"scripts.json"];
}

@implementation TDScript

- (instancetype)initWithName:(NSString *)name {
    if (self = [super init]) {
        _name = [name copy] ?: @"脚本";
        _createdAt = [[NSDate date] timeIntervalSince1970];
        _steps = [NSMutableArray array];
        // 判断默认关：老脚本打开就是原来的行为，不会莫名多出一段兜底动作
        // pos：判断在哪儿做 —— 0 识图失败当场 / 1 脚本开始时 / 2 脚本末（每轮跑完）
        _failsafe = [@{@"on": @NO, @"tpl": @"", @"once": @YES, @"pos": @0,
                       @"steps": [NSMutableArray array]} mutableCopy];
        // 循环默认关：一条脚本默认跑一遍
        _loop = [@{@"on": @NO, @"count": @1, @"gap": @800} mutableCopy];
    }
    return self;
}

- (BOOL)failsafeEnabled {
    return [_failsafe[@"on"] boolValue];
}

- (NSArray<NSDictionary *> *)failsafeSteps {
    id a = _failsafe[@"steps"];
    return [a isKindOfClass:[NSArray class]] ? a : @[];
}

- (NSString *)loopDesc {
    if (![_loop[@"on"] boolValue]) return @"不循环";
    NSInteger n = [_loop[@"count"] integerValue];
    return n <= 0 ? @"无限循环" : [NSString stringWithFormat:@"循环 %ld 次", (long)n];
}

- (NSTimeInterval)duration {
    double total = 0;
    for (NSDictionary *s in _steps) {
        total += [s[@"gap"] doubleValue] / 1000.0;
        NSString *t = s[@"t"];
        if ([t isEqualToString:@"wait"] || [t isEqualToString:@"long"] ||
            [t isEqualToString:@"swipe"] || [t isEqualToString:@"gesture"]) {
            total += [s[@"ms"] doubleValue] / 1000.0;
        } else if ([t isEqualToString:@"find"]) {
            total += 0.45 + [s[@"to"] doubleValue] / 1000.0 * 0.5;
        } else {
            total += 0.08;
        }
    }
    return total;
}

- (NSString *)summary {
    NSInteger tap = 0, swp = 0, lng = 0, img = 0, pst = 0;
    for (NSDictionary *s in _steps) {
        NSString *t = s[@"t"];
        if ([t isEqualToString:@"tap"]) tap++;
        else if ([t isEqualToString:@"swipe"]) swp++;
        else if ([t isEqualToString:@"long"]) lng++;
        else if ([t isEqualToString:@"gesture"]) swp++;
        else if ([t isEqualToString:@"find"]) img++;
        else if ([t isEqualToString:@"paste"]) pst++;
    }
    NSInteger secs = (NSInteger)llround([self duration]);
    NSMutableString *mix = [NSMutableString string];
    if (img > 0) [mix appendFormat:@" · 识图%ld", (long)img];
    if (pst > 0) [mix appendFormat:@" · 粘贴%ld", (long)pst];
    if ([_loop[@"on"] boolValue]) {
        [mix appendFormat:@" · %@", [self loopDesc]];
    }
    if ([self failsafeEnabled]) [mix appendString:@" · 有判断"];
    return [NSString stringWithFormat:@"%lu 步 · 点%ld 滑%ld 长%ld%@ · %ld:%02ld",
            (unsigned long)_steps.count, (long)tap, (long)swp, (long)lng, mix,
            (long)(secs / 60), (long)(secs % 60)];
}

- (NSArray<NSDictionary *> *)engineSteps {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in _steps) {
        double gap = [s[@"gap"] doubleValue];
        if (gap > 30) [out addObject:@{@"t": @"wait", @"ms": @(gap > 8000 ? 8000 : gap)}];
        [out addObject:s];
    }
    return out;
}

+ (NSString *)describeStep:(NSDictionary *)st {
    NSString *t = st[@"t"];
    if ([t isEqualToString:@"tap"])   return [NSString stringWithFormat:@"点击 (%.0f, %.0f)",
                                              [st[@"x"] doubleValue], [st[@"y"] doubleValue]];
    if ([t isEqualToString:@"long"])  return [NSString stringWithFormat:@"长按 (%.0f, %.0f) %.0fms",
                                              [st[@"x"] doubleValue], [st[@"y"] doubleValue], [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"swipe"]) return [NSString stringWithFormat:@"滑动 (%.0f,%.0f)→(%.0f,%.0f) %.0fms",
                                              [st[@"x1"] doubleValue], [st[@"y1"] doubleValue],
                                              [st[@"x2"] doubleValue], [st[@"y2"] doubleValue], [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"gesture"]) {
        NSArray *pts = st[@"pts"];
        NSArray *p0 = pts.count ? pts.firstObject : nil;
        NSArray *p1 = pts.count ? pts.lastObject : nil;
        return [NSString stringWithFormat:@"轨迹 %lu 点 (%.0f,%.0f)→(%.0f,%.0f) %.0fms",
                (unsigned long)pts.count,
                p0.count >= 2 ? [p0[0] doubleValue] : 0, p0.count >= 2 ? [p0[1] doubleValue] : 0,
                p1.count >= 2 ? [p1[0] doubleValue] : 0, p1.count >= 2 ? [p1[1] doubleValue] : 0,
                [st[@"ms"] doubleValue]];
    }
    if ([t isEqualToString:@"wait"])  return [NSString stringWithFormat:@"等待 %.0fms", [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"paste"]) {
        NSString *s = [st[@"text"] isKindOfClass:[NSString class]] ? st[@"text"] : @"";
        if (s.length == 0) return @"粘贴 · 评论池随机一条";
        if (s.length > 10) s = [[s substringToIndex:10] stringByAppendingString:@"…"];
        return [NSString stringWithFormat:@"粘贴「%@」", s];
    }
    if ([t isEqualToString:@"find"]) {
        NSString *name = st[@"tpl"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0) name = @"(未选模板)";
        if ([name hasPrefix:@"tpl_"]) name = [name substringToIndex:MIN((NSUInteger)13, name.length)];
        BOOL lng = [st[@"ms"] doubleValue] > 0;
        return [NSString stringWithFormat:@"识图%@ %@ ≥%.2f · 偏(%+.0f,%+.0f)",
                lng ? @"长按" : @"点击", name,
                st[@"th"] ? [st[@"th"] doubleValue] : 0.85,
                [st[@"dx"] doubleValue], [st[@"dy"] doubleValue]];
    }
    return t ?: @"?";
}

@end

#pragma mark - 存储

@implementation TDScriptStore

+ (instancetype)shared {
    static TDScriptStore *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TDScriptStore new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _scripts = [NSMutableArray array];
        [self load];
        if (_scripts.count == 0) [self createScript];
    }
    return self;
}

- (void)load {
    NSData *d = [NSData dataWithContentsOfFile:TDScriptsPath()];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *j = obj;

    [_scripts removeAllObjects];
    id arr = j[@"scripts"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id raw in arr) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            TDScript *s = [[TDScript alloc] initWithName:raw[@"name"] ?: @"脚本"];
            s.createdAt = [raw[@"created"] doubleValue];
            id steps = raw[@"steps"];
            if ([steps isKindOfClass:[NSArray class]]) {
                [s.steps removeAllObjects];
                for (id st in steps) {
                    if ([st isKindOfClass:[NSDictionary class]]) [s.steps addObject:[st mutableCopy]];
                }
            }
            // 循环 / 判断：JSON 读回来是只读容器，这里统一转成可改的，
            // 并且把「兜底动作」里的每一步也换成可变字典（编辑页会原地改它们）。
            NSDictionary *lp = raw[@"loop"];
            if ([lp isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [s.loop mutableCopy];
                for (id k in lp) m[k] = lp[k];
                s.loop = m;
            }
            NSDictionary *fs = raw[@"failsafe"];
            if ([fs isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *m = [NSMutableDictionary dictionary];
                for (id k in fs) {
                    if ([k isEqualToString:@"steps"]) continue;
                    m[k] = fs[k];
                }
                NSMutableArray *fsteps = [NSMutableArray array];
                id raw2 = fs[@"steps"];
                if ([raw2 isKindOfClass:[NSArray class]]) {
                    for (id st in raw2) {
                        if ([st isKindOfClass:[NSDictionary class]]) [fsteps addObject:[st mutableCopy]];
                    }
                }
                m[@"steps"] = fsteps;
                s.failsafe = m;
            }
            [_scripts addObject:s];
        }
    }
    _selected = [j[@"selected"] integerValue];
    if (_selected < 0 || _selected >= (NSInteger)_scripts.count) _selected = 0;
}

- (void)save {
    NSMutableArray *arr = [NSMutableArray array];
    for (TDScript *s in _scripts) {
        [arr addObject:@{@"name": s.name,
                         @"created": @(s.createdAt),
                         @"steps": s.steps ?: @[],
                         @"loop": s.loop ?: @{},
                         @"failsafe": s.failsafe ?: @{}}];
    }
    NSDictionary *j = @{@"selected": @(_selected), @"scripts": arr};
    NSData *d = [NSJSONSerialization dataWithJSONObject:j options:0 error:NULL];
    [d writeToFile:TDScriptsPath() atomically:YES];
}

- (TDScript *)createScript {
    NSString *name = [NSString stringWithFormat:@"脚本 %lu", (unsigned long)(_scripts.count + 1)];
    TDScript *s = [[TDScript alloc] initWithName:name];
    [_scripts addObject:s];
    _selected = (NSInteger)_scripts.count - 1;
    [self save];
    return s;
}

- (TDScript *)selectedScript {
    if (_scripts.count == 0) return nil;
    if (_selected < 0 || _selected >= (NSInteger)_scripts.count) _selected = 0;
    return _scripts[_selected];
}

- (void)removeAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)_scripts.count) return;
    [_scripts removeObjectAtIndex:idx];
    if (_selected >= (NSInteger)_scripts.count) _selected = (NSInteger)_scripts.count - 1;
    if (_selected < 0) _selected = 0;
    if (_scripts.count == 0) _selected = -1;
    [self save];
}

@end
