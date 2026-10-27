import AppKit
import ImageIO
import Vision

/// One background Vision pass per artwork URL, shared across scene/window changes.
@MainActor
enum V3ArtworkSubject {
    struct Analysis: Sendable {
        let imageSize: CGSize
        /// Normalized top-left attention/face regions, matching SwiftUI's canvas.
        let regions: [CGRect]

        func subjects(in artworkRect: CGRect) -> [CGRect] {
            regions.map { region in
                CGRect(x: artworkRect.minX + region.minX * artworkRect.width,
                       y: artworkRect.minY + region.minY * artworkRect.height,
                       width: region.width * artworkRect.width, height: region.height * artworkRect.height)
            }
        }
    }

    private static var tasks: [URL: Task<Analysis?, Never>] = [:]

    static func analysis(for url: URL?) async -> Analysis? {
        guard let url else { return nil }
        if let task = tasks[url] { return await task.value }
        let task = Task<Analysis?, Never> {
            guard let image = await ArtworkImageLoader.shared.image(for: url),
                  let data = image.tiffRepresentation else { return nil }
            return await Task.detached(priority: .utility) { analyze(data) }.value
        }
        tasks[url] = task
        return await task.value
    }

    nonisolated private static func analyze(_ data: Data) -> Analysis? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let attention = VNGenerateAttentionBasedSaliencyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            do {
                try VNImageRequestHandler(cgImage: image).perform([attention, faces])
                let regions = (attention.results?.first?.salientObjects ?? []).map(\.boundingBox)
                    + (faces.results ?? []).map(\.boundingBox)
                guard !regions.isEmpty else { return nil }
                return Analysis(imageSize: CGSize(width: image.width, height: image.height),
                    regions: regions.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) })
            } catch {
                return nil
            }
        }
    }
}

enum V3ArtworkSubjectLayout {
    struct Placement {
        let position: String
        var widthFraction: CGFloat { 0.57 }
    }

    static func placement(subjects: [CGRect]?, canvas: CGSize, manualPosition: String) -> Placement {
        if ["left", "center", "right"].contains(manualPosition) {
            return Placement(position: manualPosition)
        }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let visible = (subjects ?? []).map { $0.intersection(canvasRect) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = visible.first else { return Placement(position: "right") }
        let bounds = visible.dropFirst().reduce(first) { $0.union($1) }
        let centre = bounds.midX / max(1, canvas.width)
        if (0.35...0.65).contains(centre) {
            let left = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height)
            let right = left.offsetBy(dx: canvas.width / 2, dy: 0)
            return Placement(position: coveredArea(visible, in: left) < coveredArea(visible, in: right) ? "left" : "right")
        }
        return Placement(position: centre >= 0.5 ? "left" : "right")
    }

    /// Count overlapping attention/face rectangles once when comparing the two halves.
    private static func coveredArea(_ regions: [CGRect], in half: CGRect) -> CGFloat {
        let regions = regions.map { $0.intersection(half) }.filter { !$0.isNull && !$0.isEmpty }
        let edges = Set(regions.flatMap { [$0.minX, $0.maxX] }).sorted()
        var area: CGFloat = 0
        for (left, right) in zip(edges, edges.dropFirst()) {
            let strip = regions.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
            var end = -CGFloat.infinity
            var height: CGFloat = 0
            for rect in strip {
                height += max(0, rect.maxY - max(end, rect.minY))
                end = max(end, rect.maxY)
            }
            area += (right - left) * height
        }
        return area
    }
}
