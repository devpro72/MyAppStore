import Foundation

struct AppGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var symbol: String

    init(id: UUID = UUID(), name: String, sortOrder: Int, symbol: String = "folder") {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.symbol = symbol
    }

    enum CodingKeys: String, CodingKey { case id, name, sortOrder, symbol }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        sortOrder = try values.decode(Int.self, forKey: .sortOrder)
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "folder"
    }
}
