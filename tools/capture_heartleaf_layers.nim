import std/[os, osproc, streams, strtabs]

const
  Root = currentSourcePath().parentDir.parentDir
  Layers = [
    (name: "ground", file: "01-grass-and-paths", label: "Ground"),
    (name: "buildings", file: "02-buildings", label: "Buildings"),
    (name: "vegetation", file: "03-trees-and-vegetation", label: "Vegetation"),
    (name: "props", file: "04-props", label: "Props"),
    (name: "all", file: "05-assembled", label: "Assembled")
  ]

type PolyworldToolsError = object of CatchableError

proc execute(
  executable: string,
  arguments: openArray[string],
  environment: StringTableRef,
  logPath = ""
) =
  ## Runs a child directly, retaining capture output in its per-layer log.
  var log: File
  if logPath.len > 0:
    log = open(logPath, fmWrite)
  defer:
    if log != nil:
      log.close()
  let
    options =
      if logPath.len == 0:
        {poUsePath, poParentStreams}
      else:
        {poUsePath, poStdErrToStdOut}
    process = startProcess(
      executable,
      workingDir = Root,
      args = arguments,
      env = environment,
      options = options
    )
  defer:
    process.close()
  if logPath.len > 0:
    var line: string
    while process.outputStream.readLine(line):
      log.writeLine(line)
  let exitCode = process.waitForExit()
  if exitCode != 0:
    var message = executable & " failed with exit code " & $exitCode
    if logPath.len > 0:
      message.add ". See " & logPath
    raise newException(PolyworldToolsError, message)

proc panel(
  magick, source, destination, label: string,
  environment: StringTableRef
) =
  ## Adds a consistent background and heading to one comparison panel.
  execute(
    magick,
    [source, "-background", "#171d17", "-alpha", "remove", "-alpha", "off",
      "-gravity", "north", "-background", "#171d17", "-splice", "0x64",
      "-font", "Arial", "-pointsize", "30", "-fill", "#e8eadf",
      "-annotate", "+0+15", label, destination],
    environment
  )

proc compare(output: string, environment: StringTableRef) =
  ## Compares the unchanged references with captures when ImageMagick exists.
  let
    magick = findExe("magick")
    reference = Root.parentDir / "polyworld_art/terrain/heartleaf/layers"
  if magick.len == 0:
    echo "ImageMagick not found; saved the five 3D captures without comparisons."
    return
  var
    composite: seq[string]
    montage = @["montage"]
  for i in 0 ..< Layers.len - 1:
    let
      layer = Layers[i]
      target = output / layer.file
    panel(
      magick,
      reference / (layer.file & ".png"),
      target & "-2d-panel.png",
      "2D reference | " & layer.label,
      environment
    )
    panel(
      magick,
      target & "-3d.png",
      target & "-3d-panel.png",
      "3D game geometry | " & layer.label,
      environment
    )
    execute(
      magick,
      [target & "-2d-panel.png", target & "-3d-panel.png", "+append",
        target & "-comparison.png"],
      environment
    )
    composite.add reference / (layer.file & ".png")
    if i > 0:
      composite.add @["-compose", "over", "-composite"]
    montage.add target & "-comparison.png"
  composite.add output / "05-assembled-2d.png"
  execute(magick, composite, environment)
  execute(
    magick,
    [output / "05-assembled-2d.png", output / "05-assembled-3d.png",
      "+append", output / "05-assembled-comparison.png"],
    environment
  )
  montage.add @[
    "-tile", "2x2", "-geometry", "1122x733+14+14",
    "-background", "#0f140f", output / "layers-overview.png"
  ]
  execute(magick, montage, environment)

proc main() =
  ## Builds once and renders five registered layers without opening windows.
  if paramCount() > 1:
    raise newException(
      PolyworldToolsError,
      "Usage: nim r tools/capture_heartleaf_layers.nim [output-directory]"
    )
  let
    directory =
      if paramCount() == 0 or paramStr(1).len == 0:
        "tmp/heartleaf-layers"
      else:
        paramStr(1)
    output = absolutePath(directory, Root)
    binary = Root / "tmp/heartleaf-town" / ("layers" & ExeExt)
    environment = newStringTable(modeCaseSensitive)
  for name, value in envPairs():
    if name notin ["CAM_DIST", "CAM_X", "CAM_Z", "SIM_SECONDS"]:
      environment[name] = value
  createDir(output)
  createDir(binary.parentDir)
  echo "Building Heartleaf layer capture."
  execute(
    "nim",
    ["c", "--hints:off", "--nimcache:tmp/heartleaf-town/cache-layers",
      "-d:takeScreenshot", "-d:sceneCapture", "--out:" & binary,
      "examples/heartleaf/heartleaf.nim"],
    environment
  )
  for layer in Layers:
    echo "Capturing ", layer.name, "."
    environment["HEARTLEAF_LAYER"] = layer.name
    environment["SCREENSHOT_PATH"] = output / (layer.file & "-3d.png")
    execute(
      binary,
      ["--bot", "examples/heartleaf/players/base.bas:9", "--seek-tick",
        "1500", "--play=false", "--windowSize", "1122x1402"],
      environment,
      output / (layer.name & ".log")
    )
  compare(output, environment)
  echo "Saved Heartleaf layers to ", output

main()
