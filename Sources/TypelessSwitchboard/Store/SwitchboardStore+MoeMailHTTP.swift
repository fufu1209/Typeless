import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func moeMailURL(path: String) -> URL? {
        guard let base = URL(string: state.settings.moeMailBaseURL) else { return nil }
        return URL(string: path, relativeTo: base)
    }


    func moeMailRequest(url: URL, apiKey: String, method: String = "GET", body: Data? = nil, timeoutInterval: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 必须显式超时：轮询路径总窗口只有约 101 秒，一次请求挂起（默认 60s）就会吃掉整个窗口。
        request.timeoutInterval = timeoutInterval
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "MoeMail",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
            )
        }
        return data
    }


    func parseMoeMailEmails(from data: Data) -> [MoeMailEmail] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dictionaries = collectDictionaries(from: json)

        let emails = dictionaries.compactMap { dictionary -> MoeMailEmail? in
            let address = stringValue(dictionary, keys: ["email", "address", "mail", "emailAddress"])
            let id = stringValue(dictionary, keys: ["id", "_id", "emailId", "emailID", "uuid"])
            guard !address.isEmpty || !id.isEmpty else { return nil }

            let resolvedAddress = address
            let domain = stringValue(dictionary, keys: ["domain", "mailDomain"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").last ?? "")
            let name = stringValue(dictionary, keys: ["name", "username", "label"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").first ?? "")
            let resolvedID = id.ifEmpty(resolvedAddress)

            return MoeMailEmail(
                id: resolvedID,
                address: resolvedAddress,
                name: name,
                domain: domain,
                expiresAt: nil,
                rawSummary: summarize(dictionary)
            )
        }

        return Array(Dictionary(grouping: emails, by: \.id).compactMap { $0.value.first })
            .sorted { $0.address < $1.address }
    }


    func parseMoeMailMessages(from data: Data) -> [MoeMailMessage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return collectDictionaries(from: json).compactMap { dictionary -> MoeMailMessage? in
            let id = stringValue(dictionary, keys: ["id", "_id", "messageId", "messageID", "uuid"])
            let subject = stringValue(dictionary, keys: ["subject", "title"]).ifEmpty("无主题")
            let sender = stringValue(dictionary, keys: ["from", "sender", "fromAddress"])
            let receivedAt = stringValue(dictionary, keys: ["createdAt", "receivedAt", "date", "time"])
            let preview = stringValue(dictionary, keys: ["preview", "text", "body", "content"])
            guard !id.isEmpty || !sender.isEmpty || subject != "无主题" else { return nil }
            return MoeMailMessage(
                id: id.ifEmpty(UUID().uuidString),
                subject: subject,
                sender: sender,
                receivedAt: receivedAt,
                preview: preview
            )
        }
    }


    func collectDictionaries(from object: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                result.append(dictionary)
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }

        walk(object)
        return result
    }


    func stringValue(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return ""
    }


    func summarize(_ dictionary: [String: Any]) -> String {
        dictionary
            .prefix(4)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "  ")
    }


    func extractDomains(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var values: [String] = []

        func walk(_ object: Any) {
            if let string = object as? String {
                if looksLikeDomain(string) {
                    values.append(string)
                }
            } else if let array = object as? [Any] {
                array.forEach(walk)
            } else if let dictionary = object as? [String: Any] {
                dictionary.values.forEach(walk)
            }
        }

        walk(json)
        return Array(Set(values)).sorted()
    }


    func looksLikeDomain(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."),
              !trimmed.contains(" "),
              !trimmed.contains("@"),
              !trimmed.hasPrefix("http") else {
            return false
        }
        return trimmed.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

extension JSONEncoder {

    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {

    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
