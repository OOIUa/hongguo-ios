# iOS 验证记录

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
