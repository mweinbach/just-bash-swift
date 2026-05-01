import Foundation
import JavaScriptCore
import JustBashFS

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

    func resolveSymlinkPath(_ path: String, relativeTo cwd: String, depth: Int = 0) -> String {
        guard depth < 40 else {
            return execution.cmdCtx.fileSystem.normalizePath(path, relativeTo: cwd)
        }
        let normalized = execution.cmdCtx.fileSystem.normalizePath(path, relativeTo: cwd)
        if normalized == "/" {
            return normalized
        }

        let components = VirtualPath.components(for: normalized)
        var current = ""
        for index in components.indices {
            current = current.isEmpty ? "/\(components[index])" : "\(current)/\(components[index])"
            guard
                let info = try? execution.cmdCtx.fileSystem.fileInfo(path: current, relativeTo: "/"),
                info.kind == .symlink,
                let target = try? execution.cmdCtx.fileSystem.readlink(current, relativeTo: "/")
            else {
                continue
            }

            let targetPath = execution.cmdCtx.fileSystem.normalizePath(target, relativeTo: VirtualPath.dirname(current))
            let remaining = components[(index + 1)...].joined(separator: "/")
            let nextPath = remaining.isEmpty ? targetPath : "\(targetPath)/\(remaining)"
            return resolveSymlinkPath(nextPath, relativeTo: "/", depth: depth + 1)
        }
        return normalized
    }

    let readFileSync: @convention(block) (String) -> JSValue? = { path in
        do {
            let resolvedPath = resolveSymlinkPath(path, relativeTo: execution.cmdCtx.cwd)
            let data = try execution.cmdCtx.fileSystem.readFile(path: resolvedPath, relativeTo: "/")
            return JSValue(object: String(decoding: data, as: UTF8.self), in: context)
        } catch {
            return nil
        }
    }
    context.setObject(readFileSync, forKeyedSubscript: "__jb_read_text" as NSString)
    context.setObject(execution.scriptPath ?? "", forKeyedSubscript: "__jb_script_path" as NSString)
    context.setObject(execution.cmdCtx.cwd, forKeyedSubscript: "__jb_cwd" as NSString)
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
      function fileURLToPathname(value) {
        return String(value || '').replace(/^file:\\/\\//, '').replace(/[?#][\\s\\S]*$/, '');
      }
      function unique(list) {
        var out = [];
        var seen = {};
        for (var i = 0; i < list.length; i++) {
          var value = normalizePath(list[i] || '');
          if (!value || seen[value]) continue;
          seen[value] = true;
          out.push(value);
        }
        return out;
      }
      function candidateWithExtensions(base) {
        return [base, base + '.js', base + '.mjs', base + '/index.js', base + '/index.mjs'];
      }
      function findReadable(candidates) {
        for (var i = 0; i < candidates.length; i++) {
          var src = globalThis.__jb_read_text(candidates[i]);
          if (typeof src === 'string') return { path: candidates[i], source: src };
        }
        return undefined;
      }
      function packageParts(name) {
        if (!name || name.charAt(0) === '.' || name.charAt(0) === '/') return undefined;
        var parts = String(name).split('/');
        if (parts[0].charAt(0) === '@') {
          if (parts.length < 2) return undefined;
          return { packageName: parts[0] + '/' + parts[1], subpath: parts.slice(2).join('/') };
        }
        return { packageName: parts[0], subpath: parts.slice(1).join('/') };
      }
      function nodeModuleBases(baseDir) {
        var start = normalizePath(baseDir || globalThis.__jb_script_dir || globalThis.__jb_cwd || '/workspace');
        var bases = [start, globalThis.__jb_cwd || '', globalThis.__jb_script_dir || '', '/workspace', '/'];
        var current = start;
        while (current && current !== '/') {
          bases.push(current);
          current = dirname(current);
        }
        bases.push('/');
        return unique(bases).map(function(base) { return normalizePath(base + '/node_modules'); });
      }
      function exportTarget(packageJson, subpath) {
        var exportName = subpath ? './' + subpath : '.';
        var exportsValue = packageJson && packageJson.exports;
        var value = exportsValue && exportsValue[exportName];
        var target = pickPackageExport(value);
        if (target) return target;
        if (!subpath) return packageJson.module || packageJson.main || './index.js';
        return './' + subpath;
      }
      function pickPackageExport(value) {
        if (typeof value === 'string') return value;
        if (!value || typeof value !== 'object') return undefined;
        var conditions = ['import', 'default', 'node', 'require', 'browser'];
        for (var i = 0; i < conditions.length; i++) {
          var picked = pickPackageExport(value[conditions[i]]);
          if (picked) return picked;
        }
        return undefined;
      }
      function resolvePackage(name, baseDir) {
        var parts = packageParts(name);
        if (!parts) return undefined;
        var bases = nodeModuleBases(baseDir);
        for (var i = 0; i < bases.length; i++) {
          var packageDir = normalizePath(bases[i] + '/' + parts.packageName);
          var packageJsonText = globalThis.__jb_read_text(packageDir + '/package.json');
          if (typeof packageJsonText !== 'string') continue;
          var packageJson = {};
          try { packageJson = JSON.parse(packageJsonText); } catch (e) {}
          var target = exportTarget(packageJson, parts.subpath);
          if (!target) continue;
          if (target.indexOf('./') === 0) target = target.slice(2);
          var resolved = findReadable(candidateWithExtensions(normalizePath(packageDir + '/' + target)));
          if (resolved) return resolved;
        }
        return undefined;
      }
      function resolveSource(name, baseDir) {
        if (String(name).indexOf('file://') === 0) {
          return findReadable(candidateWithExtensions(fileURLToPathname(name)));
        } else if (name.indexOf('.') === 0) {
          var base = normalizePath((baseDir || globalThis.__jb_script_dir || '') + '/' + name);
          return findReadable(candidateWithExtensions(base));
        }
        if (String(name).charAt(0) === '/') {
          return findReadable(candidateWithExtensions(name));
        }
        return resolvePackage(name, baseDir);
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
      function moduleImportStatementToCjs(statement, importIndex) {
        var trimmed = statement.trim().replace(/;\\s*$/, '');
        var m = trimmed.match(/^import\\s*([\\s\\S]+?)\\s*from\\s*(["'])([^"']+)\\2$/);
        if (m) {
          var clause = m[1].trim();
          var spec = m[3];
          if (clause.indexOf('{') === 0) {
            return 'const { ' + namedImportPattern(clause.slice(1, -1)) + ' } = __jb_require(' + JSON.stringify(spec) + ');';
          }
          if (clause.indexOf('* as ') === 0) {
            return 'const ' + clause.slice(5).trim() + ' = __jb_require(' + JSON.stringify(spec) + ');';
          }
          if (clause.indexOf(',') !== -1) {
            var parts = clause.split(',');
            var local = '__jb_import_' + importIndex;
            return [
              'const ' + local + ' = __jb_require(' + JSON.stringify(spec) + ');',
              'const ' + parts[0].trim() + ' = __jb_import_default(' + local + ');',
              'const { ' + namedImportPattern(parts.slice(1).join(',').trim().slice(1, -1)) + ' } = ' + local + ';'
            ].join('\\n');
          }
          return 'const ' + clause + ' = __jb_import_default(__jb_require(' + JSON.stringify(spec) + '));';
        }
        m = trimmed.match(/^import\\s*(["'])([^"']+)\\1$/);
        if (m) return '__jb_require(' + JSON.stringify(m[2]) + ');';
        return statement;
      }
      function moduleExportListToCjs(body) {
        var out = [];
        body.split(',').forEach(function(part) {
          var trimmed = part.trim();
          if (!trimmed) return;
          var bits = trimmed.split(/\\s+as\\s+/);
          var source = bits[0].trim();
          var target = (bits[1] || bits[0]).trim();
          out.push('exports[' + JSON.stringify(target) + '] = ' + source + ';');
        });
        return out.join('\\n');
      }
      function isIdentifierBoundary(ch) {
        return !ch || !/[A-Za-z0-9_$]/.test(ch);
      }
      function findStatementEnd(src, start) {
        var quote = null;
        var escaped = false;
        var comment = null;
        for (var i = start; i < src.length; i++) {
          var ch = src.charAt(i);
          var next = src.charAt(i + 1);
          if (comment === 'line') {
            if (ch === '\\n' || ch === '\\r') comment = null;
            continue;
          }
          if (comment === 'block') {
            if (ch === '*' && next === '/') { comment = null; i++; }
            continue;
          }
          if (quote) {
            if (escaped) { escaped = false; continue; }
            if (ch === '\\\\') { escaped = true; continue; }
            if (ch === quote) quote = null;
            continue;
          }
          if (ch === '/' && next === '/') { comment = 'line'; i++; continue; }
          if (ch === '/' && next === '*') { comment = 'block'; i++; continue; }
          if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue; }
          if (ch === ';') return i + 1;
        }
        return src.length;
      }
      function transformTopLevelModuleSyntax(src) {
        var out = '';
        var last = 0;
        var quote = null;
        var escaped = false;
        var comment = null;
        var importIndex = 0;
        for (var i = 0; i < src.length; i++) {
          var ch = src.charAt(i);
          var next = src.charAt(i + 1);
          if (comment === 'line') {
            if (ch === '\\n' || ch === '\\r') comment = null;
            continue;
          }
          if (comment === 'block') {
            if (ch === '*' && next === '/') { comment = null; i++; }
            continue;
          }
          if (quote) {
            if (escaped) { escaped = false; continue; }
            if (ch === '\\\\') { escaped = true; continue; }
            if (ch === quote) quote = null;
            continue;
          }
          if (ch === '/' && next === '/') { comment = 'line'; i++; continue; }
          if (ch === '/' && next === '*') { comment = 'block'; i++; continue; }
          if (ch === '"' || ch === "'" || ch === '`') { quote = ch; continue; }

          if (src.slice(i, i + 6) === 'import' && isIdentifierBoundary(src.charAt(i - 1)) && isIdentifierBoundary(src.charAt(i + 6))) {
            var afterImport = i + 6;
            while (/\\s/.test(src.charAt(afterImport))) afterImport++;
            if (src.charAt(afterImport) === '(' || src.slice(i, i + 11) === 'import.meta') continue;
            var importEnd = findStatementEnd(src, i);
            out += src.slice(last, i) + moduleImportStatementToCjs(src.slice(i, importEnd), importIndex++);
            last = importEnd;
            i = importEnd - 1;
            continue;
          }

          if (src.slice(i, i + 6) === 'export' && isIdentifierBoundary(src.charAt(i - 1)) && isIdentifierBoundary(src.charAt(i + 6))) {
            var cursor = i + 6;
            while (/\\s/.test(src.charAt(cursor))) cursor++;
            if (src.charAt(cursor) === '{') {
              var exportEnd = findStatementEnd(src, i);
              var statement = src.slice(i, exportEnd).trim().replace(/;\\s*$/, '');
              var m = statement.match(/^export\\s*\\{([\\s\\S]*)\\}$/);
              if (m) {
                out += src.slice(last, i) + moduleExportListToCjs(m[1]);
                last = exportEnd;
                i = exportEnd - 1;
              }
            }
          }
        }
        return out + src.slice(last);
      }
      function transpileModuleSource(src, filename) {
        var moduleDir = dirname(filename || globalThis.__jb_script_path || '');
        var exportsToAssign = [];
        var lines = transformTopLevelModuleSyntax(String(src || ''))
          .replace(/\\bimport\\.meta\\.url\\b/g, JSON.stringify(fileURL(filename)))
          .replace(/\\bimport\\s*\\(/g, '__jb_dynamic_import(' + JSON.stringify(moduleDir) + ', ')
          .split('\\n');
        var out = [];
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i];
          var trimmed = line.trim();
          var m = trimmed.match(/^import\\s+(.+?)\\s+from\\s+["']([^"']+)["']\\s*;?(.*)$/);
          if (m) {
            var clause = m[1].trim();
            var spec = m[2];
            var remainder = m[3] || '';
            if (clause.indexOf('{') === 0) {
              out.push('const { ' + namedImportPattern(clause.slice(1, -1)) + ' } = __jb_require(' + JSON.stringify(spec) + ');');
            } else if (clause.indexOf('* as ') === 0) {
              out.push('const ' + clause.slice(5).trim() + ' = __jb_require(' + JSON.stringify(spec) + ');');
            } else if (clause.indexOf(',') !== -1) {
              var parts = clause.split(',');
              var local = '__jb_import_' + i;
              out.push('const ' + local + ' = __jb_require(' + JSON.stringify(spec) + ');');
              out.push('const ' + parts[0].trim() + ' = __jb_import_default(' + local + ');');
              out.push('const { ' + namedImportPattern(parts.slice(1).join(',').trim().slice(1, -1)) + ' } = ' + local + ';');
            } else {
              out.push('const ' + clause + ' = __jb_import_default(__jb_require(' + JSON.stringify(spec) + '));');
            }
            if (remainder.trim()) out.push(remainder);
            continue;
          }
          m = trimmed.match(/^import\\s+["']([^"']+)["']\\s*;?(.*)$/);
          if (m) {
            out.push('__jb_require(' + JSON.stringify(m[1]) + ');');
            if ((m[2] || '').trim()) out.push(m[2]);
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
        if (typeof base === 'string' && base.indexOf('file://') === 0) baseDir = dirname(fileURLToPathname(base));
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
        var resolved = resolveSource(name, baseDir);
        if (resolved) {
          var cacheKey = resolved.path;
          if (cache[cacheKey] !== undefined) return cache[cacheKey];
          var src = transpileModuleSource(resolved.source, resolved.path);
          var moduleObj = { exports: {} };
          var localRequire = makeRequire(dirname(resolved.path));
          var previousRequire = globalThis.require;
          globalThis.require = localRequire;
          var fn = new Function('module', 'exports', '__filename', '__dirname', '__jb_import_default', '__jb_require', src + '\\n;return module.exports;');
          try {
            var ret = fn(moduleObj, moduleObj.exports, resolved.path, dirname(resolved.path), importDefault, localRequire);
          } finally {
            globalThis.require = previousRequire;
          }
          cache[cacheKey] = ret || moduleObj.exports;
          return cache[cacheKey];
        }
        var err = new Error("Cannot find module '" + name + "'");
        err.code = 'MODULE_NOT_FOUND';
        throw err;
      }
      globalThis.require = makeRequire(globalThis.__jb_script_dir || '');
      globalThis.__jb_require = globalThis.require;
    })();
    """
    context.evaluateScript(resolverSetup)
}
