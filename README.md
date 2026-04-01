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
│JustBashCmds │  40+ commands: grep, sed, awk, sort, tr, cut, find, etc.
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
- One filesystem backend today: `VirtualFileSystem`
- Selective, test-driven parity with upstream `just-bash`, not line-for-line feature parity yet

## What's Supported

Everything in this section is intended to describe implemented behavior in the current package, not future roadmap work.

### Shell Features

| Feature | Status |
|---|---|
| **Pipes & redirections** | `\|`, `|&`, `>`, `>>`, `<`, `2>`, `>&`, `<&`, `>|`, `<<<`, `<<` |
| **Logic operators** | `&&`, `\|\|`, `!` (pipeline negation) |
| **Control flow** | `if/elif/else/fi`, `for/do/done`, `while/until`, `case/esac` |
| **Functions** | `name() { ... }`, `function name { ... }`, local scoping, `return` |
| **Subshells** | `( ... )` — isolated environment |
| **Brace groups** | `{ ...; }` |
| **Brace expansion** | `{a,b}`, `{1..5}`, `{1..9..2}`, `{a..z}`, nested brace expansion in literal word segments |
| **Command substitution** | `$(...)`, `` `...` `` |
| **Arithmetic** | `$(( ))`, `(( ))` — full precedence: `**`, `*/%`, `+-`, shifts, bitwise, comparison, logical, ternary |
| **Conditionals** | `[[ ]]` — file tests, string comparison, regex `=~`, `-eq`/`-ne`/`-lt`/etc. |
| **test / [** | Unary and binary operators |
| **Quoting** | Single, double, `$'...'` (ANSI-C), `\\` escaping |
| **Variables** | `$var`, `${var}`, assignment, `+=`, command-scoped (`VAR=x cmd`), indexed and associative array assignment and element assignment |
| **Special vars** | `$?`, `$#`, `$@`, `$*`, `$$`, `$!`, `$0`, `$-` |
| **Expansions** | `${var:-default}`, `${var:=}`, `${var:+}`, `${var:?}`, `${#var}`, `${var:off:len}`, `${var#pat}`, `${var##}`, `${var%}`, `${var%%}`, `${var/p/r}`, `${var//p/r}`, `${var^}`, `${var^^}`, `${var,}`, `${var,,}`, `${arr[n]}`, `${arr[@]}`, `${arr[*]}`, `${#arr[@]}`, `${map[key]}` |
| **Tilde expansion** | `~`, `~user` |
| **Field splitting** | Unquoted expansion splits on `IFS` |
| **Glob patterns** | `*`, `?`, `[abc]`, `[a-z]` via virtual filesystem |
| **Heredocs** | `<< EOF`, `<<- EOF` (tab stripping), quoted delimiters suppress expansion |
| **Here-strings** | `<<<` |
| **Comments** | `# ...` |
| **Shell options** | enforced: `set -e`, `set -u`, `set -x`, `set -f`, `set -C`, `set -o pipefail` |
| **Aliases** | `alias`/`unalias`, basic command-position alias expansion |

### Commands

**Shell builtins:** `cd`, `pwd`, `echo`, `printf`, `env`, `printenv`, `which`/`type`, `true`, `false`, `export`, `unset`, `local`, `declare`/`typeset`, `read`, `set`, `shift`, `return`, `exit`, `break`, `continue`, `test`/`[`, `eval`, `source`/`.`, `trap`, `alias`, `unalias`, `:`, `command`, `let`, `getopts`, `mapfile`/`readarray`, `pushd`, `popd`, `dirs`, `builtin`, `hash`, `exec`, `readonly`, `shopt`

**External commands:** `cat`, `tee`, `ls`, `mkdir`, `touch`, `rm`, `rmdir`, `cp`, `mv`, `ln`, `chmod`, `stat`, `tree`, `split`, `find`, `du`, `realpath`, `readlink`, `basename`, `dirname`, `file`, `strings`, `grep`, `egrep`, `fgrep`, `rg`, `sed`, `awk`, `sort`, `uniq`, `tr`, `cut`, `paste`, `join`, `wc`, `head`, `tail`, `tac`, `rev`, `nl`, `fold`, `expand`, `unexpand`, `column`, `od`, `seq`, `yes`, `base64`, `expr`, `md5sum`, `sha1sum`, `sha256sum`, `gzip`, `gunzip`, `zcat`, `tar`, `sqlite3`, `jq`, `yq`, `curl`, `html-to-markdown`, `xargs`, `diff`, `comm`, `date`, `sleep`, `uname`, `hostname`, `whoami`, `clear`, `help`, `history`, `bash`, `sh`, `time`, `timeout`

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

119 tests covering: control flow, functions, alias expansion, brace expansion, command substitution, heredocs, variable operations, indexed and associative array support, shell builtins parity, arithmetic, conditionals, pipes, `|&`, redirections, output limits, nounset, noclobber, field splitting, glob character classes, expanded utility command coverage, gzip-family compression, tar archives, sqlite3 support, jq and yq support, readonly/shopt behavior, filesystem persistence, session isolation, and curated parity cases.

## License

MIT
