# Light vs Dark

BASIC overlords gather resources, build armies, and fight. The simulation winner scores one win, including its existing time-limit resolution.

Each slot commands an independent player. Even slots use Light stats and odd slots use Dark stats. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/light_vs_dark/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/light_vs_dark/bots.nim` and `content.nim`.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs six-player free-for-all matches. Each player starts neutral and can form alliances, request peace, or declare war. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.

## BASIC numbers and coordinates

BASIC uses [Bassy](https://github.com/treeform/bassy) with [Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. Globals and arrays retain fractional values across decisions. `/` performs decimal division; `\` performs integer division. Decimal operands must fit -32768 through 32767.99998. Integer-only calculations retain the full signed 32-bit range. When converting large world-unit observations, divide them as integers first, for example `(selfAttackRange \ 100) / (worldScale \ 100)` in GotA.

`and`, `or`, `xor`, and `not` are bitwise. Comparisons produce -1 for true and 0 for false; conditions accept any nonzero number. Host flags and action results remain 1 or 0, so use `flag = 0` instead of `not flag` to negate a host flag.

`moveUnit(id, x, y)` and `attackMove(id, x, y)` accept fractional tile coordinates. Integers continue to name tile centers. Building placement and rally tiles remain whole tiles. IDs, slots, indices, and terrain queries require exact integers. Passing a fractional value to an integer argument raises a BASIC error instead of truncating it. Accepted fractional destinations are preserved in action replays.

## Buildings and resources

Building footprints are rectangular. Use `buildWidth(kind)` and
`buildDepth(kind)` when planning placement. Building positions are the minimum
X/Y corner; `buildFootprint(kind)` returns the larger dimension for compatibility.
The bundled baseline leaves a walking lane around each building.

Starting gold mines contain 45,000 gold. Expansion mines contain 25,000 gold.
Units, buildings, terrain, trees, rocks, and faction symbols use the cleared
Polyworld art library. Faction colors and building trims vary between matches
and remain consistent when replaying a match.

## Rosters and maps

Every supplied bot gets a player slot. Local `--bot PATH:N` adds N copies;
repeat `--bot` to mix programs. `--player:N` inserts a human at slot N.
A solo game runs until its time limit. Multiplayer ends when one player
remains, or ranks surviving players by score at the time limit. Equal top
scores draw.

Each player starts at a spawn node with a town hall, main mine, nearby wood,
and N nearby expansion nodes. N defaults to 2. Clear paths join expansions
to their town and towns to the central clearing. Spokes vary in angle and
length, and home bases can sit near map edges. Expansions choose random nearby
positions with room for their mines and paths, avoiding edges and buildings.
Roads have gentle random bends that smooth out at each node. The same seed
and settings reproduce the same map. Use these local settings:

- `--map-layout spoke|random` selects ring spokes or seeded random starts.
- `--map-size N` sets the baseline side length for two players (default 90).
- `--expansions N` sets nearby expansion mines per player, including zero.
- `--min-distance N` sets minimum spawn separation in tiles (default 45).

Map size grows with the roster and grows further when spacing or expansion
clusters need more room. The current tile and memory limit is 4096 per side;
impossible settings fail with a descriptive error. Hosted configurations
accept `map_layout`, `map_size`, `expansions`, and `min_distance`.

BASIC exposes `playerCount`, `enemyHomeX`, and `enemyHomeY`. `enemyPlayer` is
the nearest living player at war with you, or -1 when none exists.
`nearestEnemy` also considers only players at war. Visible neutral and allied
players still appear in observations. Query `mapSize` for the actual tile stride.
Use the minimap's arrow buttons or press V to cycle through every player's
fog view and the all-map view. Tab shows the full roster. Replays store map
settings, actual size, and every player slot.
Gameplay version 23 requires its matching replay client.

## Diplomacy and the base policy

Everyone starts neutral. Only players at war can damage each other. A war
declaration starts a warning before either side can attack. Peace and alliance
offers require the other player's agreement. Peace stops combat immediately;
alliances share live vision between direct allies. Ending an alliance takes
twice the war warning, with vision shared until that deadline. A separate war
declaration must then complete its full warning. Explored terrain stays known.

`--war-grace-seconds N` controls the warning (default 10), and
`--diplomacy-offer-seconds N` controls offer expiry (default 60). Both accept
1 through 3600 seconds. Hosted configuration uses `war_grace_seconds` and
`diplomacy_offer_seconds`. Timers use simulation ticks and settings are replayed.

The base policy ranks living opponents by distance between starting bases,
breaking ties by player ID. With M opponents, it wants `min(M, floor(M / 2) + 1)`
farther opponents at war and the remaining nearer opponents allied. Eight
living players means four preferred enemies and three preferred allies each.
Actual wars can exceed this target because declarations affect both players.

The policy reconsiders once per simulated second and after eliminations. It
offers peace to new preferred allies, accepts their peace and alliance offers,
and ends alliances with new preferred enemies. With two or three players left,
every opponent becomes a war target. An allied roster does not win together;
the existing last-player and time-limit victory rules still apply.

The BASIC interface exposes these values and calls:

- `neighborCount`, `neighbor(rank)`: living opponents, closest first, from rank 0.
- `tickRate`: simulation ticks per second.
- `relation(player)`: 0 neutral, 1 war warning, 2 at war, 3 allied,
  4 alliance ending.
- `relationTicks(player)`, `relationInitiator(player)`, `sharesVision(player)`.
- `offerKind(player)`: 0 none, 1 peace, 2 alliance.
- `offerSender(player)`, `offerId(player)`, `offerTicks(player)`.
- `declareWar(player)`, `withdrawWar(player)`, `endAlliance(player)`.
- `offerPeace(player)`, `offerAlliance(player)`.
- `acceptOffer(player, id)`, `declineOffer(player, id)`,
  `withdrawOffer(player, id)`: replies require the current offer ID.

Commands return 1 when accepted and 0 when refused. Uploads must explicitly
declare war before fighting; attack orders never declare war automatically.
