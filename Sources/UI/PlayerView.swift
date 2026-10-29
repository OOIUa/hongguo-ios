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
    // Page drag: the current picture follows the finger and the neighbouring episode number slides in.
    @State private var pageHeight: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var dragging = false
    @State private var sliding = false
    @State private var slideTarget: Int?

    init(request: PlaybackRequest, model: AppModel) { _session = StateObject(wrappedValue: PlayerSession(request: request, app: model)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                GeometryReader { full in
                    pages(height: full.size.height)
                        .onAppear { pageHeight = max(full.size.height, 1) }
                        .onChange(of: full.size.height) { _, height in pageHeight = max(height, 1) }
                }.ignoresSafeArea().allowsHitTesting(false)
                VStack(spacing: 0) {
                    Color.clear.frame(height: geometry.size.height < 420 ? 58 : 70).allowsHitTesting(false)
                    VideoGestureView(enabled: !sliding && !episodesVisible && !speedsVisible && !session.scrubbing,
                                     tap: session.toggle, holdBegan: session.beginHold, holdEnded: session.endHold,
                                     dragChanged: dragChanged, dragEnded: dragEnded, dragCancelled: dragCancelled)
                        .accessibilityElement().accessibilityLabel("视频画面").accessibilityHint("轻点暂停或继续，上下拖动切换剧集").accessibilityAddTraits(.isButton)
                        .accessibilityAction { session.toggle() }
                        .accessibilityAction(named: "下一集") { session.next() }
                        .accessibilityAction(named: "上一集") { session.previous() }
                    Color.clear.frame(height: geometry.size.height < 420 ? 112 : 174).allowsHitTesting(false)
                }.zIndex(1)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).frame(maxHeight: .infinity, alignment: .top).allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: min(geometry.size.height * 0.45, 300)).frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar
                    if session.holding { Label("2× 临时加速中", systemImage: "forward.fill").font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 8).background(.black.opacity(0.5), in: Capsule()).padding(.top, 10) }
                    Spacer(minLength: 10)
                    if dragging || sliding { EmptyView() }
                    else if session.preparing { preparationPanel.allowsHitTesting(false) }
                    else if let error = session.error { errorPanel(error) }
                    else if session.buffering { ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false) }
                    else if !session.isPlaying && session.player != nil {
                        Button(action: session.toggle) { Image(systemName: "play.fill").font(.system(size: 38)).frame(width: 82, height: 82).background(.black.opacity(0.3), in: Circle()) }.buttonStyle(.plain).accessibilityLabel("继续播放")
                    }
                    Spacer(minLength: 10)
                    if let end = session.endMessage { Text(end).font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12) }
                    bottomBar(compact: geometry.size.height < 420)
                }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12).zIndex(2).allowsHitTesting(!sliding)
            }.foregroundStyle(.white)
        }.background(.black).preferredColorScheme(.dark).statusBarHidden(false)
            .sheet(isPresented: $episodesVisible) { episodeSheet }
            .sheet(isPresented: $speedsVisible) { speedSheet }
            .task { session.onSlide = { target in slide(to: target) }; session.start() }
            .onDisappear { session.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.suspend() } }
            .onChange(of: episodesVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: speedsVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: session.app.preloadNext) { _, _ in session.preferencesChanged() }
    }

    // MARK: Episode paging

    /// The episode whose page fills most of the screen, so labels change half-way through a drag like a pager.
    private var visibleEpisode: Episode {
        let episodes = session.detail.episodes
        if dragOffset <= -pageHeight / 2 { return episodes[min(slideTarget ?? session.index + 1, episodes.count - 1)] }
        if dragOffset >= pageHeight / 2 { return episodes[max(slideTarget ?? session.index - 1, 0)] }
        return session.episode
    }

    private func pages(height: CGFloat) -> some View {
        let count = session.detail.episodes.count
        let above = slideTarget.flatMap { $0 < session.index ? $0 : nil } ?? session.index - 1
        let below = slideTarget.flatMap { $0 > session.index ? $0 : nil } ?? session.index + 1
        return ZStack {
            if above >= 0 { neighbourPage(above).offset(y: dragOffset - height) }
            currentPage.offset(y: dragOffset)
            if below < count { neighbourPage(below).offset(y: dragOffset + height) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }

    private var currentPage: some View {
        ZStack {
            Color.black
            if let player = session.player {
                PlayerLayerView(player: player) { [ticket = session.playID] in session.firstFrame(ticket: ticket) }.id(session.playID)
            }
            // Fade the picture in once its first frame is on screen instead of popping from black; cover instantly on switch.
            Color.black.opacity(session.rendered ? 0 : 1).animation(session.rendered ? Animation.easeOut(duration: 0.24) : nil, value: session.rendered)
            if !session.rendered && (dragging || sliding) { EpisodePlaceholder(number: session.episode.index, title: session.detail.drama.title) }
        }
    }

    private func neighbourPage(_ index: Int) -> some View {
        ZStack { Color.black; EpisodePlaceholder(number: session.detail.episodes[index].index, title: session.detail.drama.title) }
    }

    private func dragChanged(_ translation: CGFloat) {
        guard !sliding else { return }
        if !dragging { dragging = true; session.holdForGesture() }
        let atFirst = session.index == 0 && translation > 0
        let atLast = session.index + 1 >= session.detail.episodes.count && translation < 0
        dragOffset = atFirst || atLast ? translation * 0.28 : translation
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        guard dragging else { return }
        dragging = false
        let projected = translation + velocity * 0.18
        let direction = projected <= -pageHeight * 0.3 ? 1 : (projected >= pageHeight * 0.3 ? -1 : 0)
        let target = session.index + direction
        if direction != 0, session.detail.episodes.indices.contains(target) { commitSlide(to: target); return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
        if scenePhase == .active { session.releaseGesture() }
        if direction == 1 { session.next() } else if direction == -1 { session.previous() }
    }

    private func dragCancelled() {
        guard dragging else { return }
        dragging = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { dragOffset = 0 }
        if scenePhase == .active { session.releaseGesture() }
    }

    /// Autoplay, buttons and the episode sheet slide the same way a swipe does. Touches are off until the slide ends.
    private func slide(to target: Int) {
        guard !sliding, !dragging, target != session.index, session.detail.episodes.indices.contains(target) else { return }
        session.holdForGesture()
        commitSlide(to: target)
    }

    private func commitSlide(to target: Int) {
        let direction: CGFloat = target > session.index ? 1 : -1
        sliding = true; slideTarget = target
        withAnimation(.easeInOut(duration: 0.32)) { dragOffset = -direction * pageHeight } completion: {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                session.load(index: target, startAt: 0)
                dragOffset = 0; slideTarget = nil; sliding = false
            }
            if scenePhase != .active { session.suspend() }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 13) {
            Button { session.stop(); dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 40, height: 44).background(.black.opacity(0.18), in: Circle()) }.accessibilityLabel("关闭播放器")
            VStack(alignment: .leading, spacing: 4) { Text(session.detail.drama.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text("第 \(visibleEpisode.index) 集 / 共 \(session.detail.episodes.count) 集").font(.caption).foregroundStyle(.white.opacity(0.7)) }.frame(maxWidth: .infinity, alignment: .leading)
            Button { library.toggleFavorite(session.detail.drama) } label: { Image(systemName: library.isFavorite(session.detail.drama) ? "star.fill" : "star").font(.title3).foregroundStyle(library.isFavorite(session.detail.drama) ? .yellow : .white).frame(width: 44, height: 44) }.accessibilityLabel(library.isFavorite(session.detail.drama) ? "取消本机收藏" : "添加本机收藏")
        }.buttonStyle(.plain)
    }

    private var preparationPanel: some View {
        VStack(spacing: 15) { ProgressView().tint(.white).scaleEffect(1.2); Text(session.stage).font(.subheadline); Text("正在准备首帧，无需等待整集下载").font(.caption2).foregroundStyle(.white.opacity(0.5)) }.padding(25).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) { Image(systemName: "exclamationmark.circle").font(.largeTitle); Text(message).font(.subheadline).multilineTextAlignment(.center).lineLimit(5); HStack(spacing: 15) { Button("重试", action: session.retry).buttonStyle(.borderedProminent).tint(Color(hex: 0xC94426)); Button("选择其他集") { episodesVisible = true }.buttonStyle(.bordered) } }.padding(25).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
    }

    private func bottomBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 13) {
            if !compact { HStack { Text("第 \(visibleEpisode.index) 集").font(.title3.bold()); Spacer(); Text("上滑下一集 · 左侧长按 2×").font(.caption2).foregroundStyle(.white.opacity(0.55)) } }
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
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 49), spacing: 10)], spacing: 12) { ForEach(Array(session.detail.episodes.enumerated()), id: \.element.id) { index, episode in Button { episodesVisible = false; if index != session.index { session.go(to: index) } else if session.error != nil { session.retry() } } label: { Text("\(episode.index)").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48).background(index == session.index ? Color(hex: 0xC94426) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11)) }.buttonStyle(.plain) } }.padding(20) }.background(Color(hex: 0x171719)).navigationTitle("全部 \(session.detail.episodes.count) 集").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { episodesVisible = false } } }
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

private struct EpisodePlaceholder: View {
    let number: Int
    let title: String
    var body: some View {
        VStack(spacing: 6) {
            Text("第 \(number) 集").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.78))
            Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }.padding(.horizontal, 40).accessibilityHidden(true)
    }
}

private struct VideoGestureView: UIViewRepresentable {
    let enabled: Bool
    let tap: () -> Void
    let holdBegan: () -> Void
    let holdEnded: () -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat, CGFloat) -> Void
    let dragCancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))); hold.minimumPressDuration = 0.35; hold.allowableMovement = 18
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)); tap.require(toFail: hold)
        // A vertical pan replaces the old one-shot swipes so the page follows the finger. While a hold is active the
        // pan cannot start, and a pan that starts first makes the hold fail, so 2x and paging never mix.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:))); pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        let recognizers: [UIGestureRecognizer] = [hold, tap, pan]
        recognizers.forEach { $0.isEnabled = enabled; view.addGestureRecognizer($0) }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.gestureRecognizers?.forEach { if $0.isEnabled != enabled { $0.isEnabled = enabled } }
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.parent.holdEnded(); coordinator.parent.dragCancelled() }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: VideoGestureView
        init(_ parent: VideoGestureView) { self.parent = parent }
        @objc func tapped() { parent.tap() }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began, let view = gesture.view, gesture.location(in: view).x < view.bounds.width / 2 { parent.holdBegan() }; if [.ended, .cancelled, .failed].contains(gesture.state) { parent.holdEnded() } }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began, .changed: parent.dragChanged(gesture.translation(in: view).y)
            case .ended: parent.dragEnded(gesture.translation(in: view).y, gesture.velocity(in: view).y)
            case .cancelled, .failed: parent.dragCancelled()
            default: break
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
    }
}
