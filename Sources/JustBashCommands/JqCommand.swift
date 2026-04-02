import Foundation

func jq() -> AnyBashCommand {
    AnyBashCommand(name: "jq") { args, ctx in
        var rawOutput = false
        var compact = false
        var nullInput = false
        var filter: String?
        var files: [String] = []

        for arg in args {
            switch arg {
            case "--help":
                return ExecResult.success("jq FILTER [FILE]\n  -c   compact output\n  -r   raw string output\n  -n   null input\n")
            case "-c", "--compact-output":
                compact = true
            case "-r", "--raw-output":
                rawOutput = true
            case "-n", "--null-input":
                nullInput = true
            case let option where option.hasPrefix("-"):
                return ExecResult.failure("jq: unknown option: \(option)")
            default:
                if filter == nil {
                    filter = arg
                } else {
                    files.append(arg)
                }
            }
        }

        let program = filter ?? "."
        let inputs: [Any]
        do {
            if nullInput {
                inputs = [NSNull()]
            } else {
                let inputText: String
                if files.isEmpty {
                    inputText = ctx.stdin
                } else {
                    inputText = try files.map { try ctx.fileSystem.readFile($0, relativeTo: ctx.cwd) }.joined(separator: "\n")
                }
                inputs = try parseJQInputValues(inputText)
            }
        } catch {
            return ExecResult.failure("jq: \(error.localizedDescription)")
        }

        do {
            var outputs: [Any] = []
            for input in inputs {
                outputs.append(contentsOf: try evaluateJQFilter(program, input: input))
            }
            let rendered = outputs.map { renderJQValue($0, compact: compact, raw: rawOutput) }.joined(separator: "\n")
            return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
        } catch {
            return ExecResult.failure("jq: \(error.localizedDescription)")
        }
    }
}

func escapeJSONString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

func parseJQInputValues(_ input: String) throws -> [Any] {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [NSNull()] }
    let data = Data(trimmed.utf8)
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return [value]
}

func evaluateJQFilter(_ filter: String, input: Any, bindings: [String: Any] = [:]) throws -> [Any] {
    let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)

    if let binding = parseJQBinding(trimmed) {
        let boundValue = try evaluateJQFilter(binding.source, input: input, bindings: bindings).first ?? input
        var nextBindings = bindings
        nextBindings[binding.name] = boundValue
        return try evaluateJQFilter(binding.rest, input: input, bindings: nextBindings)
    }

    if let commaParts = splitTopLevelJQ(trimmed, separator: ",") {
        return try commaParts.flatMap { try evaluateJQFilter($0, input: input, bindings: bindings) }
    }

    if let pipeParts = splitTopLevelJQ(trimmed, separator: "|") {
        var values: [Any] = [input]
        for part in pipeParts {
            values = try values.flatMap { try evaluateJQFilter(part, input: $0, bindings: bindings) }
        }
        return values
    }

    if trimmed.hasPrefix("try ") || trimmed == "try" {
        let afterTry = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        if let catchParts = splitTopLevelJQKeyword(afterTry, keyword: " catch ") {
            let expr = catchParts.left.trimmingCharacters(in: .whitespaces)
            let handler = catchParts.right.trimmingCharacters(in: .whitespaces)
            do {
                return try evaluateJQFilter(expr, input: input, bindings: bindings)
            } catch {
                let errorMessage = error.localizedDescription
                return try evaluateJQFilter(handler, input: errorMessage as Any, bindings: bindings)
            }
        } else {
            let expr = afterTry.isEmpty ? "." : afterTry
            do {
                return try evaluateJQFilter(expr, input: input, bindings: bindings)
            } catch {
                return []
            }
        }
    }

    if trimmed.hasPrefix("@") {
        return [jqFormatString(trimmed, value: input)]
    }

    if trimmed == ".." {
        return jqRecursiveDescent(input)
    }

    if trimmed == "." {
        return [input]
    }

    if trimmed == ".[]" {
        return iterateJQValues(input)
    }

    if trimmed == "numbers" {
        return jqIsNumber(input) ? [input] : []
    }

    if trimmed == "strings" {
        return input is String ? [input] : []
    }

    if trimmed == "booleans" {
        if let number = input as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return [input]
        }
        if input is Bool { return [input] }
        return []
    }

    if trimmed == "nulls" {
        return input is NSNull ? [input] : []
    }

    if trimmed == "objects" {
        return jqObjectDictionary(input) != nil ? [input] : []
    }

    if trimmed == "arrays" {
        return input is [Any] ? [input] : []
    }

    if trimmed == "iterables" {
        if input is [Any] || jqObjectDictionary(input) != nil {
            return [input]
        }
        return []
    }

    if trimmed == "scalars" {
        if input is [Any] || jqObjectDictionary(input) != nil {
            return []
        }
        return [input]
    }

    if trimmed == "values" {
        return input is NSNull ? [] : [input]
    }

    if trimmed == "env" {
        return [OrderedJSONObject(entries: [])]
    }

    if trimmed == "empty" {
        return []
    }

    if trimmed == "input" {
        return [NSNull()]
    }

    if trimmed == "inputs" {
        return [[Any]()]
    }

    if trimmed == "explode" {
        guard let string = input as? String else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "explode requires string input"])
        }
        return [string.unicodeScalars.map { Int($0.value) }]
    }

    if trimmed == "implode" {
        guard let array = input as? [Any] else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "implode requires array input"])
        }
        let scalars = array.compactMap { jqIntegerValue($0) }.compactMap { UnicodeScalar($0) }
        return [String(String.UnicodeScalarView(scalars))]
    }

    if trimmed == "tojson" {
        return [renderJQValue(input, compact: true, raw: false)]
    }

    if trimmed == "fromjson" {
        guard let string = input as? String else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "fromjson requires string input"])
        }
        let data = Data(string.utf8)
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return [value]
    }

    if trimmed == "recurse" {
        return jqRecursiveDescent(input)
    }

    if trimmed.hasPrefix("recurse("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        return try jqRecurseWith(input, filter: inner, bindings: bindings)
    }

    if trimmed == "paths" {
        return jqAllPaths(input)
    }

    if trimmed == "leaf_paths" {
        return jqLeafPaths(input)
    }

    if trimmed == "not" {
        return [!jqTruthy(input)]
    }

    if trimmed == "length" {
        return [jqLength(input)]
    }

    if trimmed == "floor" {
        return [jqUnaryNumeric(input) { Foundation.floor($0) }]
    }

    if trimmed == "ceil" {
        return [jqUnaryNumeric(input) { Foundation.ceil($0) }]
    }

    if trimmed == "round" {
        return [jqUnaryNumeric(input) { Foundation.round($0) }]
    }

    if trimmed == "sqrt" {
        return [jqUnaryNumeric(input) { Foundation.sqrt($0) }]
    }

    if trimmed == "abs" {
        return [jqUnaryNumeric(input) { Swift.abs($0) }]
    }

    if trimmed == "tostring" {
        return [jqToStringValue(input)]
    }

    if trimmed == "tonumber" {
        return [jqToNumberValue(input)]
    }

    if trimmed == "ascii_downcase" {
        return [jqAsciiTransform(input, uppercased: false)]
    }

    if trimmed == "ascii_upcase" {
        return [jqAsciiTransform(input, uppercased: true)]
    }

    if trimmed == "keys" {
        return [jqKeys(input)]
    }

    if trimmed == "add" {
        return [jqAdd(input)]
    }

    if trimmed == "to_entries" {
        return [jqToEntries(input)]
    }

    if trimmed == "from_entries" {
        return [jqFromEntries(input)]
    }

    if trimmed == "type" {
        return [jqType(input)]
    }

    if trimmed == "first" {
        return [jqFirst(input)]
    }

    if trimmed.hasPrefix("first("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        return [try evaluateJQFilter(inner, input: input, bindings: bindings).first ?? NSNull()]
    }

    if trimmed == "last" {
        return [jqLast(input)]
    }

    if trimmed.hasPrefix("last("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(5).dropLast())
        return [try evaluateJQFilter(inner, input: input, bindings: bindings).last ?? NSNull()]
    }

    if trimmed == "reverse" {
        return [jqReverse(input)]
    }

    if trimmed == "sort" {
        return [jqSort(input)]
    }

    if trimmed == "unique" {
        return [jqUnique(input)]
    }

    if trimmed == "min" {
        return [jqMin(input)]
    }

    if trimmed == "max" {
        return [jqMax(input)]
    }

    if trimmed == "flatten" {
        return [try jqFlatten(input, depth: nil)]
    }

    if trimmed.hasPrefix("flatten("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        let depth = try evaluateJQFilter(inner, input: input, bindings: bindings).first.flatMap(jqIntegerValue)
        return [try jqFlatten(input, depth: depth)]
    }

    if trimmed == "transpose" {
        return [jqTranspose(input)]
    }

    if trimmed.hasPrefix("split("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        let separator = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqSplit(input, separator: separator)]
    }

    if trimmed.hasPrefix("join("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(5).dropLast())
        let separator = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqJoin(input, separator: separator)]
    }

    if trimmed.hasPrefix("test("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(5).dropLast())
        let pattern = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqTest(input, pattern: pattern)]
    }

    if trimmed.hasPrefix("startswith("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(11).dropLast())
        let prefix = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqStartsWith(input, prefix: prefix)]
    }

    if trimmed.hasPrefix("endswith("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        let suffix = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqEndsWith(input, suffix: suffix)]
    }

    if trimmed.hasPrefix("ltrimstr("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        let prefix = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqTrimString(input, needle: prefix, fromStart: true)]
    }

    if trimmed.hasPrefix("rtrimstr("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        let suffix = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqTrimString(input, needle: suffix, fromStart: false)]
    }

    if trimmed.hasPrefix("min_by("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(7).dropLast())
        return [try jqExtremaBy(input, filter: inner, pickMax: false)]
    }

    if trimmed.hasPrefix("max_by("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(7).dropLast())
        return [try jqExtremaBy(input, filter: inner, pickMax: true)]
    }

    if trimmed.hasPrefix("sort_by("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        return [try jqSortBy(input, filter: inner)]
    }

    if trimmed.hasPrefix("group_by("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        return [try jqGroupBy(input, filter: inner)]
    }

    if trimmed.hasPrefix("unique_by("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(10).dropLast())
        return [try jqUniqueBy(input, filter: inner)]
    }

    if trimmed.hasPrefix("with_entries("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(13).dropLast())
        return [try jqWithEntries(input, filter: inner, bindings: bindings)]
    }

    if trimmed.hasPrefix("range("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        return try jqRange(inner, input: input, bindings: bindings)
    }

    if trimmed.hasPrefix("limit("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        return try jqLimit(inner, input: input, bindings: bindings)
    }

    if trimmed.hasPrefix("getpath("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        let pathValue = try evaluateJQFilter(inner, input: input, bindings: bindings).first ?? []
        guard let path = pathValue as? [Any] else { return [NSNull()] }
        return [jqGetPath(input, path: path)]
    }

    if trimmed.hasPrefix("setpath("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        let arguments = splitTopLevelJQ(inner, separator: ";") ?? []
        guard arguments.count == 2 else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid setpath arguments"])
        }
        let pathValue = try evaluateJQFilter(arguments[0], input: input, bindings: bindings).first ?? []
        guard let path = pathValue as? [Any] else { return [input] }
        let replacement = try evaluateJQFilter(arguments[1], input: input, bindings: bindings).first ?? NSNull()
        return [jqSetPath(input, path: path, replacement: replacement)]
    }

    if trimmed.hasPrefix("pow("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        let arguments = splitTopLevelJQ(inner, separator: ";") ?? []
        guard arguments.count == 2 else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid pow arguments"])
        }
        let lhs = try evaluateJQFilter(arguments[0], input: input, bindings: bindings).first ?? NSNull()
        let rhs = try evaluateJQFilter(arguments[1], input: input, bindings: bindings).first ?? NSNull()
        guard let base = jqNumericValue(lhs), let exponent = jqNumericValue(rhs) else { return [NSNull()] }
        return [NSNumber(value: Foundation.pow(base, exponent))]
    }

    if trimmed.hasPrefix("atan2("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        let arguments = splitTopLevelJQ(inner, separator: ";") ?? []
        guard arguments.count == 2 else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid atan2 arguments"])
        }
        let lhs = try evaluateJQFilter(arguments[0], input: input, bindings: bindings).first ?? NSNull()
        let rhs = try evaluateJQFilter(arguments[1], input: input, bindings: bindings).first ?? NSNull()
        guard let y = jqNumericValue(lhs), let x = jqNumericValue(rhs) else { return [NSNull()] }
        return [NSNumber(value: Foundation.atan2(y, x))]
    }

    if trimmed.hasPrefix("sub("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        let arguments = splitTopLevelJQ(inner, separator: ";") ?? []
        guard arguments.count == 2 else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid sub arguments"])
        }
        let pattern = try evaluateJQFilter(arguments[0], input: input, bindings: bindings).first as? String ?? ""
        let replacement = try evaluateJQFilter(arguments[1], input: input, bindings: bindings).first as? String ?? ""
        return [jqSubstitute(input, pattern: pattern, replacement: replacement, global: false)]
    }

    if trimmed.hasPrefix("gsub("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(5).dropLast())
        let arguments = splitTopLevelJQ(inner, separator: ";") ?? []
        guard arguments.count == 2 else {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid gsub arguments"])
        }
        let pattern = try evaluateJQFilter(arguments[0], input: input, bindings: bindings).first as? String ?? ""
        let replacement = try evaluateJQFilter(arguments[1], input: input, bindings: bindings).first as? String ?? ""
        return [jqSubstitute(input, pattern: pattern, replacement: replacement, global: true)]
    }

    if trimmed.hasPrefix("index("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(6).dropLast())
        let needle = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqIndex(input, needle: needle)]
    }

    if trimmed.hasPrefix("indices("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(8).dropLast())
        let needle = try evaluateJQFilter(inner, input: input, bindings: bindings).first as? String ?? ""
        return [jqIndices(input, needle: needle)]
    }

    if trimmed.hasPrefix("if "), trimmed.hasSuffix(" end") {
        return [try evaluateJQConditional(trimmed, input: input, bindings: bindings)]
    }

    if trimmed.hasPrefix("any("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [false] }
        return [try array.contains { try evaluateJQFilter(inner, input: $0, bindings: bindings).contains(where: jqTruthy) }]
    }

    if trimmed.hasPrefix("all("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [false] }
        return [try array.allSatisfy { try evaluateJQFilter(inner, input: $0, bindings: bindings).contains(where: jqTruthy) }]
    }

    if trimmed.hasPrefix("contains("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(9).dropLast())
        let rhs = try evaluateJQFilter(inner, input: input, bindings: bindings).first ?? NSNull()
        return [jqContains(input, rhs)]
    }

    if trimmed.hasPrefix("del("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespaces)
        return [try jqDel(input, pathExpr: inner)]
    }

    if trimmed.hasPrefix("path("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(5).dropLast()).trimmingCharacters(in: .whitespaces)
        return [jqPathExpr(inner)]
    }

    if let op = parseJQBinaryOperator(trimmed) {
        let lhsValues = try evaluateJQFilter(op.left, input: input, bindings: bindings)
        let rhsValues = try evaluateJQFilter(op.right, input: input, bindings: bindings)
        let lhs = lhsValues.first ?? NSNull()
        let rhs = rhsValues.first ?? NSNull()
        return [try evaluateJQBinary(lhs: lhs, rhs: rhs, op: op.op)]
    }

    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
        return [try evaluateJQObject(trimmed, input: input, bindings: bindings)]
    }

    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let collected = inner.isEmpty ? [] : try evaluateJQFilter(inner, input: input, bindings: bindings)
        return [collected]
    }

    if trimmed.hasPrefix("map("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast())
        guard let array = input as? [Any] else { return [NSNull()] }
        let mapped = try array.flatMap { try evaluateJQFilter(inner, input: $0, bindings: bindings) }
        return [mapped]
    }

    if trimmed.hasPrefix("select("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(7).dropLast())
        let predicateValues = try evaluateJQFilter(inner, input: input, bindings: bindings)
        if predicateValues.contains(where: jqTruthy) {
            return [input]
        }
        return []
    }

    if trimmed.hasPrefix("has("), trimmed.hasSuffix(")") {
        let inner = String(trimmed.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return [jqHas(input, argument: inner)]
    }

    if trimmed.hasPrefix(".") {
        return try evaluateJQPath(trimmed, input: input)
    }

    if trimmed.hasPrefix("$"), let bound = bindings[String(trimmed.dropFirst())] {
        return [bound]
    }

    if let literal = parseJQLiteral(trimmed) {
        return [literal]
    }

    throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported filter: \(trimmed)"])
}

private func parseJQBinding(_ text: String) -> (source: String, name: String, rest: String)? {
    guard let range = text.range(of: " as $") else { return nil }
    let source = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    let after = text[range.upperBound...]
    guard let pipeRange = after.range(of: " | ") else { return nil }
    let name = String(after[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    let rest = String(after[pipeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
    guard !source.isEmpty, !name.isEmpty, !rest.isEmpty else { return nil }
    return (source, name, rest)
}

private func evaluateJQObject(_ filter: String, input: Any, bindings: [String: Any]) throws -> OrderedJSONObject {
    let inner = String(filter.dropFirst().dropLast())
    let parts = splitTopLevelJQ(inner, separator: ",") ?? [inner]
    var entries: [(String, Any)] = []
    for part in parts {
        let trimmedPart = part.trimmingCharacters(in: .whitespaces)
        guard !trimmedPart.isEmpty else { continue }

        guard let colonIndex = topLevelJQColonIndex(trimmedPart) else {
            let normalizedKey = trimmedPart.replacingOccurrences(of: "\"", with: "")
            entries.append((normalizedKey, try evaluateJQFilter(".\(normalizedKey)", input: input, bindings: bindings).first ?? NSNull()))
            continue
        }
        let key = String(trimmedPart[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        var valueExpr = String(trimmedPart[trimmedPart.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        if valueExpr.hasPrefix("("), valueExpr.hasSuffix(")") {
            valueExpr = String(valueExpr.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let normalizedKey = key.replacingOccurrences(of: "\"", with: "")
        entries.append((normalizedKey, try evaluateJQFilter(valueExpr, input: input, bindings: bindings).first ?? NSNull()))
    }
    return OrderedJSONObject(entries: entries)
}

private func topLevelJQColonIndex(_ text: String) -> String.Index? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var index = text.startIndex
    while index < text.endIndex {
        let ch = text[index]
        if escaped {
            escaped = false
            index = text.index(after: index)
            continue
        }
        if ch == "\\" {
            escaped = true
            index = text.index(after: index)
            continue
        }
        if ch == "\"" {
            inString.toggle()
            index = text.index(after: index)
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            case ":" where depthParen == 0 && depthBracket == 0 && depthBrace == 0:
                return index
            default:
                break
            }
        }
        index = text.index(after: index)
    }
    return nil
}

func splitTopLevelJQ(_ text: String, separator: Character) -> [String]? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var current = ""
    var parts: [String] = []
    var sawSeparator = false

    for ch in text {
        if escaped {
            current.append(ch)
            escaped = false
            continue
        }
        if ch == "\\" {
            current.append(ch)
            escaped = true
            continue
        }
        if ch == "\"" {
            inString.toggle()
            current.append(ch)
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            if ch == separator, depthParen == 0, depthBracket == 0, depthBrace == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                sawSeparator = true
                continue
            }
        }
        current.append(ch)
    }

    guard sawSeparator else { return nil }
    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts
}

private func evaluateJQPath(_ filter: String, input: Any) throws -> [Any] {
    if filter == "." { return [input] }
    var currentValues: [Any] = [input]
    var index = filter.startIndex
    guard filter[index] == "." else { return [input] }
    index = filter.index(after: index)

    while index < filter.endIndex {
        if filter[index] == "[" {
            guard let closing = filter[index...].firstIndex(of: "]") else {
                throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad path"])
            }
            let content = String(filter[filter.index(after: index)..<closing])
            if content.isEmpty {
                currentValues = currentValues.flatMap(iterateJQValues)
            } else if content.contains(":") {
                currentValues = currentValues.map { jqSlice($0, spec: content) }
            } else if let number = Int(content) {
                currentValues = currentValues.map { jqArrayIndex($0, number) ?? NSNull() }
            } else if let key = parseJQLiteral(content) as? String {
                currentValues = currentValues.map { jqObjectLookup($0, key: key) }
            } else {
                currentValues = currentValues.map { _ in NSNull() }
            }
            index = filter.index(after: closing)
            if index < filter.endIndex, filter[index] == "." {
                index = filter.index(after: index)
            }
            continue
        }

        let originalIndex = index
        while index < filter.endIndex, filter[index].isWhitespace {
            index = filter.index(after: index)
        }
        if index != originalIndex, index < filter.endIndex, filter[index] != "\"" {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad path"])
        }

        if index < filter.endIndex, filter[index] == "\"" {
            let stringStart = index
            index = filter.index(after: index)
            var escaped = false
            while index < filter.endIndex {
                let ch = filter[index]
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    break
                }
                index = filter.index(after: index)
            }
            guard index < filter.endIndex else {
                throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad path"])
            }
            let keyToken = String(filter[stringStart...index])
            guard let key = parseJQLiteral(keyToken) as? String else {
                throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad path"])
            }
            currentValues = currentValues.map { jqObjectLookup($0, key: key) }
            index = filter.index(after: index)
            if index < filter.endIndex, filter[index] == "." {
                index = filter.index(after: index)
            }
            continue
        }

        let start = index
        while index < filter.endIndex, filter[index] != ".", filter[index] != "[" {
            index = filter.index(after: index)
        }
        let key = String(filter[start..<index])
        if !key.isEmpty {
            let normalizedKey = key.hasSuffix("?") ? String(key.dropLast()) : key
            currentValues = currentValues.map { jqObjectLookup($0, key: normalizedKey) }
        }
        if index < filter.endIndex, filter[index] == "." {
            index = filter.index(after: index)
        }
    }

    return currentValues
}

func jqObjectLookup(_ value: Any, key: String) -> Any {
    if let object = value as? OrderedJSONObject {
        return object.entries.first(where: { $0.0 == key })?.1 ?? NSNull()
    }
    if let object = value as? [String: Any] {
        return object[key] ?? NSNull()
    }
    if let object = value as? NSDictionary {
        return object.object(forKey: key) ?? NSNull()
    }
    return NSNull()
}

func iterateJQValues(_ value: Any) -> [Any] {
    if let array = value as? [Any] {
        return array
    }
    if let object = value as? OrderedJSONObject {
        return object.entries.map(\.1)
    }
    if let object = value as? [String: Any] {
        return object.keys.sorted().compactMap { object[$0] }
    }
    return [NSNull()]
}

func jqArrayIndex(_ value: Any, _ index: Int) -> Any? {
    guard let array = value as? [Any], !array.isEmpty else { return nil }
    let resolved = index >= 0 ? index : array.count + index
    guard resolved >= 0, resolved < array.count else { return nil }
    return array[resolved]
}

private func jqSlice(_ value: Any, spec: String) -> Any {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return NSNull() }
    let start = parts[0].isEmpty ? nil : Int(parts[0])
    let end = parts[1].isEmpty ? nil : Int(parts[1])

    if let array = value as? [Any] {
        let lower = resolvedJQIndex(start, count: array.count, defaultValue: 0)
        let upper = resolvedJQIndex(end, count: array.count, defaultValue: array.count)
        guard lower <= upper else { return [] }
        return Array(array[lower..<upper])
    }

    if let string = value as? String {
        let chars = Array(string)
        let lower = resolvedJQIndex(start, count: chars.count, defaultValue: 0)
        let upper = resolvedJQIndex(end, count: chars.count, defaultValue: chars.count)
        guard lower <= upper else { return "" }
        return String(chars[lower..<upper])
    }

    return NSNull()
}

private func resolvedJQIndex(_ value: Int?, count: Int, defaultValue: Int) -> Int {
    guard let value else { return defaultValue }
    let resolved = value >= 0 ? value : count + value
    return max(0, min(count, resolved))
}

private func jqHas(_ value: Any, argument: String) -> Bool {
    if let key = parseJQLiteral(argument) as? String {
        if let object = jqObjectDictionary(value) {
            return object[key] != nil
        }
    }
    if let array = value as? [Any], let index = Int(argument) {
        return index >= 0 && index < array.count
    }
    return false
}

func jqTruthy(_ value: Any) -> Bool {
    if value is NSNull { return false }
    if let bool = value as? Bool { return bool }
    return true
}

private func jqContains(_ lhs: Any, _ rhs: Any) -> Bool {
    if let lhsArray = lhs as? [Any], let rhsArray = rhs as? [Any] {
        return rhsArray.allSatisfy { rhsValue in lhsArray.contains(where: { jqEqual($0, rhsValue) }) }
    }
    if let lhsObject = jqObjectDictionary(lhs), let rhsObject = jqObjectDictionary(rhs) {
        return rhsObject.allSatisfy { key, rhsValue in
            guard let lhsValue = lhsObject[key] else { return false }
            return jqEqual(lhsValue, rhsValue)
        }
    }
    return jqEqual(lhs, rhs)
}

private func jqEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case (_ as NSNull, _ as NSNull):
        return true
    case let (l as NSNumber, r as NSNumber):
        return l == r
    case let (l as String, r as String):
        return l == r
    case let (l as [Any], r as [Any]):
        return l.count == r.count && zip(l, r).allSatisfy { jqEqual($0, $1) }
    case let (l as [String: Any], r as [String: Any]):
        return l.keys == r.keys && l.keys.allSatisfy { key in jqEqual(l[key] as Any, r[key] as Any) }
    default:
        if let l = jqObjectDictionary(lhs), let r = jqObjectDictionary(rhs) {
            return l.keys == r.keys && l.keys.allSatisfy { key in jqEqual(l[key] as Any, r[key] as Any) }
        }
        return false
    }
}

private func jqLength(_ value: Any) -> Any {
    if let array = value as? [Any] { return array.count }
    if let string = value as? String { return string.count }
    if let object = jqObjectDictionary(value) { return object.count }
    return 0
}

private func jqRecursiveDescent(_ value: Any) -> [Any] {
    var values: [Any] = [value]
    if let array = value as? [Any] {
        for child in array {
            values.append(contentsOf: jqRecursiveDescent(child))
        }
    } else if let object = value as? OrderedJSONObject {
        for (_, child) in object.entries {
            values.append(contentsOf: jqRecursiveDescent(child))
        }
    } else if let object = jqObjectDictionary(value) {
        for key in object.keys.sorted() {
            values.append(contentsOf: jqRecursiveDescent(object[key] as Any))
        }
    }
    return values
}

func jqFormatString(_ format: String, value: Any) -> Any {
    switch format {
    case "@base64":
        guard let string = value as? String else { return NSNull() }
        return Data(string.utf8).base64EncodedString()
    case "@base64d":
        guard let string = value as? String,
              let data = Data(base64Encoded: string) else { return NSNull() }
        return String(data: data, encoding: .utf8) ?? NSNull()
    case "@uri":
        guard let string = value as? String else { return NSNull() }
        return string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? string
    case "@csv":
        guard let array = value as? [Any] else { return NSNull() }
        return array.map(jqCSVField).joined(separator: ",")
    case "@tsv":
        guard let array = value as? [Any] else { return NSNull() }
        return array.map(jqTSVField).joined(separator: "\t")
    case "@json":
        return renderJQValue(value, compact: true, raw: false)
    case "@html":
        guard let string = value as? String else { return NSNull() }
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    case "@sh":
        guard let string = value as? String else { return NSNull() }
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    case "@text":
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        return String(describing: jqToStringValue(value))
    default:
        return NSNull()
    }
}

func jqCSVField(_ value: Any) -> String {
    let rendered = jqPlainTextValue(value)
    let needsQuotes = rendered.contains(",") || rendered.contains("\"") || rendered.contains("\n")
    let escaped = rendered.replacingOccurrences(of: "\"", with: "\"\"")
    return needsQuotes ? "\"\(escaped)\"" : escaped
}

func jqTSVField(_ value: Any) -> String {
    jqPlainTextValue(value)
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
}

func jqPlainTextValue(_ value: Any) -> String {
    if value is NSNull { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if floor(number.doubleValue) == number.doubleValue {
            return String(number.intValue)
        }
        return String(number.doubleValue)
    }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return String(double) }
    return renderJQValue(value, compact: true, raw: true)
}

private func jqIsNumber(_ value: Any) -> Bool {
    if let number = value as? NSNumber {
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }
    return value is Int || value is Double
}

private func jqKeys(_ value: Any) -> Any {
    if let object = jqObjectDictionary(value) {
        return object.keys.sorted()
    }
    return []
}

private func jqAdd(_ value: Any) -> Any {
    if let array = value as? [Any] {
        if array.allSatisfy({ ($0 as? NSNumber) != nil }) {
            return array.compactMap { ($0 as? NSNumber)?.doubleValue }.reduce(0.0, +)
        }
        if array.allSatisfy({ $0 is String }) {
            return array.compactMap { $0 as? String }.joined()
        }
    }
    return NSNull()
}

private func jqToEntries(_ value: Any) -> Any {
    guard let object = jqObjectDictionary(value) else { return [] }
    return object.keys.sorted().map { key in
        OrderedJSONObject(entries: [("key", key), ("value", object[key] as Any)])
    }
}

private func jqFromEntries(_ value: Any) -> Any {
    guard let array = value as? [Any] else { return OrderedJSONObject(entries: []) }
    var entries: [(String, Any)] = []
    for item in array {
        if let object = jqObjectDictionary(item),
           let key = object["key"] as? String {
            entries.append((key, object["value"] as Any))
        }
    }
    return OrderedJSONObject(entries: entries)
}

private func jqType(_ value: Any) -> Any {
    if value is NSNull { return "null" }
    if value is String { return "string" }
    if value is NSNumber {
        if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
            return "boolean"
        }
        return "number"
    }
    if value is [Any] { return "array" }
    if jqObjectDictionary(value) != nil { return "object" }
    return "unknown"
}

private func jqFirst(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return array.first ?? NSNull()
    }
    return NSNull()
}

private func jqLast(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return array.last ?? NSNull()
    }
    return NSNull()
}

private func jqReverse(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return Array(array.reversed())
    }
    return NSNull()
}

private func jqSort(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return array.sorted { jqSortableString($0) < jqSortableString($1) }
    }
    return NSNull()
}

private func jqUnique(_ value: Any) -> Any {
    if let array = value as? [Any] {
        var result: [Any] = []
        for item in array {
            if !result.contains(where: { jqEqual($0, item) }) {
                result.append(item)
            }
        }
        return result
    }
    return NSNull()
}

private func jqMin(_ value: Any) -> Any {
    if let array = value as? [Any], let min = array.min(by: { jqSortableString($0) < jqSortableString($1) }) {
        return min
    }
    return NSNull()
}

private func jqMax(_ value: Any) -> Any {
    if let array = value as? [Any], let max = array.max(by: { jqSortableString($0) < jqSortableString($1) }) {
        return max
    }
    return NSNull()
}

private func jqFlatten(_ value: Any, depth: Int?) throws -> Any {
    guard let array = value as? [Any] else { return NSNull() }
    if let depth, depth < 0 {
        throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "flatten depth must not be negative"])
    }
    return jqFlattenArray(array, depth: depth)
}

private func jqFlattenArray(_ array: [Any], depth: Int?) -> [Any] {
    guard depth != 0 else { return array }
    return array.flatMap { element in
        guard let nested = element as? [Any] else { return [element] }
        let nextDepth = depth.map { $0 - 1 }
        return jqFlattenArray(nested, depth: nextDepth)
    }
}

private func jqTranspose(_ value: Any) -> Any {
    guard let rows = value as? [Any] else { return NSNull() }
    let arrays = rows.map { ($0 as? [Any]) ?? [] }
    let maxWidth = arrays.map(\.count).max() ?? 0
    var result: [[Any]] = []
    for column in 0..<maxWidth {
        result.append(arrays.map { column < $0.count ? $0[column] : NSNull() })
    }
    return result
}

private func jqSplit(_ value: Any, separator: String) -> Any {
    guard let string = value as? String else { return [] }
    return string.components(separatedBy: separator)
}

private func jqJoin(_ value: Any, separator: String) -> Any {
    guard let array = value as? [Any] else { return NSNull() }
    return array.map {
        if $0 is NSNull { return "" }
        return ($0 as? String) ?? String(describing: $0)
    }.joined(separator: separator)
}

private func jqTest(_ value: Any, pattern: String) -> Any {
    guard let string = value as? String else { return false }
    return (try? NSRegularExpression(pattern: pattern).firstMatch(
        in: string,
        range: NSRange(string.startIndex..<string.endIndex, in: string)
    )) != nil
}

private func jqStartsWith(_ value: Any, prefix: String) -> Any {
    guard let string = value as? String else { return false }
    return string.hasPrefix(prefix)
}

private func jqEndsWith(_ value: Any, suffix: String) -> Any {
    guard let string = value as? String else { return false }
    return string.hasSuffix(suffix)
}

private func jqTrimString(_ value: Any, needle: String, fromStart: Bool) -> Any {
    guard let string = value as? String else { return NSNull() }
    if fromStart, string.hasPrefix(needle) {
        return String(string.dropFirst(needle.count))
    }
    if !fromStart, string.hasSuffix(needle) {
        return String(string.dropLast(needle.count))
    }
    return string
}

private func jqAsciiTransform(_ value: Any, uppercased: Bool) -> Any {
    guard let string = value as? String else { return NSNull() }
    return uppercased ? string.uppercased() : string.lowercased()
}

private func jqUnaryNumeric(_ value: Any, transform: (Double) -> Double) -> Any {
    guard let number = jqNumericValue(value) else { return NSNull() }
    return transform(number)
}

private func jqExtremaBy(_ value: Any, filter: String, pickMax: Bool) throws -> Any {
    guard let array = value as? [Any], !array.isEmpty else { return NSNull() }
    let decorated = try array.map { element -> (Any, String) in
        let key = try evaluateJQFilter(filter, input: element).first ?? NSNull()
        return (element, jqSortableString(key))
    }
    return pickMax
        ? decorated.max(by: { $0.1 < $1.1 })?.0 ?? NSNull()
        : decorated.min(by: { $0.1 < $1.1 })?.0 ?? NSNull()
}

private func jqSortBy(_ value: Any, filter: String) throws -> Any {
    guard let array = value as? [Any] else { return [] }
    return try array.sorted { lhs, rhs in
        let left = try evaluateJQFilter(filter, input: lhs).first ?? NSNull()
        let right = try evaluateJQFilter(filter, input: rhs).first ?? NSNull()
        return jqSortableString(left) < jqSortableString(right)
    }
}

private func jqGroupBy(_ value: Any, filter: String) throws -> Any {
    guard let sorted = try jqSortBy(value, filter: filter) as? [Any] else { return [] }
    var groups: [[Any]] = []
    for element in sorted {
        let key = try evaluateJQFilter(filter, input: element).first ?? NSNull()
        if let lastKey = groups.last.flatMap({ try? evaluateJQFilter(filter, input: $0.first ?? NSNull()).first ?? NSNull() }),
           jqEqual(lastKey, key) {
            groups[groups.count - 1].append(element)
        } else {
            groups.append([element])
        }
    }
    return groups
}

private func jqUniqueBy(_ value: Any, filter: String) throws -> Any {
    guard let sorted = try jqSortBy(value, filter: filter) as? [Any] else { return [] }
    var result: [Any] = []
    for element in sorted {
        let key = try evaluateJQFilter(filter, input: element).first ?? NSNull()
        if !result.contains(where: {
            let otherKey = try? evaluateJQFilter(filter, input: $0).first ?? NSNull()
            return otherKey.map { jqEqual($0, key) } ?? false
        }) {
            result.append(element)
        }
    }
    return result
}

private func jqWithEntries(_ value: Any, filter: String, bindings: [String: Any]) throws -> Any {
    let entries: [OrderedJSONObject]
    if let direct = jqToEntries(value) as? [OrderedJSONObject] {
        entries = direct
    } else if let array = jqToEntries(value) as? [Any] {
        entries = array.compactMap { $0 as? OrderedJSONObject }
    } else {
        entries = []
    }
    let transformed = try entries.map { entry -> OrderedJSONObject in
        let transformedValue = try evaluateJQFilter(filter, input: entry, bindings: bindings).first ?? entry
        if let object = transformedValue as? OrderedJSONObject {
            return object
        }
        return entry
    }
    return jqFromEntries(transformed)
}

private func jqRange(_ arguments: String, input: Any, bindings: [String: Any]) throws -> [Any] {
    let parts = splitTopLevelJQ(arguments, separator: ";") ?? [arguments]
    guard (1...3).contains(parts.count) else {
        throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid range arguments"])
    }

    let values = try parts.map { try evaluateJQFilter($0, input: input, bindings: bindings).first ?? NSNull() }
    let start: Int
    let end: Int
    let step: Int

    switch values.count {
    case 1:
        start = 0
        end = jqIntegerValue(values[0]) ?? 0
        step = 1
    case 2:
        start = jqIntegerValue(values[0]) ?? 0
        end = jqIntegerValue(values[1]) ?? 0
        step = 1
    default:
        start = jqIntegerValue(values[0]) ?? 0
        end = jqIntegerValue(values[1]) ?? 0
        step = jqIntegerValue(values[2]) ?? 0
    }

    guard step != 0 else { return [] }
    let maximumResults = 1_000_000
    var result: [Any] = []
    var current = start
    while (step > 0 && current < end) || (step < 0 && current > end) {
        result.append(current)
        if result.count > maximumResults {
            throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "range result limit exceeded"])
        }
        current += step
    }
    return result
}

private func jqLimit(_ arguments: String, input: Any, bindings: [String: Any]) throws -> [Any] {
    let parts = splitTopLevelJQ(arguments, separator: ";") ?? []
    guard parts.count == 2 else {
        throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid limit arguments"])
    }
    let countValue = try evaluateJQFilter(parts[0], input: input, bindings: bindings).first ?? 0
    let count = max(0, jqIntegerValue(countValue) ?? 0)
    guard count > 0 else { return [] }
    let values = try evaluateJQFilter(parts[1], input: input, bindings: bindings)
    return Array(values.prefix(count))
}

private func jqSubstitute(_ value: Any, pattern: String, replacement: String, global: Bool) -> Any {
    guard let string = value as? String,
          let regex = try? NSRegularExpression(pattern: pattern) else { return NSNull() }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    if global {
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
    }
    guard let match = regex.firstMatch(in: string, range: range) else { return string }
    return regex.stringByReplacingMatches(in: string, options: [], range: match.range, withTemplate: replacement)
}

private func jqIndex(_ value: Any, needle: String) -> Any {
    guard let string = value as? String,
          let range = string.range(of: needle) else { return NSNull() }
    return string.distance(from: string.startIndex, to: range.lowerBound)
}

private func jqIndices(_ value: Any, needle: String) -> Any {
    guard let string = value as? String, !needle.isEmpty else { return [] }
    var indices: [Int] = []
    var start = string.startIndex
    while let range = string[start...].range(of: needle) {
        indices.append(string.distance(from: string.startIndex, to: range.lowerBound))
        start = range.upperBound
    }
    return indices
}

private func jqGetPath(_ value: Any, path: [Any]) -> Any {
    guard let head = path.first else { return value }
    let tail = Array(path.dropFirst())

    if let key = head as? String {
        if let object = value as? OrderedJSONObject,
           let child = object.entries.first(where: { $0.0 == key })?.1 {
            return jqGetPath(child, path: tail)
        }
        if let object = jqObjectDictionary(value),
           let child = object[key] {
            return jqGetPath(child, path: tail)
        }
        return NSNull()
    }

    guard let index = jqPathIndex(head),
          let array = value as? [Any],
          index >= 0,
          index < array.count else {
        return NSNull()
    }
    return jqGetPath(array[index], path: tail)
}

private func jqSetPath(_ value: Any, path: [Any], replacement: Any) -> Any {
    guard let head = path.first else { return replacement }
    let tail = Array(path.dropFirst())

    if let key = head as? String {
        var entries = jqObjectEntries(value)
        if let existingIndex = entries.firstIndex(where: { $0.0 == key }) {
            entries[existingIndex].1 = jqSetPath(entries[existingIndex].1, path: tail, replacement: replacement)
        } else {
            let seed: Any = tail.first.flatMap(jqPathIndex) != nil ? [Any]() : OrderedJSONObject(entries: [])
            entries.append((key, jqSetPath(seed, path: tail, replacement: replacement)))
        }
        return OrderedJSONObject(entries: entries)
    }

    guard let index = jqPathIndex(head), index >= 0 else { return value }
    var array = (value as? [Any]) ?? []
    if index >= array.count {
        array.append(contentsOf: Array(repeating: NSNull(), count: index - array.count + 1))
    }
    array[index] = jqSetPath(array[index], path: tail, replacement: replacement)
    return array
}

private func jqSortableString(_ value: Any) -> String {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return String(number.doubleValue) }
    return String(describing: value)
}

func jqObjectEntries(_ value: Any) -> [(String, Any)] {
    if let object = value as? OrderedJSONObject {
        return object.entries
    }
    if let object = jqObjectDictionary(value) {
        return object.keys.sorted().map { ($0, object[$0] as Any) }
    }
    return []
}

func jqObjectDictionary(_ value: Any) -> [String: Any]? {
    if let value = value as? OrderedJSONObject {
        return Dictionary(uniqueKeysWithValues: value.entries)
    }
    if let value = value as? [String: Any] {
        return value
    }
    if let dict = value as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            guard let key = key as? String else { return nil }
            result[key] = value
        }
        return result
    }
    return nil
}

private func evaluateJQConditional(_ filter: String, input: Any, bindings: [String: Any]) throws -> Any {
    let patterns = [
        #"^if\s+(.+?)\s+then\s+(.+?)\s+elif\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+?)\s+end$"#,
        #"^if\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+?)\s+end$"#
    ]

    for pattern in patterns {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(filter.startIndex..<filter.endIndex, in: filter)
        guard let match = regex.firstMatch(in: filter, options: [], range: range) else { continue }
        let captures = (1..<match.numberOfRanges).compactMap { idx -> String? in
            guard let range = Range(match.range(at: idx), in: filter) else { return nil }
            return String(filter[range]).trimmingCharacters(in: .whitespaces)
        }

        let branches: [(String, String)]
        let elseExpr: String
        if captures.count == 5 {
            branches = [(captures[0], captures[1]), (captures[2], captures[3])]
            elseExpr = captures[4]
        } else if captures.count == 3 {
            branches = [(captures[0], captures[1])]
            elseExpr = captures[2]
        } else {
            break
        }

        for (condition, valueExpr) in branches {
            let conditionValue = try evaluateJQFilter(condition, input: input, bindings: bindings).first ?? NSNull()
            if jqTruthy(conditionValue) {
                return try evaluateJQFilter(valueExpr, input: input, bindings: bindings).first ?? NSNull()
            }
        }
        return try evaluateJQFilter(elseExpr, input: input, bindings: bindings).first ?? NSNull()
    }

    throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid conditional"])
}

private func splitTopLevelJQKeyword(_ text: String, keyword: String) -> (left: String, right: String)? {
    let parts = splitTopLevelJQKeywordAll(text, keyword: keyword)
    guard parts.count >= 2 else { return nil }
    return (parts[0], parts[1...].joined(separator: keyword).trimmingCharacters(in: .whitespaces))
}

private func splitTopLevelJQKeywordAll(_ text: String, keyword: String) -> [String] {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    var current = ""
    var parts: [String] = []
    let chars = Array(text)
    let keywordChars = Array(keyword)
    var index = 0

    while index < chars.count {
        let ch = chars[index]
        if escaped {
            current.append(ch)
            escaped = false
            index += 1
            continue
        }
        if ch == "\\" {
            current.append(ch)
            escaped = true
            index += 1
            continue
        }
        if ch == "\"" {
            inString.toggle()
            current.append(ch)
            index += 1
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            if depthParen == 0, depthBracket == 0, depthBrace == 0,
               index + keywordChars.count <= chars.count,
               Array(chars[index..<(index + keywordChars.count)]) == keywordChars {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index += keywordChars.count
                continue
            }
        }
        current.append(ch)
        index += 1
    }

    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts
}

private func parseJQBinaryOperator(_ text: String) -> (left: String, op: String, right: String)? {
    if let split = splitTopLevelJQKeyword(text, keyword: " and ") {
        return (split.left, "and", split.right)
    }
    if let split = splitTopLevelJQKeyword(text, keyword: " or ") {
        return (split.left, "or", split.right)
    }
    for op in ["//", "==", "!=", ">=", "<=", ">", "<", "%", "*", "/", "+", "-"] {
        if let split = splitTopLevelJQOperator(text, op: op) {
            return split
        }
    }
    return nil
}

private func splitTopLevelJQOperator(_ text: String, op: String) -> (left: String, op: String, right: String)? {
    var depthParen = 0
    var depthBracket = 0
    var depthBrace = 0
    var inString = false
    var escaped = false
    let chars = Array(text)
    var index = 0
    while index < chars.count {
        let ch = chars[index]
        if escaped {
            escaped = false
            index += 1
            continue
        }
        if ch == "\\" {
            escaped = true
            index += 1
            continue
        }
        if ch == "\"" {
            inString.toggle()
            index += 1
            continue
        }
        if !inString {
            switch ch {
            case "(":
                depthParen += 1
            case ")":
                depthParen -= 1
            case "[":
                depthBracket += 1
            case "]":
                depthBracket -= 1
            case "{":
                depthBrace += 1
            case "}":
                depthBrace -= 1
            default:
                break
            }
            let currentIndex = text.index(text.startIndex, offsetBy: index)
            if depthParen == 0, depthBracket == 0, depthBrace == 0,
               text[currentIndex...].hasPrefix(op) {
                let left = String(text[..<currentIndex]).trimmingCharacters(in: .whitespaces)
                let rightStart = text.index(currentIndex, offsetBy: op.count)
                let right = String(text[rightStart...]).trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { return nil }
                return (left, op, right)
            }
        }
        index += 1
    }
    return nil
}

private func evaluateJQBinary(lhs: Any, rhs: Any, op: String) throws -> Any {
    switch op {
    case "*":
        return jqDouble(lhs) * jqDouble(rhs)
    case "+":
        if let left = lhs as? String, let right = rhs as? String {
            return left + right
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left + right
        }
        if jqObjectDictionary(lhs) != nil, jqObjectDictionary(rhs) != nil {
            return jqMergeObjects(lhs, rhs)
        }
        return jqDouble(lhs) + jqDouble(rhs)
    case "-":
        return jqDouble(lhs) - jqDouble(rhs)
    case "/":
        return jqDouble(lhs) / jqDouble(rhs)
    case "%":
        return jqDouble(lhs).truncatingRemainder(dividingBy: jqDouble(rhs))
    case ">":
        return jqDouble(lhs) > jqDouble(rhs)
    case "<":
        return jqDouble(lhs) < jqDouble(rhs)
    case ">=":
        return jqDouble(lhs) >= jqDouble(rhs)
    case "<=":
        return jqDouble(lhs) <= jqDouble(rhs)
    case "==":
        return jqEqual(lhs, rhs)
    case "!=":
        return !jqEqual(lhs, rhs)
    case "and":
        return jqTruthy(lhs) && jqTruthy(rhs)
    case "or":
        return jqTruthy(lhs) || jqTruthy(rhs)
    case "//":
        return jqTruthy(lhs) ? lhs : rhs
    default:
        throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported operator: \(op)"])
    }
}

private func jqDouble(_ value: Any) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let int = value as? Int { return Double(int) }
    if let double = value as? Double { return double }
    return 0
}

private func jqNumericValue(_ value: Any) -> Double? {
    guard jqIsNumber(value) else { return nil }
    return jqDouble(value)
}

func jqToStringValue(_ value: Any) -> Any {
    if let string = value as? String { return string }
    return renderJQValue(value, compact: true, raw: false)
}

private func jqToNumberValue(_ value: Any) -> Any {
    if jqIsNumber(value) { return value }
    guard let string = value as? String else { return NSNull() }
    if let int = Int(string) { return int }
    if let double = Double(string) { return double }
    return NSNull()
}

private func jqIntegerValue(_ value: Any) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        let double = number.doubleValue
        return floor(double) == double ? Int(double) : nil
    }
    if let double = value as? Double, floor(double) == double {
        return Int(double)
    }
    return nil
}

private func jqPathIndex(_ value: Any) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return Int(truncating: number)
    }
    return nil
}

private func jqMergeObjects(_ lhs: Any, _ rhs: Any) -> Any {
    var entries = jqObjectEntries(lhs)
    for (key, value) in jqObjectEntries(rhs) {
        if let existingIndex = entries.firstIndex(where: { $0.0 == key }) {
            entries[existingIndex].1 = value
        } else {
            entries.append((key, value))
        }
    }
    return OrderedJSONObject(entries: entries)
}

func parseJQLiteral(_ text: String) -> Any? {
    if text == "null" { return NSNull() }
    if text == "true" { return true }
    if text == "false" { return false }
    if let int = Int(text) { return int }
    if let double = Double(text) { return double }
    if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
        if let data = text.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) {
            return value
        }
    }
    if text.hasPrefix("\""), text.hasSuffix("\"") {
        return String(text.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
    return nil
}

func renderJQValue(_ value: Any, compact: Bool, raw: Bool) -> String {
    if raw, let string = value as? String {
        return string
    }
    if value is NSNull { return "null" }
    if let array = value as? [OrderedJSONObject] {
        if compact {
            return "[" + array.map { renderJQValue($0, compact: true, raw: false) }.joined(separator: ",") + "]"
        }
        let rendered = array.map { "  " + renderJQValue($0, compact: false, raw: false).replacingOccurrences(of: "\n", with: "\n  ") }
        return "[\n" + rendered.joined(separator: ",\n") + "\n]"
    }
    if let object = value as? OrderedJSONObject {
        if compact {
            let rendered = object.entries.map { key, value in
                "\"\(escapeJSONString(key))\":" + renderJQValue(value, compact: true, raw: false)
            }.joined(separator: ",")
            return "{\(rendered)}"
        }
        let rendered = object.entries.map { key, value in
            "  \"\(escapeJSONString(key))\": " + renderJQValue(value, compact: false, raw: false)
        }.joined(separator: ",\n")
        return "{\n\(rendered)\n}"
    }
    if let string = value as? String { return "\"\(escapeJSONString(string))\"" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if floor(number.doubleValue) == number.doubleValue {
            return String(number.intValue)
        }
        return String(number.doubleValue)
    }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return String(double) }
    if JSONSerialization.isValidJSONObject(value) {
        let options: JSONSerialization.WritingOptions = compact ? [] : [.prettyPrinted]
        let data = try? JSONSerialization.data(withJSONObject: value, options: options)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
    return String(describing: value)
}

private func jqRecurseWith(_ value: Any, filter: String, bindings: [String: Any]) throws -> [Any] {
    var results: [Any] = [value]
    var current = [value]
    let limit = 1_000_000
    while !current.isEmpty {
        var next: [Any] = []
        for item in current {
            let produced = try evaluateJQFilter(filter, input: item, bindings: bindings)
            for v in produced {
                if v is NSNull { continue }
                next.append(v)
            }
        }
        if results.count + next.count > limit { break }
        results.append(contentsOf: next)
        current = next
    }
    return results
}

private func jqAllPaths(_ value: Any) -> [Any] {
    var result: [Any] = []
    jqCollectPaths(value, prefix: [], into: &result, leafOnly: false)
    return result
}

private func jqLeafPaths(_ value: Any) -> [Any] {
    var result: [Any] = []
    jqCollectPaths(value, prefix: [], into: &result, leafOnly: true)
    return result
}

private func jqCollectPaths(_ value: Any, prefix: [Any], into result: inout [Any], leafOnly: Bool) {
    if let array = value as? [Any] {
        if !leafOnly { result.append(prefix) }
        for (index, child) in array.enumerated() {
            jqCollectPaths(child, prefix: prefix + [index], into: &result, leafOnly: leafOnly)
        }
    } else if let object = value as? OrderedJSONObject {
        if !leafOnly { result.append(prefix) }
        for (key, child) in object.entries {
            jqCollectPaths(child, prefix: prefix + [key], into: &result, leafOnly: leafOnly)
        }
    } else if let dict = jqObjectDictionary(value) {
        if !leafOnly { result.append(prefix) }
        for key in dict.keys.sorted() {
            jqCollectPaths(dict[key] as Any, prefix: prefix + [key], into: &result, leafOnly: leafOnly)
        }
    } else {
        result.append(prefix)
    }
}

private func jqDel(_ value: Any, pathExpr: String) throws -> Any {
    if pathExpr.hasPrefix(".[") && pathExpr.hasSuffix("]") {
        let indexStr = String(pathExpr.dropFirst(2).dropLast())
        if let index = Int(indexStr), var array = value as? [Any] {
            let resolved = index >= 0 ? index : array.count + index
            guard resolved >= 0, resolved < array.count else { return value }
            array.remove(at: resolved)
            return array
        }
    }

    if pathExpr.hasPrefix(".") {
        let keyPath = String(pathExpr.dropFirst())
        let parts = keyPath.split(separator: ".").map(String.init)
        return jqDelKeyPath(value, keys: parts)
    }

    throw NSError(domain: "jq", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported del expression: \(pathExpr)"])
}

private func jqDelKeyPath(_ value: Any, keys: [String]) -> Any {
    guard let firstKey = keys.first else { return value }

    if keys.count == 1 {
        var entries = jqObjectEntries(value)
        entries.removeAll { $0.0 == firstKey }
        return OrderedJSONObject(entries: entries)
    }

    var entries = jqObjectEntries(value)
    if let idx = entries.firstIndex(where: { $0.0 == firstKey }) {
        entries[idx].1 = jqDelKeyPath(entries[idx].1, keys: Array(keys.dropFirst()))
    }
    return OrderedJSONObject(entries: entries)
}

private func jqPathExpr(_ expr: String) -> Any {
    guard expr.hasPrefix(".") else { return [expr] }
    let keyPath = String(expr.dropFirst())
    if keyPath.isEmpty { return [Any]() }
    return keyPath.split(separator: ".").map { String($0) as Any }
}
