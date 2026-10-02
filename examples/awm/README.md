# AWM — Archers Warriors Mages

Card-game prototype in Nim + Polyworld. Native and browser.

## Layout

```
src/awm.nim          reads the command line and starts a game mode
src/app.nim          what every mode shares: window, renderers, heroes
src/play.nim         playing on a table: targeting, attacks, bots, beats
src/core/            the game itself: no window, no graphics
  core.nim           cards, rules and the rules DSL
  sim.nim            the match: players, turns, effects, deaths
  baseset.nim        the cards and decks
  sessions.nim       saved games and the built-in bot
  bots.nim           BASIC bot scripts
src/modes/           game modes, clients of the core
  duel.nim           two players
  multiplayer.nim    three to seven players around the ring
src/scene/           the 3D world: cards and piles, the courtyard and the
                     ring, heroes, camera placements, post-processing
src/vfx/             card and combat effects
src/ui/              the HUD, card faces, and developer panels
src/net/             the browser server and its client side
```

`nim c src/awm.nim` writes `./awm` (see `config.nims`), next to `players/`
and `web/`.

## Native

```sh
nim c src/awm.nim                            # builds ./awm
./awm                                        # bot vs bot, random classes
./awm --human --class warrior --opponent mage # play against a bot
./awm --seed 42                              # fixed deal
./awm --players=4 --human                    # multiplayer: you and 3 bots
```

| Flag | Default |
|---|---|
| `--human` | off (bot vs bot) |
| `--class CLASS` | `archer` |
| `--opponent CLASS` | `mage` |
| `--seed INTEGER` | `20260910` |
| `--players INTEGER` | `2` |
| `--bot PATH` | `players/base.bas` |

Bot vs bot ignores `--class`/`--opponent` and picks randomly.

Hero Select presents the animated Polyworld characters on stone podiums,
with class banners, lanterns and the battlefield's starry sky and materials.
In human mode, click a character or its button, or press 1, 2 or 3 for Archer,
Warrior or Mage. The camera and hit areas adapt to the viewport. The same
selection screen is used for duels and multiplayer; bot selection stays automatic.

`--players=3` (or `--players 3`) and larger counts play a multiplayer match:
a small circular center surrounded by one modular balcony per player. Each
balcony has its own hero, deck, cards in play, discard pile and hand. The
camera fits all balconies in the view. With `--human` you pick your class on
screen and play seat 1; bots with random classes play the others, and the last
player alive wins. Without it, bots play every seat. Omitting `--players`, or
using `--players=2`, keeps the existing two-player game. Counts below two and
invalid counts are rejected. F8 toggles the same screen effects as the game.

Balcony zones and the camera fit live in `src/scene/ring.nim`. The stone floor,
fascia, parapet and end pieces are built in separate curved courses; the ring
expands with player count while preserving card sizes and usable balcony depth.
Lanterns, ivy and hanging banners use the original courtyard materials and props.

Build with `-d:awmLayoutTuning` to tune the camera and the hands live, in the
duel and in the multiplayer preview. Z/X pick what moves — your hand, the
opponent's hand, the camera, or (in the duel) the spot a played spell floats
in, printed to the console — WASD move it forward,
left, back and right, Q/E raise and lower it, T/G pitch it down and up, F/H yaw
it left and right, and Enter prints the values to paste back as defaults.

### Screen effects

`src/scene/post.nim` renders the 3D scene offscreen and adds screen-space ambient
occlusion (before the VFX), bloom from the light the VFX add, FXAA, a light
grade and a vignette. The HUD is not affected. F8 toggles all of it.

| Variable (native) | Default |
|---|---|
| `AWM_POSTFX=0` | all effects on |
| `AWM_SSAO=0` / `AWM_BLOOM=0` / `AWM_FXAA=0` | each on |
| `AWM_SSAO_RADIUS` | `1.501` world units |
| `AWM_SSAO_INTENSITY` | `3.523` |
| `AWM_SSAO_BIAS` | `0.08` |

Build with `-d:awmPostLayers` to view the intermediate layers: 1 final image,
2 scene before bloom and grading, 3 depth, 4 surface normals, 5 unblurred
occlusion, 6 occlusion, 7 scene before VFX, 8 light added by VFX, 9 bloom
source, 0 bloom. `AWM_POST_LAYER=N` starts on layer N (for screenshots).

Build with `-d:awmPostPanel` for a draggable tuning window with every setting,
grouped by layer (F9 shows or hides it; with `-d:awmPostLayers` it also picks
the layer). "Print settings" writes the values as Nim for
`defaultPostSettings` in `src/scene/post.nim`. Clicks over the window don't reach
the board.

### Night courtyard materials

The paving ends at the enclosure walls. The background is a three-layer
starfield with camera parallax, scrolling, twinkling and soft star halos.
Blue-violet nebulas drift and pulse behind it. It writes no depth, so SSAO
ignores the sky while the brightest stars can feed bloom.

Stone uses two seamless linear OpenGL (+Y) normal maps: broad fractured rock
faces and restrained fine grain. A weathering texture adds mineral variation
without baking in a light direction. Triplanar mapping keeps the
circular slabs, wall faces and bevels at the same material scale. Assets live
in `polyworld_art/awm/battlefield/textures` and are staged by the web build.
The original generated rock source and its prompt are retained in
`polyworld_art/awm/battlefield/source`; rebuilding conditions the edges and
normalizes the vectors after resizing. Rebuild them with:

```sh
nim r --out:build/render-stone-normals tools/render_stone_normals.nim
```

Lighting uses the mapped normals. A depth-tested normal replay supplies the
visible stone normals to SSAO and layer 4; cards and characters keep their
depth-derived normals. The replay shares scene depth and never writes it,
so floor detail cannot leak onto foreground cards. SSAO uses a restrained
blend of surface detail while the debug layer shows the full mapped normals.
`AWM_STONE_NORMALS=0` disables the normal perturbation for comparison. Neither
the material nor the sky changes the HUD or card artwork.

```sh
nim r -d:headless --out:build/test_courtyard tests/test_courtyard.nim
nim r --out:build/test_courtyard_render tests/test_courtyard_render.nim
```

Screenshot builds support `AWM_CAPTURE_NO_HOVER=1` and `AWM_SCENE_TIME=0` for
repeatable material comparisons without the card inspector.

## Browser

```sh
./tools/serve.sh                             # build + serve
./tools/build_web.sh                         # build only
AWM_SKIP_WEB_BUILD=1 ./tools/serve.sh       # serve existing build
```

The browser loader uses a flat Polyworld-style night courtyard and an AWM
shield logo, spelling out **Archers Warriors Mages**. Its brass progress bar reports
asset download progress, then shows preparation until the first game frame
is ready. Loading assets are staged separately from the game pack so they
can appear immediately. Source mappings are in `web/loading/README.md`.

With Playwright and Chrome available, run `node tests/test_hero_select.cjs`
against the server to check hero and button selection, keyboard shortcuts,
duel/multiplayer, portrait/Retina layouts, and loader progress/error states.

The page takes the native flags as URL parameters:

- Bots: <http://127.0.0.1:8080/awm.html>
- Duel: <http://127.0.0.1:8080/awm.html?human=1&class=warrior&opponent=mage&seed=42>
- Multiplayer, bots: <http://127.0.0.1:8080/awm.html?players=5>
- Multiplayer, you and 3 bots: <http://127.0.0.1:8080/awm.html?players=4&human=1>

| Parameter | Native flag |
|---|---|
| `human=1` | `--human` |
| `class`, `opponent` | `--class`, `--opponent` |
| `players` | `--players` |
| `seed` | `--seed` |
| `bot=URL` (repeatable) | `--bot` |

## Online: Coworld

AWM runs online on Coworld the way Polyworld's other games do: the platform
stages one BASIC player per seat, the game plays the match headless, then
publishes the results and a replay that plays in the browser. Two seats play
a duel; three to seven play the multiplayer ring. The package (manifest,
Compose file, guide, baseline player and replay viewer build hook) is in
[`coworld/awm`](../../coworld/awm); the shared runtime contract is in
[`coworld/integration.md`](../../coworld/integration.md).

```sh
export POLYWORLD_DEPS="$PWD/../../tmp/coworld/deps"   # pinned dependencies
(cd ../.. && nim r coworld/tools/sync_dependencies.nim)
nim c -d:coworld -o:../../tmp/coworld/awm src/awm.nim  # the Coworld server
(cd ../.. && nim r coworld/tools/test_runtime.nim awm)  # its contract tests
coworld build --project ../../coworld/awm --version VERSION
```

The config takes `players` and `tokens` (2 to 7 each), `seed`, `max_ticks`,
and an optional `classes` array (one of `archer`, `warrior`, `mage` per seat;
otherwise drawn from the seed). One tick is one game action. The winner
scores 1, everyone else 0; a draw or a timeout scores 0 for all.

### Headless matches and replays

```sh
nim c -d:headless -o:build/awm-headless src/awm.nim
./build/awm-headless --bot players/base.bas:5 --seed 9 --record build/m.replay
./build/awm-headless --replay build/m.replay  # checks every tick's hash
./awm --replay build/m.replay                 # watch it on the table
```

`--classes archer,mage,...` fixes the classes and `--ticks N` limits the
match. The replay viewer has the shared Polyworld transport: play/pause
(Space), step, seek, loop and 1x-16x speed. Its browser build is
`AWM_WEB_DIR=build/replay ./tools/build_web.sh -d:replayViewer`; open
`awm.html?replay=URL` from the same server.

## Tests

```sh
nim r -d:headless --out:build/test_awm tests/test_awm.nim
nim r -d:headless --out:build/test_sessions tests/test_sessions.nim
nim r -d:headless --out:build/test_multiplayer tests/test_multiplayer.nim
nim r -d:headless --out:build/test_match tests/test_match.nim
```

## Rules

- Choose Archer, Warrior, or Mage.
- 20 life, 40-card class deck, 5-card opening hand.
- Random first player; first player skips their turn draw.
- Each turn: +1 max energy, full replenish, draw one card.
- Minions attack once per turn, starting the turn after they're played:
  click one, then an enemy minion or hero (right-click cancels). Minions
  deal their power to each other; damage stays, and minions at 0
  toughness go to the discard pile.
- Ranged minions take no combat damage from non-ranged minions, whether
  attacking or defending. Spells and on-play effects still damage them.
- Power/toughness buffs are permanent while the minion stays on the board;
  a bounced minion returns to hand with its printed stats. Changed stats
  show green (raised) or red (lowered) on the card. Lost keywords are
  permanent the same way, and show on the card's type line.
- Summoned minions enter at the right of their owner's board. Like played
  minions they attack from their owner's next turn, and their own on-play
  rules don't run. A card's later rules reach them (Rally buffs its own
  Footsoldiers).
- Trinkets (Plan) stay in play on their owner's board but aren't minions:
  they can't attack or be attacked, and minion targets and "all minions"
  effects ignore them.
- `on(nextTurn(...))` rules fire once, at the start of that player's next
  turn after their draw, for the card's owner, if the card is still in
  play. Drawing from an empty deck loses the game, as on a normal turn.
- Cards with several targets (Duel) are aimed one target at a time. A
  fight is combat without an attack: both minions deal their power at
  once, Ranged applies, and it doesn't use up either minion's attack.
- No victory condition yet.

| Class | Card | Copies | Cost | Type | Stats | Effect |
|---|---|---|---|---|---|---|
| Archer | Bolt | 10 | 1 | Spell | — | 2 damage to either hero |
| Archer | Sniper | 14 | 2 | Minion | 2/1 | Ranged |
| Archer | Sharpshooter | 10 | 3 | Minion | 3/1 | Ranged; 1 damage to any target |
| Archer | Hail of Arrows | 6 | 3 | Spell | — | 1 damage to all enemy minions |
| Warrior | Bear | 8 | 2 | Minion | 3/2 | — |
| Warrior | Swords | 5 | 2 | Spell | — | Friendly minions get +1/+0 permanently |
| Warrior | Shields | 4 | 1 | Spell | — | Friendly minions get +0/+1 permanently |
| Warrior | Duel | 5 | 2 | Spell | — | A minion gets +1/+1, a minion loses Ranged, then they fight |
| Warrior | Tactician | 5 | 2 | Minion | 1/2 | A minion gets -1/-0 permanently |
| Warrior | Footsoldier | 6 | 1 | Minion | 1/2 | — |
| Warrior | Commander | 4 | 5 | Minion | 2/3 | Summons 2 Footsoldiers |
| Warrior | Rally | 3 | 5 | Spell | — | Summons 2 Footsoldiers, then friendly minions get +1/+0 |
| Mage | Bouncer | 16 | 1 | Minion | 1/1 | Return a minion to owner's hand |
| Mage | Primordial | 2 | 8 | Minion | 10/10 | Return all other cards to their owners' hands |
| Mage | Study | 7 | 2 | Spell | — | Draw 2 cards, then discard 1 card of your choice |
| Mage | Plan | 7 | 3 | Trinket | — | Draw 1 card; at the start of your next turn, draw 1 card and destroy Plan |
| Mage | Oozification | 4 | 4 | Spell | — | Destroy a minion; its owner gets Oozes equal to its current toughness |
| Mage | Ooze | — | 0 | Minion | 0/1 | — (only summoned, by Oozification) |
| Mage | Bubble Shield | 4 | 2 | Spell | — | Summon 2 Bubbles |
| Mage | Bubble | — | 0 | Trinket | — | When your hero is attacked, return the attacker to its owner's hand and destroy Bubble (only summoned, by Bubble Shield) |
