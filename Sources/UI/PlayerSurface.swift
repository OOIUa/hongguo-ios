import AVKit
import Combine
import SwiftUI
import UIKit

/// One picture layer for the whole player screen. Episodes swap the layer's player instead of replacing the layer,
/// so 小窗播放 (picture in picture) keeps running when autoplay moves to the next episode.
@MainActor
final class PlayerSurface: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    let view = PlayerLayerHost()
    @Published private(set) var pipPossible = false
    @Published private(set) var pipActive = false
    /// Between the system's decision to start and the small window being up; leaving the app must not pause then.
    private(set) var pipStarting = false
    /// Called when the small window closes while the app is in the background (its × button).
    var closedInBackground: (() -> Void)?
    private var pip: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var playerSubscription: AnyCancellable?
    private weak var session: PlayerSession?

    override init() {
        super.init()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
    }

    var pipSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func bind(_ session: PlayerSession) {
        guard self.session !== session else { return }
        self.session = session
        playerSubscription = session.$player.sink { [weak self] player in self?.view.playerLayer.player = player }
        observations = [view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in guard let self, let session = self.session else { return }; session.firstFrame(ticket: session.playID) }
        }]
        guard pip == nil, pipSupported, let controller = AVPictureInPictureController(playerLayer: view.playerLayer) else { return }
        controller.delegate = self
        // Leaving the app while an episode plays continues it in the small window. Users can turn this off in
        // the system's 画中画 settings.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.pipPossible = possible }
        })
    }

    func unbind() {
        pip?.stopPictureInPicture()
        pip?.delegate = nil; pip = nil
        observations.removeAll(); playerSubscription = nil
        view.playerLayer.player = nil
        pipActive = false; pipStarting = false; pipPossible = false; session = nil
    }

    func startPictureInPicture() { pip?.startPictureInPicture() }
    func stopPictureInPicture() { pip?.stopPictureInPicture() }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.pipStarting = true }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.pipStarting = false; self.pipActive = true }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.pipStarting = false; self.pipActive = false }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipStarting = false; self.pipActive = false
            if UIApplication.shared.applicationState == .background { self.closedInBackground?() }
        }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen stays presented underneath, so there is nothing to rebuild.
        completionHandler(true)
    }
}

final class PlayerLayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// A layer of its own per player, for the home feed's previews.
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

struct PlayerSurfaceView: UIViewRepresentable {
    let surface: PlayerSurface
    func makeUIView(context: Context) -> PlayerLayerHost { surface.view }
    func updateUIView(_ uiView: PlayerLayerHost, context: Context) { }
}

/// The app follows the phone's rotation except while the player locks it: 全屏观看 holds landscape, and leaving
/// full screen holds portrait until the player closes.
@MainActor
enum InterfaceOrientationLock {
    static let free: UIInterfaceOrientationMask = .allButUpsideDown
    private(set) static var mask: UIInterfaceOrientationMask = free

    static func lock(_ mask: UIInterfaceOrientationMask, rotate: Bool) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller { current.setNeedsUpdateOfSupportedInterfaceOrientations(); controller = current.presentedViewController }
        }
        if rotate { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in } }
    }
}

final class HongguoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { InterfaceOrientationLock.mask }
    }
}
