// Check the browser input handoff without fetching or compiling a game.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
const source = fs.readFileSync("src/polyworld/webinputs.js", "utf8");

function configure(query) {
  const Module = {};
  vm.runInNewContext(source, {
    Module, URL, URLSearchParams,
    window: {location: {search: query,
      href: "https://example.com/games/game.html" + query}}
  });
  return Array.from(Module.arguments);
}

assert.deepEqual(configure("?bot=../bots/Dragon.bas:3&bot=other/Dragon.bas"), [
  "--bot", "/web/bot0/Dragon.bas:3", "--bot", "/web/bot1/Dragon.bas"
]);
assert.deepEqual(configure("?bot=my%2520bot.BAS"), [
  "--bot", "/web/bot0/my bot.BAS"
]);
assert.deepEqual(configure("?replay=query.replay"), [
  "--replay", "/web/replay.replay"
]);
assert.deepEqual(configure("?bot=base.bas:9&player=6&play=false"), [
  "--bot", "/web/bot0/base.bas:9", "--player=6", "--play", "false"
]);
assert.deepEqual(configure("?bot=https://example.com/%252Fescape.bas"), [
  "--bot", "/web/bot0/_escape.bas"
]);
assert.deepEqual(configure("?draft-mode=open&player=1"), [
  "--draft-mode", "open", "--player=1"
]);
console.log("Browser input names passed");
