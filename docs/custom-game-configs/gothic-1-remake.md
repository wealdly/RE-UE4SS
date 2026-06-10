# Gothic 1 Remake — UE4SS Compatibility Notes

**Game build:** Gothic 1 Remake (G1R) · Unreal Engine 5.4.3 · Win64 Shipping · DX12 · IoStore packaging

---

## Required settings

These settings differ from upstream defaults for G1R. All are documented in
the supplied `UE4SS-settings.ini`.

### `bUseUObjectArrayCache` — `true` with this fork, `false` with stock UE4SS

G1R's IoStore build creates objects on async loading threads during streaming
zone transitions. With stock UE4SS, this fires create/delete listener callbacks
on partially initialised items, causing an access violation at startup or on
the first zone load — so stock builds must set this to `false` (all
`FindAllOf` / `FindFirstOf` calls then scan the array directly each time;
~0.1 ms at G1R's object count).

The `g1r-compat` branch of [wealdly/UEPseudo](https://github.com/wealdly/UEPseudo)
(commit `ffe5677`+) guards the listeners, searcher-pool population, and the
`UStruct::Link` detour against partially-initialized objects (null
`ClassPrivate`/`ObjectItem`), and adds a mutex around the global object cache
(the delete listener fires on async loading threads while the game thread
reads via `FindObject`). With these guards, `bUseUObjectArrayCache = true` has
been verified stable in-game (startup, zone streaming, lockpicking, clean exit).

### `DefaultExecuteInGameThreadMethod = EngineTick`  *(already the upstream default)*

G1R's heavy AngelScript usage drives ProcessEvent at thousands of calls per
frame. Using it as the game-thread dispatch point for deferred Lua work creates
thundering-herd pressure. `EngineTick` coalesces all deferred callbacks to once
per frame.

---

## What works from Lua (verified in-game)

| API | Notes |
|---|---|
| `NotifyOnNewObject` | Works on both native `/Script/G1R.*` and AngelScript `/Script/Angelscript.*` classes |
| `FindAllOf` / `FindFirstOf` | Safe; do not cache results across ticks |
| Property reads/writes | All reflected properties (native and AS) are readable and writable |
| `RegisterHook` on **engine** natives | Reliable — e.g. `PlayerController:ClientRestart`, `AbilityTask_LockPick:UpPressed` |
| `RegisterInitGameStatePostHook` | The correct world-reset hook for G1R. Safe to call; do not touch stored object wrappers inside the callback |
| `LoopAsync`, `ExecuteWithDelay`, `ExecuteInGameThread` | Safe |
| `RegisterKeyBind` | Safe; hot-reload re-registers without removing old ones — debounce defensively |

---

## What does NOT work

### `RegisterHook` on G1R/AngelScript-bound natives

G1R's AngelScript plugin calls its own bound natives directly through the
binding table (`G1R\Script\Binds.Cache`), bypassing UFunction dispatch
entirely. `RegisterHook` on these functions registers without error and never
fires. This was verified across a full world load (416 lock instances):
`GothicLockConfig:AddPiece` and `GothicLockConfig:AddConnection` registered fine
and saw zero calls. **Hook G1R natives only where the caller is the engine
(input dispatch, ProcessEvent), never where the caller is script logic.**

Engine-dispatched hooks that *do* fire reliably: `AbilityTask_LockPick:UpPressed`,
`DownPressed`, `LeftPressed`, `RightPressed`, `TryOpenLock` — both keyboard and
controller input.

### TMap property access

UE4SS TMap access via reflection returns a **copy**. Mutations (`:Empty()`,
element writes) on that copy do not propagate back to the live object. TMap
**iteration** via reflection is also suspected of native access violations under
unclear conditions; `pcall` cannot catch native AVs. Avoid TMap iteration in
shipped mods unless unavoidable.

### Reading instance properties off AngelScript class objects

`RandomLockSubsystem.m_RegisteredChests` maps chest names to per-chest AS
classes (e.g. `IO_OC_CHEST_DIGGER502`). Reading instance properties off those
class objects returns reflection garbage and access-violates. `GetCDO()` and
`StaticFindObject` on them crash natively. `pcall` does not catch native AVs.
**Do not touch chest class objects from Lua.**

### Object lifetime

Actors go pending-kill (`IsValid()` returns false) the moment their scene ends.
Subobjects like `MaterialInstanceDynamic` merely become unreferenced and stay
apparently "valid" until the next GC. A polling session keyed on MID validity
will outlive its minigame. A save-load GC purge leaves all Lua wrappers from
the previous session dangling — the next property access is a native AV.

**Rule:** key session liveness on the owning actor, and kill every session
unconditionally inside `RegisterInitGameStatePostHook` without touching any
stored wrapper.

---

## Known-bad Engine.ini CVars when UE4SS is loaded

These settings interact with UE4SS's raw `UObject*` hooks and cause crashes.
Do not add them to `Engine.ini` when UE4SS is present.

| CVar | Why it crashes |
|---|---|
| `gc.GarbageEliminationEnabled=1` | Eliminates objects too aggressively; UE4SS holds raw pointers that become dangling |
| `gc.IncrementalBeginDestroyEnabled=1` | Begins destruction while the object is still addressable; UE4SS hooks read partially-destroyed objects |
| `tick.AllowAsyncTickDispatch=1` | Races with UE4SS non-thread-safe tick hooks |
| `tick.AllowBatchedTicks=1` | Same race class |
| `r.RHIThread.Enable` / `r.RHIThread.NumRHIThreads` | Type conflict crash in G1R's shipping ConsoleManager (ConsoleManager.cpp:2762) |

---

## Performance tuning

G1R's AngelScript layer drives engine dispatch points (especially
`ProcessEvent`) at thousands of calls per frame, so UE4SS detours that are
cheap elsewhere are disproportionately expensive here. The supplied
`UE4SS-settings.ini` disables every detour no installed mod uses:
`HookUObjectProcessEvent`, `HookAActorTick`, `HookGameViewportClientTick`,
`HookEndPlay`, `HookProcessConsoleExec`, `HookLocalPlayerExec`,
`HookCallFunctionByNameWithArguments`. If a mod needs one, UE4SS logs a
warning naming the hook — re-enable just that one.

The `g1r-compat` UEPseudo branch also replaces the searcher pools' O(n)
erase-remove with index-mapped swap-and-pop (O(1) add/remove, deduped).
Streaming zone transitions delete thousands of actors at once; the old removal
was O(deletes × pool size) inside the GC path, under a mutex.

---

## Expected scan messages (cosmetic)

`[PS] Failed to find FUObjectHashTables::Get()` appears in every G1R launch.
This scan is optional and its result is currently unused by UE4SS (WIP since
upstream PR #744). Do not supply a custom `UE4SS_Signatures/GUObjectHashTables.lua`
for it — a wrong AOB is worse than none. All required scans (GUObjectArray,
GMalloc, FName, StaticConstructObject, GameEngineTick) resolve cleanly on G1R.

---

## Exit crash (fixed by listener guards)

G1R with **stock** UE4SS installed exits with an access violation after the
game has finished saving and shutting down — UE4SS listeners firing after the
engine has torn down the object array. It was always cosmetic (no effect on
gameplay or saves).

With the `g1r-compat` UEPseudo listener guards (same fix as the
`bUseUObjectArrayCache` issue above), exits have been observed clean. If it
recurs, symbolicate the minidump in `%LOCALAPPDATA%\G1R\Saved\Crashes\`
against the build's `UE4SS.pdb`.

---

## G1R build specifics

- **Packaging:** IoStore (`G1R-Windows.ucas` ~29 GB)
- **Gameplay:** AngelScript plugin (Hazelight-style). Compiled blob at `G1R\Script\PrecompiledScript_Shipping.Cache` (122 MB); binding table at `G1R\Script\Binds.Cache`
- **Stats/skills:** GameplayAbilities (GAS) — AttributeSets + GameplayEffects
- **Scale:** ~1680 native `/Script/G1R` classes, ~34 800 AngelScript classes
- **Anti-cheat:** None. Single-player only.
- **Log locations:**
  - UE4SS log (overwritten each launch): `G1R\Binaries\Win64\ue4ss\UE4SS.log`
  - Game crash dumps: `%LOCALAPPDATA%\G1R\Saved\Crashes\`
  - Game logs: `%LOCALAPPDATA%\G1R\Saved\Logs\`
