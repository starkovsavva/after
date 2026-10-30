import Foundation

// Test-only presentation helpers for standalone service/integrity smoke checks.
// Keep canonical Russian messages deterministic without loading AppKit UI state
// or changing any production runtime, process, or pre-dlopen integrity guard.
func L(_ source: String) -> String { source }

func LF(_ source: String, arguments: [String]) -> String {
    var result = source
    guard let expression = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#) else { return result }
    let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
    for match in matches.reversed() {
        guard let numberRange = Range(match.range(at: 1), in: result),
              let index = Int(result[numberRange]), arguments.indices.contains(index),
              let range = Range(match.range, in: result) else { continue }
        result.replaceSubrange(range, with: arguments[index])
    }
    return result
}
