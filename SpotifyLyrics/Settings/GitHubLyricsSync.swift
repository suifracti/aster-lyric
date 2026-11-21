#if canImport(AppKit)
import AppKit
#endif
import CryptoKit
import Foundation

extension Notification.Name {
    static let personalLibraryAssetsDidMutate = Notification.Name("SpotifyLyrics.PersonalLibraryAssetsDidMutate")
    static let personalFavoritesDidMutate = Notification.Name("SpotifyLyrics.PersonalFavoritesDidMutate")
}

public enum GitHubSyncTranslationScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case aiAndManual = "ai_and_manual"
    case aiOnly = "ai_only"
    case all = "all"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aiAndManual: return "仅 AI 与人工译文（排除词源自带）"
        case .aiOnly: return "严格仅 AI 模型译文"
        case .all: return "全部译文（含词源自带）"
        }
    }
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
    public let pulledCount: Int
    public let conflictCount: Int
    public let headCommitSHA: String?
    public let status: Status

    public init(
        repository: String,
        branch: String,
        trackCount: Int,
        favoritesCount: Int,
        pulledCount: Int = 0,
        conflictCount: Int = 0,
        headCommitSHA: String? = nil,
        status: Status
    ) {
        self.repository = repository
        self.branch = branch
        self.trackCount = trackCount
        self.favoritesCount = favoritesCount
        self.pulledCount = pulledCount
        self.conflictCount = conflictCount
        self.headCommitSHA = headCommitSHA
        self.status = status
    }
}

public struct GitHubSyncRemoteSnapshot: Equatable, Sendable {
    public let repository: String
    public let branch: String
    public let headCommitSHA: String
    public let treeSHA: String
    public let treeBlobSHAs: [String: String]
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

    public func fetchHeadCommitSHA(
        repository rawRepo: String,
        branch rawBranch: String,
        token: String
    ) async throws -> String? {
        let verified = try await verifyPrivateRepository(repository: rawRepo, token: token)
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? verified.defaultBranch
            : rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = "repos/\(verified.owner)/\(verified.name)"
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        do {
            return try await fetchBranchRefSHA(repoPath: repoPath, escapedBranch: escapedBranch, branch: branch, token: trimmedToken)
        } catch GitHubLyricsSyncError.branchNotFound {
            return nil
        }
    }

    public func fetchRemoteBranchSnapshot(
        repository rawRepo: String,
        branch rawBranch: String,
        token: String
    ) async throws -> GitHubSyncRemoteSnapshot? {
        let verified = try await verifyPrivateRepository(repository: rawRepo, token: token)
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? verified.defaultBranch
            : rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = "repos/\(verified.owner)/\(verified.name)"
        let escapedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let headSHA: String
        do {
            headSHA = try await fetchBranchRefSHA(repoPath: repoPath, escapedBranch: escapedBranch, branch: branch, token: trimmedToken)
        } catch GitHubLyricsSyncError.branchNotFound {
            return nil
        }
        let treeSHA = try await fetchCommitTreeSHA(repoPath: repoPath, commitSHA: headSHA, token: trimmedToken)
        let remoteTree = try await fetchRecursiveTree(repoPath: repoPath, treeSHA: treeSHA, token: trimmedToken)
        return GitHubSyncRemoteSnapshot(
            repository: verified.slug,
            branch: branch,
            headCommitSHA: headSHA,
            treeSHA: treeSHA,
            treeBlobSHAs: remoteTree
        )
    }

    public func fetchBlobsData(
        repository rawRepo: String,
        blobs: [(path: String, sha: String)],
        token: String
    ) async throws -> [String: Data] {
        guard !blobs.isEmpty else { return [:] }
        let verified = try await verifyPrivateRepository(repository: rawRepo, token: token)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = "repos/\(verified.owner)/\(verified.name)"
        let maxConcurrency = 6
        var output: [String: Data] = [:]

        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < blobs.count else { return }
                let item = blobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    let (data, _) = try await self.request(
                        method: "GET",
                        path: "\(repoPath)/git/blobs/\(item.sha)",
                        token: trimmedToken
                    )
                    struct BlobPayload: Decodable {
                        let content: String
                        let encoding: String?
                    }
                    guard let decoded = try? JSONDecoder().decode(BlobPayload.self, from: data) else {
                        throw GitHubLyricsSyncError.invalidResponse("Blob 读取失败")
                    }
                    let cleaned = decoded.content.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                    guard let raw = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else {
                        throw GitHubLyricsSyncError.invalidResponse("Blob Base64 解码失败")
                    }
                    return (item.path, raw)
                }
            }
            for _ in 0..<min(maxConcurrency, blobs.count) {
                enqueueNext()
            }
            while let (path, raw) = try await group.next() {
                output[path] = raw
                enqueueNext()
            }
        }
        return output
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
        pulledCount: Int = 0,
        conflictCount: Int = 0,
        preloadedSnapshot: GitHubSyncRemoteSnapshot? = nil,
        commitMessage: String
    ) async throws -> GitHubSyncResult {
        let verified = try await verifyPrivateRepository(repository: rawRepo, token: token)
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? verified.defaultBranch
            : rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoPath = "repos/\(verified.owner)/\(verified.name)"

        let headSHA: String
        let baseTreeSHA: String
        let remoteTree: [String: String]
        if let preloadedSnapshot,
           preloadedSnapshot.repository == verified.slug,
           preloadedSnapshot.branch == branch {
            headSHA = preloadedSnapshot.headCommitSHA
            baseTreeSHA = preloadedSnapshot.treeSHA
            remoteTree = preloadedSnapshot.treeBlobSHAs
        } else {
            headSHA = try await ensureBranchHeadSHA(
                repoPath: repoPath,
                branch: branch,
                token: trimmedToken,
                seedReadme: files["README.md"] ?? Data("# Aster · Lyric\n".utf8)
            )
            baseTreeSHA = try await fetchCommitTreeSHA(repoPath: repoPath, commitSHA: headSHA, token: trimmedToken)
            remoteTree = try await fetchRecursiveTree(repoPath: repoPath, treeSHA: baseTreeSHA, token: trimmedToken)
        }

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
                pulledCount: pulledCount,
                conflictCount: conflictCount,
                headCommitSHA: headSHA,
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
            pulledCount: pulledCount,
            conflictCount: conflictCount,
            headCommitSHA: newCommitSHA,
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
    public static let managedPrefixes = ["tracks/", "playlists/"]
    public static let backupPath = "backup/LyricIslandPersonalData.json"

    static func buildFiles(
        package: PersonalDataPackage,
        favorites: [V3FavoriteLines.Entry],
        playlists: [GitHubSyncPlaylistSnapshot] = [],
        defaults: UserDefaults = .lyricsQ,
        includeDataPackageBackup: Bool,
        translationScope: GitHubSyncTranslationScope = .aiAndManual
    ) throws -> (files: [String: Data], exactManagedPaths: Set<String>) {
        var files: [String: Data] = [:]
        var indexRows: [(artist: String, title: String, album: String, status: String, translationTag: String, spotifyID: String, path: String)] = []
        var pathByStableKey: [String: String] = [:]
        var pathBySpotifyID: [String: String] = [:]
        var pathByTitleArtist: [String: String] = [:]

        let favoriteLookup = groupFavorites(favorites)
        var usedPaths = Set<String>()

        for trackPkg in package.tracks.sorted(by: {
            let lhs = ($0.track.artist.lowercased(), $0.track.title.lowercased(), $0.track.stableKey)
            let rhs = ($1.track.artist.lowercased(), $1.track.title.lowercased(), $1.track.stableKey)
            return lhs < rhs
        }) {
            let path = uniqueTrackPath(for: trackPkg.track, used: &usedPaths)
            let preferredLyrics = choosePreferredLyrics(in: trackPkg)
            let rankedTranslations = rankTranslations(for: preferredLyrics, in: trackPkg, scope: translationScope)
            let trackFavorites = favoritesForTrack(trackPkg.track, in: favoriteLookup)

            let markdown = renderTrackMarkdown(
                trackPkg: trackPkg,
                preferredLyrics: preferredLyrics,
                rankedTranslations: rankedTranslations,
                favorites: trackFavorites,
                defaults: defaults,
                translationScope: translationScope
            )
            files[path] = Data(markdown.utf8)

            pathByStableKey[trackPkg.track.stableKey] = path
            if let sid = trackPkg.track.spotifyID, !sid.isEmpty {
                pathBySpotifyID[sid.lowercased()] = path
            }
            let normTA = "\(TrackTextNormalizer.normalize(trackPkg.track.title))|\(TrackTextNormalizer.normalize(trackPkg.track.artist))"
            if pathByTitleArtist[normTA] == nil {
                pathByTitleArtist[normTA] = path
            }

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
                translationTag = translationIndexTag(for: primary)
            } else if translationScope == .all,
                      preferredLyrics?.lines.contains(where: { !($0.translationText ?? "").isEmpty }) == true {
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

        var usedPlaylistPaths = Set<String>()
        var exportedPlaylistCount = 0
        for playlist in playlists.sorted(by: { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }) where !playlist.tracks.isEmpty {
            let pPath = uniquePlaylistPath(for: playlist, used: &usedPlaylistPaths)
            let pMarkdown = renderPlaylistMarkdown(
                playlist: playlist,
                pathByStableKey: pathByStableKey,
                pathBySpotifyID: pathBySpotifyID,
                pathByTitleArtist: pathByTitleArtist
            )
            files[pPath] = Data(pMarkdown.utf8)
            exportedPlaylistCount += 1
        }

        files["INDEX.md"] = Data(renderIndexMarkdown(rows: indexRows, favoritesCount: favorites.count).utf8)
        files["favorites.md"] = Data(renderFavoritesMarkdown(favorites: favorites).utf8)
        files["README.md"] = Data(renderReadmeMarkdown(
            trackCount: package.tracks.count,
            favoritesCount: favorites.count,
            playlistCount: exportedPlaylistCount,
            includeBackup: includeDataPackageBackup
        ).utf8)

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

    static func isProviderEmbedded(_ translation: PersonalLyricsLibraryPackage.PackageTranslationVersion) -> Bool {
        translation.sourceKind == AITranslationSourceKind.providerEmbedded.rawValue
            || translation.sourceKind == "embedded"
            || (translation.sourceKind == AITranslationSourceKind.legacyImported.rawValue && translation.targetLanguage == "und")
    }

    private static func isManualTranslation(_ translation: PersonalLyricsLibraryPackage.PackageTranslationVersion) -> Bool {
        translation.isManuallyEdited
            || translation.sourceKind == AITranslationSourceKind.manualEdit.rawValue
            || translation.sourceKind == AITranslationSourceKind.manualImport.rawValue
    }

    private static func translationIndexTag(for translation: PersonalLyricsLibraryPackage.PackageTranslationVersion) -> String {
        if isProviderEmbedded(translation) { return "词源译文" }
        if isManualTranslation(translation) { return "人工译文" }
        return "AI译文(\(translation.model))"
    }

    private static func translationHeadingLabel(for translation: PersonalLyricsLibraryPackage.PackageTranslationVersion) -> String {
        if isProviderEmbedded(translation) { return "词源译文" }
        if isManualTranslation(translation) { return "人工修订 · \(translation.model)" }
        return "AI · \(translation.model)"
    }

    private static func rankTranslations(
        for lyrics: PersonalLyricsLibraryPackage.PackageLyricsVersion?,
        in package: PersonalLyricsLibraryPackage,
        scope: GitHubSyncTranslationScope
    ) -> [PersonalLyricsLibraryPackage.PackageTranslationVersion] {
        guard let lyrics else { return [] }
        return package.translationVersions
            .filter { tv in
                guard tv.lyricsVersionID == lyrics.id, !tv.isArchived, tv.status == "complete" else { return false }
                switch scope {
                case .aiOnly:
                    return tv.sourceKind == AITranslationSourceKind.ai.rawValue && !tv.isManuallyEdited
                case .aiAndManual:
                    return !isProviderEmbedded(tv)
                case .all:
                    return true
                }
            }
            .sorted { lhs, rhs in
                if lhs.isLocked != rhs.isLocked { return lhs.isLocked && !rhs.isLocked }
                if lhs.isManuallyEdited != rhs.isManuallyEdited { return lhs.isManuallyEdited && !rhs.isManuallyEdited }
                let lhsManualOrAI = !isProviderEmbedded(lhs)
                let rhsManualOrAI = !isProviderEmbedded(rhs)
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
        defaults: UserDefaults,
        translationScope: GitHubSyncTranslationScope
    ) -> String {
        let t = trackPkg.track
        let primaryTranslation = rankedTranslations.first
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
        if let preferredLyrics {
            lines.append("lyrics_version_id: \(yamlQuote(preferredLyrics.id.uuidString))")
            lines.append("source_content_hash: \(yamlQuote(preferredLyrics.contentHash))")
        }
        lines.append("translation_language: \(yamlQuote(primaryTranslation?.targetLanguage ?? "zh-Hans"))")
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

        let translationByIndex: [Int: String] = Dictionary(
            (primaryTranslation?.lines ?? []).map { ($0.lineIndex, $0.translatedText) },
            uniquingKeysWith: { first, _ in first }
        )

        if let primaryTranslation {
            lines.append("- 主展示译文：\(translationHeadingLabel(for: primaryTranslation))（\(primaryTranslation.targetLanguage)）")
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
            let fallbackEmbedded = translationScope == .all ? (row.translationText ?? "") : ""
            let tr = (translationByIndex[row.lineIndex] ?? fallbackEmbedded).trimmingCharacters(in: .whitespacesAndNewlines)
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
                let lock = edition.isLocked ? " [已锁定]" : ""
                lines.append("### \(translationHeadingLabel(for: edition))（\(edition.targetLanguage)）\(lock)")
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

    private static func uniquePlaylistPath(for playlist: GitHubSyncPlaylistSnapshot, used: inout Set<String>) -> String {
        let baseSlug = sanitizePathComponent(playlist.name, maxLength: 56)
        let hash = shortSHA256Hex(playlist.id, length: 8)
        var candidate = "playlists/\(baseSlug) [\(hash)].md"
        var counter = 2
        while !used.insert(candidate).inserted {
            candidate = "playlists/\(baseSlug) [\(hash)-\(counter)].md"
            counter += 1
        }
        return candidate
    }

    private static func renderPlaylistMarkdown(
        playlist: GitHubSyncPlaylistSnapshot,
        pathByStableKey: [String: String],
        pathBySpotifyID: [String: String],
        pathByTitleArtist: [String: String]
    ) -> String {
        var lines = [
            "---",
            "playlist_id: \(yamlQuote(playlist.id))",
            "playlist_name: \(yamlQuote(playlist.name))",
            "source: \(yamlQuote(playlist.source))",
            "track_count: \(playlist.tracks.count)",
            "---",
            "",
            "# 歌单：\(playlist.name)",
            "",
            "- 来源：\(playlist.source) · 共 **\(playlist.tracks.count)** 首",
            "",
            "| # | 歌名 | 歌手 | 专辑 | 歌词文件 |",
            "|---|---|---|---|---|"
        ]
        for (idx, item) in playlist.tracks.enumerated() {
            let matchedPath = pathByStableKey[item.stableKey]
                ?? item.spotifyID.flatMap { pathBySpotifyID[$0.lowercased()] }
                ?? pathByTitleArtist["\(TrackTextNormalizer.normalize(item.title))|\(TrackTextNormalizer.normalize(item.artist))"]
            let linkCell: String
            if let matchedPath {
                let encoded = ("../" + matchedPath).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ("../" + matchedPath)
                linkCell = "[查看](\(encoded))"
            } else {
                linkCell = "暂未查词"
            }
            lines.append("| \(idx + 1) | \(escapePipe(item.title)) | \(escapePipe(item.artist)) | \(escapePipe(item.album)) | \(linkCell) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderReadmeMarkdown(trackCount: Int, favoritesCount: Int, playlistCount: Int, includeBackup: Bool) -> String {
        var lines = [
            "# Aster · Lyric 个人歌词库（私有同步）",
            "",
            "本仓库由 Aster · Lyric 自动或手动同步维护，用于保存个人查到的歌词、中文译文与收藏金句（仅限私有仓库）。",
            "",
            "- [INDEX.md](INDEX.md)：全库 **\(trackCount)** 首歌曲总索引",
            "- `tracks/`：每首歌独立 Markdown（原词、译文对照、其他译稿、收藏金句）",
            "- [favorites.md](favorites.md)：收藏金句汇总（**\(favoritesCount)** 句）"
        ]
        if playlistCount > 0 {
            lines.append("- `playlists/`：已浏览歌单目录（**\(playlistCount)** 份，含顺序曲目与单曲歌词跳转）")
        }
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

// MARK: - Bidirectional Markdown Parser

public enum GitHubSyncMarkdownParser {
    public struct ParsedTrackTranslation: Equatable, Sendable {
        public let lyricsVersionID: UUID
        public let sourceContentHash: String
        public let targetLanguage: String
        public let linesByIndex: [Int: String]
    }

    public struct ParsedFavorite: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let text: String
        public let translation: String?
    }

    static func parseTrackMarkdown(
        _ markdown: String,
        knownLyricsByID: [UUID: PersonalLyricsLibraryPackage.PackageLyricsVersion]
    ) -> ParsedTrackTranslation? {
        let rawLines = markdown.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        let frontmatter = parseFrontmatter(rawLines)
        guard let rawID = frontmatter["lyrics_version_id"],
              let lyricsID = UUID(uuidString: rawID),
              let rawHash = frontmatter["source_content_hash"],
              let sourceLyrics = knownLyricsByID[lyricsID],
              sourceLyrics.contentHash == rawHash else {
            return nil
        }

        let targetLanguage = frontmatter["translation_language"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-Hans"

        guard let sectionStart = rawLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## 歌词与译文对照" }) else {
            return nil
        }

        struct BulletItem {
            var originalText: String
            var translation: String = ""
        }

        var bullets: [BulletItem] = []
        for line in rawLines[(sectionStart + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            if trimmed.isEmpty { continue }

            if line.hasPrefix("- ") {
                bullets.append(BulletItem(originalText: String(line.dropFirst(2))))
            } else if (line.hasPrefix("  ") || line.hasPrefix("\t")), !bullets.isEmpty {
                if trimmed.hasPrefix("- 译：") {
                    bullets[bullets.count - 1].translation = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("- 译:") {
                    bullets[bullets.count - 1].translation = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let nonBlankSource = sourceLyrics.lines
            .sorted { $0.lineIndex < $1.lineIndex }
            .filter { !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard bullets.count == nonBlankSource.count else { return nil }

        var linesByIndex: [Int: String] = [:]
        var hasAnyTranslation = false

        for (bullet, sourceLine) in zip(bullets, nonBlankSource) {
            var parsedOrig = stripLeadingTimestamp(from: bullet.originalText)
            if let performer = sourceLine.performerID, !performer.isEmpty {
                let prefix = "（\(performer)）"
                if parsedOrig.hasPrefix(prefix) {
                    parsedOrig = String(parsedOrig.dropFirst(prefix.count))
                }
            }
            let expectedOrig = sourceLine.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard parsedOrig.trimmingCharacters(in: .whitespacesAndNewlines) == expectedOrig else {
                return nil
            }
            linesByIndex[sourceLine.lineIndex] = bullet.translation
            if !bullet.translation.isEmpty {
                hasAnyTranslation = true
            }
        }

        guard hasAnyTranslation else { return nil }
        return ParsedTrackTranslation(
            lyricsVersionID: lyricsID,
            sourceContentHash: rawHash,
            targetLanguage: targetLanguage,
            linesByIndex: linesByIndex
        )
    }

    static func parseFavoritesMarkdown(_ markdown: String) -> [ParsedFavorite]? {
        let rawLines = markdown.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard rawLines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "# 收藏金句" }) else {
            return nil
        }

        var items: [ParsedFavorite] = []
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- **"),
               let parsed = parseFavoriteBullet(line) {
                items.append(parsed)
            } else if (line.hasPrefix("  ") || line.hasPrefix("\t")), !items.isEmpty {
                if trimmed.hasPrefix("- 译：") {
                    let prev = items[items.count - 1]
                    let tr = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    items[items.count - 1] = ParsedFavorite(title: prev.title, artist: prev.artist, text: prev.text, translation: tr.isEmpty ? nil : tr)
                } else if trimmed.hasPrefix("- 译:") {
                    let prev = items[items.count - 1]
                    let tr = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    items[items.count - 1] = ParsedFavorite(title: prev.title, artist: prev.artist, text: prev.text, translation: tr.isEmpty ? nil : tr)
                }
            }
        }
        return items
    }

    private static func parseFavoriteBullet(_ line: String) -> ParsedFavorite? {
        // Format: - **Title** — Artist：「Text」
        guard line.hasPrefix("- **"), line.hasSuffix("」") else { return nil }
        let afterOpen = line.dropFirst(4)
        guard let titleCloseRange = afterOpen.range(of: "** — ") else { return nil }
        let title = String(afterOpen[..<titleCloseRange.lowerBound])
        let afterTitle = afterOpen[titleCloseRange.upperBound...]
        guard let quoteStartRange = afterTitle.range(of: "：「", options: .backwards) else { return nil }
        let artist = String(afterTitle[..<quoteStartRange.lowerBound])
        let text = String(afterTitle[quoteStartRange.upperBound...].dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { return nil }
        return ParsedFavorite(title: title, artist: artist, text: text, translation: nil)
    }

    private static func parseFrontmatter(_ lines: [String]) -> [String: String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func stripLeadingTimestamp(from text: String) -> String {
        guard text.hasPrefix("[") else { return text }
        guard let closeBracket = text.firstIndex(of: "]") else { return text }
        let inside = text[text.index(after: text.startIndex)..<closeBracket]
        let isValidTimestamp = inside.contains(":") && inside.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." }
        guard isValidTimestamp else { return text }
        let afterBracket = text.index(after: closeBracket)
        guard afterBracket < text.endIndex else { return "" }
        return String(text[afterBracket...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Baseline Store

public final class GitHubSyncBaselineStore: @unchecked Sendable {
    public struct RepoBaseline: Codable, Equatable, Sendable {
        public var lastRemoteCommitSHA: String?
        public var fileBlobSHAs: [String: String]

        public init(lastRemoteCommitSHA: String? = nil, fileBlobSHAs: [String: String] = [:]) {
            self.lastRemoteCommitSHA = lastRemoteCommitSHA
            self.fileBlobSHAs = fileBlobSHAs
        }
    }

    private struct Storage: Codable {
        var repos: [String: RepoBaseline] = [:]
    }

    public static var defaultURL: URL? {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent("github-sync-baseline.json")
        }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLyrics", isDirectory: true)
            .appendingPathComponent("github-sync-baseline.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var memoryStorage = Storage()

    public init(fileURL: URL? = GitHubSyncBaselineStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func load(repository: String, branch: String) -> RepoBaseline {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(repository: repository, branch: branch)
        return readStorage().repos[key] ?? RepoBaseline()
    }

    public func save(_ baseline: RepoBaseline, repository: String, branch: String) {
        lock.lock()
        defer { lock.unlock() }
        var storage = readStorage()
        storage.repos[Self.key(repository: repository, branch: branch)] = baseline
        writeStorage(storage)
    }

    private static func key(repository: String, branch: String) -> String {
        "\(repository.lowercased())@\(branch)"
    }

    private func readStorage() -> Storage {
        guard let fileURL else { return memoryStorage }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data) else {
            return Storage()
        }
        return decoded
    }

    private func writeStorage(_ storage: Storage) {
        guard let fileURL else {
            memoryStorage = storage
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(storage) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Playlist Snapshot Store

public struct GitHubSyncPlaylistTrack: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let stableKey: String
    public let spotifyID: String?
}

public struct GitHubSyncPlaylistSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let source: String
    public let updatedAt: Date
    public let tracks: [GitHubSyncPlaylistTrack]
}

public final class GitHubSyncPlaylistStore: @unchecked Sendable {
    public static let shared = GitHubSyncPlaylistStore()

    private struct Storage: Codable {
        var playlists: [String: GitHubSyncPlaylistSnapshot] = [:]
    }

    public static var defaultURL: URL? {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DATABASE_PATH"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent("github-sync-playlists.json")
        }
#endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLyrics", isDirectory: true)
            .appendingPathComponent("github-sync-playlists.json")
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var memoryStorage = Storage()

    public init(fileURL: URL? = GitHubSyncPlaylistStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func savePlaylist(id: String, name: String, source: String, tracks: [Track]) {
        guard !id.isEmpty, !tracks.isEmpty else { return }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
        if ProcessInfo.processInfo.environment["LYRICSQ_NATIVE_TESTS"] == "1" && fileURL == Self.defaultURL { return }
#endif
        let mapped = tracks.map { track in
            GitHubSyncPlaylistTrack(
                title: track.title,
                artist: track.artist,
                album: track.album,
                stableKey: TrackIdentity(track: track).stableKey,
                spotifyID: track.spotifyId
            )
        }
        lock.lock()
        defer { lock.unlock() }
        var storage = readStorage()
        storage.playlists[id] = GitHubSyncPlaylistSnapshot(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : name,
            source: source,
            updatedAt: Date(),
            tracks: mapped
        )
        writeStorage(storage)
    }

    public func loadAll() -> [GitHubSyncPlaylistSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return Array(readStorage().playlists.values)
    }

    private func readStorage() -> Storage {
        guard let fileURL else { return memoryStorage }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data) else {
            return Storage()
        }
        return decoded
    }

    private func writeStorage(_ storage: Storage) {
        guard let fileURL else {
            memoryStorage = storage
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(storage) {
            try? data.write(to: fileURL, options: .atomic)
        }
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
        static let bidirectional = "githubSync.bidirectionalSyncEnabled.v1"
        static let translationScope = "githubSync.translationScope.v1"
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
    @Published var bidirectionalSyncEnabled: Bool {
        didSet { defaults.set(bidirectionalSyncEnabled, forKey: Keys.bidirectional) }
    }
    @Published var translationScope: GitHubSyncTranslationScope {
        didSet { defaults.set(translationScope.rawValue, forKey: Keys.translationScope) }
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
    private let favoritesApplier: @MainActor ([V3FavoriteLines.Entry]) -> Void
    private let playlistsLoader: @MainActor () -> [GitHubSyncPlaylistSnapshot]
    private let defaults: UserDefaults
    private let tokenStore: any GitHubSyncTokenStoring
    private let baselineStore: GitHubSyncBaselineStore
    private let client: GitHubSyncClient
    private var autoSyncTask: Task<Void, Never>?
    private var lastRemoteHeadCheckAt: Date?
    private var batchSuppressionCount = 0
    private var pendingBatchSync = false
    private var observers: [NSObjectProtocol] = []

    init(
        repository: SQLiteLyricsRepository = SQLiteLyricsRepository(),
        favoritesLoader: @escaping @MainActor () -> [V3FavoriteLines.Entry] = { V3FavoriteLines.shared.entries },
        favoritesApplier: @escaping @MainActor ([V3FavoriteLines.Entry]) -> Void = { V3FavoriteLines.shared.replaceFromGitHubSync($0) },
        playlistsLoader: @escaping @MainActor () -> [GitHubSyncPlaylistSnapshot] = { GitHubSyncPlaylistStore.shared.loadAll() },
        defaults: UserDefaults = .lyricsQ,
        tokenStore: any GitHubSyncTokenStoring = GitHubSyncTokenStore(),
        baselineStore: GitHubSyncBaselineStore = GitHubSyncBaselineStore(),
        client: GitHubSyncClient = GitHubSyncClient(),
        observesMutations: Bool = true
    ) {
        self.repository = repository
        self.favoritesLoader = favoritesLoader
        self.favoritesApplier = favoritesApplier
        self.playlistsLoader = playlistsLoader
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.baselineStore = baselineStore
        self.client = client
        self.repositoryText = defaults.string(forKey: Keys.repository) ?? ""
        self.branchText = defaults.string(forKey: Keys.branch) ?? "main"
        self.autoSyncEnabled = defaults.bool(forKey: Keys.autoSync)
        self.bidirectionalSyncEnabled = defaults.object(forKey: Keys.bidirectional) as? Bool ?? true
        if let rawScope = defaults.string(forKey: Keys.translationScope),
           let scope = GitHubSyncTranslationScope(rawValue: rawScope) {
            self.translationScope = scope
        } else {
            self.translationScope = .aiAndManual
        }
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
        statusMessage = bidirectionalSyncEnabled ? "正在双向检查并同步歌词与译文…" : "正在打包歌词并同步到 GitHub…"
        defer { isSyncing = false }

        do {
            var package = try await repository.exportPersonalDataPackage()
            var favorites = favoritesLoader()
            let playlists = playlistsLoader()
            var built = try GitHubSyncSnapshotBuilder.buildFiles(
                package: package,
                favorites: favorites,
                playlists: playlists,
                defaults: defaults,
                includeDataPackageBackup: includeDataPackageBackup,
                translationScope: translationScope
            )

            let remoteSnapshot = try await client.fetchRemoteBranchSnapshot(
                repository: repositoryText,
                branch: branchText,
                token: token
            )

            let resolvedRepoSlug = remoteSnapshot?.repository ?? GitHubRepositorySlug.normalize(repositoryText)?.slug ?? repositoryText
            let resolvedBranch = remoteSnapshot?.branch ?? branchText
            let baseline = baselineStore.load(repository: resolvedRepoSlug, branch: resolvedBranch)

            var pulledCount = 0
            var conflictCount = 0

            if bidirectionalSyncEnabled, let remoteSnapshot {
                let pullOutcome = try await pullRemoteChanges(
                    remoteSnapshot: remoteSnapshot,
                    localFiles: built.files,
                    baseline: baseline,
                    package: package,
                    favorites: favorites,
                    token: token
                )
                pulledCount = pullOutcome.pulledCount
                conflictCount = pullOutcome.conflictCount
                if pullOutcome.didMutateLocal {
                    package = try await repository.exportPersonalDataPackage()
                    favorites = favoritesLoader()
                    built = try GitHubSyncSnapshotBuilder.buildFiles(
                        package: package,
                        favorites: favorites,
                        playlists: playlists,
                        defaults: defaults,
                        includeDataPackageBackup: includeDataPackageBackup,
                        translationScope: translationScope
                    )
                }
            }

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
                pulledCount: pulledCount,
                conflictCount: conflictCount,
                preloadedSnapshot: remoteSnapshot,
                commitMessage: commitMessage
            )

            let nextBlobSHAs = Dictionary(uniqueKeysWithValues: built.files.map { ($0.key, GitHubSyncClient.gitBlobSHA(of: $0.value)) })
            baselineStore.save(
                GitHubSyncBaselineStore.RepoBaseline(
                    lastRemoteCommitSHA: result.headCommitSHA ?? remoteSnapshot?.headCommitSHA,
                    fileBlobSHAs: nextBlobSHAs
                ),
                repository: result.repository,
                branch: result.branch
            )

            let now = Date()
            lastSyncDate = now
            defaults.set(now, forKey: Keys.lastDate)
            let summary = Self.formatSummary(result: result)
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

    private func pullRemoteChanges(
        remoteSnapshot: GitHubSyncRemoteSnapshot,
        localFiles: [String: Data],
        baseline: GitHubSyncBaselineStore.RepoBaseline,
        package: PersonalDataPackage,
        favorites: [V3FavoriteLines.Entry],
        token: String
    ) async throws -> (pulledCount: Int, conflictCount: Int, didMutateLocal: Bool) {
        let localBlobSHAs = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.key, GitHubSyncClient.gitBlobSHA(of: $0.value)) })

        var blobsToFetch: [(path: String, sha: String)] = []
        for (path, remoteSHA) in remoteSnapshot.treeBlobSHAs where path.hasPrefix("tracks/") && path.hasSuffix(".md") {
            if remoteSHA != baseline.fileBlobSHAs[path], remoteSHA != localBlobSHAs[path] {
                blobsToFetch.append((path, remoteSHA))
            }
        }
        if let remoteFavSHA = remoteSnapshot.treeBlobSHAs["favorites.md"],
           remoteFavSHA != baseline.fileBlobSHAs["favorites.md"],
           remoteFavSHA != localBlobSHAs["favorites.md"] {
            blobsToFetch.append(("favorites.md", remoteFavSHA))
        }

        guard !blobsToFetch.isEmpty else {
            return (0, 0, false)
        }

        let fetchedData = try await client.fetchBlobsData(
            repository: remoteSnapshot.repository,
            blobs: blobsToFetch.sorted { $0.path < $1.path },
            token: token
        )

        var knownLyricsByID: [UUID: PersonalLyricsLibraryPackage.PackageLyricsVersion] = [:]
        for trackPkg in package.tracks {
            for lv in trackPkg.lyricsVersions {
                knownLyricsByID[lv.id] = lv
            }
        }

        var pulledCount = 0
        var conflictCount = 0
        var didMutateLocal = false

        for (path, data) in fetchedData.sorted(by: { $0.key < $1.key }) where path != "favorites.md" {
            guard let markdown = String(data: data, encoding: .utf8),
                  let parsed = GitHubSyncMarkdownParser.parseTrackMarkdown(markdown, knownLyricsByID: knownLyricsByID) else {
                continue
            }
            let localChangedSinceBase = baseline.fileBlobSHAs[path] != nil && localBlobSHAs[path] != baseline.fileBlobSHAs[path]
            if let saved = try await repository.saveGitHubSyncedTranslation(
                lyricsVersionID: parsed.lyricsVersionID,
                sourceContentHash: parsed.sourceContentHash,
                targetLanguage: parsed.targetLanguage,
                linesByIndex: parsed.linesByIndex,
                isConflictCandidate: localChangedSinceBase
            ) {
                _ = saved
                pulledCount += 1
                didMutateLocal = true
                if localChangedSinceBase {
                    conflictCount += 1
                }
            }
        }

        if let favData = fetchedData["favorites.md"],
           let favMarkdown = String(data: favData, encoding: .utf8),
           let parsedFavs = GitHubSyncMarkdownParser.parseFavoritesMarkdown(favMarkdown) {
            let localFavChanged = baseline.fileBlobSHAs["favorites.md"] != nil
                && localBlobSHAs["favorites.md"] != baseline.fileBlobSHAs["favorites.md"]
            let merged = mergeFavorites(parsedRemote: parsedFavs, local: favorites, preserveLocalExtras: localFavChanged, package: package)
            if merged != favorites {
                favoritesApplier(merged)
                pulledCount += 1
                didMutateLocal = true
            }
        }

        return (pulledCount, conflictCount, didMutateLocal)
    }

    private func mergeFavorites(
        parsedRemote: [GitHubSyncMarkdownParser.ParsedFavorite],
        local: [V3FavoriteLines.Entry],
        preserveLocalExtras: Bool,
        package: PersonalDataPackage
    ) -> [V3FavoriteLines.Entry] {
        struct FavoriteIdentity: Hashable {
            let title: String
            let artist: String
            let text: String
        }
        func makeIdentity(title: String, artist: String, text: String) -> FavoriteIdentity {
            FavoriteIdentity(
                title: TrackTextNormalizer.normalize(title),
                artist: TrackTextNormalizer.normalize(artist),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var localByID: [FavoriteIdentity: V3FavoriteLines.Entry] = [:]
        for entry in local {
            let key = makeIdentity(title: entry.title, artist: entry.artist, text: entry.text)
            if localByID[key] == nil { localByID[key] = entry }
        }

        var trackByTitleArtist: [String: PersonalLyricsLibraryPackage.PackageTrack] = [:]
        for pkg in package.tracks {
            let key = "\(TrackTextNormalizer.normalize(pkg.track.title))|\(TrackTextNormalizer.normalize(pkg.track.artist))"
            if trackByTitleArtist[key] == nil { trackByTitleArtist[key] = pkg.track }
        }

        var merged: [V3FavoriteLines.Entry] = []
        var seen = Set<FavoriteIdentity>()

        for item in parsedRemote {
            let id = makeIdentity(title: item.title, artist: item.artist, text: item.text)
            guard seen.insert(id).inserted else { continue }
            if var existing = localByID[id] {
                existing.translation = item.translation
                merged.append(existing)
            } else {
                let trackKeyHint = "\(TrackTextNormalizer.normalize(item.title))|\(TrackTextNormalizer.normalize(item.artist))"
                let matchedTrack = trackByTitleArtist[trackKeyHint]
                merged.append(V3FavoriteLines.Entry(
                    text: item.text,
                    translation: item.translation,
                    title: item.title,
                    artist: item.artist,
                    trackKey: matchedTrack?.stableKey ?? "metadata:\(trackKeyHint)",
                    artworkURL: matchedTrack?.artworkURL.flatMap(URL.init(string:))
                ))
            }
        }

        if preserveLocalExtras {
            for entry in local {
                let id = makeIdentity(title: entry.title, artist: entry.artist, text: entry.text)
                if seen.insert(id).inserted {
                    merged.append(entry)
                }
            }
        }

        return merged
    }

    private static func formatSummary(result: GitHubSyncResult) -> String {
        var segments: [String] = []
        if result.pulledCount > 0 {
            segments.append("拉取 \(result.pulledCount) 项")
        }
        switch result.status {
        case .upToDate:
            if segments.isEmpty {
                return "已是最新（\(result.trackCount) 首歌曲 · 无需上传）"
            }
        case .committed(_, let uploaded, let deleted):
            var pushText = "推送 \(uploaded) 项"
            if deleted > 0 { pushText += "，清理 \(deleted) 项" }
            segments.append(pushText)
        }
        if result.conflictCount > 0 {
            segments.append("双端冲突 \(result.conflictCount) 首（已保留本地稿并存为候选）")
        }
        return "双向已同步（\(segments.joined(separator: " · ")) · 共 \(result.trackCount) 首）"
    }

    public func triggerManualSync() {
        Task { await syncNow() }
    }

    public func beginBatchSuppression() {
        batchSuppressionCount += 1
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    public func endBatchSuppression() {
        guard batchSuppressionCount > 0 else { return }
        batchSuppressionCount -= 1
        if batchSuppressionCount == 0 && pendingBatchSync {
            pendingBatchSync = false
            scheduleAutoSyncIfNeeded()
        }
    }

    public func scheduleAutoSyncIfNeeded() {
        guard autoSyncEnabled, isConfigured else { return }
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" { return }
        if ProcessInfo.processInfo.environment["LYRICSQ_NATIVE_TESTS"] == "1" { return }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        if batchSuppressionCount > 0 {
            pendingBatchSync = true
            autoSyncTask?.cancel()
            autoSyncTask = nil
            return
        }
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.autoSyncEnabled, self.isConfigured, self.batchSuppressionCount == 0 else { return }
            _ = await self.syncNow()
        }
    }

    private func checkRemoteChangesIfNeeded() {
        guard autoSyncEnabled, bidirectionalSyncEnabled, isConfigured, !isSyncing, batchSuppressionCount == 0 else { return }
        if ProcessInfo.processInfo.environment["SPOTIFYLYRICS_DISABLE_KEYCHAIN"] == "1" { return }
        if ProcessInfo.processInfo.environment["LYRICSQ_NATIVE_TESTS"] == "1" { return }
#if DEBUG
        if DebugAcceptanceDataIsolation.isRequested { return }
#endif
        if let lastCheck = lastRemoteHeadCheckAt, Date().timeIntervalSince(lastCheck) < 20 { return }
        lastRemoteHeadCheckAt = Date()
        guard let token = tokenStore.read(), !token.isEmpty else { return }
        let repo = repositoryText
        let branch = branchText
        Task { [weak self] in
            guard let self else { return }
            guard let normalized = GitHubRepositorySlug.normalize(repo) else { return }
            guard let remoteHead = try? await self.client.fetchHeadCommitSHA(repository: repo, branch: branch, token: token) else { return }
            let baseline = self.baselineStore.load(repository: normalized.slug, branch: branch)
            if remoteHead != baseline.lastRemoteCommitSHA {
                _ = await self.syncNow()
            }
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
#if canImport(AppKit)
        let activeObserver = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkRemoteChangesIfNeeded() }
        }
        observers = [dbObserver, favObserver, activeObserver]
#else
        observers = [dbObserver, favObserver]
#endif
    }
}
