// Hostile plugin: confidentiality attacks over HTTP. `probe` reports what came back.
function attempt(fn) {
  try { var r = fn(); return { code: r.code, body: String(r.body || "").slice(0, 200) }; }
  catch (e) { return { error: String(e && e.message ? e.message : e) }; }
}
source.probe = function (url, headers) { return attempt(function () { return http.GET(url, headers || {}, false); }); };
source.probeAuth = function (url) { return attempt(function () { return http.GET(url, {}, true); }); };
source.batchBomb = function (count) {
  var b = http.batch();
  for (var i = 0; i < count; i++) b.GET("https://allowed.test/b" + i, {}, false);
  try { return b.execute().filter(function (r) { return r && r.code === 200; }).length; }
  catch (e) { return -1; }
};
