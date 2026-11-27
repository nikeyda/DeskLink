#if !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

struct ToolbarPreferences: View {
    @AppStorage("toolbar.style") private var style = DeskToolbarStyle.docked
    @AppStorage("toolbar.size") private var size = DeskToolbarSize.standard
    @AppStorage("toolbar.buttons") private var stored = DeskToolbarButton.standard
    @AppStorage("toolbar.keyboardTrailing") private var keyboardTrailing = false
    @AppStorage("toolbar.twoFingerToggle") private var twoFingerToggle = true
    @State private var adding = false
    @State private var selected: Set<DeskToolbarButton> = []
    private var buttons: [DeskToolbarButton] { DeskToolbarButton.buttons(in: stored) }

    var body: some View {
        List {
            Section {
                Picker("样式", selection: $style) {
                    ForEach(DeskToolbarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("toolbar.style.setting")
                Picker("按钮大小", selection: $size) {
                    ForEach(DeskToolbarSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("键盘按钮位置", selection: $keyboardTrailing) {
                    Text("起始位置").tag(false)
                    Text("末尾位置").tag(true)
                }
                Toggle("双指双击切换全屏幕", isOn: $twoFingerToggle)
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
        stored = items.map(\.rawValue).joined(separator: ",")
    }
}

struct PencilPreferences: View {
    @AppStorage("toolbar.style") private var style = DeskToolbarStyle.docked
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
            if style == .floating || selection.wrappedValue == .toggleExpandedToolbar {
                Text("展开或折叠工具栏").tag(RemotePencilAction.toggleExpandedToolbar).disabled(style != .floating)
            }
        }
        .accessibilityIdentifier(title == "双击" ? "pencil.doubleTap" : "pencil.squeeze")
    }
}
#endif
