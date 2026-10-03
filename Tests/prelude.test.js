// Run with: node Tests/prelude.test.js
// Exercises prelude.js in a plain V8 context with a fake __native, mirroring what the Swift host provides.
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");

const preludeSrc = fs.readFileSync(path.join(__dirname, "../Jaybird/Plugin/Resources/prelude.js"), "utf8");

function makeContext(httpImpl) {
  const logs = [];
  const sandbox = {
    __native: {
      log: (s) => logs.push(s),
      toast: () => {},
      isLoggedIn: () => false,
      hasPackage: () => true,
      setTimeout: () => 1,
      clearTimeout: () => {},
      sleep: () => {},
      http: httpImpl || ((reqs) => JSON.stringify(JSON.parse(reqs).map(() => ({ code: 200, url: "u", body: "{}", headers: {} })))),
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(preludeSrc, ctx);
  ctx.__logs = logs;
  return ctx;
}
const run = (ctx, code) => vm.runInContext(code, ctx);
let passed = 0;
function test(name, fn) { fn(); passed++; console.log("ok  " + name); }

test("ScriptException single and double argument forms", () => {
  const c = makeContext();
  assert.strictEqual(run(c, "new ScriptException('boom').plugin_type"), "ScriptException");
  assert.strictEqual(run(c, "new ScriptException('boom').message"), "boom");
  assert.strictEqual(run(c, "new ScriptException('UnavailableException','gone').plugin_type"), "UnavailableException");
  assert.strictEqual(run(c, "new LoginRequiredException('x').plugin_type"), "ScriptLoginRequiredException");
  assert.strictEqual(run(c, "new TimeoutException('x').plugin_type"), "ScriptTimeoutException");
  assert.strictEqual(run(c, "new LoginRequiredException('x') instanceof ScriptException"), true);
  assert.strictEqual(run(c, "new LoginRequiredException('x') instanceof Error"), true);
});

test("pager invoke / nextPage with replacement semantics", () => {
  const c = makeContext();
  run(c, `
    class P extends VideoPager {
      constructor(page) { super([new PlatformVideo({id:new PlatformID('T','v'+page,'p'),name:'v'+page,url:'https://t/'+page})], page < 2, {page}); this.page = page; }
      nextPage() { return new P(this.page + 1); }
    }
    source.getHome = function() { return new P(0); };
  `);
  const first = JSON.parse(run(c, "__jb.invoke('getHome','[]','pager')"));
  assert.strictEqual(first.ok, true);
  assert.strictEqual(first.value.results[0].name, "v0");
  assert.strictEqual(first.value.results[0].contentType, 1);
  assert.strictEqual(first.value.hasMore, true);
  const second = JSON.parse(run(c, `__jb.nextPage(${first.value.pager})`));
  assert.strictEqual(second.value.results[0].name, "v1");
  const third = JSON.parse(run(c, `__jb.nextPage(${first.value.pager})`));
  assert.strictEqual(third.value.results[0].name, "v2");
  assert.strictEqual(third.value.hasMore, false);
});

test("errors map to plugin_type payloads", () => {
  const c = makeContext();
  run(c, `
    source.a = function(){ throw new UnavailableException('nope'); };
    source.b = function(){ throw new Error('plain'); };
    source.c = function(){ throw new CaptchaRequiredException('https://x','<html>'); };
    source.d = function(){ throwException('AgeException','too young'); };
    source.e = function(){ return new ScriptException('CriticalException','returned not thrown'); };
    source.f = function(){ throw new ReloadRequiredException('reload','state'); };
  `);
  const err = (n) => JSON.parse(run(c, `__jb.invoke('${n}','[]','value')`)).error;
  assert.deepStrictEqual(err("a"), { type: "UnavailableException", msg: "nope" });
  assert.strictEqual(err("b").type, "ScriptExecutionException");
  assert.strictEqual(err("b").msg, "plain");
  assert.strictEqual(err("c").type, "CaptchaRequiredException");
  assert.strictEqual(err("c").url, "https://x");
  assert.deepStrictEqual(err("d"), { type: "AgeException", msg: "too young" });
  assert.strictEqual(err("e").type, "CriticalException");
  assert.strictEqual(err("f").reloadData, "state");
  const missing = JSON.parse(run(c, "__jb.invoke('nothing','[]','value')"));
  assert.strictEqual(missing.error.type, "ScriptImplementationException");
});

test("details preparation retains request modifiers and getters via handles", () => {
  const c = makeContext();
  run(c, `
    source.getContentDetails = function(url) {
      return new PlatformVideoDetails({
        id: new PlatformID('T','1','p'), name: 'n', url: url, description: 'd', viewCount: 5, isLive: false,
        video: new VideoSourceDescriptor([ new VideoUrlSource({ url: 'https://v/1.mp4', height: 720, width: 1280, container: 'video/mp4',
          requestModifier: new RequestModifier({ allowByteSkip: false, modifyRequest: function(u,h){ return { url: u + '?x=1', headers: Object.assign({}, h, {A:'b'}) }; } }) }) ]),
        subtitles: [{ name: 'en', getSubtitles: function(){ return 'WEBVTT'; } }],
        getComments: function(){ return new CommentPager([new PlatformComment({message:'hi', getReplies: function(){ return new CommentPager([new PlatformComment({message:'reply'})], false); }})], false); },
        getPlaybackTracker: function(){ return { nextRequest: 500, onProgress: function(s,p){ this.last = s; } }; }
      });
    };
  `);
  const d = JSON.parse(run(c, "__jb.invoke('getContentDetails','[\"https://t/1\"]','details')")).value;
  assert.strictEqual(d.has_getComments, true);
  assert.strictEqual(d.has_getPlaybackTracker, true);
  const src = d.video.videoSources[0];
  assert.strictEqual(src.requestModifier.allowByteSkip, false);
  const mod = JSON.parse(run(c, `__jb.callHandle(${src.requestModifier.handle},'modifyRequest',JSON.stringify(['https://v/1.mp4',{}]))`)).value;
  assert.strictEqual(mod.url, "https://v/1.mp4?x=1");
  assert.strictEqual(mod.headers.A, "b");
  const sub = JSON.parse(run(c, `__jb.callHandle(${d.subtitles[0].getSubtitlesHandle},'getSubtitles','[]')`)).value;
  assert.strictEqual(sub, "WEBVTT");
  const comments = JSON.parse(run(c, `__jb.callHandleForPager(${d.__handle},'getComments','[]')`)).value;
  assert.strictEqual(comments.results[0].message, "hi");
  const replies = JSON.parse(run(c, `__jb.subComments(${comments.results[0].__handle})`)).value;
  assert.strictEqual(replies.results[0].message, "reply");
  const tracker = JSON.parse(run(c, `__jb.callHandleForHandle(${d.__handle},'getPlaybackTracker','[]')`)).value;
  assert.strictEqual(tracker.nextRequest, 500);
  assert.strictEqual(run(c, `__jb.hasMember(${tracker.handle},'onProgress')`), true);
  assert.strictEqual(run(c, `__jb.hasMember(${tracker.handle},'onInit')`), false);
  run(c, `__jb.callHandle(${tracker.handle},'onProgress',JSON.stringify([12,true]))`);
});

test("playlist kind retains the contents pager", () => {
  const c = makeContext();
  run(c, `
    source.getPlaylist = function(url) {
      return new PlatformPlaylistDetails({ id: new PlatformID('T','pl','p'), name: 'List', url: url, videoCount: 2,
        contents: new VideoPager([new PlatformVideo({ id: new PlatformID('T','a','p'), name: 'a', url: 'https://t/a' })], true, {}) });
    };
  `);
  const pl = JSON.parse(run(c, "__jb.invoke('getPlaylist','[\"https://t/pl\"]','playlist')")).value;
  assert.strictEqual(pl.name, "List");
  assert.strictEqual(pl.contents.results[0].name, "a");
  assert.ok(pl.contents.pager > 0);
  assert.strictEqual(pl.contents.hasMore, true);
});

test("http: single, batch with DUMMY, bytes, and errors", () => {
  const seen = [];
  const c = makeContext((reqs, parallel) => {
    const list = JSON.parse(reqs);
    seen.push({ list, parallel });
    return JSON.stringify(list.map((r, i) => {
      if (r.control) return { code: 200 };
      if (r.url.includes("fail")) return { error: "boom" };
      if (r.url.includes("blocked")) return { error: "Attempted to access non-whitelisted url", errorType: "ScriptImplementationException" };
      if (r.bytes) return { code: 200, url: r.url, bodyBase64: "AQID", headers: {} };
      return { code: r.url.includes("404") ? 404 : 200, url: r.url, body: "b" + i, headers: { "content-type": ["x"] } };
    }));
  });
  run(c, "var http = __makeHttp();");
  const single = JSON.parse(run(c, "JSON.stringify(http.GET('https://a/1', {X:'y'}, false))"));
  assert.strictEqual(single.isOk, true);
  assert.strictEqual(seen[0].list[0].headers.X, "y");
  assert.strictEqual(seen[0].list[0].useAuth, false);
  const batch = JSON.parse(run(c, "JSON.stringify(http.batch().GET('https://a/1',{},false).DUMMY().POST('https://a/404','{}',{},true).execute())"));
  assert.strictEqual(batch.length, 3);
  assert.strictEqual(batch[1], null);
  assert.strictEqual(batch[2].code, 404);
  assert.strictEqual(batch[2].isOk, false);
  const last = seen[seen.length - 1];
  assert.strictEqual(last.parallel, true);
  assert.strictEqual(last.list[1].useAuth, true);
  assert.strictEqual(last.list[1].body.text, "{}");
  const bytes = JSON.parse(run(c, "JSON.stringify(http.GET('https://a/b', {}, false, true).body)"));
  assert.deepStrictEqual(bytes, [1, 2, 3]);
  assert.throws(() => run(c, "http.GET('https://a/fail', {}, false)"), /boom/);
  const blocked = run(c, "try { http.GET('https://a/blocked', {}, false); 'no' } catch (e) { e.plugin_type }");
  assert.strictEqual(blocked, "ScriptImplementationException");
  const clientSetup = run(c, "var cl = http.newClient(false); cl.setDefaultHeaders({U:'1'}); cl.GET('https://a/1', {}).code");
  assert.strictEqual(clientSetup, 200);
  const lastReq = seen[seen.length - 1].list[0];
  assert.strictEqual(lastReq.headers.U, "1");
  assert.ok(lastReq.clientId.startsWith("client-"));
});

test("URL and URLSearchParams behave like the web versions for common cases", () => {
  const c = makeContext();
  assert.strictEqual(run(c, "new URL('https://Example.com:8080/a/b/../c?x=1&y=2#frag').pathname"), "/a/c");
  assert.strictEqual(run(c, "new URL('https://example.com/a?x=1').searchParams.get('x')"), "1");
  assert.strictEqual(run(c, "new URL('https://example.com/p').host"), "example.com");
  assert.strictEqual(run(c, "new URL('/rel/x?q=1','https://example.com/base/y').href"), "https://example.com/rel/x?q=1");
  assert.strictEqual(run(c, "var u = new URL('https://e.com/'); u.searchParams.set('a','b c'); u.href"), "https://e.com/?a=b%20c");
  assert.strictEqual(run(c, "new URLSearchParams('?a=1&a=2&b=%20').getAll('a').join(',')"), "1,2");
  assert.throws(() => run(c, "new URL('not a url')"));
});

test("parseSettings JSON-parses string values like the host", () => {
  const c = makeContext();
  assert.strictEqual(run(c, "parseSettings({a:'true', b:'5', c:'\"x\"', d:'raw text'}).a"), true);
  assert.strictEqual(run(c, "parseSettings({b:'5'}).b"), 5);
  assert.strictEqual(run(c, "parseSettings({c:'\"x\"'}).c"), "x");
  assert.strictEqual(run(c, "parseSettings({d:'raw text'}).d"), "raw text");
});

test("base64 helpers round trip", () => {
  const c = makeContext();
  assert.strictEqual(run(c, "__b64encode([72,101,108,108,111])"), "SGVsbG8=");
  assert.strictEqual(run(c, "__b64decode('SGVsbG8=').join(',')"), "72,101,108,108,111");
  assert.strictEqual(run(c, "btoa('hi')"), "aGk=");
  assert.strictEqual(run(c, "atob('aGk=')"), "hi");
});

test("capability snapshot reflects defined methods", () => {
  const c = makeContext();
  run(c, "source.getComments = function(){}; source.searchChannels = function(){};");
  const snap = JSON.parse(run(c, "__jb.capabilitySnapshot()"));
  assert.strictEqual(snap.getComments, true);
  assert.strictEqual(snap.searchChannels, true);
  assert.strictEqual(snap.getPlaylist, false);
});

console.log(`\n${passed} test groups passed`);
