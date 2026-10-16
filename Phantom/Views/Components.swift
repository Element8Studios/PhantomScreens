import SwiftUI

// Small controls shared by the sheets.

extension Color {
    /// Phantom Screens brand navy (#000A3E) and cyan (#86D9DD).
    static let phantomNavy = Color(red: 0, green: 10 / 255, blue: 62 / 255)
    static let phantomCyan = Color(red: 134 / 255, green: 217 / 255, blue: 221 / 255)
}

/// A frame color dot; wood grain shows streaks instead of a flat color.
struct FinishSwatch: View {
    let finish: FrameFinish

    var body: some View {
        Circle()
            .fill(finish.color)
            .overlay {
                if finish == .woodGrain {
                    Canvas { context, size in
                        let streak = Color(red: 0.36, green: 0.22, blue: 0.11).opacity(0.55)
                        for i in 0..<7 {
                            let x = size.width * (CGFloat(i) + 0.5) / 7
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addQuadCurve(to: CGPoint(x: x + (i.isMultiple(of: 2) ? 1.5 : -1.5), y: size.height),
                                              control: CGPoint(x: x + (i.isMultiple(of: 2) ? -2 : 2), y: size.height / 2))
                            context.stroke(path, with: .color(streak), lineWidth: i % 3 == 0 ? 1.4 : 0.7)
                        }
                    }
                    .clipShape(Circle())
                }
            }
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.5))
    }
}

struct SectionLabel: View {
    let title: String
    let value: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(value).font(.footnote.weight(.semibold))
            }
        }
    }
}

struct DoneButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done")
    }
}

/// Capsule choice chips that wrap onto new lines.
struct FlowChips<Item: Identifiable & Equatable>: View {
    let items: [Item]
    let selected: Item
    let title: KeyPath<Item, String>
    let onSelect: (Item) -> Void

    var body: some View {
        ChipLayout(spacing: 8) {
            ForEach(items) { item in
                let isSelected = item == selected
                Button { onSelect(item) } label: {
                    Text(item[keyPath: title])
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(isSelected ? Color.white : Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ExtentSlider: View {
    let session: PhantomSession
    @ObservedObject var live: ScreenLive

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Screen")
                Spacer()
                Text(live.extent < 0.02 ? "Retracted" : "\(Int(live.extent * 100))% closed")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { live.extent }, set: { session.setExtent($0) }), in: 0...1)
                .accessibilityLabel("Screen position")
        }
    }
}

/// A row with − and + buttons that repeat while held.
struct NudgeRow: View {
    let title: String
    let detail: String
    let minus: String
    let plus: String
    let step: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            button(minus, "\(title) minus", positive: false)
            button(plus, "\(title) plus", positive: true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func button(_ symbol: String, _ label: String, positive: Bool) -> some View {
        Button { step(positive) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 40)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }
}

struct StepperRow: View {
    let title: String
    let value: Float
    let unit: LengthUnit
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            stepButton("minus", label: "\(title) smaller by one eighth inch", delta: -1)
            Text(Length.string(value, unit: unit))
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(minWidth: 100)
            stepButton("plus", label: "\(title) larger by one eighth inch", delta: 1)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, label: String, delta: Int) -> some View {
        Button {
            let next = Float(Length.eighths(value) + delta) * Length.eighth
            onChange(min(max(next, range.lowerBound), range.upperBound))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }
}
