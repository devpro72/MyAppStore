import SwiftUI

private enum SidebarSelection: Hashable {
    case all, uncategorized, group(UUID)
}

struct StoreView: View {
    @Environment(StoreModel.self) private var store
    @State private var selection: SidebarSelection? = .all
    @State private var showingAddGroup = false
    @State private var editingGroup: AppGroup?
    @State private var deletingGroup: AppGroup?
    @State private var deletingApp: AppRecord?
    @State private var showingDeleteApp = false
    @State private var groupName = ""
    @State private var groupSymbol = "folder"

    private var visibleApps: [AppRecord] {
        switch selection ?? .all {
        case .all: return store.catalog.applications
        case .uncategorized: return store.catalog.applications.filter { app in
            guard let id = app.groupID else { return true }
            return !store.catalog.groups.contains { $0.id == id }
        }
        case .group(let id): return store.catalog.applications.filter { $0.groupID == id }
        }
    }

    private var title: String {
        switch selection ?? .all {
        case .all: return "All Applications"
        case .uncategorized: return "Uncategorized"
        case .group(let id): return store.catalog.groups.first { $0.id == id }?.name ?? "Applications"
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("All Applications", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.all)
                Label("Uncategorized", systemImage: "tray")
                    .tag(SidebarSelection.uncategorized)

                Section {
                    ForEach(store.sortedGroups) { group in
                        Label(group.name, systemImage: group.symbol)
                            .tag(SidebarSelection.group(group.id))
                            .contextMenu {
                                Button("Rename") {
                                    groupName = group.name
                                    groupSymbol = group.symbol
                                    editingGroup = group
                                }
                                Button("Move Up") { store.moveGroup(group.id, by: -1) }
                                Button("Move Down") { store.moveGroup(group.id, by: 1) }
                                Divider()
                                Button("Delete Group", role: .destructive) { deletingGroup = group }
                            }
                    }
                } header: {
                    HStack {
                        Text("Groups")
                        Spacer()
                        Button {
                            groupName = ""
                            groupSymbol = "folder"
                            showingAddGroup = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add Group")
                    }
                }
            }
            .navigationTitle("Private App Store")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(title).font(.largeTitle.bold())
                    Spacer()
                    Button("Choose Repository") { Task { await store.selectRepository() } }
                        .disabled(store.isBusy)
                    Button("Refresh") { Task { await store.refresh() } }
                        .disabled(store.repositoryURL == nil || store.isBusy)
                    Button("Publish App") {
                        let groupID: UUID?
                        if case .group(let id) = selection { groupID = id } else { groupID = nil }
                        Task { await store.publish(preferredGroupID: groupID) }
                    }
                        .disabled(store.repositoryURL == nil || store.isBusy)
                }
                Button("Installation Folder") {
                    do { _ = try store.chooseInstallationFolder() }
                    catch { store.message = error.localizedDescription }
                }
                .disabled(store.isBusy)
                Text(store.message).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if store.isBusy { ProgressView() }
                List(visibleApps) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = store.icons[app.id] {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.fill").resizable().scaledToFit()
                            }
                        }
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.headline)
                            Text("\(app.id) · \(app.latestRelease?.version ?? "Unknown")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let status = store.installationStatus[app.id] {
                                Text(status).font(.caption).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Uncategorized") { store.assign(app.id, to: nil) }
                            ForEach(store.sortedGroups) { group in
                                Button(group.name) { store.assign(app.id, to: group.id) }
                            }
                        } label: {
                            Label("Group", systemImage: "folder")
                        }
                        .disabled(store.repositoryURL == nil || store.isBusy)
                        let installed = store.installedVersion(for: app)
                        let latest = app.latestRelease?.version
                        let needsUpdate = installed.flatMap { version in
                            latest.map { version.compare($0, options: .numeric) == .orderedAscending }
                        } ?? false
                        if let installed {
                            Text("Installed: \(installed)").font(.caption).foregroundStyle(.secondary)
                        }
                        Button(needsUpdate ? "Update" : (installed == nil ? "Install" : "Reinstall")) {
                            Task { await store.install(app) }
                        }
                        .disabled(store.isBusy)
                    }
                    .padding(.vertical, 5)
                    .contextMenu {
                        Button("Delete from Catalog…", role: .destructive) {
                            deletingApp = app
                            showingDeleteApp = true
                        }
                        .disabled(store.isBusy || !store.hasLoadedCatalog)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 850, minHeight: 500)
        .alert("Delete from Catalog?", isPresented: $showingDeleteApp, presenting: deletingApp) { app in
            Button("Delete", role: .destructive) {
                store.deleteAppFromCatalog(app.id)
                deletingApp = nil
            }
            Button("Cancel", role: .cancel) { deletingApp = nil }
        } message: { app in
            Text("Remove \(app.name) and all its releases from the shared catalog? Installed applications and repository package files will be kept.")
        }
        .alert("New Group", isPresented: $showingAddGroup) {
            TextField("Group name", text: $groupName)
            TextField("SF Symbol (e.g. folder)", text: $groupSymbol)
            Button("Create") { store.addGroup(groupName, symbol: groupSymbol.isEmpty ? "folder" : groupSymbol) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: Binding(
            get: { editingGroup != nil },
            set: { if !$0 { editingGroup = nil } }
        )) {
            TextField("Group name", text: $groupName)
            TextField("SF Symbol (e.g. folder)", text: $groupSymbol)
            Button("Save") {
                if let group = editingGroup { store.renameGroup(group.id, to: groupName, symbol: groupSymbol.isEmpty ? "folder" : groupSymbol) }
                editingGroup = nil
            }
            Button("Cancel", role: .cancel) { editingGroup = nil }
        }
        .confirmationDialog("Delete this group? Apps will become Uncategorized.", isPresented: Binding(
            get: { deletingGroup != nil },
            set: { if !$0 { deletingGroup = nil } }
        )) {
            Button("Delete Group", role: .destructive) {
                if let group = deletingGroup {
                    store.deleteGroup(group.id)
                    if selection == .group(group.id) { selection = .uncategorized }
                }
                deletingGroup = nil
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        }
    }
}
