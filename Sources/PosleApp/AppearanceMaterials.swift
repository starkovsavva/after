import AppKit
import SwiftUI

enum AppearanceMaterial: String, CaseIterable, Identifiable {
    case graphite, matteGlass, nativeLiquidGlass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: return "Графит"
        case .matteGlass: return "Матовое стекло"
        case .nativeLiquidGlass: return "Liquid Glass"
        }
    }
    var availabilityDescription: String {
        if #available(macOS 26, *) { return "" }
        return "На этом Mac используется матовое стекло. Liquid Glass доступно в macOS 26."
    }
}

enum AppSurfaceRole {
    case toolbar, sidebar, floatingPanel
    var radius: CGFloat { self == .floatingPanel ? 14 : 0 }
}

/// Materials belong to navigation and controls, never to the reading surface.
/// Accessibility settings always take precedence over imported preferences.
private struct AppSurface: ViewModifier {
    @ObservedObject private var theme = ThemeController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let role: AppSurfaceRole
    func body(content: Content) -> some View {
        let material = AppearanceMaterial(rawValue: theme.palette.material) ?? .graphite
        let shape = RoundedRectangle(cornerRadius: role.radius)
        Group {
            if reduceTransparency || contrast == .increased || material == .graphite {
                content.background(role == .sidebar ? Ink.sidebar : Ink.paper, in: shape)
            } else if material == .nativeLiquidGlass {
                if #available(macOS 26, *) {
                    // Keep glass on the chrome's backdrop. Applying it to the
                    // whole content also changes foreground vibrancy, which can
                    // resolve dark-mode text as black in separately hosted views.
                    content.background {
                        Color.clear.glassEffect(.regular.interactive(false), in: shape)
                    }
                } else {
                    content.background(.regularMaterial, in: shape)
                }
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
    }
}

extension View {
    func appSurface(_ role: AppSurfaceRole) -> some View { modifier(AppSurface(role: role)) }
}

/// Real interface structure using the same fonts, materials and semantic colors.
/// It is deliberately inert and contains no data or action from the library.
struct ThemeApplicationPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("После").font(AppTypography.controlStrong)
                Spacer()
                Image(systemName: "mic")
                Label("Записать", systemImage: "record.circle")
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Ink.soft, in: RoundedRectangle(cornerRadius: 6))
            }.font(AppTypography.control).padding(.horizontal, 14).frame(height: 42).appSurface(.toolbar)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Встречи", systemImage: "waveform").font(AppTypography.controlStrong)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.selection, in: RoundedRectangle(cornerRadius: 6))
                    Label("Заметки", systemImage: "note.text").padding(.horizontal, 8)
                    Label("Задачи", systemImage: "checklist").padding(.horizontal, 8)
                    Spacer(minLength: 0)
                }.font(AppTypography.control).padding(10).frame(width: 132).appSurface(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("План запуска").font(AppTypography.sectionTitle)
                    Text("Решили начать с небольшой группы. В пятницу проверим первые результаты.")
                        .font(AppTypography.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "quote.bubble")
                        Text("Открыть исходную реплику")
                    }.font(AppTypography.control).foregroundStyle(Ink.accent)
                    Spacer(minLength: 0)
                    Label("Подготовить сценарий", systemImage: "circle")
                        .font(AppTypography.control).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Ink.soft, in: RoundedRectangle(cornerRadius: 7))
                }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading).background(Ink.paper)
            }.frame(height: 216)
        }.background(Ink.paper).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
            .allowsHitTesting(false).accessibilityElement(children: .combine)
    }
}
