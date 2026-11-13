#import "TD.h"
#include <stdlib.h>

// ---------------------------------------------------------------------------
// 评论池 + 粘贴
//
// 一池话术，一行一条，存 Documents/comment_pool.txt。
// 回放到「粘贴」步骤时：随机取一条 → 写系统剪贴板 → 发 Cmd+V。
//
// 为什么不自己「逐字打进去」：抖音的评论框在别的进程里，我们摸不到它的
// UITextView；而键盘通道是系统级的 —— 只要输入框有焦点，Cmd+V 就会被 UIKit
// 翻成 paste:，把剪贴板内容贴进去。所以这里只负责「准备剪贴板」和「按一下粘贴」。
//
// 注意两点：
//   1) 写剪贴板到系统可见有一小段延迟，写完立刻按 Cmd+V 会贴到上一条旧内容，
//      所以中间必须等一下（120ms 实测够）。
//   2) UIPasteboard 归 UI 侧管，统一回主线程写，免得偶发「写进去了但同步不出去」。
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

void TDPasteText(NSString *text) {
    if (text.length == 0) return;

    void (^put)(void) = ^{
        [UIPasteboard generalPasteboard].string = text;
    };
    if ([NSThread isMainThread]) put();
    else dispatch_sync(dispatch_get_main_queue(), put);

    usleep(120 * 1000);     // 等剪贴板同步出去，太急会贴到旧内容
    TDsendCmdV();
}
