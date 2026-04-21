import Foundation
import JavaScriptCore

/// Installs `process`, `console`, and `Buffer` globals.
///
/// `console.log/info/debug` route to captured stdout; `error/warn` route to
/// captured stderr. `process.exit(code)` flips the engine's `exitRequested`
/// flag so the engine returns the requested status after the current eval.
func installProcessBridge(into context: JSContext, execution: JSCExecutionContext) {
    // Console — replace the polyfill defaults with capture-backed implementations.
    // Blocks installed as JSContext globals first; a JS factory wraps them so
    // variadic JS calls collect their arguments into an array before invoking.
    let writeStdout: @convention(block) ([Any]) -> Void = { parts in
        execution.capture.appendLineToStdout(formatConsoleArgs(parts))
    }
    let writeStderr: @convention(block) ([Any]) -> Void = { parts in
        execution.capture.appendLineToStderr(formatConsoleArgs(parts))
    }
    context.setObject(writeStdout, forKeyedSubscript: "__jb_write_stdout" as NSString)
    context.setObject(writeStderr, forKeyedSubscript: "__jb_write_stderr" as NSString)
    let consoleSetup = """
    (function() {
      function gather() { var a = []; for (var i = 0; i < arguments.length; i++) a.push(arguments[i]); return a; }
      globalThis.console = {
        log: function() { __jb_write_stdout(gather.apply(null, arguments)); },
        info: function() { __jb_write_stdout(gather.apply(null, arguments)); },
        debug: function() { __jb_write_stdout(gather.apply(null, arguments)); },
        warn: function() { __jb_write_stderr(gather.apply(null, arguments)); },
        error: function() { __jb_write_stderr(gather.apply(null, arguments)); }
      };
    })();
    """
    context.evaluateScript(consoleSetup)

    // Process.
    let process = JSValue(newObjectIn: context)!
    let argv: [String] = ["js-exec"] + (execution.scriptPath.map { [$0] } ?? []) + execution.scriptArgs
    process.setObject(argv, forKeyedSubscript: "argv" as NSString)
    process.setObject(execution.cmdCtx.environment, forKeyedSubscript: "env" as NSString)
    process.setObject("linux", forKeyedSubscript: "platform" as NSString)
    process.setObject("v22.0.0-jsc", forKeyedSubscript: "version" as NSString)
    let cwdFn: @convention(block) () -> String = { execution.cmdCtx.cwd }
    process.setObject(cwdFn, forKeyedSubscript: "cwd" as NSString)
    let chdirFn: @convention(block) (String) -> Void = { _ in /* no-op; shell controls cwd */ }
    process.setObject(chdirFn, forKeyedSubscript: "chdir" as NSString)
    let exitFn: @convention(block) (JSValue?) -> Void = { value in
        execution.exitRequested = true
        if let v = value, !v.isUndefined { execution.exitCode = Int(v.toInt32()) }
        // Also throw inside JS so the rest of the script doesn't run.
        context.exception = JSValue(newErrorFromMessage: "__jb_exit", in: context)
    }
    process.setObject(exitFn, forKeyedSubscript: "exit" as NSString)
    let hrtimeFn: @convention(block) () -> [UInt64] = {
        let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return [nanos / 1_000_000_000, nanos % 1_000_000_000]
    }
    process.setObject(hrtimeFn, forKeyedSubscript: "hrtime" as NSString)
    let stdinValue: String = execution.cmdCtx.stdin
    process.setObject(["isTTY": false], forKeyedSubscript: "stdin" as NSString)
    process.setObject(stdinValue, forKeyedSubscript: "__stdin_text" as NSString)
    context.setObject(process, forKeyedSubscript: "process" as NSString)

    // Buffer — minimal polyfill on top of Uint8Array.
    let bufferImpl = """
    (function() {
      function Buffer(input, enc) { return Buffer.from(input, enc); }
      Buffer.from = function(input, enc) {
        if (typeof input === 'string') {
          if (!enc || enc === 'utf8' || enc === 'utf-8') {
            var bytes = [];
            for (var i = 0; i < input.length; i++) {
              var code = input.charCodeAt(i);
              if (code < 0x80) bytes.push(code);
              else if (code < 0x800) { bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f)); }
              else if (code < 0xd800 || code >= 0xe000) { bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f)); }
              else {
                i++;
                var c2 = input.charCodeAt(i);
                var combined = 0x10000 + (((code & 0x3ff) << 10) | (c2 & 0x3ff));
                bytes.push(0xf0 | (combined >> 18), 0x80 | ((combined >> 12) & 0x3f), 0x80 | ((combined >> 6) & 0x3f), 0x80 | (combined & 0x3f));
              }
            }
            return wrapBuffer(new Uint8Array(bytes));
          }
          if (enc === 'base64') {
            var bin = atob(input);
            var arr = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
            return wrapBuffer(arr);
          }
          if (enc === 'hex') {
            var arr = new Uint8Array(input.length / 2);
            for (var i = 0; i < arr.length; i++) arr[i] = parseInt(input.substr(i * 2, 2), 16);
            return wrapBuffer(arr);
          }
        }
        if (input instanceof Uint8Array) return wrapBuffer(input);
        if (Array.isArray(input)) return wrapBuffer(new Uint8Array(input));
        return wrapBuffer(new Uint8Array(0));
      };
      Buffer.alloc = function(size) { return wrapBuffer(new Uint8Array(size)); };
      Buffer.byteLength = function(s, enc) { return Buffer.from(s, enc || 'utf8').length; };
      function wrapBuffer(u8) {
        u8.toString = function(enc) {
          enc = enc || 'utf8';
          if (enc === 'utf8' || enc === 'utf-8') {
            var s = '';
            var i = 0;
            while (i < this.length) {
              var b = this[i++];
              if (b < 0x80) s += String.fromCharCode(b);
              else if (b < 0xc0) { /* skip invalid */ }
              else if (b < 0xe0) s += String.fromCharCode(((b & 0x1f) << 6) | (this[i++] & 0x3f));
              else if (b < 0xf0) s += String.fromCharCode(((b & 0x0f) << 12) | ((this[i++] & 0x3f) << 6) | (this[i++] & 0x3f));
              else {
                var combined = ((b & 0x07) << 18) | ((this[i++] & 0x3f) << 12) | ((this[i++] & 0x3f) << 6) | (this[i++] & 0x3f);
                combined -= 0x10000;
                s += String.fromCharCode(0xd800 + (combined >> 10), 0xdc00 + (combined & 0x3ff));
              }
            }
            return s;
          }
          if (enc === 'base64') {
            var bin = '';
            for (var i = 0; i < this.length; i++) bin += String.fromCharCode(this[i]);
            return btoa(bin);
          }
          if (enc === 'hex') {
            var s = '';
            for (var i = 0; i < this.length; i++) { var h = this[i].toString(16); if (h.length === 1) h = '0' + h; s += h; }
            return s;
          }
          return '';
        };
        return u8;
      }
      globalThis.Buffer = Buffer;
      // atob/btoa polyfills if missing
      if (typeof atob === 'undefined') {
        var b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        globalThis.atob = function(s) {
          s = s.replace(/=+$/, '');
          var out = '';
          for (var i = 0; i < s.length;) {
            var c1 = b64.indexOf(s.charAt(i++));
            var c2 = b64.indexOf(s.charAt(i++));
            var c3 = b64.indexOf(s.charAt(i++));
            var c4 = b64.indexOf(s.charAt(i++));
            out += String.fromCharCode((c1 << 2) | (c2 >> 4));
            if (c3 !== -1 && c3 !== 64) out += String.fromCharCode(((c2 & 15) << 4) | (c3 >> 2));
            if (c4 !== -1 && c4 !== 64) out += String.fromCharCode(((c3 & 3) << 6) | c4);
          }
          return out;
        };
        globalThis.btoa = function(s) {
          var out = '';
          for (var i = 0; i < s.length;) {
            var c1 = s.charCodeAt(i++) & 0xff;
            var c2 = s.charCodeAt(i++) & 0xff;
            var c3 = s.charCodeAt(i++) & 0xff;
            out += b64.charAt(c1 >> 2);
            out += b64.charAt(((c1 & 3) << 4) | (c2 >> 4));
            out += isNaN(c2) ? '=' : b64.charAt(((c2 & 15) << 2) | (c3 >> 6));
            out += isNaN(c3) ? '=' : b64.charAt(c3 & 63);
          }
          return out;
        };
      }
    })();
    """
    context.evaluateScript(bufferImpl)
}

private func formatConsoleArgs(_ parts: [Any]) -> String {
    parts.map { formatConsoleArg($0) }.joined(separator: " ")
}

private func formatConsoleArg(_ arg: Any) -> String {
    if let str = arg as? String { return str }
    if arg is NSNull { return "null" }
    // NSNumber bridging swallows Bool (true/false become NSNumber(1)/NSNumber(0)).
    // Discriminate via CFBoolean so booleans print "true"/"false" the way Node does.
    if let num = arg as? NSNumber {
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
            return num.boolValue ? "true" : "false"
        }
        return num.stringValue
    }
    if let bool = arg as? Bool { return bool ? "true" : "false" }
    if let dict = arg as? [String: Any] {
        let pairs = dict.map { "\($0.key): \(formatConsoleArg($0.value))" }
        return "{ " + pairs.joined(separator: ", ") + " }"
    }
    if let array = arg as? [Any] {
        return "[ " + array.map { formatConsoleArg($0) }.joined(separator: ", ") + " ]"
    }
    return String(describing: arg)
}
