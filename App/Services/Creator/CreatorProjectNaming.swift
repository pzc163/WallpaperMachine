import Foundation

/// A short local display name; never changes the immutable project identity or validation digest.
enum CreatorProjectNaming {
    static let defaultNames: Set<String> = ["Untitled project", "未命名工程", "未命名專案", "名称未設定のプロジェクト", "이름 없는 프로젝트", "Projeto sem título"]
    static func title(from sanitizedPrompt: String) -> String? {
        var text = sanitizedPrompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let prefixes = ["请帮我", "請幫我", "帮我", "幫我", "我想要", "请", "請", "生成一个", "生成一张", "生成一個", "生成一張", "生成", "制作一个", "製作一個", "设计一个", "設計一個", "做一个", "做一個", "一个", "一個", "一张", "一張", "please create ", "please generate ", "create ", "generate ", "please "]
        for _ in 0..<6 {
            guard let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0) }) else { break }
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        var result = ""
        for character in text.prefix(18) {
            guard result.unicodeScalars.count + character.unicodeScalars.count <= 60 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreatorBundlePresentation.validText(result, limit: 60) ? result : nil
    }
}
