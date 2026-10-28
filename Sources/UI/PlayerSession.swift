import Foundation
import AVFoundation
import Combine

@MainActor
final class PlayerSession: ObservableObject {
    let detail: DramaDetail
    let app: AppModel
    let recordsLocalHistory: Bool
    @Published private(set) var index: Int
    @Published private(set) var playID = UUID()
    @Published private(set) var player: AVPlayer?
    @Published private(set) var preparing = false
    @Published private(set) var stage = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var buffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rendered = false
    @Published private(set) var holding = false
    @Published private(set) var endMessage: String?
    private var finished = false
    @Published var scrubbing = false
    @Published var previewPosition: Double = 0
    private var requestTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var warmURL: URL?
    private var warmEpisodeID: String?
    private var currentURL: URL?
    private var currentStream: ProgressivePlayback?
    private var periodic: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var prefetchStarted = false
    private var stopped = false
    private var lastSave = Date.distantPast
    private let initialPosition: Double
    private let accountToken: UUID
    var episode: Episode { detail.episodes[index] }

    init(request: PlaybackRequest, app: AppModel) {
        detail = request.detail; index = request.index; initialPosition = request.position
        recordsLocalHistory = request.recordsLocalHistory; self.app = app
        accountToken = AccountService.shared.playbackToken
    }

    func start() { stopped = false; load(index: index, startAt: initialPosition) }

    func load(index target: Int, startAt: Double? = nil) {
        guard detail.episodes.indices.contains(target), !stopped else { return }
        saveProgress(flush: true)
        requestTask?.cancel()
        let nextEpisode = detail.episodes[target]
        let prepared = warmEpisodeID == nextEpisode.id ? warmURL : nil
        if prepared != nil { warmURL = nil; warmEpisodeID = nil }
        cancelWarm()
        releasePlayer()
        index = target; playID = UUID()
        let ticket = playID
        let saved = startAt ?? (recordsLocalHistory ? app.library.progress(for: detail.drama.id).flatMap { $0.episodeID == nextEpisode.id ? $0.position : nil } : nil) ?? 0
        position = saved; duration = 0; previewPosition = saved
        preparing = true; stage = "正在获取播放地址"; progress = 0; error = nil
        rendered = false; endMessage = nil; holding = false; scrubbing = false; prefetchStarted = false; finished = false
        requestTask = Task { [weak self] in
            do {
                let item: AVPlayerItem
                if let prepared {
                    guard let self, self.playID == ticket, !self.stopped else { await MediaPreparer.shared.unpin(prepared); return }
                    self.currentURL = prepared; self.progress = 1
                    item = AVPlayerItem(url: prepared)
                }
                else {
                    let track = try await DramaAPI.shared.track(episodeID: nextEpisode.id)
                    try Task.checkCancellation()
                    if let url = try await MediaPreparer.shared.cachedPlayback(track: track, episodeID: nextEpisode.id) {
                        await MediaPreparer.shared.pin(url)
                        guard let self, self.playID == ticket, !self.stopped, !Task.isCancelled else { await MediaPreparer.shared.unpin(url); return }
                        self.currentURL = url; self.progress = 1
                        item = AVPlayerItem(url: url)
                    } else {
                        let stream = try await ProgressivePlayback.open(track: track, episodeID: nextEpisode.id) { [weak self] name, fraction in
                            Task { @MainActor in guard let self, self.playID == ticket, !self.stopped else { return }; self.stage = name; self.progress = fraction.isFinite ? min(max(fraction, 0), 1) : 0 }
                        }
                        guard let self, self.playID == ticket, !self.stopped, !Task.isCancelled else { stream.close(); return }
                        self.currentStream = stream
                        item = AVPlayerItem(asset: stream.asset)
                        item.preferredForwardBufferDuration = 3
                    }
                }
                guard let self, self.playID == ticket, !self.stopped, !Task.isCancelled else { return }
                self.install(item: item, startAt: saved, ticket: ticket)
            } catch is CancellationError { if let prepared { await MediaPreparer.shared.unpin(prepared) } }
            catch {
                guard let self, self.playID == ticket, !self.stopped else { return }
                self.preparing = false; self.error = friendlyError(error); self.stage = "准备失败"
            }
        }
    }

    private func install(item: AVPlayerItem, startAt: Double, ticket: UUID) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let next = AVPlayer(playerItem: item)
        next.automaticallyWaitsToMinimizeStalling = currentStream == nil
        player = next; preparing = false; buffering = true
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.playID == ticket else { return }
                if item.status == .failed { self.error = "视频播放失败，请重试或选择其他集。"; self.buffering = false; self.isPlaying = false }
                let length = item.duration.seconds
                if length.isFinite && length > 0 { self.duration = length }
            }
        })
        observations.append(next.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in guard let self, self.playID == ticket else { return }; self.isPlaying = player.timeControlStatus == .playing; self.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate; if !self.isPlaying { self.endHold() } }
        })
        periodic = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.playID == ticket else { return }
                let now = time.seconds
                if now.isFinite { self.position = max(0, now) }
                let total = self.player?.currentItem?.duration.seconds ?? 0
                if total.isFinite && total > 0 { self.duration = total }
                if Date().timeIntervalSince(self.lastSave) > 5 { self.saveProgress() }
                self.prefetchIfReady()
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playID == ticket else { return }; self.ended() } })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.playID == ticket else { return }; self.error = "视频播放中断，请重试或选择其他集。"; self.pause() } })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause(); self?.saveProgress(flush: true) } })
        let position = CMTime(seconds: max(0, startAt), preferredTimescale: 600)
        next.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in guard let self, self.playID == ticket, !self.stopped else { return }; self.player?.playImmediately(atRate: self.app.speed) }
        }
    }

    func firstFrame(ticket: UUID) {
        guard ticket == playID, !rendered, let player, !stopped else { return }
        rendered = true; buffering = false
        if recordsLocalHistory {
            let value = player.currentTime().seconds
            app.library.record(drama: detail.drama, episode: episode, position: value.isFinite ? max(0, value) : position)
            app.library.flush()
        }
    }

    func toggle() { if finished { load(index: index, startAt: 0) } else if isPlaying || (player?.rate ?? 0) > 0 { pause() } else { endHold(); endMessage = nil; currentStream?.resume(); player?.playImmediately(atRate: app.speed) } }
    func pause() { endHold(); player?.pause(); currentStream?.pause(); isPlaying = false; saveProgress(flush: true) }
    func setSpeed(_ speed: Float) { app.speed = speed; holding = false; if isPlaying { player?.rate = speed } }
    func beginHold() { guard isPlaying, rendered, !scrubbing else { return }; holding = true; player?.rate = 2 }
    func endHold() { guard holding else { return }; holding = false; if (player?.rate ?? 0) > 0 { player?.rate = app.speed } }
    func setSeeking(_ editing: Bool) {
        endHold()
        if editing { previewPosition = position; scrubbing = true }
        else { scrubbing = false; finished = false; endMessage = nil; player?.seek(to: CMTime(seconds: max(0, previewPosition), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); position = previewPosition; saveProgress() }
    }
    func next() { guard index + 1 < detail.episodes.count else { endMessage = "已到最后一集"; return }; load(index: index + 1, startAt: 0) }
    func previous() { guard index > 0 else { endMessage = "已经是第一集"; return }; load(index: index - 1, startAt: 0) }
    func retry() { load(index: index, startAt: position) }
    func suspend() {
        pause(); saveProgress(flush: true); cancelWarm()
        if preparing { requestTask?.cancel(); playID = UUID(); preparing = false; error = "播放准备已暂停，回到前台后可重试。" }
    }
    func preferencesChanged() { if !app.preloadNext { cancelWarm(); prefetchStarted = false } }

    private func ended() {
        if rendered { AccountService.shared.observePlayback(drama: detail.drama, episode: episode, position: duration, duration: duration, token: accountToken, force: true) }
        endHold(); isPlaying = false; position = 0; finished = true
        if recordsLocalHistory { app.library.updatePosition(dramaID: detail.drama.id, episodeID: episode.id, position: 0); app.library.flush() }
        if index + 1 < detail.episodes.count { if app.autoNext { next() } else { endMessage = "本集已播完，上滑观看下一集" } }
        else { endMessage = "已播完最后一集" }
    }

    private func prefetchIfReady() {
        guard app.preloadNext, rendered, isPlaying, !prefetchStarted, index + 1 < detail.episodes.count,
              currentStream == nil || progress >= 0.999 else { return }
        prefetchStarted = true
        let next = detail.episodes[index + 1], ticket = playID
        warmTask = Task { [weak self] in
            do {
                let track = try await DramaAPI.shared.track(episodeID: next.id)
                try Task.checkCancellation()
                let url = try await MediaPreparer.shared.prepare(track: track, episodeID: next.id) { _, _ in }
                try Task.checkCancellation()
                await MediaPreparer.shared.pin(url)
                guard let self, self.playID == ticket, !self.stopped, !Task.isCancelled, self.app.preloadNext else { await MediaPreparer.shared.unpin(url); return }
                self.warmURL = url; self.warmEpisodeID = next.id
            } catch { }
        }
    }

    private func cancelWarm() { warmTask?.cancel(); warmTask = nil; if let url = warmURL { Task { await MediaPreparer.shared.unpin(url) } }; warmURL = nil; warmEpisodeID = nil }

    private func saveProgress(flush: Bool = false) {
        guard rendered, !finished else { return }
        let value = player?.currentTime().seconds ?? position
        let current = value.isFinite ? max(0, value) : position
        if recordsLocalHistory {
            app.library.updatePosition(dramaID: detail.drama.id, episodeID: episode.id, position: current)
            if flush { app.library.flush() }
        }
        AccountService.shared.observePlayback(drama: detail.drama, episode: episode, position: current, duration: duration, token: accountToken, force: flush)
        lastSave = Date()
    }

    private func releasePlayer() {
        endHold(); player?.pause()
        if let periodic, let player { player.removeTimeObserver(periodic) }; periodic = nil
        observations.removeAll(); notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        player?.replaceCurrentItem(with: nil); player = nil; isPlaying = false; buffering = false
        currentStream?.close(); currentStream = nil
        if let url = currentURL { Task { await MediaPreparer.shared.unpin(url) } }; currentURL = nil
    }

    func stop() { guard !stopped else { return }; saveProgress(flush: true); stopped = true; requestTask?.cancel(); requestTask = nil; cancelWarm(); playID = UUID(); releasePlayer(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
}
