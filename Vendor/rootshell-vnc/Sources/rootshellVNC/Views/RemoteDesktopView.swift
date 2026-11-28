import SwiftUI
import RFBProtocol
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct DockedKeyboardViewportMetrics: Equatable {
    var containerSize: CGSize = .zero
    var keyboardInset: CGFloat = 0

    func effectiveInset(reservingObstruction: Bool) -> CGFloat {
        reservingObstruction ? keyboardInset : 0
    }

    func availableSize(reservingObstruction: Bool) -> CGSize {
        let effectiveInset = effectiveInset(
            reservingObstruction: reservingObstruction)
        return CGSize(
            width: containerSize.width,
            height: max(0, containerSize.height - effectiveInset))
    }

    func isApproximatelyEqual(
        to other: DockedKeyboardViewportMetrics
    ) -> Bool {
        abs(containerSize.width - other.containerSize.width) <= 0.5
            && abs(containerSize.height - other.containerSize.height) <= 0.5
            && abs(keyboardInset - other.keyboardInset) <= 0.5
    }

    /// The size Match Client fills, above a docked HUD bar. A non-nil
    /// `layoutSize` wins over this reader, which can miss a Mac Catalyst
    /// window resize.
    func matchClientSize(
        layoutSize: CGSize?,
        hudReserve: CGFloat,
        avoidanceMode: VNCKeyboardAvoidanceMode,
        reservingObstruction: Bool
    ) -> CGSize? {
        let size = layoutSize ?? (avoidanceMode == .automatic
            ? availableSize(reservingObstruction: reservingObstruction)
            : containerSize)
        guard size.width > 0, size.height > hudReserve else { return nil }
        return CGSize(width: size.width, height: size.height - hudReserve)
    }
}

/// Chooses which layer owns keyboard and accessory clearance for the remote
/// viewport. Container apps with a shared pane layout can opt out of the
/// package spacer while the standalone view keeps automatic avoidance.
public enum VNCKeyboardAvoidanceMode: Equatable, Sendable {
    case automatic
    case hostManaged
}

/// Displays the remote desktop and provides one input/viewport layer for both
/// Adaptive video and Full Quality framebuffer rendering.
public struct RemoteDesktopView: View {
    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var localViewport: RemoteViewportState
    @State private var localViewportPanningMode: RemoteViewportPanningMode
    private var hostViewport: Binding<RemoteViewportState>?
    private var hostViewportPanningMode: Binding<RemoteViewportPanningMode>?
    private var viewportSelection: Binding<RemoteViewportState> { hostViewport ?? $localViewport }
    private var viewportPanningSelection: Binding<RemoteViewportPanningMode> {
        hostViewportPanningMode ?? $localViewportPanningMode
    }
    private var viewport: RemoteViewportState {
        get { viewportSelection.wrappedValue }
        nonmutating set { viewportSelection.wrappedValue = newValue }
    }
    /// Height at the bottom that a docked HUD bar keeps clear of the fitted screen.
    @State private var hudReserve: CGFloat = 0
    @State private var localPointerMode: RemotePointerMode
    private var hostPointerSelection: Binding<RemotePointerMode>?
    private var pointerModeSelection: Binding<RemotePointerMode> { hostPointerSelection ?? $localPointerMode }
    @State private var keyboardActive = false
    @State private var confirmPasswordSend = false
    @State private var confirmPasswordOnly = false
    @State private var curtainPromptPresented = false
    @State private var keyboardCapture: VNCKeyboardCapture
    #if canImport(UIKit)
    @State private var keyboardViewportMetrics = DockedKeyboardViewportMetrics()
    @State private var hardwareKeyboardAttached = false
    @State private var showsFileTransfers = false
    @State private var hudFrame = HUDFrameModel()
    #endif
    #if targetEnvironment(macCatalyst)
    /// A Mac window has no docked software keyboard, so the laid-out size is
    /// the viewport.
    @State private var catalystLayoutSize: CGSize?
    #endif

    #if !canImport(UIKit)
    @State private var lastFallbackMagnification: CGFloat = 1
    @State private var fallbackDragRemotePoint: CGPoint?
    #endif

    private let touchHandler: TouchInputHandler
    let keyboardHandler: KeyboardInputHandler
    private let isFullScreen: Bool
    private let toggleFullScreen: (() -> Void)?
    private let hudMenuExtras: VNCHUDMenuExtras
    private var screenPlaceholder: AnyView?
    /// The host shows the HUD's items in its own menu (the Mac menu bar). Off by default.
    private var hidesHUD = false
    private var pencilToolbarAction: ((RemotePencilAction, CGPoint) -> Void)?
    private var desktopControls: VNCDesktopControls?
    private var hostPointerMode: RemotePointerMode?
    private var hostSuspendsKeyboardCapture = false
    #if canImport(UIKit)
    private var hudAccessory: HUDAccessory?
    private var customHUD: ((AnyView, CGSize) -> AnyView)?
    private var leadingDock: LeadingHUD?

    private struct LeadingHUD {
        let style: VNCHUDButtonStyle
        let content: (AnyView, CGFloat) -> AnyView
    }
    #endif
    private var keyboardAvoidanceMode: VNCKeyboardAvoidanceMode
    /// Edges whose safe area the HUD keeps clear of. A host that covers a
    /// system region (a full-screen takeover over a side rail) drops its edge.
    private let hudSafeAreaEdges: Edge.Set
    private let clipboardSynchronizer: VNCClipboardSynchronizer?
    private let onSharedClipboardUserChange: (@MainActor (Bool) -> Void)?
    private let hostOwnsRecoveryChrome: Bool
    private let brightnessGain: Double
    private let pointerSpeed: Double
    /// On-screen height of the locally drawn pointer, in view points. The
    /// host owns this because only it knows the display the desktop is being
    /// viewed on and what the user asked for.
    private let cursorHeight: CGFloat
    private let touchGestures: RemoteTouchGestureConfiguration
    private var monitorShortcut: ((VNCMonitorSelection) -> Void)?
    private var screenshotShortcut: (() -> Void)?
    private var windowMonitorRegion: CGRect?
    private var hostDictation: (() -> Void)?

    #if canImport(UIKit)
    /// A host-provided accessory can remain visible without the software
    /// keyboard, so it must keep its measured clearance. When neither is
    /// active, any nonzero layout-guide value is stale and must be ignored.
    private var shouldReserveKeyboardInset: Bool {
        keyboardActive || keyboardCapture.inputViews.accessory != nil
    }
    #endif

    /// `hudMenuExtras` adds the host's own items to the HUD menu.
    public init(
        session: VNCSession,
        keyboardCapture: VNCKeyboardCapture? = nil,
        isFullScreen: Bool = false,
        toggleFullScreen: (() -> Void)? = nil,
        keyboardAvoidanceMode: VNCKeyboardAvoidanceMode = .automatic,
        hudSafeAreaEdges: Edge.Set = .all,
        clipboardSynchronizer: VNCClipboardSynchronizer? = nil,
        initialViewportPanningMode: RemoteViewportPanningMode = .edge,
        initialViewportSizing: RemoteViewportSizing = .fit,
        initialPointerMode: RemotePointerMode = .direct,
        pointerSpeed: Double = 1.0,
        cursorHeight: CGFloat = 17,
        touchGestures: RemoteTouchGestureConfiguration = .standard,
        onRemoteInput: (@MainActor () -> Void)? = nil,
        onSharedClipboardUserChange: (@MainActor (Bool) -> Void)? = nil,
        hostOwnsRecoveryChrome: Bool = false,
        brightnessGain: Double = 1.0,
        hudMenuExtras: VNCHUDMenuExtras = VNCHUDMenuExtras()
    ) {
        self.session = session
        self.hostOwnsRecoveryChrome = hostOwnsRecoveryChrome
        self.hudMenuExtras = hudMenuExtras
        self._localViewport = State(initialValue: RemoteViewportState(sizing: initialViewportSizing))
        self._localViewportPanningMode = State(initialValue: initialViewportPanningMode)
        self._localPointerMode = State(initialValue: initialPointerMode)
        self.pointerSpeed = pointerSpeed
        self.cursorHeight = cursorHeight
        self.touchGestures = touchGestures
        self._keyboardCapture = State(
            initialValue: keyboardCapture ?? VNCKeyboardCapture())
        self.isFullScreen = isFullScreen
        self.toggleFullScreen = toggleFullScreen
        self.keyboardAvoidanceMode = keyboardAvoidanceMode
        self.hudSafeAreaEdges = hudSafeAreaEdges
        self.clipboardSynchronizer = clipboardSynchronizer
        self.onSharedClipboardUserChange = onSharedClipboardUserChange
        self.brightnessGain = brightnessGain
        self.touchHandler = TouchInputHandler(
            sendPointerEvent: { [session] buttonMask, x, y in
                onRemoteInput?()
                session.sendPointerEvent(buttonMask: buttonMask, x: x, y: y)
            },
            sendScrollEvent: { [session] event in
                onRemoteInput?()
                session.sendScrollEvent(event)
            },
            sendGestureEvent: { [session] event in
                onRemoteInput?()
                session.sendGestureEvent(event)
            })
        self.keyboardHandler = KeyboardInputHandler(
            sendKeyEvent: { [session] downFlag, key in
                if downFlag { onRemoteInput?() }
                session.sendKeyEvent(downFlag: downFlag, key: key)
            },
            usesAppleModifierConvention: { [session] in
                session.serverUsesAppleModifierConvention
            },
            sendPhysicalKeyEvent: { [session] down, usage, keysym in
                if down { onRemoteInput?() }
                session.sendKeyEvent(downFlag: down, key: keysym,
                                     macKeyCode: session.macKeyCode(forHardwareUsage: usage, useKeystrokes: true))
            },
            physicalKeySupported: { [session] in session.macKeyCode(forHardwareUsage: $0) != nil },
            optionPhysicalKeySupported: { [session] in
                !session.configuration.usesLegacyHardwareKeyboardMapping
                    && session.macKeyCode(forHardwareUsage: $0, useKeystrokes: true) != nil
            },
            usesLegacyHardwareMapping: { [session] in session.configuration.usesLegacyHardwareKeyboardMapping },
            usesLegacySoftwareMapping: { [session] in session.configuration.usesLegacySoftwareKeyboardMapping })
    }

    /// Reads the server's reported state, never a local optimistic one, so the
    /// switch cannot claim the remote screen is hidden when it isn't. Turning it
    /// on opens the message prompt first; turning it off is immediate, matching
    /// Apple's client.
    private var curtainBinding: Binding<Bool> {
        Binding(
            get: { session.isCurtained },
            set: { enabled in
                if enabled {
                    curtainPromptPresented = true
                } else {
                    session.setCurtainMode(false)
                }
            })
    }

    /// Keeps the viewport with its host when replacing the desktop renderer.
    public func controllingViewport(_ viewport: Binding<RemoteViewportState>,
                                    panningMode: Binding<RemoteViewportPanningMode>? = nil) -> Self {
        var copy = self
        copy.hostViewport = viewport
        copy.hostViewportPanningMode = panningMode
        return copy
    }

    /// Keeps pointer choices with the host when its desktop view is recreated.
    public func controllingPointerMode(_ selection: Binding<RemotePointerMode>) -> Self {
        var copy = self
        copy.hostPointerSelection = selection
        return copy
    }

    /// Hides the floating HUD (menu button and accessory). For a host that offers the same items in its own menu.
    /// Off by default.
    public func hidesHUD(_ hidden: Bool) -> Self {
        var copy = self
        copy.hidesHUD = hidden
        return copy
    }

    /// Routes Control-Shift-digit to the viewer while a multi-monitor desktop has keyboard focus.
    public func onMonitorShortcut(_ action: @escaping (VNCMonitorSelection) -> Void) -> Self {
        var copy = self
        copy.monitorShortcut = action
        return copy
    }

    /// Uses the containing app's screenshot exporter for the iPad keyboard shortcut.
    public func onScreenshotShortcut(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.screenshotShortcut = action
        return copy
    }

    public func onDictation(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.hostDictation = action
        return copy
    }

    /// Uses a window-local crop for both presentation and input translation.
    public func showingMonitor(in region: CGRect) -> Self {
        var copy = self
        copy.windowMonitorRegion = region
        return copy
    }

    /// Reports local toolbar gestures and their normalized position within the desktop.
    public func onPencilToolbarAction(_ action: @escaping (RemotePencilAction, CGPoint) -> Void) -> Self {
        var copy = self
        copy.pencilToolbarAction = action
        return copy
    }

    /// Lets the host trigger the file transfers panel and the curtain prompt from its own menu.
    public func desktopControls(_ controls: VNCDesktopControls?) -> Self {
        var copy = self
        copy.desktopControls = controls
        return copy
    }

    /// Keeps the desktop viewport and the host's trackpad on separate panes.
    public func separateTrackpad(_ enabled: Bool, usesDirectTouch: Bool = false) -> Self {
        var copy = self
        if enabled {
            copy.hostPointerMode = usesDirectTouch ? .direct : .trackpad
            copy.keyboardAvoidanceMode = .hostManaged
        }
        return copy
    }

    /// Lets a host's local text field own focus while it is presented.
    public func suspendingKeyboardCapture(_ suspended: Bool) -> Self {
        var copy = self
        copy.hostSuspendsKeyboardCapture = suspended
        return copy
    }

    /// Host content drawn over the remote picture and under the controls,
    /// in the box the fitted screen occupies. For what the host shows while
    /// there is no picture; it never takes touches.
    public func screenPlaceholder<Placeholder: View>(
        @ViewBuilder _ placeholder: () -> Placeholder
    ) -> Self {
        var copy = self
        copy.screenPlaceholder = AnyView(placeholder())
        return copy
    }

    #if canImport(UIKit)
    /// Adds host content to the HUD, inside its glass: `beside` the menu
    /// button, taking the button style to match, and `behind` the buttons
    /// across the whole bar, taking the width it may use. `buttonStyle` sizes
    /// every button from that width. `docksToBottom` pins the bar along the bottom and fits the
    /// screen above it, though zoomed content still shows through underneath.
    /// `floatingMovement` controls repositioning while the bar is unpinned.
    /// `providesKeyboardButton` drops the menu's own Show Keyboard item.
    public func hudAccessory<Behind: View, Beside: View>(
        isEnabled: Bool = true,
        docksToBottom: Bool = false,
        floatingMovement: VNCHUDFloatingMovement = .snapToEdge,
        providesKeyboardButton: Bool = false,
        onUpwardSwipe: ((CGPoint, UIView) -> Void)? = nil,
        buttonStyle: @escaping (_ availableWidth: CGFloat) -> VNCHUDButtonStyle,
        @ViewBuilder behind: @escaping (_ availableWidth: CGFloat) -> Behind,
        @ViewBuilder beside: @escaping (_ buttonStyle: VNCHUDButtonStyle) -> Beside
    ) -> Self {
        guard isEnabled else { return self }
        var copy = self
        copy.hudAccessory = HUDAccessory(
            docksToBottom: docksToBottom,
            floatingMovement: floatingMovement,
            providesKeyboardButton: providesKeyboardButton,
            onUpwardSwipe: onUpwardSwipe,
            buttonStyle: buttonStyle,
            behind: { AnyView(behind($0)) },
            beside: { AnyView(beside($0)) })
        return copy
    }

    /// Places the existing session menu inside a host-provided floating toolbar.
    public func floatingHUD<Content: View>(isEnabled: Bool,
        @ViewBuilder content: @escaping (AnyView, CGSize) -> Content) -> Self {
        guard isEnabled else { return self }
        var copy = self
        copy.customHUD = { AnyView(content($0, $1)) }
        return copy
    }

    /// Reserves a column beside the desktop for host controls and the session menu.
    public func leadingHUD<Content: View>(isEnabled: Bool, buttonStyle: VNCHUDButtonStyle,
        @ViewBuilder content: @escaping (AnyView, CGFloat) -> Content
    ) -> Self {
        guard isEnabled else { return self }
        var copy = self
        copy.leadingDock = LeadingHUD(style: buttonStyle, content: { AnyView(content($0, $1)) })
        return copy
    }
    #endif

    @ViewBuilder
    public var body: some View {
        #if canImport(UIKit)
        HStack(spacing: 0) {
            if !hidesHUD, let leadingDock {
                leadingBar(leadingDock)
            }
            viewportBody
        }
        .ignoresSafeArea(.keyboard)
        #else
        viewportBody
        #endif
    }

    private var viewportBody: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let framebufferSize = windowMonitorRegion?.size ?? session.presentedFramebufferSize
                let framebufferOrigin = windowMonitorRegion?.origin ?? session.presentedFramebufferRegion?.origin ?? .zero
                // The fitted screen stops above a docked HUD bar. Zoomed in, it
                // still draws underneath: only the ZStack clips.
                let contentSize = CGSize(
                    width: geometry.size.width,
                    height: max(1, geometry.size.height - hudReserve))
                let viewportGeometry = RemoteViewportGeometry(viewSize: contentSize, framebufferSize: framebufferSize,
                                                              displayScale: displayScale)

                let transform = viewport.renderScale(viewSize: contentSize, framebufferSize: framebufferSize)
                ZStack {
                    Color.black
                        .ignoresSafeArea()

                    desktopContent(in: contentSize)
                        .scaleEffect(x: transform.width, y: transform.height)
                        .offset(viewport.offset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if let screenPlaceholder {
                        screenPlaceholder
                            .frame(width: contentSize.width, height: contentSize.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }

                    if session.connectionState.isConnected,
                       framebufferSize.width > 0,
                       framebufferSize.height > 0 {
                        interactionLayer(
                            viewSize: contentSize,
                            framebufferSize: framebufferSize,
                            framebufferOrigin: framebufferOrigin)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }

                    viewportControls

                    #if canImport(UIKit)
                    fileTransferOverlay(
                        viewSize: contentSize,
                        framebufferSize: framebufferSize,
                        framebufferOrigin: framebufferOrigin)
                    #endif

                    VNCCurtainPrompt(
                        session: session,
                        isPresented: $curtainPromptPresented)

                    // Hosts that render their own reconnect/failure prompts
                    // suppress these; drawing both would stack duplicate
                    // cards now that the chrome is translucent.
                    if !hostOwnsRecoveryChrome {
                        recoveryOverlay
                    }
                }
                .clipped()
                .confirmationDialog(
                    String(localized: "Type the saved password?", bundle: .module),
                    isPresented: $confirmPasswordSend,
                    titleVisibility: .visible
                ) {
                    if !confirmPasswordOnly {
                        Button(String(localized: "Type Password and Log In", bundle: .module)) {
                            keyboardCapture.noteExternalInput()
                            session.sendLoginPassword()
                        }
                    }
                    Button(String(localized: "Type Password Only", bundle: .module)) {
                        keyboardCapture.noteExternalInput()
                        session.sendLoginPassword(pressingReturn: false)
                    }
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                } message: {
                    if confirmPasswordOnly {
                        Text(String(localized: "The password will be typed without submitting the remote form.", bundle: .module))
                    } else {
                        Text(String(localized: "The password will be typed into the remote computer. Type Password Only skips Return so you can submit it yourself.", bundle: .module))
                    }
                }
                .onChange(of: viewportGeometry, initial: true) { _, next in
                    viewport.updateGeometry(next)
                }
                .onChange(of: geometry.size) { _, newSize in
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: newSize)
                    #elseif targetEnvironment(macCatalyst)
                    catalystLayoutSize = newSize
                    updateRemoteDisplaySizeFromMeasuredContainer()
                    #endif
                }
                .onChange(of: hudReserve) {
                    #if canImport(UIKit)
                    updateRemoteDisplaySizeFromMeasuredContainer()
                    #endif
                }
                .onAppear {
                    presentPendingLoginPasswordPrompt()
                    #if !canImport(UIKit)
                    updateRemoteDisplaySize(for: geometry.size)
                    #elseif targetEnvironment(macCatalyst)
                    catalystLayoutSize = geometry.size
                    #endif
                }
                .onChange(of: session.loginPasswordPromptPending) { _, pending in
                    if pending {
                        presentPendingLoginPasswordPrompt()
                    }
                }
                .onChange(of: displayScale) {
                    #if canImport(UIKit)
                    updateRemoteDisplaySizeFromMeasuredContainer()
                    #else
                    updateRemoteDisplaySize(for: geometry.size)
                    #endif
                }
                .onChange(of: session.connectionState) { _, newState in
                    if newState.isConnected {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    } else {
                        confirmPasswordSend = false
                        curtainPromptPresented = false
                    }
                }
                .onChange(of: session.configuration.displaySizingMode) { _, mode in
                    if mode == .matchClient {
                        #if canImport(UIKit)
                        updateRemoteDisplaySizeFromMeasuredContainer()
                        #else
                        updateRemoteDisplaySize(for: geometry.size)
                        #endif
                    }
                }
            }

            #if canImport(UIKit)
            if keyboardAvoidanceMode == .automatic {
                Color.clear
                    // Keyboard layout-guide callbacks can arrive out of order
                    // during dismissal/reparenting. Once neither the software
                    // keyboard nor an accessory is active, ignore stale data.
                    .frame(height: keyboardViewportMetrics.effectiveInset(
                        reservingObstruction: shouldReserveKeyboardInset))
                    .accessibilityHidden(true)
            }
            #endif
        }
        // Two-way sync with the host-visible keyboard request. The local
        // @State stays authoritative for HUD-driven changes; the equality
        // guards prevent onChange ping-pong between the two sources.
        .onChange(of: keyboardActive) { _, active in
            if keyboardCapture.softwareKeyboardRequested != active {
                keyboardCapture.softwareKeyboardRequested = active
            }
            #if canImport(UIKit)
            updateRemoteDisplaySizeFromMeasuredContainer()
            #endif
        }
        .onChange(of: keyboardCapture.softwareKeyboardRequested) { _, requested in
            if keyboardActive != requested {
                keyboardActive = requested
            }
        }
        .onChange(of: desktopControlRequests) { old, new in
            guard new.controller != nil, old.controller == new.controller else { return }
            #if canImport(UIKit)
            // Two toggles can land in one update; only the parity moves the panel.
            if (new.fileTransferToggles &- old.fileTransferToggles) & 1 != 0 {
                showsFileTransfers.toggle()
            }
            #endif
            if new.curtainPrompts != old.curtainPrompts {
                presentHostCurtainPrompt()
            }
            if new.passwordOnlyPrompts != old.passwordOnlyPrompts {
                requestPasswordSend(only: true)
            } else if new.passwordPrompts != old.passwordPrompts {
                requestPasswordSend()
            }
        }
        #if canImport(UIKit)
        // The overlay's teardown never reports, so its last measurements would
        // keep shortening the screen and steering the composition preview.
        .onChange(of: hidesHUD) { _, hidden in
            guard hidden else { return }
            hudReserve = 0
            hudFrame.frame = .zero
        }
        .onChange(of: leadingDock != nil) { _, docked in
            guard docked else { return }
            hudReserve = 0
            hudFrame.frame = .zero
        }
        .background {
            DockedKeyboardInsetReader(
                metrics: $keyboardViewportMetrics,
                onWindowSceneChange: { [session] in session.setHostScene($0) })
        }
        // UIKit's layout guide distinguishes a bottom-docked keyboard from
        // floating and split keyboards; SwiftUI's safe area does not.
        .ignoresSafeArea(.keyboard)
        .onChange(of: keyboardViewportMetrics) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        .onChange(of: keyboardAvoidanceMode) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        .onChange(of: keyboardCapture.inputViewsGeneration) { _, _ in
            updateRemoteDisplaySizeFromMeasuredContainer()
        }
        #endif
    }

    @ViewBuilder
    private func desktopContent(in viewSize: CGSize) -> some View {
        if session.isHighPerformanceMode {
            #if canImport(UIKit)
            AdaptiveDisplayView(
                primaryRenderer: session.videoBandRenderer,
                secondaryRenderer: session.secondaryVideoBandRenderer,
                displayRegions: session.presentedVideoDisplayRegions,
                cropRegion: windowMonitorRegion ?? session.selectedVirtualRegion,
                independentLayers: windowMonitorRegion != nil,
                brightnessGain: brightnessGain)
                .frame(width: viewSize.width, height: viewSize.height)
            #else
            placeholderView
                .frame(width: viewSize.width, height: viewSize.height)
            #endif
        } else {
            StandardFramebufferContent(
                session: session,
                cropRegion: windowMonitorRegion ?? session.presentedFramebufferRegion,
                showsWaitingCard: !hostOwnsRecoveryChrome,
                brightnessGain: brightnessGain,
                viewSize: viewSize)
                .frame(width: viewSize.width, height: viewSize.height)
        }
    }

    @ViewBuilder
    private func interactionLayer(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some View {
        #if canImport(UIKit)
        RemoteInteractionView(
            viewport: viewportSelection,
            viewportPanningMode: viewportPanningSelection.wrappedValue,
            pointerMode: hostPointerMode ?? pointerModeSelection.wrappedValue,
            pointerSpeed: pointerSpeed,
            cursorHeight: cursorHeight,
            serverRendersCursor: session.activeCursorRendering == .server,
            showsLocalCursorDot: false,
            touchGestures: touchGestures,
            keyboardActive: $keyboardActive,
            hardwareKeyboardAttached: $hardwareKeyboardAttached,
            framebufferSize: framebufferSize,
            touchHandler: touchHandler,
            keyboardHandler: keyboardHandler,
            keyboardCapture: keyboardCapture,
            suspendsKeyboardCapture: curtainPromptPresented || hostSuspendsKeyboardCapture,
            framebufferOrigin: framebufferOrigin,
            requestPasswordSend: requestPasswordSend,
            requestDictation: requestDictation,
            toggleFullScreen: toggleFullScreen,
            disconnect: { session.requestUserDisconnect() },
            // Apple's adaptive profile asks the server for cached cursor
            // images so the responsive local pointer can adopt their shape.
            remoteCursor: session.remoteCursor,
            remoteCursorPresence: session.remoteCursorPresence,
            usesFallbackCursor: session.configuration.usesFallbackCursor,
            swapsHardwareCommandAndControl: session.configuration.swapsHardwareCommandAndControl,
            allowsViewportZoom: session.configuration.allowsViewportZoom,
            routesDirectTouchesToRemote: hostPointerMode != .trackpad,
            desktopControls: desktopControls,
            fileTransfers: session.fileTransfers,
            pencilToolbarAction: pencilToolbarAction,
            monitorIDs: monitorShortcut == nil ? [] : session.selectableMonitorIDs,
            monitorShortcut: monitorShortcut,
            screenshotShortcut: screenshotShortcut)
            .frame(width: viewSize.width, height: viewSize.height)
            .contentShape(Rectangle())
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(fallbackTapGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackDragGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize,
                framebufferOrigin: framebufferOrigin))
            .simultaneousGesture(fallbackMagnificationGesture(
                viewSize: viewSize,
                framebufferSize: framebufferSize), including: session.configuration.allowsViewportZoom ? .all : .none)
        #endif
    }

    @ViewBuilder
    private var viewportControls: some View {
        #if canImport(UIKit)
        GeometryReader { proxy in
            let margin = HUDBar<EmptyView>.margin(for: hudAccessory)
            let available = HUDBar<EmptyView>.availableWidth(
                containerWidth: proxy.size.width,
                safeArea: proxy.safeAreaInsets,
                safeAreaEdges: hudSafeAreaEdges,
                margin: margin)
            if !hidesHUD, let customHUD {
                customHUD(AnyView(hudMenu), proxy.size)
                    .onAppear { hudReserve = 0; hudFrame.frame = .zero }
            } else if !hidesHUD, leadingDock == nil {
                DraggableHUDOverlay(
                    inset: margin,
                    safeAreaEdges: hudSafeAreaEdges,
                    pinnedRowHeight: hudAccessory?.docksToBottom == true
                        ? hudAccessory?.buttonStyle(available).size.height : nil,
                    floatingMovement: hudAccessory?.floatingMovement ?? .snapToEdge,
                    onUpwardSwipe: hudAccessory?.onUpwardSwipe,
                    onReserveChange: { hudReserve = $0 },
                    onFrameChange: { [hudFrame] in hudFrame.frame = $0 }
                ) {
                    HUDBar(accessory: hudAccessory, availableWidth: available) {
                        hudMenu
                    }
                }
            }
            CompositionPreviewLayer(
                keyboardCapture: keyboardCapture,
                hudFrame: hudFrame,
                margin: margin,
                safeArea: proxy.safeAreaInsets,
                safeAreaEdges: hudSafeAreaEdges)
        }
        #else
        if !hidesHUD {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    hudMenu
                }
                .padding(12)
            }
            .allowsHitTesting(true)
        }
        #endif
    }

    #if canImport(UIKit)
    private func leadingBar(_ dock: LeadingHUD) -> some View {
        GeometryReader { proxy in
            let menu = AnyView(hudMenu.environment(\.vncHUDButtonStyle, dock.style))
            dock.content(menu, max(0, proxy.size.height - 12))
                .modifier(HUDBarChromeModifier(cornerRadius: dock.style.size.width / 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: dock.style.size.width + 12)
        .padding(.bottom, keyboardAvoidanceMode == .automatic
                 ? keyboardViewportMetrics.effectiveInset(reservingObstruction: shouldReserveKeyboardInset) : 0)
    }

    private struct DragOutTargetGeometry: Equatable {
        let viewSize: CGSize
        let framebufferSize: CGSize
        let framebufferOrigin: CGPoint
        let viewport: RemoteViewportState
        let dragAnchor: CGPoint?
    }

    @ViewBuilder
    private func fileTransferOverlay(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some View {
        let transfers = session.fileTransfers
        let geometry = DragOutTargetGeometry(
            viewSize: viewSize,
            framebufferSize: framebufferSize,
            framebufferOrigin: framebufferOrigin,
            viewport: viewport,
            dragAnchor: transfers.remoteDragAnchor)
        ZStack {
            if transfers.showsDragOutTarget, let target = dragOutTargetFrame(geometry) {
                VNCDragOutTargetView(
                    names: transfers.remoteDraggedNames,
                    isTargeted: transfers.remoteDragOverTarget,
                    width: target.width)
                    #if targetEnvironment(macCatalyst)
                    .allowsHitTesting(false)
                    #else
                    .contentShape(Capsule())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in transfers.dismissDragOutTarget() })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { transfers.dismissDragOutTarget() }
                    #endif
                    .position(x: target.midX, y: target.midY)
                    .transition(.opacity)
            }
            if showsFileTransfers {
                VNCFileTransfersPanel(controller: transfers) {
                    showsFileTransfers = false
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: transfers.showsDragOutTarget)
        .animation(.easeOut(duration: 0.2), value: showsFileTransfers)
        .onAppear { updateDragOutTarget(geometry) }
        .onChange(of: geometry) { _, newGeometry in
            updateDragOutTarget(newGeometry)
        }
        .onChange(of: transfers.transfers.count) { oldCount, newCount in
            if newCount > oldCount { showsFileTransfers = true }
        }
    }

    private func dragOutTargetFrame(_ geometry: DragOutTargetGeometry) -> CGRect? {
        guard let frame = geometry.viewport.displayedFrame(
            viewSize: geometry.viewSize,
            framebufferSize: geometry.framebufferSize) else { return nil }
        let visible = frame.intersection(CGRect(origin: .zero, size: geometry.viewSize))
        #if targetEnvironment(macCatalyst)
        return VNCDragOutTargetView.targetFrame(in: visible, near: nil)
        #else
        guard let anchor = geometry.dragAnchor,
              let point = geometry.viewport.viewPoint(forFramebufferPoint: CGPoint(
                x: anchor.x - geometry.framebufferOrigin.x, y: anchor.y - geometry.framebufferOrigin.y),
                viewSize: geometry.viewSize, framebufferSize: geometry.framebufferSize),
              visible.contains(point) else { return nil }
        return VNCDragOutTargetView.targetFrame(in: visible, near: point)
        #endif
    }

    private func updateDragOutTarget(_ geometry: DragOutTargetGeometry) {
        let transfers = session.fileTransfers
        func remotePoint(_ point: CGPoint) -> CGPoint? {
            geometry.viewport.framebufferPoint(
                for: point,
                viewSize: geometry.viewSize,
                framebufferSize: geometry.framebufferSize)
        }
        guard let frame = dragOutTargetFrame(geometry),
              let topLeft = remotePoint(CGPoint(x: frame.minX, y: frame.minY)),
              let bottomRight = remotePoint(CGPoint(x: frame.maxX - 0.5, y: frame.maxY - 0.5)) else {
            if transfers.dragOutTarget != nil { transfers.dragOutTarget = nil }
            return
        }
        let rect = CGRect(
            x: topLeft.x + geometry.framebufferOrigin.x,
            y: topLeft.y + geometry.framebufferOrigin.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y)
        if transfers.dragOutTarget != rect { transfers.dragOutTarget = rect }
    }
    #endif

    #if canImport(UIKit)
    private var hudMenu: some View {
        HUDMenu(
            keyboardCapture: keyboardCapture,
            keyboardHandler: keyboardHandler,
            keyboardActive: $keyboardActive,
            hardwareKeyboardAttached: hardwareKeyboardAttached,
            hostProvidesKeyboardButton: leadingDock != nil || hudAccessory?.providesKeyboardButton == true,
            viewport: viewportSelection,
            viewportPanningMode: viewportPanningSelection,
            pointerMode: pointerModeSelection,
            isFullScreen: isFullScreen,
            toggleFullScreen: toggleFullScreen,
            extras: hudMenuExtras,
            disconnect: { session.requestUserDisconnect() },
            sessionActions: {
                clipboardMenu
                if session.fileTransfers.canUpload || session.fileTransfers.canDownload
                    || !session.fileTransfers.transfers.isEmpty {
                    Button {
                        showsFileTransfers.toggle()
                    } label: {
                        Label(
                            showsFileTransfers
                                ? String(localized: "Hide File Transfers", bundle: .module)
                                : String(localized: "File Transfers", bundle: .module),
                            systemImage: "arrow.up.arrow.down.circle")
                    }
                }
                passwordButton
            },
            sessionDisplay: { curtainToggle })
    }
    #else
    /// Without the touch and keyboard layer there is little to group.
    private var hudMenu: some View {
        Menu {
            clipboardMenu
            passwordButton
            hudMenuExtras.actions
            Menu {
                HUDFitScreenButton(viewport: viewportSelection)
                HUDPanningPicker(selection: viewportPanningSelection)
                HUDPointerPicker(selection: pointerModeSelection)
                curtainToggle
                hudMenuExtras.display
            } label: {
                Label(String(localized: "Display", bundle: .module), systemImage: "display")
            }
            if let toggleFullScreen {
                HUDFullScreenButton(isFullScreen: isFullScreen, toggle: toggleFullScreen)
            }
            hudMenuExtras.keyboard
            hudMenuExtras.session
            Divider()
            HUDCloseConnectionButton { session.requestUserDisconnect() }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.bold))
                .frame(width: 46, height: 46)
                .modifier(HUDButtonChromeModifier())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(String(localized: "Remote Desktop Controls", bundle: .module))
        .help(String(localized: "Remote Desktop Controls", bundle: .module))
    }
    #endif

    @ViewBuilder
    private var clipboardMenu: some View {
        if let clipboardSynchronizer {
            VNCClipboardMenu(
                synchronizer: clipboardSynchronizer,
                onSharedClipboardUserChange: onSharedClipboardUserChange)
        }
    }

    /// Absent, not greyed out, while there is no password to type.
    @ViewBuilder
    private var passwordButton: some View {
        if session.canSendLoginPassword {
            Button {
                requestPasswordSend()
            } label: {
                Label(String(localized: "Type Password", bundle: .module), systemImage: "key.fill")
            }
        }
    }

    @ViewBuilder
    private var curtainToggle: some View {
        if session.supportsCurtainMode {
            Toggle(isOn: curtainBinding) {
                Label(
                    String(localized: "Curtain Mode", bundle: .module),
                    systemImage: session.isCurtained ? "eye.slash.fill" : "eye.slash")
            }
        }
    }

    private struct DesktopControlRequests: Equatable {
        var controller: UUID?
        var fileTransferToggles = 0
        var curtainPrompts = 0
        var passwordPrompts = 0
        var passwordOnlyPrompts = 0
    }

    private var desktopControlRequests: DesktopControlRequests {
        guard let desktopControls else { return DesktopControlRequests() }
        var requests = DesktopControlRequests(
            controller: desktopControls.identity,
            curtainPrompts: desktopControls.curtainPromptRequests,
            passwordPrompts: desktopControls.passwordPromptRequests,
            passwordOnlyPrompts: desktopControls.passwordOnlyPromptRequests)
        #if canImport(UIKit)
        requests.fileTransferToggles = desktopControls.fileTransfersToggleRequests
        #endif
        return requests
    }

    /// Same gate as the HUD's toggle: confirming would otherwise send nothing.
    private func presentHostCurtainPrompt() {
        guard session.connectionState.isConnected,
              session.supportsCurtainMode else { return }
        curtainPromptPresented = true
    }

    private func requestPasswordSend() { requestPasswordSend(only: false) }

    private func requestPasswordSend(only: Bool) {
        guard session.canSendLoginPassword, !confirmPasswordSend else { return }
        confirmPasswordOnly = only
        confirmPasswordSend = true
    }

    private func presentPendingLoginPasswordPrompt() {
        guard session.loginPasswordPromptPending else { return }
        guard session.consumeLoginPasswordPromptRequest() else { return }
        requestPasswordSend()
    }

    private func requestDictation() {
        if let hostDictation { hostDictation(); return }
        keyboardCapture.capture()
        keyboardActive = true
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            switch session.connectionState {
            case .connecting:
                ProgressView().controlSize(.large)
                Text(String(localized: "Connecting...", bundle: .module)).foregroundStyle(.secondary)
            case .connected:
                ProgressView().controlSize(.large)
                Text(String(localized: "Waiting for framebuffer...", bundle: .module)).foregroundStyle(.secondary)
            case .reconnecting(let attempt, _):
                ProgressView().controlSize(.large)
                Text(String(localized: "Reconnecting (attempt \(attempt))...", bundle: .module))
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text(String(localized: "Connection Failed", bundle: .module)).font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            case .disconnected:
                Image(systemName: "rectangle.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Disconnected", bundle: .module)).foregroundStyle(.secondary)
            case .idle, .disconnecting:
                Image(systemName: "desktopcomputer")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "No Active Connection", bundle: .module)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recoveryOverlay: some View {
        switch session.connectionState {
        case .reconnecting:
            ConnectionStatusOverlay(session: session)

        case .failed(let reason):
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title)
                Text(String(localized: "Unable to reconnect", bundle: .module)).font(.headline)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button(String(localized: "Try Again", bundle: .module)) { session.retryConnection() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "Disconnect", bundle: .module), role: .destructive) { session.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()

        default:
            EmptyView()
        }
    }

    private func updateRemoteDisplaySize(for viewSize: CGSize) {
        guard windowMonitorRegion == nil else { return }
        session.updateRemoteDisplaySize(
            viewSize: viewSize,
            displayScale: displayScale)
    }

    #if canImport(UIKit)
    private func updateRemoteDisplaySizeFromMeasuredContainer() {
        #if targetEnvironment(macCatalyst)
        let layoutSize = catalystLayoutSize
        #else
        let layoutSize: CGSize? = nil
        #endif
        guard let size = keyboardViewportMetrics.matchClientSize(
            layoutSize: layoutSize,
            hudReserve: hudReserve,
            avoidanceMode: keyboardAvoidanceMode,
            reservingObstruction: shouldReserveKeyboardInset) else { return }
        updateRemoteDisplaySize(for: size)
    }
    #endif

    #if !canImport(UIKit)
    private func fallbackTapGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                touchHandler.handleTap(x: point.x, y: point.y)
            }
    }

    private func fallbackDragGesture(
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard let point = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin) else { return }
                fallbackDragRemotePoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                touchHandler.handleDrag(x: point.x, y: point.y)
            }
            .onEnded { value in
                let mapped = remotePoint(
                    value.location,
                    viewSize: viewSize,
                    framebufferSize: framebufferSize,
                    framebufferOrigin: framebufferOrigin)
                let finalPoint = mapped ?? fallbackDragRemotePoint.map({
                    (x: UInt16($0.x), y: UInt16($0.y))
                })
                fallbackDragRemotePoint = nil
                guard let finalPoint else { return }
                touchHandler.handleDragEnd(x: finalPoint.x, y: finalPoint.y)
            }
    }

    private func fallbackMagnificationGesture(
        viewSize: CGSize,
        framebufferSize: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let incremental = value.magnification / lastFallbackMagnification
                viewport.zoom(
                    by: incremental,
                    around: value.startAnchor.point(in: viewSize),
                    viewSize: viewSize,
                    framebufferSize: framebufferSize)
                lastFallbackMagnification = value.magnification
            }
            .onEnded { _ in
                lastFallbackMagnification = 1
            }
    }

    private func remotePoint(
        _ point: CGPoint,
        viewSize: CGSize,
        framebufferSize: CGSize,
        framebufferOrigin: CGPoint = .zero
    ) -> (x: UInt16, y: UInt16)? {
        guard let mapped = viewport.framebufferPoint(
            for: point,
            viewSize: viewSize,
            framebufferSize: framebufferSize) else { return nil }
        return (
            UInt16(min(CGFloat(UInt16.max), mapped.x + framebufferOrigin.x)),
            UInt16(min(CGFloat(UInt16.max), mapped.y + framebufferOrigin.y)))
    }
    #endif
}

/// Shared HUD submenu used by both the package demo and container apps.
/// Hosts the curtain prompts on their own, deliberately frame-independent view.
///
/// `RemoteDesktopView.body` re-evaluates on every decoded frame, and an alert
/// whose text field is bound to state up there is rebuilt on each keystroke,
/// which drops keyboard focus after every character. Keeping the draft message
/// as this view's own state, and reading nothing that changes per frame, means
/// typing only invalidates this zero-sized view.
private struct VNCCurtainPrompt: View {
    @Bindable var session: VNCSession
    @Binding var isPresented: Bool
    @State private var message = ""

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { session.curtainChangeFailed },
            set: { presented in
                if !presented { session.acknowledgeCurtainFailure() }
            })
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .alert(
                String(localized: "Turn On Curtain Mode?", bundle: .module),
                isPresented: $isPresented
            ) {
                TextField(
                    String(localized: "optional message", bundle: .module),
                    text: $message)
                Button(String(localized: "Curtain", bundle: .module)) {
                    session.setCurtainMode(true, message: message)
                    message = ""
                }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) {
                    message = ""
                }
            } message: {
                Text(String(localized: "The remote computer's own display will be hidden while you keep control. Anyone at that computer sees a lock screen with your message.", bundle: .module))
            }
            .alert(
                String(localized: "Curtain Mode Did Not Change", bundle: .module),
                isPresented: failureBinding
            ) {
                Button(String(localized: "OK", bundle: .module), role: .cancel) {}
            } message: {
                Text(String(localized: "The remote computer did not confirm the change, so its display may still be visible to anyone nearby.", bundle: .module))
            }
    }
}

private struct VNCClipboardMenu: View {
    @Bindable var synchronizer: VNCClipboardSynchronizer
    let onSharedClipboardUserChange: (@MainActor (Bool) -> Void)?

    private var sharedClipboardBinding: Binding<Bool> {
        Binding(
            get: { synchronizer.sharedClipboardEnabled },
            set: { enabled in
                synchronizer.sharedClipboardEnabled = enabled
                onSharedClipboardUserChange?(enabled)
            }
        )
    }

    var body: some View {
        Menu {
            Button {
                synchronizer.getClipboard()
            } label: {
                Label(String(localized: "Get Clipboard", bundle: .module), systemImage: "arrow.down.doc")
            }
            .disabled(!synchronizer.canGetClipboard)

            Button {
                synchronizer.sendClipboard()
            } label: {
                Label(String(localized: "Send Clipboard", bundle: .module), systemImage: "arrow.up.doc")
            }
            .disabled(!synchronizer.canSendClipboard)

            Divider()

            Toggle(isOn: sharedClipboardBinding) {
                Label(String(localized: "Shared Clipboard", bundle: .module), systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Label(String(localized: "Clipboard", bundle: .module), systemImage: "doc.on.clipboard")
        }
    }
}

#if canImport(UIKit)
/// Reports only the space occupied by a keyboard docked to the bottom edge.
/// UIKit collapses this guide for floating, split, and detached keyboards.
struct DockedKeyboardInsetReader: UIViewRepresentable {
    @Binding var metrics: DockedKeyboardViewportMetrics
    var onWindowSceneChange: ((UIWindowScene?) -> Void)?

    func makeUIView(context: Context) -> DockedKeyboardInsetView {
        let view = DockedKeyboardInsetView()
        view.onMetricsChange = { newMetrics in
            context.coordinator.setMetrics(newMetrics)
        }
        view.onWindowSceneChange = onWindowSceneChange
        return view
    }

    func updateUIView(
        _ uiView: DockedKeyboardInsetView,
        context: Context
    ) {
        context.coordinator.parent = self
        uiView.onWindowSceneChange = onWindowSceneChange
        uiView.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator {
        var parent: DockedKeyboardInsetReader

        init(parent: DockedKeyboardInsetReader) {
            self.parent = parent
        }

        func setMetrics(_ metrics: DockedKeyboardViewportMetrics) {
            guard !parent.metrics.isApproximatelyEqual(to: metrics) else { return }
            parent.metrics = metrics
        }
    }
}

/// Reports the overlap of the docked keyboard with the pane it fills.
public struct VNCDockedKeyboardInsetReader: View {
    @State private var metrics = DockedKeyboardViewportMetrics()
    private let onChange: (CGFloat) -> Void

    public init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        DockedKeyboardInsetReader(metrics: $metrics)
            .onChange(of: metrics.keyboardInset, initial: true) { _, inset in onChange(inset) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
final class DockedKeyboardInsetView: UIView {
    var onMetricsChange: ((DockedKeyboardViewportMetrics) -> Void)?
    var onWindowSceneChange: ((UIWindowScene?) -> Void)? {
        didSet { onWindowSceneChange?(window?.windowScene) }
    }
    private var lastReportedMetrics: DockedKeyboardViewportMetrics?
    private let keyboardTopProbe = UIView(frame: .zero)
    private var keyboardTransitionInProgress = false
    private var metricsPublishGeneration: UInt = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // The default is already false, but make the intended floating and
        // split-keyboard behavior explicit.
        keyboardLayoutGuide.followsUndockedKeyboard = false
        if #available(iOS 17.0, *) {
            // An absent or detached keyboard should report zero rather than
            // the device's bottom safe-area inset.
            keyboardLayoutGuide.usesBottomSafeArea = false
        }

        keyboardTopProbe.isHidden = true
        keyboardTopProbe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardTopProbe)
        NSLayoutConstraint.activate([
            keyboardTopProbe.topAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor),
            keyboardTopProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardTopProbe.widthAnchor.constraint(equalToConstant: 0),
            keyboardTopProbe.heightAnchor.constraint(equalToConstant: 0),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChange?(window?.windowScene)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if !keyboardTransitionInProgress {
            publishCurrentMetrics()
        }
    }

    @objc private func keyboardFrameWillChange() {
        keyboardTransitionInProgress = true
    }

    @objc private func keyboardFrameDidChange() {
        keyboardTransitionInProgress = false
        setNeedsLayout()
        layoutIfNeeded()
        publishCurrentMetrics()
    }

    @objc private func keyboardDidHide() {
        keyboardTransitionInProgress = false
        publishMetrics(keyboardInset: 0)
    }

    private func publishCurrentMetrics() {
        let inset = max(0, bounds.maxY - keyboardTopProbe.frame.minY)
        publishMetrics(keyboardInset: inset)
    }

    private func publishMetrics(keyboardInset: CGFloat) {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: bounds.size,
            keyboardInset: keyboardInset)
        guard lastReportedMetrics?.isApproximatelyEqual(to: metrics) != true else {
            return
        }
        lastReportedMetrics = metrics
        metricsPublishGeneration &+= 1
        let generation = metricsPublishGeneration

        // Avoid publishing SwiftUI state during a UIKit layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metricsPublishGeneration == generation else { return }
            self.onMetricsChange?(metrics)
        }
    }
}
#endif

/// Circle chrome for the HUD menu button: Liquid Glass on current OS
/// releases and a material fallback where the glass API is unavailable.
/// Deliberately not host-tinted — the button floats over live desktop
/// content, where adaptive glass fits better than theme colors.
struct HUDButtonChromeModifier: ViewModifier {
    /// False while the button sits inside a HUD bar, which draws the glass.
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled { chrome(content) } else { content }
    }

    @ViewBuilder
    private func chrome(_ content: Content) -> some View {
        #if os(visionOS)
        content.background(.ultraThinMaterial, in: Circle())
        #else
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
        #endif
    }
}

/// Owns the hot standard-framebuffer observation so publishing a new frame
/// never invalidates the parent view (or even this view) per frame.
private struct StandardFramebufferContent: View {
    @Bindable var session: VNCSession
    let cropRegion: CGRect?
    /// False when the host renders its own connected-but-no-frame prompt.
    let showsWaitingCard: Bool
    let brightnessGain: Double
    let viewSize: CGSize

    var body: some View {
        if session.hasPresentedStandardPicture {
            #if canImport(UIKit) || canImport(AppKit)
            StandardFramebufferView(
                renderer: session.standardFramebufferRenderer,
                cropRegion: cropRegion,
                brightnessGain: brightnessGain)
                .frame(width: viewSize.width, height: viewSize.height)
            #else
            if let image = session.currentImage {
                let displayedImage = cropped(image) ?? image
                let imageSize = CGSize(
                    width: displayedImage.width,
                    height: displayedImage.height)
                let fit = RemoteViewportState.fitScale(content: imageSize, into: viewSize)
                Image(decorative: displayedImage, scale: 1)
                    .interpolation(.high)
                    .resizable()
                    .frame(
                        width: imageSize.width * fit.width,
                        height: imageSize.height * fit.height)
            }
            #endif
        } else if showsWaitingCard, session.connectionState.isConnected {
            // Handshake finished but no framebuffer content has been
            // published. The reconnect/failure overlays own the other states.
            ConnectionStatusCard(
                title: String(localized: "Waiting for first screen update…", bundle: .module),
                detail: session.connectingHostLabel,
                actionLabel: String(localized: "Cancel", bundle: .module),
                actionRole: .cancel
            ) { session.disconnect() }
        }
    }

    #if !canImport(UIKit) && !canImport(AppKit)
    private func cropped(_ image: CGImage) -> CGImage? {
        guard let region = cropRegion else { return nil }
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: image.width, height: image.height)
        let crop = region.integral.intersection(imageBounds)
        guard !crop.isEmpty, crop != imageBounds else { return nil }
        return image.cropping(to: crop)
    }
    #endif
}

/// A read-only monitor window has a presentation layer and no input responder.
public struct VNCMonitorPicture: View {
    @Environment(\.displayScale) private var displayScale
    private let session: VNCSession
    private let region: CGRect?
    private let sizing: RemoteViewportSizing

    public init(session: VNCSession, region: CGRect? = nil, sizing: RemoteViewportSizing = .fit) {
        self.session = session
        self.region = region
        self.sizing = sizing
    }

    public var body: some View {
        GeometryReader { proxy in
            let transform = RemoteViewportState(sizing: sizing, displayScale: displayScale)
                .renderScale(viewSize: proxy.size, framebufferSize: region?.size ?? session.presentedFramebufferSize)
            picture(in: proxy.size)
                .scaleEffect(x: transform.width, y: transform.height)
        }
        .clipped()
        .background(.black)
    }

    @ViewBuilder
    private func picture(in size: CGSize) -> some View {
        #if canImport(UIKit)
        if session.isHighPerformanceMode {
            AdaptiveDisplayView(primaryRenderer: session.videoBandRenderer,
                                secondaryRenderer: session.secondaryVideoBandRenderer,
                                displayRegions: session.presentedVideoDisplayRegions,
                                cropRegion: region ?? session.selectedVirtualRegion,
                                independentLayers: true, brightnessGain: 1)
        } else {
            standardPicture(in: size)
        }
        #else
        standardPicture(in: size)
        #endif
    }

    private func standardPicture(in size: CGSize) -> some View {
        StandardFramebufferContent(session: session, cropRegion: region ?? session.presentedFramebufferRegion,
                                   showsWaitingCard: false, brightnessGain: 1, viewSize: size)
    }
}

#if canImport(UIKit)
struct VideoMonitorPlacement {
    let canvas: CGRect
    let scale: CGSize

    init(regions: [CGRect], crop: CGRect?, view: CGSize) {
        let union = regions.reduce(CGRect.null) { $0.union($1) }
        canvas = crop ?? (union.isNull ? CGRect(origin: .zero, size: view) : union)
        scale = RemoteViewportState.fitScale(content: CGSize(width: max(1, canvas.width), height: max(1, canvas.height)),
                                             into: view)
    }

    var size: CGSize { CGSize(width: canvas.width * scale.width, height: canvas.height * scale.height) }

    func frame(for region: CGRect) -> CGRect? {
        guard !region.intersection(canvas).isEmpty else { return nil }
        return CGRect(x: (region.minX - canvas.minX) * scale.width, y: (region.minY - canvas.minY) * scale.height,
                      width: region.width * scale.width, height: region.height * scale.height)
    }
}

/// Keeps each display in its own decoder-backed renderer and positions it in
/// the server's normalized desktop coordinate space.
private struct AdaptiveDisplayView: View {
    let primaryRenderer: VideoBandLayerRenderer
    let secondaryRenderer: VideoBandLayerRenderer
    let displayRegions: [CGRect]
    let cropRegion: CGRect?
    let independentLayers: Bool
    let brightnessGain: Double

    var body: some View {
        GeometryReader { geometry in
            let regions = displayRegions.isEmpty
                ? [CGRect(origin: .zero, size: geometry.size)]
                : displayRegions
            let placement = VideoMonitorPlacement(regions: regions, crop: cropRegion, view: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(regions.prefix(2).indices), id: \.self) { index in
                    if let frame = placement.frame(for: regions[index]) {
                        videoDisplay(index == 0 ? primaryRenderer : secondaryRenderer)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .frame(width: placement.size.width, height: placement.size.height, alignment: .topLeading)
            .clipped()
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(Color.black)
    }

    @ViewBuilder private func videoDisplay(_ renderer: VideoBandLayerRenderer) -> some View {
        if independentLayers { MirroredVideoBandView(renderer: renderer, gain: brightnessGain) }
        else { VideoBandView(renderer: renderer, brightnessGain: brightnessGain) }
    }
}
#endif

#if !canImport(UIKit)
private extension UnitPoint {
    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
