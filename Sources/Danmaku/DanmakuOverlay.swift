// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), danmaku/DanmakuOverlay.kt — the SwiftUI host that
// places one DanmakuView over the picture. The playback position is read from periodic time
// observations into a cache the view's own display-link loop reads, so no SwiftUI state ticks per
// frame; loading the next windows happens in detached utility tasks and never blocks the UI.
import SwiftUI
import AVFoundation

struct DanmakuOverlay: UIViewRepresentable {
    let seriesID: String
    let episodeID: String
    /// 总时长（秒）；首帧就绪后才有值，取到后才会发起首个窗口请求。
    let durationSeconds: Double
    let player: AVPlayer?
    let settings: DanmakuSettings
    /// 用户设定的弹幕带高度（pt）；视图本身会多留约半行高度用于越界绘制。
    let bandHeight: CGFloat

    final class Coordinator {
        var loader: DanmakuLoader?
        var loaderEpisode: String?
        var boundPlayer: AVPlayer?
        var timeObserver: Any?
        /// 最近一次从宿主转发的位置（秒）；display-link 帧循环读缓存值，避免每帧查询播放器。
        var positionSeconds: Double = 0

        func unbindPlayer() {
            if let observer = timeObserver, let player = boundPlayer { player.removeTimeObserver(observer) }
            timeObserver = nil
            boundPlayer = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DanmakuView {
        let view = DanmakuView()
        view.setBandHeight(bandHeight)
        view.applyPrefs(opacityPct: settings.opacity, font: settings.font, speed: settings.speed, effect: settings.effect)
        return view
    }

    func updateUIView(_ view: DanmakuView, context: Context) {
        let coordinator = context.coordinator
        view.setBandHeight(bandHeight)
        view.applyPrefs(opacityPct: settings.opacity, font: settings.font, speed: settings.speed, effect: settings.effect)
        // 换集时重建 loader；时长首次可知或变化时同步给现有 loader（首个窗口要等时长才知道）。
        if coordinator.loader == nil || coordinator.loaderEpisode != episodeID {
            let loader = DanmakuLoader(repository: DanmakuAPI.repository, seriesID: seriesID, vid: episodeID,
                durationMs: Int64(durationSeconds * 1000),
                onFailure: { error in NSLog("Danmaku window failed: \(error)") })
            coordinator.loader = loader
            coordinator.loaderEpisode = episodeID
            if coordinator.boundPlayer != nil { view.bind(loader: loader, position: { coordinator.positionSeconds }, needMore: coordinator.needMore()) }
        }
        coordinator.loader?.durationMs = Int64(durationSeconds * 1000)
        guard let player else {
            if coordinator.boundPlayer != nil { view.unbind(); coordinator.unbindPlayer() }
            return
        }
        if coordinator.boundPlayer !== player {
            coordinator.unbindPlayer()
            coordinator.boundPlayer = player
            // 每 0.25 秒把播放位置转发给缓存；display-link 帧循环读缓存，避免每帧查询播放器。
            coordinator.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main) { time in
                    guard time.seconds.isFinite else { return }
                    let newSeconds = max(0, time.seconds)
                    // 大幅前跳或后跳（seek）时清掉屏上弹幕；正常播放只更新缓存。
                    if abs(newSeconds - coordinator.positionSeconds) > 1.25 { view.seekTo(positionSeconds: newSeconds) }
                    coordinator.positionSeconds = newSeconds
            }
            view.bind(loader: coordinator.loader!, position: { coordinator.positionSeconds }, needMore: coordinator.needMore())
            let start = max(0, player.currentTime().seconds)
            let loader = coordinator.loader!
            Task.detached(priority: .utility) { await loader.loadUpTo(Int64(start * 1000)) }
        }
    }

    static func dismantleUIView(_ view: DanmakuView, coordinator: Coordinator) {
        view.unbind()
        coordinator.unbindPlayer()
        coordinator.loader = nil
    }
}

extension DanmakuOverlay.Coordinator {
    /// 宿主侧的补载回调：视图每秒左右抬一次，任务在后台线程跑。
    func needMore() -> (Double) -> Void {
        { [weak self] position in
            guard let loader = self?.loader else { return }
            Task.detached(priority: .utility) { await loader.loadUpTo(Int64(position * 1000)) }
        }
    }
}
