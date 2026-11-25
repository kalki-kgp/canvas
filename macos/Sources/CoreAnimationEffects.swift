import AppKit
import QuartzCore
import SwiftUI

// Looping "Claude is working" effects driven by Core Animation. Once added,
// the animations run in the window server, so the app does no work per frame
// (SwiftUI TimelineViews re-render the view on the CPU for every frame).

/// A layer-hosting view whose content sits in `root`, a sublayer that always
/// fills the bounds; macOS backing layers anchor at their corner, and
/// sublayers keep their animations when the view resizes.
class EffectLayerView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        layoutEffect()
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Sublayer layout; called inside a transaction with actions disabled.
    func layoutEffect() {}

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }
}

// MARK: Claude mark

/// The Claude mark turning in eased 45° steps with a soft pulse.
struct SpinningMark: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> SpinningMarkView { SpinningMarkView() }
    func updateNSView(_ view: SpinningMarkView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinningMarkView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class SpinningMarkView: EffectLayerView {
    private let mark = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.contentsGravity = .resizeAspect
        root.addSublayer(mark)

        // one eased 45° step per beat (0.7 s), adding up forever
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.byValue = -Double.pi / 4  // negative is clockwise in AppKit's y-up layers
        turn.duration = 0.7
        turn.isCumulative = true
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        mark.add(turn, forKey: "turn")

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1
        pulse.toValue = 0.86
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mark.add(pulse, forKey: "pulse")
    }

    override func layoutEffect() {
        mark.bounds = root.bounds
        mark.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        mark.contentsScale = scale
        if mark.contents == nil || (mark.value(forKey: "renderedScale") as? CGFloat) != scale {
            mark.contents = Self.orangeMark(side: max(root.bounds.width, 1), scale: scale)
            mark.setValue(scale, forKey: "renderedScale")
        }
    }

    /// The template mark filled with Claude's orange, as a bitmap.
    static func orangeMark(side: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int((side * scale).rounded(.up))
        guard px > 0, let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px)
        var proposed = rect
        guard let template = ClaudeMark.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        ctx.clip(to: rect, mask: template)
        ctx.setFillColor(NSColor(ClaudeMark.orange).cgColor)
        ctx.fill(rect)
        return ctx.makeImage()
    }
}

// MARK: Shimmer

/// Text with a light band sweeping across it.
struct ShimmerLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 12.5, weight: .medium)

    func makeNSView(context: Context) -> ShimmerLabelView { ShimmerLabelView() }

    func updateNSView(_ view: ShimmerLabelView, context: Context) {
        view.set(text: text, font: font)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerLabelView, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: min(natural.width, proposal.width ?? .infinity), height: natural.height)
    }
}

final class ShimmerLabelView: EffectLayerView {
    private let base = NSTextField(labelWithString: "")
    private let bright = NSTextField(labelWithString: "")
    private let band = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [base, bright] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        base.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        bright.textColor = .labelColor
        bright.wantsLayer = true

        // the bright copy shows only through a band that slides across
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        band.locations = [0, 0.5, 1]
    }

    func set(text: String, font: NSFont) {
        guard base.stringValue != text || base.font != font else { return }
        for label in [base, bright] {
            label.stringValue = text
            label.font = font
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize { base.intrinsicContentSize }

    override func layoutEffect() {
        guard let layer = bright.layer else { return }
        let width = max(bounds.width, 1)
        let bandWidth = max(width * 0.42, 40)
        band.frame = CGRect(x: 0, y: 0, width: bandWidth, height: layer.bounds.height)
        layer.mask = band

        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bandWidth / 2
        sweep.toValue = width + bandWidth / 2
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        band.position = CGPoint(x: -bandWidth / 2, y: layer.bounds.midY)
        band.add(sweep, forKey: "sweep")
    }
}

// MARK: Glow

/// A soft orange light running around a rounded rectangle.
struct RunningGlow: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> RunningGlowView { RunningGlowView(cornerRadius: cornerRadius) }
    func updateNSView(_ view: RunningGlowView, context: Context) {}
}

final class RunningGlowView: EffectLayerView {
    private let cornerRadius: CGFloat
    private let sharp = CAGradientLayer()
    private let soft = CAGradientLayer()
    private let sharpMask = CAShapeLayer()
    private let softMask = CALayer()
    private var maskedSize = CGSize.zero
    /// how far the soft light spills past the edge
    private let spill: CGFloat = 14

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        let orange = NSColor(ClaudeMark.orange)
        for gradient in [sharp, soft] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.colors = [orange.withAlphaComponent(0).cgColor, orange.cgColor,
                               orange.withAlphaComponent(0).cgColor, orange.withAlphaComponent(0).cgColor]
            gradient.locations = [0, 0.25, 0.5, 1]

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 2.4
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
        let sharpHolder = CALayer()
        sharpHolder.addSublayer(sharp)
        sharpHolder.mask = sharpMask
        let softHolder = CALayer()
        softHolder.addSublayer(soft)
        softHolder.mask = softMask
        softHolder.opacity = 0.6
        root.addSublayer(softHolder)
        root.addSublayer(sharpHolder)
        sharpMask.fillColor = nil
        sharpMask.strokeColor = NSColor.black.cgColor
        sharpMask.lineWidth = 1.5
    }

    override func layoutEffect() {
        let rect = root.bounds
        guard rect.width > 0, rect.height > 0 else { return }
        let outer = rect.insetBy(dx: -spill, dy: -spill)
        let side = hypot(outer.width, outer.height)
        for gradient in [sharp, soft] {
            gradient.superlayer?.frame = outer
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: outer.width / 2, y: outer.height / 2)
        }
        let local = rect.offsetBy(dx: spill, dy: spill)
        sharpMask.frame = CGRect(origin: .zero, size: outer.size)
        sharpMask.path = CGPath(
            roundedRect: local.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: cornerRadius - 0.75, cornerHeight: cornerRadius - 0.75, transform: nil)

        // the soft ring is a blurred stroke, rendered once per size
        if maskedSize != rect.size || softMask.contentsScale != scale {
            maskedSize = rect.size
            softMask.frame = CGRect(origin: .zero, size: outer.size)
            softMask.contentsScale = scale
            softMask.contents = Self.blurredRing(size: outer.size, ring: local, radius: cornerRadius, scale: scale)
        }
    }

    private static func blurredRing(size: CGSize, ring: CGRect, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(4)
        ctx.addPath(CGPath(roundedRect: ring.insetBy(dx: 2, dy: 2),
                           cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
        ctx.strokePath()
        guard let stroke = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: stroke)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 6 * scale / 2).cropped(to: input.extent)
        return CIContext().createCGImage(blurred, from: input.extent)
    }
}
