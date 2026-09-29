import
  std/[os, strutils],
  jsony,
  polyworld/treegen,
  views

type
  PlantReport = object
    name: string
    preset, seed, triangles, cards, blooms: int

proc main() =
  ## Exports temporary review models and durable generator recipes.
  let
    directory = paramStr(1)
    recipes = paramStr(2)
  if directory.len == 0 or recipes.len == 0:
    raise newException(TreegenError, "Expected review and recipe directories")
  createDir(directory)
  createDir(recipes)
  var reports: seq[PlantReport]
  for index in 10 .. PresetNames.high:
    for seed in [42, 7, 91]:
      if seed != 42 and index notin 10 .. 14 and index != 21:
        continue
      let
        name = PresetNames[index].toLowerAscii.replace(" ", "-")
        settings = preset(index, seed)
        geometry = generateGeometry(settings)
        triangles = (geometry.bark.indices.len +
          geometry.foliage.indices.len + geometry.flowers.indices.len +
          geometry.stems.indices.len + geometry.crown.indices.len) div 3
      settings.exportTree(directory / (name & "-" & $seed & ".glb"))
      if seed == 42:
        settings.saveSettings(recipes / (name & ".json"))
      reports.add PlantReport(name: name, preset: index, seed: seed,
        triangles: triangles, cards: geometry.cards, blooms: geometry.blooms)
      echo name, " ", seed, ": ", triangles, " triangles"
  writeFile(directory / "counts.json", reports.toJson())

main()
