#import "TD.h"
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 评论池 + 粘贴
//
// 一池话术，一行一条，存 Documents/comment_pool.txt。
// 回放到「粘贴」步骤时：随机取一条 → 写系统剪贴板 → 落字。
//
// 落字有几条路（v1.15 起不再默认 Cmd+V，因为这条在这台机器上完全没反应）：
//   0) Cmd+V         HID 键盘事件。工程上最干净，但这台机器的键盘通道对非平台进程
//                    是关着的：事件看着发出去了，前台 App 一个都没收到。
//   1) 长按 + 点菜单  长按输入框 → 系统弹出「拷贝/粘贴」编辑菜单 → 点「粘贴」。
//   2) 长按 + 识图    同上，但用识图找「粘贴」两个字（需要 tpl_paste.png 模板）。
//   3) 双击 + 点菜单  双击输入框同样会弹编辑菜单，而且不会触发放大镜 / 顺手选中
//                    一大片文字，对空输入框比长按更温和 —— 长按不弹菜单就换这个。
//
// 注意四点：
//   1) 写剪贴板到系统可见有一小段延迟，写完立刻落字会贴到上一条旧内容（150ms 够）。
//   2) UIPasteboard 归 UI 侧管，统一回主线程写，免得偶发「写进去了但同步不出去」。
//   3) 长按/点菜单都会改「上次落点」，粘贴结束要把它还回去，否则连着贴两次会按
//      上一次菜单的位置去长按。
//   4) 长按之前先单击一下锚点。脚本里点的是底部「写下你的评论」，那一下只是把
//      输入框叫出来，焦点不一定在框里；不先点一下就拿不到编辑菜单的「粘贴」。
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
static NSString * const kPasteAnchorKey = @"tdPasteAnchorKind";
static NSString * const kPasteAnchorAX  = @"tdPasteAnchorAX";
static NSString * const kPasteAnchorAY  = @"tdPasteAnchorAY";
static NSString * const kPasteTplName   = @"tpl_paste.png";

NSInteger TDPasteMethod(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteMethodKey] == nil) return 1;   // 默认：长按 + 点菜单
    NSInteger m = [d integerForKey:kPasteMethodKey];
    return (m < 0 || m > 3) ? 1 : m;
}

void TDSetPasteMethod(NSInteger m) {
    if (m < 0 || m > 3) m = 1;
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:kPasteMethodKey];
}

NSString *TDPasteMethodDesc(void) {
    switch (TDPasteMethod()) {
        case 0:  return @"Cmd+V";
        case 2:  return @"长按 + 识图「粘贴」";
        case 3:  return @"双击 + 点菜单";
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

// ---------------------------------------------------------------------------
// 锚点：到底「长按哪儿」才算按住输入框
//
// 一开始想用「脚本里点评论框那一下」当锚点，实际跑不通：点的是底部那条
// 「写下你的评论」，键盘一弹，输入框整个被顶到上面去了，原来那个点已经变成
// 键盘区域。所以默认改成「屏幕底部往上固定距离」这个估算值，并且可调。
//
//   0 = 上次注入落点（脚本里点的那一下）
//   1 = 屏幕底部输入框（默认）：x 居中，y = 屏幕高 + ay，ay 默认 -280
// ---------------------------------------------------------------------------

static BOOL TDPastePointValid(CGPoint p) {
    CGSize sb = [UIScreen mainScreen].bounds.size;
    return p.x > 1 && p.y > 1 && p.x < sb.width - 1 && p.y < sb.height - 1;
}

NSInteger TDPasteAnchorKind(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteAnchorKey] == nil) return 1;
    return [d integerForKey:kPasteAnchorKey] == 0 ? 0 : 1;
}

void TDPasteSetAnchorKind(NSInteger k) {
    [[NSUserDefaults standardUserDefaults] setInteger:(k == 0 ? 0 : 1) forKey:kPasteAnchorKey];
}

NSString *TDPasteAnchorDesc(void) {
    return TDPasteAnchorKind() == 0 ? @"上次落点" : @"底部输入框";
}

CGPoint TDPasteAnchorOffset(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:kPasteAnchorAY] == nil) return CGPointMake(0, -280);
    return CGPointMake((CGFloat)[d doubleForKey:kPasteAnchorAX],
                       (CGFloat)[d doubleForKey:kPasteAnchorAY]);
}

void TDPasteSetAnchorOffset(CGFloat ax, CGFloat ay) {
    // 夹一下：太靠下会落进键盘里，太靠上就不是输入框了
    if (ay > -20) ay = -20;
    if (ay < -700) ay = -700;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:ax forKey:kPasteAnchorAX];
    [d setDouble:ay forKey:kPasteAnchorAY];
}

static CGPoint TDPasteBottomAnchor(void) {
    CGSize sb = [UIScreen mainScreen].bounds.size;
    CGPoint off = TDPasteAnchorOffset();
    return CGPointMake(sb.width / 2.0 + off.x, sb.height + off.y);
}

static void TDPasteWriteClipboard(NSString *text) {
    void (^put)(void) = ^{
        [UIPasteboard generalPasteboard].string = text;
    };
    if ([NSThread isMainThread]) put();
    else dispatch_sync(dispatch_get_main_queue(), put);
}

/// 在 anchor 处粘贴一条文本。anchor 只是「上次落点」的候选，
/// 真正用哪个由「锚点」设置决定（见上面那段注释）。
void TDPasteTextAt(NSString *text, CGPoint anchor) {
    if (text.length == 0) return;

    TDPasteWriteClipboard(text);

    NSInteger method = TDPasteMethod();
    CGPoint a = anchor;

    if (method != 0) {
        if (TDPasteAnchorKind() == 1 || !TDPastePointValid(a)) {
            a = TDPasteBottomAnchor();
        }
        if (!TDPastePointValid(a)) {
            TDLog(@"粘贴：锚点不对（%.0f,%.0f）→ 退回 Cmd+V", a.x, a.y);
            method = 0;
        }
    }

    usleep(150 * 1000);     // 等剪贴板同步出去，太急会贴到旧内容

    if (method == 0) {
        TDsendCmdV();
        return;
    }

    // 长按和点菜单都会改「上次落点」，跑完要还回去 ——
    // 否则一条脚本里连着两次粘贴，第二次会按上次菜单的位置去长按。
    BOOL hadKeep = TDLastTapPointReady();
    CGPoint keep = TDLastTapPoint();

    if (method == 3) {
        // 双击：间隔必须短（>300ms 系统就不认成双击了），800ms 后菜单一定出来了
        TDtap(a.x, a.y);
        usleep(85 * 1000);
        TDtap(a.x, a.y);
        usleep(680 * 1000);
        TDLog(@"粘贴：双击 (%.0f,%.0f) 等菜单", a.x, a.y);
    } else {
        // 先单击拿焦点：脚本里点「评论」只是把输入框叫出来，光标不一定在框里；
        // 没有焦点时长按只会弹放大镜，不会给「粘贴」菜单。
        TDtap(a.x, a.y);
        usleep(230 * 1000);
        TDlongPress(a.x, a.y, MAX(0.5, TDPasteHoldMs() / 1000.0));
        usleep(720 * 1000);     // 等编辑菜单浮出来
    }

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
                if (hadKeep) TDSetLastTapPoint(keep);
                return;
            }
            TDLog(@"粘贴：菜单里没认出「粘贴」→ 按偏移点（菜单偏移可调）");
        } else {
            TDLog(@"粘贴：还没 %@ 模板（截一张菜单截图框出「粘贴」存成它）→ 按偏移点", kPasteTplName);
        }
    }

    CGPoint off = TDPasteMenuOffset();
    TDtap(a.x + off.x, a.y + off.y);
    TDLog(@"粘贴：%@ (%.0f,%.0f)［%@］→ 点菜单 (%.0f,%.0f)",
          method == 3 ? @"双击" : @"长按", a.x, a.y, TDPasteAnchorDesc(),
          a.x + off.x, a.y + off.y);
    usleep(150 * 1000);
    if (hadKeep) TDSetLastTapPoint(keep);
}

void TDPasteText(NSString *text) {
    TDPasteTextAt(text, TDLastTapPoint());
}
