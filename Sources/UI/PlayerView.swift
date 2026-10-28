import SwiftUI
import AVFoundation
import UIKit

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session: PlayerSession
    @State private var episodesVisible = false
    @State private var speedsVisible = false

    init(request: PlaybackRequest, model: AppModel) { _session = StateObject(wrappedValue: PlayerSession(request: request, app: model)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = session.player {
                    PlayerLayerView(player: player) { [ticket = session.playID] in session.firstFrame(ticket: ticket) }.id(session.playID).ignoresSafeArea().allowsHitTesting(false)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geometry.size.height < 420 ? 58 : 70).allowsHitTesting(false)
                        VideoGestureView(tap: session.toggle, holdBegan: session.beginHold, holdEnded: session.endHold, up: session.next, down: session.previous)
                            .accessibilityElement().accessibilityLabel("视频画面").accessibilityHint("轻点暂停或继续，上下滑动切换剧集").accessibilityAddTraits(.isButton).accessibilityAction { session.toggle() }
                        Color.clear.frame(height: geometry.size.height < 420 ? 112 : 174).allowsHitTesting(false)
                    }.zIndex(1)
                }
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).frame(maxHeight: .infinity, alignment: .top).allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: min(geometry.size.height * 0.45, 300)).frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar
                    if session.holding { Label("2× 临时加速中", systemImage: "forward.fill").font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 8).background(.black.opacity(0.5), in: Capsule()).padding(.top, 10) }
                    Spacer(minLength: 10)
                    if session.preparing { preparationPanel }
                    else if let error = session.error { errorPanel(error) }
                    else if session.buffering { ProgressView().tint(.white).scaleEffect(1.4) }
                    else if !session.isPlaying && session.player != nil {
                        Button(action: session.toggle) { Image(systemName: "play.fill").font(.system(size: 38)).frame(width: 82, height: 82).background(.black.opacity(0.3), in: Circle()) }.buttonStyle(.plain).accessibilityLabel("继续播放")
                    }
                    Spacer(minLength: 10)
                    if let end = session.endMessage { Text(end).font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12) }
                    bottomBar(compact: geometry.size.height < 420)
                }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12).zIndex(2)
            }.foregroundStyle(.white)
        }.background(.black).preferredColorScheme(.dark).statusBarHidden(false)
            .sheet(isPresented: $episodesVisible) { episodeSheet }
            .sheet(isPresented: $speedsVisible) { speedSheet }
            .task { session.start() }
            .onDisappear { session.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.suspend() } }
            .onChange(of: episodesVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: speedsVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: session.app.preloadNext) { _, _ in session.preferencesChanged() }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 13) {
            Button { session.stop(); dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 40, height: 44).background(.black.opacity(0.18), in: Circle()) }.accessibilityLabel("关闭播放器")
            VStack(alignment: .leading, spacing: 4) { Text(session.detail.drama.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text("第 \(session.episode.index) 集 / 共 \(session.detail.episodes.count) 集").font(.caption).foregroundStyle(.white.opacity(0.7)) }.frame(maxWidth: .infinity, alignment: .leading)
            Button { library.toggleFavorite(session.detail.drama) } label: { Image(systemName: library.isFavorite(session.detail.drama) ? "star.fill" : "star").font(.title3).foregroundStyle(library.isFavorite(session.detail.drama) ? .yellow : .white).frame(width: 44, height: 44) }.accessibilityLabel(library.isFavorite(session.detail.drama) ? "取消本机收藏" : "添加本机收藏")
        }.buttonStyle(.plain)
    }

    private var preparationPanel: some View {
        VStack(spacing: 15) { ProgressView().tint(.white).scaleEffect(1.2); Text(session.stage).font(.subheadline); if session.progress > 0 { ProgressView(value: session.progress).tint(Color(hex: 0xF07850)).frame(width: 180); Text("\(Int(session.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.65)) }; Text("首次播放需准备视频，请稍候").font(.caption2).foregroundStyle(.white.opacity(0.5)) }.padding(25).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) { Image(systemName: "exclamationmark.circle").font(.largeTitle); Text(message).font(.subheadline).multilineTextAlignment(.center).lineLimit(5); HStack(spacing: 15) { Button("重试", action: session.retry).buttonStyle(.borderedProminent).tint(Color(hex: 0xC94426)); Button("选择其他集") { episodesVisible = true }.buttonStyle(.bordered) } }.padding(25).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private func bottomBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 13) {
            if !compact { HStack { Text("第 \(session.episode.index) 集").font(.title3.bold()); Spacer(); Text("上滑下一集 · 左侧长按 2×").font(.caption2).foregroundStyle(.white.opacity(0.55)) } }
            HStack(spacing: 10) {
                Text(timeLabel(session.scrubbing ? session.previewPosition : session.position)).font(.caption.monospacedDigit()).frame(minWidth: 36)
                Slider(value: Binding(get: { session.scrubbing ? session.previewPosition : session.position }, set: { session.previewPosition = $0 }), in: 0...max(session.duration, 1), onEditingChanged: session.setSeeking).tint(Color(hex: 0xF08058)).disabled(session.duration <= 0).accessibilityLabel("播放进度")
                Text(timeLabel(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6)).frame(minWidth: 36)
            }
            HStack(spacing: 8) {
                Button(action: session.previous) { Image(systemName: "backward.end.fill").frame(width: 38, height: 44).contentShape(Rectangle()) }.disabled(session.index == 0).accessibilityLabel("上一集")
                Button(action: session.toggle) { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 38, height: 44).contentShape(Rectangle()) }.disabled(session.player == nil).accessibilityLabel(session.isPlaying ? "暂停" : "播放")
                Button(action: session.next) { Image(systemName: "forward.end.fill").frame(width: 38, height: 44).contentShape(Rectangle()) }.disabled(session.index + 1 >= session.detail.episodes.count).accessibilityLabel("下一集")
                Spacer(minLength: 0)
                Button { speedsVisible = true } label: { Text(String(format: "%g×", session.app.speed)).font(.subheadline.weight(.semibold)).frame(minWidth: 52, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("播放倍速").accessibilityValue(String(format: "%g×", session.app.speed)).accessibilityIdentifier("player.speed")
                Button { episodesVisible = true } label: { Label("选集", systemImage: "square.grid.2x2").font(.subheadline.weight(.semibold)).frame(minHeight: 44).contentShape(Rectangle()) }.accessibilityIdentifier("player.episodes")
            }.buttonStyle(.plain)
        }
    }

    private var episodeSheet: some View {
        NavigationStack {
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 49), spacing: 10)], spacing: 12) { ForEach(Array(session.detail.episodes.enumerated()), id: \.element.id) { index, episode in Button { episodesVisible = false; session.load(index: index, startAt: index == session.index ? session.position : 0) } label: { Text("\(episode.index)").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48).background(index == session.index ? Color(hex: 0xC94426) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11)) }.buttonStyle(.plain) } }.padding(20) }.background(Color(hex: 0x171719)).navigationTitle("全部 \(session.detail.episodes.count) 集").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { episodesVisible = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
    }

    private var speedSheet: some View {
        NavigationStack { List { ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in Button { session.setSpeed(speed); speedsVisible = false } label: { HStack { Text(String(format: "%g×", speed)); Spacer(); if session.app.speed == speed { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0xF08058)) } }.foregroundStyle(.white).frame(minHeight: 33) } } }.navigationTitle("播放倍速").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { speedsVisible = false } } } }.presentationDetents([.height(405)]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
    }
}

private final class PlayerLayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let onFirstFrame: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFirstFrame) }
    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerHost()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak coordinator = context.coordinator] layer, _ in if layer.isReadyForDisplay { DispatchQueue.main.async { coordinator?.ready() } } }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { (uiView as? PlayerLayerHost)?.playerLayer.player = player }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.observation = nil; (uiView as? PlayerLayerHost)?.playerLayer.player = nil }
    final class Coordinator { var observation: NSKeyValueObservation?; private var sent = false; let callback: () -> Void; init(_ callback: @escaping () -> Void) { self.callback = callback }; func ready() { guard !sent else { return }; sent = true; callback() } }
}

private struct VideoGestureView: UIViewRepresentable {
    let tap: () -> Void
    let holdBegan: () -> Void
    let holdEnded: () -> Void
    let up: () -> Void
    let down: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))); hold.minimumPressDuration = 0.35; hold.allowableMovement = 18
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)); tap.require(toFail: hold)
        let up = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:))); up.direction = .up
        let down = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:))); down.direction = .down
        view.addGestureRecognizer(hold); view.addGestureRecognizer(tap); view.addGestureRecognizer(up); view.addGestureRecognizer(down)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.parent.holdEnded() }
    final class Coordinator: NSObject {
        var parent: VideoGestureView
        init(_ parent: VideoGestureView) { self.parent = parent }
        @objc func tapped() { parent.tap() }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began, let view = gesture.view, gesture.location(in: view).x < view.bounds.width / 2 { parent.holdBegan() }; if [.ended, .cancelled, .failed].contains(gesture.state) { parent.holdEnded() } }
        @objc func swiped(_ gesture: UISwipeGestureRecognizer) { parent.holdEnded(); if gesture.direction == .up { parent.up() } else { parent.down() } }
    }
}
