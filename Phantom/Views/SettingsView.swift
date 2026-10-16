import SwiftUI

/// Everyday settings. Tuning and developer options live under Advanced.
struct SettingsView: View {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    @ObservedObject var session: PhantomSession
    @AppStorage("units") private var unit: LengthUnit = .inches
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $unit) {
                        Text("Inches").tag(LengthUnit.inches)
                        Text("Centimeters").tag(LengthUnit.centimeters)
                    }
                    NavigationLink("Tips for good measurements") { HelpList() }
                }

                Section("App icon") {
                    AppIconPicker()
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView(session: session, closeSettings: { dismiss() })
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Detection, alignment, lighting and developer options.")
                }

                Section {
                    Link(destination: URL(string: "tel:18887426866")!) {
                        Label("Call Phantom: 1-888-PHANTOM", systemImage: "phone")
                    }
                    LabeledContent("Version", value: Self.versionText)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Tuning for testing and development. Everything here has a sensible
/// default; customers never need to open it.
struct AdvancedSettingsView: View {
    @ObservedObject var session: PhantomSession
    let closeSettings: () -> Void
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        Form {
            Section {
                Toggle("Find openings automatically", isOn: $session.autoDetect)
                Toggle("Wait for a tap before finding", isOn: $session.tapToTarget)
                    .disabled(!session.autoDetect)
                Toggle("Show detected surfaces", isOn: $session.showSurfaces)
            } header: {
                Text("Detection")
            } footer: {
                Text(session.hasLiDAR
                     ? "Uses LiDAR depth measured against ARKit's wall plane, and ARKit's door and window labels for closed doors. A tap points the search at an opening."
                     : "This iPhone has no LiDAR, so detection looks for the frame's outline and works best with clear edges.")
            }

            Section {
                Toggle("Diagonal guide line", isOn: $session.showDiagonal)
                Toggle("Rectangle preview", isOn: $session.showRectangle)
                Toggle("Snap corners to surfaces", isOn: $session.snapCorners)
                Toggle("Keep screen plumb (vertical)", isOn: $session.keepPlumb)
            } header: {
                Text("Corners")
            } footer: {
                Text("After placing, touch and drag a corner of the screen to move it.")
            }

            if session.stage == .placed {
                placementSection
            }

            Section {
                Toggle("Realistic lighting and shadows", isOn: $session.realisticLighting)
                Toggle("Match white to trim automatically", isOn: $session.autoMatchWhite)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text(String(format: "%+.1f", session.brightness))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $session.brightness, in: -1...1, step: 0.1)
                        .accessibilityLabel("Screen brightness")
                }
                Picker("Paint finish", selection: $session.gloss) {
                    ForEach(PaintGloss.allCases) { Text($0.title).tag($0) }
                }
                if session.hasLiDAR {
                    Toggle("Hide behind real objects", isOn: $session.occlusion)
                }
                Toggle("Outdoor sun shadows", isOn: $session.sunMode)
                if session.sunMode {
                    Picker("Sunlight on the opening", selection: $session.sunExposure) {
                        ForEach(SunExposure.allCases) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("Realism")
            } footer: {
                Text("White matching compares the screen's frame with your real trim when the screen appears, then checks again every few seconds. Brightness adds to it. Outdoor sun shadows uses your location, the time and the compass; turning it on restarts measuring.")
            }

            if session.stage == .placed {
                Section {
                    Button {
                        closeSettings()
                        session.beginPicking(.whiteBalance)
                    } label: {
                        Label("Pick the trim by hand", systemImage: "eyedropper.halffull")
                    }
                    Button {
                        session.matchWhiteToTrim()
                    } label: {
                        Label(session.isMatchingWhite ? "Matching…" : "Match white now", systemImage: "wand.and.stars")
                    }
                    .disabled(session.isMatchingWhite)
                    Button("Reset white matching", role: .destructive) { session.resetWhiteMatch() }
                } header: {
                    Text("White balance")
                } footer: {
                    Text("Picking the trim by hand pauses the automatic checks until Reset.")
                }
            }

            Section {
                Toggle("Debug overlay", isOn: $session.showDebug)
                Toggle("Turn off depth after placing", isOn: $session.depthOffWhenPlaced)
                Button("Show the introduction again") {
                    onboarded = false
                    closeSettings()
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("The overlay shows frame rate, how the opening was found and whether a wall plane was used. Turning off depth after placing saves battery; it takes effect on the next placement.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var placementSection: some View {
        Section {
            ExtentSlider(session: session, live: session.live.screen)
            Button {
                closeSettings()
                session.setAdjusting(true)
            } label: {
                Label("Edit all four corners", systemImage: "crop")
            }
            Button {
                session.refitWall()
            } label: {
                Label("Re-fit to the wall", systemImage: "square.3.layers.3d.down.right")
            }
            NudgeRow(title: "Turn", detail: "Left / right", minus: "rotate.left", plus: "rotate.right") {
                session.rotate(.turn, degrees: $0 ? 0.5 : -0.5)
            }
            if !session.keepPlumb {
                NudgeRow(title: "Tilt", detail: "Top in / out", minus: "arrow.down.forward", plus: "arrow.up.backward") {
                    session.rotate(.tilt, degrees: $0 ? 0.5 : -0.5)
                }
                NudgeRow(title: "Twist", detail: "Clockwise", minus: "arrow.counterclockwise", plus: "arrow.clockwise") {
                    session.rotate(.twist, degrees: $0 ? -0.5 : 0.5)
                }
            }
            NudgeRow(title: "Depth", detail: "1 cm steps", minus: "arrow.down.to.line", plus: "arrow.up.to.line") {
                session.moveDepth($0 ? 0.01 : -0.01)
            }
            if session.scannedSize != nil {
                Button {
                    session.resetFitToScan()
                } label: {
                    Label("Reset to the measured fit", systemImage: "arrow.counterclockwise")
                }
            }
        } header: {
            Text("Placement")
        } footer: {
            Text("Turn, tilt and twist move in ½° steps. Turn off Keep plumb for walls that lean.")
        }
    }
}

/// Lets the user pick one of the bundled alternate Home Screen icons.
private struct AppIconPicker: View {
    @State private var current = UIApplication.shared.alternateIconName
    @State private var errorText: String?

    private struct Option {
        let iconName: String?
        let title: String
        let preview: String
    }

    private let options = [
        Option(iconName: nil, title: "Classic", preview: "IconPreview-Classic"),
        Option(iconName: "AppIcon-Pattern", title: "Pattern", preview: "IconPreview-Pattern"),
        Option(iconName: "AppIcon-Light", title: "Light", preview: "IconPreview-Light"),
        Option(iconName: "AppIcon-Cyan", title: "Cyan", preview: "IconPreview-Cyan")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(options, id: \.title) { option in
                    let selected = option.iconName == current
                    Button {
                        choose(option.iconName)
                    } label: {
                        VStack(spacing: 6) {
                            Image(option.preview)
                                .resizable()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                                        .padding(-4)
                                )
                            Text(option.title)
                                .font(.caption)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) icon")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func choose(_ name: String?) {
        guard name != current else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorText = "This iPhone doesn't support changing the icon."
            return
        }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(name)
                current = name
                errorText = nil
            } catch {
                errorText = "Couldn't change the icon: \(error.localizedDescription)"
            }
        }
    }
}
