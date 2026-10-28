# 红果独立版 iOS

原生 SwiftUI / AVFoundation 客户端，基于 [OOIUa/hongguo-android](https://github.com/OOIUa/hongguo-android) 0.7.5（`72d5531`）移植。请求、签名、媒体处理、缓存和播放均在设备本机完成，无需部署服务器。

交付：iPhone arm64、iOS 17.0 及以上、无签名 IPA。安装前使用你自己的测试签名流程签名。

## 使用

1. 按下方构建说明生成 `dist/Hongguo-iOS-0.1.0-unsigned.ipa`，使用你自己的测试签名流程签名并安装。构建产物保存在本机，不提交到源码仓库。
2. 从首页、发现或搜索选剧，进入详情后选择集数。
3. 每集显示下载与处理进度，准备完成后播放。支持选集、上下滑切集、拖动、六档倍速和左半屏长按临时 2 倍速。
4. 在本机片单查看收藏与历史，退出播放器后可恢复集数和位置。
5. 「我的 → 设置」可切换暖白精修、沉浸暗场、内容卡片，并调整自动连播和可选下一集预加载。
6. 「我的 → 红果账号」在官方页面自行完成登录。官网会话和手机业务身份分别验证；只有云账号确认后才开放账户收藏、最近历史与预约。

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
