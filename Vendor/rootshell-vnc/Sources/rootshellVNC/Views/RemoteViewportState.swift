import CoreGraphics

public enum RemoteViewportPanningMode: CaseIterable, Hashable, Sendable {
    case edge
    case continuous
}

/// How the remote picture is framed when a connection opens.
public enum RemoteViewportSizing: Int, CaseIterable, Sendable, Codable {
    case fit = 0
    case fill = 1
    case actualSize = 2
}

/// Zoom/pan state shared by the lossless and adaptive renderers.
///
/// Gestures scale the selected framing and offset it from the center in view points. Keeping the transform here gives rendering and input conversion
/// one source of truth.
struct RemoteViewportState: Equatable, Sendable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 10
    static let edgeScrollActivationInset: CGFloat = 24
    static let maximumEdgeScrollSpeed: CGFloat = 2_400

    private(set) var sizing: RemoteViewportSizing = .fit
    var displayScale: CGFloat
    private(set) var scale: CGFloat = minimumScale
    private(set) var offset: CGSize = .zero

    init(sizing: RemoteViewportSizing = .fit, displayScale: CGFloat = 1) {
        self.sizing = sizing
        self.displayScale = displayScale
    }

    var isIdentity: Bool {
        sizing == .fit && scale == Self.minimumScale && offset == .zero
    }

    mutating func reset() {
        sizing = .fit
        scale = Self.minimumScale
        offset = .zero
    }

    mutating func zoom(
        by factor: CGFloat,
        around anchor: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) {
        guard factor.isFinite, factor > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }

        let oldScale = scale
        let framing = sizingScale(viewSize: viewSize, framebufferSize: framebufferSize)
        let minimum = min(Self.minimumScale, 1 / max(framing.width, framing.height))
        let newScale = min(Self.maximumScale, max(minimum, oldScale * factor))
        // Matching UIScrollView's minimum-zoom behavior, pinching inward at
        // the fitted scale restores the canonical centered viewport. This
        // also gives a panned-but-unzoomed desktop an immediate natural reset.
        if newScale == minimum, factor < 1 {
            if sizing == .fit || minimum < Self.minimumScale {
                reset()
            } else {
                scale = minimum
                offset = .zero
            }
            return
        }
        guard newScale != oldScale else { return }

        // Keep the remote pixel under the gesture centroid stationary.
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let ratio = newScale / oldScale
        offset = CGSize(
            width: anchor.x - center.x
                - (anchor.x - center.x - offset.width) * ratio,
            height: anchor.y - center.y
                - (anchor.y - center.y - offset.height) * ratio)
        scale = newScale
        clampOffset(viewSize: viewSize, framebufferSize: framebufferSize)
    }

    mutating func pan(
        by translation: CGSize,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) {
        offset.width += translation.width
        offset.height += translation.height
        clampOffset(viewSize: viewSize, framebufferSize: framebufferSize)
    }

    /// Returns the display translation for one frame of pointer edge
    /// scrolling. It uses the same generous overscroll limits as a two-finger
    /// pan, allowing the desktop edge to move as far as the viewport center.
    func edgeScrollTranslation(
        for pointerLocation: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        elapsedTime: Double
    ) -> CGSize {
        guard isMagnified(viewSize: viewSize, framebufferSize: framebufferSize),
              elapsedTime.isFinite, elapsedTime > 0,
              let frame = displayedFrame(
                viewSize: viewSize,
                framebufferSize: framebufferSize) else { return .zero }

        let horizontalVelocity = Self.edgeScrollVelocity(
            coordinate: pointerLocation.x,
            length: viewSize.width)
        let verticalVelocity = Self.edgeScrollVelocity(
            coordinate: pointerLocation.y,
            length: viewSize.height)
        return CGSize(
            width: Self.boundedEdgeTranslation(
                velocity: horizontalVelocity,
                elapsedTime: elapsedTime,
                leadingTravel: max(0, frame.width / 2 - offset.width),
                trailingTravel: max(0, frame.width / 2 + offset.width)),
            height: Self.boundedEdgeTranslation(
                velocity: verticalVelocity,
                elapsedTime: elapsedTime,
                leadingTravel: max(0, frame.height / 2 - offset.height),
                trailingTravel: max(0, frame.height / 2 + offset.height)))
    }

    /// Returns the translation that makes the visible desktop continuously
    /// follow the pointer. Pointer position is treated proportionally: a
    /// pointer one quarter across the viewport selects the corresponding
    /// quarter of the two-finger pan range, including its overscroll margins.
    func cursorFollowingTranslation(
        for pointerLocation: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGSize {
        guard isMagnified(viewSize: viewSize, framebufferSize: framebufferSize),
              let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return .zero }

        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let horizontalFraction = min(
            1, max(0, pointerLocation.x / viewSize.width))
        let verticalFraction = min(
            1, max(0, pointerLocation.y / viewSize.height))
        return CGSize(
            width: frame.width * (0.5 - horizontalFraction) - offset.width,
            height: frame.height * (0.5 - verticalFraction) - offset.height)
    }

    private static func edgeScrollVelocity(
        coordinate: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        guard coordinate.isFinite, length > 0 else { return 0 }
        let inset = min(edgeScrollActivationInset, length / 2)
        guard inset > 0 else { return 0 }
        if coordinate < inset {
            return maximumEdgeScrollSpeed
                * min(1, (inset - coordinate) / inset)
        }
        if coordinate > length - inset {
            return -maximumEdgeScrollSpeed
                * min(1, (coordinate - (length - inset)) / inset)
        }
        return 0
    }

    private static func boundedEdgeTranslation(
        velocity: CGFloat,
        elapsedTime: Double,
        leadingTravel: CGFloat,
        trailingTravel: CGFloat
    ) -> CGFloat {
        let proposed = velocity * CGFloat(elapsedTime)
        if proposed > 0 {
            return min(proposed, leadingTravel)
        }
        if proposed < 0 {
            return max(proposed, -trailingTravel)
        }
        return 0
    }

    mutating func clampOffset(viewSize: CGSize, framebufferSize: CGSize) {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize) else {
            offset = .zero
            return
        }

        // Keep the desktop from disappearing completely while allowing a
        // generous working margin around every edge. At the limit, the edge
        // being moved inward may reach the viewport center, but not cross it.
        let horizontalLimit = frame.width / 2
        let verticalLimit = frame.height / 2
        offset.width = min(horizontalLimit, max(-horizontalLimit, offset.width))
        offset.height = min(verticalLimit, max(-verticalLimit, offset.height))
    }

    func framebufferPoint(
        for viewPoint: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGPoint? {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize),
              frame.width > 0, frame.height > 0,
              frame.contains(viewPoint) else { return nil }

        let x = (viewPoint.x - frame.minX) / frame.width * framebufferSize.width
        let y = (viewPoint.y - frame.minY) / frame.height * framebufferSize.height
        guard x >= 0, y >= 0,
              x < framebufferSize.width,
              y < framebufferSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The nearest view point on the visible desktop, for a drag that has
    /// left it. Max edges are half-open, so they stay half a remote pixel in.
    func nearestVisibleViewPoint(
        to viewPoint: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGPoint? {
        guard viewPoint.x.isFinite, viewPoint.y.isFinite,
              let frame = displayedFrame(
                  viewSize: viewSize,
                  framebufferSize: framebufferSize) else { return nil }
        let visible = frame.intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let insetX = min(visible.width, frame.width / framebufferSize.width) / 2
        let insetY = min(visible.height, frame.height / framebufferSize.height) / 2
        return CGPoint(
            x: min(max(viewPoint.x, visible.minX), visible.maxX - insetX),
            y: min(max(viewPoint.y, visible.minY), visible.maxY - insetY))
    }

    /// Inverse of `framebufferPoint(for:viewSize:framebufferSize:)`.
    ///
    /// Deliberately does not require the result to be on screen: a virtual
    /// cursor may sit outside the visible bounds after a pinch, and the
    /// caller needs to know where it went in order to bring it back.
    func viewPoint(
        forFramebufferPoint point: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGPoint? {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize),
              framebufferSize.width > 0, framebufferSize.height > 0,
              point.x.isFinite, point.y.isFinite else { return nil }

        return CGPoint(
            x: frame.minX + point.x / framebufferSize.width * frame.width,
            y: frame.minY + point.y / framebufferSize.height * frame.height)
    }

    /// How many framebuffer pixels one view point covers at the current zoom,
    /// the conversion factor relative pointer motion needs to stay tied to
    /// finger travel on glass.
    func framebufferPixelsPerPoint(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGFloat? {
        guard let frame = displayedFrame(
            viewSize: viewSize,
            framebufferSize: framebufferSize),
              frame.width > 0 else { return nil }
        return framebufferSize.width / frame.width
    }

    /// Returns the translation, ready to hand to `pan(by:)`, that brings
    /// `viewPoint` back inside the view bounds inset by `inset`.
    ///
    /// The desktop moves opposite to the overshoot, which drags the point
    /// that rides on it into view. The result is measured after clamping on a
    /// copy rather than derived from the raw overshoot, so a caller that pans
    /// by it gets exactly the movement it was promised even at the pan limits
    /// and can trust the value when deciding whether the viewport moved.
    func translationToReveal(
        viewPoint: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        inset: CGFloat
    ) -> CGSize {
        translationToReveal(
            viewPoint: viewPoint,
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            horizontalInset: inset,
            verticalInset: inset)
    }

    /// Per-axis variant, for callers that keep the point inside a rectangle
    /// rather than away from an edge. A viewport is far wider than it is tall
    /// in landscape, so one inset in points would carve out very different
    /// margins on the two axes.
    ///
    /// Same post-clamp contract as the single-inset form: the returned
    /// translation is what `pan(by:)` will actually apply.
    func translationToReveal(
        viewPoint: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        horizontalInset: CGFloat,
        verticalInset: CGFloat
    ) -> CGSize {
        guard isMagnified(viewSize: viewSize, framebufferSize: framebufferSize),
              viewPoint.x.isFinite, viewPoint.y.isFinite,
              horizontalInset.isFinite, verticalInset.isFinite,
              displayedFrame(
                viewSize: viewSize,
                framebufferSize: framebufferSize) != nil else { return .zero }

        // An inset wider than half the viewport would invert the rectangle
        // and turn "bring inside" into a jump to the far edge; capping it
        // degenerates to aiming at the center line instead.
        let bounds = CGRect(origin: .zero, size: viewSize).insetBy(
            dx: min(max(0, horizontalInset), viewSize.width / 2),
            dy: min(max(0, verticalInset), viewSize.height / 2))
        let requested = CGSize(
            width: min(max(viewPoint.x, bounds.minX), bounds.maxX)
                - viewPoint.x,
            height: min(max(viewPoint.y, bounds.minY), bounds.maxY)
                - viewPoint.y)
        guard requested != .zero else { return .zero }

        var revealed = self
        revealed.pan(
            by: requested,
            viewSize: viewSize,
            framebufferSize: framebufferSize)
        return CGSize(
            width: revealed.offset.width - offset.width,
            height: revealed.offset.height - offset.height)
    }

    /// Match Client sizes land on an 8-point codec grid, so a near-match is
    /// stretched to fill the view rather than letterboxed by a few points.
    static let fillAspectTolerance: CGFloat = 0.02

    /// Per-axis scale that aspect-fits `content`, or fills `view` exactly
    /// when the aspect ratios differ by at most `fillAspectTolerance`.
    static func fitScale(content: CGSize, into view: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0,
              view.width > 0, view.height > 0 else { return CGSize(width: 1, height: 1) }
        let scaleX = view.width / content.width
        let scaleY = view.height / content.height
        if abs(scaleX / scaleY - 1) <= fillAspectTolerance {
            return CGSize(width: scaleX, height: scaleY)
        }
        let fit = min(scaleX, scaleY)
        return CGSize(width: fit, height: fit)
    }

    /// Both the rendered picture and input conversion start with the same fitted canvas.
    func renderScale(viewSize: CGSize, framebufferSize: CGSize) -> CGSize {
        let framing = sizingScale(viewSize: viewSize, framebufferSize: framebufferSize)
        return CGSize(width: framing.width * scale, height: framing.height * scale)
    }

    private func isMagnified(viewSize: CGSize, framebufferSize: CGSize) -> Bool {
        let transform = renderScale(viewSize: viewSize, framebufferSize: framebufferSize)
        return max(transform.width, transform.height) > Self.minimumScale
    }

    private func sizingScale(viewSize: CGSize, framebufferSize: CGSize) -> CGSize {
        guard sizing != .fit, viewSize.width > 0, viewSize.height > 0,
              framebufferSize.width > 0, framebufferSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let fit = Self.fitScale(content: framebufferSize, into: viewSize)
        let uniform: CGFloat
        switch sizing {
        case .fit: return CGSize(width: 1, height: 1)
        case .fill:
            uniform = max(viewSize.width / framebufferSize.width,
                          viewSize.height / framebufferSize.height)
        case .actualSize:
            uniform = 1 / max(1, displayScale)
        }
        return CGSize(width: uniform / fit.width, height: uniform / fit.height)
    }

    func displayedFrame(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0,
              framebufferSize.width > 0, framebufferSize.height > 0 else {
            return nil
        }

        let fit = Self.fitScale(content: framebufferSize, into: viewSize)
        let transform = renderScale(viewSize: viewSize, framebufferSize: framebufferSize)
        let size = CGSize(
            width: framebufferSize.width * fit.width * transform.width,
            height: framebufferSize.height * fit.height * transform.height)
        return CGRect(
            x: (viewSize.width - size.width) / 2 + offset.width,
            y: (viewSize.height - size.height) / 2 + offset.height,
            width: size.width,
            height: size.height)
    }
}
