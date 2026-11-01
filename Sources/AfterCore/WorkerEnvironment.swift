import Foundation

public enum WorkerEnvironment {
    /// Foundation.Process uses macOS filesystem encoding for environment values,
    /// which decomposes Unicode (й/ё/é). Keep JSON ASCII on this boundary so its
    /// decoded strings retain their exact bytes, including profile fingerprints.
    public static func json(_ data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count)
        for unit in String(decoding: data, as: UTF8.self).utf16 {
            if unit < 0x80 {
                result.unicodeScalars.append(UnicodeScalar(unit)!)
            } else {
                // UTF-16 also emits the required surrogate pair for emoji and
                // other scalars above U+FFFF. Existing JSON escapes stay intact.
                result += String(format: "\\u%04x", Int(unit))
            }
        }
        return result
    }
}
