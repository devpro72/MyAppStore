import Foundation

struct Catalog: Codable, Sendable {
    var schemaVersion: Int = 1
    var applications: [AppRecord] = []
    var groups: [AppGroup] = []
    var defaultGroupsInitialized: Bool = false

    enum CodingKeys: String, CodingKey { case schemaVersion, applications, groups, defaultGroupsInitialized }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        applications = try values.decodeIfPresent([AppRecord].self, forKey: .applications) ?? []
        groups = try values.decodeIfPresent([AppGroup].self, forKey: .groups) ?? []
        defaultGroupsInitialized = try values.decodeIfPresent(Bool.self, forKey: .defaultGroupsInitialized) ?? false
    }
}
