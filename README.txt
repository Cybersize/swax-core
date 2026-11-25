SWAX CORE — LOCAL MODULE EDITION
===============================

One entry point. Fifteen real modules. No generated single-file bundle.
The loader reads local files only; it does not fetch or execute HTTP downloads.
Storing this project on GitHub does not change that local-loader behavior.

RUN LOCALLY
1. Copy this complete swax-core folder into your executor's workspace.
   Keep the folder name swax-core and preserve its modules/ subfolders.
2. Unload the previous SwaX version using End or Destroy Script.
3. Run loader.luau. It reads and caches the local modules once per launch.
   The loader's ROOT setting defaults to swax-core relative to the executor
   workspace. Change ROOT only if you deliberately use a different location.
4. Right-click holds lock. Right Shift shows/hides controls. End unloads.

IMPORTANT
Opening loader.luau by itself is not enough; the module files must also be
in the executor workspace. This loader needs readfile and loadstring support.
It does not copy files into another application automatically.

EDIT
Edit the relevant module directly, unload, then run the loader again.
There is no bundling/build step. These are isolated module scopes returning
tables or factories, not ordered fragments sharing hidden local variables.
Dependencies are explicit factory parameters; App.luau does all composition.
The only shared context holds engine services, camera, lifetime and cleanup.

MODULE MAP
loader.luau                   The only file you run
modules/App.luau              Creates and connects all components
modules/Runtime.luau          Input, frame scheduling, camera replacement, unload

modules/core/Maid.luau        Cleanup utility
modules/core/Config.luau      Validated settings and subscriptions
modules/core/Math.luau        FOV, smoothing, rotation bounds, interception
modules/core/Scheduler.luau   Named, non-overlapping scheduled jobs

modules/rig/Cache.luau        Per-character instance/geometry cache
modules/rig/Registry.luau     Player/NPC discovery and lifetime tracking
modules/rig/Geometry.luau     Aim points, animated bones, bounds and skeletons

modules/targeting/Visibility.luau   Cached line-of-sight checks
modules/targeting/Selector.luau     Candidate scoring and projectile prediction
modules/targeting/Lock.luau         Sticky-lock state machine
modules/targeting/Aim.luau          Camera/mouse output only

modules/visuals/ESP.luau      Private visual caches and rendering
modules/ui/Panel.luau         Native Aim / Visuals controls

KEEP / REMOVE
Kept: aim/lock-on, player/NPC support, custom head/bone targeting, team/wall
checks, smoothing, prediction, projectile/drop correction, FOV/crosshair,
boxes, names, health, distance, tracers, skeleton and chams.
Removed: healing, medicine changes, movement modifications, silent aim,
triggerbot, night vision, loadout inspection, teleport/rejoin and profile UI.

THE FIVE MATH FIXES ARE PRESERVED
- Pixel-radius FOV selection matches the visible circle.
- Camera smoothing uses elapsed time; mouse rate limits use pixels/second.
- Oriented-part bounds use world half-extents = |R| * halfSize.
- Interception solves moving targets, including constant projectile gravity.
- Skeletons follow real animated Bone or Motor6D endpoints, not a guessed body.

LIMITS
Mouse output needs mousemoverel; Drawing-based visuals need the Drawing API.
Projectile prediction assumes constant target velocity, camera-origin firing,
constant gravity, no drag, and a maximum 30-second flight horizon. It cannot
account for unknown game/server projectile behavior. Skinned mesh deformation
is not a per-vertex bounding-box calculation. Settings are session-only.

TEST
    python test.py --luau PATH_TO_LUAU_EXE

The tests execute the actual loader against an in-memory filesystem and load
every actual module in its own environment. Unexpected global reads/writes
are rejected. Sixty-one tests pass, including 120 constructed projectile
trajectories, math regressions, startup failure cleanup and resource release.
The Luau files compile with the official Luau 0.748 CLI.
These are mock-engine tests, not a live Roblox/executor or visual test.

manifest.json is an inventory/hash snapshot of the supplied local files.
It is informational and is not used to prevent you from editing modules.
