# KeepAwake（合盖保活）

顶栏上的一个开关：**合上盖子也不睡**，并且把「它现在到底开没开」摆在你眼前。

## 为什么做这个

MacBook 一贯的坑：合盖（clamshell）触发的是比「空闲睡眠」更底层的一刀，任何第三方
保活 App（Amphetamine / KeepingYouAwake / caffeinate）都拦不住 —— 它们申请的是 IOKit
电源断言，只能拦住「空闲睡眠」，拦不住合盖。绕开合盖睡眠只有两条公开路径：

1. 电源 + 外接显示器（Apple 原生 clamshell 模式）；
2. `pmset -a disablesleep 1` —— 把睡眠整个关掉，合盖也不睡。

路径 2 是纯软件的，但它有两个结构性缺陷，正是这个 App 存在的理由：

- **没有任何指示器。** 它是全局粘性设置，开着一整天不会有人告诉你，关掉了也不会。
- **会被别人改回去。** Apple Silicon 上切换电源适配器时 `powerd` 可能把它重置；
  命令行随手一改也一样。

顶栏图标（开着时换成橙色咖啡杯，关着时是月亮）解决的正是这两件事：状态可见、随手可切。

## 三个守护规则

| 规则 | 触发条件 | 为什么 |
| :--- | :--- | :--- |
| 热压力 | `ThermalState` 到 serious / critical | M3 Air 无内置风扇，合盖等于把屏那面也贴上；外置风扇不能当唯一防线 |
| 电量 | 离电，且电量 < 20% | 合盖塞进包里还在跑是最坏结局 |
| 登录自启 | LaunchAgent | 顶栏常驻，状态一眼可见 |

「拔掉电源就关」被明确否决 —— 所以离电时只要电量够就继续保持。

## 自愈 vs 跟随

`disablesleep` 是全局开关，谁都能改。App 的判据只有一条：

- 我们想开、系统却是关的，**而且电源来源刚刚变过（30 秒窗口）** → 判为 `powerd` 重置，补回来；
- 其余任何不一致 → **跟随系统**，并把「你的意图」同步过去。

第二半同样重要：你在命令行手动关掉时，App 不该跟你抢方向盘。

## 安装

```bash
sh scripts/build.sh                     # 编译 + 组装 build/KeepAwake.app
sh scripts/run-tests.sh                 # 29 项测试（Core 纯函数 + 只读集成 + 助手拒绝契约）
sh scripts/check-repo.sh                # 8 项仓库边界自检（独立、无远端、不外溢）
sh scripts/status-icon-probe.sh         # 可选：量顶栏图标有没有落在正中（给 ✓/✗ 和该改的数）
sh scripts/make-icon.sh <方形PNG>       # 可选：一张 PNG 换成 packaging/AppIcon.icns
sh scripts/make-dist.sh                 # 可选：打成能发给别人的 dist/KeepAwake-<版本>.{zip,dmg}

sudo sh scripts/install-helper.sh       # 一次性授权，需要你自己跑（要交互式输密码）
sh scripts/install-login-item.sh        # 登录自启，不需要 root，也要你自己跑
```

### 给别人的话

`sh scripts/make-dist.sh` 一次产出两种形式，装的东西一模一样：

| 形式 | 大小 | 特点 |
| :--- | :--- | :--- |
| `dist/KeepAwake-<版本>.dmg` | 约 1.7MB | macOS 习惯的「安装包」：挂载出一个卷，里面是 app + 一个指向 `/Applications` 的符号链接（拖拽目标）+ 说明书 |
| `dist/KeepAwake-<版本>.zip` | 约 1.2MB | 不用挂载，解压即得；命令行 / 脚本分发方便 |

zip 用 `ditto` 而不是 `zip` 命令：ditto 会保住 .app 的代码签名与扩展属性，普通 zip 压完再解
可能签名失效 —— 那正是「打开说已损坏」最常见的原因。两种形式都实测过：解包/挂载后
`codesign --verify` 仍通过，映像里的可执行文件与本地构建**逐字节一致**。

三个前提写在说明书里了，这里也记一遍：

- **只支持 Apple Silicon（arm64）+ macOS 13 以上**。Intel Mac 跑不了。
- **没有 Apple 公证签名**（ad-hoc 自签，`spctl -a` 实测 `rejected`）。用 U 盘 / 直传拿到的
  直接能开；**经浏览器下载的会被系统拦下**，收件人要去「系统设置 → 隐私与安全性 →
  仍要打开」。要彻底免掉这一步，只有买 Developer ID（一年 99 美元）并做公证。
- 那份 `安装说明.md` 里写了授权、使用、卸载和"装在包里记得关掉"的提醒 —— 这是给不熟的人看的，
  所以是完整句子的正文，不是备忘录。

`dist/` 在 `.gitignore` 里：压缩包是产物，不该进仓库；进仓库的是 `packaging/dist-readme.md`
（说明书的源）和 `scripts/make-dist.sh`。

### 署名这件事

- 当前是 **ad-hoc 签名**：`Signature=adhoc`、`TeamIdentifier=not set`。
  它只保证「签名之后文件没被动过」（完整性，可用 `CDHash` 核对），**不证明是谁做的**。
- **Team ID** 是 Apple 分配给 Developer Program 账号的 10 位标识，只有买了会员（99 美元/年）
  做 Developer ID 签名才会出现 —— 我们这里没有，因为它不是免费的，也不该为了"好看"去买。
- 不买会员也能署名：仓库里的 LICENSE + README 版权行 + git 提交记录。对开源分享来说够用。
- 唯一属于我们、且会影响用户的身份标识是 **bundle id**：已定为 `io.github.misehinoha.keepawake`
  （`io.github.<用户名>` 是开源项目常用的反域名写法，不依赖自购域名）。它决定「同一台机器上是哪一个
  app」—— 改了就等于另一个 app，用户的设置与登录项都要重来，所以**发布之后不要再改**。

### 许可证

**MIT**（见 `LICENSE`）：可以随便使用、修改、再分发，只要保留版权声明；作者不为使用后果负责。
选它是因为这个 app 小、无依赖、只做一件事 —— 用 GPL 去"防白嫖"没有意义，用 Apache 那套专利条款
（面向有专利组合的公司）也用不上。

版权行：`Copyright (c) 2026 MiseHinoha`。改署名就改 `LICENSE` 的第一行。

### 发布流程（维护者用）

对外发布用 `sh scripts/make-public.sh` 生成一份**干净快照**（默认 `/tmp/KeepAwake-public`），再从快照建仓库：

1. 从当前提交导出文件 —— `.gitattributes` 里标了 `export-ignore` 的路径（`.workbuddy/` 工作笔记、
   `dist/`、`build/`）会被跳过；
2. 在快照里重新 `git init`，做一个干净的初始提交；
3. 自检三条：不含工作笔记、不含电话号码式的邮箱串（`[0-9]{11}@`）、不含开发机上的绝对路径。

**为什么用快照而不是直接推本地历史**：开发仓库里带着工作笔记与开发环境的细节，只在最新提交里
删文件是不够的 —— 翻历史照样能看到。快照从零开始，开发历史一个字节都不动。代价是公开仓库没有
逐次提交的开发过程 —— 这个工具小，值得。

首次发布与发版：

```bash
gh repo create Keep-Awake --public --source=. --push          # 在快照目录里
gh release create v0.1.0 "dist/KeepAwake-0.1.0.zip" "dist/KeepAwake-0.1.0.dmg" \
  --title "0.1.0" --notes "首个公开版本"
```

后续发布把新快照导出到公开仓库的 clone 里提交即可（公开历史 = 一次发布一条提交，**不要 `--force`**
重推）。`scripts/check-repo.sh` 第 5 项允许「没有 remote」或「remote 只指向本项目自己的仓库」——
所以同一份自检在开发仓库和公开 clone 里都过，发布前不需要改脚本。


## 图标（两个，别混）

| | 顶栏图标 | 应用图标 |
| :--- | :--- | :--- |
| 资源 | **SF Symbol**（`moon.zzz` / `cup.and.saucer.fill`），换符号 = 改 `Sources/App/main.swift` 里一行 | `packaging/AppIcon.icns` |
| 谁看得见 | 你每天看的那一个 | `NSAlert` 弹窗、Finder、系统设置 → 登录项 |
| 需要图片资源吗 | **不需要** | 需要（已就位） |
| 怎么来 | 改代码 | 见下 |

### 顶栏那枚图标为什么要「自己画一张画布」

不能直接把 SF Symbol 挂到按钮上：符号给出来的是**按字体度量对齐**的图，两个符号各给一张
不同宽高的 —— 实测 `cup.and.saucer.fill` 是 20x15、`moon.zzz` 是 15x17。而顶栏按钮的宽和高
都是按这张图算出来的，于是两个状态的图标尺寸/位置各不一样（按钮 36x28 与 32x30、
分别比项目正中偏高 1.0 和 2.0 点）—— 切换时肉眼能看到图标上下错、左右跳。

所以 `Sources/App/StatusIcon.swift` 把两个符号都画进同一张 **20x28 的固定画布**、居中放：
两态都是 36x28 的项目，墨迹中心偏差 0.2 点（0.4 个物理像素，量不出来）。画布高 28 不是
按图形定的，而是按**项目高度**定的：普通图片做按钮时按钮高 = 图片高（实测 24 以下是 22 的下限），
取 28 就跟改动前一样高，点得中的范围和悬停高亮不会缩水。画布是透明的，高一点不会让图标变大。

量这件事用 `sh scripts/status-icon-probe.sh`：它建一个真实的顶栏项目、把按钮渲染出来数墨迹包围盒，
再跟项目窗口的正中比，末尾直接给 ✓/✗ 和该改的数（`StatusIcon.verticalNudge`）。它和 App 编译
同一份 `StatusIcon.swift`，量的就是线上那份画法。注意 `NSStatusBar.system.thickness` 实测报的是
22（经典菜单栏高度），而带刘海的机型项目窗口实际 34 点高 —— 对齐要看项目窗口，别用 thickness。

### 换桌面时图标为什么会闪回旧状态

系统在**换桌面（Space）/ 屏幕参数变化 / 从睡眠醒来**时会把整条菜单栏重新合成一遍，可能先端出
上一次的画面 —— 图标闪回先前的状态或尺寸，一直到 App 自己再画一次才恢复。默认 5 秒轮询太长，
所以 App 监听 `NSWorkspace.activeSpaceDidChangeNotification` 等通知，收到就把当前图标重写一遍
并标脏强制重画，动画落定后再补 0.4s / 1.0s 各一次。这一步**不写日志**：它只是重画、不是状态变化，
日志只记状态相关的事（启动、电源来源变化、手动切换、外部改动、守护触发）—— 换一次桌面就刷一行太吵。
另外图标实例只建一次、之后复用：每次 refresh 新建 `NSImage` 会让按钮重新排版，被合成器抓到的
正是那半帧 —— 看起来就是放大缩小。

应用图标 = **矢量画的圆角底板** + **像素风主体（冰咖啡）**。三套配色都归档了，当前生效的是 **cold**：

| 名称 | 配色 | 说明 |
| :--- | :--- | :--- |
| `cold`（当前生效） | 浅蓝 → 深蓝 | 呼应冰饮 |
| `warm` | 橙 → 深橙 | 沿用这个 app 原本的品牌色 |
| `dark` | 深灰蓝 → 近黑 | 浅色玻璃与深色咖啡都最跳，观感最"成品" |

轮换一条命令就够，随时可以换回去：

```bash
sh scripts/switch-icon.sh cold   # warm|cold|dark：渲染 → 归档 → 生成 icns → 重建 → 重启顶栏
sh scripts/switch-icon.sh all    # 只把三版重新归档，不动当前生效的那版
sh scripts/switch-icon.sh list   # 看现在生效的是哪一版

# 换素材时：先把带背景的图抠成透明主体
swiftc -O packaging/cutout.swift -o /tmp/cutout
/tmp/cutout 带背景的素材.png packaging/glass-subject.png   # 会打印残留分析 + 洋红预览图
```

三版 PNG 存在 `packaging/icon-variants/`（每版约 700KB）。`.icns` 不进仓库 —— 它每版近 1MB，
且完全由 PNG 决定，用时现生成。`list` 靠 `cmp` 比对源图与归档来判断，不另设状态文件：
少一个会过期的真相来源。

单独手动渲染某一版：

```bash
swiftc -O -parse-as-library packaging/draw-icon.swift -o /tmp/draw-icon
/tmp/draw-icon /tmp/out.png dark                     # 不给配色名就是 warm
sh scripts/make-icon.sh /tmp/out.png                 # PNG → packaging/AppIcon.icns
sh scripts/build.sh                                  # 构建时自动带上
```

抠图工具是四步流水线（色族泛滥 → 吃过渡边缘 → 形态学开运算 → 连通域筛选），
每一步都对应一次实测踩坑，注释里写了原因。没有 `.icns` 时构建照常成功，
只是弹窗和 Finder 里显示系统通用图标。

历史：早先那版是矢量画的热咖啡杯（带热气 / 茶碟 / 投影），后来换成这幅像素风冰咖啡。

第一次授权之后，切换就是顶栏点一下的事。没装授权也能用 —— App 会回退到系统授权框，
代价是每次都要输密码。

### 授权做了什么

装了 `/usr/local/sbin/keepawake-pmset`（root 拥有、755），并在
`/etc/sudoers.d/keepawake` 里放行**两个精确参数**：

```
Admin ALL=(root) NOPASSWD: /usr/local/sbin/keepawake-pmset on, /usr/local/sbin/keepawake-pmset off
```

（上面第一段是**你的登录用户名**，安装脚本用 `SUDO_USER` 取，不用手填。）

助手脚本本身只认 `on` / `off`，别的参数一律退出 64。所以即使有别的进程拿到这条免密
通道，能做的也只有改这一个电源开关 —— 最坏后果是电池耗光，碰不到数据。

撤销：`sudo rm /etc/sudoers.d/keepawake /usr/local/sbin/keepawake-pmset`。

## 设计取舍

- **为什么是 Swift 单文件而不是 Tauri。** 一个开关不值得背 200MB 工具链：`swiftc -O`
  两秒编译、产物 ~200KB，顶栏行为（`NSStatusItem`）和 Tauri 的 tray 一样。
  如果哪天要带自绘面板 / 动效的那种界面，再上 Tauri 不迟。
- **Core 层不含副作用。** `Sources/Core/PowerState.swift` 只做「读系统事实」和「纯函数
  判定」，UI 与特权命令都在 App 层 —— 所以 `Tests/` 能直接编译它来跑断言。
- **状态读取不需要 root。** 全部来自 `IOPMrootDomain`：
  `SleepDisabled` / `AppleClamshellState` / `AppleClamshellCausesSleep` / `Last Sleep Reason`。
  电池与电源来源走 `IOPS*` API，不起子进程，因此 5 秒轮询是安全的。

## 待实测确认

- 重启是否会清掉 `disablesleep`（社区说法不一）—— 装好后的第一次重启即可确认，
  日志（`~/Library/Logs/KeepAwake.log`）会留下记录。
- 换电源适配器时 `powerd` 是否真的重置该标志 —— 这是自愈逻辑的前提，实测后再定阈值。

## 目录

```
Sources/Core/PowerState.swift   系统事实读取 + 守护判定 + 分歧分类（纯函数）
Sources/App/StatusIcon.swift    顶栏图标画法：两态共用的固定画布 + 居中偏移
Sources/App/main.swift          顶栏图标、菜单、定时器、特权助手调用
Tests/main.swift                25 项断言
packaging/Info.plist            LSUIElement（只活顶栏）
packaging/keepawake-pmset       特权助手本体
packaging/cutout.swift          抠图工具：带背景的素材 → 透明主体
packaging/glass-subject.png     抠好的主体（像素风冰咖啡，546×793）
packaging/draw-icon.swift       图标渲染：矢量底板 + 主体（warm/cold/dark）
packaging/icon-variants/        三版配色归档（wheel 轮换用）
packaging/dist-readme.md        给收件人看的说明书（打进分发包）
packaging/AppIcon-source.png    当前生效的那版（cold）
packaging/AppIcon.icns          构建时自动带上的图标
scripts/switch-icon.sh          换图标配色：渲染 → 归档 → 重建 → 重启顶栏
scripts/status-icon-probe.sh    量顶栏图标落在哪：墨迹中心 vs 项目窗口正中（+ .swift 本体）
scripts/make-dist.sh            打 dist/KeepAwake-<版本>.zip（ditto，保住签名）
scripts/build.sh                编译 + 组装 .app（有 AppIcon.icns 就自动带上）
scripts/make-icon.sh            一张 PNG → packaging/AppIcon.icns（sips + iconutil）
scripts/run-tests.sh            跑测试（Swift + shell）
scripts/check-repo.sh           仓库边界自检（独立、无远端、不外溢）
scripts/install-helper.sh       一次性免密授权（需 sudo）
scripts/install-login-item.sh   登录自启（无需 sudo）
```
