## Gods of the Arena executable entry point.

when defined(headless):
  import game
  runHeadless()
  when defined(coworld):
    import polyworld/coworld
    import sim, scores
    finishCoworld(CoworldResults(
      scores: scores(
        run.world.totalXp(), int(run.world.tick), run.world.scores()
      ),
      ticks: run.world.tick,
      seed: options.seed,
      outcome: run.world.outcome()
    ), run.world.totalXp())
else:
  import graphics
  runGraphics()
