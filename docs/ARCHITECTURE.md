# JustBash Architecture Guide

This document provides a comprehensive overview of the JustBash system architecture, explaining the design decisions, module responsibilities, data flow, and key components.

## Table of Contents

1. [Overview](#overview)
2. [Module Architecture](#module-architecture)
3. [Data Flow](#data-flow)
4. [Key Components](#key-components)
5. [Execution Pipeline](#execution-pipeline)
6. [Design Decisions & Trade-offs](#design-decisions--trade-offs)

---

## Overview

JustBash is a sandboxed bash shell implementation written in Swift. It provides a safe environment for executing bash scripts without requiring a real Unix shell or filesystem. The system is designed to be embeddable, testable, and extensible while maintaining compatibility with common bash constructs.

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Public API Layer                              │
│                        (JustBash Module)                            │
│                    ┌──────────────────┐                             │
│                    │   Bash Actor     │                             │
│                    │  (Entry Point)   │                             │
│                    └────────┬─────────┘                             │
└─────────────────────────────┼───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Core Execution Layer                            │
│                      (JustBashCore Module)                         │
│  ┌────────────────┐    ┌──────────────────┐    ┌───────────────┐    │
│  │ ShellParser    │───▶│       AST        │───▶│ShellInterpreter│   │
│  │ (Tokenizer +   │    │  (Script, Command,│    │   (Executor)   │   │
│  │ Parser)        │    │  etc.)           │    │                │   │
│  └────────────────┘    └──────────────────┘    └───────┬────────┘    │
│                                                      │              │
└──────────────────────────────────────────────────────┼──────────────┘
                                                       │
                              ┌────────────────────────┴────────────────────┐
                              ▼                                             ▼
┌────────────────────────────────────────────────┐  ┌─────────────────────────────────────────┐
│          Command Execution Layer                │  │           Filesystem Layer               │
│         (JustBashCommands Module)               │  │           (JustBashFS Module)            │
│  ┌─────────────────┐   ┌──────────────────┐  │  │  ┌─────────────────────────────────┐    │
│  │ CommandRegistry   │   │  Built-in Cmds   │  │  │  │    BashFilesystem Protocol      │    │
│  │ (Command Lookup)  │   │ (cat, ls, grep)  │  │  │  │  ┌───────────────────────────┐    │    │
│  └────────┬──────────┘   └──────────────────┘  │  │  │  │  VirtualFileSystem         │    │    │
│           │                                    │  │  │  │  (In-Memory Implementation)│    │    │
│           ▼                                    │  │  │  └───────────────────────────┘    │    │
│  ┌─────────────────┐                          │  │  └─────────────────────────────────┘    │
│  │  AnyBashCommand   │                          │  │                                       │
│  │ (Custom Commands) │                          │  │  ┌─────────────────────────────────┐    │
│  └─────────────────┘                          │  │  │       VirtualPath Utilities       │    │
└────────────────────────────────────────────────┘  │  └─────────────────────────────────┘    │
                                                      └─────────────────────────────────────────┘
```

---

## Module Architecture

The system is organized into four distinct modules, each with clear responsibilities:

### 1. JustBash (Public API)

**Responsibility**: Provides the public-facing API that users interact with.

**Key Types**:
- `Bash` - Main actor that coordinates all shell operations
- `BashOptions` - Configuration for shell initialization
- `ExecOptions` - Per-execution configuration

**Design Rationale**: This module serves as a facade, hiding the internal complexity of the parser, interpreter, and filesystem. It exposes type aliases from other modules for convenience.

```
┌─────────────────────────────────────────────────┐
│                  JustBash Module                 │
│                                                  │
│  • Public entry point                            │
│  • Configuration management                      │
│  • Type re-exports for convenience               │
│                                                  │
│  Key Type: Bash (actor)                          │
│  - Initializes all subsystems                    │
│  - Provides exec(script:) method                 │
│  - Manages filesystem and environment            │
└─────────────────────────────────────────────────┘
```

### 2. JustBashCore (Core Execution)

**Responsibility**: Parsing and interpreting bash scripts.

**Key Types**:
- `ShellParser` - Tokenizes input and builds AST
- `ShellInterpreter` - Executes parsed scripts
- `ShellSession` - Mutable execution state
- `ExecutionLimits` - Resource limits for safety

**Files**:
- `Parser.swift` - Tokenizer and recursive descent parser
- `CoreShell.swift` - AST types and session state
- `Interpreter.swift` - Main execution engine
- `ShellInterpreter+Builtins.swift` - Shell built-in commands
- `ShellInterpreter+Arithmetic.swift` - Arithmetic evaluation

```
┌─────────────────────────────────────────────────┐
│               JustBashCore Module                │
│                                                  │
│  Parsing Pipeline:                               │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │  Input   │───▶│ Tokenizer│───▶│  Parser  │  │
│  │  String  │    │ (Tokens) │    │   (AST)  │  │
│  └──────────┘    └──────────┘    └──────────┘  │
│                                                  │
│  Execution Engine:                               │
│  ┌──────────────┐    ┌──────────────┐           │
│  │   Script     │───▶│Interpreter   │           │
│  │   (AST)      │    │(Traverses AST│           │
│  └──────────────┘    │and executes) │           │
│                     └──────────────┘           │
└─────────────────────────────────────────────────┘
```

### 3. JustBashCommands (Command Infrastructure)

**Responsibility**: Built-in command implementations and command registration system.

**Key Types**:
- `CommandRegistry` - Central command registry
- `AnyBashCommand` - Type-erased command wrapper
- `CommandContext` - Execution context for commands
- `ExecResult` - Standard result type

**Design Rationale**: Commands are implemented as pure functions that receive a context and return a result. This makes them testable and allows for easy addition of custom commands.

```
┌─────────────────────────────────────────────────┐
│             JustBashCommands Module              │
│                                                  │
│  Command Registration:                           │
│  ┌─────────────────┐                            │
│  │ CommandRegistry │                            │
│  │   - builtins()  │──▶ Pre-registered commands  │
│  │   - register()  │──▶ Custom command support    │
│  └─────────────────┘                            │
│                                                  │
│  Command Types:                                  │
│  • File operations (ls, cp, mv, rm, mkdir...)   │
│  • Text processing (grep, sed, awk, sort...)    │
│  • Data commands (jq, xan, base64...)           │
│  • Shell commands (cat, tee, xargs...)          │
└─────────────────────────────────────────────────┘
```

### 4. JustBashFS (Filesystem Layer)

**Responsibility**: Abstract filesystem operations with a virtual implementation.

**Key Types**:
- `BashFilesystem` - Protocol defining filesystem operations
- `VirtualFileSystem` - In-memory filesystem implementation
- `VirtualPath` - Path normalization utilities
- `VirtualProcessInfo` - Simulated process information

**Design Rationale**: The protocol-based design allows for pluggable filesystem implementations. The default `VirtualFileSystem` provides a safe sandbox that doesn't touch the real filesystem.

```
┌─────────────────────────────────────────────────┐
│               JustBashFS Module                  │
│                                                  │
│  BashFilesystem Protocol:                        │
│  ├─ readFile(path:relativeTo:)                   │
│  ├─ writeFile(path:content:relativeTo:)         │
│  ├─ deleteFile(path:relativeTo:recursive:force:)│
│  ├─ fileExists(path:relativeTo:)                  │
│  ├─ listDirectory(path:relativeTo:)             │
│  └─ glob(pattern:relativeTo:dotglob:extglob:)   │
│                                                  │
│  VirtualFileSystem (Implementation):             │
│  • In-memory tree structure (Node class)         │
│  • Supports files, directories, symlinks          │
│  • Pre-populated with /bin, /usr, /home, etc.    │
└─────────────────────────────────────────────────┘
```

---

## Data Flow

The execution of a bash script follows this pipeline:

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Input   │────▶│ Tokenizer│────▶│  Parser  │────▶│    AST   │────▶│Interpreter│
│  Script  │     │          │     │          │     │          │     │           │
└──────────┘     └──────────┘     └──────────┘     └──────────┘     └─────┬─────┘
     │                                                                   │
     │                                                                   ▼
     │                                                          ┌──────────────┐
     │                                                          │   Commands   │
     │                                                          │   Execute    │
     │                                                          └──────┬───────┘
     │                                                                 │
     ▼                                                                 ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                              Output                                       │
│                    (stdout, stderr, exitCode)                             │
└───────────────────────────────────────────────────────────────────────────┘
```

### Detailed Data Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 1: Input                                                                │
│  ─────────────────────────────────────────────────────────────────────────  │
│  bash.exec("echo Hello World")                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 2: Tokenization (ShellParser → Tokenizer)                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Input: "echo Hello World"                                                   │
│                                                                               │
│  Output Tokens:                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ [.word("echo"), .word("Hello"), .word("World"), .eof]                  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                               │
│  More Complex Example:                                                        │
│  Input: "echo $(whoami) > /tmp/user.txt"                                     │
│  Tokens:                                                                      │
│  ├─ .word([.literal("echo"), .commandSub("whoami")])                        │
│  ├─ .great (>)                                                               │
│  ├─ .word("/tmp/user.txt")                                                   │
│  └─ .eof                                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 3: Parsing (ParserState)                                                │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Builds Abstract Syntax Tree (AST):                                          │
│                                                                               │
│  Script                                                                        │
│  └─ ListEntry                                                                  │
│     └─ AndOrList                                                               │
│        └─ PipelineDef                                                          │
│           └─ Command.simple(SimpleCommand)                                   │
│              ├─ words: [ShellWord("echo"), ShellWord("Hello"), ...]         │
│              ├─ assignments: []                                                │
│              └─ redirections: []                                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 4: Interpretation (ShellInterpreter)                                  │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Traverses AST and executes:                                                  │
│                                                                               │
│  1. Word Expansion:                                                           │
│     - Variable expansion: $USER → "user"                                     │
│     - Command substitution: $(date) → execute and capture                     │
│     - Tilde expansion: ~ → /home/user                                        │
│     - Brace expansion: {a,b,c} → a b c                                       │
│     - Glob expansion: *.txt → [file1.txt, file2.txt]                         │
│                                                                               │
│  2. Command Resolution:                                                       │
│     - Functions (session.functions)                                          │
│     - Shell builtins (shellBuiltin())                                        │
│     - Registered commands (CommandRegistry)                                   │
│     - Error: "command not found"                                               │
│                                                                               │
│  3. Execution:                                                              │
│     - Simple commands → command handler                                       │
│     - Compound commands → recursive execution                                 │
│     - Pipelines → connect stdout → stdin                                       │
│     - Control flow → throw ControlFlow signals                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Step 5: Output (ExecResult)                                                │
│  ─────────────────────────────────────────────────────────────────────────  │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ ExecResult(                                                             ││
│  │    stdout: "Hello World\n",                                            ││
│  │    stderr: "",                                                          ││
│  │    exitCode: 0                                                          ││
│  │ )                                                                        ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Components

### ShellParser

The parser uses a two-phase approach: tokenization followed by recursive descent parsing.

**Responsibilities**:
1. **Tokenization**: Convert raw input into structured tokens
2. **Word Parsing**: Handle complex word constructs (quoting, expansions)
3. **AST Construction**: Build tree representing command structure

**Key Features**:
- Supports all bash quoting styles: `'...'`, `"..."`, `$'...'` (ANSI-C), `$"..."`
- Variable expansions: `$var`, `${var}`, `${var:-default}`, `${#var}`, etc.
- Command substitutions: `$(...)` and `` `...` ``
- Arithmetic expansion: `$((...))`
- Process substitution: `<(...)` and `>(...)`
- Here-docs: `<<EOF ... EOF`

**Parsing Hierarchy**:

```
Script (top level)
├── ListEntry (command with optional backgrounding)
│   └── AndOrList (commands connected by && ||)
│       └── PipelineDef (commands connected by | |&)
│           └── Command
│               ├── .simple(SimpleCommand)
│               │   ├── assignments
│               │   ├── words
│               │   └── redirections
│               ├── .compound(CompoundCommand, redirections)
│               │   ├── .ifClause
│               │   ├── .forClause
│               │   ├── .whileClause / .untilClause
│               │   ├── .caseClause
│               │   ├── .braceGroup
│               │   ├── .subshell
│               │   └── ...
│               └── .functionDef(FunctionDef)
```

### ShellInterpreter

The interpreter executes parsed AST nodes, managing state and control flow.

**Responsibilities**:
1. **AST Traversal**: Walk the tree and execute each node
2. **Word Expansion**: Expand variables, globs, command substitutions
3. **Command Dispatch**: Route to appropriate handler
4. **Control Flow**: Handle break, continue, return, exit
5. **State Management**: Maintain ShellSession across execution

**Execution Order**:
```
executeScript()
  └── for each ListEntry:
        └── executeListEntry()
              └── executeAndOr()
                    └── executePipeline()
                          └── executeCommand()
                                ├── executeSimple()        [simple commands]
                                ├── executeCompound()      [control structures]
                                └── executeFunction()      [function calls]
```

**Word Expansion Pipeline**:
```
Raw Word → Brace Expansion → Tilde Expansion → 
    Parameter Expansion → Command Substitution → 
        Arithmetic Expansion → Word Splitting → 
            Glob Expansion → Final Arguments
```

### VirtualFileSystem

An in-memory filesystem implementation that provides a safe sandbox.

**Architecture**:
```
VirtualFileSystem
├── root: Node (directory)
│   ├── children: ["bin": Node, "home": Node, ...]
│   │   └── "home": Node (directory)
│   │       └── children: ["user": Node]
│   │           └── "user": Node (directory)
│   │               └── children: [...]
│   └── ...
└── Node types:
    ├── .file (content: Data)
    ├── .directory (children: [String: Node])
    └── .symlink (symlinkTarget: String)
```

**Features**:
- Complete Unix-like directory structure (/bin, /usr, /home, /tmp, etc.)
- File operations: read, write, create, delete
- Directory operations: create, list, walk
- Symlink support: create, read, follow
- Glob matching with extended glob patterns (extglob)
- Path normalization

**Default Layout**:
```
/
├── bin/           # Built-in command stubs
├── usr/
│   └── bin/      # Additional commands
├── tmp/          # Temporary files
├── home/
│   └── user/     # User home directory
├── dev/
│   ├── null
│   ├── stdin
│   ├── stdout
│   └── stderr
└── proc/
    └── self/     # Process info simulation
```

### CommandRegistry

Central registration system for commands.

**Design**:
```
CommandRegistry
├── commands: [String: AnyBashCommand]
│
├── register(command)     # Add custom command
├── command(named:)       # Lookup command
└── builtins()            # Factory with all built-ins
```

**CommandContext** (passed to commands):
```swift
struct CommandContext {
    let fileSystem: BashFilesystem      // Filesystem access
    let cwd: String                      // Current directory
    let environment: [String: String]  // Environment variables
    let stdin: String                    // Input data
    let executeSubshell: SubshellExecutor?  // For $(...) support
}
```

---

## Execution Pipeline

### Example 1: Simple Command

```bash
echo "Hello, $USER!"
```

**Execution Flow**:
```
1. bash.exec() called with script

2. ShellParser.tokenize():
   Input: echo "Hello, $USER!"
   Output: [.word("echo"), .word([.doubleQuoted([.literal("Hello, "), 
          .variable(.named("USER")), .literal("!")])]), .eof]

3. ParserState.parseScript():
   Output: Script([ListEntry(AndOrList(PipelineDef(
     commands: [.simple(SimpleCommand(words: ["echo", "Hello, $USER!"]))]
   )))])

4. ShellInterpreter.executeScript():
   └── executeListEntry()
         └── executeAndOr()
               └── executePipeline()
                     └── executeCommand()
                           └── executeSimple()
                                 ├── Expand words: ["echo", "Hello, user!"]
                                 ├── Lookup: "echo" is a builtin
                                 └── Execute builtin with args

5. Return ExecResult(stdout: "Hello, user!\n", stderr: "", exitCode: 0)
```

### Example 2: Pipeline

```bash
cat file.txt | grep "error" | wc -l
```

**Execution Flow**:
```
1. Parse into PipelineDef with 3 commands
   PipelineDef(
     commands: [
       .simple(cat, words: ["file.txt"]),
       .simple(grep, words: ["error"]),
       .simple(wc, words: ["-l"])
     ],
     pipeStandardError: [false, false]
   )

2. executePipeline() iterates:
   
   Command 1: cat file.txt
   ├── stdin: "" (empty)
   ├── Execute → Result1(stdout: "line1\nline2 error\n...", stderr: "")
   └── pipedInput = Result1.stdout
   
   Command 2: grep "error"
   ├── stdin: "line1\nline2 error\n..."
   ├── Execute → Result2(stdout: "line2 error\n", stderr: "")
   └── pipedInput = Result2.stdout
   
   Command 3: wc -l
   ├── stdin: "line2 error\n"
   ├── Execute → Result3(stdout: "1\n", stderr: "")
   └── pipedInput = Result3.stdout

3. Combine results:
   ├── stdout: "1\n" (last command's output)
   ├── stderr: "" (concatenated if |& used)
   └── exitCode: 0
```

### Example 3: Control Flow

```bash
for f in *.txt; do
    echo "Processing $f"
done
```

**Execution Flow**:
```
1. Parse into ForClause:
   ForClause(
     variable: "f",
     words: [ShellWord("*.txt")],
     body: Script([...])
   )

2. executeFor():
   ├── Expand words: ["file1.txt", "file2.txt", "notes.txt"]
   │   └── Glob expansion by VirtualFileSystem.glob()
   │
   ├── For each item:
   │   ├── session.setVariable("f", item)
   │   ├── executeScript(body)
   │   │   └── executeSimple(echo "Processing $f")
   │   └── Collect results
   │
   └── Return combined results

3. Output:
   Processing file1.txt
   Processing file2.txt
   Processing notes.txt
```

---

## Design Decisions & Trade-offs

### 1. Actor-Based Concurrency

**Decision**: The `Bash` actor protects all shell state.

**Rationale**:
- ✅ Thread-safe by design
- ✅ Prevents data races in session state
- ✅ Compatible with Swift 6 strict concurrency

**Trade-off**:
- ⚠️ All shell operations are serialized
- ⚠️ Background jobs are simulated (no true parallelism)

### 2. Virtual Filesystem by Default

**Decision**: Use in-memory VirtualFileSystem rather than real filesystem.

**Rationale**:
- ✅ Safe sandboxing - can't harm host system
- ✅ Deterministic testing
- ✅ Fast - no I/O overhead
- ✅ Cross-platform consistency

**Trade-off**:
- ⚠️ Cannot access real host files by default
- ⚠️ Files don't persist between sessions

**Mitigation**: The `BashFilesystem` protocol allows custom implementations that could wrap the real filesystem when needed.

### 3. Two-Phase Parsing

**Decision**: Separate tokenization from parsing.

**Rationale**:
- ✅ Cleaner separation of concerns
- ✅ Easier to handle complex word constructs
- ✅ Better error messages at specific phases

**Trade-off**:
- ⚠️ Slightly more memory usage (token array + AST)
- ⚠️ Two passes over input

### 4. Protocol-Based Commands

**Decision**: Commands implemented as handlers with `CommandContext`.

**Rationale**:
- ✅ Easy to add custom commands
- ✅ Testable - can mock context
- ✅ No inheritance hierarchy

**Trade-off**:
- ⚠️ Slightly more boilerplate than method dispatch
- ⚠️ Type erasure via `AnyBashCommand`

### 5. Mutable ShellSession

**Decision**: Pass session as `inout` parameter through execution.

**Rationale**:
- ✅ Natural model for shell state mutations
- ✅ Local variable scopes via pushScope/popScope
- ✅ Function call stack tracking

**Trade-off**:
- ⚠️ Requires `@unchecked Sendable` in some places
- ⚠️ Must be careful with async boundaries

### 6. Recursive Descent Parser

**Decision**: Hand-written recursive descent parser rather than parser generator.

**Rationale**:
- ✅ Full control over error messages
- ✅ Easy to extend with bash-specific features
- ✅ No build-time dependencies

**Trade-off**:
- ⚠️ More code to maintain than generated parser
- ⚠️ Must manually handle left recursion

### 7. Limits-Based Resource Control

**Decision**: Explicit `ExecutionLimits` for all resource constraints.

**Rationale**:
- ✅ Prevents runaway scripts (infinite loops, memory exhaustion)
- ✅ Configurable per execution
- ✅ Clear failure modes

**Trade-off**:
- ⚠️ Adds check overhead in hot paths
- ⚠️ Limits may need tuning for different use cases

### 8. Swift 6 Concurrency Compliance

**Decision**: Full adoption of Swift 6's strict concurrency checking.

**Rationale**:
- ✅ Compile-time data race detection
- ✅ Future-proof for Swift evolution
- ✅ Clear ownership semantics

**Trade-off**:
- ⚠️ Requires `@unchecked Sendable` for some types
- ⚠️ More complex async/await patterns
- ⚠️ Some patterns require explicit `@concurrent` annotations

---

## Extension Points

### Adding a Custom Command

```swift
let myCommand = AnyBashCommand(name: "mycmd") { args, context in
    // Access filesystem
    let files = try? context.fileSystem.listDirectory(".")
    
    // Return result
    return ExecResult.success("Found \(files?.count ?? 0) files")
}

let bash = Bash(options: BashOptions(
    customCommands: [myCommand]
))
```

### Custom Filesystem Implementation

```swift
struct RealFilesystem: BashFilesystem {
    func readFile(path: String, relativeTo: String) throws -> Data {
        // Implementation using Foundation FileManager
    }
    // ... other protocol requirements
}

let bash = Bash(options: BashOptions(
    filesystem: RealFilesystem()
))
```

### Custom Execution Limits

```swift
let strictLimits = ExecutionLimits(
    maxInputLength: 10_000,
    maxTokenCount: 1_000,
    maxCommandCount: 100,
    maxLoopIterations: 100,
    maxCallDepth: 10
)

let bash = Bash(options: BashOptions(executionLimits: strictLimits))
```

---

## Summary

JustBash is architected as a layered system with clear separation of concerns:

1. **Public API** (`JustBash`) provides a simple interface
2. **Core** (`JustBashCore`) handles parsing and execution
3. **Commands** (`JustBashCommands`) implements shell commands
4. **Filesystem** (`JustBashFS`) abstracts storage operations

The design prioritizes **safety** (virtual filesystem, execution limits), **testability** (protocol-based design, pure functions), and **extensibility** (custom commands, pluggable filesystem).

The modular architecture allows users to use only what they need - from just the filesystem layer to the full shell execution environment.
