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
    }
    return self;
}

- (NSTimeInterval)duration {
    double total = 0;
    for (NSDictionary *s in _steps) {
        total += [s[@"gap"] doubleValue] / 1000.0;
        NSString *t = s[@"t"];
        if ([t isEqualToString:@"wait"] || [t isEqualToString:@"long"] || [t isEqualToString:@"swipe"]) {
            total += [s[@"ms"] doubleValue] / 1000.0;
        } else {
            total += 0.08;
        }
    }
    return total;
}

- (NSString *)summary {
    NSInteger tap = 0, swp = 0, lng = 0;
    for (NSDictionary *s in _steps) {
        NSString *t = s[@"t"];
        if ([t isEqualToString:@"tap"]) tap++;
        else if ([t isEqualToString:@"swipe"]) swp++;
        else if ([t isEqualToString:@"long"]) lng++;
    }
    NSInteger secs = (NSInteger)llround([self duration]);
    return [NSString stringWithFormat:@"%lu 步 · 点%ld 滑%ld 长%ld · %ld:%02ld",
            (unsigned long)_steps.count, (long)tap, (long)swp, (long)lng,
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
    if ([t isEqualToString:@"wait"])  return [NSString stringWithFormat:@"等待 %.0fms", [st[@"ms"] doubleValue]];
    if ([t isEqualToString:@"find"])  return [NSString stringWithFormat:@"识图 %@ ≥%.2f", st[@"tpl"], [st[@"th"] doubleValue]];
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
                for (id st in steps) {
                    if ([st isKindOfClass:[NSDictionary class]]) [s.steps addObject:[st mutableCopy]];
                }
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
                         @"steps": s.steps ?: @[]}];
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
