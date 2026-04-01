# Roadmap to Feature Parity with just-bash (TypeScript)

This document tracks the gap between [just-bash](https://github.com/vercel-labs/just-bash) (TypeScript) and this Swift implementation, with a prioritized roadmap for closing it.

## Current State

| Metric | just-bash (TS) | just-bash-swift | Parity |
|---|---|---|---|
| External commands | ~79 | 35 | 44% |
| Shell builtins | ~35 | 34 | 97% |
| Shell features | ~95% of bash | ~70% of bash | ~74% |
| Filesystem backends | 4 (InMemory, Overlay, ReadWrite, Mountable) | 1 (InMemory) | 25% |
| Execution limits | 18 categories | 8 categories | 44% |
| Test fixtures | ~4,000 lines across 28 categories | ~200 lines across 5 files | ~5% |

---

## Phase 1: Core Shell Correctness (HIGH PRIORITY)

These are bugs and missing features that affect correctness of basic bash scripts. Fix these first.

### 1.1 Fix Known Bugs

- [ ] **`removeSuffix` greedy/non-greedy** — both paths use same iteration order; greedy should iterate from longest suffix first
- [ ] **Output redirections use `rawText` instead of expanding** — `> $file` writes to literal `$file` instead of the variable's value
- [ ] **Alias expansion** — aliases are stored but never expanded during tokenization
- [ ] **`|&` (pipe stderr)** — parsed as token but pipeline execution only passes stdout
- [ ] **Heredoc quoted delimiter** — `heredocBody` carries a `quoted` flag but `expandHeredoc` always expands regardless
- [ ] **`nounset` (`set -u`)** — flag tracked but expansion never errors on unset variables
- [ ] **`pipefail`** — flag tracked but pipeline only returns last command's exit code
- [ ] **`maxOutputLength`** — defined in limits but never enforced
- [ ] **`noclobber` (`set -C`)** — `>` should fail when noclobber is set (only `>|` should bypass)
- [ ] **Field splitting** — `splitByIFS` exists but only used in `read`; unquoted expansions should split by IFS
- [ ] **Arithmetic assignment** — `+=`, `-=`, `++`, `--` are tokenized but don't mutate variables
- [ ] **Glob character classes** — `[abc]`, `[a-z]` in glob patterns (detected in `mayContainGlob` but not matched by `globMatch`)
- [ ] **`xtrace` (`set -x`)** — flag tracked but no trace output generated

### 1.2 Brace Expansion

Fundamental bash feature, completely absent:

- [ ] Comma form: `{a,b,c}` → `a b c`
- [ ] Sequence form: `{1..10}` → `1 2 3 ... 10`
- [ ] Sequence with step: `{1..10..2}` → `1 3 5 7 9`
- [ ] Alpha sequences: `{a..z}`
- [ ] Nested: `{a,b{1,2}}` → `a b1 b2`
- [ ] Preamble/postscript: `pre{a,b}post` → `preapost prebpost`

### 1.3 Missing Shell Builtins

- [ ] `shopt` — extglob, dotglob, nullglob, globstar, nocaseglob, nocasematch, expand_aliases
- [ ] `readonly` — mark variables as read-only
- [ ] `mapfile` / `readarray` — read stdin lines into an array
- [ ] `exec` — replace shell (in sandbox: could redirect fds)
- [ ] `pushd` / `popd` / `dirs` — directory stack
- [ ] `hash` — command path cache (can be a no-op)
- [ ] `builtin` — force builtin execution bypassing functions

### 1.4 Missing Variable Features

- [ ] `${!var}` — indirect expansion
- [ ] `${!prefix*}` / `${!prefix@}` — variable name expansion
- [ ] `$BASH_SOURCE` — current script name
- [ ] `$FUNCNAME` — current function name
- [ ] `$PIPESTATUS` — array of pipeline exit codes
- [ ] `$_` — last argument of previous command
- [ ] `$BASHPID`, `$PPID`, `$UID`, `$EUID`
- [ ] `$OSTYPE`, `$MACHTYPE`, `$HOSTTYPE`
- [ ] `BASH_REMATCH` — regex capture groups from `[[ =~ ]]`

### 1.5 Array Support

Currently parsed in the AST but runtime treats arrays as scalars:

- [ ] Indexed arrays: `arr=(a b c)`, `arr[0]=x`
- [ ] `${arr[n]}`, `${arr[@]}`, `${arr[*]}`
- [ ] `${#arr[@]}` — array length
- [ ] `${!arr[@]}` — array indices
- [ ] Array slicing: `${arr[@]:offset:length}`
- [ ] `unset arr[n]`
- [ ] `declare -a` (indexed), `declare -A` (associative)

---

## Phase 2: Missing Commands (MEDIUM-HIGH PRIORITY)

### 2.1 Critical Commands (agents use these constantly)

- [ ] **`jq`** — JSON processor (simplified subset: `.key`, `.[]`, `select()`, `map()`, pipes)
- [ ] **`base64`** — encode/decode (`-d` flag)
- [ ] **`expr`** — expression evaluator
- [ ] **`timeout`** — run command with time limit
- [ ] **`md5sum` / `sha256sum`** — checksums (use `CryptoKit`)
- [ ] **`tac`** — reverse cat (print file in reverse)
- [ ] **`whoami`** — print username
- [ ] **`rmdir`** — remove empty directory

### 2.2 Important Commands

- [ ] **`tree`** — directory tree display
- [ ] **`file`** — file type detection (simplified: by extension)
- [ ] **`od`** — octal dump
- [ ] **`strings`** — extract printable strings
- [ ] **`split`** — split file into pieces
- [ ] **`join`** — join lines of two files on common field
- [ ] **`fgrep` / `egrep`** — aliases for `grep -F` / `grep -E`
- [ ] **`rg`** — ripgrep-compatible interface (map to grep)
- [ ] **`clear`** — clear screen (no-op in sandbox)
- [ ] **`history`** — command history (no-op or simplified)
- [ ] **`help`** — builtin help text

### 2.3 Compression & Archives (nice to have)

- [ ] **`gzip` / `gunzip` / `zcat`** — compression (use `Compression` framework)
- [ ] **`tar`** — archive create/extract (simplified subset)

### 2.4 Advanced Data Processing (nice to have)

- [ ] **`yq`** — YAML/TOML/CSV processing
- [ ] **`xan`** — CSV processing
- [ ] **`sqlite3`** — SQLite interface

### 2.5 Improve Existing Commands

- [ ] **`awk`** — currently very simplified; needs: BEGIN/END blocks, variables, conditionals, loops, multiple rules, printf, arrays, getline
- [ ] **`sed`** — needs: address ranges (`2,5s/...`), multi-command (`-e`), labels/branching (`b`, `t`), hold space (`h`, `g`, `x`), print (`p`), append/insert (`a`, `i`)
- [ ] **`grep`** — needs: `-w` (word), `-o` (only matching), `-A`/`-B`/`-C` (context lines), `--include`/`--exclude`

---

## Phase 3: Redirections & Pipes (MEDIUM PRIORITY)

- [ ] `&>file` — redirect both stdout and stderr
- [ ] `&>>file` — append both
- [ ] `{fd}>file` — assign fd to variable
- [ ] `|&` — actually pipe stderr (not just parse it)
- [ ] Implement `noclobber` enforcement for `>`
- [ ] Process substitution: `<(cmd)`, `>(cmd)` — create virtual fd paths

---

## Phase 4: Filesystem Backends (MEDIUM PRIORITY)

### 4.1 Abstract Filesystem Protocol

- [ ] Define `FileSystem` protocol matching TS `IFileSystem` interface
- [ ] Make `VirtualFileSystem` conform to it
- [ ] Allow custom FS injection via `BashOptions`

### 4.2 OverlayFS

- [ ] Copy-on-write filesystem over a real directory
- [ ] Reads from disk, writes stay in memory
- [ ] Useful for macOS where real FS access is available

### 4.3 MountableFS

- [ ] Combine multiple FS backends at different mount points
- [ ] e.g., InMemory at `/tmp`, Overlay at `/workspace`

---

## Phase 5: API Parity (LOWER PRIORITY)

### 5.1 ExecResult Enhancements

- [ ] Return post-execution environment snapshot
- [ ] Support `rawScript` option (pre-parsed AST)
- [ ] Support `args` option (bypass parsing, direct command invocation)

### 5.2 Public API Additions

- [ ] `writeFile(_:content:)` — write to VFS from host
- [ ] `getCwd()` / `getEnv()` — inspect session state
- [ ] `registerCommand(_:)` — add commands after init
- [ ] `parse(_:)` — expose parser standalone
- [ ] `serialize(_:)` — AST back to script text

### 5.3 Cancellation

- [ ] Support `Task` cancellation for long-running scripts
- [ ] Check `Task.isCancelled` in loop bodies and command execution

### 5.4 Logging & Tracing

- [ ] `BashLogger` protocol for execution tracing
- [ ] Performance profiling hooks

---

## Phase 6: Testing Infrastructure (ONGOING)

### 6.1 Comparison Test Framework

- [ ] Record mode: run scripts against real `/bin/bash` and save JSON fixtures
- [ ] Replay mode: run same scripts against just-bash-swift and compare
- [ ] Fixture format: `{command, files, stdin, stdout, stderr, exitCode}`

### 6.2 Fixture Categories Needed

Port test fixtures from just-bash TS for these categories:
- [ ] alias
- [ ] awk
- [ ] basename/dirname
- [ ] cat
- [ ] cd
- [ ] column/join
- [ ] cut
- [ ] echo
- [ ] env/export
- [ ] file-ops
- [ ] find
- [ ] glob
- [ ] grep
- [ ] head/tail
- [ ] here-doc
- [ ] ls
- [ ] parse-errors
- [ ] paste
- [ ] pipes/redirections
- [ ] sed
- [ ] sort
- [ ] substitution
- [ ] tar (once implemented)
- [ ] tee
- [ ] test/conditionals
- [ ] text-processing
- [ ] tr
- [ ] uniq
- [ ] wc

### 6.3 Additional Testing

- [ ] Property-based testing (Swift equivalent of fast-check)
- [ ] Fuzz testing for parser robustness
- [ ] Edge case tests: empty scripts, deeply nested structures, massive output, pathological globs

---

## Phase 7: Advanced Features (NICE TO HAVE)

These bring full parity but are less critical for AI agent use:

- [ ] Extended globbing (`extglob`): `?(pat)`, `*(pat)`, `+(pat)`, `@(pat)`, `!(pat)`
- [ ] `time` keyword
- [ ] `coproc`
- [ ] `select` (would need a callback mechanism since there's no TTY)
- [ ] `${var@Q}`, `${var@E}`, `${var@P}`, `${var@A}`, `${var@a}` transform operators
- [ ] Network: `curl` with URL allow-list and `SecureFetch` equivalent
- [ ] Embedded runtimes: JavaScript via `JavaScriptCore`, Python via `PythonKit`
- [ ] AST transform plugin system
- [ ] Vercel `Sandbox` API compatibility layer

---

## Implementation Order Recommendation

For an AI agent use case, work in this order:

1. **Phase 1.1** (bug fixes) — immediate correctness wins
2. **Phase 1.2** (brace expansion) — agents use this constantly
3. **Phase 2.1** (critical commands: jq, base64, expr) — agents need these
4. **Phase 1.4** (missing variable features) — correctness for real scripts
5. **Phase 1.5** (arrays) — many scripts depend on arrays
6. **Phase 2.5** (improve awk/sed/grep) — agents write awk/sed/grep heavily
7. **Phase 3** (redirections) — less common but important
8. **Phase 6** (testing) — should be ongoing alongside all other phases
9. **Phase 4** (FS backends) — mainly for macOS use cases
10. **Phase 5** (API parity) — polish
11. **Phase 2.2-2.4** (more commands) — as needed
12. **Phase 7** (advanced) — only if needed

---

## Contributing

Each phase is designed to be tackled independently. When working on a feature:

1. Write tests first (in the appropriate test target)
2. Implement the feature
3. Run `swift test` to verify all existing tests still pass
4. Add comparison fixtures where possible

The codebase is organized for easy navigation:
- **Parser changes** → `Sources/JustBashCore/Parser.swift`
- **New AST types** → `Sources/JustBashCore/CoreShell.swift`
- **Interpreter/builtins** → `Sources/JustBashCore/Interpreter.swift`
- **Commands** → `Sources/JustBashCommands/Commands.swift`
- **Filesystem** → `Sources/JustBashFS/VirtualFileSystem.swift`
