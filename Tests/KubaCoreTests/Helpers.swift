import Foundation
@testable import KubaCore

enum Fixtures {
    static var profilesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Profiles")
    }

    static func profile(_ id: String) throws -> CommandProfile {
        try CommandProfile.load(from: Data(contentsOf: profilesDir.appendingPathComponent("\(id).json")))
    }
}
