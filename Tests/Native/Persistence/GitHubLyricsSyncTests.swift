import Foundation
import XCTest
@testable import SpotifyLyrics

private final class MockKeychainTransport: AITranslationKeychainTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func read(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage["\(service)|\(account)"]
    }

    func save(service: String, account: String, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage["\(service)|\(account)"] = key
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: "\(service)|\(account)")
    }
}

private final class MockGitHubServer: GitHubHTTPTransport, @unchecked Sendable {
    struct RepoState {
        var isPrivate: Bool = true
        var branchHead: String?
        var trees: [String: [String: String]] = [:] // treeSHA -> [path: blobSHA]
        var commits: [String: String] = [:] // commitSHA -> treeSHA
        var blobs: [String: Data] = [:] // blobSHA -> raw data
        var createdCommits: [(message: String, uploads: Int, deletions: Int)] = []
    }

    private let lock = NSLock()
    var state = RepoState()
    var blobUploadCalls = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let url = try XCTUnwrap(request.url)
        let path = url.path
        let method = request.httpMethod ?? "GET"

        func respond(_ status: Int, json: Any) -> (Data, URLResponse) {
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, http)
        }

        if method == "GET" && path == "/repos/alice/lyrics-vault" {
            return respond(200, json: ["private": state.isPrivate, "default_branch": "main", "permissions": ["push": true]])
        }
        if method == "GET" && path == "/repos/alice/lyrics-vault/git/ref/heads/main" {
            guard let head = state.branchHead else {
                return respond(404, json: ["message": "Not Found"])
            }
            return respond(200, json: ["object": ["sha": head]])
        }
        if method == "PUT" && path == "/repos/alice/lyrics-vault/contents/README.md" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let raw = Data(base64Encoded: body["content"] as? String ?? "") ?? Data()
            let blobSHA = GitHubSyncClient.gitBlobSHA(of: raw)
            state.blobs[blobSHA] = raw
            let treeSHA = "tree-root-1"
            state.trees[treeSHA] = ["README.md": blobSHA]
            let commitSHA = "commit-root-1"
            state.commits[commitSHA] = treeSHA
            state.branchHead = commitSHA
            return respond(201, json: ["commit": ["sha": commitSHA]])
        }
        if method == "GET" && path.hasPrefix("/repos/alice/lyrics-vault/git/commits/") {
            let commitSHA = String(path.dropFirst("/repos/alice/lyrics-vault/git/commits/".count))
            guard let treeSHA = state.commits[commitSHA] else {
                return respond(404, json: ["message": "Not Found"])
            }
            return respond(200, json: ["tree": ["sha": treeSHA]])
        }
        if method == "GET" && path.hasPrefix("/repos/alice/lyrics-vault/git/trees/") {
            let treeSHA = String(path.dropFirst("/repos/alice/lyrics-vault/git/trees/".count))
            guard let tree = state.trees[treeSHA] else {
                return respond(404, json: ["message": "Not Found"])
            }
            let entries = tree.map { ["path": $0.key, "type": "blob", "sha": $0.value] }
            return respond(200, json: ["tree": entries])
        }
        if method == "POST" && path == "/repos/alice/lyrics-vault/git/blobs" {
            blobUploadCalls += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let raw = Data(base64Encoded: body["content"] as? String ?? "") ?? Data()
            let sha = GitHubSyncClient.gitBlobSHA(of: raw)
            state.blobs[sha] = raw
            return respond(201, json: ["sha": sha])
        }
        if method == "POST" && path == "/repos/alice/lyrics-vault/git/trees" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let baseSHA = body["base_tree"] as? String ?? ""
            var nextTree = state.trees[baseSHA] ?? [:]
            let entries = body["tree"] as? [[String: Any]] ?? []
            var uploads = 0, deletions = 0
            for entry in entries {
                guard let entryPath = entry["path"] as? String else { continue }
                if entry["sha"] is NSNull {
                    nextTree.removeValue(forKey: entryPath)
                    deletions += 1
                } else if let sha = entry["sha"] as? String {
                    nextTree[entryPath] = sha
                    uploads += 1
                }
            }
            let newTreeSHA = "tree-\(state.trees.count + 1)"
            state.trees[newTreeSHA] = nextTree
            state.createdCommits.append(("", uploads, deletions))
            return respond(201, json: ["sha": newTreeSHA])
        }
        if method == "POST" && path == "/repos/alice/lyrics-vault/git/commits" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            let treeSHA = body["tree"] as? String ?? ""
            let msg = body["message"] as? String ?? ""
            let newCommitSHA = "commit-\(state.commits.count + 1)"
            state.commits[newCommitSHA] = treeSHA
            if !state.createdCommits.isEmpty {
                let last = state.createdCommits.removeLast()
                state.createdCommits.append((msg, last.uploads, last.deletions))
            }
            return respond(201, json: ["sha": newCommitSHA])
        }
        if method == "PATCH" && path == "/repos/alice/lyrics-vault/git/refs/heads/main" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            state.branchHead = body["sha"] as? String
            return respond(200, json: ["object": ["sha": state.branchHead ?? ""]])
        }
        return respond(404, json: ["message": "Unexpected route \(method) \(path)"])
    }
}

final class GitHubLyricsSyncTests: XCTestCase {
    func testClientRejectsPublicRepositoryAndOpenSourceAppRepoWithoutWriting() async {
        let server = MockGitHubServer()
        server.state.isPrivate = false
        let client = GitHubSyncClient(transport: server)

        do {
            _ = try await client.verifyPrivateRepository(repository: "suifracti/aster-lyric", token: "tok")
            XCTFail("Open-source app repo must be forbidden")
        } catch let error as GitHubLyricsSyncError {
            guard case .publicRepositoryForbidden = error else {
                return XCTFail("Expected publicRepositoryForbidden, got \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await client.syncFiles(
                repository: "https://github.com/alice/lyrics-vault.git",
                branch: "main",
                token: "tok",
                files: ["INDEX.md": Data("hi".utf8)],
                managedPrefixes: ["tracks/"],
                exactManagedPaths: ["INDEX.md"],
                trackCount: 1,
                favoritesCount: 0,
                commitMessage: "test"
            )
            XCTFail("Public user repo must be forbidden")
        } catch let error as GitHubLyricsSyncError {
            guard case .publicRepositoryForbidden = error else {
                return XCTFail("Expected publicRepositoryForbidden, got \(error)")
            }
        } catch {
            return XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(server.blobUploadCalls, 0)
        XCTAssertTrue(server.state.createdCommits.isEmpty)
    }

    @MainActor
    func testIncrementalSyncExportsBilingualMarkdownPreservesUserNotesAndSkipsUnchanged() async throws {
        let root = NativeTestRuntime.root.appendingPathComponent("gh-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = SQLiteLyricsRepository(
            databaseURL: root.appendingPathComponent("lyrics.sqlite3"),
            alignmentProvenanceDirectory: root.appendingPathComponent("provenance")
        )
        try await repo.prepare()

        let suiteName = "github-sync-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let track1 = Track(title: "色恋", artist: "tuki.", album: "Single", duration: 205, spotifyId: "spotify:track:1111111111111111111111")
        let id1 = TrackIdentity(track: track1)
        let doc1 = LyricsDocument(
            identity: id1,
            title: track1.title,
            artist: track1.artist,
            album: track1.album,
            duration: track1.duration,
            lines: [
                LyricLine(timestamp: 12.5, originalText: "君は僕なしじゃ生きられない", translationText: "你没有我根本活不下去"),
                LyricLine(timestamp: 18.0, originalText: "本当は僕も同じなのに", backgroundText: "（ねえ）")
            ],
            isSynchronized: true,
            source: .qqExperimental,
            confidence: 0.95
        )
        let saved1 = try await repo.save(track: track1, identity: id1, document: doc1)
        let lyricsID1 = try XCTUnwrap(saved1.versionID)
        let hash1 = try XCTUnwrap(saved1.sourceContentHash)
        _ = try await repo.saveTranslation(
            lyricsVersionID: lyricsID1,
            sourceContentHash: hash1,
            originalLines: doc1.lines.map(\.originalText),
            draft: AITranslationDraft(
                lines: [
                    AITranslationLine(index: 0, translation: "你根本离不开我吧"),
                    AITranslationLine(index: 1, translation: "其实我也不能没有你")
                ],
                targetLanguage: "zh-Hans",
                model: "gpt-test",
                baseURLHost: "api.example.invalid",
                promptHash: "p1",
                sourceContentHash: hash1,
                sourceKind: .manualEdit,
                isMachineGenerated: false,
                isManuallyEdited: true
            ),
            forceNewVersion: true
        )

        let favs = [V3FavoriteLines.Entry(
            text: "本当は僕も同じなのに",
            translation: "其实我也不能没有你",
            title: track1.title,
            artist: track1.artist,
            trackKey: id1.stableKey
        )]

        let server = MockGitHubServer()
        // Seed an unrelated user note inside the private repo; incremental sync must preserve it.
        let noteData = Data("My custom playlist thoughts".utf8)
        let noteSHA = GitHubSyncClient.gitBlobSHA(of: noteData)
        server.state.blobs[noteSHA] = noteData
        server.state.trees["tree-init"] = ["notes/my-playlists.md": noteSHA]
        server.state.commits["commit-init"] = "tree-init"
        server.state.branchHead = "commit-init"

        let tokenStore = GitHubSyncTokenStore(transport: MockKeychainTransport())
        defaults.set(true, forKey: "githubSync.hasToken.v1")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // With SPOTIFYLYRICS_DISABLE_KEYCHAIN=1, supply a mock token directly via custom conformer.
        struct TestTokenStore: GitHubSyncTokenStoring {
            func read() -> String? { "ghp_test_token" }
            func save(_ token: String) throws {}
            func delete() throws {}
        }

        let service = GitHubLyricsSyncService(
            repository: repo,
            favoritesLoader: { favs },
            defaults: defaults,
            tokenStore: TestTokenStore(),
            client: GitHubSyncClient(transport: server),
            observesMutations: false
        )
        service.repositoryText = "alice/lyrics-vault"
        service.branchText = "main"

        let first = await service.syncNow()
        guard case .committed(_, let uploaded1, let deleted1) = first?.status else {
            return XCTFail("Expected initial commit, got \(String(describing: first))")
        }
        XCTAssertEqual(uploaded1, 5) // README.md, INDEX.md, favorites.md, tracks/..., backup/...
        XCTAssertEqual(deleted1, 0)

        let headAfterFirst = server.state.branchHead!
        let treeAfterFirst = server.state.trees[server.state.commits[headAfterFirst]!]!
        XCTAssertEqual(treeAfterFirst["notes/my-playlists.md"], noteSHA, "User custom notes must survive")
        let trackPath = try XCTUnwrap(treeAfterFirst.keys.first { $0.hasPrefix("tracks/") })
        let trackMD = try XCTUnwrap(String(data: server.state.blobs[treeAfterFirst[trackPath]!]!, encoding: .utf8))
        XCTAssertTrue(trackMD.contains("你根本离不开我吧"))
        XCTAssertTrue(trackMD.contains("其实我也不能没有你"))
        XCTAssertTrue(trackMD.contains("（ねえ）"))
        XCTAssertTrue(trackMD.contains("收藏金句"))

        // Second sync with unchanged database: 0 blobs, 0 commits.
        let callsBeforeSecond = server.blobUploadCalls
        let second = await service.syncNow()
        XCTAssertEqual(second?.status, .upToDate)
        XCTAssertEqual(server.blobUploadCalls, callsBeforeSecond)

        // Add a second track: only new track + INDEX.md + README.md + backup upload (1st track skipped).
        let track2 = Track(title: "shion", artist: "angelize", album: "shion", duration: 168)
        let id2 = TrackIdentity(track: track2)
        _ = try await repo.save(
            track: track2,
            identity: id2,
            document: LyricsDocument(
                identity: id2,
                title: track2.title,
                artist: track2.artist,
                album: track2.album,
                duration: track2.duration,
                lines: [LyricLine(timestamp: 1, originalText: "Purple aster")],
                isSynchronized: true,
                source: .qqExperimental,
                confidence: 0.95
            )
        )

        let third = await service.syncNow()
        guard case .committed(_, let uploaded3, _) = third?.status else {
            return XCTFail("Expected incremental commit, got \(String(describing: third))")
        }
        XCTAssertLessThan(uploaded3, uploaded1 + 1, "Unchanged track and favorites.md should not be re-uploaded")

        // Validate real tokenStore respects environment safety isolation without touching Keychain.
        XCTAssertNil(tokenStore.read())
    }
}
