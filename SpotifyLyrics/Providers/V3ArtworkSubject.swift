import AppKit
import ImageIO
import Vision

/// One background Vision pass per artwork URL, shared across scene/window changes.
@MainActor
enum V3ArtworkSubject {
    struct Analysis: Sendable {
        let imageSize: CGSize
        /// Normalized top-left coordinates, matching SwiftUI's canvas.
        let bounds: CGRect

        func subject(in artworkRect: CGRect) -> CGRect {
            CGRect(x: artworkRect.minX + bounds.minX * artworkRect.width,
                   y: artworkRect.minY + bounds.minY * artworkRect.height,
                   width: bounds.width * artworkRect.width, height: bounds.height * artworkRect.height)
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
                guard let first = regions.first else { return nil }
                let bounds = regions.dropFirst().reduce(first) { $0.union($1) }
                return Analysis(imageSize: CGSize(width: image.width, height: image.height),
                    bounds: CGRect(x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height))
            } catch {
                return nil
            }
        }
    }
}

enum V3ArtworkSubjectLayout {
    struct Placement {
        let position: String
        let widthFraction: CGFloat
    }

    static func placement(subject: CGRect?, canvas: CGSize, manualPosition: String) -> Placement {
        if ["left", "center", "right"].contains(manualPosition) {
            return Placement(position: manualPosition, widthFraction: 0.57)
        }
        guard let subject else { return Placement(position: "right", widthFraction: 0.57) }
        let visible = subject.intersection(CGRect(origin: .zero, size: canvas))
        guard !visible.isNull, !visible.isEmpty else {
            return Placement(position: "right", widthFraction: 0.57)
        }
        let centre = visible.midX / max(1, canvas.width)
        if (0.35...0.65).contains(centre), visible.width >= canvas.width * 0.48 {
            return Placement(position: "center", widthFraction: 0.40)
        }
        return Placement(position: centre >= 0.5 ? "left" : "right", widthFraction: 0.57)
    }
}
