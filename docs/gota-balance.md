# GotA role balance

Open queue permits any hero and repeated heroes. A composition should have
strengths that another composition can exploit. Drafting a role does not
apply a hidden damage modifier or decide the result.

| Role | Strength | Opponent's response |
| --- | --- | --- |
| Fighter | Early damage, pursuit, and short roots against fragile carries. | Frontline control and supported allies withstand the approach. |
| Frontline | High health and short control effects create openings. | Late carries deal sustained damage while keeping their distance. |
| Support | Healing restores teammates between bursts and during extended fights. | Focus the healer, separate allies, or interrupt it with control. |
| Mage | Area damage punishes clustered teams and overwhelms healing in bursts. | Spread out, dodge warnings, or reach the mage with a fighter. |
| Carry | Range and late scaling reward surviving and farming. | Apply early pressure and hold the carry in reach. |

These are intended advantages to test, not measured matchup guarantees.
Fighters should pressure a carry stack early, while frontliners with a
protected healer should resist a fighter rush. A support-free team should
have a substantial disadvantage in prolonged fights. Early aggression,
focused burst, and attacking the support remain ways to win.

## Gameplay version 69

The first patch changes existing tuning and effects. It adds no new combat
state or role-dependent multipliers.

| Hero | Changes |
| --- | --- |
| Crossbowman | Basic range 6.5 to 6 tiles, starting HP 232 to 225, and roughly 10% less damage in the first two spell ranks. Final spell damage stays unchanged. |
| Ranger | Basic range 5.5 to 6 tiles. Its greater speed, cheaper regular spells, and late scaling remain. |
| Vanguard Knight | Firebrand Sword reaches 2 tiles and stuns for 0.5 seconds. Rank-1 damage falls from 41 to 37. Blazing Blade reaches 3 tiles. |
| Death Knight | Afterlight Sickle reaches 2 tiles and roots for 0.5 seconds. Rank-1 damage falls from 41 to 37. |
| Demon Hunter | Gale Slash reaches 3 tiles and roots for 0.5 seconds. Rank-1 damage falls from 67 to 60. |
| Berserker | Winged Boot reaches 3.5 tiles and roots for 0.75 seconds. Rank-1 damage falls from 39 to 35. Volcanic Eruption resolves after 1 second instead of 2. |
| Arcanist | Meteor Strike delay falls from 1.5 to 1 second. Arcane Meteor delay falls from 2.25 to 1.5 seconds. |
| Lich | Bone Marionette roots for 1.5 seconds instead of 25 ticks. Rank-1 damage falls from 54 to 49. |
| Druid Warden | Starts with 350 HP. Thorn Bloom and Kindred Renewal heal every allied hero in their area and damage enemies. Healing is approximately doubled, and both spells reach 6 tiles. |
| Warlock | Starts with 338 HP. Mending Hex and Dread Pact heal one selected allied hero or damage one selected enemy from up to 6 tiles away. Dread Pact silences the enemy for 2 seconds. |

Support health still grows by 20 HP per level. Their basic damage, mana
curves, and movement speeds stay unchanged. Other roles retain their health
and basic DPS curves, apart from Crossbowman's 7-HP starting adjustment.

| Support spell | Healing at ranks 1 / 2 / 3 / 4 | Target |
| --- | --- | --- |
| Thorn Bloom | 150 / 225 / 300 / 375 | Every allied hero in a 2-tile circle. |
| Kindred Renewal | 160 / 240 / 320 / 400 | Every allied hero in a 2.5-tile circle. |
| Mending Hex | 220 / 330 / 440 / 550 | One allied hero. |
| Dread Pact | 240 / 360 / 480 / 600 | One allied hero. |

Warlock provides stronger healing to one hero. Druid provides weaker
healing per hero but more total healing when several teammates are nearby.
Healing is capped at maximum HP. An allied cast never applies the hostile
control effect. Warlock's ground projectiles remain offensive: healing
requires selecting an allied hero or self.

Ability IDs and icon keys stay stable. The renamed spells keep their
existing enum names. Reference policies read healing range from the host
and target injured allies with either support's healing spells.

## Validation

Check both teams, spell ranks, targeting allies and enemies, range limits,
and control effects. Confirm Warlock heals only its selected hero, while
Druid heals nearby allies and damages nearby enemies in the same cast.

Use one frozen policy, mirrored sides, and shared seeds to compare carry
stacks, fighter stacks, frontline/support teams, and mixed teams. Include
support-free versions and multiple supports. Report draws and game length
alongside wins, damage, healing, deaths, and objectives.

Policy-controlled smoke matches check integration. Establishing counter
strength requires more samples and policies that can use the new kits.
Pick-rate changes require observing updated policies on the hosted ladder.

The first local validation passed all 41 GotA regression modules and the
balance-tool tests. Sixteen 20-minute smoke matches exercised carry stacks,
fighter stacks, frontline/support combinations, and mixed teams. Both support
policies healed teammates. All matches timed out, so this batch establishes
working integration rather than the strength of the intended counters.
Every recorded tick of all sixteen native replays matched during playback.
The web build compiled, and the mixed-team replay reached its final results
in the browser without a replay divergence warning.

The full repository suite is currently blocked by an unrelated compile error
in the Crewrift tests. That work was left unchanged.
