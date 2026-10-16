import Foundation
import UIKit

struct SavedDesign: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var config: ScreenConfig
    var photoFile: String?

    var specText: String {
        var lines = [name]
        for item in config.lineItems(unit: .inches) {
            lines.append("\(item.label): \(item.value)")
        }
        if let note = config.customColorNote { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

/// Saved designs, persisted as JSON plus one JPEG preview each in Documents.
@MainActor
final class DesignStore: ObservableObject {
    @Published private(set) var designs: [SavedDesign] = []

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("designs.json") }

    init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Designs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([SavedDesign].self, from: data) {
            designs = decoded
        }
    }

    @discardableResult
    func add(name: String, config: ScreenConfig, photo: UIImage?) -> SavedDesign {
        var design = SavedDesign(name: name, config: config)
        if let photo, let data = photo.downscaled(maxDimension: 1600).jpegData(compressionQuality: 0.8) {
            let file = "\(design.id.uuidString).jpg"
            if (try? data.write(to: folder.appendingPathComponent(file))) != nil {
                design.photoFile = file
            }
        }
        designs.insert(design, at: 0)
        persist()
        return design
    }

    func deleteAll() {
        designs.forEach(delete)
    }

    func delete(_ design: SavedDesign) {
        if let file = design.photoFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        designs.removeAll { $0.id == design.id }
        thumbnails[design.id] = nil
        persist()
    }

    private var thumbnails: [UUID: UIImage] = [:]

    /// Small cached preview for lists; decoded from disk once.
    func thumbnail(for design: SavedDesign) -> UIImage? {
        if let cached = thumbnails[design.id] { return cached }
        guard let file = design.photoFile,
              let image = UIImage(contentsOfFile: folder.appendingPathComponent(file).path) else { return nil }
        let thumb = image.downscaled(maxDimension: 240)
        thumbnails[design.id] = thumb
        return thumb
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(designs) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

extension UIImage {
    /// A copy no larger than `maxDimension` on its longest side.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
