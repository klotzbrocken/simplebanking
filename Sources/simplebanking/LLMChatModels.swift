import Foundation

enum ChatMessageRole: String {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: ChatMessageRole
    let text: String
    let createdAt: Date = Date()
}

enum ChatState: Equatable {
    case idle
    case loading
    case failed(String)
}

struct LLMAnswer {
    let sql: String
    let resultRows: [[String: String]]
    let answerText: String
}
