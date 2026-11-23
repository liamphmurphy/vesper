import Foundation

/// API client helpers for `/api/v1/dock-chats`, which records recent chats per dock scope
/// (e.g. `app:work`, `app:knowledge`, `page:<id>`).
public enum DockChatsAPI {
    public struct ListResponse: Codable, Sendable, Equatable {
        public var chats: [API.ChatSession]
        public init(chats: [API.ChatSession] = []) {
            self.chats = chats
        }
    }

    private struct AddBody: Encodable, Sendable {
        let scope: String
        let chatId: String
        enum CodingKeys: String, CodingKey {
            case scope
            case chatId = "chat_id"
        }
    }

    public static func list(scope: String) -> APIRequest<ListResponse> {
        var query: [URLQueryItem] = []
        APIQuery.append(&query, "scope", scope)
        return APIRequest(
            method: "GET",
            template: "/dock-chats",
            path: "/api/v1/dock-chats",
            query: query,
            decode: .json
        )
    }

    public static func add(scope: String, chatId: String) -> APIRequest<APIEmpty> {
        APIRequest(
            method: "POST",
            template: "/dock-chats",
            path: "/api/v1/dock-chats",
            body: .json(AddBody(scope: scope, chatId: chatId)),
            decode: .empty
        )
    }
}
