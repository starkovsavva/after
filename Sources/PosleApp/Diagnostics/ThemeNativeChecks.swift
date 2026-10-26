#if DEBUG
import AppKit
import Foundation

/// Inert palette validation, contrast and persistence. Uses only a disposable
/// directory and never changes macOS appearance or opens a file picker.
@MainActor
enum ThemeNativeChecks {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("posle-theme-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root); ThemeRuntime.shared.set(.graphite) }
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !value() { throw AppError.message(message) }
        }
        let controller = ThemeController(); controller.configure(root: root)
        try expect(controller.palette == .graphite, "Empty theme settings must use graphite")
        controller.change { $0.appearance = "dark"; $0.accent = "29A8DD"; $0.textSize = 17; $0.density = "compact" }
        try expect(controller.error == nil, "Valid palette must persist")
        let reopened = ThemeController(); reopened.configure(root: root)
        try expect(reopened.palette == controller.palette && reopened.colorScheme == .dark, "Palette must survive reopen")
        let original = try Data(contentsOf: root.appendingPathComponent("theme.json"))
        let invalidMutations: [(inout ThemePalette) -> Void] = [
            { $0.accent = "../../secret" }, { $0.appearance = "<script>" }, { $0.textSize = 100 },
            { $0.density = "arbitrary" }, { $0.material = "script" }, { $0.version = 2 }, { $0.name = "Bad\nName" }, { $0.name = "../Name" }, { $0.name = String(repeating: "x", count: 61) }
        ]
        for mutate in invalidMutations {
            reopened.change(mutate)
            try expect(reopened.error != nil, "Invalid palette must be rejected")
            try expect(try Data(contentsOf: root.appendingPathComponent("theme.json")) == original, "Invalid palette must preserve saved settings")
        }
        let legacy = Data(#"{"version":1,"name":"Моя тема","appearance":"dark","accent":"34745A","textSize":16,"density":"compact"}"#.utf8)
        let legacyPalette = try JSONDecoder().decode(ThemePalette.self, from: legacy).validated()
        try expect(legacyPalette.material == "graphite" && legacyPalette.accent == "34745A" && legacyPalette.textSize == 16,
                   "Old palettes must preserve their values and default only the material")
        for material in AppearanceMaterial.allCases {
            reopened.change { $0.material = material.rawValue }
            try expect(reopened.error == nil && reopened.palette.material == material.rawValue, "All materials must validate and persist")
        }
        print("PASS: theme schema validation, bounded values and reopen persistence")
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            func c(_ n: CGFloat) -> Double { let x = Double(n); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * c(rgb.redComponent) + 0.7152 * c(rgb.greenComponent) + 0.0722 * c(rgb.blueComponent)
        }
        for hex in ["000000", "FFFFFF", "65696F", "2867B2", "34745A", "A26826", "FF0000", "00FF00", "0000FF"] {
            let base = ThemePalette(accent: hex).color
            for dark in [true, false] {
                for fill in [true, false] {
                    let adjusted = ThemeRuntime.accessibleAccent(base, dark: dark, fill: fill)
                    let background = dark && !fill ? 0.02 : fill ? 1.0 : 0.94
                    let foreground = luminance(adjusted)
                    try expect((max(foreground, background) + 0.05) / (min(foreground, background) + 0.05) >= 4.5, "Theme accent contrast must be at least 4.5:1")
                }
            }
        }
        print("PASS: preset and extreme custom accent contrast in both appearances")
        let target = root.appendingPathComponent("unchanged.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(at: root.appendingPathComponent("theme.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("theme.json"), withDestinationURL: target)
        reopened.change { $0.name = "Unsafe link" }
        try expect(reopened.error != nil, "Theme settings must reject symbolic links")
        try expect(try Data(contentsOf: target) == Data("keep".utf8), "Theme persistence must not follow links")
        print("PASS: theme persistence does not follow symbolic links")
    }
}
#endif
