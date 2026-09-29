import AppKit
import SwiftUI

/// One semantic palette for both system appearances. Machine readings remain
/// distinct from human presence and from alert severity.
enum MachinePalette {
    static let nativeProcessor = adaptiveNative(dark: 0x4F91FF, light: 0x236BE8)
    static let nativeGraphics = adaptiveNative(dark: 0x80D9FF, light: 0x149CE3)
    static let processor = Color(nsColor: nativeProcessor)
    static let graphics = Color(nsColor: nativeGraphics)
    static let memory = adaptive(dark: 0xF6D95C, light: 0x987300)
    static let human = adaptive(dark: 0xDBE3EB, light: 0x4E5D6C)
    static let accent = adaptive(dark: 0xF2DF63, light: 0x816B00)
    static let warm = adaptive(dark: 0xC69C60, light: 0x976A34)
    static let critical = adaptive(dark: 0xF07879, light: 0xC43F49)
    static let normal = adaptive(dark: 0x9BBDBA, light: 0x397A73)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: adaptiveNative(dark: dark, light: light))
    }

    private static func adaptiveNative(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
