import AppKit
import SwiftUI

/// Real desktop-backed frost, not a blur of the chart or its text.
struct InstrumentGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A quiet raised surface. The accessibility fallback stays opaque and legible.
struct InstrumentGlassSurface: View {
    var radius: CGFloat = 17
    var selectionTint: Color? = nil
    var lifted = false
    var quiet = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor)
                  : Color.white.opacity(surfaceOpacity))
            .overlay { shape.fill((selectionTint ?? .clear).opacity(0.045)) }
            .overlay {
                shape.fill(LinearGradient(
                    colors: [.white.opacity(scheme == .dark ? 0.035 : 0.25), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .overlay {
                shape.strokeBorder(selectionTint?.opacity(scheme == .dark ? 0.65 : 0.5)
                                   ?? .white.opacity(lifted ? 0.35 : scheme == .dark ? (quiet ? 0.055 : 0.09) : 0.65),
                                   lineWidth: selectionTint == nil ? 0.6 : 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.035), radius: 7, x: 0, y: 3)
            .allowsHitTesting(false)
    }

    private var surfaceOpacity: Double {
        if scheme == .dark {
            return lifted ? 0.11 : selectionTint != nil ? 0.085 : quiet ? 0.025 : 0.045
        }
        return lifted ? 0.8 : selectionTint != nil ? 0.72 : quiet ? 0.30 : 0.46
    }
}

struct InstrumentControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InstrumentControlFeedback(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct InstrumentControlFeedback<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovered = false
    var body: some View {
        label
            .background(MachinePalette.processor.opacity(pressed ? 0.13 : hovered ? 0.065 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}
