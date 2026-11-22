import SwiftUI
import UIKit

/// Studio colour theme (port of core/Theme + ui/Ui.kt). Values are the Android app's ARGB ints.
struct StudioTheme: Equatable, Identifiable {
    let name: String
    let light: Bool
    let bg, panel, header, topbar, ribbon, border, text, dim, accent, select, hover, input, rowAlt: Int32
    let editorBg, editorGutter, editorText, synKeyword, synString, synNumber, synComment, synBuiltin: Int32
    var id: String { name }

    static let dark = StudioTheme(
        name: "Dark", light: false,
        bg: -13750738, panel: -13750738, header: -13290187, topbar: -14342875, ribbon: -13290187, border: -15066598,
        text: -3355444, dim: -7434610, accent: -16033105, select: -16033105, hover: -12434878, input: -14342875, rowAlt: -13421773,
        editorBg: -14803426, editorGutter: -14342874, editorText: -2039584,
        synKeyword: -496260, synString: -5377643, synNumber: -14848, synComment: -8750470, synBuiltin: -8071433)

    static let lightTheme = StudioTheme(
        name: "Light", light: true,
        bg: -855310, panel: -1, header: -1184275, topbar: -1842205, ribbon: -526345, border: -3158065,
        text: -15000805, dim: -9737365, accent: -16033105, select: -4466185, hover: -1907998, input: -1, rowAlt: -526345,
        editorBg: -1, editorGutter: -789517, editorText: -15000805,
        synKeyword: -16776961, synString: -5415680, synNumber: -16086422, synComment: -16744448, synBuiltin: -15044683)

    static let midnight = StudioTheme(
        name: "Midnight", light: false,
        bg: -14999766, panel: -14802384, header: -14275781, topbar: -15394523, ribbon: -14275781, border: -15855334,
        text: -2762008, dim: -7892824, accent: -10781446, select: -12890212, hover: -13617590, input: -15328731, rowAlt: -14538954,
        editorBg: -15328731, editorGutter: -14999765, editorText: dark.editorText,
        synKeyword: dark.synKeyword, synString: dark.synString, synNumber: dark.synNumber, synComment: dark.synComment, synBuiltin: dark.synBuiltin)

    static let highContrast = StudioTheme(
        name: "High Contrast", light: false,
        bg: -16777216, panel: -16777216, header: -15066598, topbar: -16777216, ribbon: -15658735, border: -9803158,
        text: -1, dim: -3618616, accent: -14774017, select: -16756536, hover: -13421773, input: -16777216, rowAlt: -15921907,
        editorBg: -16777216, editorGutter: -15921907, editorText: -1,
        synKeyword: dark.synKeyword, synString: dark.synString, synNumber: dark.synNumber, synComment: dark.synComment, synBuiltin: dark.synBuiltin)

    static let builtIn = [dark, lightTheme, midnight, highContrast]
}

extension Color {
    init(argb v: Int32) {
        let u = UInt32(bitPattern: v)
        self.init(.sRGB, red: Double((u >> 16) & 255) / 255, green: Double((u >> 8) & 255) / 255,
                  blue: Double(u & 255) / 255, opacity: Double((u >> 24) & 255) / 255)
    }
}

extension UIColor {
    convenience init(argb v: Int32) {
        let u = UInt32(bitPattern: v)
        self.init(red: CGFloat((u >> 16) & 255) / 255, green: CGFloat((u >> 8) & 255) / 255,
                  blue: CGFloat(u & 255) / 255, alpha: CGFloat((u >> 24) & 255) / 255)
    }
}

/// Current theme, saved across launches. The root view re-renders when it changes.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var current: StudioTheme {
        didSet { UserDefaults.standard.set(current.name, forKey: "studioTheme") }
    }
    private init() {
        let n = UserDefaults.standard.string(forKey: "studioTheme")
        current = StudioTheme.builtIn.first { $0.name == n } ?? .dark
    }
}

/// Short names for the theme colours (Ui.BG, Ui.PANEL ... in the Android app).
enum Th {
    static var t: StudioTheme { ThemeStore.shared.current }
    static var bg: Color { Color(argb: t.bg) }
    static var panel: Color { Color(argb: t.panel) }
    static var header: Color { Color(argb: t.header) }
    static var topbar: Color { Color(argb: t.topbar) }
    static var ribbon: Color { Color(argb: t.ribbon) }
    static var border: Color { Color(argb: t.border) }
    static var text: Color { Color(argb: t.text) }
    static var dim: Color { Color(argb: t.dim) }
    static var accent: Color { Color(argb: t.accent) }
    static var select: Color { Color(argb: t.select) }
    static var hover: Color { Color(argb: t.hover) }
    static var input: Color { Color(argb: t.input) }
    static var rowAlt: Color { Color(argb: t.rowAlt) }
    static var card: Color { t.light ? Color(argb: -1) : Color(argb: -13092808) }
    static var editorBg: Color { Color(argb: t.editorBg) }
    static var editorGutter: Color { Color(argb: t.editorGutter) }
    /// Text on the selection colour: white on dark selections, dark on light ones.
    static var selectText: Color { luminance(t.select) > 0.6 ? Color(argb: t.text) : .white }

    static let play = Color(argb: -13726889)
    static let stop = Color(argb: -4179669)
    static let warn = Color(argb: -23296)
    static let error = Color(argb: -43691)
    static let info = Color(argb: -9652481)

    static func luminance(_ v: Int32) -> Double {
        let u = UInt32(bitPattern: v)
        return (0.299 * Double((u >> 16) & 255) + 0.587 * Double((u >> 8) & 255) + 0.114 * Double(u & 255)) / 255
    }
}
