# 发布清单与全能签软件源

这四份 JSON 由 `scripts/generate-feeds.py` 从实际未签名 IPA 生成，请勿手工改版本、大小或校验值。

- `source.json`：GitHub 直连下载。
- `source-cn.json`：通过 `gh-proxy.com` 加速源、图标及 IPA。
- `source-cn-backup.json`：通过 `ghfast.top` 备用加速。
- `update.json`：应用检查更新使用的版本、build、最低系统、说明、下载地址、SHA-256、字节数及镜像。

源的字段参照[全能签官方源](https://qnq.nuosike.cn/)。三条线路使用同一 IPA、版本、build、发布时间、大小和 SHA-256。加速服务由第三方提供。

日常发布：先更新 `Configuration/Release.json`，提交到 main，再推送对应的 `vX.Y.Z` tag。GitHub Actions 会运行离线测试、构建未签名设备包，校验 IPA 内的真实版本/部署目标/签名状态，生成清单和对应源码 ZIP，再上传 Release 并同步这四份 JSON。

本地仅准备材料（不会发布或提交）：

```sh
bash scripts/release.sh v0.1.1 --skip-build
python3 scripts/generate-feeds.py --tag v0.1.1 --check
python3 scripts/test-feeds.py
```

不传 `--skip-build` 会先构建。公开发布为独立步骤 `bash scripts/release-publish.sh v0.1.1`，通常交给 Actions 执行，以免本机与 CI 同时发布。

若 Release 已公开而源同步失败，请不要重建并覆盖该版本的资产。可以在 Actions 手动运行 release workflow，填入已有 tag，并勾选 `recover_feeds_only`；也可以在已认证的本地仓库执行：

```sh
git fetch origin --tags
bash scripts/release-sync-feeds.sh v0.1.1 --from-release
```

恢复会从该 tag 取配置，下载已发布的真实 IPA 和清单，重新校验 IPA 的 SHA-256/大小/版本/build/最低系统/未签名状态，再将四份清单提交到最新 main。只要实际 GitHub latest 或 main 清单已有更高版本，就跳过旧版同步，避免回退。同步使用普通 push；main 并发前进时从新 main 重试，最多三次，不能写入会明确失败。保护分支若禁止机器人直接提交，需要管理员允许该发布流程写入 main。

上传失败可能留下未公开草稿。先检查草稿资产及失败日志；清理该草稿后才可重新运行完整发布，脚本不会自动覆盖任何已存在的草稿或公开 Release。
