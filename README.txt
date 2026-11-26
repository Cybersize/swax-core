SWAX CORE — ORIGINAL CRISPYLIB UI
================================

Two entry-point options. Sixteen real modules. No generated single-file bundle.
Choose an entry point:
- github-loader.luau downloads the modules from public GitHub URLs.
- loader.luau reads locally installed modules. Its UI dependency still downloads
  by default unless you provide a compatible CrispyLib instance or local file.

RUN FROM GITHUB
    loadstring(game:HttpGet("https://raw.githubusercontent.com/Cybersize/swax-core/main/github-loader.luau"))()

No local module installation or key is required for the GitHub entry point.
Module URLs are pinned to the payloadRevision recorded in manifest.json
so one launch cannot mix different module versions. To release changed modules,
update REVISION in github-loader.luau after committing those module changes.
This is a public-source distribution, not a private/key-protected deployment.

RUN LOCALLY
1. Copy this complete swax-core folder into your executor's workspace.
   Keep the folder name swax-core and preserve its modules/ subfolders.
2. Unload the previous SwaX version using End or Destroy Script.
3. Run loader.luau. It reads and caches the local modules once per launch.
   The loader's ROOT setting defaults to swax-core relative to the executor
   workspace. Change ROOT only if you deliberately use a different location.
4. Right-click holds lock. Right Shift shows/hides controls. End unloads.

ORIGINAL UI
The original SwaX CrispyLib window, sidebar, loading screen and 820x545 layout
are restored, with Aimbot, FOV, ESP and Config tabs only. Color pickers, sliders,
dropdowns, profile UI and two-way setting synchronization are retained.
Core profiles use ConfigName SwaXCore, separate from old all-features profiles.
Save/load and 30-second autosave need supported executor filesystem APIs.

The UI uses CrispyLib v3.3.0 from this version-specific release URL:
https://github.com/Cybersize/Crispylib/releases/download/v3.3.0/CrispyLib.lua
Resolution: compatible getgenv().CrispyLib or _G.CrispyLib, pinned release, then
CRISPYLIB_PATH / CrispyLib.lua / CrispyLib.refactored.lua local fallbacks.
A compatible instance needs the Config.OnApplied API. A dependency failure
produces a startup error and cleanup; it does not silently start headless.
The library is external, not included in the sixteen core modules.

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
github-loader.luau            GitHub entry point (HTTP module downloads)
loader.luau                   Alternative local-files entry point
modules/App.luau              Creates and connects all components
modules/Runtime.luau          Input, frame scheduling, camera replacement, unload

modules/core/Maid.luau        Cleanup utility
modules/core/Config.luau      Validated settings and subscriptions
modules/core/Math.luau        FOV, smoothing, rotation bounds, interception
modules/core/Scheduler.luau   Named, non-overlapping scheduled jobs

modules/rig/Cache.luau        Per-character instance/geometry cache
modules/rig/Registry.luau     Player/NPC discovery and lifetime tracking
modules/rig/Teams.luau        Strict live relationship resolution and adapter API
modules/rig/Geometry.luau     Aim points, animated bones, bounds and skeletons

modules/targeting/Visibility.luau   Cached line-of-sight checks
modules/targeting/Selector.luau     Candidate scoring and projectile prediction
modules/targeting/Lock.luau         Sticky-lock state machine
modules/targeting/Aim.luau          Camera/mouse output only

modules/visuals/ESP.luau      Private visual caches and rendering
modules/ui/Panel.luau         Original CrispyLib interface and config bridge

KEEP / REMOVE
Kept: aim/lock-on, player/NPC support, custom head/bone targeting, team/wall
checks, smoothing, prediction, projectile/drop correction, FOV/crosshair,
boxes, names, health, distance, tracers, skeleton, chams and profile UI.
Removed: healing, medicine changes, movement modifications, silent aim,
triggerbot, night vision, loadout inspection and teleport/rejoin.

UPGRADED TEAM CHECK
Enable Team Check in Aimbot to target confirmed enemies only. The preference
still defaults to off; this update does not silently change your saved toggle.
When on, Ally, Self and Unknown targets are excluded, including NPCs with no
team information. Unknown targets are displayed in neutral grey by ESP/chams.

The resolver reads live Roblox Team object identity only for verified character
owners with both Neutral flags false. It also checks exact replicated fields:
TeamId, TeamID, FactionId, FactionID, Team and Faction. Supported sources are
player/character attributes and direct StringValue, IntValue, NumberValue or
ObjectValue children. Field names/types must match. Empty/malformed values,
missing counterparts, conflicting sources or stale owner mappings are Unknown.
It does not infer teams from name-tag colours, clothing, names or parent folders.

No relationship cache is used. Changes are re-read during selection, aim update
and immediately before camera/mouse output, so an old lock cannot bypass the
check until the next selection tick. Unknown drop reasons are included in the
lock log. The original CrispyLib interface is preserved.

Custom team IDs are conventions, not proof of a game's combat/alliance rules.
For games with alliances, special NPC hostility, FFA, spectator rules or another
schema, supply an explicit non-yielding adapter after running either loader:
    local runtime = <run either loader and keep its returned value>
    runtime.Components.teams.SetAdapter(function(localPlayer, targetPlayer,
                                                 localCharacter, targetCharacter)
        -- Read THIS GAME's verified relationship data here.
        -- targetPlayer may be nil for custom rigs/NPCs.
        return "Unknown", "game_rules_not_integrated"
    end)
Return exactly Ally, Enemy or Unknown, optionally followed by a diagnostic
reason. Errors/invalid results fail closed to Unknown. SetAdapter(nil) restores
the built-in resolver. This is deliberately not a universal 100% guarantee:
custom game semantics and client replication delays still need validation.

API references:
https://create.roblox.com/docs/reference/engine/classes/Player
https://create.roblox.com/docs/reference/engine/classes/Team
https://create.roblox.com/docs/reference/engine/classes/Instance

PROJECTILE SETTINGS / MATH
Projectile Mode starts OFF. Turn it ON and enter the weapon's actual projectile
speed in studs per second. Speed is not automatically discovered from the game.
Extra Lead Time (s) is a separate optional target-motion time offset, not speed.
Set it to zero when checking projectile travel-time prediction by itself.

For a stationary target with no gravity, time = distance / projectile speed.
For a moving target the solver finds the earliest supported nonnegative t:
    |r + v*t - 0.5*a*t*t| = speed*t
r is target displacement from the camera after Extra Lead Time, v is target
velocity, and a is projectile acceleration. The requested aim point is:
    target + v*(extraLead + t) - 0.5*a*t*t
Without drop, the equation is quadratic; with drop it becomes quartic.
Drop Compensation uses a=(0,-Workspace.Gravity,0). Faster shots need less lead;
farther shots generally need more. A stationary target without drop produces no
visible offset, which is expected. No reachable solution means no aim output.

This is a mathematical model, not a game-specific weapon integration. Custom
weapon gravity, different muzzle origin, inherited shooter velocity, drag,
acceleration, server latency and hitscan weapons are not automatically handled.

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
is not a per-vertex bounding-box calculation.

TEST
    python test.py --luau PATH_TO_LUAU_EXE
    python test.py --luau PATH_TO_LUAU_EXE --github

The tests execute the actual loader against an in-memory filesystem and load
every actual module in its own environment. Unexpected global reads/writes
are rejected. 111 tests pass for each entry point, including 120 constructed
projectile trajectories, UI-to-projectile speed/distance/drop checks, profile
sync, dependency failure cleanup, math regressions and resource release.
Thirty-one of these tests cover relationship evidence, conflicts, neutrality,
owner/respawn changes, adapters, filtering and final camera/mouse output gates.
The Luau files compile with the official Luau 0.748 CLI.
The external CrispyLib release also compiles. UI tests use an interface double;
these are not live Roblox/executor, weapon-accuracy or visual rendering tests.

manifest.json is an inventory/hash snapshot of the supplied local files.
It is informational and is not used to prevent you from editing modules.
