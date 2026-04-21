// module-shims.js
// Pure-JS polyfills for Node modules whose surface is small enough to live
// here. Native bridges (fs, child_process, fetch, process) are installed
// before this script runs; require() prefers them.
(function() {
  // os
  globalThis.__jb_os = {
    EOL: '\n',
    platform: function() { return 'linux'; },
    type: function() { return 'Linux'; },
    arch: function() { return 'arm64'; },
    cpus: function() { return [{ model: 'JavaScriptCore', speed: 0 }]; },
    homedir: function() { return (globalThis.process && globalThis.process.env && globalThis.process.env.HOME) || '/home/user'; },
    tmpdir: function() { return '/tmp'; },
    hostname: function() { return (globalThis.process && globalThis.process.env && globalThis.process.env.HOSTNAME) || 'localhost'; },
    userInfo: function() { return { username: 'user', uid: 1000, gid: 1000, shell: '/bin/bash', homedir: '/home/user' }; },
    networkInterfaces: function() { return {}; },
    release: function() { return '5.0.0'; },
    totalmem: function() { return 0; },
    freemem: function() { return 0; },
    uptime: function() { return 0; }
  };

  // url
  globalThis.__jb_url = {
    URL: globalThis.URL,
    URLSearchParams: globalThis.URLSearchParams,
    parse: function(s) { try { var u = new URL(s); return { href: u.href, protocol: u.protocol, host: u.host, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search, hash: u.hash }; } catch (e) { return null; } },
    format: function(o) { return o && o.href ? o.href : ''; },
    fileURLToPath: function(s) { return s.replace(/^file:\/\//, ''); },
    pathToFileURL: function(p) { return 'file://' + p; }
  };

  // assert
  function AssertionError(message) {
    this.name = 'AssertionError';
    this.message = message || 'AssertionError';
    if (Error.captureStackTrace) Error.captureStackTrace(this, AssertionError);
  }
  AssertionError.prototype = Object.create(Error.prototype);
  function assertOk(v, message) { if (!v) throw new AssertionError(message || 'AssertionError'); }
  globalThis.__jb_assert = function(v, m) { return assertOk(v, m); };
  globalThis.__jb_assert.ok = assertOk;
  globalThis.__jb_assert.equal = function(a, b, m) { if (a != b) throw new AssertionError(m || (a + ' != ' + b)); };
  globalThis.__jb_assert.notEqual = function(a, b, m) { if (a == b) throw new AssertionError(m || (a + ' == ' + b)); };
  globalThis.__jb_assert.strictEqual = function(a, b, m) { if (a !== b) throw new AssertionError(m || (a + ' !== ' + b)); };
  globalThis.__jb_assert.notStrictEqual = function(a, b, m) { if (a === b) throw new AssertionError(m || (a + ' === ' + b)); };
  globalThis.__jb_assert.deepEqual = function(a, b, m) { if (JSON.stringify(a) != JSON.stringify(b)) throw new AssertionError(m || 'deepEqual failed'); };
  globalThis.__jb_assert.deepStrictEqual = globalThis.__jb_assert.deepEqual;
  globalThis.__jb_assert.AssertionError = AssertionError;

  // util
  globalThis.__jb_util = {
    inspect: function(o) {
      try { return JSON.stringify(o); } catch (e) { return String(o); }
    },
    format: function() {
      var args = Array.prototype.slice.call(arguments);
      if (typeof args[0] !== 'string') return args.map(function(a) { return globalThis.__jb_util.inspect(a); }).join(' ');
      var fmt = args.shift();
      return fmt.replace(/%[sdjifo%]/g, function(t) {
        if (t === '%%') return '%';
        if (!args.length) return t;
        var v = args.shift();
        switch (t) {
          case '%s': return String(v);
          case '%d': case '%i': case '%f': return Number(v).toString();
          case '%j': try { return JSON.stringify(v); } catch (e) { return '[Circular]'; }
          case '%o': return globalThis.__jb_util.inspect(v);
          default: return t;
        }
      }) + (args.length ? ' ' + args.map(function(a) { return globalThis.__jb_util.inspect(a); }).join(' ') : '');
    },
    promisify: function(fn) {
      return function() {
        var args = Array.prototype.slice.call(arguments);
        return new Promise(function(resolve, reject) {
          args.push(function(err, val) { if (err) reject(err); else resolve(val); });
          fn.apply(null, args);
        });
      };
    },
    types: {
      isArray: Array.isArray,
      isDate: function(o) { return o instanceof Date; },
      isPromise: function(o) { return o && typeof o.then === 'function'; },
      isRegExp: function(o) { return o instanceof RegExp; }
    }
  };

  // events.EventEmitter
  function EventEmitter() { this._events = Object.create(null); }
  EventEmitter.prototype.on = function(name, fn) {
    if (!this._events[name]) this._events[name] = [];
    this._events[name].push(fn);
    return this;
  };
  EventEmitter.prototype.addListener = EventEmitter.prototype.on;
  EventEmitter.prototype.off = function(name, fn) {
    if (!this._events[name]) return this;
    this._events[name] = this._events[name].filter(function(f) { return f !== fn; });
    return this;
  };
  EventEmitter.prototype.removeListener = EventEmitter.prototype.off;
  EventEmitter.prototype.removeAllListeners = function(name) {
    if (name) delete this._events[name]; else this._events = Object.create(null);
    return this;
  };
  EventEmitter.prototype.emit = function(name) {
    var args = Array.prototype.slice.call(arguments, 1);
    var fns = this._events[name] || [];
    fns.slice().forEach(function(fn) { try { fn.apply(null, args); } catch (e) {} });
    return fns.length > 0;
  };
  EventEmitter.prototype.once = function(name, fn) {
    var self = this;
    function wrapped() { self.off(name, wrapped); fn.apply(null, arguments); }
    return this.on(name, wrapped);
  };
  EventEmitter.prototype.listenerCount = function(name) { return (this._events[name] || []).length; };
  globalThis.__jb_events = { EventEmitter: EventEmitter, default: EventEmitter };

  // stream — minimal readable/writable shells
  function Readable() { EventEmitter.call(this); this._buffer = []; }
  Readable.prototype = Object.create(EventEmitter.prototype);
  Readable.prototype.push = function(chunk) {
    if (chunk === null) { this.emit('end'); return false; }
    this._buffer.push(chunk); this.emit('data', chunk); return true;
  };
  Readable.prototype.read = function() { return this._buffer.shift(); };
  function Writable() { EventEmitter.call(this); }
  Writable.prototype = Object.create(EventEmitter.prototype);
  Writable.prototype.write = function(chunk) { this.emit('data', chunk); return true; };
  Writable.prototype.end = function(chunk) { if (chunk) this.write(chunk); this.emit('finish'); return this; };
  globalThis.__jb_stream = { Readable: Readable, Writable: Writable };

  // string_decoder
  function StringDecoder(encoding) { this.encoding = encoding || 'utf8'; }
  StringDecoder.prototype.write = function(buf) {
    if (typeof buf === 'string') return buf;
    if (buf && typeof buf.toString === 'function') return buf.toString(this.encoding);
    return '';
  };
  StringDecoder.prototype.end = function() { return ''; };
  globalThis.__jb_string_decoder = { StringDecoder: StringDecoder };

  // querystring
  function qsEncode(s) { return encodeURIComponent(s); }
  function qsDecode(s) { return decodeURIComponent(String(s).replace(/\+/g, ' ')); }
  globalThis.__jb_querystring = {
    parse: function(s) {
      var out = {};
      if (!s) return out;
      s.split('&').forEach(function(pair) {
        var idx = pair.indexOf('=');
        var k = idx === -1 ? pair : pair.slice(0, idx);
        var v = idx === -1 ? '' : pair.slice(idx + 1);
        out[qsDecode(k)] = qsDecode(v);
      });
      return out;
    },
    stringify: function(o) {
      var parts = [];
      Object.keys(o || {}).forEach(function(k) { parts.push(qsEncode(k) + '=' + qsEncode(o[k] == null ? '' : String(o[k]))); });
      return parts.join('&');
    }
  };
})();
