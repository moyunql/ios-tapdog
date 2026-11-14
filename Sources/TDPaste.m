#import "TD.h"
#include <stdlib.h>
#include <unistd.h>

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
//   2) 长按 + 识图    同上，但用识图找「粘贴」气泡（内置模板 tpl_paste.png）。
//   3) 双击 + 点菜单  双击输入框弹编辑菜单 → 按偏移点「粘贴」。
//   4) 双击 + 识图    双击弹菜单 → 识图找「粘贴」气泡再点（默认）。
//
// 为什么默认是「双击 + 识图」：本机实测长按只会弹放大镜 / 不弹菜单，
// 双击才稳定出「粘贴」气泡；气泡位置又跟着光标和键盘高度飘，所以干脆不猜坐标，
// 直接截屏认「黑底白字『粘贴』」这个小气泡（模板从用户截图里裁的，就在图库内置项里）。
//
// 注意五点：
//   1) 写剪贴板到系统可见有一小段延迟，写完立刻落字会贴到上一条旧内容（160ms 够）。
//   2) UIPasteboard 归 UI 侧管，统一回主线程读写，写完立刻回读校验一次。
//   3) 双击/点菜单都会改「上次落点」，粘贴结束要把它还回去，否则连着贴两次会按
//      上一次菜单的位置去双击。
//   4) 长按之前先单击一下锚点。脚本里点的是底部「写下你的评论」，那一下只是把
//      输入框叫出来，焦点不一定在框里；不先点一下就拿不到编辑菜单的「粘贴」。
//   5) 识图认到的位置必须离输入框不远（气泡一定在输入框上方），否则当误认丢掉，
//      退回「按偏移点」。
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
// 菜单弹在哪儿：双击点的正上方 40~50pt（iOS 编辑菜单跟着光标走）。
// 屏幕底部输入框、键盘在下面的时候，菜单一定在输入框上方，所以默认 dy = -46。
// 但默认那条路是识图，这个偏移只是「认不出来时」的兜底，所以不必调得多准。
// 每台机器/每个 App 的间距可能差几 pt，所以给了「偏移」可以在评论池页现场调。

static NSString * const kPasteMethodKey = @"tdPasteMethod";
static NSString * const kPasteVerKey    = @"tdPasteVer";
static NSString * const kPasteMenuDXKey = @"tdPasteMenuDX";
static NSString * const kPasteMenuDYKey = @"tdPasteMenuDY";
static NSString * const kPasteHoldKey   = @"tdPasteHoldMs";
static NSString * const kPasteAnchorKey = @"tdPasteAnchorKind";
static NSString * const kPasteAnchorAX  = @"tdPasteAnchorAX";
static NSString * const kPasteAnchorAY  = @"tdPasteAnchorAY";
static NSString * const kPasteTplName   = @"tpl_paste.png";

/// 设置版本：v1.17 起默认改成「双击 + 识图」，老安装里存的方式/偏移一并作废
/// （旧默认是长按 + dy=-62，那套在本机根本没验证通过过，留着只会误导）。
static const NSInteger kPasteVerNow = 2;

NSInteger TDPasteMethod(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d integerForKey:kPasteVerKey] < kPasteVerNow) return 4;
    NSInteger m = [d integerForKey:kPasteMethodKey];
    return (m < 0 || m > 4) ? 4 : m;
}

void TDSetPasteMethod(NSInteger m) {
    if (m < 0 || m > 4) m = 4;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:m forKey:kPasteMethodKey];
    [d setInteger:kPasteVerNow forKey:kPasteVerKey];
}

NSString *TDPasteMethodDesc(void) {
    switch (TDPasteMethod()) {
        case 0:  return @"Cmd+V";
        case 1:  return @"长按 + 点菜单";
        case 2:  return @"长按 + 识图粘贴";
        case 3:  return @"双击 + 点菜单";
        default: return @"双击 + 识图粘贴";
    }
}

CGPoint TDPasteMenuOffset(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d integerForKey:kPasteVerKey] < kPasteVerNow) return CGPointMake(0, -46);
    if ([d objectForKey:kPasteMenuDXKey] == nil) return CGPointMake(0, -46);
    return CGPointMake((CGFloat)[d doubleForKey:kPasteMenuDXKey],
                       (CGFloat)[d doubleForKey:kPasteMenuDYKey]);
}

void TDPasteSetMenuOffset(CGFloat dx, CGFloat dy) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (dy > -12) dy = -12;      // 往上一点才有意义，贴在手指下面肯定不对
    [d setDouble:dx forKey:kPasteMenuDXKey];
    [d setDouble:dy forKey:kPasteMenuDYKey];
    [d setInteger:kPasteVerNow forKey:kPasteVerKey];
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

#pragma mark - 剪贴板

/// 写剪贴板 + 立刻回读。返回 NO 说明要么没写进去，要么被系统同步吃了 ——
/// 这两种情况在「粘贴出来的还是上一句」时很难分清，所以直接把它记进日志。
BOOL TDPasteCopyToClipboard(NSString *text) {
    if (text.length == 0) return NO;
    void (^put)(void) = ^{
        [UIPasteboard generalPasteboard].string = text;
    };
    if ([NSThread isMainThread]) put();
    else dispatch_sync(dispatch_get_main_queue(), put);

    NSString *back = [UIPasteboard generalPasteboard].string;
    return [back isEqualToString:text];
}

NSString *TDPasteClipboardText(void) {
    __block NSString *s = nil;
    void (^get)(void) = ^{ s = [UIPasteboard generalPasteboard].string; };
    if ([NSThread isMainThread]) get();
    else dispatch_sync(dispatch_get_main_queue(), get);
    if (s.length > 40) s = [[s substringToIndex:40] stringByAppendingString:@"…"];
    return s ?: @"";
}

#pragma mark - 识图找「粘贴」

/// 截屏找「粘贴」气泡，认到了就点。找到返回 YES。
/// 模板优先用 Documents 里那份（用户可以在图库换掉），没有就用 bundle 里的内置图。
static BOOL TDPasteTapPasteBubble(CGPoint near, double threshold) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    UIImage *tpl = [UIImage imageWithContentsOfFile:
                    [(dir ?: NSTemporaryDirectory()) stringByAppendingPathComponent:kPasteTplName]];
    if (!tpl) {
        NSString *src = [[NSBundle mainBundle] pathForResource:@"tpl_paste"
                                                        ofType:@"png"
                                                   inDirectory:@"tpl"];
        if (src) tpl = [UIImage imageWithContentsOfFile:src];
    }
    if (!tpl) {
        TDLog(@"粘贴：没找到「粘贴」模板（tpl_paste.png）→ 按偏移点");
        return NO;
    }

    // 菜单弹出有动画，一次认不到不代表没有：隔 300ms 再认，最多三次
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt) usleep(300 * 1000);
        TDMatch *m = TDfindImageSmart(tpl, kPasteTplName, threshold, NULL);
        if (!m) continue;

        // 气泡一定在输入框上方不远处。认到屏幕别处的「白字黑底」（视频字幕之类）就当误认。
        BOOL nearOK = fabs(m.point.x - near.x) < 220 &&
                      m.point.y < near.y + 60 && m.point.y > 30;
        if (!nearOK) {
            TDLog(@"粘贴：识图认出「粘贴」但在 (%.0f,%.0f)，离输入框 (%.0f,%.0f) 太远 → 当误认",
                  m.point.x, m.point.y, near.x, near.y);
            continue;
        }
        TDtap(m.point.x, m.point.y);
        TDLog(@"粘贴：识图点到「粘贴」气泡 (%.0f,%.0f) 相似度 %.2f · 尺度 %.2f",
              m.point.x, m.point.y, m.score, m.scale);
        return YES;
    }
    TDLog(@"粘贴：三次都没认出「粘贴」气泡（阈值 %.2f）→ 按偏移点", threshold);
    return NO;
}

/// 剪贴板体检：写一次、主线程读、后台读，把 uid 一起带回来。
///
/// 起因：远程发 text 时日志一直是「剪贴板已写入 4 字」紧接着「回读和要贴的内容不一致」，
/// 屏幕上自然也就没有「粘贴」按钮。TrollStore 装的 App 如果是 root 身份的进程，
/// pasteboardd 会直接拒收它的写入 —— 写不报错、读回来是空，症状完全对得上。
/// 所以先把 uid 和三条读回路径的真实结果摊开，别再靠猜。
NSDictionary *TDclipDiagnose(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"uid"] = @(getuid());
    d[@"euid"] = @(geteuid());
    NSString *probe = @"TapDog剪贴板";
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        d[@"pbName"] = pb.name.length ? pb.name : @"(空)";
        pb.string = probe;
    });
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        d[@"readMain"] = pb.string.length ? pb.string : @"(nil)";
        d[@"items"] = @(pb.numberOfItems);
        d[@"types"] = pb.types.count ? [pb.types componentsJoinedByString:@","] : @"(空)";
    });
    UIPasteboard *pb2 = [UIPasteboard generalPasteboard];   // 后台线程再读一次
    d[@"readBg"] = pb2.string.length ? pb2.string : @"(nil)";
    d[@"ok"] = @([d[@"readMain"] isEqualToString:probe]);
    return d;
}

/// 在 anchor 处粘贴一条文本。anchor 只是「上次落点」的候选，
/// 真正用哪个由「锚点」设置决定（见上面那段注释）。
void TDPasteTextAt(NSString *text, CGPoint anchor) {
    TDPasteTextAtMode(text, anchor, -1);     // -1 = 按设置里的老办法
}

/// mode：0 = 先单击聚焦再发 Cmd+V（最省事，只要剪贴板真的有东西）
///       1 = 长按弹菜单  2 = 双击弹菜单  3 = 只写剪贴板，不落字  -1 = 照设置来
void TDPasteTextAtMode(NSString *text, CGPoint anchor, NSInteger modeIn) {
    if (text.length == 0) return;

    if (!TDPasteCopyToClipboard(text)) {
        TDLog(@"粘贴：剪贴板回读和要贴的内容不一致（系统可能还没同步完）");
    }
    TDLog(@"粘贴：剪贴板已写入 %lu 字", (unsigned long)text.length);

    if (modeIn == 3) return;      // 只写剪贴板：给「先复制、再手动粘贴」留的路

    if (modeIn == 0) {
        // Cmd+V 这条路不依赖屏幕上有没有「粘贴」气泡：单击把光标放进输入框，
        // 再把 Cmd+V 打进系统，UIKit 自己会翻成 paste:。
        // 之前默认走双击菜单，双击第二下正好落在评论列表的表情条上，
        // 于是「粘不进去」还顺手塞了个 🌹 进去。
        TDtap(anchor.x, anchor.y);
        usleep(420 * 1000);       // 等键盘起来、输入框拿到焦点
        TDsendCmdV();
        TDLog(@"粘贴：单击 (%.0f,%.0f) 聚焦后发 Cmd+V", anchor.x, anchor.y);
        return;
    }

    NSInteger method = TDPasteMethod();
    if (modeIn == 1) method = 1;             // 强制长按
    else if (modeIn == 2) method = 3;        // 强制双击
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

    usleep(160 * 1000);     // 等剪贴板同步出去，太急会贴到旧内容

    if (method == 0) {
        TDsendCmdV();
        return;
    }

    // 双击和点菜单都会改「上次落点」，跑完要还回去 ——
    // 否则一条脚本里连着两次粘贴，第二次会按上次菜单的位置去双击。
    BOOL hadKeep = TDLastTapPointReady();
    CGPoint keep = TDLastTapPoint();

    BOOL dbl = (method == 3 || method == 4);
    if (dbl) {
        // 双击：两下间隔必须短（>300ms 系统就不认成双击了）
        TDtap(a.x, a.y);
        usleep(85 * 1000);
        TDtap(a.x, a.y);
        usleep(760 * 1000);     // 等编辑菜单浮出来（双击比长按慢一点）
    } else {
        // 先单击拿焦点：脚本里点「评论」只是把输入框叫出来，光标不一定在框里；
        // 没有焦点时长按只会弹放大镜，不会给「粘贴」菜单。
        TDtap(a.x, a.y);
        usleep(230 * 1000);
        TDlongPress(a.x, a.y, MAX(0.5, TDPasteHoldMs() / 1000.0));
        usleep(760 * 1000);
    }

    BOOL done = NO;
    if (method == 2 || method == 4) {
        // 阈值从 0.62 提到 0.86：0.62 太松，屏幕上任意一处白字黑底都能凑到 0.6x，
        // 之前就是它把「粘贴」认到了表情条上，结果点出一朵 🌹。
        done = TDPasteTapPasteBubble(a, 0.86);
    }

    if (!done) {
        // 以前这里会「按校准偏移盲点一下菜单」。识别没成功时这一下基本是乱点
        // （实测会点到表情条），所以改成默认不点，只留日志；真要用偏移校准的，
        // 在设置里把 TDBlindMenu 打开。
        BOOL blind = [[NSUserDefaults standardUserDefaults] boolForKey:@"TDBlindMenu"];
        if (blind) {
            CGPoint off = TDPasteMenuOffset();
            TDtap(a.x + off.x, a.y + off.y);
            TDLog(@"粘贴：%@ (%.0f,%.0f)［%@］→ 按偏移点菜单 (%.0f,%.0f)",
                  dbl ? @"双击" : @"长按", a.x, a.y, TDPasteAnchorDesc(),
                  a.x + off.x, a.y + off.y);
        } else {
            TDLog(@"粘贴：%@ (%.0f,%.0f) 没弹出可认的「粘贴」，这次不落字",
                  dbl ? @"双击" : @"长按", a.x, a.y);
        }
    }

    usleep(180 * 1000);
    if (hadKeep) TDSetLastTapPoint(keep);
}

void TDPasteText(NSString *text) {
    TDPasteTextAt(text, TDLastTapPoint());
}
