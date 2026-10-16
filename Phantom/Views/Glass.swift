import SwiftUI

// Liquid Glass on iOS 26, with a material fallback on iOS 17–25.
// `#if compiler` keeps the project building with older Xcode versions.

extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(interactive: interactive, tint: tint), in: shape)
        } else {
            fallbackGlass(shape, tint: tint)
        }
        #else
        fallbackGlass(shape, tint: tint)
        #endif
    }

    private func fallbackGlass<S: Shape>(_ shape: S, tint: Color?) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.5), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private func makeGlass(interactive: Bool, tint: Color?) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

/// Groups glass shapes so they blend and morph together on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Controls

struct GlassIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glass(Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

/// A round glass button with a caption underneath, for the bottom toolbar.
struct ToolbarButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            GlassIconButton(systemName: systemName, label: title, size: 56, action: action)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }
}

/// The large white camera-style button in the middle of the toolbar.
struct ShutterButton: View {
    let systemName: String?
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4)
                    Circle().fill(.white).padding(8)
                    if let systemName {
                        Image(systemName: systemName)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 80, height: 80)
                .contentShape(Circle())
            }
            .buttonStyle(ShutterPressStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .accessibilityLabel(title)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlassPill<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glass(Capsule())
    }
}

extension GlassPill where Leading == EmptyView {
    init(text: String) {
        self.text = text
        self.leading = EmptyView()
    }
}

/// Amber measurement label drawn next to an edge in AR.
struct DimensionChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(Color(red: 0.11, green: 0.08, blue: 0.03))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.phantomGuide, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

struct HintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
