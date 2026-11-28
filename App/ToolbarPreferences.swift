#if !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

struct ToolbarPreferences: View {
    @State private var device = ToolbarProfileDevice.current

    var body: some View {
        ToolbarProfileEditor(device: $device).id(device)
    }
}

private struct ToolbarProfileEditor: View {
    @Binding private var device: ToolbarProfileDevice
    private var profile: ToolbarProfile
    @AppStorage("toolbar.twoFingerToggle") private var twoFingerToggle = true
    @AppStorage("toolbar.portraitSplit") private var portraitSplit = false
    @AppStorage("toolbar.splitControls") private var splitControls = DeskSplitControls.sideBySide
    @State private var adding = false
    @State private var selected: Set<DeskToolbarButton> = []
    private var buttons: [DeskToolbarButton] { DeskToolbarButton.buttons(in: profile.buttons) }

    init(device: Binding<ToolbarProfileDevice>) {
        _device = device
        profile = ToolbarProfile(device: device.wrappedValue)
    }

    var body: some View {
        List {
            Section {
                Picker("设备", selection: $device) {
                    ForEach(ToolbarProfileDevice.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbar.profileDevice")
            }
            Section {
                Picker("样式", selection: Binding(get: { profile.style }, set: { profile.style = $0 })) {
                    ForEach(DeskToolbarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("toolbar.style.setting")
                Picker("按钮大小", selection: Binding(get: { profile.size }, set: { profile.size = $0 })) {
                    ForEach(DeskToolbarSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("toolbar.size.setting")
                Picker("键盘按钮位置", selection: Binding(get: { profile.keyboardTrailing }, set: { profile.keyboardTrailing = $0 })) {
                    Text("起始位置").tag(false)
                    Text("末尾位置").tag(true)
                }
                .accessibilityIdentifier("toolbar.keyboardPosition.setting")
                Toggle("双指双击切换全屏幕", isOn: $twoFingerToggle)
            }
            Section("分屏控制") {
                Toggle("上下分屏", isOn: $portraitSplit)
                    .accessibilityIdentifier("toolbar.portraitSplit")
                Picker("控制区布局", selection: $splitControls) {
                    ForEach(DeskSplitControls.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("toolbar.splitControls")
            }
            Section("工具栏按钮") {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Label(button.preferenceTitle, systemImage: button.symbol)
                }
                .onDelete { offsets in
                    var items = buttons
                    items.remove(atOffsets: offsets)
                    save(items)
                }
                .onMove { offsets, destination in
                    var items = buttons
                    items.move(fromOffsets: offsets, toOffset: destination)
                    save(items)
                }
                Button("添加按钮…") { selected = []; adding = true }
                    .accessibilityIdentifier("toolbar.addButton")
            }
        }
        .navigationTitle("互动工具栏")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                List(DeskToolbarButton.allCases.filter { $0.available && ($0 == .spacer || !buttons.contains($0)) }, id: \.self) { button in
                    Button {
                        if !selected.insert(button).inserted { selected.remove(button) }
                    } label: {
                        HStack {
                            Label(button.preferenceTitle, systemImage: button.symbol)
                            Spacer()
                            if selected.contains(button) { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityAddTraits(selected.contains(button) ? .isSelected : [])
                    .accessibilityIdentifier("toolbar.add." + button.rawValue)
                }
                .navigationTitle("工具栏按钮")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            save(buttons + DeskToolbarButton.allCases.filter { selected.contains($0) })
                            adding = false
                        }.disabled(selected.isEmpty)
                    }
                }
            }
        }
    }

    private func save(_ items: [DeskToolbarButton]) {
        profile.buttons = items.map(\.rawValue).joined(separator: ",")
    }
}

struct PencilPreferences: View {
    private var toolbar = ToolbarProfile(device: .current)
    @AppStorage("pencil.doubleTap") private var doubleTap = RemotePencilAction.secondaryClick
    @AppStorage("pencil.squeeze") private var squeeze = RemotePencilAction.toggleToolbar

    var body: some View {
        Section("Apple Pencil") {
            picker("双击", selection: $doubleTap)
            picker("挤压", selection: $squeeze)
        }
    }

    private func picker(_ title: LocalizedStringKey, selection: Binding<RemotePencilAction>) -> some View {
        Picker(title, selection: selection) {
            Text("无").tag(RemotePencilAction.none)
            Text("右键点击（次级点击）").tag(RemotePencilAction.secondaryClick)
            Text("中键点击").tag(RemotePencilAction.middleClick)
            Text("切换工具栏的可见性").tag(RemotePencilAction.toggleToolbar)
            if toolbar.style == .floating || selection.wrappedValue == .toggleExpandedToolbar {
                Text("展开或折叠工具栏").tag(RemotePencilAction.toggleExpandedToolbar).disabled(toolbar.style != .floating)
            }
        }
        .accessibilityIdentifier(title == "双击" ? "pencil.doubleTap" : "pencil.squeeze")
    }
}
#endif
