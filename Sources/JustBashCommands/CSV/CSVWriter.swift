import Foundation

public struct CSVWriter: Sendable {
    private let config: CSVConfig
    
    public init(config: CSVConfig = .standard) {
        self.config = config
    }
    
    /// Write a complete document to string
    public func write(_ document: CSVDocument) -> String {
        var lines: [String] = []
        
        if config.hasHeader && !document.headers.isEmpty {
            lines.append(writeRow(document.headers))
        }
        
        for row in document.rows {
            lines.append(writeRow(row.values))
        }
        
        return lines.joined(separator: config.terminator) + (lines.isEmpty ? "" : config.terminator)
    }
    
    /// Write a single row
    public func writeRow(_ values: [String]) -> String {
        values.map { escape($0) }.joined(separator: String(config.delimiter))
    }
    
    /// Write a single cell
    public func escape(_ value: String) -> String {
        let needsQuotes = value.contains(config.delimiter) ||
                         value.contains(config.quote) ||
                         value.contains("\n") ||
                         value.contains("\r") ||
                         value.hasPrefix(" ") ||
                         value.hasSuffix(" ")
        
        if !needsQuotes {
            return value
        }
        
        let escaped = value.replacingOccurrences(
            of: String(config.quote),
            with: String(config.quote) + String(config.quote)
        )
        return String(config.quote) + escaped + String(config.quote)
    }
    
    /// Write document as formatted table (for `xan view`)
    public func writeTable(_ document: CSVDocument, maxWidth: Int = 30) -> String {
        let allRows = document.rows.map { $0.values }
        let headers = config.hasHeader ? document.headers : []
        
        // Calculate column widths
        let columnCount = max(headers.count, allRows.map { $0.count }.max() ?? 0)
        var widths = Array(repeating: 0, count: columnCount)
        
        for (i, header) in headers.enumerated() {
            widths[i] = max(widths[i], min(header.count, maxWidth))
        }
        
        for row in allRows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], min(cell.count, maxWidth))
            }
        }
        
        // Build output
        var lines: [String] = []
        
        // Header row
        if !headers.isEmpty {
            let headerLine = headers.enumerated().map { (i, h) in
                let display = h.count > maxWidth ? String(h.prefix(maxWidth - 3)) + "..." : h
                return display.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
            }.joined()
            lines.append(headerLine)
            lines.append(String(repeating: "-", count: headerLine.count))
        }
        
        // Data rows
        for row in allRows {
            let line = row.enumerated().map { (i, cell) -> String in
                guard i < columnCount else { return "" }
                let display = cell.count > maxWidth ? String(cell.prefix(maxWidth - 3)) + "..." : cell
                return display.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
            }.joined()
            lines.append(line)
        }
        
        return lines.joined(separator: "\n") + "\n"
    }
}
