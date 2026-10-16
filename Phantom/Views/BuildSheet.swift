import SwiftUI

/// "Build your screen": the website's steps, with every choice already made
/// from the measurement and the most popular options, so the customer only
/// changes what they want to. The screen in AR updates live behind the sheet.
struct BuildSheet: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var trim: TrimLive
    @Binding var unit: LengthUnit
    let onReview: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var open: Step?

    enum Step: Hashable {
        case type, measurement, closure, control, mesh, color
    }

    private var config: ScreenConfig { session.config }

    private var steps: [Step] {
        var list: [Step] = [.type, .measurement]
        if config.product.offersClosure { list.append(.closure) }
        if config.product.isMotorized { list.append(.control) }
        list += [.mesh, .color]
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You are customizing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(config.product.title)
                            .font(.title3.bold())
                    }
                    Spacer()
                    DoneButton { dismiss() }
                }
                .padding(.bottom, 8)

                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    StepSection(number: index + 1, title: title(step), summary: summary(step),
                                isOpen: open == step) {
                        withAnimation(.smooth(duration: 0.25)) { open = open == step ? nil : step }
                    } content: {
                        content(step)
                    }
                    Divider().overlay(Color.white.opacity(0.12))
                }

                Button(action: onReview) {
                    Text("Review Your Order")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)
                Text("Everything above was chosen for you from your measurement. Tap Edit on any step to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .animation(.smooth(duration: 0.2), value: session.config)
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

    private func summary(_ step: Step) -> String {
        switch step {
        case .type:
            var text = config.product.title
            if config.hasMeshLock { text += " with Mesh Lock" }
            if config.product.hasRetractSide { text += " · retracts \(config.side.title.lowercased())" }
            return text
        case .measurement:
            if let h = config.heightBand, let w = config.widthBand {
                return "Height: \(h.title(unit))   Width: \(w.title(unit))"
            }
            return Length.size(width: config.width, height: config.height, unit: unit)
                + (config.fitsProduct ? "" : " · custom size")
        case .closure: return config.closure.title
        case .control: return config.motorControl.title
        case .mesh: return config.mesh.title
        case .color: return config.colorUndecided ? "I'll decide later" : config.finishTitle
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
                let closest = FrameFinish.closest(to: seen)
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

            OptionCard(title: "Wood grain", detail: "Wood-look finishes in many tones.", tag: .additional,
                       selected: config.finish == .woodGrain && !config.colorUndecided) { choose(.woodGrain) }
            OptionCard(title: "Custom Color", detail: "Matched to a color or swatch you choose.", tag: .additional,
                       selected: config.finish == .custom && !config.colorUndecided) { choose(.custom) }
            if config.finish == .custom, !config.colorUndecided {
                HStack(spacing: 10) {
                    ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                        .font(.subheadline)
                    Button {
                        dismiss()
                        session.beginPicking(.customColor)
                    } label: {
                        Label("Match my trim", systemImage: "eyedropper")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
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

/// One numbered step: a header with its current choice and Edit, and its
/// options when open.
private struct StepSection<Content: View>: View {
    let number: Int
    let title: String
    let summary: String
    let isOpen: Bool
    let toggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(number)")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.phantomNavy)
                        .frame(width: 26, height: 26)
                        .background(Color.phantomCyan, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        if !isOpen {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(isOpen ? "Done" : "Edit")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.phantomCyan)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Closes this step" : "Shows the options for this step")

            if isOpen {
                content.transition(.opacity)
            }
        }
        .padding(.vertical, 14)
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
