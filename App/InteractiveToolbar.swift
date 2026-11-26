#if !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

enum DeskToolbarStyle: String, CaseIterable {
    case docked, floating, carousel

    var title: String {
        switch self {
        case .docked: "已停靠"
        case .floating: "浮动"
        case .carousel: "轮播"
        }
    }
}

enum DeskToolbarSize: String, CaseIterable {
    case small, standard, large, extraLarge

    var title: String {
        switch self {
        case .small: "小"
        case .standard: "默认"
        case .large: "大"
        case .extraLarge: "特大"
        }
    }

    var points: CGFloat {
        switch self {
        case .small: 44
        case .standard: 48
        case .large: 54
        case .extraLarge: 62
        }
    }

    var buttonStyle: VNCHUDButtonStyle {
        VNCHUDButtonStyle(size: CGSize(width: points, height: points), symbolPointSize: points * 0.38)
    }
}

enum DeskToolbarButton: String, CaseIterable {
    case escape, tab, shift, control, option, command, arrows, home, end, pageUp, pageDown, functions, edit, shortcuts, password, spacer, dictation, screenshot
    case enter, up, down, left, right
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    var functionNumber: Int? { rawValue.first == "f" ? Int(rawValue.dropFirst()) : nil }
    var supportsRepeat: Bool {
        switch self {
        case .tab, .enter, .up, .down, .left, .right, .pageUp, .pageDown: true
        default: false
        }
    }

    static let standard = "escape,tab,dictation,shift,control,option,command,arrows,edit,functions,shortcuts"
    var available: Bool {
        if #available(iOS 26, *) { return true }
        return self != .dictation
    }
    static func buttons(in stored: String) -> [Self] {
        stored.split(separator: ",").compactMap { Self(rawValue: String($0)) }.filter(\.available)
    }

    var title: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .arrows: "方向键"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .functions: "功能键"
        case .edit: "编辑"
        case .shortcuts: "远程快捷命令"
        case .password: "输入用户密码"
        case .spacer: "间距"
        case .dictation: "听写"
        case .screenshot: "保存屏幕快照"
        case .enter: "Return"
        case .up: "向上"
        case .down: "向下"
        case .left: "向左"
        case .right: "向右"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12: rawValue.uppercased()
        }
    }

    var symbol: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .shift: "shift"
        case .control: "control"
        case .option: "option"
        case .command: "command"
        case .arrows: "arrow.up.and.down.and.arrow.left.and.right"
        case .home: "arrow.up.left"
        case .end: "arrow.down.right"
        case .pageUp: "arrow.up.to.line"
        case .pageDown: "arrow.down.to.line"
        case .functions: "function"
        case .edit: "scissors"
        case .shortcuts: "command.square"
        case .password: "key"
        case .spacer: "arrow.left.and.right"
        case .dictation: "mic"
        case .screenshot: "camera"
        case .enter: "return"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12: "function"
        }
    }

    var modifier: VNCKeyboardModifiers? {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        default: nil
        }
    }

    var keysym: UInt32? {
        switch self {
        case .escape: KeyboardInputHandler.keysymEscape
        case .tab: KeyboardInputHandler.keysymTab
        case .home: KeyboardInputHandler.keysymHome
        case .end: KeyboardInputHandler.keysymEnd
        case .pageUp: KeyboardInputHandler.keysymPageUp
        case .pageDown: KeyboardInputHandler.keysymPageDown
        case .enter: KeyboardInputHandler.keysymReturn
        case .up: KeyboardInputHandler.keysymUp
        case .down: KeyboardInputHandler.keysymDown
        case .left: KeyboardInputHandler.keysymLeft
        case .right: KeyboardInputHandler.keysymRight
        default: functionNumber.map { KeyboardInputHandler.keysymF1 + UInt32($0 - 1) }
        }
    }
}

@MainActor @Observable final class DeskToolbarState {
    let keyboard = VNCKeyboardCapture()
    var visible = true
    var expanded = true
    var anchor = CGPoint(x: 0.78, y: 0.75)
    var page = 0
    private(set) var locked: VNCKeyboardModifiers = []
    private(set) var dimmed = false
    @ObservationIgnored private var lastModifier: VNCKeyboardModifiers?
    @ObservationIgnored private var lastPress = ContinuousClock.now
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var restoreVisibility: Task<Void, Never>?

    init() {
        keyboard.onSupplementalModifiersConsumed = { [weak self] in self?.consume() }
    }

    func press(_ modifier: VNCKeyboardModifiers, now: ContinuousClock.Instant = .now) {
        if locked.contains(modifier) {
            locked.remove(modifier)
            keyboard.supplementalModifiers.remove(modifier)
            lastModifier = nil
        } else if lastModifier == modifier && now - lastPress <= .milliseconds(420) {
            locked.insert(modifier)
            keyboard.supplementalModifiers.insert(modifier)
            lastModifier = nil
        } else {
            if keyboard.supplementalModifiers.contains(modifier) { keyboard.supplementalModifiers.remove(modifier) }
            else { keyboard.supplementalModifiers.insert(modifier) }
            lastModifier = modifier
        }
        lastPress = now
    }

    func consume() {
        keyboard.supplementalModifiers = locked
        lastModifier = nil
    }

    func reset() {
        locked = []
        consume()
        keyboard.softwareKeyboardRequested = false
        brighten()
    }

    func noteRemoteActivity() {
        lastActivity = .now
        guard !dimmed else { return }
        dimmed = true
        // One task follows the most recent input, even during a continuous pointer drag.
        restoreVisibility = Task { [weak self] in
            while let deadline = self?.lastActivity.advanced(by: .milliseconds(850)), .now < deadline {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
            }
            self?.dimmed = false
            self?.restoreVisibility = nil
        }
    }

    func brighten() {
        restoreVisibility?.cancel()
        restoreVisibility = nil
        dimmed = false
    }

    func handle(_ action: RemotePencilAction, at position: CGPoint, style: DeskToolbarStyle) {
        switch action {
        case .toggleToolbar:
            if !visible, style == .carousel { anchor = position }
            visible.toggle()
        case .toggleExpandedToolbar where style == .floating:
            visible = true
            expanded.toggle()
        default:
            break
        }
    }
}

struct InteractiveDesktop: View {
    let desktop: RemoteDesktopView
    let session: VNCSession
    let controls: VNCDesktopControls
    let bar: DeskToolbarState
    let chooseMonitor: (VNCMonitorSelection) -> Void
    let startDictation: () -> Void
    let captureScreenshot: () -> Void
    @AppStorage("toolbar.style") private var style = DeskToolbarStyle.docked
    @AppStorage("toolbar.size") private var size = DeskToolbarSize.standard
    @AppStorage("toolbar.buttons") private var order = DeskToolbarButton.standard
    @AppStorage("toolbar.keyboardTrailing") private var keyboardTrailing = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: CGPoint?

    private var buttons: [DeskToolbarButton] { DeskToolbarButton.buttons(in: order) }

    private var keyboardEdgeSwipe: ((CGPoint, UIView) -> Void)? {
        guard bar.keyboard.softwareKeyboardRequested, style == .docked || bar.expanded else { return nil }
        return { point, view in controls.movePointerToBottomEdge(at: point, in: view) }
    }

    var body: some View {
        desktop
            .hidesHUD(!bar.visible)
            .onPencilToolbarAction { action, point in bar.handle(action, at: point, style: style) }
            .hudAccessory(isEnabled: style != .carousel, docksToBottom: style == .docked,
                          providesKeyboardButton: true,
                          onUpwardSwipe: keyboardEdgeSwipe,
                          buttonStyle: { _ in size.buttonStyle }) { width in
                if style == .docked || bar.expanded { strip(width: width) }
            } beside: { dimensions in
                if style == .floating {
                    Button { bar.expanded.toggle() } label: {
                        Image(systemName: bar.expanded ? "chevron.right" : "chevron.left")
                            .frame(width: dimensions.size.width, height: dimensions.size.height)
                    }
                    .accessibilityLabel(bar.expanded ? "折叠工具栏" : "展开工具栏")
                    .accessibilityIdentifier("toolbar.expand")
                    .contextMenu {
                        if !bar.expanded {
                            Button("显示键盘") { bar.keyboard.softwareKeyboardRequested = true }
                            Menu("远程快捷命令") { remoteCommands }
                            Button("文件传输") { controls.toggleFileTransfers() }
                            Button("断开连接", role: .destructive) { session.requestUserDisconnect() }
                        }
                    }
                }
            }
            .floatingHUD(isEnabled: style == .carousel) { menu, available in carousel(menu: menu, in: available) }
            .overlay(alignment: .bottomTrailing) {
                if !bar.visible {
                    Button { bar.visible = true } label: {
                        Image(systemName: "ellipsis.rectangle").frame(width: 44, height: 44)
                    }
                    .background(.regularMaterial, in: Circle())
                    .padding(8).accessibilityLabel("显示工具栏")
                    .accessibilityIdentifier("toolbar.show")
                }
            }
            .onChange(of: order) { _, _ in bar.page = 0 }
            .onDisappear { bar.reset() }
    }

    private func strip(width: CGFloat) -> some View {
        let trailingWidth = size.points * (style == .floating ? 2 : 1)
        return HStack(spacing: 0) {
            if !keyboardTrailing { keyboardButton }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in commandButton(button) }
                }
            }
            .scrollIndicators(.hidden)
            if keyboardTrailing { keyboardButton }
            Color.clear.frame(width: trailingWidth).allowsHitTesting(false)
        }
        .frame(width: min(width, max(trailingWidth + size.points, size.points * CGFloat(buttons.count + 1) + trailingWidth)),
               height: size.points)
    }

    private var keyboardButton: some View {
        Button { bar.keyboard.softwareKeyboardRequested.toggle() } label: { icon("keyboard", active: bar.keyboard.softwareKeyboardRequested) }
            .accessibilityLabel("键盘").accessibilityIdentifier("toolbar.keyboard")
    }

    @ViewBuilder private func commandButton(_ button: DeskToolbarButton) -> some View {
        if let modifier = button.modifier {
            Button { bar.press(modifier) } label: {
                icon(button.symbol, active: bar.keyboard.supplementalModifiers.contains(modifier))
                    .overlay(alignment: .bottom) {
                        if bar.locked.contains(modifier) { Capsule().frame(width: 15, height: 2).padding(.bottom, 5) }
                    }
            }
            .accessibilityLabel(button.title)
            .accessibilityValue(bar.locked.contains(modifier) ? "已锁定" : bar.keyboard.supplementalModifiers.contains(modifier) ? "已选中" : "")
            .accessibilityIdentifier("toolbar." + button.rawValue)
        } else if let keysym = button.keysym, button.supportsRepeat {
            RepeatKeyButton(symbol: button.symbol, title: button.title, points: size.buttonStyle.symbolPointSize,
                            identifier: "toolbar." + button.rawValue, timing: bar.keyboard.keyRepeat) {
                let modifiers = bar.keyboard.supplementalModifiers
                return { send(keysym, additional: modifiers) }
            }
            .frame(width: size.points, height: size.points)
        } else if let keysym = button.keysym {
            Button { send(keysym) } label: {
                if button.functionNumber != nil {
                    Text(verbatim: button.title).font(.body.weight(.medium)).frame(width: size.points, height: size.points)
                } else { icon(button.symbol) }
            }
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar." + button.rawValue)
        } else if button == .dictation {
            Button(action: startDictation) { icon(button.symbol) }
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar.dictation")
        } else if button == .screenshot {
            Button(action: captureScreenshot) { icon(button.symbol) }
                .accessibilityLabel(button.title).accessibilityIdentifier("toolbar.screenshot")
        } else if button == .spacer {
            Spacer().frame(width: size.points / 2).accessibilityHidden(true)
        } else if button == .password {
            Button { controls.requestPasswordPrompt() } label: { icon(button.symbol) }
                .disabled(!session.canSendLoginPassword).accessibilityLabel(button.title)
        } else {
            Menu {
                switch button {
                case .arrows:
                    Button("向上") { send(KeyboardInputHandler.keysymUp) }
                    Button("向下") { send(KeyboardInputHandler.keysymDown) }
                    Button("向左") { send(KeyboardInputHandler.keysymLeft) }
                    Button("向右") { send(KeyboardInputHandler.keysymRight) }
                case .functions:
                    ForEach(1...12, id: \.self) { number in
                        Button("F\(number)") { send(KeyboardInputHandler.keysymF1 + UInt32(number - 1)) }
                    }
                case .edit:
                    Button("撤销") { edit("z") }
                    Button("重做") { session.serverUsesAppleModifierConvention ? edit("z", shift: true) : edit("y") }
                    Button("剪切") { edit("x") }
                    Button("拷贝") { edit("c") }
                    Button("粘贴") { edit("v") }
                    Button("全选") { edit("a") }
                case .shortcuts:
                    remoteCommands
                default: EmptyView()
                }
            } label: { icon(button.symbol) }
            .accessibilityLabel(button.title).accessibilityIdentifier("toolbar." + button.rawValue)
        }
    }

    @ViewBuilder private var remoteCommands: some View {
        RemoteCommandsMenu(session: session) {
            bar.keyboard.noteExternalInput()
            bar.consume()
        }
        if session.selectableMonitorIDs.count > 1 {
            Divider()
            MonitorMenu(session: session, select: chooseMonitor)
        }
    }

    private func edit(_ character: Character, shift: Bool = false) {
        var modifier: VNCKeyboardModifiers = session.serverUsesAppleModifierConvention ? .command : .control
        if shift { modifier.insert(.shift) }
        send(KeyboardInputHandler.keysymForCharacter(character), additional: modifier)
    }

    private func send(_ key: UInt32, additional: VNCKeyboardModifiers = []) {
        guard session.connectionState.isConnected else { return }
        let handler = KeyboardInputHandler(sendKeyEvent: { session.sendKeyEvent(downFlag: $0, key: $1) },
                                           usesAppleModifierConvention: { session.serverUsesAppleModifierConvention })
        bar.keyboard.noteExternalInput()
        if handler.handleKeysymTap(key, supplementalModifiers: bar.keyboard.supplementalModifiers.union(additional)) { bar.consume() }
    }

    private func icon(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size.buttonStyle.symbolPointSize, weight: active ? .bold : .medium))
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .frame(width: size.points, height: size.points)
            .contentShape(Rectangle())
    }

    private func carousel(menu: AnyView, in available: CGSize) -> some View {
        let ordered: [DeskToolbarButton?] = buttons.filter { $0 != .spacer }.map(Optional.some)
        let entries = keyboardTrailing ? ordered + [nil] : [nil] + ordered
        let pages = max(1, (entries.count + 5) / 6)
        let first = min(bar.page, pages - 1) * 6
        let visible = Array(entries.dropFirst(first).prefix(6))
        let radius = min(size.points * 1.26, max(0, (min(available.width, available.height) - size.points) / 2))
        let diameter = radius * 2 + size.points
        let limit = diameter / 2
        let center = CGPoint(x: max(limit, min(available.width - limit, bar.anchor.x * available.width)),
                             y: max(limit, min(available.height - limit, bar.anchor.y * available.height)))
        return TouchOnlyToolbar { translation in
            guard let translation else { dragStart = nil; return }
            guard available.width > 0, available.height > 0 else { return }
            if dragStart == nil { bar.brighten(); dragStart = center }
            guard let start = dragStart else { return }
            bar.anchor = CGPoint(x: max(limit, min(available.width - limit, start.x + translation.width)) / available.width,
                                 y: max(limit, min(available.height - limit, start.y + translation.height)) / available.height)
        } content: {
            carouselButtons(menu: menu, visible: visible, pages: pages, radius: radius)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .opacity(bar.dimmed && !reduceTransparency ? 0.32 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: bar.dimmed)
        .position(center)
    }

    private func carouselButtons(menu: AnyView, visible: [DeskToolbarButton?], pages: Int, radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(.regularMaterial)
            menu
            ForEach(visible.indices, id: \.self) { index in
                let count = visible.count + (pages > 1 ? 1 : 0)
                let angle = CGFloat(index) * 2 * .pi / CGFloat(count) - .pi / 2
                Group { if let button = visible[index] { commandButton(button) } else { keyboardButton } }
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            if pages > 1 {
                let angle = CGFloat(visible.count) * 2 * .pi / CGFloat(visible.count + 1) - .pi / 2
                Button { bar.page = (bar.page + 1) % pages } label: { icon("ellipsis") }
                    .accessibilityLabel("下一组按钮").accessibilityIdentifier("toolbar.next")
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
    }
}

#endif
