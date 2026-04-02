import Foundation

// MARK: - CSV Cell

public enum CSVCell: Sendable, Equatable {
    case string(String)
    case null
    
    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .null: return ""
        }
    }
    
    public var isEmpty: Bool {
        switch self {
        case .string(let s): return s.isEmpty
        case .null: return true
        }
    }
}

// MARK: - CSV Row

public struct CSVRow: Sendable {
    public let cells: [CSVCell]
    private let headerIndices: [String: Int]
    
    public init(cells: [CSVCell], headers: [String] = []) {
        self.cells = cells
        var indices: [String: Int] = [:]
        for (index, header) in headers.enumerated() {
            if indices[header] == nil {
                indices[header] = index
            }
        }
        self.headerIndices = indices
    }
    
    /// Access cell by column index (1-based like cut/sort -k)
    public func cell(at index: Int) -> CSVCell {
        let zeroBased = index > 0 ? index - 1 : cells.count + index
        guard zeroBased >= 0, zeroBased < cells.count else { return .null }
        return cells[zeroBased]
    }
    
    /// Access cell by column name
    public func cell(named name: String) -> CSVCell {
        guard let index = headerIndices[name] else { return .null }
        return cells[index]
    }
    
    /// Check if row has a column with given name
    public func hasColumn(_ name: String) -> Bool {
        headerIndices[name] != nil
    }
    
    public var count: Int { cells.count }
    
    /// Get all values as strings
    public var values: [String] {
        cells.map { $0.stringValue }
    }
}

// MARK: - CSV Document

public struct CSVDocument: Sendable {
    public let headers: [String]
    public let rows: [CSVRow]
    
    public init(headers: [String] = [], rows: [CSVRow] = []) {
        self.headers = headers
        self.rows = rows
    }
    
    public var rowCount: Int { rows.count }
    public var columnCount: Int { headers.count }
    
    /// Get row at index (0-based)
    public func row(at index: Int) -> CSVRow? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }
    
    /// Create a new document with filtered rows
    public func filtered(_ predicate: (CSVRow) -> Bool) -> CSVDocument {
        CSVDocument(headers: headers, rows: rows.filter(predicate))
    }
    
    /// Create a new document with selected columns
    public func select(columns: [String]) -> CSVDocument {
        let indices = columns.compactMap { headers.firstIndex(of: $0) }
        let newHeaders = indices.map { headers[$0] }
        let newRows = rows.map { row in
            let newCells = indices.map { row.cells[$0] }
            return CSVRow(cells: newCells, headers: newHeaders)
        }
        return CSVDocument(headers: newHeaders, rows: newRows)
    }
    
    /// Create a new document with reordered/repeated columns by index
    public func select(indices: [Int]) -> CSVDocument {
        let newHeaders = indices.map { idx -> String in
            let zeroBased = idx > 0 ? idx - 1 : headers.count + idx
            if zeroBased >= 0, zeroBased < headers.count {
                return headers[zeroBased]
            }
            return ""
        }
        let newRows = rows.map { row in
            let newCells = indices.map { row.cell(at: $0) }
            return CSVRow(cells: newCells, headers: newHeaders)
        }
        return CSVDocument(headers: newHeaders, rows: newRows)
    }
}

// MARK: - CSV Config

public struct CSVConfig: Sendable {
    public var delimiter: Character
    public var quote: Character
    public var escape: Character
    public var hasHeader: Bool
    public var terminator: String
    
    public init(
        delimiter: Character = ",",
        quote: Character = "\"",
        escape: Character? = nil,
        hasHeader: Bool = true,
        terminator: String = "\n"
    ) {
        self.delimiter = delimiter
        self.quote = quote
        self.escape = escape ?? quote
        self.hasHeader = hasHeader
        self.terminator = terminator
    }
    
    /// Standard CSV (RFC 4180)
    public static let standard = CSVConfig()
    
    /// TSV configuration
    public static let tsv = CSVConfig(delimiter: "\t")
    
    /// No header row
    public static func noHeader(delimiter: Character = ",") -> CSVConfig {
        CSVConfig(delimiter: delimiter, hasHeader: false)
    }
}
