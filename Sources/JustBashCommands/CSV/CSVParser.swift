import Foundation

public struct CSVParser: Sendable {
    private let config: CSVConfig
    
    public init(config: CSVConfig = .standard) {
        self.config = config
    }
    
    /// Parse complete document from string
    public func parse(_ text: String) -> CSVDocument {
        var lines = text.components(separatedBy: config.terminator)
        
        // Handle trailing empty line
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        
        // Handle Windows line endings if terminator is just \n
        if config.terminator == "\n" {
            lines = lines.flatMap { line -> [String] in
                if line.contains("\r") {
                    return line.components(separatedBy: "\r")
                }
                return [line]
            }
        }
        
        // Remove empty lines at the end
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        
        guard !lines.isEmpty else {
            return CSVDocument()
        }
        
        if config.hasHeader {
            let headers = parseRow(lines[0]).map { $0.stringValue }
            let rows = lines.dropFirst().map { CSVRow(cells: parseRow($0), headers: headers) }
            return CSVDocument(headers: headers, rows: rows)
        } else {
            let rows = lines.map { CSVRow(cells: parseRow($0), headers: []) }
            return CSVDocument(headers: [], rows: rows)
        }
    }
    
    /// Parse a single row into cells
    public func parseRow(_ line: String) -> [CSVCell] {
        var cells: [CSVCell] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        
        while index < line.endIndex {
            let char = line[index]
            
            if char == config.quote {
                // Check for escaped quote (double quote)
                let nextIndex = line.index(after: index)
                if inQuotes && nextIndex < line.endIndex && line[nextIndex] == config.quote {
                    current.append(config.quote)
                    index = line.index(after: nextIndex)
                } else {
                    inQuotes.toggle()
                    index = nextIndex
                }
            } else if char == config.delimiter && !inQuotes {
                cells.append(current.isEmpty ? .null : .string(current))
                current = ""
                index = line.index(after: index)
            } else {
                current.append(char)
                index = line.index(after: index)
            }
        }
        
        // Don't forget the last field
        cells.append(current.isEmpty ? .null : .string(current))
        
        return cells
    }
    
    /// Streaming parser - yields rows one at a time
    /// Use this for memory-efficient processing of large files
    public func parseStreaming(
        _ text: String,
        onRow: (CSVRow, Int) -> Bool  // Return false to stop parsing
    ) -> CSVDocument? {
        var lines = text.components(separatedBy: config.terminator)
        if lines.last?.isEmpty == true { lines.removeLast() }
        
        // Handle Windows line endings
        if config.terminator == "\n" {
            lines = lines.flatMap { line -> [String] in
                if line.contains("\r") { return line.components(separatedBy: "\r") }
                return [line]
            }
        }
        
        // Remove empty lines
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        
        guard !lines.isEmpty else { return nil }
        
        var headers: [String] = []
        var rows: [CSVRow] = []
        var startIndex = 0
        
        if config.hasHeader {
            headers = parseRow(lines[0]).map { $0.stringValue }
            startIndex = 1
        }
        
        for i in startIndex..<lines.count {
            let row = CSVRow(cells: parseRow(lines[i]), headers: headers)
            if !onRow(row, rows.count) {
                return CSVDocument(headers: headers, rows: rows)
            }
            rows.append(row)
        }
        
        return CSVDocument(headers: headers, rows: rows)
    }
}
