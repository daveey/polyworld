(function configurePolyworldWebInputs() {
  "use strict";

  if (typeof window === "undefined") {
    return;
  }

  var parameters = new URLSearchParams(window.location.search);
  var replayUrls = parameters.getAll("replay").filter(Boolean);
  var botSpecifications = parameters.getAll("bot").filter(Boolean);
  var commandArguments = [];
  var inputs = [];

  if (replayUrls.length > 1) {
    throw new Error("Only one replay query parameter is allowed.");
  }

  function resolveUrl(source) {
    var url = new URL(source, window.location.href);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      throw new Error("Web inputs must use an HTTP or HTTPS URL: " + source);
    }
    return url.href;
  }

  function addInput(kind, source, name, suffix) {
    var path = "/web/" + name;
    inputs.push({
      kind: kind,
      source: source,
      url: resolveUrl(source),
      directory: path.slice(0, path.lastIndexOf("/")),
      name: path.slice(path.lastIndexOf("/") + 1)
    });
    commandArguments.push("--" + kind, path + suffix);
  }

  if (replayUrls.length === 1) {
    addInput("replay", replayUrls[0], "replay.replay", "");
  }

  botSpecifications.forEach(function addBot(specification, index) {
    var match = specification.match(/^(.*):([0-9]+)$/);
    var source = match ? match[1] : specification;
    var suffix = match ? ":" + match[2] : "";
    var filename = new URL(resolveUrl(source)).pathname.split("/").pop();
    try {
      filename = decodeURIComponent(filename);
    } catch (error) {
      // Keep a literal percent sign when the URL has no encoded filename.
    }
    filename = filename.replace(/[\/\\\x00-\x1f\x7f]/g, "_");
    if (!filename || filename === "." || filename === "..") {
      filename = "bot" + index + ".bas";
    }
    addInput("bot", source, "bot" + index + "/" + filename, suffix);
  });

  [
    "seed",
    "draft-mode",
    "seconds",
    "spawn-interval",
    "view",
    "ticks",
    "speed",
    "player",
    "play"
  ].forEach(function addValueParameter(name) {
    parameters.getAll(name).forEach(function addValue(value) {
      if (name === "player") {
        commandArguments.push("--player=" + value);
      } else {
        commandArguments.push("--" + name, value);
      }
    });
  });

  if (parameters.has("verbose")) {
    commandArguments.push("--verbose");
  }

  Module["arguments"] = commandArguments;
  if (inputs.length === 0) {
    return;
  }

  function showError(message) {
    console.error(message);
    if (Module["polyworldError"]) {
      Module["polyworldError"](message);
      return;
    }
    var output = document.createElement("pre");
    output.textContent = message;
    output.style.background = "#220b0b";
    output.style.color = "#ffb4a9";
    output.style.font = "16px monospace";
    output.style.left = "24px";
    output.style.margin = "0";
    output.style.padding = "18px";
    output.style.position = "fixed";
    output.style.right = "24px";
    output.style.top = "24px";
    output.style.whiteSpace = "pre-wrap";
    output.style.zIndex = "1000";
    document.body.appendChild(output);
  }

  (Module["preRun"] || (Module["preRun"] = [])).push(
    function loadPolyworldWebInputs() {
      Module["FS_createPath"]("/", "web", true, true);
      inputs.forEach(function loadInput(input, index) {
        var dependency = "polyworld-web-input-" + index;
        Module["FS_createPath"]("/", input.directory.slice(1), true, true);
        Module["addRunDependency"](dependency);
        fetch(input.url, {credentials: "same-origin"})
          .then(function checkResponse(response) {
            if (!response.ok) {
              throw new Error(response.status + " " + response.statusText);
            }
            return response.arrayBuffer();
          })
          .then(function installInput(buffer) {
            Module["FS_createDataFile"](
              input.directory,
              input.name,
              new Uint8Array(buffer),
              true,
              false,
              true
            );
            Module["removeRunDependency"](dependency);
          })
          .catch(function reportInputError(error) {
            showError(
              "Failed to load " + input.kind + " from " + input.source +
              ".\n" + error.message
            );
          });
      });
    }
  );
})();
