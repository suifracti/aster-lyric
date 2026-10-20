import Foundation

public protocol TrackSearchProvider {
    var name: String { get }
    var isLocal: Bool { get }
    func search(query: TrackSearchQuery) async throws -> [TrackSearchResult]
}

public extension TrackSearchProvider { var isLocal: Bool { false } }
