import RealityKit
import SwiftUI

struct RootView: View {
    @StateObject private var session = PhantomSession()
    @StateObject private var store = DesignStore()
    @State private var sheet: ActiveSheet?
    @AppStorage("units") private var unit: LengthUnit = .inches
    @AppStorage("onboarded") private var onboarded = false
    @State private var flashOpacity = 0.0
    /// The one step the Options sheet opens on, or nil for all of them.
    @State private var optionsFocus: BuildSheet.Step?

    enum ActiveSheet: String, Identifiable {
        case options, review, designs, help, settings
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: session.arView)
                .ignoresSafeArea()

            switch session.stage {
            case .finding:
                // Tapping the doorway or window (or its frame) points detection at it.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(SpatialTapGesture().onEnded { session.setTarget(at: $0.location) })
                TargetMarker(live: session.live.detection)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                DetectionOverlay(session: session, live: session.live.detection, unit: unit)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                FindControls(session: session, sheet: $sheet)
            case .corners:
                CornerGuide(session: session, live: session.live.corners, unit: unit)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                Crosshair(active: session.crosshairOnSurface)
                    .allowsHitTesting(false)
                CornerControls(session: session, sheet: $sheet)
            case .placed:
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        // Near a corner: move it. Near the pull bar: slide the screen.
                        DragGesture(minimumDistance: 0)
                            .onChanged { session.touchChanged(at: $0.location) }
                            .onEnded { _ in session.touchEnded() }
                    )
                // Corner handles show in corner editing, or while a corner of
                // the screen is being dragged; otherwise the screen is clean.
                if session.isAdjusting || session.isDraggingCorner {
                    AdjustOverlay(session: session, live: session.live.corners, unit: unit)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else if session.pickerPurpose == nil {
                    HandleHintLayer(live: session.live.hint,
                                    text: session.config.product.isMotorized ? "Drag the bottom bar" : "Drag the handle")
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                if let purpose = session.pickerPurpose {
                    ColorPickerOverlay(session: session, live: session.live.picker, purpose: purpose)
                } else {
                    PlacedControls(session: session, unit: unit, sheet: $sheet) { step in
                        optionsFocus = step
                        sheet = .options
                    }
                }
            }

            ToastLayer(live: session.live.status)
                .allowsHitTesting(false)

            if session.showDebug {
                DebugOverlay(live: session.live.debug, stage: session.stage)
                    .allowsHitTesting(false)
            }

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.25), value: session.stage)
        .onChange(of: session.flash) { _, _ in
            flashOpacity = 0.7
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
        .onAppear { if onboarded { session.start() } }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView {
                onboarded = true
                session.start()
            }
        }
        .onChange(of: sheet) { _, value in session.menuOpen = value != nil }
        .sheet(item: $sheet) { item in
            switch item {
            case .options:
                BuildSheet(session: session, trim: session.live.trim, unit: $unit, focus: optionsFocus) { sheet = .review }
            case .review:
                ReviewView(session: session, store: store, unit: unit) {
                    optionsFocus = nil
                    sheet = .options
                }
            case .designs:
                DesignsView(store: store)
            case .help:
                HelpView()
            case .settings:
                SettingsView(session: session)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Finding

private struct DetectionOverlay: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var live: DetectionLive
    let unit: LengthUnit

    var body: some View {
        let quad = live.quad
        ZStack {
            if quad.count == 4 {
                Path { path in
                    path.addLines(quad)
                    path.closeSubpath()
                }
                .fill(Color.phantomGuide.opacity(session.isLocked ? 0.14 : 0.06))

                Path { path in
                    path.addLines(quad)
                    path.closeSubpath()
                }
                .stroke(Color.phantomGuide,
                        style: StrokeStyle(lineWidth: session.isLocked ? 4 : 2, lineJoin: .round,
                                           dash: session.isLocked ? [] : [8, 6]))

                if let opening = session.detectedOpening {
                    DimensionChip(text: Length.string(opening.width, unit: unit))
                        .position(x: (quad[0].x + quad[1].x) / 2, y: min(quad[0].y, quad[1].y) - 22)
                    DimensionChip(text: Length.string(opening.height, unit: unit))
                        .fixedSize()
                        .position(x: max(quad[1].x, quad[2].x) + 46, y: (quad[1].y + quad[2].y) / 2)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: quad)
    }
}

private struct FindControls: View {
    @ObservedObject var session: PhantomSession
    @Binding var sheet: RootView.ActiveSheet?

    private var status: String {
        if !session.autoDetect { return "Auto-detect is off" }
        if session.tapToTarget && !session.hasTarget { return "Tap the opening" }
        if session.isLocked { return "\(session.openingKind) found" }
        if session.hasCandidate { return "Hold steady…" }
        return session.detectionPrompt
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                GlassIconButton(systemName: "square.stack", label: "Saved designs") { sheet = .designs }
                Spacer()
                GlassPill(text: status) {
                    Circle()
                        .fill(session.isLocked ? Color.phantomGuide : Color.white.opacity(0.5))
                        .frame(width: 8, height: 8)
                }
                Spacer()
                GlassIconButton(systemName: "gearshape", label: "Settings") { sheet = .settings }
            }
            TrackingHint(live: session.live.status)
            Spacer()
            HintBubble(text: !session.autoDetect
                       ? "Tap Corners and mark two opposite corners."
                       : session.isLocked
                       ? "Edges locked. Tap Place to add a screen."
                       : session.hasTarget
                       ? "Looking at the spot you tapped. Tap again to change it."
                       : "Tap the opening to help, or mark the corners yourself.")
            GlassGroup {
                HStack {
                    ToolbarButton(systemName: "viewfinder", title: "Corners") { session.startCorners() }
                        .frame(maxWidth: .infinity)
                    ShutterButton(systemName: "checkmark", title: "Place", enabled: session.isLocked) {
                        session.placeDetected()
                    }
                    .frame(maxWidth: .infinity)
                    ToolbarButton(systemName: "questionmark", title: "Tips") { sheet = .help }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Corners

private struct Crosshair: View {
    let active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 2.5).frame(width: 44, height: 44)
            Circle().fill(active ? Color.phantomGuide : .white).frame(width: 9, height: 9)
        }
        .shadow(color: .black.opacity(0.4), radius: 3)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

private struct CornerControls: View {
    @ObservedObject var session: PhantomSession
    @Binding var sheet: RootView.ActiveSheet?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                GlassIconButton(systemName: "xmark", label: "Cancel") { session.backToAuto() }
                Spacer()
                GlassPill(text: "Corner \(min(session.cornerCount + 1, 2)) of 2") {
                    HStack(spacing: 4) {
                        ForEach(0..<2) { index in
                            Circle()
                                .fill(index < session.cornerCount ? Color.phantomGuide : Color.white.opacity(0.6))
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                Spacer()
                GlassIconButton(systemName: "gearshape", label: "Settings") { sheet = .settings }
            }
            TrackingHint(live: session.live.status)
            Spacer()
            HintBubble(text: session.cornerCount == 0
                       ? "Put the dot on one corner of the opening, then tap +"
                       : "Now the opposite corner, then tap +")
            GlassGroup {
                HStack {
                    ToolbarButton(systemName: "arrow.uturn.backward", title: "Undo") { session.undoCorner() }
                        .frame(maxWidth: .infinity)
                        .opacity(session.cornerCount == 0 ? 0.4 : 1)
                    ShutterButton(systemName: "plus", title: "Add corner", enabled: session.crosshairOnSurface) {
                        session.addCorner()
                    }
                    .frame(maxWidth: .infinity)
                    ToolbarButton(systemName: "rectangle.dashed", title: "Auto") { session.backToAuto() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Placed

/// Ring where the user tapped to pick the opening.
private struct TargetMarker: View {
    @ObservedObject var live: DetectionLive

    var body: some View {
        ZStack {
            if let target = live.target {
                ZStack {
                    Circle().stroke(Color.phantomGuide, lineWidth: 3).frame(width: 34, height: 34)
                    Circle().fill(Color.phantomGuide).frame(width: 8, height: 8)
                }
                .shadow(color: .black.opacity(0.4), radius: 3)
                .position(target)
            }
        }
    }
}

private struct HandleHintLayer: View {
    @ObservedObject var live: HintLive
    let text: String

    var body: some View {
        ZStack {
            if let hint = live.point {
                HandleHint(text: text).position(hint)
            }
        }
    }
}

private struct HandleHint: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.phantomGuide, lineWidth: 3)
                .frame(width: 56, height: 56)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .opacity(pulse ? 0.4 : 1)
            HintBubble(text: text)
                .fixedSize()
                .offset(y: 64)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct PlacedControls: View {
    @ObservedObject var session: PhantomSession
    let unit: LengthUnit
    @Binding var sheet: RootView.ActiveSheet?
    /// Opens the Options sheet on one step, or on all of them (nil).
    let openOptions: (BuildSheet.Step?) -> Void
    @State private var fanOpen = false
    @State private var hovered: BuildSheet.Step?
    @State private var fanCenter: CGPoint = .zero

    private var quickOptions: [QuickOption] { QuickOption.options(for: session.config) }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    Button { session.setAdjusting(true) } label: { Label("Edit corners", systemImage: "crop") }
                    Button { sheet = .designs } label: { Label("Saved designs", systemImage: "square.stack") }
                    Button { sheet = .help } label: { Label("Tips", systemImage: "questionmark.circle") }
                    Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glass(Circle(), interactive: true)
                }
                .accessibilityLabel("More")
                Spacer()
                GlassPill(text: session.comparing
                          ? "Before"
                          : Length.size(width: session.config.width, height: session.config.height, unit: unit))
                Spacer()
                if !session.isAdjusting {
                    CompareButton(session: session)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            Spacer()
            if session.isAdjusting {
                HintBubble(text: session.snapCorners
                           ? "Drag each corner onto the real corner. The screen hides while you drag; corners snap to nearby surfaces."
                           : "Drag each corner onto the real corner. The screen hides while you drag.")
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { session.refitWall() } label: {
                            Label("Re-fit wall", systemImage: "square.3.layers.3d.down.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .glass(Capsule(), interactive: true)
                        Button { session.resetFitToScan() } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .glass(Capsule(), interactive: true)
                    }
                }
                Button {
                    session.setAdjusting(false)
                } label: {
                    Text("Done")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                placedBottom
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay {
            if fanOpen {
                QuickOptionsFan(options: quickOptions, center: fanCenter, hovered: hovered) { step in
                    fanOpen = false
                    openOptions(step)
                } close: {
                    withAnimation(.smooth(duration: 0.2)) { fanOpen = false }
                }
            }
        }
        .coordinateSpace(.named("placed"))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: fanOpen)
        .animation(.smooth(duration: 0.15), value: hovered)
    }

    private var placedBottom: some View {
        VStack(spacing: 12) {
            if session.config.product.isMotorized {
                MotorControls(session: session)
            }
            HStack(spacing: 10) {
                SummaryChips(config: session.config, unit: unit) { openOptions($0) }
                Button { sheet = .review } label: {
                    Text("Review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review your order")
            }
            GlassGroup {
                HStack {
                    ToolbarButton(systemName: "arrow.counterclockwise", title: "Measure again") { session.remeasure() }
                        .frame(maxWidth: .infinity)
                    ShutterButton(systemName: nil, title: "Photo") { session.capturePhoto() }
                        .frame(maxWidth: .infinity)
                    OptionsButton(fanOpen: $fanOpen, hovered: $hovered, center: $fanCenter,
                                  options: quickOptions) { openOptions($0) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Quick options

/// One of the round buttons that fan out of the Options button.
struct QuickOption: Identifiable {
    let step: BuildSheet.Step
    let symbol: String
    let title: String
    var id: BuildSheet.Step { step }

    static func options(for config: ScreenConfig) -> [QuickOption] {
        var list = [QuickOption(step: .color, symbol: "paintpalette", title: "Color"),
                    QuickOption(step: .mesh, symbol: "square.grid.3x3", title: "Mesh")]
        if config.product.offersClosure {
            list.append(QuickOption(step: .closure, symbol: "hand.raised", title: "Handle"))
        }
        if config.product.isMotorized {
            list.append(QuickOption(step: .control, symbol: "dot.radiowaves.left.and.right", title: "Control"))
        }
        list.append(QuickOption(step: .measurement, symbol: "ruler", title: "Size"))
        list.append(QuickOption(step: .type, symbol: config.product.symbol, title: "Type"))
        return list
    }

    /// Centres of the option buttons: an arc above and to the left of the
    /// Options button, from beside it to straight above it.
    static func positions(count: Int, around center: CGPoint) -> [CGPoint] {
        let radius: CGFloat = 122
        return (0..<count).map { index in
            let t = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            let angle = (170 - t * 90) * CGFloat.pi / 180
            return CGPoint(x: center.x + radius * cos(angle), y: center.y - radius * sin(angle))
        }
    }
}

private struct OptionsCenterKey: PreferenceKey {
    static let defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// The Options button. Tap it to fan out the quick options, then tap one;
/// or press, slide to an option and let go. Tapping again closes the fan.
private struct OptionsButton: View {
    @Binding var fanOpen: Bool
    @Binding var hovered: BuildSheet.Step?
    @Binding var center: CGPoint
    let options: [QuickOption]
    let choose: (BuildSheet.Step?) -> Void
    @State private var pressing = false
    @State private var wasOpen = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: fanOpen ? "xmark" : "slider.horizontal.3")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
                .glass(Circle(), interactive: true)
                .background(GeometryReader { geometry in
                    let frame = geometry.frame(in: .named("placed"))
                    Color.clear.preference(key: OptionsCenterKey.self, value: CGPoint(x: frame.midX, y: frame.midY))
                })
                .gesture(drag)
            Text("Options")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .onPreferenceChange(OptionsCenterKey.self) { center = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Options")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(nil) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("placed"))
            .onChanged { value in
                if !pressing {
                    pressing = true
                    wasOpen = fanOpen
                    if !fanOpen {
                        fanOpen = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                let moved = hypot(value.translation.width, value.translation.height) > 12
                let next = moved ? option(at: value.location) : nil
                if next != hovered {
                    hovered = next
                    if next != nil { UISelectionFeedbackGenerator().selectionChanged() }
                }
            }
            .onEnded { value in
                pressing = false
                let moved = hypot(value.translation.width, value.translation.height) > 12
                if let pick = hovered {
                    hovered = nil
                    fanOpen = false
                    choose(pick)
                } else if moved || wasOpen {
                    // Slid off without choosing, or a second tap: close.
                    fanOpen = false
                }
                // A plain tap leaves the fan open for a tap on an option.
            }
    }

    private func option(at point: CGPoint) -> BuildSheet.Step? {
        let spots = QuickOption.positions(count: options.count, around: center)
        var best: (step: BuildSheet.Step, distance: CGFloat)?
        for (option, spot) in zip(options, spots) {
            let distance = hypot(spot.x - point.x, spot.y - point.y)
            if distance < 44, distance < (best?.distance ?? .infinity) { best = (option.step, distance) }
        }
        return best?.step
    }
}

/// The fanned-out option buttons over a dimmed background.
private struct QuickOptionsFan: View {
    let options: [QuickOption]
    let center: CGPoint
    let hovered: BuildSheet.Step?
    let choose: (BuildSheet.Step) -> Void
    let close: () -> Void

    var body: some View {
        let spots = QuickOption.positions(count: options.count, around: center)
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityLabel("Close options")
                .accessibilityAddTraits(.isButton)
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let lit = hovered == option.step
                Button { choose(option.step) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(lit ? Color.phantomNavy : Color.white)
                            .frame(width: 54, height: 54)
                            .background(lit ? Color.phantomCyan : Color.clear, in: Circle())
                            .glass(Circle(), interactive: true)
                        Text(option.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                    .scaleEffect(lit ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .position(x: spots[index].x, y: spots[index].y + 9)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
                .accessibilityLabel(option.title)
            }
        }
    }
}

/// The current choices as chips; each opens its own option step.
private struct SummaryChips: View {
    let config: ScreenConfig
    let unit: LengthUnit
    let open: (BuildSheet.Step) -> Void

    private struct Chip: Identifiable {
        let step: BuildSheet.Step
        let symbol: String?
        let text: String
        var id: BuildSheet.Step { step }
    }

    private var chips: [Chip] {
        var list = [Chip(step: .color, symbol: nil, text: config.colorTitle),
                    Chip(step: .mesh, symbol: "square.grid.3x3", text: config.mesh.title)]
        if config.product.offersClosure {
            list.append(Chip(step: .closure, symbol: "hand.raised", text: config.closure.shortTitle))
        }
        if config.product.isMotorized {
            list.append(Chip(step: .control, symbol: "dot.radiowaves.left.and.right", text: config.motorControl.title))
        }
        let size = Length.size(width: config.width, height: config.height, unit: unit)
        list.append(Chip(step: .measurement, symbol: "ruler", text: config.fitsProduct ? size : size + " · custom"))
        list.append(Chip(step: .type, symbol: config.product.symbol,
                         text: config.product.shortTitle + (config.hasMeshLock ? " · Mesh Lock" : "")))
        return list
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button { open(chip.step) } label: {
                        HStack(spacing: 6) {
                            if chip.step == .color {
                                Circle()
                                    .fill(config.frameColor)
                                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))
                                    .frame(width: 16, height: 16)
                            } else if let symbol = chip.symbol {
                                Image(systemName: symbol).font(.caption.weight(.semibold))
                            }
                            Text(chip.text)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .glass(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Change this option")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

/// Raise, stop and lower for motorized screens.
private struct MotorControls: View {
    let session: PhantomSession

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                GlassIconButton(systemName: "chevron.up", label: "Raise the screen") { session.raiseScreen() }
                GlassIconButton(systemName: "stop.fill", label: "Stop") { session.stopScreen() }
                GlassIconButton(systemName: "chevron.down", label: "Lower the screen") { session.lowerScreen() }
            }
        }
    }
}

/// Toasts, above the bottom controls.
private struct ToastLayer: View {
    @ObservedObject var live: StatusLive

    var body: some View {
        VStack {
            Spacer()
            if let toast = live.toast {
                HintBubble(text: toast)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 210)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.smooth(duration: 0.25), value: live.toast)
    }
}

/// ARKit's tracking state, when it needs the user's help.
private struct TrackingHint: View {
    @ObservedObject var live: StatusLive

    var body: some View {
        if let message = live.trackingMessage {
            HintBubble(text: message)
        }
    }
}

/// Developer overlay: frame rate and how the opening was found.
private struct DebugOverlay: View {
    @ObservedObject var live: DebugLive
    let stage: PhantomSession.Stage

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(live.fps) fps")
                    if stage == .finding {
                        Text("Found by: \(live.method)")
                        Text("Wall plane: \(live.wall ? "yes" : "no")")
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.green)
                .padding(6)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }
            .padding(.top, 64)
            .padding(.leading, 12)
            Spacer()
        }
    }
}

/// Press and hold to hide the screen and see the opening as it is today.
private struct CompareButton: View {
    @ObservedObject var session: PhantomSession

    var body: some View {
        Image(systemName: session.comparing ? "eye.slash" : "square.split.2x1")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glass(Circle(), interactive: true)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !session.comparing { session.comparing = true } }
                    .onEnded { _ in session.comparing = false }
            )
            .accessibilityLabel("Hold to compare before and after")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.comparing.toggle() }
    }
}

// MARK: - Corner guides

/// Diagonal from the first corner to the crosshair, and the faint rectangle it makes.
private struct CornerGuide: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var live: CornerLive
    let unit: LengthUnit

    var body: some View {
        ZStack {
            if let preview = live.preview {
                if session.showRectangle, preview.quad.count == 4 {
                    Path { path in
                        path.addLines(preview.quad)
                        path.closeSubpath()
                    }
                    .fill(Color.phantomGuide.opacity(0.1))
                    Path { path in
                        path.addLines(preview.quad)
                        path.closeSubpath()
                    }
                    .stroke(Color.phantomGuide.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    DimensionChip(text: Length.string(preview.width, unit: unit))
                        .position(x: (preview.quad[0].x + preview.quad[1].x) / 2,
                                  y: min(preview.quad[0].y, preview.quad[1].y) - 20)
                    DimensionChip(text: Length.string(preview.height, unit: unit))
                        .fixedSize()
                        .position(x: max(preview.quad[1].x, preview.quad[2].x) + 46,
                                  y: (preview.quad[1].y + preview.quad[2].y) / 2)
                }
                if session.showDiagonal {
                    Path { path in
                        path.move(to: preview.start)
                        path.addLine(to: preview.end)
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    Circle()
                        .fill(Color.phantomGuide)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(preview.start)
                }
            }
        }
    }
}

/// Outline and corner handles while fine-tuning the fit.
private struct AdjustOverlay: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var live: CornerLive
    let unit: LengthUnit

    var body: some View {
        let handles = live.handles
        let outline = live.outline.count == 4 ? live.outline : handles
        ZStack {
            if handles.count == 4 {
                // Where the corners are, and the rectangle fitted through them.
                Path { path in
                    path.addLines(handles)
                    path.closeSubpath()
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Path { path in
                    path.addLines(outline)
                    path.closeSubpath()
                }
                .stroke(Color.phantomGuide, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                ForEach(0..<4, id: \.self) { index in
                    ZStack {
                        Circle().fill(Color.phantomGuide.opacity(0.25)).frame(width: 44, height: 44)
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(Color.phantomGuide, lineWidth: 3))
                            .frame(width: 20, height: 20)
                    }
                    .position(handles[index])
                }
                DimensionChip(text: Length.string(session.config.width, unit: unit))
                    .position(x: (outline[0].x + outline[1].x) / 2, y: min(outline[0].y, outline[1].y) - 28)
                DimensionChip(text: Length.string(session.config.height, unit: unit))
                    .fixedSize()
                    .position(x: max(outline[1].x, outline[2].x) + 50, y: (outline[1].y + outline[2].y) / 2)
            }
        }
    }
}

// MARK: - Color picker

/// Reticle in the middle of the screen with a live swatch of what it sees.
private struct ColorPickerOverlay: View {
    @ObservedObject var session: PhantomSession
    @ObservedObject var live: PickerLive
    let purpose: PickerPurpose

    private var title: String {
        purpose == .whiteBalance ? "White balance" : "Match a color"
    }

    private var instruction: String {
        purpose == .whiteBalance
            ? "Aim at your white trim, with the screen's frame still in view."
            : "Aim the circle at any color, like your trim. It becomes the frame color."
    }

    var body: some View {
        ZStack {
            // Reticle
            ZStack {
                Circle().stroke(.white, lineWidth: 2.5).frame(width: 64, height: 64)
                Circle().stroke(.black.opacity(0.35), lineWidth: 1).frame(width: 69, height: 69)
                Circle().fill(.white).frame(width: 6, height: 6)
            }
            .shadow(color: .black.opacity(0.4), radius: 3)
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                GlassPill(text: title)
                Spacer()
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(live.color.map { Color($0) } ?? Color.gray)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.6), lineWidth: 1))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(live.color?.hexString ?? "Sampling…")
                            .font(.headline.monospaced())
                        Text(instruction)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(12)
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(spacing: 12) {
                    Button { session.cancelPicking() } label: {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .glass(Capsule(), interactive: true)

                    Button { session.confirmPicking() } label: {
                        Text(purpose == .whiteBalance ? "Match white" : "Use this color")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(live.color == nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }
}
