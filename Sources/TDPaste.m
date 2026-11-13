#import "TD.h"
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 评论池 + 粘贴
//
// 一池话术，一行一条，存 Documents/comment_pool.txt。
// 回放到「粘贴」步骤时：随机取一条 → 写系统剪贴板 → 落字。
//
// 落字有三条路（v1.15 加的后两条，因为 v1.14 的 Cmd+V 在这台机器上完全没反应）：
//   0) Cmd+V         HID 键盘事件。工程上最干净，但这台机器的键盘通道对非平台进程
//                    是关着的：事件看着发出去了，前台 App 一个都没收到。
//   1) 长按 + 点菜单  长按输入框 → 系统弹出「拷贝/粘贴」编辑菜单 → 点「粘贴」。
//                    全程触摸注入（已确认可用），落点 = 脚本里点评论框那一下。
//   2) 长按 + 识图    同上，但用识图找「粘贴」两个字（需要 tpl_paste.png 模板），
//                    菜单位置飘了也不会点错。
//
// 注意三点：
//   1) 写剪贴板到系统可见有一小段延迟，写完立刻落字会贴到上一条旧内容（150ms 够）。
//   2) UIPasteboard 归 UI 侧管，统一回主线程写，免得偶发「写进去了但同步不出去」。
//   3) 长按/点菜单都会改「上次落点」，粘贴结束要把它还回去，否则连着贴两次会按
//      上一次菜单的位置去长按。
// ---------------------------------------------------------------------------

static NSString *TDPoolPath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [(dir ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"comment_pool.txt"];
}

NSArray<NSString *> *TDCommentPool(void) {
    NSString *txt = [NSString stringWithContentsOfFile:TDPoolPath()
                                             encoding:NSUTF8StringEncoding
                                                error:NULL];
    if (txt.length == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    [txt enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *s = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 以 # 开头的是注释行，方便自己在 txt 里写备注
        if (s.length == 0 || [s hasPrefix:@"#"]) return;
        [out addObject:s];
    }];
    return out;
}

void TDCommentPoolSet(NSArray<NSString *> *lines) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *line in lines ?: @[]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        [s appendString:t];
        [s appendString:@"\n"];
    }
    [s writeToFile:TDPoolPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

NSInteger TDCommentPoolCount(void) {
    return (NSInteger)TDCommentPool().count;
}

NSString *TDCommentPick(void) {
    NSArray<NSString *> *pool = TDCommentPool();
    if (pool.count == 0) return nil;
    if (pool.count == 1) return pool.firstObject;

    // 连着发两条一样的话，看起来比「发得多」更像机器人；
    // 所以抽到和上一条相同的就重抽，最多试 8 次，试不出来也认了。
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:@"tdPoolLast"];
    for (int i = 0; i < 8; i++) {
        NSString *pick = pool[arc4random_uniform((uint32_t)pool.count)];
        if (![pick isEqualToString:last]) {
            [[NSUserDefaults standardUserDefaults] setObject:pick forKey:@"tdPoolLast"];
            return pick;
        }
    }
    return pool[arc4random_uniform((uint32_t)pool.count)];
}

#pragma mark - 粘贴方式

// 实测：这台机器的 HID 键盘事件打不进抖音的评论框（Cmd+V 没反应）。
// 键盘那条通道对「非平台进程」是关着的 —— 和触摸当初的 senderID 一个道理，
// 只是键盘没有「学一个真值」的机会（屏幕键盘根本不产生 HID 键盘事件）。
// 所以真正的出路是绕开键盘：只用触摸。
//
// 触摸能做的事：长按输入框 → 系统弹出「拷贝 / 粘贴」编辑菜单 → 点「粘贴」。
// 菜单点了就走了系统 pasteboard，和 Cmd+V 效果一样，但全程是触摸注入，
// 已经验证过能用（脚本里的点击就是它）。
//
// 菜单弹在哪儿：长按点的正上方大约 62pt（iOS 编辑菜单跟着光标走）。
// 屏幕底部输入框、键盘在下面的时候，菜单一定在输入框上方，所以默认 dy = -62。
// 每台机器/每个 App 的间距可能差几 pt，所以给了「偏移」可以在评论池页现场调。

static NSString * const kPasteMethodKey = @"tdPasteMethod";
static NSString * const kPasteMenuDXKey = @"tdPasteMenuDX";
static NSString * const kPasteMenuDYKey = @"tdPasteMenuDY";
static NSString * const kPasteHoldKey   = @"tdPasteHoldMs";
static NSString * const kPasteTplName   = @"tpl_paste.png";

NSInteger TDPasteMethod(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteMethodKey] == nil) return 1;   // 默认：长按 + 点菜单
    NSInteger m = [d integerForKey:kPasteMethodKey];
    return (m < 0 || m > 2) ? 1 : m;
}

void TDSetPasteMethod(NSInteger m) {
    if (m < 0 || m > 2) m = 1;
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:kPasteMethodKey];
}

NSString *TDPasteMethodDesc(void) {
    switch (TDPasteMethod()) {
        case 0:  return @"Cmd+V";
        case 2:  return @"长按 + 识图「粘贴」";
        default: return @"长按 + 点菜单";
    }
}

CGPoint TDPasteMenuOffset(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteMenuDXKey] == nil) return CGPointMake(0, -62);
    return CGPointMake((CGFloat)[d doubleForKey:kPasteMenuDXKey],
                       (CGFloat)[d doubleForKey:kPasteMenuDYKey]);
}

void TDPasteSetMenuOffset(CGFloat dx, CGFloat dy) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (dy > -12) dy = -12;      // 往上一点才有意义，贴在手指下面肯定不对
    [d setDouble:dx forKey:kPasteMenuDXKey];
    [d setDouble:dy forKey:kPasteMenuDYKey];
}

double TDPasteHoldMs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteHoldKey] == nil) return 900;
    return MAX(400.0, [d doubleForKey:kPasteHoldKey]);
}

void TDPasteSetHoldMs(double holdMs) {
    [[NSUserDefaults standardUserDefaults] setDouble:MAX(400.0, holdMs) forKey:kPasteHoldKey];
}

static void TDPasteWriteClipboard(NSString *text) {
    void (^put)(void) = ^{
        [UIPasteboard generalPasteboard].string = text;
    };
    if ([NSThread isMainThread]) put();
    else dispatch_sync(dispatch_get_main_queue(), put);
}

/// 在 anchor（输入框里的大致位置）粘贴一条文本。
void TDPasteTextAt(NSString *text, CGPoint anchor) {
    if (text.length == 0) return;

    TDPasteWriteClipboard(text);

    NSInteger method = TDPasteMethod();
    CGSize sb = [UIScreen mainScreen].bounds.size;
    BOOL ok = anchor.x > 1 && anchor.y > 1 && anchor.x < sb.width - 1 && anchor.y < sb.height - 1;
    if (method != 0 && !ok) {
        TDLog(@"粘贴：没记住输入框落点（先把评论框点开）→ 退回 Cmd+V");
        method = 0;
    }

    usleep(150 * 1000);     // 等剪贴板同步出去，太急会贴到旧内容

    if (method == 0) {
        TDsendCmdV();
        return;
    }

    // 长按和点菜单都会改「上次落点」，跑完要还回去 ——
    // 否则一条脚本里连着两次粘贴，第二次会按上次菜单的位置去长按。
    CGPoint keep = anchor;

    TDlongPress(anchor.x, anchor.y, MAX(0.5, TDPasteHoldMs() / 1000.0));
    usleep(700 * 1000);     // 等编辑菜单浮出来

    if (method == 2) {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        UIImage *tpl = [UIImage imageWithContentsOfFile:
                        [(dir ?: NSTemporaryDirectory()) stringByAppendingPathComponent:kPasteTplName]];
        if (tpl) {
            TDMatch *m = TDfindImageSmart(tpl, kPasteTplName, 0.70, NULL);
            if (m) {
                TDtap(m.point.x, m.point.y);
                TDLog(@"粘贴：识图点到「粘贴」（%.2f）", m.score);
                usleep(150 * 1000);
                TDSetLastTapPoint(keep);
                return;
            }
            TDLog(@"粘贴：菜单里没认出「粘贴」→ 按偏移点（菜单偏移可调）");
        } else {
            TDLog(@"粘贴：还没 %@ 模板（截一张菜单截图框出「粘贴」存成它）→ 按偏移点", kPasteTplName);
        }
    }

    CGPoint off = TDPasteMenuOffset();
    TDtap(anchor.x + off.x, anchor.y + off.y);
    TDLog(@"粘贴：长按 (%.0f,%.0f) → 点菜单 (%.0f,%.0f)",
          anchor.x, anchor.y, anchor.x + off.x, anchor.y + off.y);
    usleep(150 * 1000);
    TDSetLastTapPoint(keep);
}

void TDPasteText(NSString *text) {
    TDPasteTextAt(text, TDLastTapPoint());
}
