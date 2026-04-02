import Foundation
import JustBashFS

// MARK: - Main Xan Command

func xan() -> AnyBashCommand {
    AnyBashCommand(name: "xan") { args, ctx in
        var remaining = args
        var delimiter: Character = ","
        var noHeader = false
        
        // Parse global options
        while !remaining.isEmpty {
            let arg = remaining[0]
            if !arg.hasPrefix("-") || arg == "-" { break }
            if arg == "--" { remaining.removeFirst(); break }
            remaining.removeFirst()
            
            switch arg {
            case "-d", "--delimiter":
                if let d = remaining.first, let firstChar = d.first {
                    delimiter = firstChar
                    remaining.removeFirst()
                }
            case "--no-header":
                noHeader = true
            case "-t", "--tsv":
                delimiter = "\t"
            default:
                if arg.hasPrefix("-d") && arg.count > 2 {
                    delimiter = arg.dropFirst(2).first ?? ","
                }
            }
        }
        
        let config = CSVConfig(
            delimiter: delimiter,
            hasHeader: !noHeader
        )
        
        guard !remaining.isEmpty else {
            return ExecResult.failure("xan: missing subcommand. Try: view, count, headers, select, head, tail, filter, sort, freq, stats, help")
        }
        
        let subcommand = remaining[0]
        let subArgs = Array(remaining.dropFirst())
        
        switch subcommand {
        case "view", "table", "tbl":
            return await xanView(args: subArgs, ctx: ctx, config: config)
        case "count", "cnt":
            return await xanCount(args: subArgs, ctx: ctx, config: config)
        case "headers", "hdr":
            return await xanHeaders(args: subArgs, ctx: ctx, config: config)
        case "select", "sel":
            return await xanSelect(args: subArgs, ctx: ctx, config: config)
        case "head":
            return await xanHead(args: subArgs, ctx: ctx, config: config)
        case "tail":
            return await xanTail(args: subArgs, ctx: ctx, config: config)
        case "filter", "where":
            return await xanFilter(args: subArgs, ctx: ctx, config: config)
        case "sort":
            return await xanSort(args: subArgs, ctx: ctx, config: config)
        case "freq", "frequency", "top":
            return await xanFrequency(args: subArgs, ctx: ctx, config: config)
        case "stats":
            return await xanStats(args: subArgs, ctx: ctx, config: config)
        case "help", "--help", "-h":
            return ExecResult.success(xanHelp())
        default:
            return ExecResult.failure("xan: unknown subcommand '\(subcommand)'. Try 'xan help'")
        }
    }
}

// MARK: - Help

private func xanHelp() -> String {
    """
    xan - CSV processing tool

    Usage: xan [OPTIONS] <SUBCOMMAND> [ARGS]

    Options:
      -d, --delimiter <char>   Field delimiter (default: ,)
      -t, --tsv                Use TAB delimiter
      --no-header              No header row

    Subcommands:
      view [FILE]              Display CSV as formatted table
      count [FILE]             Count rows (excluding header)
      headers [FILE]           Show column names with indices
      select COLS [FILE]       Select columns (e.g., 1,3,5 or name,age,city)
      head [N] [FILE]          Show first N rows (default: 10)
      tail [N] [FILE]          Show last N rows (default: 10)
      filter EXPR [FILE]       Filter rows by expression (e.g., 'age > 30')
      sort [COL] [FILE]        Sort by column (numeric if possible)
      freq COL [FILE]          Show frequency table for column
      stats COL [FILE]         Show statistics for numeric column

    Examples:
      xan view data.csv
      xan -t view data.tsv
      xan select 1,3,5 data.csv
      xan select name,age data.csv
      xan filter 'age > 30' data.csv
      xan sort 2 data.csv
      xan head 20 data.csv
    """
}

// MARK: - Utility Functions

private func getCSVInput(args: [String], ctx: CommandContext) throws -> String {
    let files = args.filter { !$0.hasPrefix("-") && Int($0) == nil }
    
    if files.isEmpty {
        return ctx.stdin
    }
    
    let path = files.last!
    return try ctx.fileSystem.readFile(path, relativeTo: ctx.cwd)
}

// MARK: - Subcommand: view

private func xanView(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    do {
        let content = try getCSVInput(args: args, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        let writer = CSVWriter(config: config)
        let output = writer.writeTable(document)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan view: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: count

private func xanCount(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    do {
        let content = try getCSVInput(args: args, ctx: ctx)
        
        var count = 0
        let parser = CSVParser(config: config)
        _ = parser.parseStreaming(content) { _, _ in
            count += 1
            return true
        }
        
        return ExecResult.success("\(count)\n")
    } catch {
        return ExecResult.failure("xan count: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: headers

private func xanHeaders(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    do {
        let content = try getCSVInput(args: args, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        var output: [String] = []
        for (index, header) in document.headers.enumerated() {
            output.append("\(index + 1):\t\(header)")
        }
        
        return ExecResult.success(output.joined(separator: "\n") + "\n")
    } catch {
        return ExecResult.failure("xan headers: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: select

private func xanSelect(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    guard !args.isEmpty else {
        return ExecResult.failure("xan select: missing column specification")
    }
    
    do {
        let columnSpec = args[0]
        let fileArgs = Array(args.dropFirst())
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        let indices = parseColumnSelection(columnSpec, headers: document.headers)
        let selected = document.select(indices: indices)
        
        let writer = CSVWriter(config: config)
        let output = writer.write(selected)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan select: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: head

private func xanHead(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    var count = 10
    var fileArgs: [String] = []
    
    if let first = args.first, let n = Int(first) {
        count = n
        fileArgs = Array(args.dropFirst())
    } else {
        fileArgs = args
    }
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        var document = parser.parse(content)
        
        let headRows = Array(document.rows.prefix(count))
        document = CSVDocument(headers: document.headers, rows: headRows)
        
        let writer = CSVWriter(config: config)
        let output = writer.write(document)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan head: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: tail

private func xanTail(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    var count = 10
    var fileArgs: [String] = []
    
    if let first = args.first, let n = Int(first) {
        count = n
        fileArgs = Array(args.dropFirst())
    } else {
        fileArgs = args
    }
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        var document = parser.parse(content)
        
        let tailRows = Array(document.rows.suffix(count))
        document = CSVDocument(headers: document.headers, rows: tailRows)
        
        let writer = CSVWriter(config: config)
        let output = writer.write(document)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan tail: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: filter

private func xanFilter(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    guard !args.isEmpty else {
        return ExecResult.failure("xan filter: missing expression")
    }
    
    let expression = args[0]
    let fileArgs = Array(args.dropFirst())
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        let engine = CSVExpressionEngine(headers: document.headers)
        let filtered = document.filtered { row in
            engine.evaluate(expression, row: row)
        }
        
        let writer = CSVWriter(config: config)
        let output = writer.write(filtered)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan filter: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: sort

private func xanSort(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    var sortColumn: String = "1"  // Default to first column
    var fileArgs: [String] = []
    
    // Parse arguments
    if let first = args.first {
        if Int(first) != nil || !first.hasPrefix("-") {
            sortColumn = first
            fileArgs = Array(args.dropFirst())
        } else {
            fileArgs = args
        }
    }
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        let sortedRows: [CSVRow]
        
        // Determine if we should sort numerically
        let shouldSortNumerically = document.rows.allSatisfy { row in
            let value: String
            if let colIndex = Int(sortColumn) {
                value = row.cell(at: colIndex).stringValue
            } else {
                value = row.cell(named: sortColumn).stringValue
            }
            return value.isEmpty || Double(value) != nil
        }
        
        if shouldSortNumerically {
            sortedRows = document.rows.sorted { a, b in
                let valA: String
                let valB: String
                if let colIndex = Int(sortColumn) {
                    valA = a.cell(at: colIndex).stringValue
                    valB = b.cell(at: colIndex).stringValue
                } else {
                    valA = a.cell(named: sortColumn).stringValue
                    valB = b.cell(named: sortColumn).stringValue
                }
                let numA = Double(valA) ?? 0
                let numB = Double(valB) ?? 0
                return numA < numB
            }
        } else {
            sortedRows = document.rows.sorted { a, b in
                let valA: String
                let valB: String
                if let colIndex = Int(sortColumn) {
                    valA = a.cell(at: colIndex).stringValue
                    valB = b.cell(at: colIndex).stringValue
                } else {
                    valA = a.cell(named: sortColumn).stringValue
                    valB = b.cell(named: sortColumn).stringValue
                }
                return valA < valB
            }
        }
        
        let sortedDoc = CSVDocument(headers: document.headers, rows: sortedRows)
        let writer = CSVWriter(config: config)
        let output = writer.write(sortedDoc)
        
        return ExecResult.success(output)
    } catch {
        return ExecResult.failure("xan sort: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: frequency

private func xanFrequency(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    guard !args.isEmpty else {
        return ExecResult.failure("xan freq: missing column specification")
    }
    
    let columnSpec = args[0]
    let fileArgs = Array(args.dropFirst())
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        // Get column index
        let colIndex: Int
        if let num = Int(columnSpec) {
            colIndex = num
        } else if let index = document.headers.firstIndex(of: columnSpec) {
            colIndex = index + 1  // Convert to 1-based
        } else {
            return ExecResult.failure("xan freq: unknown column '\(columnSpec)'")
        }
        
        // Count frequencies
        var frequencies: [String: Int] = [:]
        for row in document.rows {
            let value = row.cell(at: colIndex).stringValue
            frequencies[value, default: 0] += 1
        }
        
        // Sort by frequency (descending), then by value
        let sorted = frequencies.sorted { a, b in
            if a.value != b.value {
                return a.value > b.value
            }
            return a.key < b.key
        }
        
        // Output
        var lines: [String] = []
        lines.append("value\tcount")
        for (value, count) in sorted {
            lines.append("\(value)\t\(count)")
        }
        
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    } catch {
        return ExecResult.failure("xan freq: \(error.localizedDescription)")
    }
}

// MARK: - Subcommand: stats

private func xanStats(args: [String], ctx: CommandContext, config: CSVConfig) async -> ExecResult {
    guard !args.isEmpty else {
        return ExecResult.failure("xan stats: missing column specification")
    }
    
    let columnSpec = args[0]
    let fileArgs = Array(args.dropFirst())
    
    do {
        let content = try getCSVInput(args: fileArgs, ctx: ctx)
        let parser = CSVParser(config: config)
        let document = parser.parse(content)
        
        // Get column index
        let colIndex: Int
        if let num = Int(columnSpec) {
            colIndex = num
        } else if let index = document.headers.firstIndex(of: columnSpec) {
            colIndex = index + 1
        } else {
            return ExecResult.failure("xan stats: unknown column '\(columnSpec)'")
        }
        
        // Collect numeric values
        var values: [Double] = []
        for row in document.rows {
            let valStr = row.cell(at: colIndex).stringValue
            if let val = Double(valStr) {
                values.append(val)
            }
        }
        
        guard !values.isEmpty else {
            return ExecResult.failure("xan stats: no numeric values in column '\(columnSpec)'")
        }
        
        // Calculate statistics
        let count = values.count
        let min = values.min() ?? 0
        let max = values.max() ?? 0
        let sum = values.reduce(0, +)
        let mean = sum / Double(count)
        
        // Standard deviation
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(count)
        let stdDev = sqrt(variance)
        
        // Median
        let sorted = values.sorted()
        let median: Double
        if count % 2 == 0 {
            median = (sorted[count/2 - 1] + sorted[count/2]) / 2
        } else {
            median = sorted[count/2]
        }
        
        let headerName = colIndex <= document.headers.count ? document.headers[colIndex - 1] : columnSpec
        
        let output = """
        Statistics for column '\(headerName)':
        
        count:    \(count)
        min:      \(min)
        max:      \(max)
        sum:      \(sum)
        mean:     \(mean)
        median:   \(median)
        stddev:   \(stdDev)
        """
        
        return ExecResult.success(output + "\n")
    } catch {
        return ExecResult.failure("xan stats: \(error.localizedDescription)")
    }
}
