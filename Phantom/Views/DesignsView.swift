import SwiftUI

struct DesignsView: View {
    @ObservedObject var store: DesignStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.designs.isEmpty {
                    ContentUnavailableView(
                        "No saved designs",
                        systemImage: "square.stack",
                        description: Text("Designs are saved when you send a quote request.")
                    )
                } else {
                    List {
                        ForEach(store.designs) { design in
                            DesignRow(design: design, photo: store.thumbnail(for: design))
                        }
                        .onDelete { offsets in
                            offsets.map { store.designs[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Designs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct DesignRow: View {
    let design: SavedDesign
    let photo: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    design.config.frameColor
                }
            }
            .frame(width: 54, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(design.name).font(.headline)
                Text(design.config.summary).font(.subheadline).foregroundStyle(.secondary)
                Text(Length.size(width: design.config.width, height: design.config.height, unit: .inches))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: design.specText) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpList()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HelpList: View {
    var body: some View {
        List {
            Section("Finding the opening") {
                Label("Stand 2–3 m (6–10 ft) back so the whole opening and some wall around it are on screen.", systemImage: "figure.stand")
                Label("Tap the opening (or its frame) to point the search at it.", systemImage: "hand.tap")
                Label("Closed doors work too: move the phone slowly for a moment so it can recognize the door.", systemImage: "door.left.hand.closed")
                Label("LiDAR can't see glass. Windows work best with the frame and wall around them in view.", systemImage: "window.vertical.closed")
                Label("Large outdoor openings may be out of LiDAR's reach (about 5 m). Mark the corners instead.", systemImage: "sun.max")
            }
            Section("Marking corners") {
                Label("Put the dot on one corner, tap +, then aim at the opposite corner.", systemImage: "plus.circle")
                Label("The line and rectangle preview show the size before you tap.", systemImage: "rectangle.dashed")
                Label("After placing, touch a corner of the screen and drag it onto the real corner. Handles show while you drag.", systemImage: "crop")
            }
            Section("Your screen") {
                Label("Drag the pull handle (or the bottom bar of a motorized screen) to open and close it.", systemImage: "hand.draw")
                Label("Hold the compare button to see the opening without it.", systemImage: "square.split.2x1")
                Label("Everything starts chosen for you. Tap a chip above the toolbar to change that option, or press Options and slide to one.", systemImage: "slider.horizontal.3")
                Label("In Color, the eyedropper matches any real color with the camera.", systemImage: "eyedropper")
                Label("Colors on screen are approximate. Your local expert brings real swatches.", systemImage: "paintpalette")
            }
        }
        .navigationTitle("Tips")
        .navigationBarTitleDisplayMode(.inline)
    }
}
