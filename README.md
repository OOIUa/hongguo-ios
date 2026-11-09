<div align="center">

<img src="distribution/icon.png" width="112" alt="红果独立版 logo">

# 红果独立版 iOS

**在 iPhone 上发现好剧，随时接着看。**

基于 SwiftUI 与 AVFoundation 构建的原生 iOS 短剧客户端。<br>请求签名、媒体解密、缓存与播放均在本机完成，无需部署服务器或配置 API key。

[![Release](https://img.shields.io/github/v/release/OOIUa/hongguo-ios?label=Release&color=F15A2B)](https://github.com/OOIUa/hongguo-ios/releases/latest) [![iOS](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](#下载与安装) [![UI](https://img.shields.io/badge/UI-SwiftUI-F05138?logo=swift&logoColor=white)](#功能一览) [![License](https://img.shields.io/badge/License-GPL--3.0--only-blue)](LICENSE)

[**添加全能签源**](#全能签在线源) · [下载 IPA](https://github.com/OOIUa/hongguo-ios/releases/latest) · [功能一览](#功能一览) · [源码构建](#源码构建) · [反馈问题](https://github.com/OOIUa/hongguo-ios/issues)

</div>

## 下载与安装

发布的是 **无签名 IPA**（iPhone arm64，iOS 17.0 及以上），需要用你自己的签名工具签名后安装。

### 全能签在线源

推荐方式：在全能签的「软件源」中添加下面任一地址，之后有新版本会在源里直接显示。三条线路对应同一个 IPA，选当前网络能访问的即可。

| 线路 | 软件源地址 |
| --- | --- |
| 官方 GitHub | `https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source.json` |
| 加速一 gh-proxy | `https://gh-proxy.com/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn.json` |
| 加速二 ghfast | `https://ghfast.top/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn-backup.json` |

加速线路由第三方提供，可用性取决于当地网络；连不上时换一条，或切回官方直连。源格式参考[全能签官方源](https://qnq.nuosike.cn/)。

### 手动下载

在 [GitHub Releases](https://github.com/OOIUa/hongguo-ios/releases/latest) 下载 `Hongguo-iOS-<版本>-unsigned.ipa`，同页附有 SHA-256 校验文件和对应源码。

> **已安装旧版？** 覆盖安装即可保留收藏、历史与续播位置。签名时保持相同的 Bundle ID 和兼容的签名配置，否则系统会当成新应用，本机数据和账号登录无法恢复。

应用内「我的 → 设置 → 检查更新与全能签源」也能检查新版本：可切换官方与加速线路，下载后核对版本、大小和 SHA-256，再导出给你的签名工具。应用无法自行安装无签名包。

## 功能一览

| 功能 | 说明 |
| --- | --- |
| 首页与推荐 | 本机最近观看一键续播；推荐（猜你喜欢）、热度、最新短剧与榜单；沉浸暗场风格上下滑动自动试看第 1 集 |
| 发现与搜索 | 浏览短剧、漫剧、AI 剧，按上游提供的条件筛选；按剧名或关键词搜索 |
| 剧集详情 | 简介、选集、相关作品（其他季与同 IP 作品，待上线作品可预约） |
| 边下边播 | 读取视频索引后即可起播，不等整集下完；拖动时按需补齐目标片段，已校验的分块缓存复用 |
| 播放手势 | 轻点显示或隐藏控件；双击任意位置暂停或继续；长按临时 2 倍速，长按后左右拖动调整进度；上下滑动切集；双指外拉清屏 |
| 播放控制 | 选集面板、六档倍速（0.5×–2×，自动记住）、自动连播、可选下一集预加载；点击顶部剧名打开详情 |
| 全屏与小窗 | 横屏片源可「全屏观看」；支持画中画小窗，播放时离开应用自动转为小窗 |
| 片单与历史 | 本机收藏与播放历史，退出后恢复集数和位置；登录后可查看账号收藏、最近历史与预约 |
| 红果账号 | 扫码、手机号或官网登录；账号收藏写入后回读核对；云进度上报默认关闭 |
| 界面风格 | 暖白精修、沉浸暗场、内容卡片三种布局，浅色、深色或跟随系统 |
| iPhone Duo | 用 iOS 27.1 以上 SDK 构建，展开后按内屏尺寸运行；海报网格随屏幕宽度增加列数 |

## 快速上手

1. 从「首页」「发现」或搜索选剧，进入详情后选择集数开始播放。
2. 播放中轻点画面呼出控件，双击任意位置暂停；长按临时 2 倍速，长按后左右拖动调整进度。
3. 退出播放器后，在首页或「我的 → 播放历史」继续上次的集数与位置。
4. 「我的 → 设置」切换主题样式、浅色或深色，调整自动连播与下一集预加载。
5. 「我的」顶部的账号卡片进入红果账号登录。官网会话和手机业务身份分别验证，云账号确认后才开放账号收藏、历史与预约。

## 当前版本边界

- 支持 HTTP 分段读取的普通 MP4 与全样本 CENC 视频，按需下载并解密；索引位于文件尾部也能先读索引再起播。碎片化 MP4、子样本或模式加密暂不支持。
- 当前集的完整分块校验后缓存，退出时保留已完成分块并取消未完成的请求。下一集预加载默认关闭，开启后在当前集缓存完成时准备完整下一集。
- 只在前台播放（小窗除外）。三种风格按 iOS 原生控件适配，共用同一个播放器。
- 本机收藏与历史各最多 200 部，与账号数据分开管理。账号历史读取最近 50 部，预约读取 20 部，收藏展示已读取的批次；不提供完整的云端备份。
- 账号收藏响应不确定时保留「待核对」状态，不会自动重发收藏请求。
- 云进度上报需主动开启，只上报开启后实际观看的内容，待发送记录按账号隔离并加密保存。

## 源码构建

需要完整 Xcode 及 **iOS 27.1 或更新的 SDK**（`Configuration/Release.json` 的 `minimumBuildSDK`），旧 SDK 构建的包在 iPhone Duo 展开后会按普通 iPhone 尺寸加黑边显示，构建脚本会直接拒绝。部署最低版本 iOS 17.0，无外部 Swift Package 依赖。

```sh
bash scripts/build-unsigned.sh
```

脚本会生成 Xcode 工程、编译 Release 设备目标（关闭代码签名）、打包标准 `Payload/Hongguo.app` 结构，并把 IPA 和 SHA-256 输出到 `dist/`。

在 Xcode 中开发：

```sh
python3 scripts/generate_project.py
open Hongguo.xcodeproj
```

版本号、build、最低系统与更新说明统一在 `Configuration/Release.json` 维护，工程由脚本从中生成。

## 验证

离线测试：

```sh
bash scripts/test-account-rules.sh
bash scripts/test-library.sh
bash scripts/test-network.sh
bash scripts/test-media.sh
bash scripts/test-progressive.sh
bash scripts/test-updates.sh
python3 scripts/test-feeds.py
```

实网测试会访问内容源并下载视频，需要显式加 `--live`：

```sh
bash scripts/test-network-live.sh --live
bash scripts/test-media-live.sh --live
bash scripts/test-progressive-live.sh --live
```

测试不需要本人账号，也不会打印设备身份、Cookie、媒体密钥或完整媒体 URL。各版本的验证记录与尚未验证的部分见 [VALIDATION.md](VALIDATION.md)。

## 发布

推送 `v<版本>` 标签后，GitHub Actions 会构建并校验无签名 IPA，上传 Release，再同步三条全能签源与应用内更新清单。完整流程、本机发布与故障恢复见 [RELEASING.md](RELEASING.md)。

## 开源与来源

最初移植自 [OOIUa/hongguo-android](https://github.com/OOIUa/hongguo-android) 0.7.5（`72d5531`），此后随 Android 版本同步功能。应用图标与应用内标识来自 Android 0.7.8（`69c1d5a`）的矢量素材，重新生成方式见 [Branding/README.md](Branding/README.md)。

项目按 GPL-3.0-only 分发，许可证和原作者通知保留在 `Resources/`。签名算法来自 `jackotom/hongguo-drama` 的开源实现，在本机由 JavaScriptCore 执行；设备注册、账号与媒体处理参考 Android 版及其列出的 GPL / MIT 来源。详见 `Resources/ThirdPartyNotices.txt`、`Sources/Networking/PureSign.js` 与各源文件注释。分发安装包时应同时提供对应源码及构建脚本，每个 Release 都附有源码 ZIP。
