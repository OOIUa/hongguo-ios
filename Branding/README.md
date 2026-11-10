# Android 图标来源

同步自 [OOIUa/hongguo-android](https://github.com/OOIUa/hongguo-android) 0.7.8，提交 `69c1d5abf35c2b133885d053c665860e3ccfc9fb`。

`Android/` 保留原始启动图标背景、前景和应用内 logo 的矢量 XML。`scripts/make-icon.swift` 使用相同坐标、颜色、贝塞尔曲线与偶奇填充规则，通过 Core Graphics 生成：

- 1024 × 1024 的 iOS AppIcon，采用 Android 的 `#FFF9F6` 背景，无透明通道，外轮廓由 iOS 处理。Android 自适应图标 108dp 画布只露出中间约 72dp，iOS 若整张绘制标志会过小（issue #5），因此 iOS 只取以标志为中心的 80 单位视窗，标志高度约占图标 66%。
- 同尺寸的深色（透明背景，由系统提供深色底）与着色（黑底白标，由系统按亮度着色）变体，iOS 18 起随主屏幕外观切换。
- 透明的应用内 BrandLogo，采用 Android `ic_logo.xml` 的裁切范围。
- 与 AppIcon 完全相同的全能签源图标。

发布源中的图标地址使用对应版本标签，例如 `v0.1.2/distribution/icon.png`，让图标随版本变更地址，避免继续命中旧图标缓存；软件源订阅地址保持不变。

重新生成：

```sh
xcrun swift scripts/make-icon.swift
```

以后同步 Android 图标时，一并更新 XML、绘制几何及来源提交，再重新生成三个资源。不要恢复旧的“果”字占位图标。
