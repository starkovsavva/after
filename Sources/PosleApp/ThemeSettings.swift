import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Themes are inert preferences. Imported files cannot contain paths, scripts,
/// fonts or application settings such as endpoints and API credentials.
struct ThemePalette: Codable, Equatable {
    var version = 1
    var name = "Графит"
    var appearance = "system"
    var accent = "65696F"
    var textSize = 14
    var density = "regular"
    var material = "graphite"

    private enum CodingKeys: String, CodingKey { case version, name, appearance, accent, textSize, density, material }
    init(version: Int = 1, name: String = "Графит", appearance: String = "system", accent: String = "65696F",
         textSize: Int = 14, density: String = "regular", material: String = "graphite") {
        self.version = version; self.name = name; self.appearance = appearance; self.accent = accent
        self.textSize = textSize; self.density = density; self.material = material
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Графит"
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "65696F"
        textSize = try c.decodeIfPresent(Int.self, forKey: .textSize) ?? 14
        density = try c.decodeIfPresent(String.self, forKey: .density) ?? "regular"
        material = try c.decodeIfPresent(String.self, forKey: .material) ?? "graphite"
    }

    static let graphite = ThemePalette()
    func validated() throws -> ThemePalette {
        let hex = accent.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains("/"), !name.contains("\\"), ["system", "light", "dark"].contains(appearance),
              hex.count == 6, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              (12...18).contains(textSize), ["regular", "compact"].contains(density),
              AppearanceMaterial(rawValue: material) != nil else {
            throw AppError.message("В файле темы неверные параметры. Нужна тема После версии 1.")
        }
        var result = self; result.accent = hex
        return result
    }
    var color: NSColor {
        let value = UInt32(accent, radix: 16) ?? 0x65696F
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255,
                       blue: Double(value & 255) / 255, alpha: 1)
    }
}

/// Dynamic NSColors can resolve off the main thread. Keep their inputs in a
/// lock-protected value instead of reaching into the main-actor controller.
final class ThemeRuntime: @unchecked Sendable {
    static let shared = ThemeRuntime()
    private let lock = NSLock()
    private var value = ThemePalette.graphite
    var palette: ThemePalette { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ palette: ThemePalette) { lock.lock(); value = palette; lock.unlock() }

    static func accessibleAccent(_ base: NSColor, dark: Bool, fill: Bool) -> NSColor {
        guard let rgb = base.usingColorSpace(.sRGB) else { return .controlAccentColor }
        func luminance(_ color: NSColor) -> Double {
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        // White button labels require a dark enough fill in either appearance.
        // Foreground links have the opposite requirement on a dark surface.
        let lighten = dark && !fill
        let target = lighten ? NSColor.white : NSColor.black
        let background: Double = lighten ? 0.02 : fill ? 1 : 0.94
        var candidate = rgb
        for step in 0...100 {
            let amount = CGFloat(step) / 100
            candidate = (rgb.blended(withFraction: amount, of: target) ?? rgb).usingColorSpace(.sRGB) ?? rgb
            let l = luminance(candidate)
            let contrast = (max(l, background) + 0.05) / (min(l, background) + 0.05)
            if contrast >= 4.6 { return candidate }
        }
        return candidate
    }
}

@MainActor
final class ThemeController: ObservableObject {
    static let shared = ThemeController()
    @Published private(set) var palette = ThemePalette.graphite
    @Published var error: String?
    private var root: URL?

    var colorScheme: ColorScheme? {
        palette.appearance == "dark" ? .dark : palette.appearance == "light" ? .light : nil
    }
    func configure(root: URL) {
        guard self.root != root else { return }
        self.root = root
        let url = root.appendingPathComponent("theme.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try rejectLink(url)
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536 else {
                    throw AppError.message("Файл темы слишком большой.")
                }
                let decoded = try JSONDecoder().decode(ThemePalette.self, from: Data(contentsOf: url)).validated()
                palette = decoded; ThemeRuntime.shared.set(decoded)
            } else { palette = .graphite; ThemeRuntime.shared.set(.graphite) }
        } catch {
            palette = .graphite; ThemeRuntime.shared.set(.graphite)
            self.error = "Не удалось открыть тему. Используется «Графит»."
        }
    }
    func change(_ mutate: (inout ThemePalette) -> Void) {
        var next = palette; mutate(&next)
        do {
            next = try next.validated()
            guard let root else { throw AppError.message("Папка настроек ещё не открыта.") }
            let url = root.appendingPathComponent("theme.json")
            try rejectLink(url)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: url, options: .atomic)
            ThemeRuntime.shared.set(next); palette = next; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func importPalette() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.prompt = "Выбрать тему"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536 else {
                throw AppError.message("Файл темы слишком большой.")
            }
            let next = try JSONDecoder().decode(ThemePalette.self, from: Data(contentsOf: url)).validated()
            change { $0 = next }
        } catch { self.error = "Не удалось импортировать тему: \(error.localizedDescription)" }
    }
    func exportPalette() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "После — \(palette.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(palette).write(to: url, options: .atomic)
            error = nil
        } catch { self.error = "Не удалось сохранить тему: \(error.localizedDescription)" }
    }
    private func rejectLink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw AppError.message("Файл темы не может быть ссылкой.") }
    }
}

struct ThemeSettingsView: View {
    @ObservedObject var theme: ThemeController
    private func binding<T>(_ keyPath: WritableKeyPath<ThemePalette, T>) -> Binding<T> {
        Binding(get: { theme.palette[keyPath: keyPath] }, set: { value in theme.change { $0[keyPath: keyPath] = value } })
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 18) {
            Text(title).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppPageHeader(title: "Оформление", compact: true)
            VStack(alignment: .leading, spacing: 18) {
                row("Стиль") {
                    Picker("Стиль", selection: binding(\.material)) {
                        ForEach(AppearanceMaterial.allCases) { material in Text(material.title).tag(material.rawValue) }
                    }.labelsHidden().frame(width: 210).accessibilityIdentifier("theme.material")
                }
                if theme.palette.material == AppearanceMaterial.nativeLiquidGlass.rawValue,
                   !AppearanceMaterial.nativeLiquidGlass.availabilityDescription.isEmpty {
                    Text(AppearanceMaterial.nativeLiquidGlass.availabilityDescription)
                        .font(AppTypography.caption).foregroundStyle(Ink.secondaryText)
                }
                Picker("Внешний вид", selection: binding(\.appearance)) {
                    Text("Как в macOS").tag("system"); Text("Светлый").tag("light"); Text("Тёмный").tag("dark")
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Внешний вид")
                row("Цвет акцента") {
                    HStack(spacing: 10) {
                        ForEach([("Графит", "65696F"), ("Синий", "2867B2"), ("Зелёный", "34745A"), ("Янтарный", "A26826")], id: \.1) { name, hex in
                            Button { theme.change { $0.name = name; $0.accent = hex } } label: {
                                Circle().fill(Color(nsColor: ThemePalette(accent: hex).color)).frame(width: 22, height: 22)
                                    .overlay { if theme.palette.accent == hex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                                    .padding(4).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(theme.palette.accent == hex ? .isSelected : [])
                        }
                        ColorPicker("Свой цвет", selection: Binding(get: { Color(nsColor: theme.palette.color) }, set: { color in
                            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                            let hex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                            theme.change { $0.name = "Своя тема"; $0.accent = hex }
                        }), supportsOpacity: false).labelsHidden().accessibilityLabel("Свой цвет акцента")
                    }
                }
                row("Размер текста") {
                    Picker("Размер текста", selection: binding(\.textSize)) {
                        ForEach(12...18, id: \.self) { Text("\($0) пт").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                row("Плотность") {
                    Picker("Плотность", selection: binding(\.density)) {
                        Text("Обычная").tag("regular"); Text("Компактная").tag("compact")
                    }.labelsHidden().frame(width: 160)
                }
            }
            ThemeApplicationPreview()
                .accessibilityLabel("Предпросмотр оформления: список встреч, конспект и панель управления")
            HStack {
                Button("Импортировать тему…") { theme.importPalette() }
                Button("Экспортировать…") { theme.exportPalette() }
                Spacer()
                Button("Сбросить") { theme.change { $0 = .graphite } }.disabled(theme.palette == .graphite)
            }.buttonStyle(.bordered)
            if let error = theme.error { Text(error).font(AppTypography.caption).foregroundStyle(Ink.warning).textSelection(.enabled) }
        }
    }
}

/// Applies the same appearance and accent to separately hosted native panels.
struct PosleThemeRoot: ViewModifier {
    @ObservedObject private var theme = ThemeController.shared
    var root: URL
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme.colorScheme).tint(Ink.accent)
            .onAppear { theme.configure(root: root) }
    }
}
