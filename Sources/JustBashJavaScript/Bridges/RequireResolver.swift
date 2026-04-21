import Foundation
import JavaScriptCore

/// Installs a CommonJS-style `require()` resolver.
///
/// Resolution order:
/// 1. Built-in shim modules (fs, path, child_process, process, console,
///    Buffer, fetch, URL, URLSearchParams, plus the JS-side polyfills that
///    `module-shims.js` registers).
/// 2. Host-provided addon modules from `BashJavaScriptOptions.addonModules`.
/// 3. Filesystem-relative paths via `ctx.fileSystem`.
func installRequireResolver(into context: JSContext, execution: JSCExecutionContext) {
    // Build the addon source table on the JS side once, indexed by name.
    let addonsObject = JSValue(newObjectIn: context)!
    for module in execution.options.addonModules {
        addonsObject.setObject(module.source, forKeyedSubscript: module.name as NSString)
    }
    context.setObject(addonsObject, forKeyedSubscript: "__jb_addon_sources" as NSString)

    let readFileSync: @convention(block) (String) -> JSValue? = { path in
        do {
            let data = try execution.cmdCtx.fileSystem.readFile(path: path, relativeTo: execution.cmdCtx.cwd)
            return JSValue(object: String(decoding: data, as: UTF8.self), in: context)
        } catch {
            return nil
        }
    }
    context.setObject(readFileSync, forKeyedSubscript: "__jb_read_text" as NSString)

    let resolverSetup = """
    (function() {
      var cache = {};
      var builtinNames = new Set(['fs', 'path', 'child_process', 'process', 'os', 'url', 'assert', 'util', 'events', 'buffer', 'stream', 'string_decoder', 'querystring']);
      function tryBuiltin(name) {
        if (name === 'fs') return globalThis.__jb_fs || globalThis.fs;
        if (name === 'path') return globalThis.path;
        if (name === 'child_process') return globalThis.child_process;
        if (name === 'process') return globalThis.process;
        if (name === 'os') return globalThis.__jb_os;
        if (name === 'url') return globalThis.__jb_url;
        if (name === 'assert') return globalThis.__jb_assert;
        if (name === 'util') return globalThis.__jb_util;
        if (name === 'events') return globalThis.__jb_events;
        if (name === 'buffer') return { Buffer: globalThis.Buffer };
        if (name === 'stream') return globalThis.__jb_stream;
        if (name === 'string_decoder') return globalThis.__jb_string_decoder;
        if (name === 'querystring') return globalThis.__jb_querystring;
        return undefined;
      }
      globalThis.require = function(name) {
        if (cache[name] !== undefined) return cache[name];
        if (builtinNames.has(name)) {
          var b = tryBuiltin(name);
          if (b !== undefined) { cache[name] = b; return b; }
        }
        var addonSrc = globalThis.__jb_addon_sources && globalThis.__jb_addon_sources[name];
        if (typeof addonSrc === 'string') {
          var moduleObj = { exports: {} };
          var fn = new Function('module', 'exports', 'require', addonSrc + '\\n;return module.exports;');
          var ret = fn(moduleObj, moduleObj.exports, globalThis.require);
          cache[name] = ret || moduleObj.exports;
          return cache[name];
        }
        if (name.indexOf('/') !== -1 || name.indexOf('.') === 0) {
          var src = globalThis.__jb_read_text(name);
          if (typeof src === 'string') {
            var moduleObj = { exports: {} };
            var fn = new Function('module', 'exports', 'require', src + '\\n;return module.exports;');
            var ret = fn(moduleObj, moduleObj.exports, globalThis.require);
            cache[name] = ret || moduleObj.exports;
            return cache[name];
          }
        }
        var err = new Error("Cannot find module '" + name + "'");
        err.code = 'MODULE_NOT_FOUND';
        throw err;
      };
    })();
    """
    context.evaluateScript(resolverSetup)
}
