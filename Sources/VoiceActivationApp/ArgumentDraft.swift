import Foundation

struct ArgumentDraft: Equatable, Identifiable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String) {
        self.id = id
        self.value = value
    }
}
