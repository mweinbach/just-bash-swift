import Foundation
import JustBashFS

func curl() -> AnyBashCommand {
    AnyBashCommand(name: "curl") { args, ctx in
        var outputPath: String?
        var headOnly = false
        var urls: [String] = []
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--help":
                return ExecResult.success("curl URL\n  -o FILE   write body to file\n  -I        head request\n")
            case "-o", "--output":
                index += 1
                if index < args.count { outputPath = args[index] }
            case "-I", "--head":
                headOnly = true
            default:
                if !args[index].hasPrefix("-") {
                    urls.append(args[index])
                }
            }
            index += 1
        }

        guard let urlString = urls.first else { return ExecResult.failure("curl: no URL specified") }
        let (headers, body): (String, Data)
        do {
            (headers, body) = try await fetchURLPayload(urlString)
        } catch {
            return ExecResult.failure("curl: \(error.localizedDescription)")
        }

        let stdout: String
        if headOnly {
            stdout = headers
        } else if let outputPath {
            do {
                try ctx.fileSystem.writeFile(stringFromVirtualData(body, preferUTF8: false), to: outputPath, relativeTo: ctx.cwd)
                stdout = ""
            } catch {
                return ExecResult.failure("curl: \(error.localizedDescription)")
            }
        } else {
            stdout = stringFromVirtualData(body, preferUTF8: true)
        }

        return ExecResult.success(stdout + (stdout.isEmpty || stdout.hasSuffix("\n") ? "" : "\n"))
    }
}

func htmlToMarkdown() -> AnyBashCommand {
    AnyBashCommand(name: "html-to-markdown") { args, ctx in
        let files = args.filter { !$0.hasPrefix("-") }
        let html: String
        do {
            if files.isEmpty {
                html = ctx.stdin
            } else {
                html = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined()
            }
        } catch {
            return ExecResult.failure("html-to-markdown: \(error.localizedDescription)")
        }
        return ExecResult.success(convertHTMLToMarkdown(html))
    }
}

private func fetchURLPayload(_ urlString: String) async throws -> (String, Data) {
    if urlString.hasPrefix("data:") {
        guard let comma = urlString.firstIndex(of: ",") else {
            throw NSError(domain: "curl", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid data URL"])
        }
        let metadata = String(urlString[..<comma])
        let payload = String(urlString[urlString.index(after: comma)...])
        if metadata.contains(";base64"), let data = Data(base64Encoded: payload) {
            return ("HTTP/1.1 200 OK\n", data)
        }
        return ("HTTP/1.1 200 OK\n", Data(payload.removingPercentEncoding?.utf8 ?? payload.utf8))
    }

    guard let url = URL(string: urlString) else {
        throw NSError(domain: "curl", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid URL"])
    }

    if url.isFileURL {
        let data = try Data(contentsOf: url)
        return ("HTTP/1.1 200 OK\n", data)
    }

    let (data, response) = try await URLSession.shared.data(from: url)
    let headerText: String
    if let http = response as? HTTPURLResponse {
        let lines = ["HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"] +
            http.allHeaderFields.map { "\($0.key): \($0.value)" }
        headerText = lines.joined(separator: "\n") + "\n"
    } else {
        headerText = "HTTP/1.1 200 OK\n"
    }
    return (headerText, data)
}

private func convertHTMLToMarkdown(_ html: String) -> String {
    var result = html
    let replacements: [(String, String)] = [
        ("(?is)<h1>(.*?)</h1>", "# $1\n\n"),
        ("(?is)<h2>(.*?)</h2>", "## $1\n\n"),
        ("(?is)<strong>(.*?)</strong>", "**$1**"),
        ("(?is)<b>(.*?)</b>", "**$1**"),
        ("(?is)<em>(.*?)</em>", "_$1_"),
        ("(?is)<i>(.*?)</i>", "_$1_"),
        ("(?is)<code>(.*?)</code>", "`$1`"),
        ("(?is)<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", "[$2]($1)"),
        ("(?is)<li>(.*?)</li>", "- $1\n"),
        ("(?is)<p>(.*?)</p>", "$1\n\n"),
        ("(?is)<br\\s*/?>", "\n")
    ]

    for (pattern, template) in replacements {
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(result.startIndex..., in: result)
        result = regex?.stringByReplacingMatches(in: result, range: range, withTemplate: template) ?? result
    }

    let tagRegex = try? NSRegularExpression(pattern: "(?is)<[^>]+>")
    if let tagRegex {
        let range = NSRange(result.startIndex..., in: result)
        result = tagRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }

    result = result
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")

    return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}
