import AppKit
import CoreGraphics

extension NSScreen {
    var lyricsDisplayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Existing saved frames use the WindowServer number. Keep reading and writing that key.
    var lyricsFrameScreenID: String {
        if let id = lyricsDisplayNumber { return "display-\(id)" }
        return "name-\(localizedName)-\(NSStringFromRect(frame))"
    }

    /// A user's explicit display choice can outlive a WindowServer display-number change.
    var lyricsDisplayID: String {
        guard let id = lyricsDisplayNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return lyricsFrameScreenID }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func lyricsScreen(for identifier: String?) -> NSScreen? {
        guard let identifier, !identifier.isEmpty else { return nil }
        return screens.first { $0.lyricsFrameScreenID == identifier || $0.lyricsDisplayID == identifier }
    }
}
