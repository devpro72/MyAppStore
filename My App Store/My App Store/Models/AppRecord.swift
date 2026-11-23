import Foundation

/// A published application in the private iCloud Drive catalog.
struct AppRecord: Codable, Identifiable, Hashable, Sendable {
    enum PackageType: String, Codable, CaseIterable, Sendable {
        case app
        case zip
        case dmg
        case pkg
    }

    enum Origin: String, Codable, CaseIterable, Sendable {
        case personal
        case thirdParty
    }

    struct Release: Codable, Hashable, Sendable {
        let version: String
        let build: String?
        let packagePath: String
        let packageType: PackageType
        let sha256: String
        let sizeBytes: Int64
        let publishedAt: Date
        let signingTeamID: String?

        init(
            version: String,
            build: String? = nil,
            packagePath: String,
            packageType: PackageType,
            sha256: String,
            sizeBytes: Int64,
            publishedAt: Date = .now,
            signingTeamID: String? = nil
        ) {
            self.version = version
            self.build = build
            self.packagePath = packagePath
            self.packageType = packageType
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.publishedAt = publishedAt
            self.signingTeamID = signingTeamID
        }
    }

    /// Stable bundle identifier; do not use the display name as an identity.
    let id: String
    var name: String
    var summary: String
    var origin: Origin
    var iconPath: String?
    var groupID: UUID? = nil
    var releases: [Release]

    var latestRelease: Release? {
        releases.max { lhs, rhs in
            let comparison = lhs.version.compare(rhs.version, options: .numeric)
            if comparison == .orderedSame {
                return (lhs.build ?? "").compare(rhs.build ?? "", options: .numeric) == .orderedAscending
            }
            return comparison == .orderedAscending
        }
    }
}
