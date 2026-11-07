# 发布流程

[AGENTS.md](AGENTS.md) 记录了持续约定：只打无签名 IPA，iOS 代码单独托管，每次发布新版本都必须同步全能签三条源和应用内更新清单。

## 常规发布

1. 在 `Configuration/Release.json` 中递增 `version` 和 `build`，填写 `releaseNotes`，再运行 `python3 scripts/generate_project.py`。
2. 提交源码并推送到 `main`。
3. 为该提交创建与配置一致的标签并推送：

   ```sh
   git tag v0.1.16
   git push origin v0.1.16
   ```

4. GitHub Actions（`.github/workflows/release.yml`，`xcode-27` runner）依次运行离线测试、构建无签名设备包、校验 IPA 的版本、部署目标、SDK 与签名状态，从实际 IPA 生成大小、SHA-256 和四份清单，上传 Release，最后把清单同步回 `main` 的 `distribution/`。
5. 核对 Release 资产与三条源、`update.json` 都已是新版本，且大小和 SHA-256 一致，才算发布完成。

普通源码推送不会发布新版本；只有推送 `v*` 标签才会触发构建和源更新。不要手工填写包哈希，不要覆盖已发布的版本，也不要只上传 IPA 而遗漏软件源。仓库需允许 Actions 写入内容；整个流程不需要 Apple 证书或签名密钥。

## 本机发布

GitHub 排不到 macOS runner 时，可在本机完成同样的步骤。先准备并检查发布材料：

```sh
bash scripts/release.sh v0.1.16
python3 scripts/generate-feeds.py --tag v0.1.16 --check
```

确认标签指向对应代码后，用已登录的 GitHub CLI 发布并同步源：

```sh
bash scripts/release-publish.sh v0.1.16
bash scripts/release-sync-feeds.sh v0.1.16
```

本机构建同样必须使用 iOS 27.1 或更新的 SDK；`build-unsigned.sh` 与 `verify-ipa.py` 会拒绝更旧的 SDK。若工作流已经排队，先取消，避免两边同时发布。

## 故障恢复

Release 已经公开但源同步失败时，先取回标签，再从已发布的实际安装包恢复源：

```sh
git fetch origin --tags
bash scripts/release-sync-feeds.sh v0.1.16 --from-release
```

恢复流程会重新下载远程 IPA 并核对版本、大小和 SHA-256，再同步源，不会覆盖已发布的资产。也可以在 Actions 中手动运行发布工作流，并勾选 `recover_feeds_only`。若发布停在草稿状态，应先解决草稿发布失败的原因，不要把草稿当作稳定更新源。

清单字段与线路说明见 [distribution/README.md](distribution/README.md)。
