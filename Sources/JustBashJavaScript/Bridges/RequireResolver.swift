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
      var builtinNames = new Set(['fs', 'fs/promises', 'path', 'child_process', 'process', 'os', 'url', 'assert', 'util', 'events', 'buffer', 'stream', 'string_decoder', 'querystring', 'module']);
      function normalizeBuiltinName(name) {
        return (typeof name === 'string' && name.indexOf('node:') === 0) ? name.slice(5) : name;
      }
      function tryBuiltin(name) {
        var normalized = normalizeBuiltinName(name);
        if (normalized === 'fs') return globalThis.__jb_fs || globalThis.fs;
        if (normalized === 'fs/promises') return (globalThis.__jb_fs || globalThis.fs || {}).promises;
        if (normalized === 'path') return globalThis.path;
        if (normalized === 'child_process') return globalThis.child_process;
        if (normalized === 'process') return globalThis.process;
        if (normalized === 'os') return globalThis.__jb_os;
        if (normalized === 'url') return globalThis.__jb_url;
        if (normalized === 'assert') return globalThis.__jb_assert;
        if (normalized === 'util') return globalThis.__jb_util;
        if (normalized === 'events') return globalThis.__jb_events;
        if (normalized === 'buffer') return { Buffer: globalThis.Buffer };
        if (normalized === 'stream') return globalThis.__jb_stream;
        if (normalized === 'string_decoder') return globalThis.__jb_string_decoder;
        if (normalized === 'querystring') return globalThis.__jb_querystring;
        if (normalized === 'module') return globalThis.__jb_module;
        return undefined;
      }
      function createRequire(base) {
        var req = function(name) { return globalThis.require(name); };
        req.resolve = function(name) {
          if (tryBuiltin(name) !== undefined) return name;
          if (globalThis.__jb_addon_sources && typeof globalThis.__jb_addon_sources[name] === 'string') return name;
          if (name.indexOf('/') !== -1 || name.indexOf('.') === 0) {
            var src = globalThis.__jb_read_text(name);
            if (typeof src === 'string') return name;
          }
          var err = new Error("Cannot find module '" + name + "'");
          err.code = 'MODULE_NOT_FOUND';
          throw err;
        };
        return req;
      }
      globalThis.__jb_module = { createRequire: createRequire };
      globalThis.require = function(name) {
        if (cache[name] !== undefined) return cache[name];
        if (builtinNames.has(normalizeBuiltinName(name))) {
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
