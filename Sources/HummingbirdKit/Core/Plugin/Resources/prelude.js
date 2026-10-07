// Hummingbird plugin prelude.
// Clean-room implementation of the plugin-facing JavaScript surface, written from the public
// plugin type definitions, example plugins, and a prose behaviour report.
// It runs inside the host's JavaScript engine (JavaScriptCore) before the plugin script.
//
// The only function the host installs is `__hostCall(name, a, b) -> string`; everything else, including the
// `__native` object below and the optional Http / DOMParser / Utilities packages, is built on it:
//   log(a) toast(a) isLoggedIn() hasPackage(a) sleep(a=ms) setTimeout(a=id, b=ms) http(a=requestsJson, b="1"|"0")
//   dom.parse(a=html) dom.get(a=handle, b=property) dom.call(a=handle, b=jsonArray) dom.release(a=handle)
//   util.<fn>(a=json or string)
// Package globals (http, domParser, utility) are installed by the host depending on config.packages.

"use strict";

(function (global) {

  // ------------------------------------------------------------------ host bridge

  var hostCall = global.__hostCall;
  var timers = {};
  var timerSeq = 0;

  global.__native = {
    log: function (s) { hostCall("log", String(s), ""); },
    toast: function (s) { hostCall("toast", String(s), ""); },
    isLoggedIn: function () { return hostCall("isLoggedIn", "", "") === "1"; },
    hasPackage: function (name) { return hostCall("hasPackage", String(name), "") === "1"; },
    sleep: function (ms) { hostCall("sleep", String(ms || 0), ""); },
    setTimeout: function (fn, ms) {
      var id = ++timerSeq;
      timers[id] = fn;
      hostCall("setTimeout", String(id), String(ms || 0));
      return id;
    },
    clearTimeout: function (id) { delete timers[id]; },
    http: function (requestsJson, parallel) { return hostCall("http", requestsJson, parallel ? "1" : "0"); },
    fireTimer: function (id) {
      var fn = timers[id];
      if (!fn) return;
      delete timers[id];
      try { fn(); } catch (e) { }
    }
  };

  // ------------------------------------------------------------------ DOMParser and Utilities packages

  function wrapNode(v) {
    if (v === null || v === undefined) return null;
    if (Array.isArray(v)) return v.map(wrapNode);
    return new DOMNode(v.__node);
  }
  function domGet(h, prop) { return JSON.parse(hostCall("dom.get", String(h), prop)); }
  function domCall(h, method, args) { return JSON.parse(hostCall("dom.call", String(h), JSON.stringify([method].concat(args)))); }

  function DOMNode(h) { Object.defineProperty(this, "__h", { value: h, enumerable: false }); }
  ["nodeType", "tagName", "attributes", "innerHTML", "outerHTML", "textContent", "text", "data", "classList", "className"].forEach(function (p) {
    Object.defineProperty(DOMNode.prototype, p, { get: function () { return domGet(this.__h, p); }, enumerable: true });
  });
  ["childNodes", "firstChild", "lastChild", "parentNode", "parentElement"].forEach(function (p) {
    Object.defineProperty(DOMNode.prototype, p, { get: function () { return wrapNode(domGet(this.__h, p)); }, enumerable: true });
  });
  ["getElementById", "getElementsByClassName", "getElementsByTagName", "getElementsByName", "querySelector", "querySelectorAll"].forEach(function (m) {
    DOMNode.prototype[m] = function (arg) { return wrapNode(domCall(this.__h, m, [String(arg)])); };
  });
  DOMNode.prototype.getAttribute = function (k) { return domCall(this.__h, "getAttribute", [String(k)]); };
  DOMNode.prototype.dispose = function () { hostCall("dom.release", String(this.__h), ""); };

  global.__makeDomParser = function () {
    return {
      parseFromString: function (html, contentType) {
        var h = hostCall("dom.parse", String(html), String(contentType || "text/html"));
        return h === "" ? null : new DOMNode(Number(h));
      }
    };
  };

  function byteArg(v) {
    if (typeof v === "string") return JSON.stringify({ s: v });
    return JSON.stringify({ b: Array.prototype.slice.call(v) });
  }
  global.__makeUtility = function () {
    return {
      toBase64: function (v) { return hostCall("util.toBase64", byteArg(v), ""); },
      fromBase64: function (s) { return JSON.parse(hostCall("util.fromBase64", String(s), "")); },
      md5: function (v) { return JSON.parse(hostCall("util.md5", byteArg(v), "")); },
      md5String: function (s) { return hostCall("util.md5String", String(s), ""); },
      sha256: function (v) { return JSON.parse(hostCall("util.sha256", byteArg(v), "")); },
      sha256String: function (s) { return hostCall("util.sha256String", String(s), ""); },
      randomUUID: function () { return hostCall("util.randomUUID", "", ""); }
    };
  };

  // ------------------------------------------------------------------ constants

  global.Type = {
    Source: { Dash: "DASH", HLS: "HLS", STATIC: "Static" },
    Feed: { Videos: "VIDEOS", Streams: "STREAMS", Mixed: "MIXED", Live: "LIVE", Subscriptions: "SUBSCRIPTIONS" },
    Order: { Chronological: "CHRONOLOGICAL" },
    Date: { LastHour: "LAST_HOUR", Today: "TODAY", LastWeek: "LAST_WEEK", LastMonth: "LAST_MONTH", LastYear: "LAST_YEAR" },
    Duration: { Short: "SHORT", Medium: "MEDIUM", Long: "LONG" },
    Text: { RAW: 0, HTML: 1, MARKUP: 2 },
    Chapter: { NORMAL: 0, SKIPPABLE: 5, SKIP: 6, SKIPONCE: 7 }
  };

  global.Language = {
    UNKNOWN: "Unknown", ARABIC: "ar", SPANISH: "es", FRENCH: "fr", HINDI: "hi", INDONESIAN: "id",
    KOREAN: "ko", PORTUGUESE: "pt", PORTBRAZIL: "pt", RUSSIAN: "ru", THAI: "th", TURKISH: "tr",
    VIETNAMESE: "vi", ENGLISH: "en"
  };

  var ContentType = { UNKNOWN: 0, MEDIA: 1, POST: 2, ARTICLE: 3, PLAYLIST: 4, WEB: 7, URL: 9, NESTED_VIDEO: 11, CHANNEL: 60, LOCKED: 70 };

  // ------------------------------------------------------------------ exceptions

  function ScriptException(type, msg) {
    var message;
    if (arguments.length === 1) {
      message = String(type);
      this.plugin_type = "ScriptException";
      this.msg = message;
    } else {
      message = String(msg === undefined ? "" : msg);
      this.plugin_type = type === undefined || type === null ? "" : String(type);
      this.msg = message;
    }
    this.message = message;
    this.name = this.plugin_type || "ScriptException";
    if (Error.captureStackTrace) Error.captureStackTrace(this, ScriptException);
    else this.stack = (new Error(message)).stack;
  }
  ScriptException.prototype = Object.create(Error.prototype);
  ScriptException.prototype.constructor = ScriptException;

  function subclass(name, pluginType) {
    var C = function (msg) {
      ScriptException.call(this, pluginType, msg);
    };
    C.prototype = Object.create(ScriptException.prototype);
    C.prototype.constructor = C;
    Object.defineProperty(C, "name", { value: name });
    return C;
  }

  global.ScriptException = ScriptException;
  global.LoginRequiredException = subclass("LoginRequiredException", "ScriptLoginRequiredException");
  global.ScriptLoginRequiredException = global.LoginRequiredException;
  global.CriticalException = subclass("CriticalException", "CriticalException");
  global.UnavailableException = subclass("UnavailableException", "UnavailableException");
  global.AgeException = subclass("AgeException", "AgeException");
  global.TimeoutException = subclass("TimeoutException", "ScriptTimeoutException");
  global.ScriptImplementationException = subclass("ScriptImplementationException", "ScriptImplementationException");

  global.ReloadRequiredException = function (msg, reloadData) {
    ScriptException.call(this, "ReloadRequiredException", msg);
    this.reloadData = reloadData;
  };
  global.ReloadRequiredException.prototype = Object.create(ScriptException.prototype);
  global.ReloadRequiredException.prototype.constructor = global.ReloadRequiredException;

  global.CaptchaRequiredException = function (url, body) {
    ScriptException.call(this, "CaptchaRequiredException", JSON.stringify({ plugin_type: "CaptchaRequiredException", url: url, body: body }));
    this.plugin_type = "CaptchaRequiredException";
    this.url = url;
    this.body = body;
  };
  global.CaptchaRequiredException.prototype = Object.create(ScriptException.prototype);
  global.CaptchaRequiredException.prototype.constructor = global.CaptchaRequiredException;

  global.throwException = function (type, message) {
    throw new Error("V8EXCEPTION:" + type + "-" + message);
  };

  // ------------------------------------------------------------------ small models

  global.Thumbnail = function (url, quality) { this.url = url || ""; this.quality = quality || 0; };
  global.Thumbnails = function (thumbnails) { this.sources = thumbnails || []; };

  global.PlatformID = function (platform, id, pluginId, claimType, claimFieldType) {
    this.platform = platform || "";
    this.pluginId = pluginId;
    this.value = id;
    this.claimType = claimType === undefined || claimType === null ? 0 : claimType;
    this.claimFieldType = claimFieldType === undefined || claimFieldType === null ? -1 : claimFieldType;
  };

  global.PlatformAuthorLink = function (id, name, url, thumbnail, subscribers, membershipUrl) {
    this.id = id || new global.PlatformID("", "", "");
    this.name = name || "";
    this.url = url || "";
    this.thumbnail = thumbnail;
    if (subscribers) this.subscribers = subscribers;
    if (membershipUrl) this.membershipUrl = membershipUrl;
  };
  global.PlatformAuthorMembershipLink = global.PlatformAuthorLink;

  global.RatingLikes = function (likes) { this.type = 1; this.likes = likes; };
  global.RatingLikesDislikes = function (likes, dislikes) { this.type = 2; this.likes = likes; this.dislikes = dislikes; };
  global.RatingScaler = function (value) { this.type = 3; this.value = value; };

  // ------------------------------------------------------------------ content

  function PlatformContent(obj, type) {
    obj = obj || {};
    this.contentType = type;
    this.id = obj.id || new global.PlatformID("", "", "");
    this.name = obj.name || "";
    this.thumbnails = obj.thumbnails;
    this.author = obj.author;
    this.datetime = obj.datetime !== undefined ? obj.datetime : (obj.uploadDate !== undefined ? obj.uploadDate : 0);
    this.url = obj.url || "";
    if (obj.shareUrl !== undefined) this.shareUrl = obj.shareUrl;
  }
  global.PlatformContent = PlatformContent;

  function extend(Base, ctor) {
    ctor.prototype = Object.create(Base.prototype);
    ctor.prototype.constructor = ctor;
    return ctor;
  }

  global.PlatformVideo = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.MEDIA);
    this.plugin_type = "PlatformVideo";
    this.duration = obj.duration !== undefined ? obj.duration : -1;
    this.viewCount = obj.viewCount !== undefined ? obj.viewCount : -1;
    this.isLive = obj.isLive || false;
    if (obj.isShort !== undefined) this.isShort = obj.isShort;
    if (obj.playbackTime !== undefined) this.playbackTime = obj.playbackTime;
    if (obj.playbackDate !== undefined) this.playbackDate = obj.playbackDate;
  });

  global.PlatformVideoDetails = extend(global.PlatformVideo, function (obj) {
    obj = obj || {};
    global.PlatformVideo.call(this, obj);
    this.plugin_type = "PlatformVideoDetails";
    this.description = obj.description || "";
    this.video = obj.video || {};
    this.dash = obj.dash || null;
    this.hls = obj.hls || null;
    this.live = obj.live || null;
    this.rating = obj.rating || null;
    this.subtitles = obj.subtitles || [];
    ["getComments", "getPlaybackTracker", "getContentRecommendations", "getVODEvents"].forEach(function (k) {
      if (typeof obj[k] === "function") this[k] = obj[k];
    }, this);
  });

  global.PlatformPost = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.POST);
    this.plugin_type = "PlatformPost";
    this.thumbnails = obj.thumbnails || [];
    this.images = obj.images || [];
    this.description = obj.description || "";
  });

  global.PlatformPostDetails = extend(global.PlatformPost, function (obj) {
    obj = obj || {};
    global.PlatformPost.call(this, obj);
    this.plugin_type = "PlatformPostDetails";
    this.rating = obj.rating || new global.RatingLikes(-1);
    this.textType = obj.textType || 0;
    this.content = obj.content || "";
  });

  global.PlatformArticle = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.ARTICLE);
    this.plugin_type = "PlatformArticle";
    this.summary = obj.summary || "";
    this.thumbnails = obj.thumbnails;
  });

  global.PlatformArticleDetails = extend(global.PlatformArticle, function (obj) {
    obj = obj || {};
    global.PlatformArticle.call(this, obj);
    this.plugin_type = "PlatformArticleDetails";
    this.rating = obj.rating || new global.RatingLikes(-1);
    this.segments = obj.segments || [];
  });

  global.PlatformPlaylist = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.PLAYLIST);
    this.plugin_type = "PlatformPlaylist";
    this.videoCount = obj.videoCount !== undefined ? obj.videoCount : -1;
    this.thumbnail = obj.thumbnail;
  });

  global.PlatformPlaylistDetails = extend(global.PlatformPlaylist, function (obj) {
    obj = obj || {};
    global.PlatformPlaylist.call(this, obj);
    this.plugin_type = "PlatformPlaylistDetails";
    this.contents = obj.contents;
  });

  global.PlatformNestedMediaContent = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.NESTED_VIDEO);
    this.plugin_type = "PlatformNestedMediaContent";
    this.contentUrl = obj.contentUrl || "";
    this.contentName = obj.contentName;
    this.contentDescription = obj.contentDescription;
    this.contentProvider = obj.contentProvider;
    this.contentThumbnails = obj.contentThumbnails || new global.Thumbnails();
  });

  global.PlatformLockedContent = extend(PlatformContent, function (obj) {
    obj = obj || {};
    PlatformContent.call(this, obj, ContentType.LOCKED);
    this.plugin_type = "PlatformLockedContent";
    this.contentName = obj.contentName;
    this.contentThumbnails = obj.contentThumbnails || new global.Thumbnails();
    this.unlockUrl = obj.unlockUrl || "";
    this.lockDescription = obj.lockDescription;
  });

  global.PlatformChannel = function (obj) {
    obj = obj || {};
    this.plugin_type = "PlatformChannel";
    this.id = obj.id !== undefined ? obj.id : "";
    this.name = obj.name || "";
    this.thumbnail = obj.thumbnail;
    this.banner = obj.banner;
    this.subscribers = obj.subscribers || 0;
    this.description = obj.description;
    this.url = obj.url || "";
    this.urlAlternatives = obj.urlAlternatives || [];
    this.links = obj.links || {};
  };

  global.PlatformComment = function (obj) {
    obj = obj || {};
    this.plugin_type = "Comment";
    this.contextUrl = obj.contextUrl || "";
    this.author = obj.author || new global.PlatformAuthorLink(null, "", "", null);
    this.message = obj.message || "";
    this.rating = obj.rating || new global.RatingLikes(0);
    this.date = obj.date || 0;
    this.replyCount = obj.replyCount || 0;
    this.context = obj.context || {};
    if (typeof obj.getReplies === "function") this.getReplies = obj.getReplies;
  };
  global.Comment = global.PlatformComment;

  // ------------------------------------------------------------------ sources

  global.VideoSourceDescriptor = function (obj) {
    obj = obj || {};
    this.plugin_type = "MuxVideoSourceDescriptor";
    this.isUnMuxed = false;
    this.videoSources = Array.isArray(obj) ? obj : (obj.videoSources || []);
  };
  global.MuxVideoSourceDescriptor = global.VideoSourceDescriptor;

  global.UnMuxVideoSourceDescriptor = function (videoSourcesOrObj, audioSources) {
    var o = videoSourcesOrObj || {};
    this.plugin_type = "UnMuxVideoSourceDescriptor";
    this.isUnMuxed = true;
    if (Array.isArray(o)) { this.videoSources = o; this.audioSources = audioSources || []; }
    else { this.videoSources = o.videoSources || []; this.audioSources = o.audioSources || []; }
  };

  function copyIf(self, obj, keys) {
    keys.forEach(function (k) { if (obj[k] !== undefined && obj[k] !== null) self[k] = obj[k]; });
  }

  global.VideoUrlSource = function (obj) {
    obj = obj || {};
    this.plugin_type = "VideoUrlSource";
    this.width = obj.width || 0; this.height = obj.height || 0;
    this.container = obj.container || ""; this.codec = obj.codec || "";
    this.name = obj.name || ""; this.bitrate = obj.bitrate || 0;
    this.duration = obj.duration || 0; this.url = obj.url;
    copyIf(this, obj, ["requestModifier", "language", "original"]);
  };
  global.VideoUrlRangeSource = extend(global.VideoUrlSource, function (obj) {
    obj = obj || {};
    global.VideoUrlSource.call(this, obj);
    this.plugin_type = "VideoUrlRangeSource";
    this.itagId = obj.itagId === undefined ? null : obj.itagId;
    this.initStart = obj.initStart === undefined ? null : obj.initStart;
    this.initEnd = obj.initEnd === undefined ? null : obj.initEnd;
    this.indexStart = obj.indexStart === undefined ? null : obj.indexStart;
    this.indexEnd = obj.indexEnd === undefined ? null : obj.indexEnd;
  });
  global.YTVideoSource = global.VideoUrlRangeSource;

  global.AudioUrlSource = function (obj) {
    obj = obj || {};
    this.plugin_type = "AudioUrlSource";
    this.name = obj.name || ""; this.bitrate = obj.bitrate || 0;
    this.container = obj.container || ""; this.codec = obj.codec || "";
    this.duration = obj.duration || 0; this.url = obj.url;
    this.language = obj.language || global.Language.UNKNOWN;
    copyIf(this, obj, ["requestModifier", "original"]);
  };
  global.AudioUrlRangeSource = extend(global.AudioUrlSource, function (obj) {
    obj = obj || {};
    global.AudioUrlSource.call(this, obj);
    this.plugin_type = "AudioUrlRangeSource";
    this.itagId = obj.itagId === undefined ? null : obj.itagId;
    this.initStart = obj.initStart === undefined ? null : obj.initStart;
    this.initEnd = obj.initEnd === undefined ? null : obj.initEnd;
    this.indexStart = obj.indexStart === undefined ? null : obj.indexStart;
    this.indexEnd = obj.indexEnd === undefined ? null : obj.indexEnd;
    this.audioChannels = obj.audioChannels || 2;
  });
  global.YTAudioSource = global.AudioUrlRangeSource;

  global.HLSSource = function (obj) {
    obj = obj || {};
    this.plugin_type = "HLSSource";
    this.name = obj.name || "HLS"; this.duration = obj.duration || 0;
    this.url = obj.url; this.priority = obj.priority || false;
    copyIf(this, obj, ["language", "requestModifier", "original"]);
  };
  global.DashSource = function (obj) {
    obj = obj || {};
    this.plugin_type = "DashSource";
    this.name = obj.name || "Dash"; this.duration = obj.duration || 0; this.url = obj.url;
    copyIf(this, obj, ["language", "requestModifier", "original"]);
  };
  global.RequestModifier = function (obj) {
    obj = obj || {};
    this.allowByteSkip = obj.allowByteSkip;
    if (typeof obj.modifyRequest === "function") this.modifyRequest = obj.modifyRequest;
  };

  // ------------------------------------------------------------------ capabilities

  global.ResultCapabilities = function (types, sorts, filters) {
    this.types = types || []; this.sorts = sorts || []; this.filters = filters || [];
  };
  global.FilterGroup = function (name, filters, isMultiSelect, id) {
    if (!name) throw new global.ScriptException("No name for filter group");
    if (!filters) throw new global.ScriptException("No filter provided");
    this.name = name; this.filters = filters; this.isMultiSelect = isMultiSelect; this.id = id;
  };
  global.FilterCapability = function (name, value, id) {
    if (!name) throw new global.ScriptException("No name for filter");
    if (!value) throw new global.ScriptException("No filter value");
    this.name = name; this.value = value; this.id = id;
  };

  // ------------------------------------------------------------------ pagers

  function makePager(pluginType) {
    var C = function (results, hasMore, context) {
      this.plugin_type = pluginType;
      this.results = results || [];
      this.hasMore = hasMore || false;
      this.context = context || {};
    };
    C.prototype.hasMorePagers = function () { return this.hasMore; };
    C.prototype.nextPage = function () { return new C([], false, this.context); };
    return C;
  }
  global.ContentPager = makePager("ContentPager");
  global.VideoPager = makePager("VideoPager");
  global.ChannelPager = makePager("ChannelPager");
  global.PlaylistPager = makePager("PlaylistPager");
  global.CommentPager = makePager("CommentPager");

  global.LiveEventPager = function (results, hasMore, context) {
    this.plugin_type = "LiveEventPager";
    this.results = results || [];
    this.hasMore = hasMore || false;
    this.context = context || {};
    this.nextRequest = 4000;
  };
  global.LiveEventPager.prototype.hasMorePagers = function () { return this.hasMore; };
  global.LiveEventPager.prototype.nextPage = function () { return new global.LiveEventPager([], false, this.context); };

  global.PlaybackTracker = function (interval) { this.nextRequest = interval || 10 * 1000; };
  global.PlaybackTracker.prototype.setProgress = function () {
    throw new global.ScriptImplementationException("Missing required setProgress(seconds) on PlaybackTracker");
  };

  // ------------------------------------------------------------------ live events

  function LiveEvent(type) { this.type = type; }
  global.LiveEvent = LiveEvent;
  global.LiveEventComment = extend(LiveEvent, function (name, message, thumbnail, colorName, badges) {
    LiveEvent.call(this, 1); this.name = name; this.message = message; this.thumbnail = thumbnail; this.colorName = colorName; this.badges = badges;
  });
  global.LiveEventEmojis = extend(LiveEvent, function (emojis) { LiveEvent.call(this, 4); this.emojis = emojis; });
  global.LiveEventDonation = extend(LiveEvent, function (amount, name, message, thumbnail, expire, colorDonation) {
    LiveEvent.call(this, 5); this.amount = amount; this.name = name; this.message = message || ""; this.thumbnail = thumbnail; this.expire = expire; this.colorDonation = colorDonation;
  });
  global.LiveEventViewCount = extend(LiveEvent, function (viewCount) { LiveEvent.call(this, 10); this.viewCount = viewCount; });
  global.LiveEventRaid = extend(LiveEvent, function (targetUrl, targetName, targetThumbnail, isOutgoing) {
    LiveEvent.call(this, 100); this.targetUrl = targetUrl; this.targetName = targetName; this.targetThumbnail = targetThumbnail; this.isOutgoing = isOutgoing;
  });

  // ------------------------------------------------------------------ plugin/source globals

  global.plugin = { config: {}, settings: {} };

  global.parseSettings = function (settings) {
    if (!settings) return {};
    var out = {};
    for (var key in settings) {
      if (typeof settings[key] === "string") {
        try { out[key] = JSON.parse(settings[key]); } catch (e) { out[key] = settings[key]; }
      } else out[key] = settings[key];
    }
    return out;
  };

  global.log = function (obj) {
    if (obj === undefined || obj === null || obj === "") return;
    __native.log(typeof obj === "string" ? obj : JSON.stringify(obj, null, 4));
  };
  global.console = {
    log: function () { global.log(Array.prototype.slice.call(arguments).map(function (a) { return typeof a === "string" ? a : JSON.stringify(a); }).join(" ")); },
    warn: function () { global.console.log.apply(null, arguments); },
    error: function () { global.console.log.apply(null, arguments); },
    info: function () { global.console.log.apply(null, arguments); },
    debug: function () { global.console.log.apply(null, arguments); }
  };

  // Defaults the plugin overrides. isChannelUrl / isContentDetailsUrl default to false.
  global.source = {
    getHome: function () { throw new global.ScriptImplementationException("Missing required getHome"); },
    enable: function () {},
    getSearchCapabilities: function () { return new global.ResultCapabilities([global.Type.Feed.Mixed], [], []); },
    isChannelUrl: function () { return false; },
    isContentDetailsUrl: function () { return false; }
  };

  global.bridge = global.bridge || {};
  Object.assign(global.bridge, {
    buildPlatform: "ios",
    buildSpecVersion: 2,
    supportedContent: [1, 2, 4, 7, 9, 11, 60, 70],
    supportedFeatures: ["ReloadRequiredException", "HttpBatchClient"],
    isLoggedIn: function () { return __native.isLoggedIn(); },
    log: function (s) { __native.log(String(s)); },
    toast: function (s) { __native.toast(String(s)); },
    devSubmit: function () {},
    throwTest: function (s) { throw new Error(String(s)); },
    hasPackage: function (name) { return __native.hasPackage(String(name)); },
    setTimeout: function (fn, ms) { return __native.setTimeout(fn, ms || 0); },
    clearTimeout: function (id) { __native.clearTimeout(id); },
    sleep: function (ms) { __native.sleep(ms || 0); },
    dispose: function () {}
  });
  global.setTimeout = function (fn, ms) { return global.bridge.setTimeout(fn, ms); };
  global.clearTimeout = function (id) { global.bridge.clearTimeout(id); };

  // ------------------------------------------------------------------ base64 helpers

  var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  global.__b64encode = function (bytes) {
    var out = "", i = 0, n = bytes.length;
    for (; i + 2 < n; i += 3) {
      var v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64[(v >> 18) & 63] + B64[(v >> 12) & 63] + B64[(v >> 6) & 63] + B64[v & 63];
    }
    if (i < n) {
      var a = bytes[i], b = i + 1 < n ? bytes[i + 1] : 0;
      var w = (a << 16) | (b << 8);
      out += B64[(w >> 18) & 63] + B64[(w >> 12) & 63] + (i + 1 < n ? B64[(w >> 6) & 63] : "=") + "=";
    }
    return out;
  };
  global.__b64decode = function (str) {
    str = String(str).replace(/[^A-Za-z0-9+\/]/g, "");
    var out = [], buffer = 0, bits = 0;
    for (var i = 0; i < str.length; i++) {
      buffer = (buffer << 6) | B64.indexOf(str[i]); bits += 6;
      if (bits >= 8) { bits -= 8; out.push((buffer >> bits) & 255); }
    }
    return out;
  };
  function utf8Bytes(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) { c = 0x10000 + ((c - 0xd800) << 10) + (s.charCodeAt(++i) - 0xdc00); }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }
  global.__utf8Bytes = utf8Bytes;
  if (!global.btoa) global.btoa = function (s) { var b = []; for (var i = 0; i < s.length; i++) b.push(s.charCodeAt(i) & 255); return global.__b64encode(b); };
  if (!global.atob) global.atob = function (s) { return global.__b64decode(s).map(function (c) { return String.fromCharCode(c); }).join(""); };

  // ------------------------------------------------------------------ URL / URLSearchParams

  function URLSearchParams(init) {
    this._entries = [];
    if (typeof init === "string") {
      init = init.replace(/^\?/, "");
      if (init !== "") init.split("&").forEach(function (pair) {
        var idx = pair.indexOf("=");
        var k = idx < 0 ? pair : pair.slice(0, idx), v = idx < 0 ? "" : pair.slice(idx + 1);
        this.append(decodeURIComponent(k.replace(/\+/g, " ")), decodeURIComponent(v.replace(/\+/g, " ")));
      }, this);
    } else if (init instanceof URLSearchParams) {
      init.forEach(function (v, k) { this.append(k, v); }, this);
    } else if (Array.isArray(init)) {
      init.forEach(function (p) { this.append(p[0], p[1]); }, this);
    } else if (init && typeof init === "object") {
      Object.keys(init).forEach(function (k) { this.append(k, init[k]); }, this);
    }
  }
  URLSearchParams.prototype.append = function (k, v) { this._entries.push([String(k), String(v)]); this._sync(); };
  URLSearchParams.prototype.delete = function (k) { this._entries = this._entries.filter(function (e) { return e[0] !== k; }); this._sync(); };
  URLSearchParams.prototype.get = function (k) { for (var i = 0; i < this._entries.length; i++) if (this._entries[i][0] === k) return this._entries[i][1]; return null; };
  URLSearchParams.prototype.getAll = function (k) { return this._entries.filter(function (e) { return e[0] === k; }).map(function (e) { return e[1]; }); };
  URLSearchParams.prototype.has = function (k) { return this.get(k) !== null; };
  URLSearchParams.prototype.set = function (k, v) {
    var found = false, out = [];
    this._entries.forEach(function (e) { if (e[0] === k) { if (!found) { out.push([k, String(v)]); found = true; } } else out.push(e); });
    if (!found) out.push([String(k), String(v)]);
    this._entries = out; this._sync();
  };
  URLSearchParams.prototype.forEach = function (cb, thisArg) { this._entries.slice().forEach(function (e) { cb.call(thisArg, e[1], e[0], this); }, this); };
  URLSearchParams.prototype.keys = function () { return this._entries.map(function (e) { return e[0]; })[Symbol.iterator](); };
  URLSearchParams.prototype.values = function () { return this._entries.map(function (e) { return e[1]; })[Symbol.iterator](); };
  URLSearchParams.prototype.entries = function () { return this._entries.map(function (e) { return [e[0], e[1]]; })[Symbol.iterator](); };
  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
  URLSearchParams.prototype.toString = function () {
    return this._entries.map(function (e) { return encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1]); }).join("&");
  };
  URLSearchParams.prototype._sync = function () { if (this._owner) this._owner._search = this._entries.length ? "?" + this.toString() : ""; };
  global.URLSearchParams = URLSearchParams;

  function URL(href, base) {
    href = String(href);
    var m = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)?(?:\/\/(?:([^\/?#@]*)@)?(\[[^\]]*\]|[^\/?#:]*)(?::(\d+))?)?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(href);
    if (!m || (!m[1] && !base)) throw new TypeError("Invalid URL: " + href);
    if (!m[1] && base) {
      var b = base instanceof URL ? base : new URL(base);
      var path = m[5];
      if (href.indexOf("//") === 0) { return new URL(b.protocol + href); }
      if (path === "" ) path = b.pathname;
      else if (path[0] !== "/") path = b.pathname.replace(/[^\/]*$/, "") + path;
      return new URL(b.protocol + "//" + b.host + path + (m[6] || (path === b.pathname && href[0] !== "?" && !m[5] ? b.search : "")) + (m[7] || ""));
    }
    this.protocol = m[1].toLowerCase();
    var userinfo = m[2] || "";
    this.username = userinfo.split(":")[0] || "";
    this.password = userinfo.indexOf(":") >= 0 ? userinfo.slice(userinfo.indexOf(":") + 1) : "";
    this.hostname = (m[3] || "").toLowerCase();
    this.port = m[4] || "";
    var segs = [];
    (m[5] || (m[3] !== undefined ? "/" : "")).split("/").forEach(function (s, i) {
      if (s === "..") { if (segs.length > 1) segs.pop(); }
      else if (s !== "." ) segs.push(s);
    });
    this.pathname = segs.join("/") || (m[3] !== undefined ? "/" : "");
    this._search = m[6] && m[6] !== "?" ? m[6] : "";
    this.hash = m[7] && m[7] !== "#" ? m[7] : "";
    this.searchParams = new URLSearchParams(this._search);
    this.searchParams._owner = this;
  }
  Object.defineProperty(URL.prototype, "search", { get: function () { return this._search; }, set: function (v) { v = String(v); this._search = v === "" || v === "?" ? "" : (v[0] === "?" ? v : "?" + v); this.searchParams = new URLSearchParams(this._search); this.searchParams._owner = this; } });
  Object.defineProperty(URL.prototype, "host", { get: function () { return this.hostname + (this.port ? ":" + this.port : ""); } });
  Object.defineProperty(URL.prototype, "origin", { get: function () { return this.protocol + "//" + this.host; } });
  Object.defineProperty(URL.prototype, "href", { get: function () {
    var auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
    return this.protocol + "//" + auth + this.host + this.pathname + this._search + this.hash;
  } });
  URL.prototype.toString = function () { return this.href; };
  URL.prototype.toJSON = function () { return this.href; };
  global.URL = URL;

  // ------------------------------------------------------------------ http package (JS over one native call)

  function toBase64Body(body) {
    if (body === undefined || body === null) return null;
    if (typeof body === "string") return { text: body };
    if (Array.isArray(body) || (typeof Uint8Array !== "undefined" && (body instanceof Uint8Array || ArrayBuffer.isView(body)))) {
      return { b64: global.__b64encode(Array.prototype.slice.call(body)) };
    }
    return { text: String(body) };
  }

  function throwHttpError(raw) {
    if (raw.errorType === "ScriptImplementationException") throw new global.ScriptImplementationException(raw.error);
    throw new Error(raw.error);
  }

  function convertResponse(raw, bytes) {
    if (raw === null) return null;
    if (raw.error) throwHttpError(raw);
    var body = raw.body;
    if (bytes && raw.bodyBase64 !== undefined && raw.bodyBase64 !== null) body = global.__b64decode(raw.bodyBase64);
    return { url: raw.url || "", code: raw.code, body: body === undefined ? null : body, headers: raw.headers || {}, isOk: raw.code >= 200 && raw.code < 300 };
  }

  function Client(clientId, withAuth) {
    this.clientId = clientId;
    this._auth = !!withAuth;
    this._headers = {};
    this._applyCookies = true;
    this._updateCookies = true;
    this._allowNewCookies = true;
    this._timeoutMs = null;
  }
  Client.prototype._req = function (method, url, body, headers, bytes) {
    var merged = {};
    var h = headers || {};
    var lower = {};
    Object.keys(h).forEach(function (k) { lower[k.toLowerCase()] = true; merged[k] = h[k]; });
    Object.keys(this._headers).forEach(function (k) { if (!lower[k.toLowerCase()]) merged[k] = this._headers[k]; }, this);
    var b = toBase64Body(body);
    return {
      method: method, url: String(url), headers: merged, body: b, bytes: !!bytes,
      clientId: this.clientId, useAuth: this._auth,
      applyCookies: this._applyCookies, updateCookies: this._updateCookies, allowNewCookies: this._allowNewCookies,
      timeoutMs: this._timeoutMs
    };
  };
  Client.prototype._run = function (reqs, parallel) {
    var raw = JSON.parse(__native.http(JSON.stringify(reqs), parallel));
    return raw;
  };
  Client.prototype.request = function (method, url, headers, bytes) {
    var r = this._req(method, url, null, headers, bytes);
    return convertResponse(this._run([r], false)[0], bytes);
  };
  Client.prototype.requestWithBody = function (method, url, body, headers, bytes) {
    var r = this._req(method, url, body, headers, bytes);
    return convertResponse(this._run([r], false)[0], bytes);
  };
  Client.prototype.GET = function (url, headers, bytes) { return this.request("GET", url, headers, bytes); };
  Client.prototype.POST = function (url, body, headers, bytes) { return this.requestWithBody("POST", url, body, headers, bytes); };
  Client.prototype.setDefaultHeaders = function (h) { this._headers = Object.assign({}, this._headers, h || {}); };
  Client.prototype.setTimeout = function (ms) { this._timeoutMs = ms; };
  Client.prototype.setDoApplyCookies = function (v) { this._applyCookies = !!v; };
  Client.prototype.setDoUpdateCookies = function (v) { this._updateCookies = !!v; };
  Client.prototype.setDoAllowNewCookies = function (v) { this._allowNewCookies = !!v; };
  Client.prototype.resetAuthCookies = function () { __native.http(JSON.stringify([{ control: "resetAuthCookies", clientId: this.clientId }]), false); };
  Client.prototype.clearOtherCookies = function () { __native.http(JSON.stringify([{ control: "clearOtherCookies", clientId: this.clientId }]), false); };

  function Batch(owner) { this._owner = owner; this._items = []; }
  Batch.prototype._push = function (client, method, url, body, headers, useAuth, bytes) {
    var c = client;
    if (useAuth !== undefined && useAuth !== null && !!useAuth !== c._auth) c = global.http._clientFor(!!useAuth);
    var tmp = c._req(method, url, body, headers, bytes);
    this._items.push(tmp);
    return this;
  };
  Batch.prototype.request = function (method, url, headers, useAuth) { return this._push(this._owner, method, url, null, headers, useAuth); };
  Batch.prototype.requestWithBody = function (method, url, body, headers, useAuth) { return this._push(this._owner, method, url, body, headers, useAuth); };
  Batch.prototype.GET = function (url, headers, useAuth) { return this._push(this._owner, "GET", url, null, headers, useAuth); };
  Batch.prototype.POST = function (url, body, headers, useAuth) { return this._push(this._owner, "POST", url, body, headers, useAuth); };
  Batch.prototype.DUMMY = function () { this._items.push(null); return this; };
  Batch.prototype.execute = function () {
    var live = [], index = [];
    this._items.forEach(function (it, i) { if (it !== null) { live.push(it); index.push(i); } });
    var raw = live.length ? JSON.parse(__native.http(JSON.stringify(live), true)) : [];
    var out = new Array(this._items.length);
    for (var i = 0; i < out.length; i++) out[i] = null;
    var firstError = null;
    raw.forEach(function (r, i) {
      if (r && r.error) { if (!firstError) firstError = r; }
      else out[index[i]] = convertResponse(r, live[i].bytes);
    });
    if (firstError) throwHttpError(firstError);
    return out;
  };

  var nextClientId = 1;
  global.__makeHttp = function () {
    var anon = new Client("default-anon", false), auth = new Client("default-auth", true);
    var http = {
      _clientFor: function (withAuth) { return withAuth ? auth : anon; },
      GET: function (url, headers, useAuth, bytes) { return http._clientFor(useAuth).GET(url, headers, bytes); },
      POST: function (url, body, headers, useAuth, bytes) { return http._clientFor(useAuth).POST(url, body, headers, bytes); },
      request: function (method, url, headers, useAuth, bytes) { return http._clientFor(useAuth).request(method, url, headers, bytes); },
      requestWithBody: function (method, url, body, headers, useAuth, bytes) { return http._clientFor(useAuth).requestWithBody(method, url, body, headers, bytes); },
      batch: function () { return new Batch(anon); },
      getDefaultClient: function (withAuth) { return http._clientFor(withAuth); },
      newClient: function (withAuth) {
        var c = new Client("client-" + (nextClientId++), withAuth);
        __native.http(JSON.stringify([{ control: "newClient", clientId: c.clientId, withAuth: !!withAuth }]), false);
        return c;
      },
      socket: function () { throw new global.ScriptImplementationException("WebSocket support is not implemented by this host"); },
      setDefaultHeaders: function (h) { anon.setDefaultHeaders(h); auth.setDefaultHeaders(h); },
      setDoAllowNewCookies: function (v) { anon.setDoAllowNewCookies(v); auth.setDoAllowNewCookies(v); }
    };
    return http;
  };

  // ------------------------------------------------------------------ handles + invoke wrapper used by the Swift host

  var handles = {};
  var nextHandle = 1;
  function putHandle(obj) { var id = nextHandle++; handles[id] = obj; return id; }

  function describeError(e) {
    if (e && typeof e === "object" && typeof e.plugin_type === "string" && e.plugin_type !== "") {
      var o = { type: e.plugin_type, msg: e.msg !== undefined ? e.msg : e.message };
      if (e.plugin_type === "CaptchaRequiredException") { o.url = e.url; o.body = e.body; }
      if (e.plugin_type === "ReloadRequiredException") o.reloadData = e.reloadData;
      return o;
    }
    var message = e && e.message !== undefined ? String(e.message) : String(e);
    var m = /^V8EXCEPTION:([^-]+)-([\s\S]*)$/.exec(message);
    if (m) return { type: m[1], msg: m[2] };
    return { type: "ScriptExecutionException", msg: message };
  }

  function prepareItem(item) {
    if (!item || typeof item !== "object") return item;
    if (item.plugin_type === "Comment") {
      var copy = Object.assign({}, item);
      delete copy.getReplies;
      copy.__handle = putHandle(item);
      return copy;
    }
    return item;
  }

  function prepareDetails(d) {
    if (!d || typeof d !== "object") return d;
    var out = Object.assign({}, d);
    ["getComments", "getPlaybackTracker", "getContentRecommendations", "getVODEvents"].forEach(function (k) {
      if (typeof d[k] === "function") { out["has_" + k] = true; delete out[k]; }
    });
    out.__handle = putHandle(d);
    function prepSource(s) {
      if (!s || typeof s !== "object") return s;
      var c = Object.assign({}, s);
      if (s.requestModifier) { c.requestModifier = { handle: putHandle(s.requestModifier), allowByteSkip: s.requestModifier.allowByteSkip !== false }; }
      return c;
    }
    if (out.video) {
      var v = Object.assign({}, out.video);
      if (v.videoSources) v.videoSources = v.videoSources.map(prepSource);
      if (v.audioSources) v.audioSources = v.audioSources.map(prepSource);
      out.video = v;
    }
    ["dash", "hls", "live"].forEach(function (k) { if (out[k]) out[k] = prepSource(out[k]); });
    if (out.subtitles) out.subtitles = out.subtitles.map(function (s) {
      var c = Object.assign({}, s);
      if (typeof s.getSubtitles === "function") { c.getSubtitlesHandle = putHandle(s); delete c.getSubtitles; }
      return c;
    });
    return out;
  }

  function isPager(v) { return v && typeof v === "object" && Array.isArray(v.results) && ("hasMore" in v || typeof v.nextPage === "function"); }

  function pagerPayload(p, id) {
    var res = (p.results || []).map(prepareItem);
    return { pager: id, results: res, hasMore: !!p.hasMore, nextRequest: p.nextRequest };
  }

  global.__jb = {
    // kind: "value" | "pager" | "details"
    invoke: function (name, argsJson, kind) {
      try {
        var fn = global.source[name];
        if (typeof fn !== "function") return JSON.stringify({ ok: false, error: { type: "ScriptImplementationException", msg: "Plugin does not implement " + name } });
        var args = argsJson ? JSON.parse(argsJson) : [];
        var v = fn.apply(global.source, args);
        if (v && typeof v === "object" && typeof v.plugin_type === "string" && /Exception$/.test(v.plugin_type)) throw v;
        if (kind === "pager") {
          if (!isPager(v)) return JSON.stringify({ ok: true, value: { pager: 0, results: [], hasMore: false } });
          var id = putHandle(v);
          return JSON.stringify({ ok: true, value: pagerPayload(v, id) });
        }
        if (kind === "details") return JSON.stringify({ ok: true, value: prepareDetails(v) });
        if (kind === "playlist") {
          var pl = Object.assign({}, v);
          if (v && v.contents && isPager(v.contents)) pl.contents = pagerPayload(v.contents, putHandle(v.contents));
          else pl.contents = { pager: 0, results: Array.isArray(v && v.contents) ? v.contents : [], hasMore: false };
          return JSON.stringify({ ok: true, value: pl });
        }
        return JSON.stringify({ ok: true, value: v === undefined ? null : v });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    nextPage: function (id) {
      try {
        var p = handles[id];
        if (!p) return JSON.stringify({ ok: true, value: { pager: id, results: [], hasMore: false } });
        var n = p.nextPage();
        if (n && typeof n === "object" && typeof n.plugin_type === "string" && /Exception$/.test(n.plugin_type)) throw n;
        handles[id] = n;
        return JSON.stringify({ ok: true, value: pagerPayload(n, id) });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    // Call a method on a retained object. Used for request modifiers, trackers, subtitle getters, comment replies.
    callHandle: function (id, method, argsJson) {
      try {
        var o = handles[id];
        if (!o) return JSON.stringify({ ok: false, error: { type: "ScriptExecutionException", msg: "Stale handle " + id } });
        var fn = o[method];
        if (typeof fn !== "function") return JSON.stringify({ ok: false, error: { type: "ScriptImplementationException", msg: "Missing " + method } });
        var v = fn.apply(o, argsJson ? JSON.parse(argsJson) : []);
        return JSON.stringify({ ok: true, value: v === undefined ? null : v });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    // Call a function that returns a retained object (e.g. details.getComments()) and expose it as pager/handle.
    callHandleForPager: function (id, method, argsJson) {
      try {
        var o = handles[id];
        if (!o || typeof o[method] !== "function") return JSON.stringify({ ok: false, error: { type: "ScriptImplementationException", msg: "Missing " + method } });
        var v = o[method].apply(o, argsJson ? JSON.parse(argsJson) : []);
        if (!isPager(v)) return JSON.stringify({ ok: true, value: { pager: 0, results: [], hasMore: false } });
        var pid = putHandle(v);
        return JSON.stringify({ ok: true, value: pagerPayload(v, pid) });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    // Retain an object returned by a source method (e.g. a playback tracker).
    invokeForHandle: function (name, argsJson) {
      try {
        var fn = global.source[name];
        if (typeof fn !== "function") return JSON.stringify({ ok: true, value: null });
        var v = fn.apply(global.source, argsJson ? JSON.parse(argsJson) : []);
        if (!v) return JSON.stringify({ ok: true, value: null });
        return JSON.stringify({ ok: true, value: { handle: putHandle(v), nextRequest: v.nextRequest } });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    // Call a method on a retained object and retain the object it returns (e.g. details.getPlaybackTracker()).
    callHandleForHandle: function (id, method, argsJson) {
      try {
        var o = handles[id];
        if (!o || typeof o[method] !== "function") return JSON.stringify({ ok: true, value: null });
        var v = o[method].apply(o, argsJson ? JSON.parse(argsJson) : []);
        if (!v) return JSON.stringify({ ok: true, value: null });
        return JSON.stringify({ ok: true, value: { handle: putHandle(v), nextRequest: v.nextRequest } });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    hasMember: function (id, name) {
      var o = handles[id];
      return !!o && typeof o[name] === "function";
    },
    getProperty: function (id, prop) {
      var o = handles[id];
      if (!o) return JSON.stringify(null);
      return JSON.stringify(o[prop] === undefined ? null : o[prop]);
    },
    // Comment replies: use the comment's own getReplies when present, else source.getSubComments.
    subComments: function (id) {
      try {
        var c = handles[id];
        if (!c) return JSON.stringify({ ok: true, value: { pager: 0, results: [], hasMore: false } });
        var v = typeof c.getReplies === "function" ? c.getReplies() : global.source.getSubComments(c);
        if (!isPager(v)) return JSON.stringify({ ok: true, value: { pager: 0, results: [], hasMore: false } });
        return JSON.stringify({ ok: true, value: pagerPayload(v, putHandle(v)) });
      } catch (e) {
        return JSON.stringify({ ok: false, error: describeError(e) });
      }
    },
    has: function (name) { return typeof global.source[name] === "function"; },
    capabilitySnapshot: function () {
      var names = ["searchChannels", "getUserSubscriptions", "getComments", "searchPlaylists", "getPlaylist", "getUserPlaylists",
        "searchChannelContents", "saveState", "getPlaybackTracker", "getSearchCapabilities", "getChannelCapabilities",
        "getSearchChannelContentsCapabilities", "getLiveEvents", "getLiveChatWindow", "getContentChapters", "peekChannelContents",
        "getChannelPlaylists", "getContentRecommendations", "getUserHistory", "getShorts", "searchSuggestions", "isPlaylistUrl",
        "getPeekChannelTypes"];
      var out = {};
      names.forEach(function (n) { out[n] = typeof global.source[n] === "function"; });
      return JSON.stringify(out);
    },
    fireTimer: function (id) { global.__native.fireTimer(id); },
    releaseHandles: function () { handles = {}; }
  };

})(typeof globalThis !== "undefined" ? globalThis : this);
