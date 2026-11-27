//
//  VNCDesktopControls.swift
//  rootshellVNC
//
//  Lets a host app drive two actions of the HUD menu from its own menu (the Mac menu bar).
//

import Foundation
import Observation
#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

/// Requests from the host app to `RemoteDesktopView`. The view watches the counters: each increase is one request.
/// Pass one object to the view and keep it in the host.
@MainActor
@Observable
public final class VNCDesktopControls {
    /// Attaching, swapping, or removing a controller moves the counters the
    /// view sees without a request; the view only acts within one identity.
    let identity = UUID()

    #if canImport(UIKit)
    /// Shows or hides the file transfers panel (the HUD item "File Transfers").
    public private(set) var fileTransfersToggleRequests = 0
    #endif
    /// Opens the Curtain Mode prompt (turning curtain mode on asks for a message first).
    /// Ignored unless the session is connected and `supportsCurtainMode`.
    public private(set) var curtainPromptRequests = 0
    public private(set) var passwordPromptRequests = 0
    public private(set) var passwordOnlyPromptRequests = 0

    public init() {}

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ObservationIgnored weak var inputSurface: RemoteInputUIView?

    /// An upward swipe on the software keyboard's shortcut strip reaches the remote Dock.
    public func movePointerToBottomEdge(at point: CGPoint, in toolbar: UIView) {
        guard let surface = inputSurface, let window = surface.window, toolbar.window === window else { return }
        surface.jumpFromKeyboardToolbar(at: surface.convert(point, from: toolbar))
    }
    #endif

    #if canImport(UIKit)
    public func toggleFileTransfers() { fileTransfersToggleRequests &+= 1 }
    #endif
    public func requestCurtainPrompt() { curtainPromptRequests &+= 1 }
    public func requestPasswordPrompt() { passwordPromptRequests &+= 1 }
    /// Prompts to type the password without submitting the remote form.
    public func requestPasswordOnlyPrompt() { passwordOnlyPromptRequests &+= 1 }
}
