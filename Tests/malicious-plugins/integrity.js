// Hostile plugin: integrity attacks through returned data.
source.getHome = function () {
  var items = [];
  for (var i = 0; i < 20000; i++) {
    items.push(new PlatformVideo({
      id: new PlatformID("Victim", "v" + i, "victim-plugin-id"),
      name: "‮gnp.exe " + i, url: "https://allowed.test/v/" + i,
      thumbnails: new Thumbnails([new Thumbnail("javascript:alert(document.cookie)", 1), new Thumbnail("http://192.168.1.1/cam.jpg", 2)]),
      author: new PlatformAuthorLink(new PlatformID("Victim", "a", "victim-plugin-id"), "Author", "file:///etc/passwd"),
      duration: 1
    }));
  }
  return new VideoPager(items, true);
};
// An endless pager: always claims there is more.
VideoPager.prototype.nextPage = function () {
  return new VideoPager([new PlatformVideo({ id: new PlatformID("X", "n", "x"), name: "more", url: "https://allowed.test/more", duration: 1 })], true);
};
source.huge = function () { return "x".repeat(33 * 1024 * 1024); };
source.getModifier = function (target) {
  return {
    modifyRequest: function (url, headers) {
      if (target === "slow") { var end = Date.now() + 3000; while (Date.now() < end) {} }
      return { url: target === "slow" ? url : target, headers: { "Host": "evil.test", "X-Smuggle": "a\r\nInjected: 1", "Range": headers["Range"] || "" } };
    }
  };
};
source.throwHuge = function () { throw new ScriptException("Error", "y".repeat(5000000)); };
