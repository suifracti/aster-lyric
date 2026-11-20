import CryptoKit
import Foundation

extension Notification.Name {
    static let personalLibraryAssetsDidMutate = Notification.Name("SpotifyLyrics.PersonalLibraryAssetsDidMutate")
    static let personalFavoritesDidMutate = Notification.Name("SpotifyLyrics.PersonalFavoritesDidMutate")
}

// MARK: - Keychain Token Store

public protocol GitHubSyncTokenStoring: Sendable {
    func read() -> String?
    func save(_ token: String) throws
    func delete() throws
}

public final class GitHubSyncTokenStore: GitHubSyncTokenStoring, @unchecked Sendable {
    public static let service = "com.spotifylyrics.github-sync"
    public static let account = "personal-access-token"

    private let keyStore: KeychainAITranslationAPIKeyStore

    public init(
        service: String = GitHubSyncTokenStore.service,
        account: String = GitHubSyncTokenStore.account,
        transport: any AITranslationKeychainTransport = SecurityAITranslationKeychainTransport()
    ) {
        self.keyStore = KeychainAITranslationAPIKeyStore(service: service, account: account, transport: transport)
    }

    public func read() -> String? { keyStore.read() }
    public func save(_ token: String) throws { try keyStore.save(token) }
    public func delete() throws { try keyStore.delete() }
    public func invalidateCache() { keyStore.invalidateCache() }
}

// MARK: - Errors & Results

public enum GitHubLyricsSyncError: Error, LocalizedError, Equatable, Sendable {
    case invalidRepository(String)
    case publicRepositoryForbidden(String)
    case missingToken
    case unauthorized
    case repositoryNotFound(String)
    case branchNotFound(String)
    case httpError(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let value):
            return value.isEmpty
                ? "请先填写 GitHub 私有仓库（格式：用户名/仓库名）"
                : "仓库格式无效「\(value)」，请使用「用户名/仓库名」或 GitHub 仓库链接"
        case .publicRepositoryForbidden(let slug):
            return "出于版权与隐私保护，仅允许同步到 GitHub 私有仓库；「\(slug)」为公开仓库或受保护源码仓，已拒绝写入。"
        case .missingToken:
            return "请先保存 GitHub Token（需私有仓库 Contents 读写权限）"
        case .unauthorized:
            return "GitHub Token 无效或缺少该私有仓库的读写权限（401/403）"
        case .repositoryNotFound(let slug):
            return "找不到仓库「\(slug)」，请检查拼写或 Token 对该私有仓库的访问授权"
        case .branchNotFound(let branch):
            return "找不到分支「\(branch)」，请检查分支名称或仓库初始化状态"
        case .httpError(let code, let detail):
            return detail.isEmpty ? "GitHub 请求失败（HTTP \(code)）" : "GitHub 请求失败（HTTP \(code)）：\(detail)"
        case .invalidResponse(let detail):
            return "GitHub 返回了无法解析的响应：\(detail)"
        }
    }
}

public struct GitHubSyncResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case upToDate
        case committed(sha: String, uploadedCount: Int, deletedCount: Int)
    }

    public let repository: String
    public let branch: String
    public let trackCount: Int
    public let favoritesCount: Int
    public let status: Status
}

// MARK: - HTTP Transport

public protocol GitHubHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionGitHubHTTPTransport: GitHubHTTPTransport, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - GitHub Repository & Git Data API Client

public enum GitHubRepositorySlug {
    /// Source repo for the open-source app itself; never allowed as a personal lyrics sync target.
    static let forbiddenSourceRepositories: Set<String> = ["suifracti/aster-lyric"]

    public static func normalize(_ raw: String) -> (owner: String, name: String, slug: String)? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:"] {
            if trimmed.lowercased().hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0], name = parts[1]
        guard isValidSegment(owner), isValidSegment(name) else { return nil }
        return (owner, name, "\(owner)/\(name)")
    }

    private static func isValidSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}

public struct GitHubSyncClient: Sendable {
    private let transport: any GitHubHTTPTransport
    private let baseURL: URL

    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport(),
        baseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
    }

    public func verifyPrivateRepository(
        repository rawRepo: String,
        token: String
    ) async throws -> (owner: String, name: String, slug: String, defaultBranch: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw GitHubLyricsSyncError.missingToken }
        guard let repo = GitHubRepositorySlug.normalize(rawRepo) else {
            throw GitHubLyricsSyncError.invalidRepository(rawRepo)
        }
        if GitHubRepositorySlug.forbiddenSourceRepositories.contains(repo.slug.lowercased()) {
            throw GitHubLyricsSyncError.publicRepositoryForbidden(repo.slug)
        }

        let (data, _) = try await request(
            method: "GET",
            path: "repos/\(repo.owner)/\(repo.name)",
            token: trimmedToken,
            notFoundError: .repositoryNotFound(repo.slug)
        )
        struct RepoInfo: Decodable {
            let `private`: Bool
            let default_branch: String?
            let permissions: Permissions?
            struct Permissions: Decodable { let push: Bool? }
        }
        guard let info = try? JSONDecoder().decode(RepoInfo.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("仓库信息解析失败")
        }
        guard info.private else {
            throw GitHubLyricsSyncError.publicRepositoryForbidden(repo.slug)
        }
        if info.permissions?.push == false {
            throw GitHubLyricsSyncError.unauthorized
        }
        return (repo.owner, repo.name, repo.slug, info.default_branch ?? "main")
    }

    public func syncFiles(
        repository rawRepo: String,
        branch rawBranch: String,
        token: String,
        files: [String: Data],
        managedPrefixes: [String],
        exactManagedPaths: Set<String>,
        trackCount: Int,
        favoritesCount: Int,
        commitMessage: String
    ) async throws -> GitHubSyncResult {
        let verified = try await verifyPrivateRepository(repository: rawRepo, token: token)
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? verified.defaultBranch
            : rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = "repos/\(verified.owner)/\(verified.name)"

        let headSHA = try await ensureBranchHeadSHA(
            repoPath: repoPath,
            branch: branch,
            token: trimmedToken,
            seedReadme: files["README.md"] ?? Data("# Aster · Lyric\n".utf8)
        )

        let baseTreeSHA = try await fetchCommitTreeSHA(repoPath: repoPath, commitSHA: headSHA, token: trimmedToken)
        let remoteTree = try await fetchRecursiveTree(repoPath: repoPath, treeSHA: baseTreeSHA, token: trimmedToken)

        var uploads: [(path: String, data: Data)] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let localSHA = Self.gitBlobSHA(of: data)
            if remoteTree[path] != localSHA {
                uploads.append((path, data))
            }
        }

        let deletions = remoteTree.keys
            .filter { path in
                guard files[path] == nil else { return false }
                return exactManagedPaths.contains(path) || managedPrefixes.contains(where: { path.hasPrefix($0) })
            }
            .sorted()

        if uploads.isEmpty && deletions.isEmpty {
            return GitHubSyncResult(
                repository: verified.slug,
                branch: branch,
                trackCount: trackCount,
                favoritesCount: favoritesCount,
                status: .upToDate
            )
        }

        let uploadedBlobs = try await uploadBlobs(uploads, repoPath: repoPath, token: trimmedToken)

        var treeEntries: [[String: Any]] = []
        treeEntries.reserveCapacity(uploadedBlobs.count + deletions.count)
        for (path, blobSHA) in uploadedBlobs {
            treeEntries.append([
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": blobSHA
            ])
        }
        for path in deletions {
            treeEntries.append([
                "path": path,
                "mode": "100644",
                "type": "blob",
                "sha": NSNull()
            ])
        }

        let newTreeSHA = try await createTree(
            repoPath: repoPath,
            baseTreeSHA: baseTreeSHA,
            entries: treeEntries,
            token: trimmedToken
        )
        let newCommitSHA = try await createCommit(
            repoPath: repoPath,
            message: commitMessage,
            treeSHA: newTreeSHA,
            parentSHA: headSHA,
            token: trimmedToken
        )
        try await updateRef(repoPath: repoPath, branch: branch, commitSHA: newCommitSHA, token: trimmedToken)

        return GitHubSyncResult(
            repository: verified.slug,
            branch: branch,
            trackCount: trackCount,
            favoritesCount: favoritesCount,
            status: .committed(sha: newCommitSHA, uploadedCount: uploads.count, deletedCount: deletions.count)
        )
    }

    public static func gitBlobSHA(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\u{0}".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func ensureBranchHeadSHA(
        repoPath: String,
        branch: String,
        token: String,
        seedReadme: Data
    ) async throws -> String {
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        do {
            return try await fetchBranchRefSHA(repoPath: repoPath, escapedBranch: escapedBranch, branch: branch, token: token)
        } catch GitHubLyricsSyncError.branchNotFound {
            // An empty newly-created private repository rejects Git Data API calls until a root commit exists.
            let readmePayload: [String: Any] = [
                "message": "Initialize Aster · Lyric sync repository",
                "content": seedReadme.base64EncodedString(),
                "branch": branch
            ]
            let body = try JSONSerialization.data(withJSONObject: readmePayload)
            _ = try await request(
                method: "PUT",
                path: "\(repoPath)/contents/README.md",
                token: token,
                body: body
            )
            return try await fetchBranchRefSHA(repoPath: repoPath, escapedBranch: escapedBranch, branch: branch, token: token)
        }
    }

    private func fetchBranchRefSHA(
        repoPath: String,
        escapedBranch: String,
        branch: String,
        token: String
    ) async throws -> String {
        let (data, _) = try await request(
            method: "GET",
            path: "\(repoPath)/git/ref/heads/\(escapedBranch)",
            token: token,
            treatConflictAsMissingBranch: true,
            notFoundError: .branchNotFound(branch)
        )
        struct RefResponse: Decodable {
            let object: Object
            struct Object: Decodable { let sha: String }
        }
        guard let decoded = try? JSONDecoder().decode(RefResponse.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("分支引用解析失败")
        }
        return decoded.object.sha
    }

    private func fetchCommitTreeSHA(repoPath: String, commitSHA: String, token: String) async throws -> String {
        let (data, _) = try await request(method: "GET", path: "\(repoPath)/git/commits/\(commitSHA)", token: token)
        struct CommitResponse: Decodable {
            let tree: Tree
            struct Tree: Decodable { let sha: String }
        }
        guard let decoded = try? JSONDecoder().decode(CommitResponse.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("提交树解析失败")
        }
        return decoded.tree.sha
    }

    private func fetchRecursiveTree(repoPath: String, treeSHA: String, token: String) async throws -> [String: String] {
        let (data, _) = try await request(
            method: "GET",
            path: "\(repoPath)/git/trees/\(treeSHA)?recursive=1",
            token: token
        )
        struct TreeResponse: Decodable {
            let tree: [Entry]
            struct Entry: Decodable {
                let path: String
                let type: String
                let sha: String
            }
        }
        guard let decoded = try? JSONDecoder().decode(TreeResponse.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("目录树解析失败")
        }
        var result: [String: String] = [:]
        for entry in decoded.tree where entry.type == "blob" {
            result[entry.path] = entry.sha
        }
        return result
    }

    private func uploadBlobs(
        _ uploads: [(path: String, data: Data)],
        repoPath: String,
        token: String
    ) async throws -> [(String, String)] {
        guard !uploads.isEmpty else { return [] }
        let maxConcurrency = 6
        var results: [(Int, String, String)] = []
        results.reserveCapacity(uploads.count)

        try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < uploads.count else { return }
                let idx = nextIndex
                let item = uploads[idx]
                nextIndex += 1
                group.addTask {
                    let payload: [String: Any] = [
                        "content": item.data.base64EncodedString(),
                        "encoding": "base64"
                    ]
                    let body = try JSONSerialization.data(withJSONObject: payload)
                    let (data, _) = try await self.request(
                        method: "POST",
                        path: "\(repoPath)/git/blobs",
                        token: token,
                        body: body
                    )
                    struct BlobResponse: Decodable { let sha: String }
                    guard let decoded = try? JSONDecoder().decode(BlobResponse.self, from: data) else {
                        throw GitHubLyricsSyncError.invalidResponse("Blob 创建响应无效")
                    }
                    return (idx, item.path, decoded.sha)
                }
            }

            for _ in 0..<min(maxConcurrency, uploads.count) {
                enqueueNext()
            }
            while let item = try await group.next() {
                results.append(item)
                enqueueNext()
            }
        }

        return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    private func createTree(
        repoPath: String,
        baseTreeSHA: String,
        entries: [[String: Any]],
        token: String
    ) async throws -> String {
        let payload: [String: Any] = [
            "base_tree": baseTreeSHA,
            "tree": entries
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await request(method: "POST", path: "\(repoPath)/git/trees", token: token, body: body)
        struct TreeCreated: Decodable { let sha: String }
        guard let decoded = try? JSONDecoder().decode(TreeCreated.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("Tree 创建响应无效")
        }
        return decoded.sha
    }

    private func createCommit(
        repoPath: String,
        message: String,
        treeSHA: String,
        parentSHA: String,
        token: String
    ) async throws -> String {
        let payload: [String: Any] = [
            "message": message,
            "tree": treeSHA,
            "parents": [parentSHA]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await request(method: "POST", path: "\(repoPath)/git/commits", token: token, body: body)
        struct CommitCreated: Decodable { let sha: String }
        guard let decoded = try? JSONDecoder().decode(CommitCreated.self, from: data) else {
            throw GitHubLyricsSyncError.invalidResponse("Commit 创建响应无效")
        }
        return decoded.sha
    }

    private func updateRef(repoPath: String, branch: String, commitSHA: String, token: String) async throws {
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let body = try JSONSerialization.data(withJSONObject: ["sha": commitSHA])
        _ = try await request(method: "PATCH", path: "\(repoPath)/git/refs/heads/\(escapedBranch)", token: token, body: body)
    }

    private func request(
        method: String,
        path: String,
        token: String,
        body: Data? = nil,
        treatConflictAsMissingBranch: Bool = false,
        notFoundError: GitHubLyricsSyncError? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GitHubLyricsSyncError.invalidResponse(path)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Aster-Lyric", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubLyricsSyncError.invalidResponse("非 HTTP 响应")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401, 403:
            throw GitHubLyricsSyncError.unauthorized
        case 404:
            if let notFoundError { throw notFoundError }
            throw GitHubLyricsSyncError.httpError(404, Self.errorMessage(from: data))
        case 409 where treatConflictAsMissingBranch:
            if let notFoundError { throw notFoundError }
            throw GitHubLyricsSyncError.httpError(409, Self.errorMessage(from: data))
        default:
            throw GitHubLyricsSyncError.httpError(http.statusCode, Self.errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }
}

// MARK: - Snapshot Builder (GPT-Readable Markdown + Optional Machine Backup)

public enum GitHubSyncSnapshotBuilder {
    public static let managedPrefixes = ["tracks/"]
    public static let backupPath = "backup/LyricIslandPersonalData.json"

    static func buildFiles(
        package: PersonalDataPackage,
        favorites: [V3FavoriteLines.Entry],
        defaults: UserDefaults = .lyricsQ,
        includeDataPackageBackup: Bool
    ) throws -> (files: [String: Data], exactManagedPaths: Set<String>) {
        var files: [String: Data] = [:]
        var indexRows: [(artist: String, title: String, album: String, status: String, translationTag: String, spotifyID: String, path: String)] = []

        let favoriteLookup = groupFavorites(favorites)
        var usedPaths = Set<String>()

        for trackPkg in package.tracks.sorted(by: {
            let lhs = ($0.track.artist.lowercased(), $0.track.title.lowercased(), $0.track.stableKey)
            let rhs = ($1.track.artist.lowercased(), $1.track.title.lowercased(), $1.track.stableKey)
            return lhs < rhs
        }) {
            let path = uniqueTrackPath(for: trackPkg.track, used: &usedPaths)
            let preferredLyrics = choosePreferredLyrics(in: trackPkg)
            let rankedTranslations = rankTranslations(for: preferredLyrics, in: trackPkg)
            let trackFavorites = favoritesForTrack(trackPkg.track, in: favoriteLookup)

            let markdown = renderTrackMarkdown(
                trackPkg: trackPkg,
                preferredLyrics: preferredLyrics,
                rankedTranslations: rankedTranslations,
                favorites: trackFavorites,
                defaults: defaults
            )
            files[path] = Data(markdown.utf8)

            let lyricsStatus: String
            if let preferredLyrics {
                let kind = preferredLyrics.isSynced ? "时间轴" : "纯文本"
                let flags = [
                    preferredLyrics.isLocked ? "已锁定" : nil,
                    preferredLyrics.isManuallyEdited ? "人工" : nil
                ].compactMap { $0 }.joined(separator: "/")
                lyricsStatus = flags.isEmpty ? "\(preferredLyrics.lines.count)行(\(kind))" : "\(preferredLyrics.lines.count)行(\(kind),\(flags))"
            } else {
                lyricsStatus = "缺歌词"
            }

            let translationTag: String
            if let primary = rankedTranslations.first {
                translationTag = primary.isManuallyEdited ? "人工译文" : (primary.sourceKind == "embedded" ? "词源译文" : "AI译文(\(primary.model))")
            } else if preferredLyrics?.lines.contains(where: { !($0.translationText ?? "").isEmpty }) == true {
                translationTag = "内嵌译文"
            } else {
                translationTag = "无译文"
            }

            let spotifyColumn = trackPkg.track.spotifyURI ?? trackPkg.track.spotifyID ?? ""
            indexRows.append((
                artist: trackPkg.track.artist,
                title: trackPkg.track.title,
                album: trackPkg.track.album,
                status: lyricsStatus,
                translationTag: translationTag,
                spotifyID: spotifyColumn,
                path: path
            ))
        }

        files["INDEX.md"] = Data(renderIndexMarkdown(rows: indexRows, favoritesCount: favorites.count).utf8)
        files["favorites.md"] = Data(renderFavoritesMarkdown(favorites: favorites).utf8)
        files["README.md"] = Data(renderReadmeMarkdown(trackCount: package.tracks.count, favoritesCount: favorites.count, includeBackup: includeDataPackageBackup).utf8)

        if includeDataPackageBackup {
            let stablePackage = stabilizedBackupPackage(from: package)
            files[backupPath] = try PersonalDataSyncStore.encode(stablePackage)
        }

        let exactManagedPaths: Set<String> = ["README.md", "INDEX.md", "favorites.md", backupPath]
        return (files, exactManagedPaths)
    }

    private static func uniqueTrackPath(for track: PersonalLyricsLibraryPackage.PackageTrack, used: inout Set<String>) -> String {
        let baseSlug = sanitizePathComponent("\(track.artist) - \(track.title)", maxLength: 64)
        let hash = shortSHA256Hex(track.stableKey, length: 8)
        var candidate = "tracks/\(baseSlug) [\(hash)].md"
        var counter = 2
        while used.contains(candidate) {
            candidate = "tracks/\(baseSlug) [\(hash)-\(counter)].md"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func sanitizePathComponent(_ raw: String, maxLength: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>#[]")
        let collapsed = raw
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fallback = collapsed.isEmpty ? "Untitled" : collapsed
        return String(fallback.prefix(maxLength))
    }

    private static func shortSHA256Hex(_ text: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    private static func choosePreferredLyrics(in package: PersonalLyricsLibraryPackage) -> PersonalLyricsLibraryPackage.PackageLyricsVersion? {
        if let id = package.preferredLyricsVersionID,
           let match = package.lyricsVersions.first(where: { $0.id == id }) {
            return match
        }
        return package.lyricsVersions.sorted {
            if $0.isLocked != $1.isLocked { return $0.isLocked && !$1.isLocked }
            if $0.isManuallyEdited != $1.isManuallyEdited { return $0.isManuallyEdited && !$1.isManuallyEdited }
            if $0.isSynced != $1.isSynced { return $0.isSynced && !$1.isSynced }
            return $0.updatedAt > $1.updatedAt
        }.first
    }

    private static func rankTranslations(
        for lyrics: PersonalLyricsLibraryPackage.PackageLyricsVersion?,
        in package: PersonalLyricsLibraryPackage
    ) -> [PersonalLyricsLibraryPackage.PackageTranslationVersion] {
        guard let lyrics else { return [] }
        return package.translationVersions
            .filter { $0.lyricsVersionID == lyrics.id && !$0.isArchived && $0.status == "complete" }
            .sorted { lhs, rhs in
                if lhs.isLocked != rhs.isLocked { return lhs.isLocked && !rhs.isLocked }
                if lhs.isManuallyEdited != rhs.isManuallyEdited { return lhs.isManuallyEdited && !rhs.isManuallyEdited }
                let lhsManualOrAI = lhs.sourceKind != "embedded"
                let rhsManualOrAI = rhs.sourceKind != "embedded"
                if lhsManualOrAI != rhsManualOrAI { return lhsManualOrAI && !rhsManualOrAI }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private static func groupFavorites(_ entries: [V3FavoriteLines.Entry]) -> [String: [V3FavoriteLines.Entry]] {
        var map: [String: [V3FavoriteLines.Entry]] = [:]
        for entry in entries {
            map[entry.trackKey, default: []].append(entry)
        }
        return map
    }

    private static func favoritesForTrack(
        _ track: PersonalLyricsLibraryPackage.PackageTrack,
        in map: [String: [V3FavoriteLines.Entry]]
    ) -> [V3FavoriteLines.Entry] {
        if let direct = map[track.stableKey], !direct.isEmpty { return direct }
        let normTitle = TrackTextNormalizer.normalize(track.title)
        let normArtist = TrackTextNormalizer.normalize(track.artist)
        return map.values.flatMap { $0 }.filter {
            TrackTextNormalizer.normalize($0.title) == normTitle && TrackTextNormalizer.normalize($0.artist) == normArtist
        }
    }

    private static func stabilizedBackupPackage(from package: PersonalDataPackage) -> PersonalDataPackage {
        let stabilizedTracks = package.tracks.map { trackPkg in
            let maxTrackDate = (trackPkg.lyricsVersions.map(\.updatedAt)
                + trackPkg.translationVersions.map(\.updatedAt)
                + trackPkg.readingVersions.map(\.updatedAt)
                + trackPkg.timingVersions.map(\.createdAt)).max() ?? Date(timeIntervalSince1970: 0)
            return PersonalLyricsLibraryPackage(
                manifest: PersonalLyricsLibraryPackage.Manifest(
                    formatVersion: trackPkg.manifest.formatVersion,
                    appVersion: trackPkg.manifest.appVersion,
                    exportedAt: maxTrackDate,
                    packageType: trackPkg.manifest.packageType
                ),
                track: trackPkg.track,
                lyricsVersions: trackPkg.lyricsVersions,
                translationVersions: trackPkg.translationVersions,
                readingVersions: trackPkg.readingVersions,
                timingVersions: trackPkg.timingVersions,
                preferredLyricsVersionID: trackPkg.preferredLyricsVersionID
            )
        }
        let maxDate = stabilizedTracks.map(\.manifest.exportedAt).max() ?? Date(timeIntervalSince1970: 0)
        return PersonalDataPackage(
            manifest: PersonalDataPackage.Manifest(
                schemaVersion: PersonalDataPackage.currentSchemaVersion,
                createdAt: maxDate,
                appVersion: PersonalLyricsLibraryPackage.appVersion,
                packageType: "personal_data"
            ),
            tracks: stabilizedTracks
        )
    }

    private static func renderTrackMarkdown(
        trackPkg: PersonalLyricsLibraryPackage,
        preferredLyrics: PersonalLyricsLibraryPackage.PackageLyricsVersion?,
        rankedTranslations: [PersonalLyricsLibraryPackage.PackageTranslationVersion],
        favorites: [V3FavoriteLines.Entry],
        defaults: UserDefaults
    ) -> String {
        let t = trackPkg.track
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuote(t.title))")
        lines.append("artist: \(yamlQuote(t.artist))")
        lines.append("album: \(yamlQuote(t.album))")
        lines.append("duration_seconds: \(Int(t.duration.rounded()))")
        if let sid = t.spotifyID, !sid.isEmpty { lines.append("spotify_id: \(yamlQuote(sid))") }
        if let uri = t.spotifyURI, !uri.isEmpty { lines.append("spotify_uri: \(yamlQuote(uri))") }
        if let isrc = t.isrc, !isrc.isEmpty { lines.append("isrc: \(yamlQuote(isrc))") }
        lines.append("stable_key: \(yamlQuote(t.stableKey))")
        lines.append("---")
        lines.append("")
        lines.append("# \(t.title) — \(t.artist)")
        lines.append("")
        var metaParts: [String] = []
        if !t.album.isEmpty { metaParts.append("专辑：《\(t.album)》") }
        if t.duration > 0 { metaParts.append("时长：\(formatTime(t.duration))") }
        if let sid = t.spotifyURI ?? t.spotifyID, !sid.isEmpty { metaParts.append("ID：`\(sid)`") }
        if !metaParts.isEmpty {
            lines.append("- " + metaParts.joined(separator: " · "))
        }

        guard let preferredLyrics else {
            lines.append("- 状态：暂无已保存原词")
            return lines.joined(separator: "\n") + "\n"
        }

        let labelKey = "personalLibrary.versionLabel.lyrics.\(preferredLyrics.id.uuidString)"
        let customTitle = defaults.string(forKey: labelKey + ".title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customNote = defaults.string(forKey: labelKey + ".note")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let flags = [
            preferredLyrics.isLocked ? "锁定" : nil,
            preferredLyrics.isManuallyEdited ? "人工" : nil,
            preferredLyrics.isSynced ? "时间轴" : "纯文本"
        ].compactMap { $0 }.joined(separator: " / ")
        lines.append("- 原词版本：\(customTitle.isEmpty ? preferredLyrics.source : customTitle)（\(flags)）")
        if !customNote.isEmpty { lines.append("- 备注：\(customNote)") }

        let primaryTranslation = rankedTranslations.first
        let translationByIndex: [Int: String] = Dictionary(
            (primaryTranslation?.lines ?? []).map { ($0.lineIndex, $0.translatedText) },
            uniquingKeysWith: { first, _ in first }
        )

        if let primaryTranslation {
            let tKind = primaryTranslation.isManuallyEdited ? "人工修订" : (primaryTranslation.sourceKind == "embedded" ? "词源译文" : "AI · \(primaryTranslation.model)")
            lines.append("- 主展示译文：\(tKind)（\(primaryTranslation.targetLanguage)）")
        }

        lines.append("")
        lines.append("## 歌词与译文对照")
        lines.append("")

        for row in preferredLyrics.lines.sorted(by: { $0.lineIndex < $1.lineIndex }) {
            let timePrefix = row.startTime.map { "[\(formatTime($0))] " } ?? ""
            let voicePrefix = row.performerID.map { !$0.isEmpty ? "（\($0)）" : "" } ?? ""
            let orig = row.originalText.trimmingCharacters(in: .newlines)
            if orig.isEmpty {
                lines.append("")
                continue
            }
            lines.append("- \(timePrefix)\(voicePrefix)\(orig)")
            let tr = (translationByIndex[row.lineIndex] ?? row.translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !tr.isEmpty {
                lines.append("  - 译：\(tr)")
            }
            if let bg = row.backgroundText?.trimmingCharacters(in: .whitespacesAndNewlines), !bg.isEmpty {
                lines.append("  - 和声：\(bg)")
            }
        }

        if rankedTranslations.count > 1 {
            lines.append("")
            lines.append("## 其他已存译文版本")
            lines.append("")
            for edition in rankedTranslations.dropFirst() {
                let kind = edition.isManuallyEdited ? "人工编辑" : (edition.sourceKind == "embedded" ? "词源译文" : "AI · \(edition.model)")
                let lock = edition.isLocked ? " [已锁定]" : ""
                lines.append("### \(kind)（\(edition.targetLanguage)）\(lock)")
                lines.append("")
                for tLine in edition.lines.sorted(by: { $0.lineIndex < $1.lineIndex }) where !tLine.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("- \(tLine.lineIndex + 1). \(tLine.translatedText)")
                }
                lines.append("")
            }
        }

        if !favorites.isEmpty {
            lines.append("")
            lines.append("## 收藏金句")
            lines.append("")
            for fav in favorites.sorted(by: { $0.text < $1.text }) {
                lines.append("- 「\(fav.text)」")
                if let tr = fav.translation, !tr.isEmpty {
                    lines.append("  - 译：\(tr)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderIndexMarkdown(
        rows: [(artist: String, title: String, album: String, status: String, translationTag: String, spotifyID: String, path: String)],
        favoritesCount: Int
    ) -> String {
        var lines = [
            "# Aster · Lyric 个人歌词库索引",
            "",
            "- 收录歌曲：**\(rows.count)** 首 · 收藏金句：**\(favoritesCount)** 句",
            "- 供 GPT / 个人整理歌单快速查阅；每首歌对应下方 `tracks/` 文件，内含原文、中文译文与金句。",
            "",
            "| 歌名 | 歌手 | 专辑 | 原词状态 | 译文状态 | ID | 详情 |",
            "|---|---|---|---|---|---|---|"
        ]
        for r in rows {
            let linkTitle = "[查看](\(r.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? r.path))"
            lines.append("| \(escapePipe(r.title)) | \(escapePipe(r.artist)) | \(escapePipe(r.album)) | \(escapePipe(r.status)) | \(escapePipe(r.translationTag)) | `\(escapePipe(r.spotifyID))` | \(linkTitle) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderFavoritesMarkdown(favorites: [V3FavoriteLines.Entry]) -> String {
        var lines = [
            "# 收藏金句",
            "",
            "共 \(favorites.count) 句。",
            ""
        ]
        for fav in favorites.sorted(by: { ($0.artist, $0.title, $0.text) < ($1.artist, $1.title, $1.text) }) {
            lines.append("- **\(fav.title)** — \(fav.artist)：「\(fav.text)」")
            if let tr = fav.translation, !tr.isEmpty {
                lines.append("  - 译：\(tr)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderReadmeMarkdown(trackCount: Int, favoritesCount: Int, includeBackup: Bool) -> String {
        var lines = [
            "# Aster · Lyric 个人歌词库（私有同步）",
            "",
            "本仓库由 Aster · Lyric 自动或手动同步维护，用于保存个人查到的歌词、中文译文与收藏金句（仅限私有仓库）。",
            "",
            "- [INDEX.md](INDEX.md)：全库 **\(trackCount)** 首歌曲总索引",
            "- `tracks/`：每首歌独立 Markdown（原词、译文对照、其他译稿、收藏金句）",
            "- [favorites.md](favorites.md)：收藏金句汇总（**\(favoritesCount)** 句）"
        ]
        if includeBackup {
            lines.append("- `\(backupPath)`：Aster · Lyric 标准个人数据包备份，可用于跨 Mac 导入恢复")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped - Double(mins * 60)
        return String(format: "%02d:%05.2f", mins, secs)
    }

    private static func yamlQuote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static func escapePipe(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Observable Service

@MainActor
final class GitHubLyricsSyncService: ObservableObject {
    static let shared = GitHubLyricsSyncService()

    private enum Keys {
        static let repository = "githubSync.repository.v1"
        static let branch = "githubSync.branch.v1"
        static let autoSync = "githubSync.autoSyncEnabled.v1"
        static let includeBackup = "githubSync.includeDataPackageBackup.v1"
        static let hasToken = "githubSync.hasToken.v1"
        static let lastSummary = "githubSync.lastSyncSummary.v1"
        static let lastDate = "githubSync.lastSyncAt.v1"
    }

    @Published var repositoryText: String {
        didSet { defaults.set(repositoryText, forKey: Keys.repository) }
    }
    @Published var branchText: String {
        didSet { defaults.set(branchText, forKey: Keys.branch) }
    }
    @Published var autoSyncEnabled: Bool {
        didSet { defaults.set(autoSyncEnabled, forKey: Keys.autoSync) }
    }
    @Published var includeDataPackageBackup: Bool {
        didSet { defaults.set(includeDataPackageBackup, forKey: Keys.includeBackup) }
    }
    @Published private(set) var hasStoredToken: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isErrorStatus = false
    @Published private(set) var lastSyncSummary: String?
    @Published private(set) var lastSyncDate: Date?

    var isConfigured: Bool {
        hasStoredToken && GitHubRepositorySlug.normalize(repositoryText) != nil
    }

    private let repository: SQLiteLyricsRepository
    private let favoritesLoader: @MainActor () -> [V3FavoriteLines.Entry]
    private let defaults: UserDefaults
    private let tokenStore: any GitHubSyncTokenStoring
    private let client: GitHubSyncClient
    private var autoSyncTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        repository: SQLiteLyricsRepository = SQLiteLyricsRepository(),
        favoritesLoader: @escaping @MainActor () -> [V3FavoriteLines.Entry] = { V3FavoriteLines.shared.entries },
        defaults: UserDefaults = .lyricsQ,
        tokenStore: any GitHubSyncTokenStoring = GitHubSyncTokenStore(),
        client: GitHubSyncClient = GitHubSyncClient(),
        observesMutations: Bool = true
    ) {
        self.repository = repository
        self.favoritesLoader = favoritesLoader
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.client = client
        self.repositoryText = defaults.string(forKey: Keys.repository) ?? ""
        self.branchText = defaults.string(forKey: Keys.branch) ?? "main"
        self.autoSyncEnabled = defaults.bool(forKey: Keys.autoSync)
        self.includeDataPackageBackup = defaults.object(forKey: Keys.includeBackup) as? Bool ?? true
        self.hasStoredToken = defaults.bool(forKey: Keys.hasToken)
        self.lastSyncSummary = defaults.string(forKey: Keys.lastSummary)
        self.lastSyncDate = defaults.object(forKey: Keys.lastDate) as? Date

        if observesMutations {
            startObserving(dbURL: repository.databaseURL.standardizedFileURL)
        }
    }

    deinit {
        autoSyncTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public func saveToken(_ rawToken: String) {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请先输入 GitHub Token"
            isErrorStatus = true
            return
        }
        do {
            try tokenStore.save(trimmed)
            defaults.set(true, forKey: Keys.hasToken)
            hasStoredToken = true
            statusMessage = "GitHub Token 已保存到 Keychain（不会写入配置或日志）"
            isErrorStatus = false
        } catch {
            statusMessage = "保存 Token 失败：\(error.localizedDescription)"
            isErrorStatus = true
        }
    }

    public func clearToken() {
        do {
            try tokenStore.delete()
            defaults.set(false, forKey: Keys.hasToken)
            hasStoredToken = false
            autoSyncEnabled = false
            statusMessage = "已清除 Keychain 中的 GitHub Token"
            isErrorStatus = false
        } catch {
            statusMessage = "清除 Token 失败：\(error.localizedDescription)"
            isErrorStatus = true
        }
    }

    public func testConnection() {
        guard !isSyncing else { return }
        guard let token = tokenStore.read(), !token.isEmpty else {
            statusMessage = GitHubLyricsSyncError.missingToken.errorDescription
            isErrorStatus = true
            return
        }
        isSyncing = true
        isErrorStatus = false
        statusMessage = "正在校验私有仓库…"
        let repoInput = repositoryText
        Task {
            defer { self.isSyncing = false }
            do {
                let info = try await client.verifyPrivateRepository(repository: repoInput, token: token)
                self.repositoryText = info.slug
                if self.branchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.branchText = info.defaultBranch
                }
                self.statusMessage = "连接正常：私有仓库「\(info.slug)」（默认分支 \(info.defaultBranch)）"
                self.isErrorStatus = false
            } catch {
                self.statusMessage = error.localizedDescription
                self.isErrorStatus = true
            }
        }
    }

    @discardableResult
    public func syncNow() async -> GitHubSyncResult? {
        guard !isSyncing else { return nil }
        guard let token = tokenStore.read(), !token.isEmpty else {
            statusMessage = GitHubLyricsSyncError.missingToken.errorDescription
            isErrorStatus = true
            return nil
        }

        isSyncing = true
        isErrorStatus = false
        statusMessage = "正在打包歌词并同步到 GitHub…"
        defer { isSyncing = false }

        do {
            let package = try await repository.exportPersonalDataPackage()
            let favorites = favoritesLoader()
            let built = try GitHubSyncSnapshotBuilder.buildFiles(
                package: package,
                favorites: favorites,
                defaults: defaults,
                includeDataPackageBackup: includeDataPackageBackup
            )
            let commitMessage = "Aster · Lyric 同步：\(package.tracks.count) 首歌曲"
            let result = try await client.syncFiles(
                repository: repositoryText,
                branch: branchText,
                token: token,
                files: built.files,
                managedPrefixes: GitHubSyncSnapshotBuilder.managedPrefixes,
                exactManagedPaths: built.exactManagedPaths,
                trackCount: package.tracks.count,
                favoritesCount: favorites.count,
                commitMessage: commitMessage
            )
            let now = Date()
            lastSyncDate = now
            defaults.set(now, forKey: Keys.lastDate)
            let summary: String
            switch result.status {
            case .upToDate:
                summary = "已是最新（\(result.trackCount) 首歌曲 · 无需上传）"
            case .committed(_, let uploaded, let deleted):
                var parts = ["已同步 \(result.trackCount) 首歌曲（更新 \(uploaded) 项"]
                if deleted > 0 { parts[0] += "，清理 \(deleted) 项" }
                parts[0] += "）"
                summary = parts[0]
            }
            lastSyncSummary = summary
            defaults.set(summary, forKey: Keys.lastSummary)
            statusMessage = summary
            isErrorStatus = false
            return result
        } catch {
            statusMessage = "同步失败：\(error.localizedDescription)"
            isErrorStatus = true
            return nil
        }
    }

    public func triggerManualSync() {
        Task { await syncNow() }
    }

    public func scheduleAutoSyncIfNeeded() {
        guard autoSyncEnabled, isConfigured else { return }
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" { return }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.autoSyncEnabled, self.isConfigured else { return }
            _ = await self.syncNow()
        }
    }

    private func startObserving(dbURL: URL) {
        let center = NotificationCenter.default
        let dbObserver = center.addObserver(forName: .personalLibraryAssetsDidMutate, object: nil, queue: .main) { [weak self] note in
            guard let changedURL = note.object as? URL, changedURL.standardizedFileURL == dbURL else { return }
            Task { @MainActor in self?.scheduleAutoSyncIfNeeded() }
        }
        let favObserver = center.addObserver(forName: .personalFavoritesDidMutate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleAutoSyncIfNeeded() }
        }
        observers = [dbObserver, favObserver]
    }
}
