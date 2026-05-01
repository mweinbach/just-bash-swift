import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JustBashFS

func git() -> AnyBashCommand {
    AnyBashCommand(name: "git") { args, ctx in
        await PortableGit(ctx: ctx).run(args)
    }
}

private struct PortableGit {
    let ctx: CommandContext

    func run(_ rawArgs: [String]) async -> ExecResult {
        let parsed = parseGlobalOptions(rawArgs)
        let args = parsed.args
        guard let command = args.first else {
            return .failure("git: usage: git <command> [<args>]")
        }
        let rest = Array(args.dropFirst())

        switch command {
        case "--version", "version":
            return .success("git version just-bash-portable\n")
        case "init":
            return initRepository(rest)
        case "status":
            return status(rest, gitDirOverride: parsed.gitDir)
        case "add":
            return add(rest, gitDirOverride: parsed.gitDir)
        case "commit":
            return commit(rest, gitDirOverride: parsed.gitDir)
        case "log":
            return log(rest, gitDirOverride: parsed.gitDir)
        case "rev-parse":
            return revParse(rest, gitDirOverride: parsed.gitDir)
        case "clone":
            return await clone(rest)
        case "push":
            return push(rest, gitDirOverride: parsed.gitDir)
        case "ls-remote":
            return await lsRemote(rest)
        case "credential":
            return credential(rest)
        default:
            return .failure("git: '\(command)' is not a supported portable git command")
        }
    }

    // MARK: - Commands

    private func initRepository(_ args: [String]) -> ExecResult {
        let bare = args.contains("--bare")
        let positional = args.filter { !$0.hasPrefix("-") }
        let target = positional.last ?? "."
        let repoRoot = ctx.fileSystem.normalizePath(target, relativeTo: ctx.cwd)
        let gitDir = bare ? repoRoot : join(repoRoot, ".git")

        do {
            try ensureDirectory(repoRoot)
            try ensureDirectory(gitDir)
            try ensureDirectory(join(gitDir, "refs/heads"))
            try ensureDirectory(join(gitDir, "objects"))
            try ensureDirectory(join(gitDir, "justbash"))
            try writeText("ref: refs/heads/master\n", to: join(gitDir, "HEAD"))
            try writeText("[core]\n\trepositoryformatversion = 0\n\tbare = \(bare ? "true" : "false")\n", to: join(gitDir, "config"))
            try writeJSON([String](), to: join(gitDir, "justbash/index.json"))
            try writeJSON([PortableCommit](), to: join(gitDir, "justbash/commits.json"))
        } catch {
            return .failure("git init: \(error.localizedDescription)")
        }

        return .success("Initialized empty Git repository in \(gitDir)/\n")
    }

    private func add(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        guard !repo.isBare else {
            return .failure("fatal: this operation must be run in a work tree", exitCode: 128)
        }

        let paths = args.filter { !$0.hasPrefix("-") }
        let requested = paths.isEmpty ? ["."] : paths

        do {
            var staged = Set(try readIndex(repo.gitDir))
            for path in requested {
                let absolute = ctx.fileSystem.normalizePath(path, relativeTo: ctx.cwd)
                if ctx.fileSystem.isDirectory(path: absolute, relativeTo: "/") {
                    for file in try ctx.fileSystem.walk(path: absolute, relativeTo: "/") where isStageableFile(file, repo: repo) {
                        staged.insert(relativePath(file, from: repo.workTree))
                    }
                } else if ctx.fileSystem.fileExists(path: absolute, relativeTo: "/"), isStageableFile(absolute, repo: repo) {
                    staged.insert(relativePath(absolute, from: repo.workTree))
                } else {
                    return .failure("fatal: pathspec '\(path)' did not match any files")
                }
            }
            try writeJSON(staged.sorted(), to: join(repo.gitDir, "justbash/index.json"))
            return .success()
        } catch {
            return .failure("git add: \(error.localizedDescription)")
        }
    }

    private func commit(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        guard !repo.isBare else {
            return .failure("fatal: this operation must be run in a work tree", exitCode: 128)
        }
        guard let message = commitMessage(from: args), !message.isEmpty else {
            return .failure("error: switch `m' requires a value")
        }

        do {
            let staged = try readIndex(repo.gitDir)
            guard !staged.isEmpty else {
                return ExecResult(stdout: "On branch \(repo.headBranchName)\nnothing to commit, working tree clean\n", stderr: "", exitCode: 1)
            }

            var commits = try readCommits(repo.gitDir)
            let parent = try readHeadCommit(repo)
            var snapshot = parent.flatMap { id in commits.first(where: { $0.id == id })?.snapshot } ?? [:]
            for path in staged {
                let absolute = join(repo.workTree, path)
                if ctx.fileSystem.fileExists(path: absolute, relativeTo: "/") {
                    snapshot[path] = try readText(absolute)
                } else {
                    snapshot.removeValue(forKey: path)
                }
            }

            let authorName = ctx.environment["GIT_AUTHOR_NAME"] ?? ctx.environment["USER"] ?? "Just Bash"
            let authorEmail = ctx.environment["GIT_AUTHOR_EMAIL"] ?? "just-bash@example.com"
            let seed = ([message, parent ?? "", authorName, authorEmail] + snapshot.keys.sorted().flatMap { [$0, snapshot[$0] ?? ""] }).joined(separator: "\u{1f}")
            let id = sha1(seed)
            let commit = PortableCommit(id: id, message: message, parent: parent, authorName: authorName, authorEmail: authorEmail, timestamp: Date().timeIntervalSince1970, snapshot: snapshot)
            commits.append(commit)
            try writeJSON(commits, to: join(repo.gitDir, "justbash/commits.json"))
            try writeText(id + "\n", to: repo.headRefPath)
            try writeJSON([String](), to: join(repo.gitDir, "justbash/index.json"))

            let branch = repo.headBranchName
            let summary = "[\(branch) \(String(id.prefix(7)))] \(message)\n \(staged.count) file\(staged.count == 1 ? "" : "s") changed\n"
            return .success(summary)
        } catch {
            return .failure("git commit: \(error.localizedDescription)")
        }
    }

    private func status(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        guard !repo.isBare else {
            return .success()
        }

        do {
            let short = args.contains("--short") || args.contains("-s")
            let staged = Set(try readIndex(repo.gitDir))
            let headSnapshot = try currentSnapshot(repo)
            let files = Set(try ctx.fileSystem.walk(path: repo.workTree, relativeTo: "/")
                .filter { isStageableFile($0, repo: repo) }
                .map { relativePath($0, from: repo.workTree) })
            let tracked = Set(headSnapshot.keys)
            let all = files.union(tracked).union(staged).sorted()

            var lines: [String] = []
            for path in all {
                if staged.contains(path) {
                    lines.append("A  \(path)")
                    continue
                }
                let absolute = join(repo.workTree, path)
                if tracked.contains(path), !files.contains(path) {
                    lines.append(" D \(path)")
                } else if tracked.contains(path), let content = try? readText(absolute), content != headSnapshot[path] {
                    lines.append(" M \(path)")
                } else if !tracked.contains(path), files.contains(path) {
                    lines.append("?? \(path)")
                }
            }

            if short {
                return .success(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
            }
            if lines.isEmpty {
                return .success("On branch \(repo.headBranchName)\nnothing to commit, working tree clean\n")
            }
            return .success(lines.joined(separator: "\n") + "\n")
        } catch {
            return .failure("git status: \(error.localizedDescription)")
        }
    }

    private func log(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        do {
            let commits = try readCommits(repo.gitDir)
            guard let head = try readHeadCommit(repo), let start = commits.first(where: { $0.id == head }) else {
                return .failure("fatal: your current branch '\(repo.headBranchName)' does not have any commits yet", exitCode: 128)
            }
            let oneline = args.contains("--oneline")
            let maxCount = args.contains("-1") ? 1 : Int.max
            var byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
            var current: PortableCommit? = start
            var rendered: [String] = []
            while let commit = current, rendered.count < maxCount {
                if oneline {
                    rendered.append("\(String(commit.id.prefix(7))) \(commit.message)")
                } else {
                    rendered.append("commit \(commit.id)\nAuthor: \(commit.authorName) <\(commit.authorEmail)>\n\n    \(commit.message)")
                }
                current = commit.parent.flatMap { byID[$0] }
                if let id = current?.id { byID[id] = nil }
            }
            return .success(rendered.joined(separator: "\n") + "\n")
        } catch {
            return .failure("git log: \(error.localizedDescription)")
        }
    }

    private func revParse(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        if args.contains("--show-toplevel") {
            return repo.isBare ? .failure("fatal: this operation must be run in a work tree", exitCode: 128) : .success(repo.workTree + "\n")
        }
        guard let name = args.first else {
            return .failure("usage: git rev-parse [--show-toplevel] <rev>")
        }
        do {
            if name == "HEAD", let head = try readHeadCommit(repo) {
                return .success(head + "\n")
            }
            let refPath = name.hasPrefix("refs/") ? join(repo.gitDir, name) : join(repo.gitDir, "refs/heads/\(name)")
            if ctx.fileSystem.fileExists(path: refPath, relativeTo: "/") {
                return .success(try readText(refPath).trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            }
            return .failure("fatal: ambiguous argument '\(name)': unknown revision or path not in the working tree.", exitCode: 128)
        } catch {
            return .failure("git rev-parse: \(error.localizedDescription)")
        }
    }

    private func clone(_ args: [String]) async -> ExecResult {
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let source = positional.first else {
            return .failure("fatal: repository URL required")
        }
        let destination = positional.dropFirst().first ?? defaultCloneDirectoryName(for: source)
        if source.contains("://") {
            return await cloneGitHub(source: source, destination: destination)
        }

        let sourcePath = ctx.fileSystem.normalizePath(source, relativeTo: ctx.cwd)
        let destPath = ctx.fileSystem.normalizePath(destination, relativeTo: ctx.cwd)
        let sourceGitDir = ctx.fileSystem.isDirectory(path: join(sourcePath, ".git"), relativeTo: "/") ? join(sourcePath, ".git") : sourcePath
        do {
            let commits = try readCommits(sourceGitDir)
            let sourceRepo = PortableRepo(gitDir: sourceGitDir, workTree: sourcePath, isBare: !ctx.fileSystem.isDirectory(path: join(sourcePath, ".git"), relativeTo: "/"))
            let head = try readHeadCommit(sourceRepo)
            try ensureDirectory(destPath)
            try initClonedMetadata(at: destPath, commits: commits, head: head)
            if let head, let commit = commits.first(where: { $0.id == head }) {
                for (path, content) in commit.snapshot {
                    let out = join(destPath, path)
                    try ensureDirectory(dirname(out))
                    try writeText(content, to: out)
                }
            }
            return .success("Cloning into '\(destination)'...\n")
        } catch {
            return .failure("fatal: could not clone '\(source)': \(error.localizedDescription)")
        }
    }

    private func push(_ args: [String], gitDirOverride: String?) -> ExecResult {
        guard let repo = locateRepository(gitDirOverride: gitDirOverride) else {
            return .failure("fatal: not a git repository (or any of the parent directories): .git", exitCode: 128)
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let remoteArg = positional.first else {
            return .failure("fatal: remote required")
        }
        guard !remoteArg.contains("://") else {
            return .failure("fatal: portable git remote push requires a libgit2-backed transport; local repository push is available in-process")
        }
        let refspec = positional.dropFirst().first ?? "HEAD:refs/heads/\(repo.headBranchName)"
        let parts = refspec.split(separator: ":", maxSplits: 1).map(String.init)
        let dstRef = parts.count == 2 ? parts[1] : "refs/heads/\(repo.headBranchName)"
        let remotePath = ctx.fileSystem.normalizePath(remoteArg == "origin" ? readOrigin(repo) ?? remoteArg : remoteArg, relativeTo: ctx.cwd)
        let remoteGitDir = ctx.fileSystem.isDirectory(path: join(remotePath, ".git"), relativeTo: "/") ? join(remotePath, ".git") : remotePath

        do {
            let commits = try readCommits(repo.gitDir)
            try ensureDirectory(join(remoteGitDir, "justbash"))
            try ensureDirectory(dirname(join(remoteGitDir, dstRef)))
            try writeJSON(commits, to: join(remoteGitDir, "justbash/commits.json"))
            if let head = try readHeadCommit(repo) {
                try writeText(head + "\n", to: join(remoteGitDir, dstRef))
            }
            return .success()
        } catch {
            return .failure("fatal: could not push to '\(remoteArg)': \(error.localizedDescription)")
        }
    }

    private func lsRemote(_ args: [String]) async -> ExecResult {
        let positional = args.filter { !$0.hasPrefix("-") }
        guard let remote = positional.first else {
            return .failure("usage: git ls-remote <repository>")
        }
        guard let github = parseGitHubRemote(remote) else {
            return .failure("fatal: portable git ls-remote currently supports GitHub HTTPS remotes")
        }

        do {
            var request = URLRequest(url: github.apiURL(path: "git/matching-refs"))
            applyGitHubAuth(to: &request, host: "github.com")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure("fatal: unable to access '\(remote)': \(httpStatus(response))")
            }
            let refs = try JSONDecoder().decode([GitHubRef].self, from: data)
            let lines = refs.map { "\($0.object.sha)\t\($0.ref)" }.sorted()
            return .success(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        } catch {
            return .failure("fatal: unable to access '\(remote)': \(error.localizedDescription)")
        }
    }

    private func credential(_ args: [String]) -> ExecResult {
        guard args.first == "fill" else {
            return .failure("git credential: only 'fill' is supported")
        }
        let request = parseCredentialRequest(ctx.stdin)
        guard let host = request["host"], let protocolName = request["protocol"] else {
            return .failure("fatal: refusing to work with credential missing host or protocol")
        }
        let home = ctx.environment["HOME"] ?? "/home/user"
        let credentialsPath = ctx.fileSystem.normalizePath(".git-credentials", relativeTo: home)
        guard let lines = try? readText(credentialsPath).split(separator: "\n").map(String.init) else {
            return .failure("fatal: could not read Username for '\(protocolName)://\(host)': terminal prompts disabled")
        }
        for line in lines {
            guard let url = URL(string: line), url.scheme == protocolName, url.host == host else { continue }
            let password = url.password ?? ""
            let username = url.user ?? ""
            return .success("protocol=\(protocolName)\nhost=\(host)\nusername=\(username)\npassword=\(password)\n\n")
        }
        return .failure("fatal: could not read Username for '\(protocolName)://\(host)': terminal prompts disabled")
    }

    // MARK: - GitHub HTTPS transport

    private func cloneGitHub(source: String, destination: String) async -> ExecResult {
        guard let github = parseGitHubRemote(source) else {
            return .failure("fatal: portable git remote clone currently supports GitHub HTTPS remotes")
        }
        let destPath = ctx.fileSystem.normalizePath(destination, relativeTo: ctx.cwd)

        do {
            var repoRequest = URLRequest(url: github.apiURL())
            applyGitHubAuth(to: &repoRequest, host: "github.com")
            let (repoData, repoResponse) = try await URLSession.shared.data(for: repoRequest)
            guard let repoHTTP = repoResponse as? HTTPURLResponse, (200..<300).contains(repoHTTP.statusCode) else {
                return .failure("fatal: unable to access '\(source)': \(httpStatus(repoResponse))")
            }
            let repository = try JSONDecoder().decode(GitHubRepository.self, from: repoData)

            var treeRequest = URLRequest(url: github.apiURL(path: "git/trees/\(repository.defaultBranch)", queryItems: [
                URLQueryItem(name: "recursive", value: "1")
            ]))
            applyGitHubAuth(to: &treeRequest, host: "github.com")
            let (treeData, treeResponse) = try await URLSession.shared.data(for: treeRequest)
            guard let treeHTTP = treeResponse as? HTTPURLResponse, (200..<300).contains(treeHTTP.statusCode) else {
                return .failure("fatal: unable to read remote tree '\(source)': \(httpStatus(treeResponse))")
            }
            let tree = try JSONDecoder().decode(GitHubTreeResponse.self, from: treeData)

            try ensureDirectory(destPath)
            var snapshot: [String: String] = [:]
            for item in tree.tree where item.type == "blob" {
                var blobRequest = URLRequest(url: github.apiURL(path: "git/blobs/\(item.sha)"))
                applyGitHubAuth(to: &blobRequest, host: "github.com")
                let (blobData, blobResponse) = try await URLSession.shared.data(for: blobRequest)
                guard let blobHTTP = blobResponse as? HTTPURLResponse, (200..<300).contains(blobHTTP.statusCode) else {
                    return .failure("fatal: unable to read remote blob '\(item.path)': \(httpStatus(blobResponse))")
                }
                let blob = try JSONDecoder().decode(GitHubBlob.self, from: blobData)
                let cleanContent = blob.content.replacingOccurrences(of: "\n", with: "")
                let fileData = Data(base64Encoded: cleanContent) ?? Data()
                let outputPath = join(destPath, item.path)
                try ensureDirectory(dirname(outputPath))
                try ctx.fileSystem.writeFile(path: outputPath, content: fileData, relativeTo: "/")
                if let text = String(data: fileData, encoding: .utf8) {
                    snapshot[item.path] = text
                }
            }

            try initClonedMetadata(at: destPath, commits: [], head: nil)
            let gitDir = join(destPath, ".git")
            try writeText("[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote \"origin\"]\n\turl = \(source)\n", to: join(gitDir, "config"))
            let message = "Clone \(github.owner)/\(github.repo)"
            let id = sha1(([message] + snapshot.keys.sorted().flatMap { [$0, snapshot[$0] ?? ""] }).joined(separator: "\u{1f}"))
            let commit = PortableCommit(
                id: id,
                message: message,
                parent: nil,
                authorName: "GitHub",
                authorEmail: "noreply@github.com",
                timestamp: Date().timeIntervalSince1970,
                snapshot: snapshot
            )
            try writeJSON([commit], to: join(gitDir, "justbash/commits.json"))
            try writeText(id + "\n", to: join(gitDir, "refs/heads/master"))

            return .success("Cloning into '\(destination)'...\n")
        } catch {
            return .failure("fatal: unable to clone '\(source)': \(error.localizedDescription)")
        }
    }

    // MARK: - Repository helpers

    private func locateRepository(gitDirOverride: String?) -> PortableRepo? {
        if let gitDirOverride {
            let gitDir = ctx.fileSystem.normalizePath(gitDirOverride, relativeTo: ctx.cwd)
            return PortableRepo(gitDir: gitDir, workTree: dirname(gitDir), isBare: isBareGitDir(gitDir))
        }

        var current = ctx.fileSystem.normalizePath(".", relativeTo: ctx.cwd)
        while true {
            let dotGit = join(current, ".git")
            if ctx.fileSystem.isDirectory(path: dotGit, relativeTo: "/") {
                return PortableRepo(gitDir: dotGit, workTree: current, isBare: false)
            }
            if isBareGitDir(current) {
                return PortableRepo(gitDir: current, workTree: dirname(current), isBare: true)
            }
            if current == "/" { return nil }
            current = dirname(current)
        }
    }

    private func isBareGitDir(_ path: String) -> Bool {
        ctx.fileSystem.fileExists(path: join(path, "HEAD"), relativeTo: "/")
            && ctx.fileSystem.isDirectory(path: join(path, "refs"), relativeTo: "/")
            && ctx.fileSystem.isDirectory(path: join(path, "justbash"), relativeTo: "/")
            && !ctx.fileSystem.isDirectory(path: join(path, ".git"), relativeTo: "/")
    }

    private func currentSnapshot(_ repo: PortableRepo) throws -> [String: String] {
        let commits = try readCommits(repo.gitDir)
        guard let head = try readHeadCommit(repo), let commit = commits.first(where: { $0.id == head }) else {
            return [:]
        }
        return commit.snapshot
    }

    private func readHeadCommit(_ repo: PortableRepo) throws -> String? {
        guard ctx.fileSystem.fileExists(path: repo.headRefPath, relativeTo: "/") else { return nil }
        let value = try readText(repo.headRefPath).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func readIndex(_ gitDir: String) throws -> [String] {
        try readJSON([String].self, from: join(gitDir, "justbash/index.json")) ?? []
    }

    private func readCommits(_ gitDir: String) throws -> [PortableCommit] {
        try readJSON([PortableCommit].self, from: join(gitDir, "justbash/commits.json")) ?? []
    }

    private func initClonedMetadata(at workTree: String, commits: [PortableCommit], head: String?) throws {
        let gitDir = join(workTree, ".git")
        try ensureDirectory(gitDir)
        try ensureDirectory(join(gitDir, "refs/heads"))
        try ensureDirectory(join(gitDir, "objects"))
        try ensureDirectory(join(gitDir, "justbash"))
        try writeText("ref: refs/heads/master\n", to: join(gitDir, "HEAD"))
        try writeText("[core]\n\trepositoryformatversion = 0\n\tbare = false\n", to: join(gitDir, "config"))
        try writeJSON([String](), to: join(gitDir, "justbash/index.json"))
        try writeJSON(commits, to: join(gitDir, "justbash/commits.json"))
        if let head {
            try writeText(head + "\n", to: join(gitDir, "refs/heads/master"))
        }
    }

    private func readOrigin(_ repo: PortableRepo) -> String? {
        guard let config = try? readText(join(repo.gitDir, "config")) else { return nil }
        let lines = config.split(separator: "\n").map(String.init)
        for line in lines where line.trimmingCharacters(in: .whitespaces).hasPrefix("url =") {
            return line.components(separatedBy: "=").dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func parseGitHubRemote(_ remote: String) -> GitHubRemote? {
        guard let url = URL(string: remote),
              url.scheme == "https",
              url.host?.lowercased() == "github.com"
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return GitHubRemote(owner: parts[0], repo: repo)
    }

    private func applyGitHubAuth(to request: inout URLRequest, host: String) {
        guard let credential = storedCredential(protocolName: "https", host: host) else { return }
        let token = "\(credential.username):\(credential.password)"
        let encoded = Data(token.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    private func storedCredential(protocolName: String, host: String) -> (username: String, password: String)? {
        let home = ctx.environment["HOME"] ?? "/home/user"
        let credentialsPath = ctx.fileSystem.normalizePath(".git-credentials", relativeTo: home)
        guard let lines = try? readText(credentialsPath).split(separator: "\n").map(String.init) else {
            return nil
        }
        for line in lines {
            guard let url = URL(string: line), url.scheme == protocolName, url.host == host else { continue }
            return (url.user ?? "", url.password ?? "")
        }
        return nil
    }

    private func httpStatus(_ response: URLResponse) -> String {
        guard let http = response as? HTTPURLResponse else { return "non-HTTP response" }
        return "HTTP \(http.statusCode)"
    }

    // MARK: - Parsing

    private func parseGlobalOptions(_ args: [String]) -> (args: [String], gitDir: String?) {
        var remaining: [String] = []
        var gitDir: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--git-dir", index + 1 < args.count {
                gitDir = args[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--git-dir=") {
                gitDir = String(arg.dropFirst("--git-dir=".count))
                index += 1
                continue
            }
            if arg == "-C", index + 1 < args.count {
                index += 2
                continue
            }
            remaining.append(arg)
            index += 1
        }
        return (remaining, gitDir)
    }

    private func commitMessage(from args: [String]) -> String? {
        var index = 0
        while index < args.count {
            if args[index] == "-m" || args[index] == "--message" {
                return index + 1 < args.count ? args[index + 1] : nil
            }
            if args[index].hasPrefix("--message=") {
                return String(args[index].dropFirst("--message=".count))
            }
            index += 1
        }
        return nil
    }

    private func parseCredentialRequest(_ input: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                result[parts[0]] = parts[1]
            }
        }
        return result
    }

    // MARK: - Filesystem helpers

    private func ensureDirectory(_ path: String) throws {
        if ctx.fileSystem.isDirectory(path: path, relativeTo: "/") { return }
        try ctx.fileSystem.createDirectory(path: path, relativeTo: "/", recursive: true)
    }

    private func writeText(_ text: String, to path: String) throws {
        try ensureDirectory(dirname(path))
        try ctx.fileSystem.writeFile(path: path, content: Data(text.utf8), relativeTo: "/")
    }

    private func readText(_ path: String) throws -> String {
        let data = try ctx.fileSystem.readFile(path: path, relativeTo: "/")
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let data = try JSONEncoder().encode(value)
        try ensureDirectory(dirname(path))
        try ctx.fileSystem.writeFile(path: path, content: data, relativeTo: "/")
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from path: String) throws -> T? {
        guard ctx.fileSystem.fileExists(path: path, relativeTo: "/") else { return nil }
        return try JSONDecoder().decode(T.self, from: ctx.fileSystem.readFile(path: path, relativeTo: "/"))
    }

    private func isStageableFile(_ path: String, repo: PortableRepo) -> Bool {
        guard path.hasPrefix(repo.workTree == "/" ? "/" : repo.workTree + "/") else { return false }
        guard !ctx.fileSystem.isDirectory(path: path, relativeTo: "/") else { return false }
        let relative = relativePath(path, from: repo.workTree)
        return !relative.isEmpty && !relative.hasPrefix(".git/")
    }

    private func relativePath(_ path: String, from root: String) -> String {
        if root == "/" { return String(path.dropFirst()) }
        let prefix = root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func defaultCloneDirectoryName(for source: String) -> String {
        let trimmed = source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.split(separator: "/").last.map(String.init) ?? "repository"
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    private func join(_ base: String, _ component: String) -> String {
        if component.hasPrefix("/") { return ctx.fileSystem.normalizePath(component, relativeTo: "/") }
        if base == "/" { return "/" + component }
        return ctx.fileSystem.normalizePath(base + "/" + component, relativeTo: "/")
    }

    private func dirname(_ path: String) -> String {
        let normalized = ctx.fileSystem.normalizePath(path, relativeTo: "/")
        if normalized == "/" { return "/" }
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    private func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct GitHubRemote {
    let owner: String
    let repo: String

    func apiURL(path: String = "", queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        let suffix = path.isEmpty ? "" : "/\(path)"
        components.path = "/repos/\(owner)/\(repo)\(suffix)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}

private struct GitHubRepository: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

private struct GitHubTreeResponse: Decodable {
    let tree: [GitHubTreeItem]
}

private struct GitHubTreeItem: Decodable {
    let path: String
    let type: String
    let sha: String
}

private struct GitHubBlob: Decodable {
    let content: String
}

private struct GitHubRef: Decodable {
    let ref: String
    let object: GitHubRefObject
}

private struct GitHubRefObject: Decodable {
    let sha: String
}

private struct PortableRepo {
    let gitDir: String
    let workTree: String
    let isBare: Bool

    var headBranchName: String { "master" }
    var headRefPath: String { gitDir + "/refs/heads/master" }
}

private struct PortableCommit: Codable {
    let id: String
    let message: String
    let parent: String?
    let authorName: String
    let authorEmail: String
    let timestamp: TimeInterval
    let snapshot: [String: String]
}
