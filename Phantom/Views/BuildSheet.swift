import SwiftUI

/// Customize: one option at a time, chosen from a row of tabs (Color, Mesh,
/// Handle, Size, Type). Everything starts chosen for the customer from the
/// measurement and the most popular options. The sheet opens short, so the
/// screen stays visible above it and can still be dragged open and closed;
/// pull it up for more room.
struct BuildSheet: View {
    typealias Step = OptionStep

    @ObservedObject var session: PhantomSession
    @ObservedObject var trim: TrimLive
    @Binding var unit: LengthUnit
    /// The option to open on.
    let focus: Step
    let onReview: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Step?
    @State private var detent: PresentationDetent = BuildSheet.short

    private static let short = PresentationDetent.height(430)

    private var config: ScreenConfig { session.config }
    private var steps: [Step] { OptionStep.steps(for: config.product) }

    /// The tab showing; falls back to Color if the product lost that option.
    private var current: Step {
        let step = selected ?? focus
        return steps.contains(step) ? step : .color
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.product.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title(current))
                        .font(.title3.bold())
                }
                Spacer()
                DoneButton { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            tabs
            Divider().overlay(Color.white.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content(current)
                    Button(action: onReview) {
                        Text("Review Your Order")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(20)
            }
        }
        .presentationDetents([Self.short, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.short))
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .animation(.smooth(duration: 0.2), value: session.config)
    }

    /// One tab per option, with an underline on the one showing.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(steps) { step in
                let isCurrent = step == current
                Button {
                    withAnimation(.smooth(duration: 0.2)) { selected = step }
                } label: {
                    VStack(spacing: 4) {
                        if step == .color {
                            Circle()
                                .fill(config.frameColor)
                                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))
                                .frame(width: 18, height: 18)
                                .frame(height: 22)
                        } else {
                            Image(systemName: step.symbol(for: config.product))
                                .font(.system(size: 16, weight: .semibold))
                                .frame(height: 22)
                        }
                        Text(step.tabTitle)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(isCurrent ? Color.phantomCyan : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(isCurrent ? Color.phantomCyan : Color.clear)
                            .frame(height: 3)
                            .padding(.horizontal, 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.tabTitle)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Steps

    private func title(_ step: Step) -> String {
        switch step {
        case .type: return config.product.category == .door ? "Select Door Screen Type" : "Select Screen Type"
        case .measurement: return "Measurement"
        case .closure: return "Closure"
        case .control: return "Control"
        case .mesh: return "Mesh Type"
        case .color: return "Color"
        }
    }

    @ViewBuilder
    private func content(_ step: Step) -> some View {
        switch step {
        case .type: typeStep
        case .measurement: measurementStep
        case .closure: closureStep
        case .control: controlStep
        case .mesh: meshStep
        case .color: colorStep
        }
    }

    // MARK: Type

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Opening", selection: Binding(get: { config.product.category }, set: selectCategory)) {
                ForEach(OpeningCategory.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            ForEach(config.product.category.products) { product in
                OptionCard(title: product.title, detail: product.detail,
                           badge: product == session.suggestedProduct ? "Suggested" : nil,
                           symbol: product.symbol, selected: config.product == product) {
                    session.config.product = product
                }
            }

            if config.product.offersMeshLock {
                Text("I want:").font(.subheadline.weight(.semibold)).padding(.top, 4)
                OptionCard(title: "Door Screen",
                           detail: "Mesh floats along the track. Great for fresh air and keeping bugs out.",
                           selected: !config.meshLock) { session.config.meshLock = false }
                OptionCard(title: "Door Screen with Mesh Lock",
                           detail: "Mesh secured in the tracks with black vinyl corners. Great for fresh air, keeping bugs out, and people with small pets.",
                           selected: config.meshLock) { session.config.meshLock = true }
            }

            if config.product.hasRetractSide {
                HStack {
                    Text("Retracts to the").font(.subheadline)
                    Spacer()
                    Picker("Retracts to the", selection: $session.config.side) {
                        ForEach(RetractSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                .padding(.top, 4)
            }
            if !config.fitsProduct {
                sizeWarning
            }
        }
    }

    private func selectCategory(_ category: OpeningCategory) {
        guard category != config.product.category else { return }
        if let suggested = session.suggestedProduct, suggested.category == category {
            session.config.product = suggested
        } else if let first = category.products.first {
            session.config.product = first
        }
        session.config.mount = category == .outdoor ? .outside : .inside
    }

    private var sizeWarning: some View {
        let limit = config.product.maxSize
        return Label("This opening is larger than a standard \(config.product.title) (up to \(Length.size(width: limit.x, height: limit.y, unit: unit))). Your local expert will quote a custom size.",
                     systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(Color.phantomGuide)
    }

    // MARK: Measurement

    private var measurementStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Units", selection: $unit) {
                Text("Inches").tag(LengthUnit.inches)
                Text("Centimeters").tag(LengthUnit.centimeters)
            }
            .pickerStyle(.segmented)

            Text("Measured in AR").font(.subheadline.weight(.semibold))
            StepperRow(title: "Width", value: config.width, unit: unit,
                       range: ScreenConfig.widthRange) { session.config.width = $0 }
            StepperRow(title: "Height", value: config.height, unit: unit,
                       range: ScreenConfig.heightRange) { session.config.height = $0 }

            if config.product.usesSizeBands {
                bandList("Door Height", SizeBand.heights, selected: config.heightBand)
                bandList("Door Width", SizeBand.widths, selected: config.widthBand)
                Text("Selected automatically from your measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !config.fitsProduct {
                sizeWarning
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mount").font(.subheadline)
                    Text("Inside the frame, or on the wall face").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Mount", selection: $session.config.mount) {
                    ForEach(Mount.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            Text("Your local expert confirms final measurements on site.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bandList(_ title: String, _ bands: [SizeBand], selected: SizeBand?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).padding(.top, 4)
            ForEach(bands, id: \.upper) { band in
                OptionCard(title: band.title(unit), tag: band.tag, selected: band == selected) {}
                    .disabled(band != selected)
                    .opacity(band == selected ? 1 : 0.45)
            }
        }
    }

    // MARK: Closure, control, mesh

    private var closureStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Closure.allCases) { closure in
                OptionCard(title: closure.title, note: closure.note, tag: closure.tag,
                           selected: config.closure == closure) { session.config.closure = closure }
            }
        }
    }

    private var controlStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MotorControl.allCases) { control in
                OptionCard(title: control.title, detail: control.detail,
                           selected: config.motorControl == control) { session.config.motorControl = control }
            }
        }
    }

    private var meshStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionCard(title: MeshType.insect.title, detail: MeshType.insect.detail, tag: .included,
                       selected: config.mesh == .insect) { session.config.mesh = .insect }
            OptionCard(title: "Custom mesh", detail: "Pet, sun & heat, or privacy mesh.", tag: .additional,
                       selected: config.mesh.isCustom) {
                if !config.mesh.isCustom { session.config.mesh = .pet }
            }
            if config.mesh.isCustom {
                FlowChips(items: MeshType.customOptions, selected: config.mesh, title: \.shortTitle) {
                    session.config.mesh = $0
                }
                Text(config.mesh.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Color

    private var colorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let seen = trim.color {
                let closest = FrameFinish.closest(to: seen, lightKelvin: trim.lightKelvin)
                HStack(spacing: 10) {
                    FinishSwatch(finish: closest).frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Closest to your trim").font(.caption).foregroundStyle(.secondary)
                        Text(closest.title).font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    if config.finish != closest || config.colorUndecided {
                        Button("Use") { choose(closest) }
                            .buttonStyle(.bordered)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(FrameFinish.standard) { finish in
                    let selected = config.finish == finish && !config.colorUndecided
                    Button { choose(finish) } label: {
                        FinishSwatch(finish: finish)
                            .padding(4)
                            .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2.5))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(finish.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if config.finish.tag == .included, !config.colorUndecided {
                Text(config.finish.title).font(.subheadline.weight(.semibold))
            }

            // Wood grain, any custom color, or match a real color with the camera.
            HStack(spacing: 18) {
                specialSwatch("Wood grain", selected: config.finish == .woodGrain && !config.colorUndecided) {
                    Button { choose(.woodGrain) } label: {
                        FinishSwatch(finish: .woodGrain)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Wood grain")
                }
                specialSwatch("Custom", selected: config.finish == .custom && !config.colorUndecided) {
                    ZStack {
                        Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                      center: .center))
                        if config.finish == .custom {
                            Circle().fill(config.frameColor).padding(7)
                        }
                        ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .opacity(0.02)
                            .scaleEffect(1.6)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Choose a custom color")
                }
                specialSwatch("Match a color", selected: false) {
                    Button {
                        dismiss()
                        session.beginPicking(.customColor)
                    } label: {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.phantomNavy)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.phantomCyan, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Match a color with the camera")
                }
            }
            Text(specialCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            OptionCard(title: "I'm unsure, I'll decide later",
                       selected: config.colorUndecided) { session.config.colorUndecided.toggle() }

            VStack(alignment: .leading, spacing: 4) {
                Text("A disclaimer about color").font(.subheadline.weight(.semibold))
                Text("The way these colors look on your screen may differ from the coated samples or installed product. Having trouble choosing? Talk to your local expert to see true color swatches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Get in touch", action: onReview)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.phantomCyan)
            }
            .padding(.top, 4)
        }
    }

    private var specialCaption: String {
        if config.finish == .custom, !config.colorUndecided {
            let source = config.customMatchedToTrim ? "matched with the camera" : "chosen on screen"
            return "Custom Color \(config.customColorHex), \(source). Additional cost; your expert color-matches it on site."
        }
        return "Wood grain and custom colors are an additional cost. Tap the eyedropper and aim at anything, like your trim, to match its color."
    }

    /// A round swatch with a caption and a selection ring.
    private func specialSwatch<Swatch: View>(_ caption: String, selected: Bool,
                                             @ViewBuilder swatch: () -> Swatch) -> some View {
        VStack(spacing: 6) {
            swatch()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .padding(4)
                .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2.5))
            Text(caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func choose(_ finish: FrameFinish) {
        session.config.finish = finish
        session.config.colorUndecided = false
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { session.config.frameColor },
            set: { color in
                session.config.customColorHex = UIColor(color).hexString
                session.config.customMatchedToTrim = false
                session.config.finish = .custom
                session.config.colorUndecided = false
            }
        )
    }
}

/// A selectable card, styled after the website's option rows.
struct OptionCard: View {
    let title: String
    var detail: String?
    var note: String?
    var tag: PriceTag?
    var badge: String?
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline.weight(.semibold))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.phantomNavy)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.phantomCyan, in: Capsule())
                        }
                    }
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note).font(.caption.weight(.semibold)).foregroundStyle(Color.phantomCyan)
                    }
                    if let tag {
                        Text(tag.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.phantomCyan : Color.secondary)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.phantomNavy : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.phantomCyan.opacity(0.9) : Color.white.opacity(0.1),
                              lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
