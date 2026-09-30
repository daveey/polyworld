import
  std/os,
  ../tests/neuralfixtures

const Policies = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/neural/policies"

proc main() =
  ## Generates reproducible packages containing only sparse synthetic weights.
  let directory =
    if paramCount() == 0:
      "tmp/neural-examples"
    else:
      paramStr(1)
  createDir(directory)
  for author in ["richard", "david", "andre", "fly"]:
    let
      source = readFile(Policies / (author & ".bas"))
      model =
        case author
        of "richard": richardFixture()
        of "david": davidFixture()
        of "fly": flyFixture()
        else: andreFixture()
      name =
        case author
        of "david": "model.bin"
        of "fly": "fly.bin"
        else: "weights.bin"
      path = directory / ("synthetic-" & author & ".zip")
    writeFile(path,
      zipFixture([("policy.bas", source), (name, model)], true))
    echo path

main()
