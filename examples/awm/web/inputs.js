/* AWM web inputs — add AWM-specific command-line arguments.
   Bot loading is handled by Polyworld's webinputs.js (loaded first). */
(function configureAwmWebInputs() {
  "use strict";
  if (typeof window === "undefined") return;

  var parameters = new URLSearchParams(window.location.search);
  var args = Module["arguments"] || [];

  if (parameters.get("human") === "true" || parameters.get("human") === "1") {
    args.push("--human", "true");
  }

  ["class", "opponent", "players"].forEach(
    function addValue(name) {
      parameters.getAll(name).forEach(function (value) {
        args.push("--" + name, value);
      });
    }
  );

  Module["arguments"] = args;
})();
