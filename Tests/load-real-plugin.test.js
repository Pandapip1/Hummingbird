// Loads a real, unmodified third-party plugin script (path given as argv[2]) against the prelude
// to check that top-level code runs and the expected entry points exist.
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const pluginDir = process.argv[2];
if (!pluginDir) { console.log("skip: pass a plugin directory"); process.exit(0); }
const cfgFile = fs.readdirSync(pluginDir).find(f => /Config\.json$/.test(f) && !/dev/.test(f));
const config = JSON.parse(fs.readFileSync(path.join(pluginDir, cfgFile), "utf8"));
const script = fs.readFileSync(path.join(pluginDir, config.scriptUrl), "utf8");
const prelude = fs.readFileSync(path.join(__dirname, "../Sources/JaybirdCore/Plugin/Resources/prelude.js"), "utf8");
const logs = [];
const ctx = vm.createContext({ __hostCall: (name, a) => { if (name === "log") logs.push(a); if (name === "http") return "[]"; if (name === "hasPackage") return "1"; return ""; } });
vm.runInContext(prelude, ctx);
vm.runInContext("var http = __makeHttp(); plugin.config = " + JSON.stringify(config) + "; plugin.settings = {};", ctx);
vm.runInContext(script, ctx, { filename: config.scriptUrl });
for (const fn of ["getHome","search","isChannelUrl","getChannel","getChannelContents","isContentDetailsUrl","getContentDetails"])
  assert.strictEqual(vm.runInContext(`typeof source.${fn}`, ctx), "function", fn + " missing");
const snap = JSON.parse(vm.runInContext("__jb.capabilitySnapshot()", ctx));
console.log("loaded", config.name, "v" + config.version, "capabilities:", Object.keys(snap).filter(k => snap[k]).join(", "));
const isUrl = JSON.parse(vm.runInContext(`__jb.invoke('isContentDetailsUrl', JSON.stringify(['https://odysee.com/@x:1/y:2']), 'value')`, ctx));
console.log("isContentDetailsUrl ->", JSON.stringify(isUrl));
