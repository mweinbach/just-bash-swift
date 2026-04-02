import Foundation

// MARK: - Column Selection

/// Parse column selection string (e.g., "1,3,5" or "name,age,city")
public func parseColumnSelection(_ spec: String, headers: [String]) -> [Int] {
    let parts = spec.split(separator: ",").map(String.init)
    var indices: [Int] = []
    
    for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        
        // Try numeric index first
        if let num = Int(trimmed) {
            indices.append(num)
        } else {
            // Try header name
            if let index = headers.firstIndex(of: trimmed) {
                indices.append(index + 1)  // Convert to 1-based
            }
        }
    }
    
    return indices
}

// MARK: - Expression Engine

public struct CSVExpressionEngine: Sendable {
    private let headers: [String]
    
    public init(headers: [String]) {
        self.headers = headers
    }
    
    /// Evaluate simple expression like "age > 30" or "name == 'John'"
    public func evaluate(_ expression: String, row: CSVRow) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        
        // Handle parentheses for grouping
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            let inner = String(trimmed.dropFirst().dropLast())
            return evaluate(inner, row: row)
        }
        
        // Handle logical operators (and, or)
        if let andParts = splitLogicalOp(trimmed, op: "&&") ?? splitLogicalOp(trimmed, op: "and") {
            return evaluate(andParts.0, row: row) && evaluate(andParts.1, row: row)
        }
        
        if let orParts = splitLogicalOp(trimmed, op: "||") ?? splitLogicalOp(trimmed, op: "or") {
            return evaluate(orParts.0, row: row) || evaluate(orParts.1, row: row)
        }
        
        // Handle comparison operators
        let ops = ["==", "!=", "<=", ">=", "<", ">", "="]
        for op in ops {
            if let parts = splitComparison(trimmed, op: op) {
                return compare(parts.left, parts.right, op: op, row: row)
            }
        }
        
        return false
    }
    
    private func splitLogicalOp(_ text: String, op: String) -> (String, String)? {
        guard let range = text.range(of: " \(op) ") else { return nil }
        let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (left, right)
    }
    
    private func splitComparison(_ text: String, op: String) -> (left: String, right: String)? {
        guard let range = text.range(of: op) else { return nil }
        let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (left, right)
    }
    
    private func compare(_ left: String, _ right: String, op: String, row: CSVRow) -> Bool {
        let leftValue = getValue(left, row: row)
        let rightValue = getValue(right, row: row)
        
        // Try numeric comparison first
        if let leftNum = Double(leftValue), let rightNum = Double(rightValue) {
            switch op {
            case "==", "=": return leftNum == rightNum
            case "!=": return leftNum != rightNum
            case "<": return leftNum < rightNum
            case ">": return leftNum > rightNum
            case "<=": return leftNum <= rightNum
            case ">=": return leftNum >= rightNum
            default: return false
            }
        }
        
        // String comparison
        switch op {
        case "==", "=": return leftValue == rightValue
        case "!=": return leftValue != rightValue
        case "<": return leftValue < rightValue
        case ">": return leftValue > rightValue
        case "<=": return leftValue <= rightValue
        case ">=": return leftValue >= rightValue
        default: return false
        }
    }
    
    private func getValue(_ expr: String, row: CSVRow) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        
        // Quoted string literal
        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) ||
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return String(trimmed.dropFirst().dropLast())
        }
        
        // Numeric literal
        if Double(trimmed) != nil {
            return trimmed
        }
        
        // Column reference (by index or name)
        if let index = Int(trimmed) {
            return row.cell(at: index).stringValue
        }
        
        // Try column name
        return row.cell(named: trimmed).stringValue
    }
}
