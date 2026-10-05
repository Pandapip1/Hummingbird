// Debug source: one hardcoded video, no network beyond the local server that
// serves this file. It exists so playback can be exercised against a fixed,
// offline item instead of whatever a real source happens to return — the video
// path has bugs that are hard to compare between runs when every run plays
// different content.

var PLUGIN_ID = "hummingbird-debug";
var BASE = "http://127.0.0.1:8742";
var VIDEO_URL = BASE + "/test.mp4";
var NON_RANGE_VIDEO_URL = BASE + "/no-range.mp4";
var THUMBNAIL_URL = BASE + "/thumbnail.svg";
var VIDEO_ID = "debug-video-1";
var VIDEO_PAGE = BASE + "/watch/" + VIDEO_ID;

function platformId(value) {
    return new PlatformID("HummingbirdDebug", value, PLUGIN_ID);
}

function author() {
    return new PlatformAuthorLink(
        platformId("debug-author"),
        "Debug Source",
        BASE + "/author",
        null
    );
}

function video() {
    return new PlatformVideo({
        id: platformId(VIDEO_ID),
        name: "Debug test pattern (10s, 320x240)",
        thumbnails: new Thumbnails([{ url: THUMBNAIL_URL, quality: 100 }]),
        author: author(),
        datetime: 0,
        duration: 10,
        viewCount: 0,
        url: VIDEO_PAGE,
        isLive: false
    });
}

function nonRangeVideo() {
    var item = video();
    item.id = platformId("debug-video-no-range");
    item.name = "Debug non-range test pattern (10s, 320x240)";
    item.url = BASE + "/watch/debug-video-no-range";
    return item;
}

function headerVideo() {
    var item = video();
    item.id = platformId("debug-video-header");
    item.name = "Debug header-protected test pattern (10s, 320x240)";
    item.url = BASE + "/watch/debug-video-header";
    return item;
}

source.enable = function (conf, settings, savedState) {};

source.disable = function () {};

source.getHome = function () {
    return new VideoPager([video(), nonRangeVideo(), headerVideo()], false);
};

source.search = function (query) {
    return new VideoPager([video()], false);
};

source.searchSuggestions = function (query) {
    return [];
};

source.getSearchCapabilities = function () {
    return { types: [], sorts: [], filters: [] };
};

source.isChannelUrl = function (url) {
    return url.indexOf(BASE + "/author") === 0;
};

source.getChannel = function (url) {
    return new PlatformChannel({
        id: platformId("debug-author"),
        name: "Debug Source",
        thumbnail: "",
        banner: "",
        subscribers: 0,
        description: "Serves one hardcoded video for testing playback.",
        url: BASE + "/author"
    });
};

source.getChannelContents = function (url) {
    return new VideoPager([video()], false);
};

source.isContentDetailsUrl = function (url) {
    return url.indexOf(BASE + "/watch/") === 0;
};

source.getContentDetails = function (url) {
    var noRange = url.indexOf("debug-video-no-range") >= 0;
    var needsHeader = url.indexOf("debug-video-header") >= 0;
    var itemName = needsHeader ? "Debug header-protected test pattern (10s, 320x240)"
        : (noRange ? "Debug non-range test pattern (10s, 320x240)" : "Debug test pattern (10s, 320x240)");
    return new PlatformVideoDetails({
        id: platformId(needsHeader ? "debug-video-header" : (noRange ? "debug-video-no-range" : VIDEO_ID)),
        name: itemName,
        thumbnails: new Thumbnails([{ url: THUMBNAIL_URL, quality: 100 }]),
        author: author(),
        datetime: 0,
        duration: 10,
        viewCount: 0,
        url: VIDEO_PAGE,
        isLive: false,
        description: "A locally served 10 second test pattern. Muxed H.264 in MP4,"
            + " so it needs none of the features GtkVideo lacks.",
        video: new VideoSourceDescriptor([
            new VideoUrlSource({
                name: "320x240",
                url: needsHeader ? BASE + "/header-video.mp4" : (noRange ? NON_RANGE_VIDEO_URL : VIDEO_URL),
                width: 320,
                height: 240,
                duration: 10,
                container: "video/mp4",
                codec: "h264",
                requestModifier: needsHeader ? new RequestModifier({
                    modifyRequest: function(requestUrl, headers) {
                        headers["X-Debug-Video"] = "allowed";
                        return { url: requestUrl, headers: headers };
                    }
                }) : null
            })
        ])
    });
};
