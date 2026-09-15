# TrackMyPath

A World of Warcraft **3.3.5a** (Wrath of the Lich King) addon that draws the path
you have walked onto the **world map**, fading it out over time.

Built for farming: open the map and you can see at a glance which parts of the
zone you have already swept and which way you came from. The trail dissolves
behind you, so after the fade window it is gone and you get a clean slate.

```
        ·                       ← ~10 min ago, almost gone
          · ·
             · ·
                · · ·
                     · ·
                        · · ·
                             ● ← you are here, full brightness
```

## Why this exists

Nothing on 3.3.5a does quite this. The closest options are:

| Addon | What it does | Why it is not this |
|---|---|---|
| **BreadCrumbs** | Short trail behind you | Minimap only, fixed dot count, no time-based fade |
| **Routes** | Draws a precomputed optimal farming route | A planned route, not the path you actually walked |
| **Where Do We Go Now** | Line showing where auto-run is taking you | Your future path, not your past one |
| **Cartographer / Mapster** | Map frameworks | No trail tracking at all |

## Installation

Copy the `TrackMyPath` folder into:

```
World of Warcraft/Interface/AddOns/TrackMyPath/
```

Then restart the client (or `/reload` if it was already running). The folder name
must be `TrackMyPath` so it matches the `.toc` filename.

## Usage

It records automatically once enabled. Open the world map to see the trail.

```
/tmp                 open the options panel
/tmp on | off        enable or disable tracking
/tmp fade <sec>      trail lifetime, 30-3600 seconds (default 600 = 10 min)
/tmp rate <sec>      how often a position is sampled, 0.2-5 s (default 1)
/tmp size <px>       dot size, 2-16 (default 6)
/tmp worldmap        toggle the world map trail
/tmp minimap         toggle the minimap trail (see caveat below)
/tmp clear           erase the recorded trail
/tmp calibrate       re-measure the current zone's shape (see below)
/tmp reset           restore default settings
/tmp status          show current state
```

`/trackmypath` works as the long form of every command.

## Behaviour

- **Trail is session-only.** Settings persist, the recorded path does not. After
  a `/reload` or a relog you start fresh. With a 10 minute fade this is barely
  noticeable, and it keeps SavedVariables tiny.
- **Per-zone.** Samples are stored per map area, so walking from Icecrown into
  Storm Peaks does not connect unrelated dots, and browsing to another zone on
  the map does not paint this zone's trail onto it.
- **Standing still adds nothing.** Samples closer together than `minDistance`
  are skipped, so fighting or AFK-ing in one spot does not build a blob.
- **Nothing is recorded** in instances, battlegrounds, on continent or cosmic
  map views, or whenever the client reports position `0,0`. Coordinates are
  meaningless in all of those cases.
- **Recording pauses while you browse.** `GetPlayerMapPosition` on 3.3.5a reports
  your position projected onto *whatever zone the map is currently showing*. If
  you open the map and look at another zone, recording pauses rather than writing
  bogus coordinates, and resumes when the map returns to your own zone. The addon
  deliberately never calls `SetMapToCurrentZone()` while the map is open, because
  that would yank the view away from you mid-browse.

## The minimap layer

The minimap trail is **off by default and is an approximation.** Positioning
something on the 3.3.5a minimap requires knowing the current zone's size in
yards, because minimap distances are in yards while `GetPlayerMapPosition`
returns 0-1 fractions of the zone.

That is really two problems, and they have different answers.

**Distance — still approximate.** How many yards one map unit spans cannot be
derived without either a zone dimension database or a known run speed. Astrolabe,
LibMapData and HereBeDragons each ship such a database, but their data is not
under a licence compatible with this addon's MIT, and those tables *are* the
substance of those libraries rather than an incidental detail — so they are not
copied here. A mid-range zone size is assumed instead, leaving distance off by
roughly ±30% in unusually large or small zones.

**Zone shape — fixed.** WotLK zones are not square (Icecrown is about 3:2), and
because x and y are each fractions of *their own* axis, drawing both at one scale
squashed the trail along one axis and skewed every direction that was not exactly
N/S/E/W. The addon now measures each zone's height/width ratio from your own
movement. This needs no external data at all: run speed scales both axes equally,
so it cancels out of the ratio entirely — mounts, buffs and swimming make no
difference.

Consequence: direction is now correct, distance is still approximate. Good enough
for "which way did I come from", not good enough to navigate by.

The world map layer has no such problem — it is exact, because it works in the
same coordinate space the API reports.

### Zone shape calibration

A new zone needs a few seconds of ordinary movement before its shape is known,
and that movement has to bend — running in a dead straight line tells the addon
nothing about the other axis, so it deliberately waits rather than guessing.

**The measurement is taken once and then locked permanently.** It is never
refined afterwards. This is deliberate: an estimate that kept adjusting itself
would shift the whole trail underfoot every time it changed, which is exactly the
kind of drift the live anchoring and rotation easing above exist to eliminate.
The trade is one small correction at the moment a zone locks, in exchange for a
trail that is perfectly stable from then on.

Locked ratios are saved, so a relog does not start the measurement over.

```
/tmp status      shows whether this zone is locked, measuring, or unmeasured
/tmp calibrate   forget this zone's shape and measure it again
```

`/tmp reset` also clears every locked ratio along with the other settings.

### Motion

The minimap trail is anchored on the player's **live** position, so it sits still
in the world while you move through it. Three things keep it from feeling hectic:

- **Live anchoring.** An earlier version anchored on the newest recorded *sample*
  instead. Between samples the player moved but the anchor did not, so the whole
  trail slid relative to the player and then snapped back when the next sample
  landed — once per `sampleInterval`. The trail now moves rigidly with the world.
- **Rotation easing.** With `rotateMinimap` on, the facing angle is eased towards
  its target rather than read raw each frame, so small camera movements do not
  swing the trail around. Easing takes the shortest arc, so crossing north does
  not spin it a full turn.
- **Edge fading.** Dots dissolve across the outer 20% of the minimap radius
  instead of popping off at the boundary.

Redraws are also skipped entirely when the anchor, facing, zoom and sample count
are all unchanged — with a time bound so the fade still animates while standing
still.

## Performance

At the default 10 minute fade and 1 sample/second the steady state is ~600 dots.
Three things keep that cheap:

- **Texture pooling.** Textures are created once and reused. Nothing is
  allocated in `OnUpdate`.
- **Alpha bucketing.** Fade alpha is quantised into 24 steps and only written to
  a texture when it actually crosses a step, instead of writing a
  visually-identical value every frame.
- **The fade only animates while the map is open.** With the map closed the
  render loop is stopped entirely and only sampling runs.

The sample buffer is a FIFO with explicit head/tail indices rather than
`table.remove(t, 1)`, which would shift hundreds of entries on every expiry tick.

Measured in the stress test (30 minutes of continuous movement): buffer peaks at
602 samples, the texture pool does not grow across 200 redraws, and expired
per-zone buckets are fully reclaimed.

## Tests

The addon logic is tested outside the game against a stubbed WoW API. WoW 3.3.5a
runs Lua 5.1, so the suite runs against 5.1 — a newer interpreter would accept
syntax the game rejects.

```bash
./test/run.sh
```

The runner probes for both `lua5.1`/`luac5.1` (distro packages) and `lua`/`luac`
(what CI installs), and falls back to `loadfile` for the syntax pass if `luac` is
missing. Override with `LUA=/path/to/lua`.

Covers syntax on every file plus 116 assertions: the FIFO and ageing model,
instance/cosmic/foreign-zone rejection, the stationary-player case, render-layer
pooling and the alpha gradient, all slash commands, and a 30-minute stress run.

`test_minimap.lua` pins the motion behaviour specifically: that the trail shifts
rigidly with the player rather than drifting and snapping, that rotation easing
takes the short way round a wrap, that dots fade towards the rim, and that
standing still skips redraws without freezing the fade.

`test_calibration.lua` pins the zone-shape measurement: that a known 3:2 zone is
recovered from simulated movement, that a straight-line run refuses to lock, that
a locked ratio never changes no matter how much contradictory movement follows,
that a locked zone renders bit-identical frames, and that absurd measurements are
rejected rather than baked in.

## Building

```bash
./build.sh
```

Writes `dist/TrackMyPath-<version>.zip`, packaged so that unzipping it into
`Interface/AddOns/` produces the correctly named folder. Tests and CI config are
not shipped. The script fails if the `.toc` lists a file that does not exist, and
warns about Lua files that exist but are not listed — those load silently as
nothing in-game.

## CI

`.github/workflows/ci.yml` calls the reusable workflow from
[`tehw0lf/workflows`](https://github.com/tehw0lf/workflows):

- **Pull requests** run the test suite and stop.
- **Push to main** additionally packages the addon and publishes a GitHub release
  tagged from the `## Version:` field of the `.toc`.

The version lives in two places — `TrackMyPath.toc`, which drives the release
tag, and `TMP.VERSION` in `Config.lua`, which the options panel displays. They
must be bumped together, and the test suite fails if they disagree, so the drift
cannot reach a release unnoticed.

## Layout

```
TrackMyPath.toc     Addon manifest (Interface: 30300)
Config.lua          Defaults and SavedVariables
Core.lua            Event wiring, sampling loop, zone/instance gating
Trail.lua           The data model: per-zone FIFO, ageing, pruning
WorldMap.lua        World map render layer (exact)
Minimap.lua         Minimap render layer (approximate, off by default)
Options.lua         Slash commands and options panel
test/               Lua 5.1 test suite with a stubbed WoW API
build.sh            Packages dist/TrackMyPath-<version>.zip
.github/workflows/  CI via tehw0lf/workflows
```

## Licence

MIT
