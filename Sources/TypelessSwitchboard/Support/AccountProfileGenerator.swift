import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct GeneratedAccountProfile {
    var displayName: String
    var username: String
    var email: String
    var domain: String
    var password: String
}

enum AccountProfileGenerator {
    private static let adjectives = [
        "clear", "swift", "bright", "quiet", "fresh", "lucky", "solid", "rapid",
        "neat", "smart", "calm", "prime", "true", "bold", "clean", "sharp"
    ]
    private static let nouns = [
        "note", "draft", "paper", "cursor", "field", "page", "signal", "orbit",
        "marker", "line", "pixel", "folder", "writer", "memo", "frame", "script"
    ]

    static func make(domain: String) -> GeneratedAccountProfile {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("example.com")
        let adjective = adjectives.randomElement() ?? "clear"
        let noun = nouns.randomElement() ?? "note"
        let suffix = String(Int.random(in: 100_000...999_999))
        let username = "\(adjective)_\(noun)_\(suffix)"
        let email = "\(adjective).\(noun).\(suffix)@\(normalizedDomain)"

        return GeneratedAccountProfile(
            displayName: "\(adjective.capitalized) \(noun.capitalized)",
            username: username,
            email: email,
            domain: normalizedDomain,
            password: PasswordGenerator.make()
        )
    }
}

enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!@#$%*+=?")

    static func make(length: Int = 20) -> String {
        let required = [
            lowercase.randomElement() ?? "a",
            uppercase.randomElement() ?? "A",
            digits.randomElement() ?? "2",
            symbols.randomElement() ?? "!"
        ]
        let all = lowercase + uppercase + digits + symbols
        let rest = (0..<max(length - required.count, 0)).map { _ in
            all.randomElement() ?? "x"
        }
        return String((required + rest).shuffled())
    }
}
