import Foundation
import KubaCore

/// Perfis embutidos no app + perfis criados/importados pelo usuário (pasta Documentos/Profiles).
final class ProfileStore: ObservableObject {
    @Published private(set) var bundled: [CommandProfile] = []
    @Published private(set) var user: [CommandProfile] = []
    @Published private(set) var loadErrors: [String] = []

    private let userDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Profiles", isDirectory: true)
    }()

    init() { reload() }

    var all: [CommandProfile] {
        let userIDs = Set(user.map(\.id))
        return user + bundled.filter { !userIDs.contains($0.id) }
    }

    func profile(id: String) -> CommandProfile? { all.first { $0.id == id } }

    func isUserProfile(_ id: String) -> Bool { user.contains { $0.id == id } }

    func reload() {
        loadErrors = []
        let bundledURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Profiles") ?? []
        bundled = bundledURLs.compactMap(load).sorted { $0.name < $1.name }
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userURLs = (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
        user = userURLs.filter { $0.pathExtension == "json" }.compactMap(load).sorted { $0.name < $1.name }
    }

    private func load(_ url: URL) -> CommandProfile? {
        do {
            let profile = try CommandProfile.load(from: Data(contentsOf: url))
            _ = try ProfileDriver(profile: profile)
            return profile
        } catch {
            loadErrors.append("\(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func save(_ profile: CommandProfile) throws {
        _ = try ProfileDriver(profile: profile)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try profile.encoded().write(to: userDir.appendingPathComponent("\(profile.id).json"), options: .atomic)
        reload()
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: userDir.appendingPathComponent("\(id).json"))
        reload()
    }

    @discardableResult
    func importFile(_ url: URL) throws -> CommandProfile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let profile = try CommandProfile.load(from: Data(contentsOf: url))
        try save(profile)
        return profile
    }

    /// Melhor perfil para o aparelho conectado: primeiro os do usuário, depois os verificados.
    func bestMatch(name: String?, services: [String]) -> CommandProfile? {
        let candidates = all.filter { $0.matches(name: name, services: services) }
        return candidates.first { isUserProfile($0.id) }
            ?? candidates.first { $0.verified }
            ?? candidates.first
    }
}
