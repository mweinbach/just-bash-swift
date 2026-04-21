// path-polyfill.js
// POSIX path module. Mirrors the Node.js `path` API surface used by typical
// scripts (join, resolve, dirname, basename, extname, normalize, relative,
// isAbsolute, parse, format) without trying to be a perfect clone of Node.
(function() {
  function normalizeParts(parts, allowAboveRoot) {
    var up = 0;
    for (var i = parts.length - 1; i >= 0; i--) {
      var p = parts[i];
      if (p === '.') parts.splice(i, 1);
      else if (p === '..') { parts.splice(i, 1); up++; }
      else if (up) { parts.splice(i, 1); up--; }
    }
    if (allowAboveRoot) for (; up--; up) parts.unshift('..');
    return parts;
  }
  function trimSurroundingSlashes(s) {
    while (s.length && s.charAt(0) === '/') s = s.slice(1);
    while (s.length && s.charAt(s.length - 1) === '/') s = s.slice(0, -1);
    return s;
  }
  var path = {};
  path.sep = '/';
  path.delimiter = ':';
  path.posix = path;
  path.normalize = function(p) {
    if (typeof p !== 'string') throw new TypeError('Path must be a string');
    if (p.length === 0) return '.';
    var isAbsolute = p.charAt(0) === '/';
    var trailingSlash = p.charAt(p.length - 1) === '/';
    p = normalizeParts(p.split('/').filter(function(s) { return !!s; }), !isAbsolute).join('/');
    if (!p && !isAbsolute) p = '.';
    if (p && trailingSlash) p += '/';
    return (isAbsolute ? '/' : '') + p;
  };
  path.isAbsolute = function(p) { return typeof p === 'string' && p.charAt(0) === '/'; };
  path.join = function() {
    var parts = [];
    for (var i = 0; i < arguments.length; i++) {
      var a = arguments[i];
      if (typeof a !== 'string') throw new TypeError('Path must be a string');
      if (a) parts.push(a);
    }
    return path.normalize(parts.join('/'));
  };
  path.resolve = function() {
    var resolved = '';
    var resolvedAbs = false;
    for (var i = arguments.length - 1; i >= -1 && !resolvedAbs; i--) {
      var p = i >= 0 ? arguments[i] : (typeof process !== 'undefined' && process.cwd ? process.cwd() : '/');
      if (typeof p !== 'string') throw new TypeError('Path must be a string');
      if (!p) continue;
      resolved = p + '/' + resolved;
      resolvedAbs = p.charAt(0) === '/';
    }
    resolved = normalizeParts(resolved.split('/').filter(function(s) { return !!s; }), !resolvedAbs).join('/');
    return (resolvedAbs ? '/' : '') + resolved || '.';
  };
  path.dirname = function(p) {
    if (typeof p !== 'string') throw new TypeError('Path must be a string');
    if (p.length === 0) return '.';
    var idx = p.lastIndexOf('/');
    if (idx === -1) return '.';
    if (idx === 0) return '/';
    return p.slice(0, idx);
  };
  path.basename = function(p, ext) {
    if (typeof p !== 'string') throw new TypeError('Path must be a string');
    var idx = p.lastIndexOf('/');
    var base = idx === -1 ? p : p.slice(idx + 1);
    if (ext && base.length >= ext.length && base.slice(-ext.length) === ext) base = base.slice(0, -ext.length);
    return base;
  };
  path.extname = function(p) {
    if (typeof p !== 'string') throw new TypeError('Path must be a string');
    var base = path.basename(p);
    var idx = base.lastIndexOf('.');
    if (idx <= 0) return '';
    return base.slice(idx);
  };
  path.relative = function(from, to) {
    from = path.resolve(from);
    to = path.resolve(to);
    if (from === to) return '';
    var fromParts = from.slice(1).split('/');
    var toParts = to.slice(1).split('/');
    var samePartsLength = Math.min(fromParts.length, toParts.length);
    for (var i = 0; i < samePartsLength; i++) {
      if (fromParts[i] !== toParts[i]) { samePartsLength = i; break; }
    }
    var outputParts = [];
    for (var i = samePartsLength; i < fromParts.length; i++) outputParts.push('..');
    return outputParts.concat(toParts.slice(samePartsLength)).join('/');
  };
  path.parse = function(p) {
    var root = path.isAbsolute(p) ? '/' : '';
    var dir = path.dirname(p);
    var base = path.basename(p);
    var ext = path.extname(base);
    return { root: root, dir: dir, base: base, ext: ext, name: base.slice(0, base.length - ext.length) };
  };
  path.format = function(o) {
    var dir = o.dir || o.root || '';
    var base = o.base || ((o.name || '') + (o.ext || ''));
    if (!dir) return base;
    if (dir === o.root) return dir + base;
    return dir + '/' + base;
  };
  globalThis.path = path;
})();
