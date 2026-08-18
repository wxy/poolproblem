import Foundation

/// 把绝对路径转成脱敏模式：家目录换成 `~`，UUID/长十六进制段换成 `*`。
public enum PathPatternizer {
    public static func patternize(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = path
        if result == homeDirectory {
            result = "~"
        } else if result.hasPrefix(homeDirectory + "/") {
            result = "~" + result.dropFirst(homeDirectory.count)
        }
        result = result.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "*",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8,}"#,
            with: "*",
            options: .regularExpression
        )
        return result
    }
}
