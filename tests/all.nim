## Builds the focused CI checks once per operating system.

when not defined(replayEvents):
  {.error: "CI checks require replay events.".}

{.warning[UnusedImport]: off.}

# These fixtures expect the initial terrain dimensions.
import test_gota_abilities
# Recording subprocesses exit here before running the remaining unit tests.
import determinism
import
  test_cli,
  test_tapes,
  test_policy_packages,
  test_gota_neural,
  test_gota_andre,
  test_gota_fly,
  test_gota_host,
  test_gota_structures,
  test_gota_observations,
  test_gota_replays,
  test_gota_attacks,
  test_gota_decisions,
  test_gota_events,
  test_gota_phases,
  test_gota_controls,
  test_gota_camps,
  test_gota_portals,
  test_gota_potions,
  test_gota_progression,
  test_gota_scores,
  test_gota_gods,
  test_gota_drafts,
  test_gota_training,
  test_llms,
  test_llm_hosts

echo "CI tests passed"
