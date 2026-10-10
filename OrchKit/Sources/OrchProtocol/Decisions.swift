import Foundation

public extension Decisions {
    /// Selects exactly the four authoritative fields; host view metadata never enters the §13 hash.
    static func questionHash(questionID: ID16, ticket: String, text: String, options: JSONValue) throws -> Data {
        try contentHash(of: ["question_id": .string(questionID.hex), "ticket": .string(ticket),
                             "text": .string(text), "options": options])
    }
}
