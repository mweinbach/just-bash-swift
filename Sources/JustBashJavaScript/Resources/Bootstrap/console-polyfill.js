// console-polyfill.js
// Default console implementation; replaced by ProcessBridge with capture-backed
// versions during context init. Kept here so the polyfill exists if a bootstrap
// script tries to call console before installProcessBridge runs.
if (typeof globalThis.console === 'undefined') {
  globalThis.console = {
    log: function() {},
    info: function() {},
    debug: function() {},
    warn: function() {},
    error: function() {}
  };
}
