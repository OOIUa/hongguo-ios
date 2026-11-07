import SwiftUI
import AVFoundation
import UIKit

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session: PlayerSession
    @StateObject private var surface = PlayerSurface()
    @State private var episodesVisible = false
    @State private var speedsVisible = false
    /// 短剧详情 over the player; the episode waits paused underneath and goes on when the sheet closes.
    @State private var detailVisible = false
    @State private var resumeAfterDetail = false
    /// The side badge after a double-tap skip; quick repeats on the same side add up.
    @State private var skipFeedback: SkipFeedback?
    // Page drag: the current picture follows the finger and the neighbouring episode number slides in.
    @State private var pageHeight: CGFloat = 1
    @State private var dragOffset: CGFloat = 0
    @State private var dragging = false
    @State private var sliding = false
    @State private var slideTarget: Int?
    /// 清屏: only the picture remains until a tap or an inward pinch brings the controls back.
    @State private var cleanScreen = false
    /// Landscape is full-screen viewing, whether 全屏观看 turned the screen or the user did: episodes change from the
    /// controls, the episode sheet or autoplay rather than by swiping.
    @State private var landscape = false
    /// Holding for 2× hides the same elements, for as long as the hold lasts.
    private var chromeHidden: Bool { cleanScreen || session.holding }
    /// Just under a picture wider than tall, as in the official app.
    private var fullScreenOffered: Bool {
        !landscape && !chromeHidden && session.rendered && session.error == nil && !dragging && !sliding && !surface.pipActive
            && session.videoSize.width > session.videoSize.height
    }

    private let requestID: UUID

    init(request: PlaybackRequest, model: AppModel) { requestID = request.id; _session = StateObject(wrappedValue: PlayerSession(request: request, app: model)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // The insets keep touches near the controls from reaching the picture; with the controls gone the whole screen responds.
                    Color.clear.frame(height: cleanScreen ? 0 : (geometry.size.height < 420 ? 58 : 70)).allowsHitTesting(false)
                    VideoGestureView(enabled: !sliding && !episodesVisible && !speedsVisible && !detailVisible && !session.scrubbing,
                                     tap: videoTapped, doubleTap: videoDoubleTapped, holdBegan: session.beginHold, holdEnded: session.endHold,
                                     dragChanged: dragChanged, dragEnded: dragEnded, dragCancelled: dragCancelled,
                                     pinched: { if !landscape { cleanScreen = $0 } })
                        .accessibilityElement().accessibilityLabel("视频画面").accessibilityHint((session.isPlaying ? "轻点暂停" : "轻点继续播放") + (landscape ? "" : "，上下拖动切换剧集")).accessibilityAddTraits(.isButton)
                        .accessibilityAction { session.toggle() }
                        .accessibilityAction(named: cleanScreen ? "退出清屏" : "清屏播放") { cleanScreen.toggle() }
                        .accessibilityAction(named: "快退 10 秒") { skip(forward: false) }
                        .accessibilityAction(named: "快进 10 秒") { skip(forward: true) }
                        .accessibilityAction(named: "下一集") { session.next() }
                        .accessibilityAction(named: "上一集") { session.previous() }
                    Color.clear.frame(height: cleanScreen ? 0 : (geometry.size.height < 420 ? 112 : 174)).allowsHitTesting(false)
                }.ignoresSafeArea(edges: cleanScreen ? .all : []).zIndex(1)
                if let feedback = skipFeedback {
                    SkipBadge(feedback: feedback)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: feedback.forward ? .trailing : .leading)
                        .padding(.horizontal, landscape ? 70 : 26).allowsHitTesting(false).transition(.opacity).zIndex(1.6)
                }
                if fullScreenOffered {
                    GeometryReader { full in
                        let pictureHeight = min(full.size.height, full.size.width * session.videoSize.height / session.videoSize.width)
                        Button(action: enterFullScreen) {
                            Label("全屏观看", systemImage: "rotate.right").font(.footnote.weight(.medium))
                                .padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityIdentifier("player.fullScreen")
                        .position(x: full.size.width / 2, y: (full.size.height + pictureHeight) / 2 + 30)
                    }.ignoresSafeArea().zIndex(1.5).transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 150).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom).frame(height: min(geometry.size.height * 0.45, 300)).frame(maxHeight: .infinity, alignment: .bottom).ignoresSafeArea().opacity(chromeHidden ? 0 : 1).allowsHitTesting(false)
                VStack(spacing: 0) {
                    chrome { topBar }
                    Spacer(minLength: 10)
                    if dragging || sliding { EmptyView() }
                    else if session.preparing { preparationPanel.allowsHitTesting(false) }
                    else if let error = session.error { errorPanel(error) }
                    else if chromeHidden { EmptyView() }
                    else if session.buffering { ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false) }
                    else if !session.isPlaying && session.player != nil {
                        Button(action: session.toggle) { Image(systemName: "play.fill").font(.system(size: 38)).frame(width: 82, height: 82).background(.black.opacity(0.3), in: Circle()) }.buttonStyle(.plain).accessibilityLabel("继续播放")
                    }
                    Spacer(minLength: 10)
                    if let end = session.endMessage { chrome { Text(end).font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12) } }
                    chrome { bottomBar(compact: geometry.size.height < 420) }
                }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, landscape ? 0 : 12).zIndex(2).allowsHitTesting(!sliding)
            }.foregroundStyle(.white)
            .animation(.easeOut(duration: 0.18), value: chromeHidden)
        }
        // The picture sits behind everything at the full screen size, under the home indicator and the camera
        // housing as well, so full screen reaches every edge whatever space the controls take.
        .background {
            GeometryReader { full in
                pages(height: full.size.height)
                    .onAppear { pageHeight = max(full.size.height, 1); landscape = full.size.width > full.size.height }
                    .onChange(of: full.size) { _, size in pageHeight = max(size.height, 1); landscape = size.width > size.height }
            }.background(.black).ignoresSafeArea().allowsHitTesting(false)
        }
        .preferredColorScheme(.dark).statusBarHidden(chromeHidden).persistentSystemOverlays(chromeHidden ? .hidden : .automatic)
            .sheet(isPresented: $episodesVisible) { episodeSheet }
            .sheet(isPresented: $speedsVisible) { speedSheet }
            .sheet(isPresented: $detailVisible, onDismiss: detailClosed) { detailSheet }
            .task {
                surface.bind(session)
                surface.closedInBackground = { session.suspend() }
                session.onSlide = { target in slide(to: target) }; session.start()
            }
            .onDisappear { session.stop(); surface.unbind(); InterfaceOrientationLock.lock(InterfaceOrientationLock.free, rotate: false) }
            // Only a real move to the background pauses: an episode that is playing then goes on in the small window
            // (the system starts it as the app leaves), and anything else stops as before.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background, !surface.pipActive, !surface.pipStarting else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    if UIApplication.shared.applicationState == .background, !surface.pipActive, !surface.pipStarting { session.suspend() }
                }
            }
            .onChange(of: landscape) { _, _ in cleanScreen = false }
            // In full screen the controls step aside after a few seconds of playback.
            .task(id: autoHideKey) {
                guard landscape, !cleanScreen, session.isPlaying, !session.scrubbing, !episodesVisible, !speedsVisible, !detailVisible else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { cleanScreen = true }
            }
            .onChange(of: episodesVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: speedsVisible) { _, shown in if shown { session.endHold() } }
            .onChange(of: session.app.preloadNext) { _, _ in session.preferencesChanged() }
            // Anything the viewer has to act on brings the controls back: an error, the end of the last episode, a pause they did not ask for.
            .onChange(of: session.error) { _, error in if error != nil { cleanScreen = false } }
            .onChange(of: session.endMessage) { _, message in if message != nil { cleanScreen = false } }
            .onChange(of: session.isPlaying) { _, playing in
                if !playing, !session.buffering, !session.preparing, session.rendered, !dragging, !sliding { cleanScreen = false }
            }
    }

    /// As in Bilibili-style players: a tap shows or hides the controls; a double tap on the left or right third jumps
    /// 10 seconds back or ahead, and in the middle pauses or resumes. A pause brings the controls back by itself.
    private func videoTapped(at fraction: CGFloat) {
        // Taps that follow a skip on the same side keep skipping, so tap-tap-tap goes 20 seconds.
        if let feedback = skipFeedback, feedback.forward ? fraction > 0.7 : fraction < 0.3 { skip(forward: feedback.forward); return }
        cleanScreen.toggle()
    }

    private func videoDoubleTapped(at fraction: CGFloat) {
        if fraction < 0.3 { skip(forward: false) } else if fraction > 0.7 { skip(forward: true) } else if session.player != nil { session.toggle() }
    }

    private func skip(forward: Bool) {
        guard session.skip(by: forward ? 10 : -10) else { return }
        let feedback = SkipFeedback(forward: forward, seconds: (skipFeedback?.forward == forward ? skipFeedback?.seconds ?? 0 : 0) + 10)
        withAnimation(.easeOut(duration: 0.12)) { skipFeedback = feedback }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if skipFeedback == feedback { withAnimation(.easeOut(duration: 0.25)) { skipFeedback = nil } }
        }
    }

    private func openDetail() {
        resumeAfterDetail = session.isPlaying
        if session.isPlaying { session.pause() }
        detailVisible = true
    }

    private func detailClosed() {
        // Playing an episode from the detail page replaces this player, so nothing resumes behind the new one.
        if resumeAfterDetail, !session.isPlaying, session.app.playback?.id == requestID { session.toggle() }
        resumeAfterDetail = false
    }

    private var autoHideKey: String { "\(landscape)-\(cleanScreen)-\(session.isPlaying)-\(session.scrubbing)-\(episodesVisible || speedsVisible || detailVisible)" }

    /// 全屏观看 holds landscape; leaving it holds portrait until the player closes, even with the phone held sideways.
    private func enterFullScreen() { InterfaceOrientationLock.lock(.landscape, rotate: true) }
    private func exitFullScreen() { InterfaceOrientationLock.lock(.portrait, rotate: true) }

    /// Controls fade out with the screen and stop taking touches and VoiceOver focus.
    private func chrome(@ViewBuilder content: () -> some View) -> some View {
        content().opacity(chromeHidden ? 0 : 1).allowsHitTesting(!chromeHidden).accessibilityHidden(chromeHidden)
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
            PlayerSurfaceView(surface: surface)
            // Fade the picture in once its first frame is on screen instead of popping from black; cover instantly on switch.
            Color.black.opacity(session.rendered ? 0 : 1).animation(session.rendered ? Animation.easeOut(duration: 0.24) : nil, value: session.rendered)
            if !session.rendered && (dragging || sliding) { EpisodePlaceholder(number: session.episode.index, title: session.detail.drama.title) }
            if surface.pipActive {
                VStack(spacing: 10) { Image(systemName: "pip").font(.system(size: 34)); Text("正在小窗播放").font(.subheadline) }.foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func neighbourPage(_ index: Int) -> some View {
        ZStack { Color.black; EpisodePlaceholder(number: session.detail.episodes[index].index, title: session.detail.drama.title) }
    }

    private func dragChanged(_ translation: CGFloat) {
        guard !sliding, !landscape else { return }
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
        // Full screen has no pages to slide, and the small window may be running with the app in the background.
        if landscape || surface.pipActive { session.load(index: target, startAt: 0); return }
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
            Button { if landscape { exitFullScreen() } else { session.stop(); dismiss() } } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 40, height: 44).background(.black.opacity(0.18), in: Circle()) }.accessibilityLabel(landscape ? "退出全屏" : "关闭播放器")
            Button(action: openDetail) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) { Text(session.detail.drama.title).font(.subheadline.weight(.semibold)).lineLimit(1); Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6)) }
                    Text("第 \(visibleEpisode.index) 集 / 共 \(session.detail.episodes.count) 集").font(.caption).foregroundStyle(.white.opacity(0.7))
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityLabel("\(session.detail.drama.title)，第 \(visibleEpisode.index) 集").accessibilityHint("打开短剧详情").accessibilityIdentifier("player.dramaTitle")
            if surface.pipPossible {
                Button { if surface.pipActive { surface.stopPictureInPicture() } else { surface.startPictureInPicture() } } label: { Image(systemName: surface.pipActive ? "pip.exit" : "pip.enter").font(.title3).frame(width: 40, height: 44) }.accessibilityLabel(surface.pipActive ? "退出小窗" : "小窗播放").accessibilityIdentifier("player.pip")
            }
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
            if !compact { HStack { Text("第 \(visibleEpisode.index) 集").font(.title3.bold()); Spacer(); Text("双击暂停 · 双击两侧快退/快进 · 左侧长按 2×").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.8) } }
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
                if landscape {
                    Button(action: exitFullScreen) { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 40, height: 44).contentShape(Rectangle()) }.accessibilityLabel("退出全屏").accessibilityIdentifier("player.exitFullScreen")
                }
            }.buttonStyle(.plain)
        }
    }

    private var episodeSheet: some View {
        NavigationStack {
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 49), spacing: 10)], spacing: 12) { ForEach(Array(session.detail.episodes.enumerated()), id: \.element.id) { index, episode in Button { episodesVisible = false; if index != session.index { session.go(to: index) } else if session.error != nil { session.retry() } } label: { Text("\(episode.index)").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48).background(index == session.index ? Color(hex: 0xC94426) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11)) }.buttonStyle(.plain) } }.padding(20) }.background(Color(hex: 0x171719)).navigationTitle("全部 \(session.detail.episodes.count) 集").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { episodesVisible = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
    }

    /// The same page the library and home open, themed like them rather than like the dark player.
    private var detailSheet: some View {
        NavigationStack {
            DetailView(drama: session.detail.drama)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detailVisible = false } } }
        }.environment(\.colorScheme, session.app.isDark ? .dark : .light).preferredColorScheme(session.app.isDark ? .dark : .light)
        .presentationDragIndicator(.visible)
    }

    private var speedSheet: some View {
        NavigationStack { List { ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in Button { session.setSpeed(speed); speedsVisible = false } label: { HStack { Text(String(format: "%g×", speed)); Spacer(); if session.app.speed == speed { Image(systemName: "checkmark").foregroundStyle(Color(hex: 0xF08058)) } }.foregroundStyle(.white).frame(minHeight: 33) } } }.navigationTitle("播放倍速").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { speedsVisible = false } } } }.presentationDetents([.height(405)]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
    }
}

private struct SkipFeedback: Equatable {
    let forward: Bool
    let seconds: Int
    let id = UUID()
}

private struct SkipBadge: View {
    let feedback: SkipFeedback
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: feedback.forward ? "forward.fill" : "backward.fill").font(.system(size: 22))
            Text("\(feedback.forward ? "+" : "-")\(feedback.seconds) 秒").font(.caption.weight(.semibold).monospacedDigit())
        }.frame(width: 86, height: 86).background(.black.opacity(0.4), in: Circle()).accessibilityHidden(true)
    }
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
    /// Where the tap landed across the picture, 0 at the left edge and 1 at the right.
    let tap: (CGFloat) -> Void
    let doubleTap: (CGFloat) -> Void
    let holdBegan: () -> Void
    let holdEnded: () -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat, CGFloat) -> Void
    let dragCancelled: () -> Void
    /// true for fingers moving apart, false for fingers moving together. Fires once per gesture.
    let pinched: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:))); hold.minimumPressDuration = 0.35; hold.allowableMovement = 18
        // A single tap waits for the double tap to fail (about a quarter second), as in other players with double-tap skips.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2; doubleTap.require(toFail: hold)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))); tap.require(toFail: hold); tap.require(toFail: doubleTap)
        // A vertical pan replaces the old one-shot swipes so the page follows the finger. While a hold is active the
        // pan cannot start, and a pan that starts first makes the hold fail, so 2x and paging never mix.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:))); pan.maximumNumberOfTouches = 1; pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinchChanged(_:)))
        let recognizers: [UIGestureRecognizer] = [hold, doubleTap, tap, pan, pinch]
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
        private var pinchDecided = false
        init(_ parent: VideoGestureView) { self.parent = parent }
        @objc func pinchChanged(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { pinchDecided = false }
            guard gesture.state == .changed, !pinchDecided, gesture.scale >= 1.18 || gesture.scale <= 0.85 else { return }
            pinchDecided = true
            parent.pinched(gesture.scale > 1)
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) { if let x = fraction(gesture) { parent.tap(x) } }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) { if let x = fraction(gesture) { parent.doubleTap(x) } }
        private func fraction(_ gesture: UIGestureRecognizer) -> CGFloat? {
            guard let view = gesture.view, view.bounds.width > 0 else { return nil }
            return gesture.location(in: view).x / view.bounds.width
        }
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
            // A second finger makes this a pinch rather than a page drag.
            guard pan.numberOfTouches <= 1 else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
    }
}
