import Foundation
import Observation
import AppKit
import CryptoKit
import UniformTypeIdentifiers

@MainActor @Observable
final class StoreModel {
    var catalog = Catalog()
    var message = "Choose your iCloud Drive repository folder to begin."
    var isBusy = false
    private(set) var hasLoadedCatalog = false
    private var didRestoreSettings = false
    var repositoryURL: URL?
    var icons: [String: NSImage] = [:]

    var installationURL: URL?
    var installationStatus: [String: String] = [:]
    private let installationBookmarkKey = "PrivateAppStore.InstallationBookmark"

    private let bookmarkKey = "PrivateAppStore.RepositoryBookmark"

    func load() async {
        guard !didRestoreSettings else { return }
        didRestoreSettings = true
        // Restore permissions only. Repository contents are read by Refresh.
        if let data = UserDefaults.standard.data(forKey: installationBookmarkKey) {
            var stale = false
            installationURL = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            if stale { installationURL = nil }
        }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            if stale { message = "Repository permission expired. Select the folder again."; return }
            repositoryURL = url
            hasLoadedCatalog = false
            catalog = Catalog()
            icons = [:]
            message = "Repository selected. Click Refresh to load applications."
        } catch { message = error.localizedDescription }
        guard repositoryURL != nil else { return }
        do { try await Task.sleep(for: .seconds(2)) }
        catch { return }
        await refresh()
    }

    func selectRepository() async {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            repositoryURL = url
            hasLoadedCatalog = false
            catalog = Catalog()
            icons = [:]
            message = "Repository selected. Click Refresh to load applications."
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        guard !isBusy else { return }
        guard let url = repositoryURL else { return }
        isBusy = true
        defer { isBusy = false }
        message = "Loading repository…"
        await Task.yield()
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        do {
            let catalogURL = url.appendingPathComponent("catalog.json")
            if FileManager.default.fileExists(atPath: catalogURL.path) {
                let data = try Data(contentsOf: catalogURL)
                catalog = try JSONDecoder.storeDecoder.decode(Catalog.self, from: data)
            } else {
                catalog = Catalog()
                try FileManager.default.createDirectory(at: url.appendingPathComponent("Apps"), withIntermediateDirectories: true)
                try saveCatalog(at: url)
            }
            if !catalog.defaultGroupsInitialized {
                seedDefaultGroups()
                try saveCatalog(at: url)
            }
            loadIcons(at: url)
            hasLoadedCatalog = true
            message = "Repository ready — \(catalog.applications.count) applications."
        } catch { message = "Unable to read repository: \(error.localizedDescription)" }
    }

    func publish(preferredGroupID: UUID? = nil) async {
        guard !isBusy else { return }
        guard let repositoryURL else { message = "Select a repository first."; return }
        guard hasLoadedCatalog else { message = "Click Refresh before publishing applications."; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle, .zip]
        panel.prompt = "Publish"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let groups = sortedGroups
        guard !groups.isEmpty else { message = "Create a group before importing an application."; return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        picker.addItems(withTitles: groups.map(\.name))
        if let index = groups.firstIndex(where: { $0.id == preferredGroupID }) {
            picker.selectItem(at: index)
        }
        let alert = NSAlert()
        alert.messageText = "Assign Application Group"
        alert.informativeText = "Choose the group for \(source.lastPathComponent)."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let groupID = groups[picker.indexOfSelectedItem].id
        let sourceAllowed = source.startAccessingSecurityScopedResource()
        let repoAllowed = repositoryURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAllowed { source.stopAccessingSecurityScopedResource() }
            if repoAllowed { repositoryURL.stopAccessingSecurityScopedResource() }
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let isApp = source.pathExtension.lowercased() == "app"
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: temp) }
            if isApp {
                try await run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, temp.path])
            } else {
                try FileManager.default.copyItem(at: source, to: temp)
            }
            let unpack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: unpack) }
            let bundleURL: URL
            if isApp { bundleURL = source }
            else {
                // ZIP metadata must be supplied by the publisher's embedded .app.
                try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
                try await run("/usr/bin/ditto", ["-x", "-k", temp.path, unpack.path])
                let apps = findApps(in: unpack)
                guard apps.count == 1, let found = apps.first else { throw StoreError.invalidPackage }
                bundleURL = found
            }
            guard let bundle = Bundle(url: bundleURL),
                  let id = bundle.bundleIdentifier,
                  let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  !id.isEmpty, !version.isEmpty else { throw StoreError.missingMetadata }
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? bundleURL.deletingPathExtension().lastPathComponent
            guard !id.contains("/"), !version.contains("/"), id != "..", version != ".." else {
                throw StoreError.missingMetadata
            }
            let relative = "Apps/\(id)/\(version).zip"
            let destination = repositoryURL.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.alreadyPublished }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let hash = try SHA256.hash(data: Data(contentsOf: temp)).map { String(format: "%02x", $0) }.joined()
            var committed = false
            let iconPath = "Apps/\(id)/\(UUID().uuidString).png"
            let iconURL = repositoryURL.appendingPathComponent(iconPath)
            defer {
                if !committed {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.removeItem(at: iconURL)
                }
            }
            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            guard let tiff = icon.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw StoreError.iconExtraction
            }
            try png.write(to: iconURL, options: .atomic)
            try FileManager.default.copyItem(at: temp, to: destination)
            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            let release = AppRecord.Release(version: version, build: build, packagePath: relative, packageType: .zip, sha256: hash, sizeBytes: size)
            var updated = catalog
            if let index = updated.applications.firstIndex(where: { $0.id == id }) {
                updated.applications[index].releases.append(release)
                updated.applications[index].groupID = groupID
                updated.applications[index].iconPath = iconPath
            } else {
                updated.applications.append(AppRecord(id: id, name: name, summary: "", origin: .personal, iconPath: iconPath, groupID: groupID, releases: [release]))
            }
            let old = catalog
            catalog = updated
            do { try saveCatalog(at: repositoryURL) }
            catch { catalog = old; throw error }
            committed = true
            icons[id] = icon
            message = "Published \(name) \(version)."
        } catch { message = "Publish failed: \(error.localizedDescription)" }
    }

    private func loadIcons(at root: URL) {
        var loaded: [String: NSImage] = [:]
        for app in catalog.applications {
            guard let path = app.iconPath,
                  let image = NSImage(contentsOf: root.appendingPathComponent(path)) else { continue }
            loaded[app.id] = image
        }
        icons = loaded
    }

    private func seedDefaultGroups() {
        let defaults: [(String, String)] = [
            ("Tools", "hammer.fill"),
            ("Finance", "creditcard.fill"),
            ("Utilities", "wrench.and.screwdriver.fill"),
            ("Developer", "chevron.left.forwardslash.chevron.right"),
            ("Office", "doc.text.fill"),
            ("AI", "brain.head.profile")
        ]
        for (name, symbol) in defaults where !catalog.groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            catalog.groups.append(AppGroup(name: name, sortOrder: catalog.groups.count, symbol: symbol))
        }
        catalog.defaultGroupsInitialized = true
    }

    var sortedGroups: [AppGroup] {
        catalog.groups.sorted { $0.sortOrder < $1.sortOrder }
    }

    func addGroup(_ name: String, symbol: String = "folder") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateCatalog { catalog in
            catalog.groups.append(AppGroup(name: trimmed, sortOrder: catalog.groups.count, symbol: symbol))
        }
    }

    func renameGroup(_ id: UUID, to name: String, symbol: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateCatalog { catalog in
            guard let index = catalog.groups.firstIndex(where: { $0.id == id }) else { return }
            catalog.groups[index].name = trimmed
            if let symbol { catalog.groups[index].symbol = symbol }
        }
    }

    func deleteGroup(_ id: UUID) {
        mutateCatalog { catalog in
            catalog.groups.removeAll { $0.id == id }
            for index in catalog.applications.indices where catalog.applications[index].groupID == id {
                catalog.applications[index].groupID = nil
            }
            for index in catalog.groups.indices { catalog.groups[index].sortOrder = index }
        }
    }

    func assign(_ appID: String, to groupID: UUID?) {
        mutateCatalog { catalog in
            guard let index = catalog.applications.firstIndex(where: { $0.id == appID }) else { return }
            catalog.applications[index].groupID = groupID
        }
    }

    func deleteAppFromCatalog(_ appID: String) {
        guard !isBusy, hasLoadedCatalog, let repositoryURL,
              let app = catalog.applications.first(where: { $0.id == appID }) else { return }
        let allowed = repositoryURL.startAccessingSecurityScopedResource()
        defer { if allowed { repositoryURL.stopAccessingSecurityScopedResource() } }
        let previous = catalog
        catalog.applications.removeAll { $0.id == appID }
        do {
            try saveCatalog(at: repositoryURL)
            icons.removeValue(forKey: appID)
            installationStatus.removeValue(forKey: appID)
            message = "Deleted \(app.name) from the catalog."
        } catch {
            catalog = previous
            message = "Unable to delete application: \(error.localizedDescription)"
        }
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        mutateCatalog { catalog in
            var groups = catalog.groups.sorted { $0.sortOrder < $1.sortOrder }
            guard let source = groups.firstIndex(where: { $0.id == id }) else { return }
            let destination = min(max(source + offset, 0), groups.count - 1)
            guard source != destination else { return }
            let moved = groups.remove(at: source)
            groups.insert(moved, at: destination)
            for index in groups.indices { groups[index].sortOrder = index }
            catalog.groups = groups
        }
    }

    private func mutateCatalog(_ edit: (inout Catalog) -> Void) {
        guard !isBusy else { return }
        guard hasLoadedCatalog else { message = "Click Refresh before editing groups."; return }
        guard let repositoryURL else { message = "Choose a repository first."; return }
        let allowed = repositoryURL.startAccessingSecurityScopedResource()
        defer { if allowed { repositoryURL.stopAccessingSecurityScopedResource() } }
        let old = catalog
        edit(&catalog)
        do {
            try saveCatalog(at: repositoryURL)
            message = "Groups saved to iCloud Drive."
        } catch {
            catalog = old
            message = "Unable to save groups: \(error.localizedDescription)"
        }
    }

    func chooseInstallationFolder() throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose Applications or your personal Applications folder to authorize installation."
        panel.prompt = "Use for Installation"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: installationBookmarkKey)
        installationURL = url
        return url
    }

    func installedVersion(for app: AppRecord) -> String? {
        guard let folder = installationURL else { return nil }
        let allowed = folder.startAccessingSecurityScopedResource()
        defer { if allowed { folder.stopAccessingSecurityScopedResource() } }
        for entry in findApps(in: folder) {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == app.id else { continue }
            return info["CFBundleShortVersionString"] as? String
        }
        return nil
    }

    func install(_ app: AppRecord) async {
        guard !isBusy else { return }
        guard let repositoryURL, let release = app.latestRelease else { return }
        let allowed = repositoryURL.startAccessingSecurityScopedResource()
        defer { if allowed { repositoryURL.stopAccessingSecurityScopedResource() } }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let targetDirectory = try installationURL ?? chooseInstallationFolder() else { return }
            let targetAllowed = targetDirectory.startAccessingSecurityScopedResource()
            defer { if targetAllowed { targetDirectory.stopAccessingSecurityScopedResource() } }
            installationStatus[app.id] = "Checking package…"
            message = "Checking \(app.name)…"
            await Task.yield()
            guard release.packageType == .zip else { throw StoreError.unsupportedPackage }
            let archive = repositoryURL.appendingPathComponent(release.packagePath)
            guard FileManager.default.fileExists(atPath: archive.path) else { throw StoreError.notDownloaded }
            let digest = try SHA256.hash(data: Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw StoreError.checksumMismatch }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            installationStatus[app.id] = "Extracting…"
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, temp.path])
            let apps = findApps(in: temp)
            guard apps.count == 1, let extracted = apps.first,
                  Bundle(url: extracted)?.bundleIdentifier == app.id else { throw StoreError.invalidPackage }
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            guard let extractedBundle = Bundle(url: extracted),
                  extractedBundle.bundleIdentifier == app.id,
                  extractedBundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version
            else { throw StoreError.invalidPackage }

            let existing = findApps(in: targetDirectory).first { url in
                guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
                return info["CFBundleIdentifier"] as? String == app.id
            }
            if existing != nil, NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty == false {
                throw StoreError.applicationRunning
            }
            let target = existing ?? targetDirectory.appendingPathComponent(extracted.lastPathComponent)
            let staged = targetDirectory.appendingPathComponent(".private-store-\(UUID().uuidString).app")
            installationStatus[app.id] = "Installing…"
            await Task.yield()
            try FileManager.default.copyItem(at: extracted, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }

            if let existing {
                let backup = targetDirectory.appendingPathComponent(".private-store-backup-\(UUID().uuidString).app")
                try FileManager.default.moveItem(at: existing, to: backup)
                do {
                    try FileManager.default.moveItem(at: staged, to: target)
                    try verifyInstallation(at: target, appID: app.id, release: release)
                    try? FileManager.default.removeItem(at: backup)
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: backup, to: existing)
                    throw error
                }
                message = "Updated \(app.name) to \(release.version)."
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
                do { try verifyInstallation(at: target, appID: app.id, release: release) }
                catch {
                    try? FileManager.default.removeItem(at: target)
                    throw error
                }
                message = "Installed \(app.name) in \(targetDirectory.path)."
            }
            installationStatus[app.id] = "Installed \(release.version) — verified"
        } catch {
            installationStatus[app.id] = "Failed: \(error.localizedDescription)"
            message = "Install failed: \(error.localizedDescription)"
        }
    }

    private func verifyInstallation(at url: URL, appID: String, release: AppRecord.Release) throws {
        // Read the plist directly to avoid Bundle caching after replacing an app.
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == appID,
              info["CFBundleShortVersionString"] as? String == release.version,
              release.build == nil || info["CFBundleVersion"] as? String == release.build else {
            throw StoreError.verificationFailed
        }
    }

    private func saveCatalog(at root: URL) throws {
        let data = try JSONEncoder.storeEncoder.encode(catalog)
        try data.write(to: root.appendingPathComponent("catalog.json"), options: .atomic)
    }

    private func findApps(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "app" {
                result.append(url)
                enumerator.skipDescendants()
            }
        }
        return result
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A file avoids pipe-buffer deadlocks while retaining command diagnostics.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        process.standardError = log
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw NSError(domain: "PrivateAppStore.Archive", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Archive command failed (\(status)). \(details)"
            ])
        }
    }
}

private enum StoreError: LocalizedError {
    case verificationFailed
    case iconExtraction
    case invalidPackage, missingMetadata, alreadyPublished, unsupportedPackage, notDownloaded, checksumMismatch, alreadyInstalled, applicationRunning, archiveFailure
    var errorDescription: String? {
        switch self {
        case .verificationFailed: "The installed application does not match the published identifier, version, or build."
        case .iconExtraction: "Unable to extract the application icon."
        case .invalidPackage: "Package does not contain a valid application."
        case .missingMetadata: "Application needs a bundle identifier and version."
        case .alreadyPublished: "This version is already published."
        case .unsupportedPackage: "This installer type is not yet supported."
        case .notDownloaded: "Package is not available locally yet. Wait for iCloud Drive to download it."
        case .checksumMismatch: "Package checksum does not match the catalog."
        case .alreadyInstalled: "Application already exists in ~/Applications."
        case .applicationRunning: "Quit the application before updating it."
        case .archiveFailure: "Unable to process ZIP archive."
        }
    }
}

private extension JSONEncoder {
    static var storeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
private extension JSONDecoder {
    static var storeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
