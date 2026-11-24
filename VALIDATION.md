# iOS 验证记录

## 0.1.33 / build 34：同步 Android PR #19 播放链路（2026-11-24）

同步 hongguo-android `eca9db8`（PR #19，含 `c0821c6` 与 `bd85341`，对应 Android v0.8.0）：匿名设备注册后调用 `app_alert_check` 激活并解析 `klink_egdi`；播放 query 补齐官方设备上下文（28 项 + `klink_egdi`）；medusa 信封升级为 38 字段 deviceInfo、9 字段 env、f16 设备令牌、f15 嵌套常量与 `4480…` flags。信封算法在 `PlayerSignV5.js` 内实现，38 字段结构复用 `PureSign.js` 目录签名已有的 `deviceProto` 形态。

`bd85341`（302 落地域白名单放宽、形状正常的被拒落地域换源重试）无需移植：iOS 的 `MediaRangeHTTP.allowedAfterRedirect` 本来就跟随任意公网 HTTPS 落地域（含 `bdcgslb.com`），明文、怪端口、带凭据和内网跳转仍终态且不触碰镜像，`ProgressiveTransportChecks` 已有断言覆盖。

**服务端 A/B（macOS 实网探针，同一台刚注册并激活的匿名设备、同一分集《无限白粥》第 1 集，两轮一致）：**

| 请求形态 | query 参数 | HTTP | 正文 | 结果 |
| --- | --- | --- | --- | --- |
| 旧信封 + 12 项设备 query（HEAD） | 21 | 200 | 0 字节 | 无片源 |
| 新信封 + 完整设备 query + `klink_egdi` | 39 | 200 | 23,550 字节 | code 0，5 条清晰度 |

注册响应实际下发 56 字符 `klink_egdi`；`app_alert_check` 返回 HTTP 200。对照组使用的是已激活设备，说明仅激活不足以恢复取源，信封与 query 升级是必要的。另两集（第 1、2 集）分别返回 23,550 与 14,643 字节的完整模型。

**离线检查：** `scripts/test-network.sh` 通过，`MobilePlaybackChecks` 新增设备上下文字段、`klink_egdi` 携带与解析的断言；`scripts/test-progressive.sh` 通过（含真实 AVPlayer 首帧与 seek）。Xcode 27.2 / iOS 27.2 SDK 模拟器 Debug 构建通过。

**模拟器（iPhone 18 Pro / iOS 27.0）：** `HongguoQATests.testV5PlaybackAndEpisodeSwitching` 通过（38.6 秒，0 失败）：搜索 → 详情 → 播放第 1 集 → 暂停/恢复 → 切第 2 集，导出截图确认真实画面与字幕。模拟器网络日志可见 App 进程连接 `log5-applog-lf.fqnovel.com`（注册与激活）、`api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/`（v5 取源）及 `*.bdcgslb.com` / `*.vegslb.com`（CDN 分块）。结果包 `/tmp/hongguo-v5-pr19.xcresult`。

**未验证：** 无签名 IPA 未在实体 iPhone 安装；`readMobilePlayback`（v5 POST）与单集接口未单独做实网探针，仅随信封升级一并受益；激活请求在 XCTest 进程中的状态码未直接读取，由 macOS 探针确认。

## 0.1.32 / build 33 播放空响应修复（2026-11-23，beta.1 测试包）

在 iPhone Duo 模拟器（iOS 27.1）上从 `DramaAPI.track(episodeID:seriesID:)` 发起取源。App 接口在进程内模拟，官网访客分集页、网页播放器取源、CDN 分块读取及 AVPlayer 解码走实网，每轮使用独立缓存。

| 分集 | App 接口模拟条件 | 模拟器实际结果 |
| --- | --- | --- |
| 《分家住破屋，我赶山带妻女吃肉》第 1 集 | 空正文及一次连接中断 | 360 × 640，时长 163.88 秒 |
| 《灾荒之年，我能往返两界》第 1 集 | 空正文及一次连接中断 | 640 × 360，时长 187.33 秒 |
| 《装穷提亲，娶到全家嫌弃的她》第 1 集 | 全部空正文 | 360 × 640，时长 168.55 秒 |
| 《铁血信使》第 1、2 集 | 全部空正文 | 均为 360 × 640，时长分别为 125.14 和 113.67 秒 |
| 《持械入宋：第七季》第 1 集 | 全部空正文 | 360 × 640，时长 92.67 秒 |
| 《分家住破屋，我赶山带妻女吃肉》第 31 集 | 全部空正文 | 官网未对访客开放，客户端提示不可用，未请求媒体 |

在相同的两组「空正文及一次连接中断」样本上，修复前均在官网取源前报 `NSURLErrorDomain/-1005`。修复后六个公开分集均自动切至官网，连续播放至少 11 秒，并在跳转到距片尾约 3 秒处后解码出画面。用离线延迟请求还验证了慢速重试会被取消，官网取源仍有可用时间。拒绝、限流、任务取消及模型错误的回归检查均通过。

本地无签名 arm64 iPhone IPA 已通过 `scripts/verify-ipa.py` 核对，大小为 2,068,676 字节，SHA-256 为 `712f2fa4f695a55878d557d7e17ea9607de8d440a7b5acbd5870671904dfe254`。本轮播放验证在模拟器上完成，实体 iPhone 安装待测。

## 网页片源回退实测（2026-11-23，未发布）

在 iPhone Duo 模拟器（iOS 27.1）上，向生产取源流程注入 App 接口的零字节响应。官网分集页、访客播放接口和 CDN 均走实网。使用临时缓存，通过应用的渐进播放器连续解码超过 11 秒，再跳到距离结尾约 3 秒处读取视频帧。

| 剧名 | 集数 | 媒体时长 | 解码到的片尾位置 |
| --- | --- | --- | --- |
| 铁血信使 | 1 | 125.14 秒 | 122.20 秒 |
| 铁血信使 | 2 | 113.67 秒 | 110.67 秒 |
| 铁血信使 | 3 | 90.33 秒 | 87.37 秒 |
| 持械入宋：第七季 | 1 | 92.67 秒 | 89.67 秒 |
| 持械入宋：第七季 | 10 | 官网未向访客开放 | 停在分集页，未请求视频 |

四个可播样本的实际解码尺寸均为 360 × 640。《铁血信使》第 2 集页面省略了时长字段，独立使用官网访客播放器读到 113.667 秒，与 iOS 读到的时长一致。样本中的 App 接口空响应由测试构造，未对实体 iPhone 上的原始故障做复现。

复测命令为 `scripts/test-public-episode-live.sh --live <已启动的模拟器UDID>`。省略 UDID 时使用 macOS AVFoundation。离线检查 `scripts/test-network.sh`、`scripts/test-media.sh`、`scripts/test-progressive.sh` 均通过。Xcode 27.2 无签名 iPhone Release 目标编译通过。

## 0.1.30 / build 31：官方弹幕（2026-11-21）

- 来源：同步 hongguo-android 0.7.32（PR #13；原始来源 tsukiyo-zero/hongguoTV、jycao2/hongguoTV，GPL-3.0-only）。播放页新增官方弹幕：30 秒窗口预取、固定行距滚动渲染、设置面板（开关、屏幕占比、字体大小、不透明度、文字效果、移动速度、恢复默认），emoji 代码展开为 Unicode 表情，U+FFFC 贴纸占位剔除。
- 结构：`Sources/Danmaku/` 五个文件——`DanmakuRepository`（actor，30 秒窗口 + 窗内分页、主机与签名形态轮换自愈、风控冷却、节流）、`DanmakuLoader`（提前 60 秒缓冲、快进跳过、1s/4s/15s 退避、连续 10 次失败放弃）、`DanmakuView`（CADisplayLink 滚动层，轨道分配与 Android 同算法）、`DanmakuPrefs`/`DanmakuSettings`（千分数落盘，键名与 Android 同语义）、`DanmakuEmoji`；UI 层 `DanmakuOverlay`（UIViewRepresentable，periodic time observer 缓存位置避免每帧查询播放器）与 `DanmakuPanels`（底部栏「弹」开关+齿轮入口、设置 sheet）。`AppModel.danmaku` 落盘，`PlayerView` 画面上方、手势层之下挂弹幕带（竖屏让出顶栏，横屏贴顶）。
- 离线：`test-network` 新增 `DanmakuChecks`（emoji 展开与簇区间、去重排序、风控冷却解析、退避阶梯、参数夹取、千分数往返）并纳入 Danmaku 纯逻辑四文件，与既有 v5/video_tab 套件同跑全过；account-rules、updates、library、media、progressive 及 10 项源生成检查无回归。
- 渲染层（DanmakuView/Overlay/面板）与工程由发布工作流 xcode-27 构建验证；本机 Xcode 27.2 对 SwiftUI 宏展开存在环境限制（未改动基线同样失败），不计为移植问题。工作流首两轮修复了三处编译期问题（PlayerView 弹幕开关误用 `copy`、`DanmakuView.init` 中 `self` 先于 `super.init`），全部为本地套件无法覆盖的 UI 层问题；最终 RUN 44927467789 成功。
- 发布后校验：`Hongguo-iOS-0.1.30-unsigned.ipa` 2,004,354 字节，SHA-256 `d9a02230b56196c0e0821bb4333dbfbfb9cc2b5cef2816acaecc212c1ba8b1bf`，与 Release 附件及 `distribution/update.json` 一致；官方 raw 与 gh-proxy、ghfast 两条加速线的 `update.json` 匿名下载哈希一致（`8bd1c39d…`）；`verify-ipa.py` 通过。
- 弹幕的真实取流与在屏渲染待实体 iPhone 验收；评论接口对模拟器设备身份可能风控冷却，Android 端同环境曾出现。

## 0.1.29 / build 30：video_tab v5 无正文 GET 取源（2026-11-21）

- 来源：同步 hongguo-android PR #12（jackotom/hongguo-drama 7.7，GPL-3.0-only）。2026-11-20 起上游取源接口变更，`player/v1` 的 v5 POST 与旧签名 `video_tab` 一律返回 HTTP 200 + 空正文，0.1.28 及更早版本触发「播放服务连续返回空响应」。
- 改动：`PlayerSignV5.js` 新增 `hgSignedPlaybackGetV5`（正文摘要按空 body 的 MD5 计算，仅返回 x-khronos / x-helios / x-medusa 三头，不带 x-ss-stub / Content-Type / Content-Encoding）；`ProtocolSigner.signedPlaybackGetV5` 桥接；`MobilePlayback` 提供 video_tab 端点、7.4.3.32 档位查询与 UA；`DramaAPI.playbackTrack` 在原有 mobile/single/routes 之前先尝试该路径，除取消外的失败按原顺序继续既有梯队。
- 离线：`test-network`（新增无正文 GET 签名断言：三头齐全、无 x-ss-stub、7.4.3.32 档位查询绑定分集与设备身份；既有 video_tab 解析与 v5 恒向量不变）、`test-account-rules`、`test-updates`、`test-library`、`test-media`、`test-progressive` 全部通过。
- IPA 由发布工作流（xcode-27 runner）构建并发布；本轮未做实网 `--live` 取流、未做实体 iPhone 安装验收。

## 0.1.27 / build 28：新版 v5 播放接口（2026-11-16）

- 来源：N3urda/hongguoTV `6672b55`（GPL-3.0-only），包含 0.16.5 的 v5 签名和 0.16.6 的 `device_level=1` 修复。本机 JavaScriptCore 生成 v04.10.03 Medusa / Helios / Khronos，对最终 query 与实际 gzip 正文字节签名；优先 `/novel/player/multi_video_model/player/v1`，兼容 flat / data.1004 模型映射并精确匹配分集。
- 与账号、搜索、目录签名分离；播放请求不带账号 Cookie。保留成功匿名身份复用、最多 5 次空响应恢复、旧单集及兼容路径、20 秒请求启动预算、HTTP/业务明确拒绝与取消语义。空响应不再推定为身份被拒。
- 修复前匿名目录和 96 集详情正常，但单集 5 次及全部兼容接口均为空；修复后同一目录样本 `M=ok`，22,013,835 字节加密媒体在读取 524,288 字节时解出首帧（2.38%），75 帧视频、21 个音频缓冲通过。
- 上游问题剧《无限白粥，朕可是忠臣啊》第 1、2 集：均 `M=ok`，分别 39,645,908 / 23,299,261 字节，首帧仅读取 786,432 / 524,288 字节；各解出 90 帧视频与 22 / 21 个音频缓冲。
- iPhone 17 / iOS 27.0 模拟器实际 App：搜索上述剧集、播放第 1 集、暂停/恢复、切到第 2 集，1 项 XCTest、0 失败（37.5 秒），导出截图确认真实画面。旧全流程测试依赖空历史和旧标签，本轮未计为通过；新增针对播放流程的用例显式指定主题并通过。
- 离线：32 组独立 SDK 摘要、4 组载体向量经 JavaScriptCore 对齐；新增 gzip/身份绑定、精确分集、双映射、拒绝、大小限制及 v5 优先/旧路回退检查。网络、账号、更新、本机库、媒体、渐进播放及 10 项源生成检查通过。
- Xcode 27.2 / SDK 27.2，无签名 iPhone arm64 Release 构建与 IPA 校验通过。发布仅包含本次播放修复；工作区待发布的账号资料补齐改动未合入。未做实体 iPhone 安装验收。
- 日志 `/tmp/hongguo-v5-ios-*.log`；UI 结果 `build/v5-qa/Logs/Test/Test-HongguoQA-2026.11.16_22-35-01-+0800.xcresult`。线上发布和四份稳定清单以 GitHub Release / distribution 为准。

## 待发布：账号片单名称与海报补齐（2026-11-16）

- 代码缺陷：云历史先生成无海报的“剧集”占位条目，资料批次只返回部分作品时保留占位；资料整行替换会抹掉已有字段；较旧的观看记录即使带有效资料也被丢弃；刷新未复用同账号已有资料。用户确认问题位于账号片单，未读取其真实账号数据。
- 历史、收藏、点赞按每批最多 50 个唯一作品编号补资料；部分返回或可选资料请求失败时，按字段合并当前列表与同账号已有名称、海报、简介和集数，不把已移除的旧条目重新加入列表。仅名称或仅海报的资料也可用于补齐，兼容 book_name、series_title、series_cover 等字段及转义/HTTP/相对协议图片地址。
- 较旧记录可补名称和海报；播放集号、位置与时间仍取最新记录。资料请求前后检查账号代次，失效登录与取消仍向外传递。没有清空账号、本机记录或重新登录操作，也没有云写入。
- `scripts/test-account-rules.sh` 通过：原账号规则及网页登录回归、新增 `AccountMetadataSelfTest`（部分返回、字段保留、资料字段、URL、进度不回退、50 条批次、无关 ID 过滤、19 位 ID 与取消）。Xcode 27.2 / iOS SDK 27.2 的无签名 iPhone Release 编译通过。
- 日志：`/tmp/hongguo-ios-account-metadata-tests.log`、`/tmp/hongguo-ios-account-metadata-build.log`。没有受影响账号的实网验收；从未取得且上游持续不返回的资料仍需后续刷新取得。此修复尚未发布，0.1.26 不包含。
- 追加实网检查：生产目录选取 12 部真实作品，以新注册匿名身份调用与账号片单相同的 multi-detail 资料端点，实际返回 12 条，修复后的解析取得 12 个名称、12 个海报地址，12 张海报均实际下载并经 ImageIO 解码通过，无图片 HTTP 错误。可用 `bash scripts/test-account-metadata-live.sh --live` 重现；此结果仅证明匿名真实资料与图片链路，不能代替受影响账号片单验收。
- 真实账号测试尝试：在已有模拟器的隔离克隆中运行只读探针，原始模拟器保持关闭。加密缓存存在，但测试包访问 Keychain 返回 -34018，未恢复可用登录态；未取得真实账号片单读测结果。随后尝试的本地模拟器 ad-hoc 测试包未能启动，没有生成或使用 Apple 签名证书，也没有更改发布 IPA。隔离副本测试仅尝试资料读取，没有预约、收藏修改或进度上报。所有物理设备当前均未连接。
- 实网日志：`/tmp/hongguo-ios-metadata-anonymous-live.log`；账号测试失败记录 `/tmp/hongguo-ios-metadata-live-report.json`。隔离副本测试失败不计入账号功能通过。

- 发布完成：GitHub `v0.1.27`，无签名 IPA 1,864,015 字节，SHA-256 `faae18e097cacc21fd991b6372a1ef2d65c7ad7c49721f9018e0b9479ac366d4`。三条全能签源和应用更新清单由 `5a13d71` 同步；官方及两条代理的清单和完整 IPA 均验证大小/哈希一致，生产更新客户端实际下载校验通过。线上报告 `build/online-0.1.27-verification.json`。

## 0.1.26 / build 27：播放空响应恢复（2026-11-16）

- 参考 LiuWQ0809/hongguo-android `89169c0` 及前置提交，单集接口空响应先做有限恢复（300ms 等待、最多 5 次），再走既有兼容路径。仅缓存已返回可用轨道的匿名身份，与账号及推荐身份分离；旧失败不能清除或覆盖另一个请求的新成功身份。
- HTTP 403/429 与已识别的登录/风控业务拒绝停止后续请求；保留模型错误优先级。注册前开始计算 20 秒请求启动预算，不会在预算耗尽后启动新请求；已发出的 HTTP 请求仍由各自超时约束，不宣称严格截断在 20 秒。取消等待、注册与取流均停止本次后续操作。
- `scripts/test-network.sh` 通过，新增恢复检查覆盖复用、换新、次数上限、拒绝、预算、取消和 actor 重入期间的旧请求失败；原签名向量、模型/ByteVC2 与旧路径回归通过。
- `scripts/test-progressive.sh` 通过，包含真实 AVPlayer 首帧、未缓存位置跳转、暂停恢复、取消和范围数据校验。
- `scripts/test-progressive-live.sh --live` 匿名实网通过：加密分集共 22,013,835 字节，首帧时仅下载 524,288 字节（约 2.4%）；解码 75 帧视频与 22 个音频缓冲。
- Xcode 27.2 / iOS SDK 27.2，关闭全部签名的 iPhone Release 目标编译通过，产物在 `build/playback-device/`。本轮按 0.1.26 / build 27 交付新的无签名 IPA，实际发布状态见 GitHub Release 与稳定更新清单；未做 iPhone 真机验收。
- 日志：`/tmp/hongguo-playback-ios-network.log`、`/tmp/hongguo-playback-ios-progressive.log`、`/tmp/hongguo-playback-ios-live.log`、`/tmp/hongguo-playback-ios-device-build.log`。

## 0.1.25 / build 26：推荐去重、漫剧续页与数据保护

日期：2026-11-14。版本 0.1.25 / build 26。本轮按无签名 iPhone IPA 发布，实际发布状态与安装包校验信息见 GitHub Release 及稳定更新清单。

- 首页：最近 540 部推荐按匿名与稳定账号分别保存到本机，文件仅含剧集 ID 和账号键的 SHA-256；重开应用、刷新与连续刷新继承去重。暖白顶部推荐、卡片前三条推荐不再重复进入下方海报网格；列表追加也过滤同一批次的重复 ID。
- 漫剧榜单：参考 hongguo-web `1b00f06`，改用 `filter_ids` 累积唯一作品，不再依赖上游忽略的 offset；单页最多三次请求，没有新增内容时停止。
- 本机片单：读取损坏或失败后锁定写入，自动 flush、收藏、历史记录和清空均不会覆盖原文件；片单页展示错误并可重新读取，恢复成功后才开放写入。新增损坏文件后继续 flush 与重读恢复回归。
- 预约：服务端确认写入成功后，回读的业务错误仍按“结果未确认”提示，不再误报为预约拒绝；未执行真实账号写入。
- QA：由同一脚本生成主工程与 UI 测试工程，共用完整源码、资源、最低系统和 Release.json 版本；修复 dragSeekSpan 的 actor 隔离警告。
- 离线：`test-network.sh`（新增磁盘推荐恢复、账号隔离、540 条上限、取消、连续刷新与漫剧重复分页用例）、`test-library.sh`、`test-account-rules.sh`、`test-progressive.sh`、`test-feeds.py` 均通过。
- 匿名实网：`test-network-live.sh --live` 通过；使用生产推荐实现连续加载、刷新后再重建磁盘历史，三段均无跨页重复，重建后的首批 8 部与前面结果交集为 0；漫剧两页各 18 部、交集为 0、游标前进。临时探针不使用个人账号、不下载媒体。
- 编译：Xcode 27.2 / iOS 27.2 SDK，关闭签名的 iPhone Release 构建通过；QA 模拟器 build-for-testing 通过。
- UI：专用 iPhone 17 / iOS 27.0 模拟器，`testHomeSectionsDoNotRepeat` 验证暖白和卡片首页的顶部推荐与网格无重复，1 项、0 失败，约 20 秒；结果 `/tmp/hongguo-home-ui-final.xcresult`。测试未覆盖全部旧版 UI 流程，也未进行真机或账号态推荐验证。

## 0.1.20 / build 21：长按后拖动调整进度，移除两侧双击快进快退

日期：2026-11-09。对应 Android 0.7.21–0.7.22（Android issue #3）。

- 手势：双击任意位置暂停或继续，移除两侧双击 ±10 秒、跳转角标、读屏“快退 / 快进 10 秒”与 `PlayerSession.skip`。移除独立的横向 `seekPan`，改由长按识别器在长按开始后横向移动超过 10pt 时结束 2× 并调整进度，松手跳转；`beginDragSeek` 不再拒绝进行中的 2×（由 `setSeeking` 结束）。不长按的横向滑动不调进度也不切换控件。拖动中切集（如 2× 播到片尾自动连播）时取消本次拖动并忽略该手势剩余移动。
- 竖屏清屏与长按 2× 不再隐藏状态栏和 Home 指示条；仅横屏隐藏状态栏，横屏且控件隐藏时隐藏 Home 指示条。提示文字改为“双击暂停 · 长按 2× · 长按后左右拖动调进度”。
- 模拟器（iPhone 18 Pro，iOS 27.1，《和离后我带女儿横扫魔域》）：暂停于 00:22 长按后右拖约半屏到 00:53，第 16 集 00:24 到 00:55，松手后提示框消失；不长按的快速横滑进度不变、控件不切换；竖屏清屏仍显示状态栏；长按拖动中第 15 集播完切到第 16 集，提示框不残留、之后长按拖动正常（修复前提示框停留为“快退 101 秒”）。`scripts/test-network.sh`、`test-media.sh`、`test-progressive.sh` 通过。
- 未验证：模拟器工具无法发出双击，双击暂停只经代码确认；`Tests/UIQATests.swift` 已改为新规则，但 `Hongguo-QA.xcodeproj` 缺少新源文件（如 `RelatedWork`）无法编译，未运行；无签名 IPA 未在真机安装。

## 0.1.19 / build 20：修复部分分集片源不可用

日期：2026-11-09。对应 Android 0.7.21（Android issue #3：第二季第 5 集起无法播放）。

- 原因：未加密的分集整体省略 `encrypt_info`（媒体为明文 hvc1，只带 `gear_des_key`），旧规则视为加密信息缺失而在所有请求路径失败；同一集不同路径 / 身份返回的模型也不一致。
- `DramaAPI`：某条路径模型解析失败时继续下一条，全部失败才报告模型错误（优先于 HTTP / 空响应）；内联档位完全未声明加密且备用片源无法核对时按明文选用，明确声明加密却缺 `spade_a` 的仍拒绝。明文由 `MP4Processor` / `MediaPreparer` 检查索引不含 encv / enca / sinf / senc 后才播放。
- `scripts/test-network.sh`、`test-media.sh`、`test-progressive.sh` 通过；实网读取《和离后我带女儿横扫魔域第二季》第 1–30 集全部成功，修复前第 14、18、22、25、28 集失败。
- 未验证：无签名 IPA 未在真机安装。

## 0.1.18 / build 19：左右滑动调整进度

日期：2026-11-08。对应 Android 0.7.20（Android issue #3 的建议）。

- 播放页画面增加一个横向 `UIPanGestureRecognizer`：只在水平速度大于垂直速度时开始（原纵向拖动只在相反情况下开始，两者互不抢占），单指；拖动时与进度条共用预览位置，中间显示目标时间与快进 / 快退秒数，松手寻址并保存进度，位移不足 0.2 秒不跳。整屏宽度对应整集，超过 3 分钟的视频对应 3 分钟，停在片尾前 1 秒。长按 2 倍速、出错或尚未出首帧时不开始。
- 模拟器（iPhone 18 Pro，《装穷提亲，娶到全家嫌弃的她》）：右拖约半屏 00:22 → 01:47，左拖约 0.3 屏后退约 35 秒，拖动中截图可见居中时间提示且进度条跟随，上滑仍切到第 2 集。
- 未验证：横屏全屏下的拖动未单独操作；无签名 IPA 未在真机安装。

## 0.1.17 / build 18：修复偶发的视频下载 / 播放失败

日期：2026-11-08。对应 Android 0.7.19（Android issue #3 反馈的偶发播放失败）。

- 原因：片源主机会把单个 Range 请求 302 到其他 CDN 做负载均衡。实网抓到 `*.vegslb.com`（已放行）、`*.idouyinvod.com`、`*.smtcdns.com`（未放行）。`MediaRangeHTTP` 的跳转白名单拒绝后两者，该分段立即判为 `MediaError.transport`；这种跳转会持续数秒到数十秒，所以立即重试也会失败。0.1.13 记录中“1 次传输失败未查明原因”即此问题。
- 修复：首个地址仍须在片源白名单内；跳转后接受任何公网 HTTPS 域名（拒绝 http、非 443 端口、带账号、IP 字面量、localhost/.local 等内网名），不转发 Cookie/Authorization，每段仍校验 206、Content-Range 与总长度。新增 `fetchRetrying`：传输失败或分段不完整时最多 5 次，间隔 0.4/0.8/1.6/3.2 秒，取消立即生效。
- 离线：`test-progressive.sh`（新增跳转放行/拒绝与重试恢复、持续失败仍报错的检查）、`test-media.sh`、`test-network.sh` 通过。
- 实网（匿名，《和离后我带女儿横扫魔域》随机集，用 App 自身的取片源与分段下载代码完整读完整集）：修复前 30/30/40 集中分别失败 2、1、2 集，失败都在 0.1 秒内，对应分段被 302 到未放行的 CDN，同一时刻普通请求可取得 206；修复后 40 集全部成功。
- 模拟器（iPhone 18 Pro）：修复后的 Debug 构建播放第 13、14 集，换集正常。
- 未验证：无签名 IPA 未在真机安装；修复后的这一轮实网是否恰好遇到跳转未单独记录（跳转放行由单元测试与修复前抓包覆盖）。

## 0.1.14 / build 15：全屏观看、小窗播放、推荐流同步与 ByteVC2 兼容请求

日期：2026-11-07。对应 Android 0.7.16。

- 全屏观看：宽大于高的片源在画面下方显示「全屏观看」，点击后锁定横屏（`InterfaceOrientationLock` + `requestGeometryUpdate`）；退出全屏后在播放页内保持竖屏，关闭播放页恢复跟随系统旋转。横屏时轻点显示或隐藏控件，播放 4 秒后自动隐藏，不能上下滑换集；底栏增加退出全屏。画面与上下渐变铺满整个屏幕，底部不再在 Home 指示条处留出未压暗的一条。
- 小窗播放：Info.plist 增加 `UIBackgroundModes` audio。播放页改用同一个 `AVPlayerLayer`（`PlayerSurface`），换集只换播放器，小窗不中断；顶栏在系统支持画中画时显示小窗按钮，正在播放时离开应用自动进入小窗。只在真正进入后台、且小窗没有开启时才暂停（原先进入 inactive 即暂停）；小窗在后台被关闭时暂停并保存进度。
- 推荐流同步 hongguoTV 0.1.26（3d319a6、62910e0）：复用注册的匿名身份并完整签名；单列无限流改走 `bookmall/cell/change` 并使用服务端 `next_offset`；明确 110 时回退原请求；刷新保留最近 540 条去重；单批不再截断到 30 部。
- ByteVC2：整集只有 ByteVC2 时，在备用接口上加 `codec_type=0`、`force_codec=h264` 再请求一次并确认是同一视频（hongguoTV 0.1.20，265472f，issue #56）。
- 模拟器（iPhone 18 Pro，横屏片源「有间客栈」）：按钮位置、进入和退出全屏、控件自动隐藏与轻点恢复、全屏底部铺满、手动换集、自动连播下一集。
- 实网（匿名）：推荐流 10 页累计 86 部不同作品，请求全部带签名；ByteVC2 样本集现已直接下发 HEVC，兼容分支实网未触发。
- 未验证：此模拟器报告不支持画中画，小窗按钮按设计隐藏，小窗未实测；无签名 IPA 未在真机安装；账号态推荐未用真实账号验证。

## 0.1.13 / build 14：修复无法播放

日期：2026-11-06。对应 Android 0.7.15。

- 播放：2026-11-05 起未签名请求返回 HTTP 200 + 0 字节，0.1.12 及更早版本无法取得播放信息。`DramaAPI.playbackModel` 改为带完整签名（x-gorgon、khronos、ladon、argus、helios、medusa），带上注册返回的 Cookie 和 POST 的 `x-ss-stub`。在 20 秒预算内依次尝试 GET、POST、换新身份 GET、备用域名 POST，单次请求最多 8 秒。协议参考 hongguoTV 0.1.25。
- 片源：跳转和最终响应的白名单增加 `vegslb.com`、`bdcgslb.com`（含子域名，仅 https）。
- 实网（匿名）：连续取 32 集播放信息全部成功，都由第一条路线取得。解码抽测在放行前 7 集有 2 集失败，放行后 12 集成功 11 集、16 集全部成功（其中 3 集经 vegslb 跳转）。
- 模拟器（iPhone 18 Pro）：完整播放页实际播放，进度从 00:06 走到 00:15。
- 未验证：解码抽测中有 1 次传输失败未查明原因；放行前有 1 次 `MediaError` 失败未定位。第一条路线之后的重试路线只有单元测试，实网未触发过。无签名 IPA 未在真机安装。
- 已知风险：每次取播放信息都注册新身份，与上游复用身份的做法不同；平台若限制注册会表现为播放失败。

## 0.1.12 / build 13：榜单、相关作品、账号记录、亮暗主题与清屏播放

日期：2026-11-04。对应 Android 0.7.14。

- 新增接口：官网完整榜单（第 1 页不带 `page` 参数）、搜索联想、相关作品与续季、短剧预约、红果账号点赞与资料计数。点赞片名由 `multi-detail` 接口补全。
- 主题：外观模式与界面风格分开保存，三套主题都有浅色和深色，可选跟随系统；直接设置窗口外观并监听系统变化。沉浸版刷剧页始终深色。
- 播放器：长按左侧 2 倍速时隐藏全部文字、按钮和状态栏；双指外拉进入清屏，轻点或双指内捏退出；出错、非手动暂停、最后一集播完时自动恢复控件。
- 首页：频道顺序改为热度、最新、漫剧、推荐，默认选中推荐。
- 片单：追剧、播放历史、账号片单改为三列海报，登录后优先显示红果账号。“播放历史”和本机入口改为独立页面，返回回到原页面。确认框改为居中弹窗。
- 模拟器（iPhone 18 Pro，本人账号）：跟随系统在运行中双向切换、冷启动深色；长按隐藏界面、双指外拉和内捏、轻点退出；沉浸版频道顺序；播放历史页来源切换与返回；三列海报；榜单翻页；账号统计与点赞。模拟器的 `simctl ui appearance` 要重启模拟器后才真正生效，验证外观前需确认系统设置本身已变。
- 未验证：真实预约未提交（会写入账号）；自动播放下一季未走通；清屏自动恢复控件、暖白和卡片主题的频道行、本机收藏页未实际查看；无签名 IPA 未在真机安装。

## 0.1.11 / build 12：手机验证码改走 App 通道、同步上游推荐与播放修复

日期：2026-11-04。对应 Android 0.7.13。

- 手机验证码：新增 `AppPhoneLogin`（hongguoTV 0.1.17–0.1.19 的 passport 通道，固定设备号），不跟随跳转，不展示平台原文。平台要求验证时弹窗引导到官方登录页手动完成。
- 推荐：登录后只带账号登录 Cookie；错误码非 0 时换域名并从头加载；offset 按实际下发条数前进（hongguoTV PR #59，发布时仍未合并）。
- 播放：每次取播放信息注册新身份，注册失败冷却 10 秒（hongguo-drama 5.5、5.6）；ByteVC2 明确提示；缺加密信息的内联片源可用校验通过的备用片源。
- 同版本合入另一会话的改动：列表提前加载下一页并预加载封面。
- 修复：连接云账号失败后登录卡片不再一直显示“正在连接云账号”。
- 实网（匿名）：连续取 10 集全部成功，`test-progressive-live.sh --live`、`test-network-live.sh --live` 通过。
- 本人账号：模拟器上用本人手机号完成发码、验码并连接云账号，显示昵称与头像。首次连接因模拟器无签名包缺钥匙串权限失败（-34018），改用本机临时签名后通过，真机安装由用户自行签名。滑块弹窗未实际触发过；登录后的片单与推荐修复未专门核对。
- 已知风险：固定设备号由使用该方案的用户共用；每次取播放信息都注册，平台若限制注册会表现为播放失败。

## 0.1.10 / build 11：播放信息改读 video_tab 接口

日期：2026-11-02。同步 Android 0.7.12 的对应改动。

- 2026-11-02 起 `POST /novel/player/multi_video_model/v1/` 返回 HTTP 200 + 0 字节：改动前 `test-media-live.sh --live` 在 `stage=track` 失败。`DramaAPI.track` 现先以注册的匿名身份请求一次 `GET /reading/bookapi/video_tab/multi_video_model/v1/`（带齐 GetVideoModelRequest 字段、`device_level=1`，有注册 Cookie 时附带），解析 `data.video_model_data[id].video_model`；失败时回退旧流程（hongguoTV 0.1.15）。
- 旧流程空响应：换新身份后隔 300ms 经 `api5-normal-hl.fqnovel.com`、`Connection: close` 重试一次；换身份失败仍以原身份重试（hongguo-drama 5.4）。未同步其恢复的请求签名。
- 测试：`scripts/test-network.sh`（新增 video_tab 请求字段、响应解析与备用域名 URL 用例）通过；`test-media-live.sh --live`（1080p 匿名取链至 AVFoundation 解码 75 帧）与 `test-progressive-live.sh --live`（下载完成前出首帧）通过。
- 已知限制：新接口低于 1080P 的档位均为 bytevc2，被过滤后只剩 1080P；未在模拟器 App 内实测播放。

## 0.1.9 / build 10：沉浸暗场自动试看、推荐流与播放修复

日期：2026-10-30。同步 Android 0.7.10–0.7.11 的对应改动。

- 播放修复：`multi_video_model` 请求 `device_level` 3 → 1（hongguoTV 0.1.12）；空响应时经 `renewPlaybackIdentity` 换新注册的匿名身份只重试一次（hongguo-drama 5.0），并发调用共享同一次换新。
- 推荐（猜你喜欢）：新增 `GuessFeed` / `GuessPager`，读取官方 App 书城 `bookmall/tab/v1`（tab_type=16），不签名、不上报行为；未登录匿名请求，App 账号验证通过时经 `AccountService.guessBatch` 携带账号 Cookie 与账号设备（账号传输层不跟随跳转）。每页最多 3 批凑 6 部，账号变化自动刷新。首页三套主题「推荐」为首个默认标签。
- 沉浸暗场首页：iOS 17 分页滚动实现全屏上下滑动，一屏一部；`FeedPreview` 只为当前页播放第 1 集（缓存或边下边播），离开首页、打开播放器或后台时释放，不写历史与账号进度；首帧前显示封面，横屏剧集黑底。点画面暂停、按住左侧 2 倍速（`FeedGestureView`，不含平移手势，翻页仍由滚动视图处理），「立即播放」按试看位置进入完整播放器，第 1 集结束后按钮带过渡变为「继续播放 · 第 2 集」。身份偶发被拒时 2 秒后重试一次，失败页可点按重试。
- 长按 2 倍速开始时 `UIImpactFeedbackGenerator(.medium)` 震动反馈，首页与完整播放器一致。设置「清理播放缓存」显示两个播放缓存目录的实际占用。
- 测试：`scripts/test-network.sh`（新增推荐请求、解析与分页离线用例）、`test-account-rules.sh`、`test-library.sh` 通过；`test-network-live.sh --live`、`test-media-live.sh --live`（1080p 匿名取链至 AVFoundation 解码 90 帧）通过。
- iPhone 18 Pro 模拟器实测：推荐流匿名加载、全屏翻页、当前页自动试看、上滑切换后下一部自动播放、点按暂停、按住左侧显示「2× 临时加速中」、立即播放从 00:20 续播、暖白主题首页、缓存大小显示。模拟器不能验证震动；第 1 集播完的按钮过渡未实测；登录后的推荐未用本人账号验证。

## 0.1.3 / build 4：边下边播

- 默认播放改为按范围下载、按样本解密、向 AVPlayer 增量提供视频。支持跨块和跨样本读取、拖动到未缓存位置、校验后的分块复用及切集取消。
- 离线生成 4,555,986 字节的真实 H.264 CENC 视频；首帧解码与实际 AVPlayer 首帧均发生在只读取 361,682 字节时，约 8%，整集尚未完成。AVPlayer 跳到 6 秒的未缓存位置后继续输出真实图像。
- 任意顺序范围读取与完整解密结果逐字节一致，覆盖尾部 moov、8/16 字节 IV 和普通未加密 MP4。缓存损坏、活动目录保护、配额清理、暂停恢复、在途取消均通过；30 秒延迟请求在关闭所属播放器后立即取消。
- 生产 HTTP 读取器验证 206、Content-Range、长度、截断/超长响应、取消与域边界；忽略 Range 的整文件响应会被拒绝。测试没有访问外部网络。日志：`build/progressive-test.log`。
- 真实匿名 1080p 加密片源总长 13,267,284 字节；读取索引用 262,144 字节，在网络读取 524,288 字节（约 4%）时已解码首帧，随后 3 秒输出 90 视频帧和 24 音频缓冲。日志：`build/progressive-live.log`。
- iPhone 17 / iOS 27.0 全流程 XCTest 通过，1 项、0 失败，约 79.8 秒。覆盖真实播放、1.5 倍速和临时长按、第二/第三集切换、退出播放器、重启应用后恢复历史。结果为 `build/StreamingUI.xcresult`，截图在 `build/streaming-ui-attachments/`。
- [0.1.3 自动发布](https://github.com/OOIUa/hongguo-ios/actions/runs/40702290216)全部成功，包含新增渐进播放测试；稳定源由 `aabe2a3` 同步。线上更新客户端已实际下载并校验 0.1.3 / build 4，官方及两条加速源均与发布包一致。
- 线上无签名 IPA：1,197,934 字节，SHA-256 `c88017833b6e4520faf1dcd1104a57a9f372a9296696b6be718007d243971d3d`；已下载到 `dist/` 再次核对设备架构、最低系统、未签名状态及四份源文件。报告：`build/online-0.1.3-verification.json`、`build/update-live-0.1.3.log`。

## 0.1.2 / build 3：Android 图标同步

- Android 本地仓库已快进到 0.7.8 / `69c1d5abf35c2b133885d053c665860e3ccfc9fb`；本次同步品牌图标。
- 保留安卓图标矢量 XML，用相同颜色、路径和偶奇填充生成 1024 × 1024 无透明通道 AppIcon、224 × 224 透明 BrandLogo 和软件源图标，已检查渲染结果。
- 首页与关于页面已使用 BrandLogo。设备 Release 构建通过，包内 0.1.2 / build 3、iPhoneOS arm64、最低 iOS 17，未签名且无内嵌描述文件。
- 实际 Assets.car 已确认含 AppIcon（1024 × 1024，Opaque）与 BrandLogo（224 × 224，透明）。
- 软件源图标改用对应版本标签 URL，订阅地址不变，避免版本升级后继续使用旧图标缓存。
- [0.1.2 自动发布](https://github.com/OOIUa/hongguo-ios/actions/runs/40692156508)全部成功，三条全能签源和更新清单已由 `c2fb0d9` 同步到 main。
- 已下载线上无签名 IPA 复核：1,118,415 字节，SHA-256 `3897d05c46a9119c98e7057b62fdb8ecb969051a7f5a3e51f552f32e075824c9`。与线上源一致，生产更新客户端实网下载和校验通过，日志为 `build/update-live-0.1.2.log`。
- 对应标签的官方/两条代理图标均 HTTP 200，文件哈希与本地 AppIcon 一致；用户安装新版后确认 iPhone 桌面图标正常。

## 0.1.1 / build 2：更新与发布

日期：2026-10-28。

- 新增手动检查更新、官方/两条加速线路、下载安装包并核对实际大小与 SHA-256、校验后导出和复制全能签三条源。
- 本机 Release / iphoneos 构建通过，包内版本 0.1.1、build 2、arm64、最低 iOS 17；codesign 确认未签名，无内嵌描述文件。
- `scripts/test-updates.sh`：50 条版本、清单、大小、哈希、地址和重定向规则，以及 6 条生产传输实现模拟测试通过。包含已写入部分数据后取消，残留文件清理成功。
- `scripts/test-feeds.py`：10 项 IPA、版本、源一致性、篡改、发布状态和错误处理测试通过。全能签字段已与官方公开的软件源源码核对。
- 更新页模拟器 XCTest：1 项测试、0 失败，约 38.8 秒。验证从“我的”进入、版本显示、线路切换、三条软件源复制及确认提示；未校验的文件没有导出入口。
- 结果：`build/UpdateUIFinal.xcresult`，日志：`build/update-ui-final.log`。本机 QA 文件不提交。
- 新增 `scripts/test-updates-live.sh --live`，发版后使用生产更新客户端读取公开清单并下载、验证和清理 IPA；未带 `--live` 时拒绝联网。
- GitHub Actions 在 `v*` 标签推送后构建无签名 IPA、发布对应源码并同步四份源 JSON。同步前重新下载已发布 IPA 核对实际内容，拒绝草稿/预发布，避免旧版本覆盖较新源，支持只恢复源。
- 首次[自动发布运行](https://github.com/OOIUa/hongguo-ios/actions/runs/40657890712)已完整成功，[v0.1.1 Release](https://github.com/OOIUa/hongguo-ios/releases/tag/v0.1.1)已公开；源由机器人提交 `dc3d28e` 同步到 main。
- 线上实际 IPA：1,095,964 字节，SHA-256 `546e0b6614ee52e9043758b887c5a8bf72e1b2c61511aa5f80a90892c5e35385`。已下载到本机 `dist/` 并与已发布校验文件一致；本机先前自行编译的包保留在 `build/local-pre-ci-artifacts/`，以线上包与源信息为准。
- 生产 Swift 更新客户端实网探针通过：从官方源读取 0.1.1 / build 2，实际下载安装包，大小、SHA-256、ZIP 检查通过，临时文件清理通过，日志为 `build/update-live.log`。
- 官方源、两条加速源，以及两条代理 IPA 下载均 HTTP 200；源中版本、大小、哈希与线上安装包一致。报告为 `build/online-release-verification.json`。这是本轮网络结果，不保证代理永久可用。
- 本轮未在实体 iPhone 中重签安装，未在全能签客户端实际导入源；对应运行结果需要用户设备验证。

## 0.1.0 / build 1：初始移植

日期：2026-10-28。Android 参考版本：0.7.5 / `72d5531`。iOS Bundle ID：`com.ooiua.hongguo.ios`，版本 0.1.0，构建号 1。

## 构建与安装包

- Xcode 27.1（27A9275）、iOS 27.1 SDK，Release / iphoneos 构建通过。
- 最低 iOS 17.0，设备架构 arm64，标准 `Payload/Hongguo.app` IPA。
- `CODE_SIGNING_ALLOWED=NO`，`CODE_SIGNING_REQUIRED=NO`。codesign 检查结果为未签名，无内嵌描述文件。
- 两个本机签名资源 `BufferRuntime.js` / `PureSign.js`、图标与开源通知已打包。
- `scripts/verify-ipa.py` 验证 ZIP 完整性、Info.plist、Mach-O 架构、资源与未签名状态，并输出 SHA-256。
- 使用用户自己的测试签名流程签名安装；本轮没有在实体 iPhone 上重签安装。

## 真实内容与媒体

- 同一 Swift 内容实现匿名联网取得首页 18 部、详情 86 集、动态筛选 6 组、搜索 20 条及加密 1080p 轨道。
- 推荐/上新、搜索分页、漫剧和 AI 类别均读取成功；已验证的两页结果无重复、游标递增。
- 真实媒体完成取链、下载、处理及 AVFoundation 音视频解码：样本文件 13,267,284 字节，前 3 秒解码出 90 个视频帧与 24 个音频缓冲。
- 相同分集再次准备命中缓存；取消缓存校验不会误删有效缓存。
- 上述是本次网络与代表样本的结果，不代表上游接口长期不变或所有封装均兼容。

## 离线测试

以下脚本均通过：

- `scripts/test-account-rules.sh`：19 个账号身份类型、官网明确未登录否决、嵌套身份和 Cookie 域匹配案例。
- `scripts/test-network.sh`：4 组固定签名向量、Node 独立复算对齐、长 ID 精度、二进制/gzip 请求体、URL 编码与取消。
- `scripts/test-library.sh`：跨进程持久化、真实播放记录、旧集回调、删除/清空后不复活、收藏历史独立、200 部上限、损坏文件、NIST AES-CTR/CBC 向量与 gzip。
- `scripts/test-media.sh`：Spade 真值、现场生成可解码 AVC 素材、8/16 字节 IV 的样本加解密还原、AVFoundation 真实解码、损坏输入与取消。

## 模拟器真实 UI 流程

设备：任务专用 iPhone 17 / iOS 27.0 模拟器。测试程序：`Tests/UIQATests.swift`，工程 `Hongguo-QA.xcodeproj`，Scheme `HongguoQA`。

最终 XCTest：1 个完整流程，0 失败，约 71.8 秒。流程实际读取上游内容，不使用模拟列表或海报代替视频播放：

1. 首次主题选择 → 暖白首页 → 空片单 → 我的 → 设置。
2. 切换沉浸暗场 → 首页/剧场 → 动态筛选 → 输入“王妈”并搜索。
3. 搜索结果 → 真实详情 → 本机收藏 → 第一集实际播放。
4. 打开倍速面板 → 切换 1.5× → 长按临时加速后仍恢复 1.5×。
5. 点击下一集 → 第二集播放 → 打开选集面板 → 第三集播放。
6. 退出播放器 → 查看观看历史 → 切换内容卡片。
7. 终止并重新启动应用 → 本机片单仍显示第三集观看记录。

测试中发现并已修复：独立搜索页的剧集导航未打开详情；视频层/手势层覆盖底部控件点击。视频渲染层现不接收触摸，手势层只覆盖中央画面，播放控件有明确点击区域和无障碍标识。

最终结果包：`build/PlayerRegressionFinal.xcresult`，日志：`build/player-regression-final.log`。页面截图保留在 `build/ui-qa/`。这些本机 QA 产物不放入源码压缩包，以免包含大量构建缓存。

## 账号与当前限制

- 账号实现已加入 Keychain/AES-GCM 保存、官方 WebView、官网与手机业务身份分开验证、账户收藏/历史/预约读取、收藏单次写入后回读、可选进度队列。
- 静态复核后已修复：布尔值误作身份、明确匿名状态误判、Cookie 域越界、网页登录取消后的迟到回调、导入忙碌竞争、过期会话授权未撤销、退出后的旧请求，以及进度任务代次和旧确认覆盖新进度。
- 本轮没有本人账号，未宣称真实个人登录、云收藏写回或跨设备续播已经通过；这些需用户安装后正常授权并与官方客户端对照。
- 0.1.0 初始版本采用整集下载处理后播放，当时尚无渐进播放；0.1.3 已改为上述边下边播与分块缓存。下一集完整预加载默认关闭。
- 首轮视觉与交互验收为上述模拟器；iOS 17–26 的实际设备、大字号/VoiceOver、横屏与全部片源尚未全面验证。
