import SwiftUI
import UniformTypeIdentifiers

private let vncLocationType = UTType(filenameExtension: "vncloc") ?? UTType(importedAs: "com.apple.vnc-internet-location")

struct HiddenSidebarItems: OptionSet {
    static let preferenceKey = "library.hiddenSidebarItems"

    let rawValue: Int
    static let nearby = Self(rawValue: 1 << 0)
    static let tailscale = Self(rawValue: 1 << 1)
    static let links = Self(rawValue: 1 << 2)
    static let recent = Self(rawValue: 1 << 3)
    static let favorites = Self(rawValue: 1 << 4)
    static let linkSection: Self = [.links, .recent, .favorites]
}

private enum CollectionPage: Hashable {
    case all, recent, links, favorites, nearby, tailscale, folder(String), linkFolder(String)

    var title: Text {
        switch self {
        case .all: Text("所有连接")
        case .recent: Text("最近连接")
        case .links: Text("所有链接")
        case .favorites: Text("收藏")
        case .nearby: Text("附近")
        case .tailscale: Text("Tailscale")
        case .folder(let name), .linkFolder(let name): Text(verbatim: name)
        }
    }

    var folderScope: LibraryFolderScope {
        switch self {
        case .links, .recent, .linkFolder: .links
        default: .custom
        }
    }

    var sidebarItem: HiddenSidebarItems {
        switch self {
        case .nearby: .nearby
        case .tailscale: .tailscale
        case .links, .linkFolder: .links
        case .recent: .recent
        case .favorites: .favorites
        case .all, .folder: []
        }
    }

    func displayedFolder(for computer: Computer) -> String? {
        switch self {
        case .folder, .linkFolder: nil
        case .recent: computer.linkFolder ?? computer.folder
        default: computer.folder(in: folderScope)
        }
    }

    static func folder(_ name: String, in scope: LibraryFolderScope) -> Self {
        scope == .links ? .linkFolder(name) : .folder(name)
    }
}

struct ArchiveDocument: FileDocument {
    static let type = UTType(exportedAs: "local.nikey.desklink.archive", conformingTo: .json)
    static let screensType = UTType(importedAs: "com.edovia.screens5.archive", conformingTo: .data)
    static let readableContentTypes = [type, .json, screensType]
    static let writableContentTypes = [type, screensType]
    private(set) var fromScreens = false
    private(set) var outputType = Self.type
    let data: Data
    init(data: Data, exportType: UTType = Self.type) {
        self.data = data
        self.outputType = exportType
    }
    init(contentsOf url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var read: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
            read = Result { try Data(contentsOf: location) }
        }
        if let error { throw error }
        guard let read else { throw CocoaError(.fileReadUnknown) }
        try self.init(importing: read.get(), fromScreens: url.pathExtension.lowercased() == "screens")
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(importing: data, fromScreens: configuration.contentType == Self.screensType)
    }
    private init(importing data: Data, fromScreens: Bool) throws {
        self.fromScreens = fromScreens
        self.data = fromScreens ? try ScreensArchive.convert(data).encoded() : data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType == outputType else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return FileWrapper(regularFileWithContents: data)
    }
}

struct LibraryWindow: View {
    @Bindable var library: ConnectionLibrary
    let preferences: UserDefaults
    let pasteboard: UIPasteboard
    var initialComputer: UUID?
    @State private var page: CollectionPage? = .all
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var nearby = NearbyComputers()
    @Environment(TailnetDirectory.self) private var tailnet
    @Environment(AppLock.self) private var privacy
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var search = ""
    @State private var editor: EditorRequest?
    @State private var activeSession: SessionRequest?
    @State private var showFolder = false
    @State private var renamingFolder: String?
    @State private var deletingFolder: String?
    @State private var editingFolderScope = LibraryFolderScope.custom
    @State private var folderName = ""
    @State private var importFile = false
    @State private var exportFile = false
    @State private var exportDocument: ArchiveDocument?
    @State private var pendingArchives: [ArchiveDocument] = []
    @State private var importResult: ArchiveImportResult?
    @State private var deletion: Computer?
    @State private var ownError: String?
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage(HiddenSidebarItems.preferenceKey) private var hiddenSidebarItems = 0
    @AppStorage("library.savedOrder") private var savedOrder = ComputerOrder.manual
    @AppStorage("library.favoriteOrder") private var favoriteOrder = ComputerOrder.manual
    @AppStorage("library.recentOrder") private var recentOrder = ComputerOrder.lastConnected
    @AppStorage("library.linkOrder") private var linkOrder = ComputerOrder.lastConnected
    @State private var sessionToEdit: Computer?
    @State private var queuedRoute: ConnectionRoute?
    @State private var openedInitialComputer = false
    @State private var settings = false
    @State private var downloads = false
    @State private var historicalReport: ConnectionReport?
    @State private var selectedPreview: SavedDesktopPreview?

    private var hiddenItems: HiddenSidebarItems { HiddenSidebarItems(rawValue: hiddenSidebarItems) }

    private var order: Binding<ComputerOrder> {
        switch page {
        case .recent: $recentOrder
        case .links, .linkFolder: $linkOrder
        case .favorites: $favoriteOrder
        default: $savedOrder
        }
    }

    private var entries: [Computer] {
        let list: [Computer]
        switch page {
        case .recent:
            list = library.archive.computers.filter { $0.lastConnected != nil }
        case .links:
            list = library.archive.computers.filter(\.isLink)
        case .linkFolder(let name):
            list = library.archive.computers.filter { $0.isLink && $0.linkFolder == name }
        case .favorites:
            list = library.archive.computers.filter { $0.saved && $0.favorite }
        case let .folder(folder):
            list = library.archive.computers.filter { $0.saved && $0.folder == folder }
        default:
            list = library.archive.computers.filter(\.saved)
        }
        let matching = search.isEmpty ? list : list.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.endpoint.address.localizedCaseInsensitiveContains(search)
        }
        return order.wrappedValue.arrange(matching)
    }

    var body: some View {
        Group {
            if let activeSession {
                SessionScreen(request: activeSession, library: library, preferences: preferences, pasteboard: pasteboard) { edit in
                    sessionToEdit = edit ? activeSession.computer : nil
                    self.activeSession = nil
                }
                .id(activeSession.id)
            } else {
                NavigationSplitView {
                    List(selection: $page) {
                        if !hiddenItems.contains(.nearby) {
                            Label("附近", systemImage: "bonjour").tag(CollectionPage.nearby)
                        }
                        if !hiddenItems.contains(.tailscale) {
                            Label("Tailscale", systemImage: "network").tag(CollectionPage.tailscale)
                        }
                        if !hiddenItems.isSuperset(of: .linkSection) {
                            Section("链接") {
                                if !hiddenItems.contains(.links) {
                                    Label("所有链接", systemImage: "link").tag(CollectionPage.links)
                                        .accessibilityIdentifier("library.links")
                                }
                                if !hiddenItems.contains(.recent) {
                                    Label("最近连接", systemImage: "clock").tag(CollectionPage.recent)
                                }
                                if !hiddenItems.contains(.favorites) {
                                    Label("收藏", systemImage: "star").tag(CollectionPage.favorites)
                                        .accessibilityIdentifier("library.favorites")
                                }
                                if !hiddenItems.contains(.links) { folderRows(in: .links) }
                            }
                        }
                        Section("自定义连接") {
                            Label("所有连接", systemImage: "rectangle.on.rectangle").tag(CollectionPage.all)
                                .accessibilityIdentifier("library.all")
                            folderRows(in: .custom)
                        }
                    }
                    .navigationTitle(AppName.display)
                    .navigationSplitViewColumnWidth(min: 165, ideal: 205, max: 290)
                } detail: {
                    collection
                        .navigationTitle((page ?? .all).title)
                        .searchable(text: $search, prompt: "搜索")
                        .toolbar { libraryToolbar }
                }
                .onChange(of: hiddenSidebarItems, initial: true) {
                    if let page, !hiddenItems.isDisjoint(with: page.sidebarItem) {
                        self.page = .all
                    }
                }
                #if targetEnvironment(macCatalyst)
                .focusedSceneValue(\.deskLinkLibrary, libraryMenu)
                #endif
                .onAppear {
                    importPendingArchives()
                    if !openedInitialComputer, let initialComputer {
                        openedInitialComputer = true
                        present(.saved(initialComputer))
                    } else if let sessionToEdit {
                        editor = EditorRequest(purpose: .connect, computer: sessionToEdit)
                        self.sessionToEdit = nil
                    } else if let queuedRoute {
                        self.queuedRoute = nil
                        present(queuedRoute)
                    }
                }
            }
        }
        .sheet(item: $editor) { request in
            ConnectionEditor(request: request, library: library, openLink: { value in
                let route: ConnectionRoute
                if value.lowercased().hasPrefix("desklink://"), let url = URL(string: value) {
                    route = try ConnectionRoute(url: url)
                } else { route = .desktopLink(try DesktopLink(text: value)) }
                editor = try editorRequest(for: route)
            }) { offer in
                editor = nil
                activeSession = offer
            }
        }
        .sheet(isPresented: $settings) { ApplicationPreferences(preferences: preferences) }
        .sheet(isPresented: $downloads) { DownloadsView() }
        .sheet(item: $historicalReport) { report in
            if !privacy.locked { ConnectionDetails(report: report, historical: true) }
        }
        .sheet(item: $selectedPreview) { selection in
            if !privacy.locked {
                NavigationStack {
                    Group {
                        if let current = library.previews[selection.computerID] {
                            SavedDesktopImage(preview: current).padding()
                        }
                    }
                    .navigationTitle("上次桌面快照")
                    .toolbar { Button("关闭") { selectedPreview = nil } }
                }
            }
        }
        .onChange(of: privacy.locked) { _, locked in
            if locked { historicalReport = nil; selectedPreview = nil }
        }
        .alert(renamingFolder == nil ? "新建文件夹" : "重命名文件夹", isPresented: $showFolder) {
            TextField("名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let original = renamingFolder {
                    if library.renameFolder(original, to: name, in: editingFolderScope), page == .folder(original, in: editingFolderScope) {
                        page = .folder(name, in: editingFolderScope)
                    }
                } else if library.addFolder(name, in: editingFolderScope) { page = .folder(name, in: editingFolderScope) }
            }
            .disabled(!canSaveFolder)
        }
        .alert("删除文件夹", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), presenting: deletingFolder) { name in
            Button("取消", role: .cancel) {}
            Button("删除文件夹", role: .destructive) {
                if library.removeFolder(name, in: editingFolderScope), page == .folder(name, in: editingFolderScope) {
                    page = editingFolderScope == .links ? .links : .all
                }
            }
        } message: { _ in
            Text(editingFolderScope == .links ? "文件夹中的链接会保留在「所有链接」。" : "文件夹中的连接会移至「所有连接」。")
        }
        .alert("删除", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { item in
            Button("删除", role: .destructive) { library.remove(item) }
            Button("取消", role: .cancel) {}
        } message: { item in Text(item.displayName) }
        .alert("连接失败", isPresented: Binding(get: { ownError != nil || library.errorMessage != nil || nearby.errorMessage != nil }, set: { _ in
            ownError = nil; library.errorMessage = nil; nearby.errorMessage = nil
        })) {
            Button("关闭", role: .cancel) {}
        } message: { Text(ownError ?? library.errorMessage ?? nearby.errorMessage ?? "") }
        .alert("导入完成", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("完成") {}
        } message: {
            if let result = importResult {
                let counts = "新增连接 \(result.connections) 个，新增文件夹 \(result.folders) 个，跳过重复连接 \(result.duplicates) 个。"
                let note = result.importedScreens ? "\n已迁移连接地址、账户、分组及适用的 SSH 和观察设置。首次连接时请核对显示与输入偏好，并按需提供密码或密钥。" : ""
                Text(counts + note)
            }
        }
        .onChange(of: privacy.locked) { _, locked in
            guard !locked else { return }
            importPendingArchives()
            if activeSession == nil, let queuedRoute {
                self.queuedRoute = nil
                present(queuedRoute)
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: ArchiveDocument.readableContentTypes + [vncLocationType]) { result in
            do {
                let url = try result.get()
                if url.pathExtension.lowercased() == "vncloc" {
                    present(.desktopLink(try InternetLocation.read(url)))
                } else {
                    try receiveArchive(at: url)
                }
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch { ownError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportFile, document: exportDocument, contentType: exportDocument?.outputType ?? ArchiveDocument.type, defaultFilename: AppName.display) {
            if case .failure(let error) = $0 { ownError = error.localizedDescription }
            exportDocument = nil
        }
        .onOpenURL { url in
            do {
                if url.isFileURL && ["desklink", "screens"].contains(url.pathExtension.lowercased()) {
                    try receiveArchive(at: url)
                    return
                }
                let route: ConnectionRoute
                if url.isFileURL && url.pathExtension.lowercased() == "vncloc" {
                    route = .desktopLink(try InternetLocation.read(url))
                } else { route = try ConnectionRoute(url: url) }
                if activeSession != nil { queuedRoute = route } else { present(route) }
            } catch { ownError = error.localizedDescription }
        }
    }

    private func receiveArchive(at url: URL) throws {
        pendingArchives.append(try ArchiveDocument(contentsOf: url))
        importPendingArchives()
    }

    private func importPendingArchives() {
        guard !privacy.locked, activeSession == nil, !pendingArchives.isEmpty else { return }
        let files = pendingArchives
        pendingArchives.removeAll()
        var total = importResult ?? ArchiveImportResult()
        for file in files {
            do {
                guard let result = try library.importArchive(file.data) else { continue }
                total.connections += result.connections
                total.folders += result.folders
                total.duplicates += result.duplicates
                total.importedScreens = total.importedScreens || file.fromScreens
                importResult = total
            } catch { ownError = error.localizedDescription }
        }
    }

    @ViewBuilder private var collection: some View {
        if page == .tailscale {
            TailnetView(directory: tailnet, search: search, select: open, save: saveDiscovered)
        } else if page == .nearby {
            let results = nearby.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            Group {
                if let error = nearby.searchError {
                    ContentUnavailableView {
                        Label("无法查找附近的电脑", systemImage: "network.slash")
                    } description: {
                        if nearby.needsLocalNetworkAccess {
                            Text("请在系统设置中允许远程随航访问本地网络，再重新查找。")
                        } else {
                            Text(verbatim: error.localizedDescription)
                        }
                    } actions: {
                        Button("重新查找") { nearby.retry() }
                            .accessibilityIdentifier("nearby.retry")
                    }
                } else if results.isEmpty && !search.isEmpty && !nearby.entries.isEmpty {
                    emptySearch
                } else if results.isEmpty {
                    ContentUnavailableView("未找到附近的电脑", systemImage: "bonjour")
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(results) { entry in
                                Button {
                                    nearby.select(entry) { editor = EditorRequest(purpose: .connect, computer: $0) }
                                } label: { ConnectionTile(name: entry.name, address: nil, symbol: "bonjour") }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("保存到连接库") { nearby.select(entry, completion: saveDiscovered) }
                                }
                            }
                        }.padding(24)
                    }.background(Color(uiColor: .systemGroupedBackground))
                }
            }.onAppear { nearby.start() }.onDisappear { nearby.stop() }
        } else if entries.isEmpty {
            emptyCollection
        } else if listLayout {
            let visible = entries
            List {
                ForEach(visible) { item in
                    HStack {
                        Button { open(item) } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.displayName)
                                        if item.endpoint.address != item.displayName {
                                            Text(item.endpoint.address).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: { Image(systemName: "desktopcomputer") }
                                Spacer(minLength: 8)
                                if let folder = (page ?? .all).displayedFolder(for: item) {
                                    Label(folder, systemImage: "folder")
                                        .labelStyle(.titleAndIcon).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("library.computer." + item.id.uuidString)
                        .contextMenu { actions(for: item) }
                        resumeVideoButton(for: item)
                    }
                }
                .onMove(perform: page != .recent && order.wrappedValue == .manual ? { sources, destination in
                    var ids = visible.map(\.id)
                    ids.move(fromOffsets: sources, toOffset: destination)
                    _ = library.reorder(ids)
                } : nil)
            }.listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(entries) { item in
                        gridButton(item) {
                            ConnectionTile(name: item.displayName, address: item.endpoint.address,
                                           symbol: item.screensOperatingSystem == 5 ? "cpu" : "desktopcomputer",
                                           folder: (page ?? .all).displayedFolder(for: item),
                                           favorite: item.favorite, usesSSH: item.ssh != nil, preview: library.previews[item.id])
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) { resumeVideoButton(for: item) }
                    }
                }.padding(24)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
    }

    @ViewBuilder private func resumeVideoButton(for item: Computer) -> some View {
        if library.videoRetryDate(for: item) != nil {
            Button { library.resumeStreaming(for: item) } label: {
                Label("立即恢复流畅视频与音频", systemImage: "bolt.slash").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .help("立即恢复流畅视频与音频")
            .accessibilityIdentifier("library.resumeVideo." + item.id.uuidString)
        }
    }

    @ViewBuilder private func gridButton<Content: View>(_ item: Computer, @ViewBuilder label: () -> Content) -> some View {
        let button = Button { open(item) } label: { label() }
            .accessibilityIdentifier("library.computer." + item.id.uuidString)
            .contextMenu { actions(for: item) }
        if page != .recent, order.wrappedValue == .manual {
            button.draggable(item.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard ids.count == 1, let source = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    return library.move(source, to: item.id, within: Set(entries.map(\.id)))
                }
        } else { button }
    }

    private var gridColumns: [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        return [GridItem(.adaptive(minimum: 212, maximum: 340), spacing: 14, alignment: .topLeading)]
    }

    private var emptySearch: some View {
        ContentUnavailableView {
            Label("未找到匹配的连接", systemImage: "magnifyingglass")
        } actions: { Button("清除搜索") { search = "" } }
    }

    @ViewBuilder private var emptyCollection: some View {
        if !search.isEmpty {
            emptySearch
        } else {
            switch page ?? .all {
            case .favorites:
                ContentUnavailableView {
                    Label("还没有收藏的电脑", systemImage: "star")
                } description: {
                    Text("在电脑的菜单中选择「添加到收藏」，它就会显示在这里。")
                } actions: {
                    Button("所有连接") { page = .all }.accessibilityIdentifier("library.empty.all")
                }
            case .recent:
                ContentUnavailableView {
                    Label("没有最近连接", systemImage: "clock")
                } description: {
                    Text("成功连接过的电脑会显示在这里。")
                } actions: { Button("快速连接") { editor = EditorRequest(purpose: .quick) } }
            case .all:
                ContentUnavailableView {
                    Text("添加第一台电脑").font(.title2.weight(.semibold))
                } description: {
                    Text("保存常用电脑，或输入地址连接一次。")
                } actions: {
                    Button("新建连接", action: newEntry).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("library.empty.new")
                    Button("快速连接") { editor = EditorRequest(purpose: .quick) }
                        .accessibilityIdentifier("library.empty.quick")
                }
            case .folder:
                ContentUnavailableView {
                    Label("文件夹中没有连接", systemImage: "folder")
                } actions: { Button("新建连接", action: newEntry) }
            default:
                ContentUnavailableView {
                    Label("没有连接链接", systemImage: "link")
                } actions: { Button("快速连接") { editor = EditorRequest(purpose: .quick) } }
            }
        }
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { editor = EditorRequest(purpose: .quick) } label: { Label("快速连接", systemImage: "bolt") }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("library.quick")
            Button { newEntry() } label: { Label("新建连接", systemImage: "plus") }
                .accessibilityIdentifier("library.new")
            Button { downloads = true } label: { Label("文件传输", systemImage: "arrow.up.arrow.down") }
                .accessibilityIdentifier("library.transfers")
            Menu {
                Button {
                    editingFolderScope = page?.folderScope ?? .custom
                    renamingFolder = nil
                    folderName = ""
                    showFolder = true
                } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                Button { listLayout.toggle() } label: { Label(listLayout ? "网格" : "列表", systemImage: listLayout ? "square.grid.2x2" : "list.bullet") }
                if page != .nearby, page != .tailscale {
                    Menu("排序") {
                        Picker("排序", selection: order) {
                            ForEach(ComputerOrder.allCases.filter { page != .recent || $0 != .manual }, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }.pickerStyle(.inline)
                    }
                }
                Divider()
                Button("导入") { importFile = true }
                Button("导出") {
                    do { exportDocument = try ArchiveDocument(data: library.archive.encoded()); exportFile = true }
                    catch { ownError = error.localizedDescription }
                }
                Button("将已保存连接导出为 Screens 归档") {
                    do {
                        let knownMacs = library.archive.computers.filter { library.lastReport(for: $0.id)?.version == "RFB 3.889" }
                        let shares = preferences.object(forKey: "connection.sharedClipboard") as? Bool ?? true
                        let bytes = try ScreensArchive.export(library.archive, knownMacs: Set(knownMacs.map(\.id)), sharedClipboard: shares,
                                                              preferences: preferences)
                        exportDocument = ArchiveDocument(data: bytes, exportType: ArchiveDocument.screensType)
                        exportFile = true
                    } catch { ownError = error.localizedDescription }
                }
                Divider()
                Button("设置") { settings = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("library.more")
        }
    }

    private func folderRows(in scope: LibraryFolderScope) -> some View {
        ForEach(library.archive.folders(in: scope), id: \.self) { name in
            Label(name, systemImage: "folder").tag(CollectionPage.folder(name, in: scope))
                .accessibilityIdentifier((scope == .links ? "library.linkFolder." : "library.folder.") + name)
                .contextMenu {
                    Button("重命名文件夹") {
                        editingFolderScope = scope
                        folderName = name
                        renamingFolder = name
                        showFolder = true
                    }
                    Button("删除文件夹", role: .destructive) {
                        editingFolderScope = scope
                        deletingFolder = name
                    }
                }
        }
    }

    @ViewBuilder private func actions(for item: Computer) -> some View {
        Button("连接") { open(item) }
        Menu("连接模式") {
            Button("以标准模式连接") { open(item, quality: .standard) }
            Button("以高性能模式连接") { open(item, quality: .adaptive) }
            if library.videoRetryDate(for: item) != nil {
                Button("立即恢复流畅视频与音频") { library.resumeStreaming(for: item) }
            }
        }
        if supportsMultipleWindows {
            Button("在新窗口中连接") { openWindow(value: item.id) }
        }
        if item.lastConnected != nil {
            Button("上次连接信息") {
                if let report = library.lastReport(for: item.id) { historicalReport = report }
                else { ownError = "此设备尚无这台电脑的连接信息。" }
            }
        }
        Button(item.saved ? "编辑连接" : "保存") { editor = EditorRequest(purpose: .edit, computer: item) }
        if let preview = library.previews[item.id] {
            Button("查看上次桌面快照") { selectedPreview = preview }
            Button("清除桌面快照", role: .destructive) { library.clearPreview(for: item.id) }
        }
        if item.saved {
            Button("复制连接") { editor = EditorRequest(purpose: .new, computer: library.archive.duplicate(of: item)) }
        }
        Button(item.favorite ? "取消收藏" : "添加到收藏") {
            var copy = item
            copy.saved = true
            copy.favorite.toggle()
            library.save(copy)
        }
        if item.saved, !library.archive.folders.isEmpty {
            Menu("移到文件夹") {
                Button("所有连接") { var copy = item; copy.folder = nil; library.save(copy) }
                ForEach(library.archive.folders, id: \.self) { name in
                    Button(name) { var copy = item; copy.folder = name; library.save(copy) }
                }
            }
        }
        if item.isLink, !library.archive.folders(in: .links).isEmpty {
            Menu("移到链接文件夹") {
                Button("所有链接") { var copy = item; copy.linkFolder = nil; library.save(copy) }
                ForEach(library.archive.folders(in: .links), id: \.self) { name in
                    Button(name) { var copy = item; copy.linkFolder = name; library.save(copy) }
                }
            }
        }
        if let url = ConnectionRoute.sharing(item.endpoint, sshPort: item.ssh?.port, server: item.ssh?.server) {
            ShareLink(item: url) { Label("链接", systemImage: "square.and.arrow.up") }
        }
        Button("删除", role: .destructive) { deletion = item }
    }

    #if targetEnvironment(macCatalyst)
    private var libraryMenu: MacLibraryMenuActions? {
        guard !privacy.locked, editor == nil, !settings, !downloads, !importFile, !exportFile,
              !showFolder, deletingFolder == nil, deletion == nil else { return nil }
        return MacLibraryMenuActions(quickConnect: { editor = EditorRequest(purpose: .quick) },
                                     create: newEntry, settings: { settings = true }, transfers: { downloads = true })
    }
    #endif

    private var canSaveFolder: Bool {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && (name == renamingFolder || !library.archive.folders(in: editingFolderScope).contains(name))
    }

    private func newEntry() {
        if case let .folder(name) = page { editor = EditorRequest(purpose: .new, folder: name) }
        else { editor = EditorRequest(purpose: .new) }
    }
    private func open(_ entry: Computer) {
        guard !privacy.locked else { queuedRoute = .saved(entry.id); return }
        if entry.saved || entry.lastConnected != nil,
           let request = try? SessionRequest.remembered(for: entry, synchronize: preferences.bool(forKey: "credentials.synchronize")) {
            editor = nil
            activeSession = request
        } else {
            editor = EditorRequest(purpose: .connect, computer: entry)
        }
    }

    private func saveDiscovered(_ entry: Computer) {
        let existing = library.existingComputer(matching: entry)
        editor = EditorRequest(purpose: existing?.saved == true ? .edit : .new, computer: existing ?? entry)
    }

    private func open(_ entry: Computer, quality: PictureQuality) {
        var copy = entry
        var display = copy.display(for: .current)
        display.quality = quality
        if quality == .adaptive {
            if display.layout == .single { display.matchWindow = true }
        } else {
            if display.layout == .virtualPair { display.layout = .single }
            display.fixedDesktop = nil
            display.matchWindow = false
        }
        copy.setDisplay(display, for: .current)
        open(copy)
    }

    private func present(_ route: ConnectionRoute) {
        guard !privacy.locked else { queuedRoute = route; return }
        do {
            let request = try editorRequest(for: route)
            if case .saved = route, let entry = request.computer { open(entry) }
            else { editor = request }
        } catch { ownError = error.localizedDescription }
    }

    private func editorRequest(for route: ConnectionRoute) throws -> EditorRequest {
        switch route {
        case .quick: return EditorRequest(purpose: .quick)
        case .address(let endpoint): return EditorRequest(purpose: .quick, initialAddress: endpoint.address)
        case .secureAddress(let endpoint, let port, let server):
            return EditorRequest(purpose: .quick, initialAddress: endpoint.address, initialSSHPort: port, initialSSHServer: server)
        case .desktopLink(let link):
            #if targetEnvironment(macCatalyst)
            return try EditorRequest.from(link, in: library.archive, allowUnsavedHost: true)
            #else
            return try EditorRequest.from(link, in: library.archive, allowUnsavedHost: false)
            #endif
        case .saved(let id):
            guard let entry = library.archive.computers.first(where: { $0.id == id }) ?? tailnet.computerForWidget(id) else {
                throw EditorRequest.LinkError.missingComputer
            }
            return EditorRequest(purpose: .connect, computer: entry)
        }
    }
}
