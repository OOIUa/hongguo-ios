// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), danmaku/DanmakuView.kt — a lightweight rolling
// comment overlay drawn with Core Graphics instead of Android's Canvas. The playback position is
// the clock: a comment enters from the right edge when playback crosses its anchor and drifts left
// at a fixed speed, so pausing, seeking and playback-speed changes need no extra handling.
// Comments are assigned to the first track whose previous comment has fully entered; when every
// track is busy the comment is dropped, matching common danmaku behavior.
import UIKit

final class DanmakuView: UIView {
    private struct Active {
        var danmaku: Danmaku
        var text: String
        var width: CGFloat
        var track: Int
        /// When this comment crossed the right edge, in playback milliseconds.
        var anchorMs: Int64
    }

    private var active: [Active] = []
    private(set) var loader: DanmakuLoader?
    private var positionProvider: () -> Double = { 0 }
    private var needMore: (Double) -> Void = { _ in }
    private var lastPumpAt: TimeInterval = 0
    private var nextTrack = 0
    private var lastEmit: Double = -1
    private var running = false
    private var dirty = false
    private var pxPerMs: CGFloat = 0
    private var tracks = 1
    /// Height of one comment line in points; also the vertical pitch between tracks.
    private var lineHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1
    private var laidOutHeight: CGFloat = -1
    /// 用户设定的那一块高度（pt）。视图本身会多留约半行高度用于越界绘制，但算行数只认这块带子。
    private var bandHeight: CGFloat = 0
    /// Danmaku stay independent of the Dynamic Type size: 18 here means 18pt.
    private let baseTextSize: CGFloat = 18
    private let baseCrossMs: Double
    private var currentCrossMs: Double
    private var effect = DanmakuPrefs.effectDefault
    private let gap: CGFloat = 24
    private let displayLink: CADisplayLink
    private var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var outlineAttributes: [NSAttributedString.Key: Any] = [:]
    private var blocked: (String) -> Bool = { _ in false }  // 保持签名一致

    init(crossMs: Double = 9_000) {
        self.baseCrossMs = crossMs
        self.currentCrossMs = crossMs
        let link = CADisplayLink(target: self, selector: #selector(stepFrame))
        self.displayLink = link
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        applyPrefs(opacityPct: DanmakuPrefs.opacityDefault, font: DanmakuPrefs.fontDefault,
                   speed: DanmakuPrefs.speedDefault, effect: DanmakuPrefs.effectDefault)
        link.add(to: .main, forMode: .common)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError(" unsupported") }
    deinit { displayLink.invalidate() }

    /// Applies the user's rendering preferences. A font-size change keeps the comments already
    /// flying: their text is measured again at the new size, each one keeps its share of the
    /// crossing, and they are re-seated into tracks. Opacity and speed apply to what is already
    /// flying. The row count is never set from outside: relayout() derives it from the band height
    /// and the current font, so the coverage fraction chosen by the user translates into real rows.
    func applyPrefs(opacityPct: Int, font: Int, speed: Int, effect: Int) {
        let oldSize = (textAttributes[.font] as? UIFont)?.pointSize
        let alpha = CGFloat(DanmakuPrefs.opacity(opacityPct)) / 100
        let size = baseTextSize * CGFloat(DanmakuPrefs.fontScale(font))
        self.effect = DanmakuPrefs.effect(effect)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size),
            .foregroundColor: UIColor.white.withAlphaComponent(alpha),
        ]
        var outline: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size),
            .foregroundColor: UIColor.black.withAlphaComponent(alpha),
            .strokeWidth: max(1, size / 14) as NSNumber,
            .strokeColor: UIColor.black.withAlphaComponent(alpha),
        ]
        // 黑边 and 阴影 both need something behind the glyphs; the shadow carries its own colour, and
        // a 25% comment would turn into a grey blob under an opaque black blur. Both the shadow and
        // the outline therefore take the text's alpha as well. 白字 carries no blur at all.
        if self.effect == DanmakuPrefs.effectShadow {
            attributes[.shadow] = NSShadow().applying { shadow in
                shadow.shadowColor = UIColor.black.withAlphaComponent(alpha)
                shadow.shadowBlurRadius = size / 6
                shadow.shadowOffset = .zero
            }
        }
        textAttributes = attributes
        outlineAttributes = outline
        currentCrossMs = max(1, baseCrossMs * DanmakuPrefs.speedScale(speed))
        relayout()
        if let oldSize, oldSize != size {
            // 字号只是把字放大缩小，不该把正在飞的弹幕清空：按新字号重新量一遍宽度，
            // 保持各自跨屏进度不变，再重新分配轨道，实在排不下的那几条才丢掉。
            reseat(position: positionProvider(), remeasure: true)
        }
        setNeedsDisplay()
    }

    /// 重排屏上弹幕：可选按当前字号重新量宽度，然后按从右到左的顺序重新找轨道。
    private func reseat(position: Double, remeasure: Bool) {
        let carried = active
        active = []
        let resumed = carried.compactMap { item -> Active? in
            let progress = (position - Double(item.anchorMs)) / currentCrossMs
            guard progress >= 0, progress < 1 else { return nil }
            var next = item
            if remeasure { next.width = measuredWidth(of: item.text) }
            next.anchorMs = Int64((position - progress * currentCrossMs) * 1000)
            return next
        }.sorted { x($0, position) > x($1, position) }
        for item in resumed {
            let track = (0..<tracks).first { candidate in !active.contains { $0.track == candidate && overlaps($0, item, position: position) } }
            if let track { active.append(Active(danmaku: item.danmaku, text: item.text, width: item.width, track: track, anchorMs: item.anchorMs)) }
        }
        lastEmit = position
        dirty = true
    }

    private func measuredWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: textAttributes).width
    }

    private func relayout() {
        laidOutWidth = bounds.width
        laidOutHeight = bounds.height
        guard bounds.width > 0, bounds.height > 0, currentCrossMs > 0 else { return }
        pxPerMs = CGFloat(bounds.width / currentCrossMs)
        // 行距固定为字高的 1.12 倍，不随屏占比伸缩：行数按「带高 ÷ 行距」四舍五入得到，
        // 于是最后一行可能多顶出去半行，也比把行距拉宽塞满整块带更接近用户设定的比例。
        let font = (textAttributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: baseTextSize)
        let ink = max(1, font.lineHeight)
        lineHeight = ink * 1.12
        let band = bandHeight > 0 ? min(bandHeight, bounds.height) : bounds.height
        tracks = max(1, Int((band / lineHeight).rounded()))
    }

    /// 告知视图“用户选的那块带子有多高”，视图自身高度可以比它多一点用于越界绘制。
    func setBandHeight(_ px: CGFloat) {
        guard bandHeight != px else { return }
        bandHeight = px
        relayout()
        setNeedsDisplay()
    }

    /// position reports playback seconds; needMore is raised on the main thread about once a second
    /// while playback advances — the host should schedule DanmakuLoader.loadUpTo off-thread.
    func bind(loader: DanmakuLoader, position: @escaping () -> Double, needMore: @escaping (Double) -> Void = { _ in }) {
        unbind()
        self.loader = loader
        positionProvider = position
        self.needMore = needMore
        lastEmit = max(0, position())
        lastPumpAt = 0
        running = true
        isHidden = false
    }

    func setBlockedFilter(_ filter: @escaping (String) -> Bool) {
        blocked = filter
        active.removeAll { blocked($0.text) }
        dirty = true
        setNeedsDisplay()
    }

    func unbind() {
        running = false
        loader = nil
        needMore = { _ in }
        active = []
        lastEmit = -1
        isHidden = true
    }

    /// Playback jumped; comments on screen belong to the old position.
    func seekTo(positionSeconds: Double) {
        active = []
        lastEmit = max(0, positionSeconds)
        dirty = true
        setNeedsDisplay()
    }

    /// Orientation change (or any resize) keeps the comments already on screen: each one resumes
    /// at the same share of its crossing time in the new width, and is re-seated into a free track
    /// for the new height. Only comments that would overlap every track are dropped.
    override func layoutSubviews() {
        super.layoutSubviews()
        let carried = laidOutWidth > 0 && laidOutHeight > 0 ? active : []
        let position = carried.isEmpty ? 0 : positionProvider()
        relayout()
        active = []
        guard !carried.isEmpty else { return }
        let resumed = carried.compactMap { item -> Active? in
            let progress = (position - Double(item.anchorMs)) / currentCrossMs
            guard progress >= 0, progress < 1 else { return nil }
            var next = item
            next.anchorMs = Int64((position - progress * currentCrossMs) * 1000)
            return next
        }.sorted { x($0, position) > x($1, position) }
        for item in resumed {
            let track = (0..<tracks).first { candidate in !active.contains { $0.track == candidate && overlaps($0, item, position: position) } }
            if let track { active.append(Active(danmaku: item.danmaku, text: item.text, width: item.width, track: track, anchorMs: item.anchorMs)) }
        }
        lastEmit = position
        dirty = true
        setNeedsDisplay()
    }

    /// Two comments collide on a track when their text boxes (plus a gap) intersect.
    private func overlaps(_ first: Active, _ second: Active, position: Double) -> Bool {
        let firstLeft = x(first, position), secondLeft = x(second, position)
        return firstLeft < secondLeft + second.width + gap && secondLeft < firstLeft + first.width + gap
    }

    @objc private func stepFrame() {
        guard running else { return }
        step()
    }

    private func x(_ item: Active, _ position: Double) -> CGFloat {
        CGFloat(bounds.width) - CGFloat((position - Double(item.anchorMs)) * 1000) * pxPerMs
    }

    private func step() {
        guard loader != nil, bounds.width > 0 else { return }
        if bounds.width != laidOutWidth || bounds.height != laidOutHeight { relayout() }
        let position = max(0, positionProvider())
        if lastEmit < 0 { lastEmit = position }
        if position < lastEmit - Self.seekTolerance || position - lastEmit > Self.seekForward {
            active = []
            lastEmit = position
            dirty = true
        }
        if position > lastEmit {
            // between() takes milliseconds, like the Android port and the comment anchors.
            for comment in loader!.between(fromMs: Int64(lastEmit * 1000), toMs: Int64(position * 1000)) { emit(comment, position: position) }
            lastEmit = position
            dirty = true
        }
        let now = ProcessInfo.processInfo.systemUptime
        if position > 0, now - lastPumpAt > 1 {
            lastPumpAt = now
            needMore(position)
        }
        let before = active.count
        active.removeAll(where: { x($0, position) + $0.width < 0 })
        if active.count != before { dirty = true }
        if dirty { dirty = false; setNeedsDisplay() }
    }

    private func emit(_ comment: Danmaku, position: Double) {
        guard pxPerMs > 0, bounds.width > 0 else { return }
        if blocked(comment.text) { return }
        // Expand emoji codes once here: measure and draw must see the same text.
        let text = DanmakuEmoji.display(comment.text)
        let textWidth = measuredWidth(of: text)
        let widthF = CGFloat(bounds.width)
        // Round-robin instead of always top-down: with a sparse feed the comments then spread over
        // the whole coverage band, so 1/4 really looks like a quarter of the picture in use.
        for offset in 0..<tracks {
            let track = (nextTrack + offset) % tracks
            // The newest comment on this track is the one furthest right, not the one added last:
            // a rotation re-seats comments in on-screen order, so insertion order stops matching age.
            let newest = active.filter { $0.track == track }.max { x($0, position) < x($1, position) }
            if newest == nil || x(newest!, position) + newest!.width < widthF - gap {
                active.append(Active(danmaku: comment, text: text, width: textWidth, track: track, anchorMs: comment.offsetMs))
                nextTrack = (track + 1) % tracks
                return
            }
        }
        // Every track is busy; drop the comment rather than overlapping.
    }

    override func draw(_ rect: CGRect) {
        guard !active.isEmpty else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setAllowsAntialiasing(true)
        let position = max(0, positionProvider())
        let widthF = CGFloat(bounds.width)
        let font = (textAttributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: baseTextSize)
        let baseline = -font.ascender
        let stroked = effect == DanmakuPrefs.effectStroke
        for item in active {
            let left = x(item, position)
            if left > widthF || left + item.width < 0 { continue }
            let y = CGFloat(item.track) * lineHeight + baseline
            let origin = CGPoint(x: left, y: y)
            if stroked { drawOutline(item.text, origin: origin) }
            (item.text as NSString).draw(at: origin, withAttributes: textAttributes)
        }
    }

    /// 黑边 pass. Emoji are color bitmaps: a stroke attributes outlines glyph shapes, but Core Text
    /// blits the whole bitmap regardless, so stroking the same text would paint the emoji twice and
    /// make them far more opaque than the surrounding words. Only the non-emoji runs get the black
    /// edge; the emoji are left to the single fill pass.
    private func drawOutline(_ text: String, origin: CGPoint) {
        let nsText = text as NSString
        var from = text.startIndex
        for range in DanmakuEmoji.emojiRanges(in: text) {
            if from < range.lowerBound {
                let prefix = String(text[from..<range.lowerBound])
                nsText.draw(at: CGPoint(x: origin.x + measuredWidth(of: prefix), y: origin.y),
                            withAttributes: outlineAttributes)
            }
            from = range.upperBound
        }
        if from < text.endIndex {
            let prefix = String(text[from..<text.endIndex])
            nsText.draw(at: CGPoint(x: origin.x + measuredWidth(of: prefix), y: origin.y),
                        withAttributes: outlineAttributes)
        }
    }

    private static let seekTolerance: Double = 0.25
    private static let seekForward: Double = 1
}

private extension NSShadow {
    func applying(_ mutate: (NSShadow) -> Void) -> NSShadow {
        let copy = NSShadow(); mutate(copy); return copy
    }
}
