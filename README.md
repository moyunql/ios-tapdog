# TapDog · iOS 识图连点器（TrollStore 版）

免越狱的 iOS 自动化工具，给作者自己的 iPhone 7 Plus / iOS 15.8.2 写的。
和 AutoTap 的区别：**多一个「识图点击」和「随机偏移」**，这就是它存在的全部理由。

## 能做什么

| 能力 | 说明 |
|---|---|
| 识图点击 | 截全屏 → 灰度金字塔 + 归一化互相关找模板 → 命中后点它中心。阈值可调，支持 0.7~1.3 倍缩放 |
| 点击 / 长按 | 全局注入，点任意 App |
| 滑动 | 起终点 + 真实时长，中途多帧 move（不是两点瞬移） |
| 轨迹手势 | 任意多点折线，按总时长匀速插值 |
| 随机偏移 | 每个点击/手势端点加半径 R 的随机圆内偏移，防机械轨迹检测 |
| 循环 / 间隔 | 无限循环或指定次数，步骤间基础间隔 |
| 悬浮球 | 盖在抖音上面，一点即开/停 |

## 原理（为什么必须这么写）

iOS 上想让一个 App 去点「别的 App」，只有一条路：**往系统 HID 栈里塞合成的触摸事件**。

```
IOHIDEventCreateDigitizerEvent(hand)
        └── IOHIDEventCreateDigitizerFingerEvent(finger)   ← 手指子事件
IOHIDEventSetIntegerValue(hand, IsDisplayIntegrated, 1)     ← 关键：当成屏上触摸
IOHIDEventSetSenderID(hand, 0x8000000817319372)             ← 关键：伪装成内建触摸屏
IOHIDEventSystemClientDispatchEvent(client, hand)           ← 派发给前台 App
```

这两步「关键」需要内核级权限，普通 App 一定被拒：

```
com.apple.private.hid.client.event-dispatch
com.apple.private.hid.client.event-filter
```

**TrollStore 安装时保留 ipa 里 ldid 写进去的 entitlements**，所以这条路在免越狱机器上能走通——
而「把 dylib 注入进抖音」走不通，因为抖音这个进程本身没有这些权限，注入的代码一律被拒。
市面上的注入型插件（含安姐点击器、1.dylib）在抖音上失效都是这个原因，不是配置问题。

截屏同理：靠 `IOMobileFramebuffer` 取主显示器 surface，需要
`com.apple.security.iokit-user-client-class = IOMobileFramebufferUserClient`。

## 编译

本机是 Windows，没法直接编 iOS。用 GitHub Actions 的 macOS 机器：

```bash
git push          # 触发 .github/workflows/build.yml
```

产物会作为 Release 资产出现，`apple-magnifier://install?url=<ipa 直链>` 用 TrollStore 装。

本地（macOS）也可直接：

```bash
brew install ldid
./build.sh
```

编译不依赖 `.xcodeproj`，直接 `clang` + `-Wl,-undefined,dynamic_lookup` 链私有符号。

## 用法

1. 打开 TapDog，顶部「状态」两行都应该是正常（HID 就绪 / 截屏正常）
2. 点第三行设置参数：**随机偏移**（建议 4~8 点）、**识图阈值**（0.85 起）
3. 「添加」区选一种：
   - `＋点击` → 全屏截图弹出，**点哪就在哪加一个点击**
   - `＋长按` → 长按屏幕某处
   - `＋滑动` → 按住拖一条线，时长自动取你拖的真实时长
   - `＋识图点击` → **点两下框出目标图**，自动存成模板并生成识图步骤
4. 右上角「开始」，然后切到抖音
5. 屏幕右侧有悬浮球，点一下停/继续

脚本存在 `Documents/tapdog.json`，模板图存 `Documents/tpl_N.png`，可直接用文件 App 改。

## 调参建议（抖音场景）

- 刷视频：`滑动` 从屏幕下方拖到上方即可（时长 350~600ms 最像真人）
- 自动点赞：框选右侧爱心图标做识图模板，阈值 0.88，偏移 5 点
- 别把间隔设太小（<300ms），容易触发风控，也容易点空

## 免责

仅供本人在自有设备上做自动化测试与效率工具。请遵守目标 App 的用户协议，
因使用本工具导致的账号风险由使用者自负。
