## Shared Emscripten compile recipe for Polyworld games.

import
  std/[os, strformat, strutils]

proc setupEmscripten*(exampleDir: string, game = "") =
  ## Configures the wasm backend and writes the bundle next to the game.
  when defined(emscripten):
    let
      repoDir = exampleDir / ".." / ".."
      dataDir = getEnv("POLYWORLD_ART", repoDir / ".." / "polyworld_art")
      outputDir = exampleDir / "emscripten"
      shellTemplate = repoDir / "src" / "polyworld" /
        (if defined(replayViewer): "replay.html" else: "emscripten.html")
      shellFile = outputDir / "shell.html"
    let preJs =
      if defined(replayViewer):
        ""
      else:
        "--pre-js " & repoDir / "src" / "polyworld" / "webinputs.js"
    var preload = "--preload-file " & quoteShell(dataDir & "@/polyworld_art")
    var logo = ""
    if not dirExists(outputDir):
      mkDir(outputDir)
    if game.len > 0:
      let
        variant = if defined(webPng): "png" else: "ktx2"
        cache = repoDir / "tmp" / "webassets" / (game & "-" & variant)
        packer = cache / ("pack_assets" & ExeExt)
        options = if defined(webPng): " -d:webPng" else: ""
      if not dirExists(cache):
        mkDir(cache)
      exec quoteShell(getCurrentCompilerExe()) & " c --hints:off" & options &
        " --nimcache:" & quoteShell(cache / "nimcache") &
        " -o:" & quoteShell(packer) & " " &
        quoteShell(exampleDir / "pack_assets.nim")
      exec quoteShell(packer) & " " & quoteShell(dataDir) &
        " " & quoteShell(cache)
      let
        logoFile = outputDir / "loading-logo.png"
        logoData = readFile(cache / "loading-logo.png")
      if not fileExists(logoFile) or readFile(logoFile) != logoData:
        writeFile(logoFile, logoData)
      logo = "<img id=\"loading-logo\" alt=\"Game logo\" " &
        "width=\"320\" height=\"240\" src=\"loading-logo.png\" " &
        "fetchpriority=\"high\">"
      preload = "--preload-file " & quoteShell(cache / "stage" & "@/polyworld_art")
    let shell = readFile(shellTemplate).replace("<!-- GAME_LOGO -->", logo)
    if not fileExists(shellFile) or readFile(shellFile) != shell:
      writeFile(shellFile, shell)
    switch("nimcache", outputDir / "tmp")
    switch("threads", "off")
    --os:linux
    --cpu:wasm32
    --cc:clang
    when defined(windows):
      --clang.exe:emcc.bat
      --clang.linkerexe:emcc.bat
      --clang.cpp.exe:emcc.bat
      --clang.cpp.linkerexe:emcc.bat
    else:
      --clang.exe:emcc
      --clang.linkerexe:emcc
      --clang.cpp.exe:emcc
      --clang.cpp.linkerexe:emcc
    --gc:arc
    --exceptions:goto
    --define:noSignalHandler
    --debugger:native
    --define:noAutoGLerrorCheck
    --define:flatty64
    when not defined(debug):
      --define:release
      # Release -O3 only reaches the compile step. emcc also needs it at link
      # time, or Binaryen leaves the wasm and Asyncify unoptimized.
      switch("passL", "-O3")
    switch(
      "passL",
      (&"""
      -o {outputDir / projectName()}.html
      {preload}
      {preJs}
      --shell-file {shellFile}
      -s ASYNCIFY
      -s FETCH
      -s EXIT_RUNTIME=1
      -s USE_WEBGL2=1
      -s MAX_WEBGL_VERSION=2
      -s MIN_WEBGL_VERSION=1
      -s FULL_ES3=1
      -s GL_ENABLE_GET_PROC_ADDRESS=1
      -s ALLOW_MEMORY_GROWTH
      --profiling
      """).replace("\n", " ")
    )
    if paramStr(1) == "run" or paramStr(1) == "r":
      setCommand("c")
      echo "To run the Emscripten build, use:"
      echo "emrun " & outputDir / (projectName() & ".html")
