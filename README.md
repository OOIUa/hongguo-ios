# 红果独立版 iOS

原生 SwiftUI / AVFoundation 客户端，基于 [OOIUa/hongguo-android](https://github.com/OOIUa/hongguo-android) 0.7.5（`72d5531`）移植。请求、签名、媒体处理、缓存和播放均在设备本机完成，无需部署服务器。

交付：iPhone arm64、iOS 17.0 及以上、无签名 IPA。安装前使用你自己的测试签名流程签名。

应用图标与应用内标识同步自 Android 0.7.8（`69c1d5a`）的红果与播放键矢量素材，来源及重新生成方式见 [Branding/README.md](Branding/README.md)。

## 使用

1. 在 [GitHub Releases](https://github.com/OOIUa/hongguo-ios/releases) 下载无签名 IPA，或按下方说明自行构建，使用你自己的签名流程签名并安装。构建产物保存在本机，安装包通过 Releases 分发。
2. 从首页、发现或搜索选剧，进入详情后选择集数。
3. 每集显示下载与处理进度，准备完成后播放。支持选集、上下滑切集、拖动、六档倍速和左半屏长按临时 2 倍速。
4. 在本机片单查看收藏与历史，退出播放器后可恢复集数和位置。
5. 「我的 → 设置」可切换暖白精修、沉浸暗场、内容卡片，并调整自动连播和可选下一集预加载。
6. 「我的 → 红果账号」在官方页面自行完成登录。官网会话和手机业务身份分别验证；只有云账号确认后才开放账户收藏、最近历史与预约。
7. 「我的 → 检查更新」可切换官方与加速线路，下载并校验新版本，再导出给自己的签名工具。

## 全能签在线源

在全能签的软件源管理中添加下面任一地址。三个源对应同一个无签名 IPA；选择当前网络能够访问的线路即可。

| 线路 | 软件源地址 |
| --- | --- |
| 官方 GitHub | [source.json](https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source.json) |
| 加速一 GH-Proxy | [source-cn.json](https://gh-proxy.com/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn.json) |
| 加速二 GHFast | [source-cn-backup.json](https://ghfast.top/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn-backup.json) |

源格式参考[全能签官方源](https://qnq.nuosike.cn/)。加速服务为第三方线路，可用性取决于当地网络；应用内可切回官方直连。应用只下载无签名包，需自行签名后安装。覆盖升级时保留相同 Bundle ID 和兼容的签名配置。

应用更新读取 [update.json](https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/update.json)，核对版本、最低系统版本、包大小和 SHA-256 后才允许导出。

## 当前版本边界

- 当前使用完整文件下载和媒体处理后播放，渐进边下边播尚未加入。下一集预加载会完整准备下一集，默认关闭；取消未完成预加载后再次打开会从头准备。
- 三种界面风格按 iOS 原生控件适配，共用播放器；只在前台播放。
- 本机收藏与历史分别最多 200 部，独立管理。账号历史读取最近 50 部，预约各读取 20 部，收藏展示已读取批次；不宣称完整云端备份。
- 账户收藏采用单次写入后回读核对；响应不确定时保留待核对状态，不自动重放收藏请求。
- 云进度上报默认关闭。主动开启后，只上报此后实际观看的内容，按账号隔离并加密保留待发送记录。本人账号授权、云收藏写回和跨设备续播需要用户在实际设备上核对。
- 安装包代码签名由用户处理。覆盖升级需保持兼容的 Bundle ID 和 Keychain 签名配置，确保本机数据与账号存储正常恢复。

## 构建

已在 Xcode 27.1 / iOS 27.1 SDK 构建，部署最低版本为 iOS 17.0，无外部 Swift Package 依赖。需要完整 Xcode 及对应 SDK，许可协议由用户自行确认。

```sh
bash scripts/build-unsigned.sh
```

脚本生成 Xcode 工程、编译 Release 设备目标、关闭代码签名、打包标准 `Payload/Hongguo.app` 结构，输出 IPA 和 SHA-256 文件到 `dist/`。

```sh
python3 scripts/generate_project.py
open Hongguo.xcodeproj
```

## 验证

```sh
bash scripts/test-account-rules.sh
bash scripts/test-library.sh
bash scripts/test-network.sh
bash scripts/test-media.sh
bash scripts/test-updates.sh
python3 scripts/test-feeds.py
```

匿名真实接口和媒体验证会访问内容源并下载视频，需明确使用联网参数：

```sh
bash scripts/test-network-live.sh --live
bash scripts/test-media-live.sh --live
```

详细证据与尚未验证的部分见 `VALIDATION.md`。测试程序不需要本人账号，不打印设备身份、Cookie、媒体密钥或完整媒体 URL。

## 开源与来源

项目按 GPL-3.0-only 分发，许可证和原作者通知保留在 `Resources/`。签名算法来自 `jackotom/hongguo-drama` 的开源实现，以 JavaScriptCore 在本机执行；设备注册、账号、媒体算法及行为参考 Android 基线与其列出的 GPL / MIT 来源。来源说明见 `Resources/ThirdPartyNotices.txt`、`Sources/Networking/PureSign.js` 与各源文件注释。

发布安装包时应同时提供对应源码及构建脚本。

## 项目记忆与发版约定

[AGENTS.md](AGENTS.md) 记录了用户的持续要求：只打无签名 IPA；iOS 代码单独托管；每次发布新版本必须同步全能签三条源与应用更新清单。版本与 build 统一由 `Configuration/Release.json` 管理。

发版前递增版本和 build，并填写更新说明。发布工作流会从实际 IPA 生成大小、SHA-256 和源文件，再上传 GitHub Release、同步 `main` 分支的软件源。不要手工填写包哈希，不要覆盖已发布版本，不要只推送 IPA 而遗漏软件源。

提交源码并推送到 `main` 后，为该提交创建与配置相同的版本标签，例如：

```sh
git tag v0.1.1
git push origin v0.1.1
```

GitHub Actions 的发布工作流自动构建、校验、发布和同步源。仓库需要允许 Actions 写入内容；不需要 Apple 证书或签名密钥。核对线上源同步成功后再视为发版完成。

本机也可先准备发布材料并检查：

```sh
bash scripts/release.sh v0.1.1
python3 scripts/generate-feeds.py --tag v0.1.1 --check
```

已准备且确认标签指向相应代码后，可用已登录的 GitHub CLI 发布并同步源：

```sh
bash scripts/release-publish.sh v0.1.1
bash scripts/release-sync-feeds.sh v0.1.1
```

若 Release 已经公开，但同步源失败，先取回对应标签，再从已发布的实际安装包恢复源：

```sh
git fetch origin --tags
bash scripts/release-sync-feeds.sh v0.1.1 --from-release
```

恢复流程重新下载远程 IPA 并核对版本、大小和 SHA-256，再同步源；不覆盖已发布资产。若发布停在草稿状态，应先检查并解决草稿发布失败，不要把草稿作为稳定更新源。

普通源码推送不等于发布新版本；推送 `v*` 标签才触发构建和在线源更新。
