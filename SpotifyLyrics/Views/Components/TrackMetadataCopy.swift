import AppKit

enum TrackMetadataCopy {
    static func summary(title: String, artist: String, album: String) -> String {
        [title, artist, album]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
