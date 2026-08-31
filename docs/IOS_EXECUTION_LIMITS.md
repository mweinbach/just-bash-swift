# Embedded JavaScript execution limits

Status checked on 2026-08-31. The shipping `js-exec` backend is JavaScriptCore,
with cooperative cancellation and deadline checks. It does not provide a hard
wall-clock limit for arbitrary synchronous JavaScript.

## Shipping behavior

`BashJavaScriptOptions.defaultTimeoutMs` and `defaultNetworkTimeoutMs` are checked
after synchronous evaluation and while awaiting JavaScript jobs. A finite
synchronous overrun returns exit code 124 when evaluation returns. Cancellation
of pending asynchronous work returns 130 and prevents subsequent shell commands.
A synchronous infinite loop can still occupy the JavaScriptCore executor.
Moving that call into a Swift `Task`, racing a timer, or inserting source-level
loop checks does not make arbitrary JavaScript safely interruptible.

Hosts that require a preemptible execution engine must opt into the explicit
fail-closed policy:

```swift
JavaScriptRuntime(options: .init(executionPolicy: .requirePreemptible))
```

The current backend rejects this policy before evaluating user code, with exit
code 2. It does not silently fall back to cooperative execution. The default
`.cooperative` policy preserves the supported artifact workflows. No private
JavaScriptCore API is used, and no alternative engine is vendored by this change.

## Public backend investigation

A WebKit worker can be terminated through the public worker API. The existing
SwiftCodexCore code-mode implementation uses a worker with asynchronous message
replies. That worker does not isolate JustBash's `js-exec` calls. Directly moving
the current JustBash module into it would require adapting synchronous filesystem
and `child_process.execSync` bridges to a different host transport; merely
creating a worker does not supply those bridges. See the
[worker termination specification](https://html.spec.whatwg.org/multipage/workers.html#dom-worker-terminate-dev)
and Apple's [reply-capable WebKit message handler](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply).

QuickJS exposes public C callbacks for host functions, an interrupt callback,
and memory/stack limits. Those interfaces can retain synchronous filesystem and
shell semantics without WebKit or process spawning. Its interrupt callback is
periodic execution polling; the API alone does not bound every native operation.
See the [QuickJS C API documentation](https://bellard.org/quickjs/quickjs.html#QuickJS-C-API)
and [public header](https://github.com/bellard/quickjs/blob/master/quickjs.h).

An isolated prototype used the official
[QuickJS 2026-06-04 release](https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz),
whose downloaded archive SHA256 was
`b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`.
It compiled the engine C files without `quickjs-libc`, linked Swift callbacks to
the real `VirtualFileSystem` and `Bash`, and used a fresh runtime per evaluation.
The prototype built on macOS and its C target compiled for the iOS 18 arm64
Simulator. This was a feasibility probe, not an iPhone runtime test.

The callback used `JS_SetInterruptHandler` with a monotonic 20 ms deadline,
`JS_SetMemoryLimit` at 64 MiB, `JS_SetMaxStackSize` at 512 KiB, and
`JS_SetCanBlock(false)`. Results from the local prototype:

| Probe | Observed result |
| --- | --- |
| Write through Swift VFS, read through `child_process.execSync('cat …')` | `hello`, 3.22 ms |
| Read same VFS from a new runtime | `hello`, 0.07 ms |
| `while (true) {}` | Interrupted at 19.96 ms |
| Infinite loop wrapped in repeated `try/catch` | Interrupted at 19.97 ms |
| Infinite loop through dynamic `eval` | Interrupted at 19.95 ms |
| Catastrophic regular-expression probe | Interrupted at 20.11 ms |
| 128 MiB ArrayBuffer allocation | Out-of-memory exception at 0.03 ms |
| Swift callback deliberately blocking for 100 ms | Returned at 106.44 ms, not interrupted |
| Large BigInt decimal conversion | Still running after 2 seconds; external supervisor killed probe |
| Repeated large BigInt division | Still running after 2 seconds; external supervisor killed probe |
| Fresh runtime after interrupted tests | `1 + 2` returned 3 |

The two BigInt reproductions were:

```js
BigInt('0x' + 'F'.repeat(240000)).toString().length
```

```js
const a = BigInt('0x' + 'f'.repeat(100000));
const b = BigInt('0x' + 'a'.repeat(50000));
let x = 0n;
for (let i = 0; i < 300; i++) x = a / b;
String(x).length;
```

The release's `mp_mul_basecase` and `mp_divnorm` implementations contain native
loops without interrupt checks. The measured BigInt and blocking-host results
rule out claiming a universal hard deadline for this unmodified prototype.
Local evidence at the time of the investigation was in
`/tmp/justbash-quickjs-probe.J2qs0n/results.txt`, `build.log`, `ios-build.log`,
`package/Sources/CQuickJSProbe/probe.c`, and
`package/Sources/Probe/main.swift`. Those temporary files are not package inputs.

The smallest credible next implementation is an optional embedded C backend
with engine-specific Swift bridges sharing the existing virtual filesystem,
module source, and shell executor. It must bound or add interrupt polling to
expensive native operations, propagate the remaining deadline and cancellation
into every host call, and stop outstanding side effects before reporting
termination. It must also cover module loading, promise jobs, output conversion,
and cleanup. The current prototype does not meet those acceptance conditions,
so `.requirePreemptible` remains unavailable rather than overstating protection.

## Network capabilities are independent of execution policy

`BashOptions.allowedURLPrefixes` is the host's maximum HTTP(S) allowlist.
`ExecOptions(allowNetwork: false)` disables it for one invocation, including
subshells, JavaScript fetch, and GitHub REST transport. `true` and `nil` retain the
configured allowlist and never add permissions. Overlapping invocations use
immutable interpreter policies. Redirects must also match the allowlist; host
and port boundaries are checked in addition to URL prefixes.

`data:` URLs remain local. `file:` URLs read through `CommandContext.fileSystem`,
so a virtual path cannot escape into Foundation's physical filesystem. Custom
host commands remain responsible for honoring the context; they can reuse
`CommandNetworkAccess`. Network permission does not imply a hard JavaScript
deadline, and a permissive tool-approval mode does not grant network access.
