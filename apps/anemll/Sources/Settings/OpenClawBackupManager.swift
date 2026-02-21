import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)
struct OpenClawBackupExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }
}
#endif

struct OpenClawBackupArtifact: Sendable {
    let data: Data
    let defaultFileName: String
    let fileCount: Int
    let defaultsCount: Int
    let keychainCount: Int
}

struct OpenClawBackupRestoreResult: Sendable {
    let restoredFileCount: Int
    let restoredDefaultsCount: Int
    let restoredKeychainCount: Int
    let skippedFileTokens: [String]
}

enum OpenClawBackupError: LocalizedError {
    case invalidArchive
    case unsupportedArchiveVersion(Int)
    case unsupportedApp(String)
    case userDefaultsSerializationFailed
    case userDefaultsDeserializationFailed
    case keychainReadFailed(OSStatus)
    case compressionFailed
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "Invalid backup file."
        case let .unsupportedArchiveVersion(version):
            "Unsupported backup version: \(version)."
        case let .unsupportedApp(app):
            "Backup belongs to another app target (\(app))."
        case .userDefaultsSerializationFailed:
            "Could not export settings."
        case .userDefaultsDeserializationFailed:
            "Could not restore settings."
        case let .keychainReadFailed(status):
            "Could not read keychain items (status \(status))."
        case .compressionFailed:
            "Could not compress backup data."
        case .decompressionFailed:
            "Could not decompress backup data."
        }
    }
}

enum OpenClawBackupManager {
    private static let archiveMagic = Data("OCB1".utf8)
    private static let archiveVersion = 1
    private static let keychainServices = [
        "ai.openclaw.gateway",
        "ai.openclaw.node",
        "ai.openclaw.talk",
    ]

    private struct Archive: Codable {
        let version: Int
        let createdAtISO8601: String
        let appBundleIdentifier: String
        let appVersion: String
        let defaultsDomainPlist: Data
        let files: [ArchivedFile]
        let keychainItems: [KeychainItem]
    }

    private struct ArchivedFile: Codable, Hashable {
        let pathToken: String
        let data: Data
    }

    private struct KeychainItem: Codable, Hashable {
        let service: String
        let account: String
        let value: String
    }

    private struct RootAlias {
        let alias: String
        let url: URL
    }

    static func createBackupArtifact(now: Date = Date()) throws -> OpenClawBackupArtifact {
        let fileManager = FileManager.default
        let roots = self.roots(fileManager: fileManager)
        let files = try self.captureFiles(fileManager: fileManager, roots: roots)
        let defaultsData = try self.captureDefaults()
        let keychainItems = try self.captureKeychainItems()

        let archive = Archive(
            version: self.archiveVersion,
            createdAtISO8601: ISO8601DateFormatter().string(from: now),
            appBundleIdentifier: Bundle.main.bundleIdentifier ?? "ai.openclaw.ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            defaultsDomainPlist: defaultsData,
            files: files,
            keychainItems: keychainItems)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(archive)
        let compressed = try self.compress(encoded)

        var payload = Data()
        payload.append(self.archiveMagic)
        payload.append(compressed)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "AnemllClaw-Backup-\(formatter.string(from: now)).ocbackup"

        let defaultsCount = (try? self.decodeDefaultsDomain(defaultsData).count) ?? 0
        return OpenClawBackupArtifact(
            data: payload,
            defaultFileName: fileName,
            fileCount: files.count,
            defaultsCount: defaultsCount,
            keychainCount: keychainItems.count)
    }

    /// Peek at the archive metadata without restoring.  Returns `nil` when the
    /// payload cannot be decoded (invalid magic / compression / JSON).
    static func peekArchiveMetadata(from payload: Data) -> (bundleIdentifier: String, version: Int)? {
        guard let archive = try? self.decodeArchive(payload) else { return nil }
        return (archive.appBundleIdentifier, archive.version)
    }

    static func restoreBackupArchive(
        from payload: Data,
        ignoreBundleIDMismatch: Bool = false) throws -> OpenClawBackupRestoreResult
    {
        let archive = try self.decodeArchive(payload)
        guard archive.version == self.archiveVersion else {
            throw OpenClawBackupError.unsupportedArchiveVersion(archive.version)
        }

        let currentBundleId = Bundle.main.bundleIdentifier ?? "ai.openclaw.ios"
        if !ignoreBundleIDMismatch {
            guard archive.appBundleIdentifier == currentBundleId else {
                throw OpenClawBackupError.unsupportedApp(archive.appBundleIdentifier)
            }
        }

        let fileManager = FileManager.default
        try self.clearKnownPersistentStorage(fileManager: fileManager)

        let roots = self.roots(fileManager: fileManager)
        let rootsByAlias = Dictionary(uniqueKeysWithValues: roots.map { ($0.alias, $0.url) })

        var restoredFiles = 0
        var skippedTokens: [String] = []
        for entry in archive.files {
            guard let destination = self.url(fromToken: entry.pathToken, rootsByAlias: rootsByAlias) else {
                skippedTokens.append(entry.pathToken)
                continue
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try entry.data.write(to: destination, options: .atomic)
            restoredFiles += 1
        }

        let defaultsDomain = try self.decodeDefaultsDomain(archive.defaultsDomainPlist)
        UserDefaults.standard.setPersistentDomain(defaultsDomain, forName: currentBundleId)
        UserDefaults.standard.synchronize()

        for service in self.keychainServices {
            self.deleteAllKeychainEntries(service: service)
        }

        var restoredKeychain = 0
        for item in archive.keychainItems {
            guard self.keychainServices.contains(item.service) else { continue }
            if KeychainStore.saveString(item.value, service: item.service, account: item.account) {
                restoredKeychain += 1
            }
        }

        return OpenClawBackupRestoreResult(
            restoredFileCount: restoredFiles,
            restoredDefaultsCount: defaultsDomain.count,
            restoredKeychainCount: restoredKeychain,
            skippedFileTokens: skippedTokens)
    }

    private static func decodeArchive(_ payload: Data) throws -> Archive {
        let archiveData: Data
        if payload.starts(with: self.archiveMagic) {
            archiveData = try self.decompress(Data(payload.dropFirst(self.archiveMagic.count)))
        } else if let decoded = try? JSONDecoder().decode(Archive.self, from: payload) {
            return decoded
        } else {
            archiveData = try self.decompress(payload)
        }

        guard let archive = try? JSONDecoder().decode(Archive.self, from: archiveData) else {
            throw OpenClawBackupError.invalidArchive
        }
        return archive
    }

    private static func compress(_ data: Data) throws -> Data {
        guard let compressed = try (data as NSData).compressed(using: .lzfse) as Data? else {
            throw OpenClawBackupError.compressionFailed
        }
        return compressed
    }

    private static func decompress(_ data: Data) throws -> Data {
        guard let decompressed = try (data as NSData).decompressed(using: .lzfse) as Data? else {
            throw OpenClawBackupError.decompressionFailed
        }
        return decompressed
    }

    private static func captureDefaults() throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? "ai.openclaw.ios"
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        guard PropertyListSerialization.propertyList(domain, isValidFor: .binary) else {
            throw OpenClawBackupError.userDefaultsSerializationFailed
        }
        return try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
    }

    private static func decodeDefaultsDomain(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let domain = object as? [String: Any] else {
            throw OpenClawBackupError.userDefaultsDeserializationFailed
        }
        return domain
    }

    private static func captureKeychainItems() throws -> [KeychainItem] {
        var items: [KeychainItem] = []
        for service in self.keychainServices {
            let serviceItems = try self.readKeychainItems(service: service)
            items.append(contentsOf: serviceItems)
        }
        return items.sorted { lhs, rhs in
            if lhs.service == rhs.service {
                return lhs.account < rhs.account
            }
            return lhs.service < rhs.service
        }
    }

    private static func readKeychainItems(service: String) throws -> [KeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw OpenClawBackupError.keychainReadFailed(status)
        }

        let rows: [[String: Any]] = if let array = result as? [[String: Any]] {
            array
        } else if let one = result as? [String: Any] {
            [one]
        } else {
            []
        }

        var items: [KeychainItem] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                continue
            }
            items.append(KeychainItem(service: service, account: account, value: value))
        }
        return items
    }

    private static func deleteAllKeychainEntries(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func roots(fileManager: FileManager) -> [RootAlias] {
        var values: [RootAlias] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "documents", url: documents))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "caches", url: caches))
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "appSupport", url: appSupport))
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            values.append(RootAlias(alias: "library", url: library))
        }
        values.append(RootAlias(alias: "tmp", url: fileManager.temporaryDirectory))
        return values
    }

    private static func pathToken(for fileURL: URL, roots: [RootAlias]) -> String? {
        let standardized = fileURL.standardizedFileURL.path
        let sortedRoots = roots.sorted { lhs, rhs in
            lhs.url.standardizedFileURL.path.count > rhs.url.standardizedFileURL.path.count
        }

        for root in sortedRoots {
            let rootPath = root.url.standardizedFileURL.path
            if standardized == rootPath {
                return root.alias
            }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard standardized.hasPrefix(prefix) else { continue }
            let relative = String(standardized.dropFirst(prefix.count))
            if relative.isEmpty { continue }
            return "\(root.alias)/\(relative)"
        }
        return nil
    }

    private static func url(fromToken token: String, rootsByAlias: [String: URL]) -> URL? {
        let parts = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let alias = parts.first.map(String.init),
              let root = rootsByAlias[alias]
        else {
            return nil
        }
        guard parts.count > 1 else { return root }
        let relative = String(parts[1])
        guard !relative.contains("..") else { return nil }
        return root.appendingPathComponent(relative, isDirectory: false)
    }

    private static func captureFiles(fileManager: FileManager, roots: [RootAlias]) throws -> [ArchivedFile] {
        var tokenToData: [String: Data] = [:]

        func addFile(_ fileURL: URL) throws {
            guard self.isRegularFile(fileURL, fileManager: fileManager) else { return }
            guard let token = self.pathToken(for: fileURL, roots: roots) else { return }
            let data = try Data(contentsOf: fileURL)
            tokenToData[token] = data
        }

        func addDirectory(_ directoryURL: URL) throws {
            guard self.isDirectory(directoryURL, fileManager: fileManager) else { return }
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [],
                errorHandler: nil)
            else {
                return
            }

            for case let fileURL as URL in enumerator {
                guard self.isRegularFile(fileURL, fileManager: fileManager) else { continue }
                try addFile(fileURL)
            }
        }

        for directory in self.workspaceCandidates(fileManager: fileManager) {
            try addDirectory(directory)
        }

        let memoryPaths = self.memoryStoreCandidates(fileManager: fileManager)
        for memoryPath in memoryPaths {
            try addFile(memoryPath)
            try addFile(URL(fileURLWithPath: memoryPath.path + "-wal"))
            try addFile(URL(fileURLWithPath: memoryPath.path + "-shm"))
            let cronDirectory = memoryPath
                .deletingLastPathComponent()
                .appendingPathComponent("cron", isDirectory: true)
            try addDirectory(cronDirectory)
        }

        for pairingFile in self.telegramPairingCandidates(fileManager: fileManager) {
            try addFile(pairingFile)
        }

        for directory in self.additionalDirectoryCandidates(fileManager: fileManager) {
            try addDirectory(directory)
        }

        for file in self.additionalFileCandidates(fileManager: fileManager) {
            try addFile(file)
        }

        return tokenToData
            .map { ArchivedFile(pathToken: $0.key, data: $0.value) }
            .sorted { lhs, rhs in lhs.pathToken < rhs.pathToken }
    }

    private static func clearKnownPersistentStorage(fileManager: FileManager) throws {
        let workspaceCandidates = self.workspaceCandidates(fileManager: fileManager)
        let memoryCandidates = self.memoryStoreCandidates(fileManager: fileManager)
        let pairingCandidates = self.telegramPairingCandidates(fileManager: fileManager)
        let additionalDirectories = self.additionalDirectoryCandidates(fileManager: fileManager)
        let additionalFiles = self.additionalFileCandidates(fileManager: fileManager)

        for directory in workspaceCandidates {
            try self.removeIfExists(directory, fileManager: fileManager)
        }
        for memoryPath in memoryCandidates {
            try self.removeIfExists(memoryPath, fileManager: fileManager)
            try self.removeIfExists(URL(fileURLWithPath: memoryPath.path + "-wal"), fileManager: fileManager)
            try self.removeIfExists(URL(fileURLWithPath: memoryPath.path + "-shm"), fileManager: fileManager)
            let cronDirectory = memoryPath
                .deletingLastPathComponent()
                .appendingPathComponent("cron", isDirectory: true)
            try self.removeIfExists(cronDirectory, fileManager: fileManager)
        }
        for file in pairingCandidates {
            try self.removeIfExists(file, fileManager: fileManager)
        }
        for directory in additionalDirectories {
            try self.removeIfExists(directory, fileManager: fileManager)
        }
        for file in additionalFiles {
            try self.removeIfExists(file, fileManager: fileManager)
        }
    }

    private static func workspaceCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            values.append(
                documents
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("Workspace", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(caches.appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("OpenClawTVWorkspace", isDirectory: true))
        return self.uniqueURLs(values)
    }

    private static func memoryStoreCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(
                caches
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
            values.append(caches.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        }
        if let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            values.append(
                library
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
            values.append(
                library
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("GatewayMemory.sqlite", isDirectory: false))
        return self.uniqueURLs(values)
    }

    private static func telegramPairingCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(
                caches
                    .appendingPathComponent("OpenClawTV", isDirectory: true)
                    .appendingPathComponent("TelegramPairing.json", isDirectory: false))
            values.append(caches.appendingPathComponent("TelegramPairing.json", isDirectory: false))
        }
        values.append(fileManager.temporaryDirectory.appendingPathComponent("TelegramPairing.json", isDirectory: false))
        return self.uniqueURLs(values)
    }

    private static func additionalDirectoryCandidates(fileManager: FileManager) -> [URL] {
        var values: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            values.append(appSupport.appendingPathComponent("OpenClaw", isDirectory: true))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            values.append(caches.appendingPathComponent("OpenClaw", isDirectory: true))
        }
        return self.uniqueURLs(values)
    }

    private static func additionalFileCandidates(fileManager: FileManager) -> [URL] {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        return [documents.appendingPathComponent("openclaw-gateway.log", isDirectory: false)]
    }

    private static func uniqueURLs(_ values: [URL]) -> [URL] {
        var seen: Set<String> = []
        var deduped: [URL] = []
        for value in values {
            let key = value.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            deduped.append(value)
        }
        return deduped
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
