# 项目记忆

## 用户已确认的交付方式

- iOS 原生移植项目，Android 参考仓库为 https://github.com/OOIUa/hongguo-android 。
- iOS 代码独立托管于公开仓库 `OOIUa/hongguo-ios`；不要向 Android 仓库推送 iOS 代码。
- 用户先在自己的 iPhone 测试，已有自己的测试签名。**每次只打包无签名 iPhone IPA**，由用户自行签名安装。
- 构建始终传入 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''`。不申请、生成、导入或提交签名证书、描述文件、私钥。
- 无签名 IPA 不能直接在设备自安装。更新页应提供校验后导出给签名工具的流程，不能显示虚假的“安装完成”。

## 发布与在线源：每次更新必须执行

- 版本号、递增 build、最低系统版本及更新说明统一维护于 `Configuration/Release.json`，工程与包名从该文件生成。
- 打包前更新版本与 build；Git 标签格式为 `v<version>`。同一个版本不要覆盖已经发布的 IPA。
- 使用 `scripts/build-unsigned.sh` 生成设备包，通过 `scripts/verify-ipa.py` 校验无签名、设备架构、版本与资源。
- **每次推送新版本都必须同步更新全能签源和应用内更新清单**，不能仅上传 IPA 或只修改版本号。
- 实际 IPA 的大小、SHA-256、版本、build 校验通过后，才能运行 `scripts/generate-feeds.py` 生成 `distribution/update.json`、`source.json`、`source-cn.json`、`source-cn-backup.json`。
- 全能签源统一托管于 GitHub。官方源使用 GitHub Raw + GitHub Releases；加速源分别通过 `https://gh-proxy.com/`、`https://ghfast.top/` 代理相同的官方文件。代理可失效，保留官方直连与切换线路。
- 稳定官方源：`https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source.json`。
- 加速源一：`https://gh-proxy.com/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn.json`。
- 加速源二：`https://ghfast.top/https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/source-cn-backup.json`。
- 应用更新清单：`https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/update.json`，同样支持上述两种代理前缀。
- 优先用仓库发布工作流或 `scripts/release*` 完成上传和源同步；任一步失败必须修复或明确报告，不能称为已发布。
- 发版后验证 Releases 资产和仓库源链接可访问、版本/大小/SHA-256一致；区分本地已生成、已推送与线上验证通过。

## 工程与验证

- 源码在 `Sources/`，最低 iOS 17，依赖系统框架；用 `scripts/generate_project.py` 重新生成主 Xcode 工程。
- 品牌图标已同步 Android 0.7.8 / `69c1d5a`。原始 XML 与来源在 `Branding/`，用 `xcrun swift scripts/make-icon.swift` 同时生成 AppIcon、应用内 BrandLogo 与 `distribution/icon.png`；不要恢复旧“果”字图标。业务移植基线仍以 README 为准。
- `build/`、`dist/`、个人数据和密钥不进 Git；IPA/哈希等二进制交付物上传 GitHub Releases。
- 修改网络、媒体、账号、本机库或更新规则后，运行对应 `scripts/test-*.sh`。新增发布逻辑运行 `scripts/test-feeds.py`。
- 实网测试须显式传 `--live`。没有用户账号实测的登录、云写入不能宣称已验证。
- 从 0.1.3 起，默认播放使用 `ProgressivePlayback`：按范围下载、CENC 按样本解密、分块校验缓存，不等待整集完成。完整文件准备仅用于可选下一集预加载及旧版缓存；涉及这条链路须运行 `scripts/test-progressive.sh`，实网验证用 `scripts/test-progressive-live.sh --live`。

以上是用户在本项目中的持续偏好；后续打包、发布和更新维护时自动遵守，无需反复询问签名方式。
