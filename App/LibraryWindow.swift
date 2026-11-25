import SwiftUI
import UniformTypeIdentifiers

private let vncLocationType = UTType(filenameExtension: "vncloc") ?? UTType(importedAs: "com.apple.vnc-internet-location")

private enum CollectionPage: Hashable {
    case all, links, favorites, nearby, tailscale, folder(String)

    var title: String {
        switch self {
        case .all: "所有连接"
        case .links: "最近连接"
        case .favorites: "收藏"
        case .nearby: "附近"
        case .tailscale: "Tailscale"
        case .folder(let name): name
        }
    }
}

struct ArchiveDocument: FileDocument {
    static let type = UTType(exportedAs: "local.nikey.desklink.archive", conformingTo: .json)
    static let readableContentTypes = [type, .json]
    let data: Data
    init(data: Data) { self.data = data }
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
        self.data = try read.get()
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LibraryWindow: View {
    @Bindable var library: ConnectionLibrary
    let preferences: UserDefaults
    let pasteboard: UIPasteboard
    var initialComputer: UUID?
    @State private var page: CollectionPage? = .all
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
    @State private var folderName = ""
    @State private var importFile = false
    @State private var exportFile = false
    @State private var exportDocument: ArchiveDocument?
    @State private var pendingArchives: [Data] = []
    @State private var importResult: ArchiveImportResult?
    @State private var deletion: Computer?
    @State private var ownError: String?
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.savedOrder") private var savedOrder = ComputerOrder.manual
    @AppStorage("library.favoriteOrder") private var favoriteOrder = ComputerOrder.manual
    @AppStorage("library.recentOrder") private var recentOrder = ComputerOrder.lastConnected
    @State private var sessionToEdit: Computer?
    @State private var queuedRoute: ConnectionRoute?
    @State private var openedInitialComputer = false
    @State private var settings = false
    @State private var downloads = false
    @State private var historicalReport: ConnectionReport?

    private var order: Binding<ComputerOrder> {
        switch page {
        case .links: $recentOrder
        case .favorites: $favoriteOrder
        default: $savedOrder
        }
    }

    private var entries: [Computer] {
        let list: [Computer]
        switch page {
        case .links:
            list = library.archive.computers.filter { $0.lastConnected != nil }
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
                        Label("附近", systemImage: "bonjour").tag(CollectionPage.nearby)
                        Label("Tailscale", systemImage: "network").tag(CollectionPage.tailscale)
                        Section("链接") {
                            Label("最近连接", systemImage: "clock").tag(CollectionPage.links)
                            Label("收藏", systemImage: "star").tag(CollectionPage.favorites)
                        }
                        Section("自定义连接") {
                            Label("所有连接", systemImage: "rectangle.on.rectangle").tag(CollectionPage.all)
                            ForEach(library.archive.folders, id: \.self) { name in
                                Label(name, systemImage: "folder").tag(CollectionPage.folder(name))
                                    .contextMenu {
                                        Button("重命名文件夹") {
                                            folderName = name
                                            renamingFolder = name
                                            showFolder = true
                                        }
                                        Button("删除文件夹", role: .destructive) { deletingFolder = name }
                                    }
                            }
                        }
                    }
                    .navigationTitle("屏幕连线")
                    .navigationSplitViewColumnWidth(min: 165, ideal: 205, max: 290)
                } detail: {
                    collection
                        .navigationTitle((page ?? .all).title)
                        .searchable(text: $search, prompt: "搜索")
                        .toolbar { libraryToolbar }
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
        .onChange(of: privacy.locked) { _, locked in if locked { historicalReport = nil } }
        .alert(renamingFolder == nil ? "新建文件夹" : "重命名文件夹", isPresented: $showFolder) {
            TextField("名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let original = renamingFolder {
                    if library.renameFolder(original, to: name), page == .folder(original) { page = .folder(name) }
                } else if library.addFolder(name) { page = .folder(name) }
            }
            .disabled(!canSaveFolder)
        }
        .alert("删除文件夹", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), presenting: deletingFolder) { name in
            Button("取消", role: .cancel) {}
            Button("删除文件夹", role: .destructive) {
                if library.removeFolder(name), page == .folder(name) { page = .all }
            }
        } message: { _ in
            Text("文件夹中的连接会移至「所有连接」。")
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
                Text("新增连接 \(result.connections) 个，新增文件夹 \(result.folders) 个，跳过重复连接 \(result.duplicates) 个。")
            }
        }
        .onChange(of: privacy.locked) { _, locked in if !locked { importPendingArchives() } }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [ArchiveDocument.type, .json, vncLocationType]) { result in
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
        .fileExporter(isPresented: $exportFile, document: exportDocument, contentType: ArchiveDocument.type, defaultFilename: "DeskLink") {
            if case .failure(let error) = $0 { ownError = error.localizedDescription }
            exportDocument = nil
        }
        .onOpenURL { url in
            do {
                if url.isFileURL && url.pathExtension.lowercased() == "desklink" {
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
        pendingArchives.append(try ArchiveDocument(contentsOf: url).data)
        importPendingArchives()
    }

    private func importPendingArchives() {
        guard !privacy.locked, activeSession == nil, !pendingArchives.isEmpty else { return }
        let files = pendingArchives
        pendingArchives.removeAll()
        var total = importResult ?? ArchiveImportResult()
        for file in files {
            do {
                guard let result = try library.importArchive(file) else { continue }
                total.connections += result.connections
                total.folders += result.folders
                total.duplicates += result.duplicates
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
                if results.isEmpty {
                    ContentUnavailableView("未找到附近的电脑", systemImage: "bonjour")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 220))], spacing: 20) {
                            ForEach(results) { entry in
                                Button {
                                    nearby.select(entry) { editor = EditorRequest(purpose: .connect, computer: $0) }
                                } label: { tile(name: entry.name, subtitle: nil, symbol: "desktopcomputer") }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("保存到连接库") { nearby.select(entry, completion: saveDiscovered) }
                                }
                            }
                        }.padding(24)
                    }
                }
            }.onAppear { nearby.start() }.onDisappear { nearby.stop() }
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? "没有连接" : "未找到匹配的连接", systemImage: search.isEmpty ? "desktopcomputer" : "magnifyingglass")
            } actions: {
                if search.isEmpty { Button("快速连接") { editor = EditorRequest(purpose: .quick) } }
            }
        } else if listLayout {
            let visible = entries
            List {
                ForEach(visible) { item in
                    Button { open(item) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName)
                                Text(item.endpoint.address).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "desktopcomputer") }
                    }
                    .accessibilityIdentifier("library.computer." + item.id.uuidString)
                    .contextMenu { actions(for: item) }
                    .overlay(alignment: .trailing) { resumeVideoButton(for: item) }
                }
                .onMove(perform: page != .links && order.wrappedValue == .manual ? { sources, destination in
                    var ids = visible.map(\.id)
                    ids.move(fromOffsets: sources, toOffset: destination)
                    _ = library.reorder(ids)
                } : nil)
            }.listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 220))], spacing: 20) {
                    ForEach(entries) { item in
                        gridButton(item) {
                            tile(name: item.displayName, subtitle: item.endpoint.address, symbol: "desktopcomputer")
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) { resumeVideoButton(for: item) }
                    }
                }.padding(24)
            }
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
        if page != .links, order.wrappedValue == .manual {
            button.draggable(item.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard ids.count == 1, let source = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    return library.move(source, to: item.id, within: Set(entries.map(\.id)))
                }
        } else { button }
    }

    private func tile(name: String, subtitle: String?, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity).frame(height: 74)
            Text(name).font(.headline).lineLimit(2)
            if let subtitle, subtitle != name { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 125, alignment: .top)
        .contentShape(Rectangle())
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
                Button { renamingFolder = nil; folderName = ""; showFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                Button { listLayout.toggle() } label: { Label(listLayout ? "网格" : "列表", systemImage: listLayout ? "square.grid.2x2" : "list.bullet") }
                if page != .nearby, page != .tailscale {
                    Menu("排序") {
                        Picker("排序", selection: order) {
                            ForEach(ComputerOrder.allCases.filter { page != .links || $0 != .manual }, id: \.self) { option in
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
                Divider()
                Button("设置") { settings = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("library.more")
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
        return !name.isEmpty && (name == renamingFolder || !library.archive.folders.contains(name))
    }

    private func newEntry() {
        if case let .folder(name) = page { editor = EditorRequest(purpose: .new, folder: name) }
        else { editor = EditorRequest(purpose: .new) }
    }
    private func open(_ entry: Computer) { editor = EditorRequest(purpose: .connect, computer: entry) }

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
        do { editor = try editorRequest(for: route) }
        catch { ownError = error.localizedDescription }
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
            guard let entry = library.archive.computers.first(where: { $0.id == id }) else {
                throw EditorRequest.LinkError.missingComputer
            }
            return EditorRequest(purpose: .connect, computer: entry)
        }
    }
}
