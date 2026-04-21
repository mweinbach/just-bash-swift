# JustBash Cookbook

Practical code examples for common use cases with the just-bash-swift library.

## Table of Contents

1. [Hello World - Basic Execution](#recipe-1-hello-world---basic-execution)
2. [File Processor - Read, Process, Write](#recipe-2-file-processor---read-process-write-files)
3. [CSV Pipeline - Data Processing with xan](#recipe-3-csv-pipeline---using-xan-for-data-processing)
4. [JSON Transformation - Using jq](#recipe-4-json-transformation---using-jq)
5. [Custom Filesystem - Logging Wrapper](#recipe-5-custom-filesystem---logging-wrapper-example)
6. [Array Operations - Working with Large Datasets](#recipe-6-array-operations---working-with-large-datasets)
7. [Error Handling - Graceful Failure Management](#recipe-7-error-handling---graceful-failure-management)
8. [Database Operations - Using sqlite3](#recipe-8-database-operations---using-sqlite3)
9. [Archive Management - Using tar](#recipe-9-archive-management---using-tar)
10. [Sandboxed Execution - Security Patterns](#recipe-10-sandboxed-execution---security-patterns)
11. [Integration with Swift Code](#recipe-11-integration-with-swift-code)
12. [Performance-Sensitive Operations](#recipe-12-performance-sensitive-operations)

---

## Recipe 1: Hello World - Basic Execution

**Problem:** Execute a simple bash script and capture the output.

**Solution:**

```swift
import JustBash

// Create a Bash instance with default options
let bash = Bash()

// Execute a simple command
let result = await bash.exec("echo 'Hello, World!'")

print("stdout: \(result.stdout)")
print("stderr: \(result.stderr)")
print("exit code: \(result.exitCode)")
```

**Expected Output:**
```
stdout: Hello, World!

stderr: 
exit code: 0
```

**Key Points:**
- `Bash()` creates an actor with an in-memory virtual filesystem
- `exec()` runs the script and returns an `ExecResult`
- `stdout` and `stderr` are captured as strings
- `exitCode` follows standard Unix conventions (0 = success)

---

## Recipe 2: File Processor - Read, Process, Write Files

**Problem:** Read input files, process their contents, and write output files.

**Solution:**

```swift
import JustBash

// Initialize with pre-populated files
let bash = Bash(options: .init(
    files: [
        "/data/input.txt": "apple\nbanana\ncherry\n",
        "/data/config.json": "{\"maxLines\": 2}"
    ],
    env: ["PROCESSOR": "JustBash"]
))

// Process files using shell commands
let result = await bash.exec("""
    echo "Starting processing by $PROCESSOR..."
    
    # Count lines in input
    line_count=$(wc -l < /data/input.txt)
    echo "Input has $line_count lines"
    
    # Sort lines and write to output
    sort /data/input.txt > /data/sorted.txt
    
    # Get first N lines based on config
    head -2 /data/sorted.txt > /data/top.txt
    
    # Append summary
    echo "Processed on $(date)" >> /data/top.txt
    
    # Show results
    echo "=== Sorted ==="
    cat /data/sorted.txt
    echo "=== Top ==="
    cat /data/top.txt
""")

print(result.stdout)

// Read result from the virtual filesystem
let topContent = try await bash.readFile("/data/top.txt")
print("Top file content: \(topContent)")
```

**Expected Output:**
```
Starting processing by JustBash...
Input has 3 lines
=== Sorted ===
apple
banana
cherry

=== Top ===
apple
banana
Processed on Thu Apr 2 10:30:00 UTC 2026

Top file content: apple
banana
Processed on Thu Apr 2 10:30:00 UTC 2026
```

**Key Points:**
- Pre-populate files using the `files` parameter in `BashOptions`
- Use environment variables within scripts via `$VAR`
- Files persist across `exec()` calls within the same `Bash` instance
- Use `readFile()` to access results from Swift code

---

## Recipe 3: CSV Pipeline - Using xan for Data Processing

**Problem:** Process CSV data with filtering, sorting, and aggregation.

**Solution:**

```swift
import JustBash

let csvData = """
name,age,city,salary
Alice,30,NYC,75000
Bob,25,LA,60000
Carol,35,Chicago,85000
David,28,NYC,70000
Eve,32,LA,90000
"""

let bash = Bash(options: .init(
    files: ["/data/employees.csv": csvData]
))

// Process CSV using xan commands
let result = await bash.exec("""
    echo "=== Full Dataset ==="
    xan view /data/employees.csv
    
    echo "\n=== Headers ==="
    xan headers /data/employees.csv
    
    echo "\n=== Filter: Age > 28 ==="
    xan filter 'age > 28' /data/employees.csv
    
    echo "\n=== Sort by Salary ==="
    xan sort salary /data/employees.csv
    
    echo "\n=== Select Name and City ==="
    xan select name,city /data/employees.csv
    
    echo "\n=== Statistics for Salary ==="
    xan stats salary /data/employees.csv
    
    echo "\n=== Top 2 by Salary ==="
    xan sort salary /data/employees.csv | xan head 2
""")

print(result.stdout)
```

**Expected Output:**
```
=== Full Dataset ===
name   | age | city    | salary
-------|-----|---------|-------
Alice  | 30  | NYC     | 75000
Bob    | 25  | LA      | 60000
Carol  | 35  | Chicago | 85000
David  | 28  | NYC     | 70000
Eve    | 32  | LA      | 90000

=== Headers ===
1:	name
2:	age
3:	city
4:	salary

=== Filter: Age > 28 ===
name,age,city,salary
Alice,30,NYC,75000
Carol,35,Chicago,85000
Eve,32,LA,90000

=== Sort by Salary ===
name,age,city,salary
Bob,25,LA,60000
David,28,NYC,70000
Alice,30,NYC,75000
Carol,35,Chicago,85000
Eve,32,LA,90000

=== Select Name and City ===
name,city
Alice,NYC
Bob,LA
Carol,Chicago
David,NYC
Eve,LA

=== Statistics for Salary ===
Statistics for column 'salary':

 count:    5
 min:      60000
 max:      90000
 sum:      380000
 mean:     76000.0
 median:   75000.0
 stddev:   11135.528725...

=== Top 2 by Salary ===
name,age,city,salary
Eve,32,LA,90000
Carol,35,Chicago,85000
```

**Key Points:**
- `xan` provides powerful CSV processing capabilities
- Supports filtering with expressions like `'age > 30'`
- Can sort by any column (numeric or alphabetical)
- `select` can use column names or indices (1-based)
- Pipes work seamlessly between xan commands

---

## Recipe 4: JSON Transformation - Using jq

**Problem:** Parse, transform, and query JSON data.

**Solution:**

```swift
import JustBash

let jsonData = """
{
  "users": [
    {"id": 1, "name": "Alice", "active": true, "tags": ["admin", "dev"]},
    {"id": 2, "name": "Bob", "active": false, "tags": ["user"]},
    {"id": 3, "name": "Carol", "active": true, "tags": ["admin", "ops"]},
    {"id": 4, "name": "David", "active": true, "tags": ["dev"]}
  ],
  "meta": {"count": 4, "version": "1.0"}
}
"""

let bash = Bash(options: .init(
    files: ["/data/users.json": jsonData]
))

let result = await bash.exec("""
    echo "=== Extract Users Array ==="
    jq '.users' /data/users.json
    
    echo "\n=== Get All Names ==="
    jq '.users[].name' /data/users.json
    
    echo "\n=== Filter Active Users ==="
    jq '.users[] | select(.active == true)' /data/users.json
    
    echo "\n=== Count Active Users ==="
    jq '[.users[] | select(.active == true)] | length' /data/users.json
    
    echo "\n=== Create Summary ==="
    jq '{
        total: (.users | length),
        active: ([.users[] | select(.active == true)] | length),
        admins: ([.users[] | select(.tags | contains(["admin"]))] | length),
        names: [.users[].name]
    }' /data/users.json
    
    echo "\n=== Transform Users ==="
    jq '.users | map({
        id: .id,
        displayName: .name,
        status: (if .active then "online" else "offline" end),
        role: (.tags[0])
    })' /data/users.json
    
    echo "\n=== Get User with ID 2 ==="
    jq '.users[] | select(.id == 2)' /data/users.json
""")

print(result.stdout)

// Save transformed output to a file
_ = await bash.exec("""
    jq '.users | map(select(.active == true))' /data/users.json > /data/active_users.json
""")

let activeUsers = try await bash.readFile("/data/active_users.json")
print("\nActive users JSON saved to file")
```

**Expected Output:**
```
=== Extract Users Array ===
[
  {"id": 1, "name": "Alice", "active": true, "tags": ["admin", "dev"]},
  {"id": 2, "name": "Bob", "active": false, "tags": ["user"]},
  ...
]

=== Get All Names ===
"Alice"
"Bob"
"Carol"
"David"

=== Filter Active Users ===
{"id": 1, "name": "Alice", "active": true, "tags": ["admin", "dev"]}
{"id": 3, "name": "Carol", "active": true, "tags": ["admin", "ops"]}
{"id": 4, "name": "David", "active": true, "tags": ["dev"]}

=== Count Active Users ===
3

=== Create Summary ===
{
  "total": 4,
  "active": 3,
  "admins": 2,
  "names": ["Alice", "Bob", "Carol", "David"]
}

=== Transform Users ===
[
  {"id": 1, "displayName": "Alice", "status": "online", "role": "admin"},
  {"id": 2, "displayName": "Bob", "status": "offline", "role": "user"},
  ...
]

Active users JSON saved to file
```

**Key Points:**
- `jq` supports complex JSON queries and transformations
- Use `.` for identity, `.key` for field access, `[]` for array iteration
- `select()` filters elements based on conditions
- `map()` transforms each element in an array
- Pipes (`|`) chain operations together
- Supports creating new JSON structures from existing data

---

## Recipe 5: Custom Filesystem - Logging Wrapper Example

**Problem:** Audit all filesystem operations for debugging or compliance.

**Solution:**

```swift
import Foundation
import JustBash
import JustBashFS

/// A logging filesystem wrapper that records all operations
final class LoggingFilesystem: @unchecked Sendable, BashFilesystem {
    private let lock = NSLock()
    private let wrapped: BashFilesystem
    private var _operations: [(operation: String, path: String, timestamp: Date)] = []
    private let logger: (String) -> Void
    
    init(wrapping filesystem: BashFilesystem, logger: @escaping (String) -> Void = { print($0) }) {
        self.wrapped = filesystem
        self.logger = logger
    }
    
    var operations: [(operation: String, path: String, timestamp: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return _operations
    }
    
    private func log(_ operation: String, path: String) {
        let normalized = normalizePath(path, relativeTo: "/")
        let entry = (operation: operation, path: normalized, timestamp: Date())
        lock.lock()
        _operations.append(entry)
        lock.unlock()
        logger("[FS] \(operation): \(normalized)")
    }
    
    // MARK: - BashFilesystem Protocol
    
    func readFile(path: String, relativeTo: String) throws -> Data {
        log("readFile", path: path)
        return try wrapped.readFile(path: path, relativeTo: relativeTo)
    }
    
    func writeFile(path: String, content: Data, relativeTo: String) throws {
        log("writeFile", path: path)
        try wrapped.writeFile(path: path, content: content, relativeTo: relativeTo)
    }
    
    func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        log("deleteFile", path: path)
        try wrapped.deleteFile(path: path, relativeTo: relativeTo, recursive: recursive, force: force)
    }
    
    func fileExists(path: String, relativeTo: String) -> Bool {
        log("fileExists", path: path)
        return wrapped.fileExists(path: path, relativeTo: relativeTo)
    }
    
    func isDirectory(path: String, relativeTo: String) -> Bool {
        log("isDirectory", path: path)
        return wrapped.isDirectory(path: path, relativeTo: relativeTo)
    }
    
    func listDirectory(path: String, relativeTo: String) throws -> [String] {
        log("listDirectory", path: path)
        return try wrapped.listDirectory(path: path, relativeTo: relativeTo)
    }
    
    func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        log("createDirectory", path: path)
        try wrapped.createDirectory(path: path, relativeTo: relativeTo, recursive: recursive)
    }
    
    func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        log("fileInfo", path: path)
        return try wrapped.fileInfo(path: path, relativeTo: relativeTo)
    }
    
    func walk(path: String, relativeTo: String) throws -> [String] {
        log("walk", path: path)
        return try wrapped.walk(path: path, relativeTo: relativeTo)
    }
    
    func normalizePath(_ path: String, relativeTo: String) -> String {
        return wrapped.normalizePath(path, relativeTo: relativeTo)
    }
    
    func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
        log("glob", path: pattern)
        return wrapped.glob(pattern, relativeTo: relativeTo, dotglob: dotglob, extglob: extglob)
    }
}

// Usage example
let baseFS = VirtualFileSystem(initialFiles: [
    "/data/input.txt": "Hello, World!"
])

let loggingFS = LoggingFilesystem(wrapping: baseFS) { log in
    // Send to analytics, database, or monitoring system
    print(log)
}

let bash = Bash(options: .init(filesystem: loggingFS))

let result = await bash.exec("""
    echo "Reading file..."
    cat /data/input.txt
    
    echo "Writing new file..."
    echo 'New content' > /data/output.txt
    
    echo "Checking existence..."
    test -f /data/output.txt && echo "Exists!"
    
    echo "Listing directory..."
    ls /data
""")

print("\n=== Operation Audit ===")
for op in loggingFS.operations {
    print("\(op.timestamp): \(op.operation) \(op.path)")
}
```

**Expected Output:**
```
[FS] readFile: /data/input.txt
Reading file...
Hello, World!
[FS] fileExists: /data/output.txt
[FS] createDirectory: /data
[FS] writeFile: /data/output.txt
Writing new file...
[FS] fileExists: /data/output.txt
[FS] readFile: /data/output.txt
Checking existence...
Exists!
[FS] listDirectory: /data
Listing directory...
input.txt
output.txt

=== Operation Audit ===
2026-04-02 10:30:00: readFile /data/input.txt
2026-04-02 10:30:00: fileExists /data/output.txt
2026-04-02 10:30:00: createDirectory /data
2026-04-02 10:30:00: writeFile /data/output.txt
...
```

**Key Points:**
- Implement `BashFilesystem` protocol to create custom filesystem wrappers
- All methods must be `Sendable`-safe for concurrent access
- Use locks for mutable state in wrapper implementations
- Log all operations for auditing, debugging, or analytics
- Operations flow through to the wrapped filesystem

---

## Recipe 6: Array Operations - Working with Large Datasets

**Problem:** Process large arrays efficiently with shell scripting.

**Solution:**

```swift
import JustBash

let bash = Bash()

// Working with indexed arrays
let result1 = await bash.exec("""
    echo "=== Indexed Array Operations ==="
    
    # Create array with values
    numbers=(10 20 30 40 50 60 70 80 90 100)
    
    # Access individual elements
    echo "First: \${numbers[0]}"
    echo "Last: \${numbers[-1]}"
    echo "Count: \${#numbers[@]}"
    
    # Iterate over array
    echo "All values:"
    for n in "\${numbers[@]}"; do
        echo "  - $n"
    done
    
    # Process array with arithmetic
    sum=0
    for n in "\${numbers[@]}"; do
        sum=$((sum + n))
    done
    echo "Sum: $sum"
    echo "Average: $((sum / ${#numbers[@]}))"
""")

print(result1.stdout)

// Working with associative arrays
let result2 = await bash.exec("""
    echo "\n=== Associative Array Operations ==="
    
    # Create associative array
    declare -A users
    users[alice]=admin
    users[bob]=developer
    users[carol]=designer
    users[dave]=manager
    
    # Access values by key
    echo "Alice's role: \${users[alice]}"
    echo "Bob's role: \${users[bob]}"
    
    # Check if key exists
    if [[ -n "\${users[eve]+isset}" ]]; then
        echo "Eve exists"
    else
        echo "Eve not found (using default)"
    fi
    
    # Iterate over keys
    echo "All users:"
    for name in "\${!users[@]}"; do
        echo "  $name: \${users[$name]}"
    done
    
    # Count entries
    echo "Total users: \${#users[@]}"
""")

print(result2.stdout)

// Large dataset processing with readarray
let result3 = await bash.exec("""
    echo "\n=== Processing Large Dataset ==="
    
    # Generate large dataset
    for i in {1..100}; do
        echo "item_$i,$((RANDOM % 1000)),$((RANDOM % 100))"
    done > /tmp/large_dataset.txt
    
    echo "Generated $(wc -l < /tmp/large_dataset.txt) rows"
    
    # Read into array
    readarray -t lines < /tmp/large_dataset.txt
    echo "Loaded \${#lines[@]} lines into array"
    
    # Process in batches
    batch_size=10
    total=0
    for ((i=0; i<${#lines[@]}; i+=batch_size)); do
        batch_end=$((i + batch_size))
        [ $batch_end -gt ${#lines[@]} ] && batch_end=${#lines[@]}
        
        batch_count=$((batch_end - i))
        total=$((total + batch_count))
        echo "Processed batch $((i/batch_size + 1)): $batch_count items"
    done
    
    echo "Total processed: $total"
""")

print(result3.stdout)
```

**Expected Output:**
```
=== Indexed Array Operations ===
First: 10
Last: 100
Count: 10
All values:
  - 10
  - 20
  ...
Sum: 550
Average: 55

=== Associative Array Operations ===
Alice's role: admin
Bob's role: developer
Eve not found (using default)
All users:
  alice: admin
  bob: developer
  carol: designer
  dave: manager
Total users: 4

=== Processing Large Dataset ===
Generated 100 rows
Loaded 100 lines into array
Processed batch 1: 10 items
Processed batch 2: 10 items
...
Total processed: 100
```

**Key Points:**
- Indexed arrays: `arr=(1 2 3)` with `${arr[0]}`, `${#arr[@]}`
- Associative arrays: `declare -A map` with `${map[key]}`
- Use `${!array[@]}` to get all keys
- Use `${array[@]}` to get all values
- `readarray` efficiently loads files into arrays
- Batch processing helps manage memory with large datasets

---

## Recipe 7: Error Handling - Graceful Failure Management

**Problem:** Handle errors gracefully and implement robust error recovery.

**Solution:**

```swift
import JustBash

let bash = Bash()

// Basic error handling with exit codes
let result1 = await bash.exec("""
    echo "=== Basic Error Handling ==="
    
    # Check if command succeeded
    if ls /nonexistent 2>/dev/null; then
        echo "Directory found"
    else
        echo "Directory not found (exit code: $?)"
    fi
    
    # Logical operators for control flow
    mkdir -p /tmp/testdir && echo "Created directory" || echo "Failed to create"
    
    # Set -e for strict mode (exit on first error)
    set -e
    echo "Before error"
    # This would exit: cat /nonexistent
    set +e
    echo "After disabling strict mode"
""")

print(result1.stdout)
print("Exit code: \(result1.exitCode)")

// Advanced error handling with trap
let result2 = await bash.exec("""
    echo "\n=== Advanced Error Handling ==="
    
    # Define error handler
    cleanup() {
        echo "Cleaning up..."
        rm -f /tmp/temp_file_*.txt 2>/dev/null || true
        echo "Cleanup complete (exit code: $?)"
    }
    
    # Register trap for exit
    trap cleanup EXIT
    
    # Create temp files
    touch /tmp/temp_file_1.txt
    touch /tmp/temp_file_2.txt
    echo "Created temp files"
    
    # Simulate work
    echo "Doing work..."
    
    # Trap executes on exit
""")

print(result2.stdout)

// Nounset mode for undefined variables
let result3 = await bash.exec("""
    echo "\n=== Strict Variable Checking ==="
    
    # Enable nounset mode
    set -u
    
    # Define variable
    defined_var="I exist"
    echo "Defined: $defined_var"
    
    # Use default value for potentially undefined variable
    echo "Undefined with default: \${undefined_var:-default_value}"
    
    # This would fail with nounset:
    # echo "$undefined_var"
    
    # Check if variable is set before using
    if [ -n "\${maybe_set+isset}" ]; then
        echo "maybe_set is defined: $maybe_set"
    else
        echo "maybe_set is not defined"
    fi
    
    # Assign default if unset
    echo "\${unset_var:=new_default}"
    echo "Now unset_var is: $unset_var"
""")

print(result3.stdout)

// Function error handling
let result4 = await bash.exec("""
    echo "\n=== Function Error Handling ==="
    
    # Function that might fail
    process_file() {
        local file="$1"
        
        if [ ! -f "$file" ]; then
            echo "Error: File not found: $file" >&2
            return 1
        fi
        
        if [ ! -r "$file" ]; then
            echo "Error: Cannot read: $file" >&2
            return 2
        fi
        
        echo "Processing: $file"
        return 0
    }
    
    # Call function and check result
    if process_file /nonexistent; then
        echo "Success"
    else
        exit_code=$?
        echo "Failed with exit code: $exit_code"
    fi
    
    # Create a test file and try again
    touch /tmp/test.txt
    if process_file /tmp/test.txt; then
        echo "Second attempt succeeded"
    fi
""")

print(result4.stdout)
if !result4.stderr.isEmpty {
    print("stderr: \(result4.stderr)")
}
```

**Expected Output:**
```
=== Basic Error Handling ===
Directory not found (exit code: 1)
Created directory
Before error
After disabling strict mode

Exit code: 0

=== Advanced Error Handling ===
Created temp files
Doing work...
Cleaning up...
Cleanup complete (exit code: 0)

=== Strict Variable Checking ===
Defined: I exist
Undefined with default: default_value
maybe_set is not defined
new_default
Now unset_var is: new_default

=== Function Error Handling ===
Error: File not found: /nonexistent
Failed with exit code: 1
Processing: /tmp/test.txt
Second attempt succeeded
```

**Key Points:**
- Use `$?` to check the exit code of the last command
- `set -e` exits immediately on any error
- `set -u` fails on undefined variable expansion
- `trap` allows cleanup on script exit
- Functions can return exit codes with `return N`
- Redirect stderr with `2>/dev/null` or `>&2`
- Use default values: `${var:-default}` or `${var:=default}`

---

## Recipe 8: Database Operations - Using sqlite3

**Problem:** Store and query structured data using SQLite.

**Solution:**

```swift
import JustBash

let bash = Bash()

// Create database and schema
let result1 = await bash.exec("""
    echo "=== Creating Database ==="
    
    # Create a new SQLite database
    sqlite3 /data/app.db "
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            age INTEGER,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE IF NOT EXISTS orders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            product TEXT,
            amount REAL,
            FOREIGN KEY (user_id) REFERENCES users(id)
        );
    "
    
    echo "Database created successfully"
""")

print(result1.stdout)

// Insert data
let result2 = await bash.exec("""
    echo "\n=== Inserting Data ==="
    
    # Insert users
    sqlite3 /data/app.db "
        INSERT INTO users (name, email, age) VALUES
            ('Alice', 'alice@example.com', 30),
            ('Bob', 'bob@example.com', 25),
            ('Carol', 'carol@example.com', 35);
    "
    
    # Insert orders
    sqlite3 /data/app.db "
        INSERT INTO orders (user_id, product, amount) VALUES
            (1, 'Laptop', 999.99),
            (1, 'Mouse', 29.99),
            (2, 'Keyboard', 79.99),
            (3, 'Monitor', 299.99);
    "
    
    echo "Data inserted successfully"
""")

print(result2.stdout)

// Query data
let result3 = await bash.exec("""
    echo "\n=== Querying Data ==="
    
    echo "--- All Users ---"
    sqlite3 /data/app.db "SELECT * FROM users;"
    
    echo "\n--- Users with Orders ---"
    sqlite3 /data/app.db "
        SELECT u.name, COUNT(o.id) as order_count, SUM(o.amount) as total
        FROM users u
        LEFT JOIN orders o ON u.id = o.user_id
        GROUP BY u.id
        ORDER BY total DESC;
    "
    
    echo "\n--- Users over 28 ---"
    sqlite3 /data/app.db "SELECT name, age FROM users WHERE age > 28;"
    
    echo "\n--- JSON Output ---"
    sqlite3 -json /data/app.db "SELECT * FROM users LIMIT 2;"
""")

print(result3.stdout)

// Update and delete
let result4 = await bash.exec("""
    echo "\n=== Updating and Deleting ==="
    
    # Update user
    sqlite3 /data/app.db "
        UPDATE users SET age = 31 WHERE name = 'Alice';
    "
    
    echo "Updated Alice's age"
    
    # Verify update
    echo "Alice's new age:"
    sqlite3 /data/app.db "SELECT name, age FROM users WHERE name = 'Alice';"
    
    # Delete with cascade awareness
    echo "\nDeleting orders for Bob..."
    sqlite3 /data/app.db "
        DELETE FROM orders WHERE user_id = (SELECT id FROM users WHERE name = 'Bob');
    "
    
    echo "Remaining orders:"
    sqlite3 /data/app.db "SELECT COUNT(*) FROM orders;"
""")

print(result4.stdout)
```

**Expected Output:**
```
=== Creating Database ===
Database created successfully

=== Inserting Data ===
Data inserted successfully

=== Querying Data ===
--- All Users ---
1|Alice|alice@example.com|30|2026-04-02 10:30:00
2|Bob|bob@example.com|25|2026-04-02 10:30:00
3|Carol|carol@example.com|35|2026-04-02 10:30:00

--- Users with Orders ---
Alice|2|1029.98
Carol|1|299.99
Bob|1|79.99

--- Users over 28 ---
Alice|30
Carol|35

--- JSON Output ---
[{"id":1,"name":"Alice","email":"alice@example.com","age":30,"created_at":"2026-04-02 10:30:00"},{"id":2,"name":"Bob","email":"bob@example.com","age":25,"created_at":"2026-04-02 10:30:00"}]

=== Updating and Deleting ===
Updated Alice's age
Alice's new age:
Alice|31

Deleting orders for Bob...
Remaining orders:
3
```

**Key Points:**
- SQLite databases persist in the virtual filesystem
- Use standard SQL for schema creation, inserts, updates, deletes
- `sqlite3 -json` outputs results as JSON
- Join tables for complex queries
- Transactions are supported for data integrity
- Database files can be backed up and restored like any other file

---

## Recipe 9: Archive Management - Using tar

**Problem:** Create and extract tar archives for file bundling.

**Solution:**

```swift
import JustBash

let bash = Bash(options: .init(
    files: [
        "/project/src/main.swift": "print(\"Hello\")",
        "/project/src/utils.swift": "func helper() {}",
        "/project/README.md": "# Project",
        "/project/config.json": "{\"version\": \"1.0\"}"
    ]
))

// Create archive
let result1 = await bash.exec("""
    echo "=== Creating Archive ==="
    
    # Create tar archive of project
    tar -cvf /tmp/project.tar -C / project
    
    echo "\nArchive created:"
    ls -lh /tmp/project.tar
    
    # Create gzipped archive
    tar -czvf /tmp/project.tar.gz -C / project
    
    echo "\nGzipped archive created:"
    ls -lh /tmp/project.tar.gz
""")

print(result1.stdout)

// List archive contents
let result2 = await bash.exec("""
    echo "\n=== Listing Archive Contents ==="
    
    echo "--- Standard Archive ---"
    tar -tf /tmp/project.tar
    
    echo "\n--- Gzipped Archive ---"
    tar -tzf /tmp/project.tar.gz
""")

print(result2.stdout)

// Extract archive
let result3 = await bash.exec("""
    echo "\n=== Extracting Archive ==="
    
    # Create extraction directory
    mkdir -p /extracted
    
    # Extract archive
    tar -xvf /tmp/project.tar -C /extracted
    
    echo "\nExtracted contents:"
    find /extracted -type f
    
    echo "\nVerify file content:"
    cat /extracted/project/src/main.swift
""")

print(result3.stdout)

// Selective extraction
let result4 = await bash.exec("""
    echo "\n=== Selective Extraction ==="
    
    mkdir -p /selective
    
    # Extract only .swift files
    tar -xvf /tmp/project.tar -C /selective --wildcards "*.swift"
    
    echo "Extracted Swift files:"
    find /selective -name "*.swift"
    
    # Extract with strip-components
    mkdir -p /stripped
    tar -xvf /tmp/project.tar -C /stripped --strip-components=1
    
    echo "\nStripped structure:"
    ls -la /stripped/
""")

print(result4.stdout)

// Create archive from multiple sources
let result5 = await bash.exec("""
    echo "\n=== Multi-Source Archive ==="
    
    # Create additional files
    mkdir -p /docs
    echo "API documentation" > /docs/api.md
    echo "User guide" > /docs/guide.md
    
    # Create archive from multiple directories
    tar -cvf /tmp/bundle.tar /project/src /docs
    
    echo "\nBundle contents:"
    tar -tf /tmp/bundle.tar | head -10
""")

print(result5.stdout)
```

**Expected Output:**
```
=== Creating Archive ===
project/
project/src/
project/src/main.swift
project/src/utils.swift
project/README.md
project/config.json

Archive created:
-rw-r--r-- 1 user group 10K Apr 2 10:30 /tmp/project.tar

Gzipped archive created:
-rw-r--r-- 1 user group 2K Apr 2 10:30 /tmp/project.tar.gz

=== Listing Archive Contents ===
--- Standard Archive ---
project/
project/src/
project/src/main.swift
...

=== Extracting Archive ===
project/
project/src/
...

Extracted contents:
/extracted/project/src/main.swift
/extracted/project/src/utils.swift
/extracted/project/README.md
/extracted/project/config.json

Verify file content:
print("Hello")

=== Selective Extraction ===
Extracted Swift files:
/selective/project/src/main.swift
/selective/project/src/utils.swift

Stripped structure:
total 16
drwxr-xr-x 4 user group 128 Apr 2 10:30 .
drwxr-xr-x 3 user group  60 Apr 2 10:30 ..
drwxr-xr-x 2 user group  60 Apr 2 10:30 src
-rw-r--r-- 1 user group  10 Apr 2 10:30 README.md
-rw-r--r-- 1 user group  20 Apr 2 10:30 config.json
```

**Key Points:**
- `tar -cvf` creates an archive (`c`=create, `v`=verbose, `f`=file)
- `tar -czvf` creates a gzipped archive (`z`=gzip)
- `tar -tf` lists archive contents
- `tar -xvf` extracts an archive (`x`=extract)
- `tar -tzf` lists gzipped archives
- Use `--strip-components=N` to remove leading path components
- Use wildcards for selective extraction

---

## Recipe 10: Sandboxed Execution - Security Patterns

**Problem:** Run untrusted scripts safely with resource limits and restricted access.

**Solution:**

```swift
import JustBash
import JustBashCore
import JustBashFS

/// A sandboxed filesystem that restricts access to sensitive paths
final class SandboxedFilesystem: @unchecked Sendable, BashFilesystem {
    private let wrapped: BashFilesystem
    private let allowedPaths: [String]
    private let blockedPatterns: [String]
    private let maxFileSize: Int
    private let maxTotalSize: Int
    private var totalWritten: Int = 0
    private let lock = NSLock()
    
    init(
        wrapping filesystem: BashFilesystem,
        allowedPaths: [String] = ["/sandbox"],
        blockedPatterns: [String] = ["..", "/etc", "/bin", "/usr", "/proc"],
        maxFileSize: Int = 1024 * 1024, // 1MB per file
        maxTotalSize: Int = 10 * 1024 * 1024 // 10MB total
    ) {
        self.wrapped = filesystem
        self.allowedPaths = allowedPaths
        self.blockedPatterns = blockedPatterns
        self.maxFileSize = maxFileSize
        self.maxTotalSize = maxTotalSize
    }
    
    private func isPathAllowed(_ path: String) -> Bool {
        let normalized = normalizePath(path, relativeTo: "/")
        
        // Check blocked patterns
        for pattern in blockedPatterns {
            if normalized.contains(pattern) {
                return false
            }
        }
        
        // Check allowed paths
        for allowed in allowedPaths {
            if normalized.hasPrefix(allowed) || normalized == allowed {
                return true
            }
        }
        
        return false
    }
    
    func readFile(path: String, relativeTo: String) throws -> Data {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("Access denied: \(normalized)")
        }
        return try wrapped.readFile(path: path, relativeTo: relativeTo)
    }
    
    func writeFile(path: String, content: Data, relativeTo: String) throws {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("Write denied: \(normalized)")
        }
        guard content.count <= maxFileSize else {
            throw FilesystemError.ioError("File exceeds max size: \(content.count) > \(maxFileSize)")
        }
        
        lock.lock()
        let newTotal = totalWritten + content.count
        guard newTotal <= maxTotalSize else {
            lock.unlock()
            throw FilesystemError.ioError("Total quota exceeded")
        }
        totalWritten = newTotal
        lock.unlock()
        
        try wrapped.writeFile(path: path, content: content, relativeTo: relativeTo)
    }
    
    func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("Delete denied: \(normalized)")
        }
        try wrapped.deleteFile(path: path, relativeTo: relativeTo, recursive: recursive, force: force)
    }
    
    func fileExists(path: String, relativeTo: String) -> Bool {
        return wrapped.fileExists(path: path, relativeTo: relativeTo)
    }
    
    func isDirectory(path: String, relativeTo: String) -> Bool {
        return wrapped.isDirectory(path: path, relativeTo: relativeTo)
    }
    
    func listDirectory(path: String, relativeTo: String) throws -> [String] {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("List denied: \(normalized)")
        }
        return try wrapped.listDirectory(path: path, relativeTo: relativeTo)
    }
    
    func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("Create denied: \(normalized)")
        }
        try wrapped.createDirectory(path: path, relativeTo: relativeTo, recursive: recursive)
    }
    
    func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        return try wrapped.fileInfo(path: path, relativeTo: relativeTo)
    }
    
    func walk(path: String, relativeTo: String) throws -> [String] {
        let normalized = normalizePath(path, relativeTo: relativeTo)
        guard isPathAllowed(normalized) else {
            throw FilesystemError.permissionDenied("Walk denied: \(normalized)")
        }
        return try wrapped.walk(path: path, relativeTo: relativeTo)
    }
    
    func normalizePath(_ path: String, relativeTo: String) -> String {
        return wrapped.normalizePath(path, relativeTo: relativeTo)
    }
    
    func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
        return wrapped.glob(pattern, relativeTo: relativeTo, dotglob: dotglob, extglob: extglob)
    }
}

// Create sandboxed environment
let baseFS = VirtualFileSystem(initialFiles: [
    "/sandbox/input.txt": "Hello from sandbox",
    "/sandbox/config.yaml": "setting: value"
])

let sandboxedFS = SandboxedFilesystem(
    wrapping: baseFS,
    allowedPaths: ["/sandbox"],
    maxFileSize: 1024, // 1KB for demo
    maxTotalSize: 5 * 1024 // 5KB total
)

// Configure execution limits
let limits = ExecutionLimits(
    maxInputLength: 4096,        // 4KB input
    maxOutputLength: 8192,       // 8KB output
    maxCommands: 50,             // Max 50 commands
    maxPipelineDepth: 5,         // Max 5 pipes
    maxLoopIterations: 100,      // Max 100 loop iterations
    maxCallDepth: 10             // Max 10 function calls
)

let bash = Bash(options: .init(
    cwd: "/sandbox",
    executionLimits: limits,
    filesystem: sandboxedFS
))

// Test sandboxed execution
print("=== Testing Sandboxed Execution ===\n")

// 1. Allowed operations
let result1 = await bash.exec("""
    echo "=== Allowed Operations ==="
    
    # Read from sandbox
    cat input.txt
    
    # Write within sandbox
    echo "New content" > output.txt
    
    # List sandbox contents
    ls -la
""")

print(result1.stdout)
if !result1.stderr.isEmpty {
    print("stderr: \(result1.stderr)")
}

// 2. Blocked operations
let result2 = await bash.exec("""
    echo "\n=== Blocked Operations ==="
    
    # Try to access outside sandbox
    cat /etc/passwd 2>&1 || echo "Blocked: /etc/passwd"
    
    # Try to access system directories
    ls /bin 2>&1 || echo "Blocked: /bin"
    
    # Try path traversal
    cat ../etc/passwd 2>&1 || echo "Blocked: path traversal"
""")

print(result2.stdout)
if !result2.stderr.isEmpty {
    print("Errors (expected): \(result2.stderr)")
}

// 3. Resource limits
let result3 = await bash.exec("""
    echo "\n=== Resource Limits ==="
    
    # Create many small files (should work)
    for i in {1..10}; do
        echo "x" > "file_$i.txt"
    done
    echo "Created 10 small files"
    
    # Try to exceed file count with large content
    # (This would fail with large content due to quota)
    echo "Testing quota protection..."
""")

print(result3.stdout)
if !result3.stderr.isEmpty {
    print("Limit errors: \(result3.stderr)")
}

print("\n=== Sandbox Security Summary ===")
print("- Paths restricted to: /sandbox")
print("- Blocked patterns: .., /etc, /bin, /usr, /proc")
print("- Max file size: 1KB")
print("- Max total size: 5KB")
print("- Command limits: 50 commands, 5 pipeline depth")
```

**Expected Output:**
```
=== Testing Sandboxed Execution ===

=== Allowed Operations ===
Hello from sandbox
New content
total 16
drwxr-xr-x 2 user group 4096 Apr 2 10:30 .
drwxr-xr-x 3 user group 4096 Apr 2 10:30 ..
-rw-r--r-- 1 user group   20 Apr 2 10:30 config.yaml
-rw-r--r-- 1 user group   19 Apr 2 10:30 input.txt
-rw-r--r-- 1 user group   12 Apr 2 10:30 output.txt

=== Blocked Operations ===
Blocked: /etc/passwd
Blocked: /bin
Blocked: path traversal

Errors (expected): cat: /etc/passwd: Permission denied
ls: /bin: Permission denied
cat: ../etc/passwd: Permission denied

=== Resource Limits ===
Created 10 small files
Testing quota protection...

=== Sandbox Security Summary ===
- Paths restricted to: /sandbox
- Blocked patterns: .., /etc, /bin, /usr, /proc
- Max file size: 1KB
- Max total size: 5KB
- Command limits: 50 commands, 5 pipeline depth
```

**Key Points:**
- Use custom filesystem wrappers to implement path restrictions
- Validate all paths before operations
- Use `ExecutionLimits` to constrain script complexity
- Block path traversal attacks with pattern matching
- Enforce resource quotas (file size, total storage)
- Combine filesystem and execution limits for defense in depth

---

## Recipe 11: Integration with Swift Code

**Problem:** Seamlessly integrate bash execution with Swift application logic.

**Solution:**

```swift
import JustBash
import Foundation

// Define a service that wraps Bash functionality
actor DataProcessor {
    private let bash: Bash
    
    init(initialFiles: [String: String] = [:]) {
        self.bash = Bash(options: .init(
            files: initialFiles,
            env: ["PROCESSOR_VERSION": "1.0"]
        ))
    }
    
    // MARK: - Data Transformation Methods
    
    func parseCSV(_ content: String) async throws -> [[String: String]] {
        // Write content to virtual filesystem
        _ = await bash.exec("cat > /input.csv" + " << 'EOF'\n" + content + "\nEOF")
        
        // Extract headers and data
        let result = await bash.exec("""
            head -1 /input.csv | tr ',' '\n' | nl -v 0
        """)
        
        let headers = result.stdout
            .split(separator: "\n")
            .reduce(into: [Int: String]()) { dict, line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2,
                   let index = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                    dict[index] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        
        // Read all rows
        let dataResult = await bash.exec("tail -n +2 /input.csv")
        
        var records: [[String: String]] = []
        for line in dataResult.stdout.split(separator: "\n") {
            let values = line.split(separator: ",", omittingEmptySubsequences: false)
            var record: [String: String] = [:]
            for (index, value) in values.enumerated() {
                if let header = headers[index] {
                    record[header] = String(value)
                }
            }
            records.append(record)
        }
        
        return records
    }
    
    func transformJSON(_ json: String, using jqFilter: String) async throws -> String {
        _ = await bash.exec("echo '\(json)' > /input.json")
        let result = await bash.exec("jq '\(jqFilter)' /input.json")
        
        guard result.exitCode == 0 else {
            throw ProcessingError.jqFailed(result.stderr)
        }
        
        return result.stdout
    }
    
    // MARK: - File Operations
    
    func createArchive(files: [String], archiveName: String) async throws -> Data {
        // Ensure all files exist
        for file in files {
            let check = await bash.exec("test -f \(file) && echo 'exists'")
            guard check.stdout.contains("exists") else {
                throw ProcessingError.fileNotFound(file)
            }
        }
        
        // Create archive
        let fileList = files.joined(separator: " ")
        let result = await bash.exec("tar -czf \(archiveName) \(fileList)")
        
        guard result.exitCode == 0 else {
            throw ProcessingError.archiveFailed(result.stderr)
        }
        
        // Read archive data
        let archiveContent = try await bash.readFile(archiveName)
        return Data(archiveContent.utf8)
    }
    
    // MARK: - Validation Methods
    
    func validateScript(_ script: String) async -> ValidationResult {
        // Use bash's dry-run capabilities
        let check = await bash.exec("""
            set -n
            \(script)
        """)
        
        if check.exitCode == 0 {
            return .valid
        } else {
            return .invalid(check.stderr)
        }
    }
    
    func analyzeComplexity(_ script: String) async -> ComplexityMetrics {
        let result = await bash.exec("""
            echo '\(script)' | wc -l
            echo '\(script)' | grep -c '|'
            echo '\(script)' | grep -E 'for|while|until' | wc -l
        """)
        
        let lines = result.stdout.split(separator: "\n")
        return ComplexityMetrics(
            lineCount: Int(lines[0]) ?? 0,
            pipelineCount: Int(lines[1]) ?? 0,
            loopCount: Int(lines[2]) ?? 0
        )
    }
    
    // MARK: - Access to Virtual FilesSystem
    
    func readFile(_ path: String) async throws -> String {
        return try await bash.readFile(path)
    }
    
    func listFiles(in directory: String = "/") async throws -> [String] {
        let entries = try await bash.listDirectory(directory)
        return entries.map { $0.name }
    }
}

// Supporting types
enum ProcessingError: Error {
    case jqFailed(String)
    case fileNotFound(String)
    case archiveFailed(String)
}

enum ValidationResult {
    case valid
    case invalid(String)
}

struct ComplexityMetrics {
    let lineCount: Int
    let pipelineCount: Int
    let loopCount: Int
    
    var complexityScore: Int {
        lineCount + (pipelineCount * 2) + (loopCount * 3)
    }
}

// Usage example
Task {
    let processor = DataProcessor(initialFiles: [
        "/data/sample.csv": "name,age,city\nAlice,30,NYC\nBob,25,LA",
        "/data/config.json": "{\"version\": \"1.0\"}"
    ])
    
    // Parse CSV
    let records = try await processor.parseCSV("name,age\nCarol,35\nDave,28")
    print("Parsed \(records.count) records")
    for record in records {
        print("  - \(record["name"] ?? "?"): \(record["age"] ?? "?")")
    }
    
    // Transform JSON
    let transformed = try await processor.transformJSON(
        "{\"users\": [{\"name\": \"Alice\"}, {\"name\": \"Bob\"}]}",
        using: ".users[].name"
    )
    print("\nTransformed JSON: \(transformed)")
    
    // Validate script
    let validation = await processor.validateScript("echo hello; exit 0")
    switch validation {
    case .valid:
        print("\nScript is valid")
    case .invalid(let error):
        print("\nScript invalid: \(error)")
    }
    
    // Analyze complexity
    let complexity = await processor.analyzeComplexity("""
        for i in {1..10}; do
            echo $i | grep 1
        done
    """)
    print("\nComplexity: \(complexity.complexityScore) (lines: \(complexity.lineCount), pipes: \(complexity.pipelineCount), loops: \(complexity.loopCount))")
    
    // List files
    let files = try await processor.listFiles(in: "/data")
    print("\nFiles in /data: \(files.joined(separator: ", "))")
}
```

**Expected Output:**
```
Parsed 2 records
  - Carol: 35
  - Dave: 28

Transformed JSON: "Alice"
"Bob"

Script is valid

Complexity: 14 (lines: 4, pipes: 1, loops: 1)

Files in /data: sample.csv, config.json
```

**Key Points:**
- Wrap `Bash` in an actor for thread-safe Swift integration
- Define clear error types for different failure modes
- Parse command output into Swift data structures
- Use `Bash` for data transformation while keeping logic in Swift
- Expose high-level methods that hide shell complexity
- Provide validation and analysis tools for user input

---

## Recipe 12: Performance-Sensitive Operations

**Problem:** Optimize execution for performance-critical scenarios.

**Solution:**

```swift
import JustBash
import JustBashCore

// Configure for performance
let performanceLimits = ExecutionLimits(
    maxInputLength: 1024 * 1024,      // 1MB input
    maxOutputLength: 5 * 1024 * 1024, // 5MB output
    maxCommands: 1000,                // Allow many commands
    maxPipelineDepth: 32,              // Max pipeline depth
    maxLoopIterations: 10000,          // Many loop iterations
    maxCallDepth: 100,                 // Deep call stacks
    maxSubstitutionDepth: 50
)

let bash = Bash(options: .init(
    executionLimits: performanceLimits
))

// Recipe 12a: Efficient File Processing with Streams
print("=== Efficient File Processing ===\n")

let result1 = await bash.exec("""
    echo "=== Streaming Large Files ==="
    
    # Generate large file efficiently
    seq 1 10000 > /tmp/large_numbers.txt
    echo "Generated file with $(wc -l < /tmp/large_numbers.txt) lines"
    
    # Process with streaming (memory efficient)
    echo "Sum of first 1000 lines:"
    head -1000 /tmp/large_numbers.txt | awk '{sum += $1} END {print sum}'
    
    # Filter and process in one pass
    echo "\nEven numbers count (first 5000):"
    head -5000 /tmp/large_numbers.txt | awk '$1 % 2 == 0' | wc -l
    
    # Use grep with line numbers for indexed access
    echo "\nFinding specific patterns:"
    grep -n "^100$" /tmp/large_numbers.txt
""")

print(result1.stdout)

// Recipe 12b: Batch Operations
print("\n=== Batch Operations ===\n")

let result2 = await bash.exec("""
    echo "=== Processing in Batches ==="
    
    # Create test data
    for i in {1..1000}; do
        echo "user_$i,$((RANDOM % 100 + 18)),$((RANDOM % 50000 + 30000))"
    done > /tmp/users.csv
    
    # Process in chunks using split
    mkdir -p /tmp/batches
    split -l 100 /tmp/users.csv /tmp/batches/chunk_
    
    echo "Created $(ls /tmp/batches | wc -l) batches of 100 lines each"
    
    # Process each batch in parallel-like fashion (sequentially but efficiently)
    total_age=0
    count=0
    for batch in /tmp/batches/chunk_*; do
        while IFS=',' read -r name age salary; do
            total_age=$((total_age + age))
            count=$((count + 1))
        done < "$batch"
    done
    
    echo "Processed $count users"
    echo "Average age: $((total_age / count))"
""")

print(result2.stdout)

// Recipe 12c: Optimized Array Operations
print("\n=== Optimized Array Operations ===\n")

let result3 = await bash.exec("""
    echo "=== Efficient Array Handling ==="
    
    # Use mapfile for large arrays (more efficient than loops)
    mapfile -t numbers < <(seq 1 1000)
    echo "Loaded \${#numbers[@]} numbers into array"
    
    # Batch arithmetic with awk (C-speed)
    echo "\nSum using awk (fast):"
    printf '%s\n' "\${numbers[@]}" | awk '{sum += $1} END {print sum}'
    
    # Efficient filtering
    echo "\nFilter with grep (fast):"
    printf '%s\n' "\${numbers[@]}" | grep -E '^[0-9]{3}$' | wc -l
    
    # Sort large datasets externally
    echo "\nExternal sort (memory efficient):"
    printf '%s\n' "\${numbers[@]}" | sort -rn | head -5
""")

print(result3.stdout)

// Recipe 12d: Command Substitution Optimization
print("\n=== Command Substitution Optimization ===\n")

let result4 = await bash.exec("""
    echo "=== Optimized Command Substitution ==="
    
    # Avoid subshell overhead when possible
    # Instead of: result=$(echo "value")
    # Use: read -r result <<< "value"
    
    # Efficient string building
    printf -v joined '%s,' {1..100}
    echo "Joined 100 numbers (length: \${#joined})"
    
    # Use printf for formatting (faster than echo)
    echo "\nFormatted output:"
    printf 'Item %3d: %s\n' 1 "First" 2 "Second" 3 "Third"
    
    # Group commands with { } instead of ( ) when possible
    # { cmd1; cmd2; } is faster than (cmd1; cmd2) - no subshell
    {
        echo "Line 1"
        echo "Line 2"
        echo "Line 3"
    } > /tmp/grouped.txt
    
    echo "\nGrouped output:"
    cat /tmp/grouped.txt
""")

print(result4.stdout)

// Recipe 12e: Avoiding Unnecessary Forks
print("\n=== Minimizing Process Forks ===\n")

let result5 = await bash.exec("""
    echo "=== Reducing Fork Overhead ==="
    
    # Use built-in commands when possible
    # Built-in: echo, printf, read, test, [ ], [[ ]]
    # External: cat, grep, awk, sed
    
    # Instead of: cat file | grep pattern
    # Use: grep pattern file
    
    # Instead of: echo $var | sed 's/old/new/'
    # Use: \${var//old/new}
    
    test_var="hello world"
    replaced="\${test_var//world/universe}"
    echo "String replacement (built-in): $replaced"
    
    # Use parameter expansion instead of external tools
    filename="/path/to/file.txt"
    basename="\${filename##*/}"
    extension="\${filename##*.}"
    echo "\nParsed filename:"
    echo "  Full: $filename"
    echo "  Base: $basename"
    echo "  Ext:  $extension"
    
    # Use arithmetic expansion
    count=0
    for ((i=0; i<1000; i++)); do
        ((count += i))
    done
    echo "\nArithmetic sum (built-in): $count"
""")

print(result5.stdout)

// Recipe 12f: Memory-Efficient Patterns
print("\n=== Memory-Efficient Patterns ===\n")

let result6 = await bash.exec("""
    echo "=== Memory-Efficient Processing ==="
    
    # Use while read loop for line-by-line (low memory)
    line_count=0
    while read -r line; do
        ((line_count++))
        # Process line without storing all lines
    done < /tmp/large_numbers.txt
    echo "Processed $line_count lines with minimal memory"
    
    # Use awk for complex processing (compiled, fast)
    echo "\nComplex calculation with awk:"
    awk '
        {sum += $1; sumsq += $1*$1}
        END {
            mean = sum / NR
            variance = sumsq/NR - mean*mean
            print "Mean: " mean
            print "StdDev: " sqrt(variance)
        }
    ' /tmp/large_numbers.txt
    
    # Clean up temporary files
    rm -rf /tmp/large_numbers.txt /tmp/batches /tmp/users.csv /tmp/grouped.txt
    echo "\nCleaned up temporary files"
""")

print(result6.stdout)

print("\n=== Performance Tips Summary ===")
print("""
1. Use built-in commands (echo, printf, read, [[ ]]) over external tools
2. Avoid subshells with $() when possible - use parameter expansion
3. Process files line-by-line with while read instead of loading entire file
4. Use awk for numeric computations (faster than pure bash for math)
5. Chain commands with | instead of temporary files
6. Use { } grouping over ( ) subshells when isolation isn't needed
7. Use mapfile/readarray for bulk loading, but process large files streaming
8. Leverage parameter expansion: \${var//pat/rep}, \${var#prefix}, \${var%suffix}
9. Set appropriate ExecutionLimits for your workload
10. Use xargs -P or parallel processing patterns for CPU-bound tasks
""")
```

**Expected Output:**
```
=== Efficient File Processing ===

=== Streaming Large Files ===
Generated file with 10000 lines
Sum of first 1000 lines:
500500

Even numbers count (first 5000):
2500

Finding specific patterns:
100:100

=== Batch Operations ===

=== Processing in Batches ===
Created 10 batches of 100 lines each
Processed 1000 users
Average age: 67

=== Optimized Array Operations ===

=== Efficient Array Handling ===
Loaded 1000 numbers into array

Sum using awk (fast):
500500

Filter with grep (fast):
900

External sort (memory efficient):
1000
999
998
997
996

=== Command Substitution Optimization ===

=== Optimized Command Substitution ===
Joined 100 numbers (length: 292)

Formatted output:
Item   1: First
Item   2: Second
Item   3: Third

Grouped output:
Line 1
Line 2
Line 3

=== Minimizing Process Forks ===

=== Reducing Fork Overhead ===
String replacement (built-in): hello universe

Parsed filename:
  Full: /path/to/file.txt
  Base: file.txt
  Ext:  txt

Arithmetic sum (built-in): 499500

=== Memory-Efficient Patterns ===

=== Memory-Efficient Processing ===
Processed 10000 lines with minimal memory

Complex calculation with awk:
Mean: 5000.5
StdDev: 2886.89...

Cleaned up temporary files

=== Performance Tips Summary ===
1. Use built-in commands (echo, printf, read, [[ ]]) over external tools
2. Avoid subshells with $() when possible - use parameter expansion
...
```

**Key Points:**
- Configure `ExecutionLimits` appropriate for your workload size
- Use built-in commands over external tools when possible
- Stream large files instead of loading entirely into memory
- Batch operations to reduce overhead
- Use `awk` for complex numeric processing
- Leverage parameter expansion to avoid subshells
- Clean up temporary files to manage memory

---

## Additional Resources

- [README.md](../README.md) - Full API documentation
- [Tests](../Tests/) - Extensive test examples
- [Apple Documentation](https://developer.apple.com/documentation) - Swift concurrency patterns

## Contributing

When adding new recipes:
1. Include a clear problem statement
2. Provide complete, tested Swift code
3. Show expected output
4. Explain key points and performance considerations
5. Test that examples compile and run

---

*This cookbook is part of the just-bash-swift project. For issues or contributions, please refer to the project repository.*
