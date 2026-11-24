// Hostile plugin: availability attacks. Each function tries to exhaust time,
// threads, timers or the log; MaliciousPluginTests asserts each is contained.
source.spin = function (ms) {            // a pure CPU loop: nothing in-process can interrupt it
  var end = Date.now() + ms;
  while (Date.now() < end) {}
  return "finished";
};
source.quick = function () { return 42; };
source.fail = function () { throw new Error("boom"); };  // a call that throws: its machine is not reused
source.hostCallSpin = function (ms) {     // a loop of HTTP calls: after its deadline every call fails at once
  var end = Date.now() + ms, n = 0;
  while (Date.now() < end) {
    try { http.GET("https://allowed.test/spin", {}, false); } catch (e) {}
    n++;
  }
  return n;
};
source.sleepForever = function () { for (var i = 0; i < 1000; i++) bridge.sleep(1000000); return "woke"; };
source.timerFlood = function () {
  globalThis.__fired = 0;
  for (var i = 0; i < 10000; i++) setTimeout(function () { globalThis.__fired++; }, 1);
  return 0;
};
source.timersFired = function () { return globalThis.__fired || 0; };
source.logFlood = function () { for (var i = 0; i < 20000; i++) log("flood " + i); return 0; };
source.neverSettles = function () { return new Promise(function () {}); };
source.setMarker = function (v) { globalThis.__marker = v; return v; };
source.getMarker = function () { return globalThis.__marker === undefined ? "unset" : globalThis.__marker; };
