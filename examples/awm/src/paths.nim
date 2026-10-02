import
  std/os,
  polyworld/common

# This file is in examples/awm/src: the repository is three folders up.
const SourceRepo = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc artworkRoot*(): string =
  ## Locate AWM artwork in the shared Polyworld data folder.
  when defined(emscripten):
    DataRoot / "awm"
  else:
    let repo = absolutePath(getEnv("POLYWORLD_REPO", SourceRepo))
    absolutePath(DataRoot, repo) / "awm"
