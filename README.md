# just-bash-swift

A pure Swift bash interpreter for AI agent sandboxing on iOS, macOS, and iPadOS. No VMs, no containers, no real bash needed — everything runs in-process with an in-memory virtual filesystem.

Inspired by [Vercel's just-bash](https://github.com/vercel-labs/just-bash) (TypeScript). This is a ground-up Swift rewrite targeting Apple platforms where `Process`/`NSTask` aren't available (iOS/iPadOS).

This repo is intentionally library-first. The current goal is a correct, embeddable shell sandbox for Apple platforms; broader parity work and any example host app stay secondary until the runtime contract is tighter. [ROADMAP.md](ROADMAP.md) tracks that staged backlog.

## Quick Start

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/mweinbach/just-bash-swift.git", branch: "main")
```

```swift
import JustBash

let bash = Bash(options: .init(
    files: ["/data/input.txt": "hello world"],
    env: ["NAME": "Agent"]
))

let result = await bash.exec("""
    echo "Hello, $NAME!"
    for f in /data/*.txt; do
        echo "Processing: $(basename $f)"
        wc -w "$f"
    done
""")

print(result.stdout)  // Hello, Agent!\nProcessing: input.txt\n1 /data/input.txt\n
print(result.exitCode) // 0
```

## Architecture

Four modules, zero dependencies beyond Foundation:

```
┌─────────────┐
│   JustBash   │  Public API: Bash actor, BashOptions, ExecOptions
├─────────────┤
│ JustBashCore │  Parser (recursive descent), Interpreter (tree-walking),
│              │  AST types, ShellSession, Arithmetic evaluator
├─────────────┤
│JustBashCmds │  70+ commands: grep, sed, awk, jq, yq, xan, zip, sqlite3, etc.
├─────────────┤
│  JustBashFS  │  In-memory virtual filesystem with /proc, /dev layout
└─────────────┘
```

**Execution pipeline:** `Input → Tokenizer → Parser → AST → Interpreter → Output`

- The **tokenizer** handles comments, quoting (single, double, `$'...'`, ANSI-C), `$()`, `$(())`, backticks, heredocs, all operators
- The **parser** is a recursive descent parser producing a rich AST with compound commands
- The **interpreter** is a tree-walking executor with word expansion, arithmetic evaluation, and control flow
- The **filesystem** is a tree-based in-memory VFS with a seeded Linux-like layout (`/proc`, `/dev`, `/home/user`, etc.)

## Current Scope

- Fully in-process execution through the Swift parser, interpreter, builtins, and virtual commands
- Shared in-memory filesystem across `exec()` calls, with fresh shell state per call
- Pluggable filesystem backends via the `BashFilesystem` protocol (default: `VirtualFileSystem`)
- Optional embedded language runtimes via the `EmbeddedRuntime` protocol (see [Optional Products](#optional-products))
- Selective, test-driven parity with upstream `just-bash`, not line-for-line feature parity yet

## Optional Products

The package ships additional opt-in products you can depend on alongside the
core `JustBash` library. They are not loaded unless you reference them.

### `JustBashJavaScript`

Adds a `js-exec` command backed by Apple's system JavaScriptCore framework.

```swift
.product(name: "JustBashJavaScript", package: "just-bash-swift")
```

```swift
import JustBash
import JustBashJavaScript

let bash = Bash(options: .init(embeddedRuntimes: [
    JavaScriptRuntime(options: BashJavaScriptOptions(
        bootstrap: "globalThis.APP_NAME = 'demo';"
    ))
]))

let result = await bash.exec(#"""
    js-exec -c 'console.log("hi from", APP_NAME)'
"""#)
print(result.stdout)  // "hi from demo\n"
```

Node-compat surface: `fs` (sync subset + `.promises.*`), `path`, `process`,
`console`, `Buffer`, `URL`, `URLSearchParams`, `child_process` (`execSync`,
`spawnSync` route through `ctx.executeSubshell`), `fetch` (gated by
`allowedURLPrefixes`), plus pure-JS shims for `os`, `assert`, `util`, `events`,
`stream`, `string_decoder`, `querystring`. Modules registered via
`BashJavaScriptOptions.addonModules` are discoverable through `require()`.

**Caveats**: JavaScriptCore JIT is enabled on macOS but disabled on iOS / Mac
Catalyst (no JIT entitlement for non-WebKit apps), so iOS execution runs in
LLInt interpreter mode — roughly 5–10× slower than macOS for compute-heavy
scripts. Memory limits are advisory on Apple platforms; the wall-clock timeout
is enforced (default 10s, 60s when `allowedURLPrefixes` is non-empty).

## What's Supported

Everything in this section is intended to describe implemented behavior in the current package, not future roadmap work.

### Shell Features

| Feature | Status |
|---|---|
| **Pipes & redirections** | `\|`, `|&`, `>`, `>>`, `<`, `2>`, `>&`, `<&`, `>|`, `<<<`, `<<` |
| **Logic operators** | `&&`, `\|\|`, `!` (pipeline negation) |
| **Control flow** | `if/elif/else/fi`, `for/do/done`, `while/until`, `case/esac`, `select` |
| **Functions** | `name() { ... }`, `function name { ... }`, local scoping, `return` |
| **Subshells** | `( ... )` — isolated environment |
| **Brace groups** | `{ ...; }` |
| **Brace expansion** | `{a,b}`, `{1..5}`, `{1..9..2}`, `{a..z}`, nested brace expansion in literal word segments |
| **Command substitution** | `$(...)`, `` `...` `` |
| **Arithmetic** | `$(( ))`, `(( ))` — full precedence: `**`, `*/%`, `+-`, shifts, bitwise, comparison, logical, ternary |
| **Process substitution** | `<(cmd)`, `>(cmd)` via VFS temp files |
| **Conditionals** | `[[ ]]` — file tests (`-f`, `-d`, `-e`, `-nt`, `-ot`, `-ef`), string comparison, regex `=~`, `-eq`/`-ne`/`-lt`/etc. |
| **test / [** | Unary and binary operators |
| **Quoting** | Single, double, `$'...'` (ANSI-C), `\\` escaping |
| **Variables** | `$var`, `${var}`, assignment, `+=`, command-scoped (`VAR=x cmd`), indexed and associative array assignment and element assignment |
| **Special vars** | `$?`, `$#`, `$@`, `$*`, `$$`, `$!`, `$0`, `$-`, `$_`, `$RANDOM`, `$FUNCNAME`, `$BASH_VERSION`, `$PIPESTATUS`, `$HOSTNAME`, `$SECONDS`, `$LINENO` |
| **Expansions** | `${var:-default}`, `${var:=}`, `${var:+}`, `${var:?}`, `${#var}`, `${var:off:len}`, `${var#pat}`, `${var##}`, `${var%}`, `${var%%}`, `${var/p/r}`, `${var//p/r}`, `${var^}`, `${var^^}`, `${var,}`, `${var,,}`, `${!var}` (indirect), `${!prefix*}`, `${!prefix@}`, `${var@Q}`, `${var@E}`, `${var@A}`, `${arr[n]}`, `${arr[@]}`, `${arr[*]}`, `${#arr[@]}`, `${!arr[@]}`, `${map[key]}`, `${map[key]:-default}`, `${#map[key]}` |
| **Tilde expansion** | `~`, `~user` |
| **Field splitting** | Unquoted expansion splits on `IFS` |
| **Glob patterns** | `*`, `?`, `[abc]`, `[a-z]`, extended globs (`?(pat)`, `*(pat)`, `+(pat)`, `@(pat)`, `!(pat)`) via virtual filesystem |
| **Heredocs** | `<< EOF`, `<<- EOF` (tab stripping), quoted delimiters suppress expansion |
| **Here-strings** | `<<<` |
| **Comments** | `# ...` |
| **Shell options** | `set -e`, `set -u`, `set -x`, `set -f`, `set -C`, `set -o pipefail`; `shopt` options: `extglob`, `nullglob`, `globstar`, `dotglob`, `nocaseglob`, `nocasematch`, `lastpipe`, `expand_aliases` |
| **Nameref** | `declare -n ref=target` — transparent variable aliasing |
| **Aliases** | `alias`/`unalias`, basic command-position alias expansion (see [Alias Expansion](#alias-expansion)) |

#### Alias Expansion

The shell supports basic alias expansion with the following behavior:

- Aliases are expanded in command position (first word of simple commands)
- Alias expansion must be enabled via `shopt -s expand_aliases` (off by default in non-interactive mode)
- Recursive alias chains are supported (e.g., `alias a=b; alias b='echo done'`)
- Arguments are passed through (e.g., `alias greet='echo'; greet hello` outputs "hello")
- Maximum alias expansion depth is 16 levels (cycle protection)

**Intentional Limitations:**

The following bash alias behaviors are intentionally not implemented to keep the runtime simple and predictable:

1. **Self-referential aliases**: `alias ls='ls -F'` will hit the depth limit instead of working as in bash. Use the full command with flags instead.

2. **Trailing-blank multi-word aliases**: Aliases ending with a space that enable expansion of the following word are not supported. Use shell functions for multi-word command substitutions.

3. **Same-line definition timing**: In bash, an alias defined on the same line as its use does not take effect until the next line. Our implementation applies aliases immediately.

For complex command substitutions, shell functions are recommended over aliases.

### Commands

**Shell builtins:** `cd`, `pwd`, `echo`, `printf`, `env`, `printenv`, `which`/`type`, `true`, `false`, `export`, `unset`, `local`, `declare`/`typeset`, `read`, `set`, `shift`, `return`, `exit`, `break`, `continue`, `test`/`[`, `eval`, `source`/`.`, `trap`, `alias`, `unalias`, `:`, `command`, `let`, `getopts`, `mapfile`/`readarray`, `pushd`, `popd`, `dirs`, `builtin`, `hash`, `exec`, `readonly`, `shopt`, `wait`, `select`

**External commands:** `cat`, `tee`, `ls`, `mkdir`, `mktemp`, `touch`, `rm`, `rmdir`, `cp`, `mv`, `ln`, `chmod`, `stat`, `tree`, `split`, `find`, `du`, `realpath`, `readlink`, `basename`, `dirname`, `file`, `strings`, `grep`, `egrep`, `fgrep`, `rg`, `sed`, `awk`, `sort`, `uniq`, `tr`, `cut`, `paste`, `join`, `wc`, `head`, `tail`, `tac`, `rev`, `nl`, `fold`, `expand`, `unexpand`, `column`, `od`, `seq`, `yes`, `bc`, `base64`, `expr`, `md5sum`, `sha1sum`, `sha256sum`, `gzip`, `gunzip`, `zcat`, `tar`, `sqlite3`, `jq`, `yq`, `xan`, `curl`, `html-to-markdown`, `xargs`, `diff`, `comm`, `date`, `sleep`, `uname`, `hostname`, `whoami`, `clear`, `help`, `history`, `bash`, `sh`, `time`, `timeout`

### Execution Limits

| Limit | Default |
|---|---|
| Max input size | 256 KB |
| Max tokens | 16,000 |
| Max commands | 10,000 |
| Max output | 1 MB |
| Max pipeline depth | 32 |
| Max call depth | 100 |
| Max loop iterations | 10,000 |
| Max substitution depth | 50 |

All configurable via `ExecutionLimits`.

### Custom Commands

```swift
let bash = Bash(options: .init(
    customCommands: [
        AnyBashCommand(name: "greet") { args, ctx in
            ExecResult.success("Hello, \(args.joined(separator: " "))!\n")
        }
    ]
))
let result = await bash.exec("greet World")
// stdout: "Hello, World!\n"
```

### Filesystem Abstraction

By default, `Bash` uses an in-memory `VirtualFileSystem`. You can inject a custom filesystem implementation by conforming to the `BashFilesystem` protocol:

```swift
import JustBashFS

struct LoggingFilesystem: BashFilesystem {
    private let wrapped: BashFilesystem
    private let logger: (String) -> Void
    
    init(wrapping filesystem: BashFilesystem, logger: @escaping (String) -> Void) {
        self.wrapped = filesystem
        self.logger = logger
    }
    
    func readFile(path: String, relativeTo: String) throws -> Data {
        logger("[FS] read: \(path)")
        return try wrapped.readFile(path: path, relativeTo: relativeTo)
    }
    
    func writeFile(path: String, content: Data, relativeTo: String) throws {
        logger("[FS] write: \(path) (\(content.count) bytes)")
        try wrapped.writeFile(path: path, content: content, relativeTo: relativeTo)
    }
    
    // ... implement remaining protocol methods by delegating to wrapped
}

// Usage
let baseFS = VirtualFileSystem(initialFiles: ["/data/input.txt": "hello"])
let loggingFS = LoggingFilesystem(wrapping: baseFS) { log in
    print(log)
}

let bash = Bash(options: .init(filesystem: loggingFS))
let result = await bash.exec("cat /data/input.txt")
```

The `BashFilesystem` protocol requires methods for:
- **File operations**: `readFile`, `writeFile`, `deleteFile`
- **Path queries**: `fileExists`, `isDirectory`
- **Directory operations**: `listDirectory`, `createDirectory`
- **File info**: `fileInfo` (returns `FileInfo` with path, kind, size)
- **Tree walking**: `walk` (depth-first traversal)
- **Path normalization**: `normalizePath` (resolves relative paths, collapses `.` and `..`)
- **Glob matching**: `glob` (supports `*`, `?`, `[...]`, extended globs)

**Use cases for custom filesystems:**

| Use Case | Implementation Approach |
|----------|------------------------|
| **Read-only wrapper** | Reject write operations, delegate reads to underlying FS |
| **Logging layer** | Wrap an existing FS and log all operations |
| **Filtering** | Block access to sensitive paths by checking path prefixes |
| **Remote storage** | Back filesystem operations with S3, Redis, or database |
| **Quota enforcement** | Track total size in writes, throw `ioError` when limit exceeded |
| **Audit trail** | Record all file operations for compliance |

**Note:** All filesystem implementations must be `Sendable` and handle their own synchronization for thread safety.

## API Reference

### `Bash` (actor)

```swift
// Initialize with options
let bash = Bash(options: BashOptions(
    files: ["/path": "content"],   // Pre-populate filesystem
    env: ["KEY": "value"],         // Environment variables
    cwd: "/home/user",             // Working directory
    executionLimits: .init(),      // Safety limits
    customCommands: [],            // Additional commands
    processInfo: .init()           // Virtual PID/UID
))

// Execute a script
let result = await bash.exec("echo hello", options: ExecOptions(
    env: [:],            // Additional env vars for this call
    replaceEnv: false,   // Replace base env instead of merging
    cwd: nil,            // Override working directory
    stdin: ""            // Stdin data
))

// Access the virtual filesystem
let content = try bash.readFile("/path/to/file")
let entries = try bash.listDirectory("/")
```

### `ExecResult`

```swift
result.stdout    // String — captured stdout
result.stderr    // String — captured stderr
result.exitCode  // Int — 0 for success
```

### Filesystem behavior

- Filesystem **persists across `exec()` calls** — files written in one call are readable in the next
- Environment and cwd **reset between calls** — `export` and `cd` don't leak
- Each `exec()` gets a fresh `ShellSession` but shares the `VirtualFileSystem`

## Platform Support

| Platform | Minimum Version |
|---|---|
| iOS | 18.0 |
| macOS | 15.0 |
| Mac Catalyst | 18.0 |

Swift 6.0+ with strict concurrency.

## Testing

```bash
swift test
```

270+ tests covering: 60+ commands, control flow, functions, alias expansion, brace expansion, command substitution, heredocs, variable operations, indexed and associative array support, shell builtins parity, arithmetic, conditionals, pipes, `|&`, redirections, output limits, nounset, noclobber, field splitting, glob character classes, expanded utility command coverage, gzip-family and zip compression, tar archives, sqlite3 support, jq and yq support (including try/catch, type filters, del, XML output), xan CSV processing, readonly/shopt behavior, `select` loops, `trap` registration, dynamic variables (`$RANDOM`, `$BASH_VERSION`, `$HOSTNAME`, `$SECONDS`, `$LINENO`), `printf -v`, `read -a`, `declare -p`, filesystem persistence, session isolation, custom filesystem abstraction, curated parity cases, and fixture-driven parity suites for redirections, substitutions, globbing, aliases, parse errors, shell builtins, and advanced features.

## License

MIT
