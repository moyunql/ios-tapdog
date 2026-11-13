#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 触摸注入（IOHIDEvent 全局注入）

BOOL TDhidReady(void);
NSString *TDhidStatus(void);

void TDtap(CGFloat x, CGFloat y);
void TDlongPress(CGFloat x, CGFloat y, NSTimeInterval sec);
void TDswipe(CGPoint from, CGPoint to, NSTimeInterval sec);
/// 多点轨迹手势，points 为 NSValue(CGPoint)，sec 为总时长
void TDgesture(NSArray<NSValue *> *points, NSTimeInterval sec);

#pragma mark - 截屏

BOOL TDcaptureReady(void);
NSString *TDcaptureStatus(void);
UIImage * _Nullable TDscreenshot(void);

#pragma mark - 识图（模板匹配）

@class TDMatch;

/// 在当前屏幕上查找模板图，返回最佳匹配；score 为归一化相关度(0~1)
TDMatch * _Nullable TDfindImage(UIImage *tpl, double threshold, double minScale, double maxScale, int scaleSteps);

@interface TDMatch : NSObject
@property (nonatomic) double score;
@property (nonatomic) CGPoint point;   // 匹配中心，屏幕点坐标
@property (nonatomic) CGFloat scale;
@end

#pragma mark - 脚本引擎

@class TDEngine;

@interface TDEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *msg);
- (void)startWithScript:(NSDictionary *)script;
- (void)stop;
- (void)logMsg:(NSString *)fmt, ...;
@end

#pragma mark - 配置

@interface TDConfig : NSObject
@property (nonatomic) double jitterPx;      // 点击随机偏移半径(点)
@property (nonatomic) double tapHoldMs;     // 按下保持毫秒
@property (nonatomic) double intervalMs;    // 步骤间基础间隔
@property (nonatomic) double threshold;     // 识图相似度阈值
@property (nonatomic) NSInteger loopCount;  // 0=无限
+ (instancetype)shared;
- (NSMutableArray<NSMutableDictionary *> *)steps;
- (void)save;
- (void)load;
- (void)addStep:(NSDictionary *)step;
- (void)removeStepAtIndex:(NSInteger)idx;
- (void)moveStepFrom:(NSInteger)from to:(NSInteger)to;
@end

/// 屏幕点尺寸 / 像素尺寸 换算比（用于把截图像素坐标转成点击点坐标）
CGFloat TDscreenScaleRatio(void);

NS_ASSUME_NONNULL_END
