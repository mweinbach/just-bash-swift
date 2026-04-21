# Migrating from Bash to JustBash

A practical guide for transitioning bash scripts to run in the JustBash sandboxed environment.

## Table of Contents

1. [Overview](#overview)
2. [Compatible Features](#compatible-features)
3. [Known Differences](#known-differences)
4. [Limitations](#limitations)
5. [Migration Examples](#migration-examples)
6. [Common Pitfalls](#common-pitfalls)
7. [Testing Strategy](#testing-strategy)
8. [Performance Notes](#performance-notes)

---

## Overview

### Why Migrate?

JustBash provides a **sandboxed, embeddable** bash environment for Apple platforms (iOS, macOS, iPadOS) where traditional `Process`/`NSTask` aren't available. Key benefits:

- **No external dependencies**: Pure Swift implementation, no real bash binary needed
- **Sandboxed by design**: All execution happens in-process with virtual filesystem
- **AI-safe**: Controlled environment for agent/AI workloads with execution limits
- **Cross-platform**: Works on iOS/iPadOS where traditional shells can't run

### What to Expect

| Aspect | Traditional Bash | JustBash |
|--------|------------------|----------|
| Execution | External process | In-process Swift interpreter |
| Filesystem | Real disk | In-memory virtual filesystem |
| Commands | System binaries | Swift-implemented equivalents |
| Networking | Full access | Simulated (`curl`) only |
| Job control | Full support | Not available |
| Performance | Process overhead | Faster for small scripts |

### Migration Mindset

Most **pure bash** scripts will run with minimal changes. Scripts that:
- ✅ Manipulate files and text
- ✅ Use standard utilities (grep, sed, awk)
- ✅ Perform data processing

Will migrate easily. Scripts that:
- ❌ Launch background processes (`&`)
- ❌ Access network resources
- ❌ Rely on specific system binaries

Will need adjustments.

---

## Compatible Features

The following features work **identically** to traditional bash:

### Shell Syntax

| Feature | Example | Status |
|---------|---------|--------|
| Variables | `name="value"`, `$name`, `${name}` | ✅ Identical |
| Arrays | `arr=(a b c)`, `${arr[0]}`, `${#arr[@]}` | ✅ Identical |
| Associative arrays | `declare -A map`, `${map[key]}` | ✅ Identical |
| Arithmetic | `$((1 + 2))`, `((x++))` | ✅ Identical |
| Conditionals | `if`, `case`, `[[ ]]` | ✅ Identical |
| Loops | `for`, `while`, `until` | ✅ Identical |
| Functions | `myfunc() { ... }` | ✅ Identical |
| Pipes | `cmd1 \| cmd2` | ✅ Identical |
| Redirections | `>`, `>>`, `<`, `2>`, `<<<` | ✅ Identical |
| Command substitution | `$(cmd)`, `` `cmd` `` | ✅ Identical |
| Brace expansion | `{a,b,c}`, `{1..10}` | ✅ Identical |
| Glob patterns | `*`, `?`, `[abc]` | ✅ Identical |
| Extended globs | `?(pat)`, `*(pat)`, `+(pat)` | ✅ With `shopt -s extglob` |
| Quoting | `'literal'`, `"$var"`, `$'ANSI-C'` | ✅ Identical |
| Heredocs | `<<EOF ... EOF` | ✅ Identical |
| Process substitution | `<(cmd)`, `>(cmd)` | ✅ Via VFS temp files |

### Shell Builtins

All standard builtins work as expected:

```bash
# Variable management
export VAR=value
local var=value
declare -i integer_var
declare -A assoc_array
readonly CONST=value

# Control flow
return 0
exit 1
break
continue

# I/O
echo "text"
printf "Format: %s\n" "value"
read -r line
readarray lines < file

# File operations
cd /path
pwd

# Evaluation
eval "cmd"
source script.sh

# Utility
test -f file
[ -d dir ]
shift
set -e
```

### External Commands

40+ commands are implemented:

```bash
# File/text processing
cat, grep, sed, awk, sort, uniq, tr, cut, wc
head, tail, tac, rev, fold, nl, paste, join

# File system
ls, mkdir, rm, cp, mv, touch, find, du, stat
cd, pwd, pushd, popd, dirs

# Data processing
jq, yq, xan, sqlite3, tar, gzip, gunzip

# Information
uname, whoami, date, env, printenv
```

---

## Known Differences

These are **intentional design differences** between JustBash and traditional bash:

### 1. No External Processes

**Difference**: Everything runs in-process. No real `fork()` or `exec()`.

**Impact**: 
- No actual process IDs (`$$` is virtual)
- Commands are Swift implementations, not system binaries
- Slightly different error messages in some cases

**Migration**: Usually transparent, but don't rely on binary-specific behavior:

```bash
# ❌ Don't rely on GNU-specific extensions
sed -i 's/foo/bar/' file    # May not work exactly like GNU sed

# ✅ Use portable syntax
sed 's/foo/bar/' file > file.tmp && mv file.tmp file
```

### 2. Virtual Filesystem Only

**Difference**: By default, all file operations happen in memory.

**Impact**:
- Files created in one `exec()` call persist to the next
- No access to real system files (`/etc/passwd`, etc.)
- Filesystem resets when `Bash` instance is destroyed

**Migration**: Pre-populate needed files:

```swift
// ✅ Seed files at initialization
let bash = Bash(options: .init(
    files: [
        "/etc/config.json": loadConfig(),
        "/data/input.txt": loadData()
    ]
))
```

Or use a custom filesystem backend (see [Filesystem Abstraction](../README.md#filesystem-abstraction)).

### 3. Limited Alias Expansion

**Difference**: Only command-position aliases work; no trailing-blank expansion.

**Impact**:
```bash
# ✅ Works: command position
alias ll='ls -la'
ll /home    # Expands to: ls -la /home

# ❌ Doesn't work: trailing blank alias
alias sudo='sudo '          # Space after sudo
sudo ll /home               # ll won't expand in bash either
                            # But in JustBash, no support for this pattern

# ❌ Doesn't work: self-referential
alias ls='ls -F'            # Hits recursion limit
```

**Migration**: Use functions instead of aliases:

```bash
# ✅ Use functions for complex cases
my_ls() {
    ls -la "$@"
}
```

### 4. No Job Control

**Difference**: Background processes (`&`), `fg`, `bg`, `jobs` not supported.

**Impact**:
```bash
# ❌ Won't work
long_running_task &
wait $!

# ❌ Won't work
vim file.txt
# (Can't suspend/background)
```

**Migration**: Sequential execution or Swift-side concurrency:

```swift
// ✅ Swift-side parallelism
async let task1 = bash.exec("process file1")
async let task2 = bash.exec("process file2")
let (r1, r2) = await (task1, task2)
```

### 5. Simulated Networking

**Difference**: `curl` exists but doesn't make real HTTP requests in sandbox.

**Impact**:
```bash
# curl is available for script compatibility
curl -s https://api.example.com/data.json
# But by default, this returns simulated/empty data
```

**Migration**: Use custom commands for network access:

```swift
let bash = Bash(options: .init(
    customCommands: [
        AnyBashCommand(name: "curl") { args, ctx in
            // Implement real network call here
            let data = await fetchFromNetwork(args)
            return ExecResult.success(data)
        }
    ]
))
```

### 6. select Auto-Selects First Option

**Difference**: In sandbox mode, `select` automatically chooses the first option.

**Impact**:
```bash
select choice in "option1" "option2" "option3"; do
    echo "You chose: $choice"
done
# Always outputs "You chose: option1"
```

**Migration**: Don't use `select` for interactive prompts. Use it only for:
- Script compatibility
- Non-interactive default selection

```bash
# ✅ For non-interactive default
select default in "$@"; do
    process "$default"
    break
done
```

### 7. trap Registers but Doesn't Fire

**Difference**: `trap` stores handlers but signals never fire in sandbox.

**Impact**:
```bash
trap 'cleanup' EXIT
# Handler is registered but won't be called

trap 'echo "Ctrl+C"' INT
# Won't fire - sandbox has no real signals
```

**Migration**: Use explicit cleanup:

```bash
# ✅ Explicit cleanup at end
main_work
cleanup
```

Or use Swift's error handling:

```swift
do {
    let result = try await bash.exec(script)
} catch {
    // Swift-level cleanup
}
```

---

## Limitations

These features are **not supported** in JustBash:

### Not Supported

| Feature | Example | Workaround |
|---------|---------|------------|
| Job control | `&`, `fg`, `bg`, `jobs` | Sequential execution |
| Real signals | `kill`, signal handlers | Explicit error handling |
| Real processes | `ps`, `top`, `pgrep` | Not applicable |
| System calls | `mount`, `mkfs`, `insmod` | Not applicable |
| TTY control | `stty`, terminal modes | Not applicable |
| Sockets | `/dev/tcp/host/port` | Custom commands |
| Coprocesses | `coproc` | Pipes or Swift concurrency |

### Partially Supported

| Feature | Support | Notes |
|---------|---------|-------|
| `shopt` | Most options | `extglob`, `nullglob`, `pipefail` work |
| `set` | Most options | `-e`, `-u`, `-x`, `-C` work |
| `getopts` | Basic support | Standard option parsing works |
| `declare` | Most flags | `-a`, `-A`, `-i`, `-n`, `-r`, `-x` work |

### Deferrals

Per [ROADMAP.md](../ROADMAP.md), these are explicitly deferred:

- Embedded JS/Python runtimes
- Mountable filesystem backends (beyond the `BashFilesystem` protocol)
- Full interactive mode

---

## Migration Examples

### Example 1: Simple Data Processing

**Before (bash)**:
```bash
#!/bin/bash
# Process log file and extract errors

INPUT="/var/log/app.log"
OUTPUT="/tmp/errors.txt"

# Extract error lines
grep "ERROR" "$INPUT" > "$OUTPUT"

# Count by category
count=$(grep -c "ERROR" "$OUTPUT")
echo "Found $count errors"

# Show first 10
head -10 "$OUTPUT"
```

**After (JustBash)**:
```swift
import JustBash

let bash = Bash(options: .init(
    files: [
        "/var/log/app.log": loadLogContents()  // Seed from real source
    ]
))

let result = await bash.exec("""
    INPUT="/var/log/app.log"
    OUTPUT="/tmp/errors.txt"
    
    grep "ERROR" "$INPUT" > "$OUTPUT"
    
    count=$(grep -c "ERROR" "$OUTPUT")
    echo "Found $count errors"
    
    head -10 "$OUTPUT"
""")

print(result.stdout)
```

### Example 2: CSV Processing Pipeline

**Before (bash)**:
```bash
#!/bin/bash
# Process sales data

cd /data

# Filter and sort
cat sales.csv | \
    awk -F',' '$3 > 100 {print $1, $2, $3}' | \
    sort -k3 -n > high_value.txt

# Calculate total
total=$(awk '{sum+=$3} END {print sum}' high_value.txt)
echo "Total: $total"
```

**After (JustBash)**:
```swift
let bash = Bash(options: .init(
    files: ["/data/sales.csv": salesData],
    cwd: "/data"
))

let result = await bash.exec("""
    cat sales.csv | \\
        awk -F',' '$3 > 100 {print $1, $2, $3}' | \\
        sort -k3 -n > high_value.txt
    
    total=$(awk '{sum+=$3} END {print sum}' high_value.txt)
    echo "Total: $total"
""")
```

### Example 3: JSON Processing with jq

**Before (bash)**:
```bash
#!/bin/bash
# API response processing

curl -s https://api.example.com/users | \
    jq '.users[] | select(.active == true) | .name' > active_users.txt

count=$(wc -l < active_users.txt)
echo "Active users: $count"
```

**After (JustBash)**:
```swift
// Seed with API data
let apiData = await fetchUsersFromAPI()  // Swift networking

let bash = Bash(options: .init(
    files: ["/tmp/api_response.json": apiData]
))

let result = await bash.exec("""
    cat /tmp/api_response.json | \\
        jq '.users[] | select(.active == true) | .name' > active_users.txt
    
    count=$(wc -l < active_users.txt)
    echo "Active users: $count"
""")
```

### Example 4: Multi-File Processing

**Before (bash)**:
```bash
#!/bin/bash
# Batch process files

for file in /data/*.txt; do
    echo "Processing: $file"
    
    # Transform
    sed 's/old/new/g' "$file" > "${file%.txt}.out"
    
    # Verify
    if diff -q "$file" "${file%.txt}.out" > /dev/null; then
        echo "  No changes"
    else
        echo "  Updated"
    fi
done
```

**After (JustBash)**:
```swift
let fileContents = loadFiles()  // Dictionary of filename: content

let bash = Bash(options: .init(
    files: fileContents.mapKeys { "/data/\($0)" }
))

let result = await bash.exec("""
    for file in /data/*.txt; do
        echo "Processing: $file"
        
        sed 's/old/new/g' "$file" > "${file%.txt}.out"
        
        if diff -q "$file" "${file%.txt}.out" > /dev/null; then
            echo "  No changes"
        else
            echo "  Updated"
        fi
    done
""")
```

### Example 5: Error Handling

**Before (bash)**:
```bash
#!/bin/bash
set -e

cleanup() {
    echo "Cleaning up..."
    rm -f /tmp/temp.*
}
trap cleanup EXIT

process_data || {
    echo "Processing failed"
    exit 1
}

echo "Success"
```

**After (JustBash)**:
```swift
let bash = Bash()

// trap won't fire, so use explicit cleanup
let result = await bash.exec("""
    set -e
    process_data || {
        echo "Processing failed"
        exit 1
    }
    echo "Success"
""")

// Swift-level cleanup
if result.exitCode == 0 {
    print("Success")
} else {
    print("Processing failed: \(result.stderr)")
}

// No automatic cleanup - manage in Swift
```

---

## Common Pitfalls

### Pitfall 1: Expecting Real Filesystem Access

**Problem**: Script tries to read system files.

```bash
# ❌ Won't find real system files
username=$(whoami)           # Returns "user" (virtual)
home=$(cat /etc/passwd | grep $username)  # File doesn't exist
```

**Solution**: Pre-populate or mock system files:

```swift
let bash = Bash(options: .init(
    files: [
        "/etc/passwd": "user:x:1000:1000:user:/home/user:/bin/bash"
    ],
    env: ["USER": "current_user"]
))
```

### Pitfall 2: Relying on GNU-Specific Behavior

**Problem**: GNU extensions not implemented.

```bash
# ❌ GNU-specific
grep -P '\d+' file.txt       # -P for PCRE
sed -i 's/foo/bar/' file     # in-place edit
```

**Solution**: Use portable syntax:

```bash
# ✅ Portable
grep -E '[0-9]+' file.txt
sed 's/foo/bar/' file > file.tmp && mv file.tmp file
```

### Pitfall 3: Background Processes

**Problem**: Trying to use `&` for parallelism.

```bash
# ❌ Won't parallelize
generate_report &
generate_summary &
wait
```

**Solution**: Use Swift concurrency:

```swift
// ✅ Parallel in Swift
async let r1 = bash.exec("generate_report")
async let r2 = bash.exec("generate_summary")
let (result1, result2) = await (r1, r2)
```

### Pitfall 4: Interactive Prompts

**Problem**: Scripts with user interaction hang.

```bash
# ❌ Hangs waiting for input
read -p "Continue? (y/n) " answer
```

**Solution**: Non-interactive or pre-set answers:

```bash
# ✅ Non-interactive with default
answer="${ANSWER:-y}"
```

Or pass via stdin:

```swift
let result = await bash.exec(
    "read answer; echo $answer",
    options: .init(stdin: "y\n")
)
```

### Pitfall 5: Shell State Leaks

**Problem**: Expecting environment changes to persist.

```bash
# First call
export VAR=value
cd /somewhere

# Second call - VAR and cd are reset!
echo "$VAR"   # Empty
pwd            # /home/user (not /somewhere)
```

**Solution**: Set environment per-call or use single script:

```swift
// ✅ Set per-call
let result = await bash.exec(cmd, options: .init(
    env: ["VAR": "value"],
    cwd: "/somewhere"
))

// ✅ Or use single script
let result = await bash.exec("""
    export VAR=value
    cd /somewhere
    # ... rest of script
""")
```

### Pitfall 6: Large File Processing

**Problem**: Hitting execution limits.

```bash
# ❌ May exceed maxOutputLength (1MB default)
cat huge_file.txt
```

**Solution**: Stream processing or increase limits:

```swift
// ✅ Increase limits
let bash = Bash(options: .init(
    executionLimits: .init(
        maxOutputLength: 10 * 1024 * 1024  // 10MB
    )
))
```

Or process in chunks within the script.

### Pitfall 7: Self-Referential Aliases

**Problem**: Alias recursion hits depth limit.

```bash
# ❌ Recursion limit (16 levels)
alias ls='ls -la'
ls  # Expands: ls -la -> ls -la -la -> ... (fails at depth 16)
```

**Solution**: Use functions:

```bash
# ✅ Function instead
ls() {
    command ls -la "$@"
}
```

---

## Testing Strategy

### Phase 1: Compatibility Testing

Test existing scripts without modification:

```swift
import JustBash
import XCTest

class MigrationTests: XCTestCase {
    func testExistingScript() async throws {
        let bash = Bash(options: .init(
            files: loadTestData()
        ))
        
        let script = loadExistingBashScript()
        let result = await bash.exec(script)
        
        // Check exit code
        XCTAssertEqual(result.exitCode, 0, "Script failed: \(result.stderr)")
        
        // Check output
        XCTAssertEqual(result.stdout, expectedOutput)
    }
}
```

### Phase 2: Incremental Migration

1. **Start with read-only operations**:
   ```bash
   # Test that basic parsing works
   echo "test"
   var="value"
   echo "$var"
   ```

2. **Add file operations**:
   ```bash
   # Seed test files
   echo "input" > /tmp/test.txt
   cat /tmp/test.txt
   ```

3. **Test complex pipelines**:
   ```bash
   cat file | grep pattern | sort | uniq -c
   ```

### Phase 3: Validation

Compare outputs between bash and JustBash:

```swift
func verifyParity(bashScript: String) async throws {
    // Run in system bash
    let systemResult = runInRealBash(bashScript)
    
    // Run in JustBash
    let bash = Bash(options: .init(files: testFiles))
    let justBashResult = await bash.exec(bashScript)
    
    // Compare
    XCTAssertEqual(systemResult.exitCode, justBashResult.exitCode)
    XCTAssertEqual(systemResult.stdout, justBashResult.stdout)
}
```

### Phase 4: Edge Case Testing

Test known differences:

```swift
func testTrapRegistration() async {
    let bash = Bash()
    let result = await bash.exec("""
        trap 'echo caught' EXIT
        echo "trap set"
    """)
    
    // Trap won't fire, but won't error either
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "trap set\n")
}
```

### Testing Checklist

- [ ] Basic syntax (variables, loops, conditionals)
- [ ] File operations (read, write, glob)
- [ ] Pipelines and redirections
- [ ] Command substitution
- [ ] Arrays (indexed and associative)
- [ ] Functions
- [ ] External commands (grep, sed, awk, etc.)
- [ ] Error handling
- [ ] Edge cases (empty input, special characters)

---

## Performance Notes

### Speed Expectations

| Operation | JustBash | Traditional Bash | Notes |
|-----------|----------|------------------|-------|
| Simple echo | ~0.1ms | ~5ms | No process overhead |
| File I/O | ~0.5ms | ~2ms | In-memory, no disk |
| Complex pipeline | ~5-10ms | ~20ms | In-process pipes |
| Large file processing | Similar | Similar | Memory-bound |
| Startup time | ~0ms | ~5-10ms | No process spawn |

### Performance Characteristics

**Faster than traditional bash for:**
- Small, frequent invocations (no fork overhead)
- Multiple command pipelines (in-process)
- File operations (in-memory)

**Similar to traditional bash for:**
- Large file processing
- CPU-intensive operations (sorting, regex)

**Considerations:**
- Memory usage: All files stored in memory
- No I/O parallelism for disk operations (no real disk)
- Interpreter overhead vs compiled binaries

### Optimization Tips

1. **Batch operations**: Fewer `exec()` calls = less overhead
   ```swift
   // ✅ One call
   let result = await bash.exec("""
       cmd1
       cmd2
       cmd3
   """)
   
   // ❌ Three calls (more overhead)
   await bash.exec("cmd1")
   await bash.exec("cmd2")
   await bash.exec("cmd3")
   ```

2. **Minimize filesystem size**: Large virtual filesystems consume memory

3. **Use built-in commands**: `echo`, `printf` are faster than `cat <<EOF`

4. **Avoid deep nesting**: Each `$(...)` adds substitution overhead

---

## Summary

### Migration Readiness Checklist

- [ ] Identify scripts using unsupported features (job control, real signals)
- [ ] Plan filesystem seeding strategy
- [ ] Replace aliases with functions where needed
- [ ] Move networking out of scripts (to Swift)
- [ ] Test with representative data
- [ ] Verify error handling works correctly

### Quick Reference

| If you need... | Use... |
|----------------|--------|
| File processing | ✅ JustBash |
| Text manipulation | ✅ JustBash |
| Data pipelines | ✅ JustBash |
| Background jobs | ❌ Swift concurrency |
| Network access | ❌ Swift networking |
| Real system files | ❌ Custom filesystem backend |
| Interactive prompts | ❌ Pre-set inputs |

---

## Support

- **Issues**: Check [ROADMAP.md](../ROADMAP.md) for known limitations
- **Examples**: See [COOKBOOK.md](COOKBOOK.md) for practical patterns
- **Architecture**: See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation details
