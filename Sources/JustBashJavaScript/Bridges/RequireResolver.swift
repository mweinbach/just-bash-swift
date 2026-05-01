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
    context.setObject(execution.scriptPath ?? "", forKeyedSubscript: "__jb_script_path" as NSString)
    let scriptDirectory = execution.scriptPath.map { ($0 as NSString).deletingLastPathComponent } ?? execution.cmdCtx.cwd
    context.setObject(scriptDirectory, forKeyedSubscript: "__jb_script_dir" as NSString)

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
      function dirname(path) {
        path = String(path || '');
        var idx = path.lastIndexOf('/');
        if (idx < 0) return '';
        if (idx === 0) return '/';
        return path.slice(0, idx);
      }
      function normalizePath(path) {
        var absolute = String(path || '').charAt(0) === '/';
        var parts = String(path || '').split('/');
        var out = [];
        for (var i = 0; i < parts.length; i++) {
          var part = parts[i];
          if (!part || part === '.') continue;
          if (part === '..') out.pop();
          else out.push(part);
        }
        return (absolute ? '/' : '') + out.join('/');
      }
      function fileURL(path) {
        if (!path) return 'file:///workspace/<anonymous>.mjs';
        if (String(path).indexOf('file://') === 0) return path;
        return 'file://' + normalizePath(path);
      }
      function resolveSource(name, baseDir) {
        var candidates = [];
        if (String(name).indexOf('file://') === 0) {
          candidates.push(String(name).replace(/^file:\\/\\//, ''));
        } else if (name.indexOf('.') === 0) {
          var base = normalizePath((baseDir || globalThis.__jb_script_dir || '') + '/' + name);
          candidates.push(base, base + '.js', base + '.mjs', base + '/index.js', base + '/index.mjs');
        } else {
          candidates.push(name);
        }
        for (var i = 0; i < candidates.length; i++) {
          var src = globalThis.__jb_read_text(candidates[i]);
          if (typeof src === 'string') return { path: candidates[i], source: src };
        }
        return undefined;
      }
      function importDefault(value) {
        if (value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'default')) {
          return value.default;
        }
        return value;
      }
      function namedImportPattern(body) {
        return body.replace(/\\bas\\b/g, ':');
      }
      function transpileModuleSource(src, filename) {
        var moduleDir = dirname(filename || globalThis.__jb_script_path || '');
        var exportsToAssign = [];
        var lines = String(src || '')
          .replace(/\\bimport\\.meta\\.url\\b/g, JSON.stringify(fileURL(filename)))
          .replace(/\\bimport\\s*\\(/g, '__jb_dynamic_import(' + JSON.stringify(moduleDir) + ', ')
          .split('\\n');
        var out = [];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i];
          var trimmed = line.trim();
          var m = trimmed.match(/^import\\s+(.+?)\\s+from\\s+["']([^"']+)["']\\s*;?$/);
          if (m) {
            var clause = m[1].trim();
            var spec = m[2];
            if (clause.indexOf('{') === 0) {
              out.push('const { ' + namedImportPattern(clause.slice(1, -1)) + ' } = require(' + JSON.stringify(spec) + ');');
            } else if (clause.indexOf('* as ') === 0) {
              out.push('const ' + clause.slice(5).trim() + ' = require(' + JSON.stringify(spec) + ');');
            } else if (clause.indexOf(',') !== -1) {
              var parts = clause.split(',');
              var local = '__jb_import_' + i;
              out.push('const ' + local + ' = require(' + JSON.stringify(spec) + ');');
              out.push('const ' + parts[0].trim() + ' = __jb_import_default(' + local + ');');
              out.push('const { ' + namedImportPattern(parts.slice(1).join(',').trim().slice(1, -1)) + ' } = ' + local + ';');
            } else {
              out.push('const ' + clause + ' = __jb_import_default(require(' + JSON.stringify(spec) + '));');
            }
            continue;
          }
          m = trimmed.match(/^import\\s+["']([^"']+)["']\\s*;?$/);
          if (m) {
            out.push('require(' + JSON.stringify(m[1]) + ');');
            continue;
          }
          m = line.match(/^(\\s*)export\\s+(async\\s+function|function|class)\\s+([A-Za-z_$][\\w$]*)/);
          if (m) {
            exportsToAssign.push(m[3]);
            out.push(line.replace(/^(\\s*)export\\s+/, '$1'));
            continue;
          }
          m = line.match(/^(\\s*)export\\s+(const|let|var)\\s+([A-Za-z_$][\\w$]*)/);
          if (m) {
            exportsToAssign.push(m[3]);
            out.push(line.replace(/^(\\s*)export\\s+/, '$1'));
            continue;
          }
          m = trimmed.match(/^export\\s+\\{(.+)\\}\\s*;?$/);
          if (m) {
            m[1].split(',').forEach(function(part) {
              var bits = part.trim().split(/\\s+as\\s+/);
              var source = bits[0].trim();
              var target = (bits[1] || bits[0]).trim();
              out.push('exports[' + JSON.stringify(target) + '] = ' + source + ';');
            });
            continue;
          }
          m = line.match(/^(\\s*)export\\s+default\\s+/);
          if (m) {
            out.push(line.replace(/^(\\s*)export\\s+default\\s+/, '$1module.exports.default = '));
            continue;
          }
          out.push(line);
        }
        for (var j = 0; j < exportsToAssign.length; j++) {
          out.push('exports[' + JSON.stringify(exportsToAssign[j]) + '] = ' + exportsToAssign[j] + ';');
        }
        return out.join('\\n');
      }
      globalThis.__jb_transpile_esm = transpileModuleSource;
      globalThis.__jb_import_default = importDefault;
      globalThis.__jb_dynamic_import = function(baseDir, name) {
        return Promise.resolve(loadModule(name, baseDir));
      };
      function makeRequire(baseDir) {
        var req = function(name) { return loadModule(name, baseDir); };
        req.resolve = function(name) {
          if (tryBuiltin(name) !== undefined) return name;
          if (globalThis.__jb_addon_sources && typeof globalThis.__jb_addon_sources[name] === 'string') return name;
          var resolved = resolveSource(name, baseDir);
          if (resolved) return resolved.path;
          var err = new Error("Cannot find module '" + name + "'");
          err.code = 'MODULE_NOT_FOUND';
          throw err;
        };
        return req;
      }
      function createRequire(base) {
        var baseDir = globalThis.__jb_script_dir || '';
        if (typeof base === 'string' && base.indexOf('file://') === 0) baseDir = dirname(base.replace(/^file:\\/\\//, ''));
        else if (typeof base === 'string' && base.length) baseDir = dirname(base);
        return makeRequire(baseDir);
      }
      globalThis.__jb_module = { createRequire: createRequire };
      function loadModule(name, baseDir) {
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
          var resolved = resolveSource(name, baseDir);
          if (resolved) {
            var cacheKey = resolved.path;
            if (cache[cacheKey] !== undefined) return cache[cacheKey];
            var src = transpileModuleSource(resolved.source, resolved.path);
            var moduleObj = { exports: {} };
            var localRequire = makeRequire(dirname(resolved.path));
            var fn = new Function('module', 'exports', 'require', '__filename', '__dirname', '__jb_import_default', src + '\\n;return module.exports;');
            var ret = fn(moduleObj, moduleObj.exports, localRequire, resolved.path, dirname(resolved.path), importDefault);
            cache[cacheKey] = ret || moduleObj.exports;
            return cache[cacheKey];
          }
        }
        var err = new Error("Cannot find module '" + name + "'");
        err.code = 'MODULE_NOT_FOUND';
        throw err;
      }
      globalThis.require = makeRequire(globalThis.__jb_script_dir || '');
    })();
    """
    context.evaluateScript(resolverSetup)
}
