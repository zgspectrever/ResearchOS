import AppKit
import SwiftUI

enum ResearchPalette {
    static let window = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let document = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
}

extension View {
    /// A floating surface for navigation and tools; document content stays opaque.
    func researchGlassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(ResearchGlassSurface(cornerRadius: cornerRadius))
    }
}

private struct ResearchGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(ResearchPalette.card, in: shape)
                .overlay { shape.strokeBorder(ResearchPalette.separator, lineWidth: 0.5) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        ResearchPalette.separator.opacity(contrast == .increased ? 1 : 0.45),
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.06), radius: 7, y: 2)
        }
    }
}

/// Share the native glass rendering pass between neighboring control groups.
struct ResearchGlassContainer<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct ResearchCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(ResearchPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ResearchPalette.separator.opacity(0.35), lineWidth: 0.5)
            }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
    }
}
