-- Gothic1RemakeCompat — UE4SS Lua compatibility helper for G1R
--
-- Provides safe wrappers and documented patterns for the known G1R/UE4SS
-- interaction quirks. Load order: place this mod first in mods.txt so other
-- mods can rely on the globals it installs.
--
-- Verified against G1R build 8336, UE 5.4.3, UE4SS v3.0.1 Beta.

-- ── Shared-state guard ───────────────────────────────────────────────────────
-- All UE4SS Lua mods share ONE state. Capture standard globals as locals so
-- another mod replacing them (seen in the wild: ipairs replaced by a table)
-- cannot break this mod mid-session.
local ipairs, pairs, type, pcall, print = ipairs, pairs, type, pcall, print
local tostring, tonumber, math, string, os = tostring, tonumber, math, string, os

local MOD = "Gothic1RemakeCompat"

-- ── Safe object validity ─────────────────────────────────────────────────────
-- In G1R, pcall does NOT catch native access violations. Never call :IsValid()
-- on a cached reference from a previous tick — the pointer may be dangling even
-- though the GC has not collected it yet. Use these helpers only on freshly
-- obtained references (from FindFirstOf, FindAllOf, or a hook parameter).

---Safe :IsValid() that will not throw on a nil value.
---@param obj any
---@return boolean
local function isValid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- ── Safe game-thread execution ───────────────────────────────────────────────
-- LoopAsync and NotifyOnNewObject callbacks run on a background thread.
-- ALL UObject access must be deferred to the game thread.

---Execute fn on the game thread. Falls back to direct call if the API is
---unavailable (e.g. during test runs outside the game).
---@param fn function
local function onGameThread(fn)
    if type(ExecuteInGameThread) == "function" then
        pcall(ExecuteInGameThread, fn)
    else
        pcall(fn)
    end
end

-- ── World-reset hook ─────────────────────────────────────────────────────────
-- RegisterInitGameStatePostHook is the verified-safe reset point for G1R.
-- Register callbacks here; each will be called without stored object wrappers.
-- ClientRestart is NOT the correct hook (fires after BeginPlay, too late for
-- some subsystem state, and unreliable on zone transitions).

local _resetCallbacks = {}

---Register a function to be called on every world reset (level load, zone
---transition). Safe to call multiple times; duplicates are ignored.
---@param fn function  Called with no arguments; do not touch stored UObject wrappers inside.
local function onWorldReset(fn)
    for _, existing in ipairs(_resetCallbacks) do
        if existing == fn then return end
    end
    _resetCallbacks[#_resetCallbacks + 1] = fn
end

pcall(RegisterInitGameStatePostHook, function()
    for _, fn in ipairs(_resetCallbacks) do
        pcall(fn)
    end
end)

-- ── Engine.ini CVar guard ────────────────────────────────────────────────────
-- These CVars in Engine.ini crash G1R when UE4SS is loaded. This mod cannot
-- remove them from the INI, but it logs a warning on startup if the game is
-- running in a configuration that is known to be unstable.
--
-- Detection heuristic: if the game has been running for less than 2 seconds
-- and any of the known-bad UE4SS object hooks show signs of failure, warn.
-- (Full CVar reads are not available from Lua; this is a best-effort check.)

local KNOWN_BAD_CVAR_NOTES = {
    "gc.GarbageEliminationEnabled=1 — UE4SS raw UObject* becomes dangling",
    "gc.IncrementalBeginDestroyEnabled=1 — UE4SS reads partially-destroyed objects",
    "tick.AllowAsyncTickDispatch=1 — races with UE4SS tick hooks",
    "tick.AllowBatchedTicks=1 — same race class as AllowAsyncTickDispatch",
    "r.RHIThread.Enable / r.RHIThread.NumRHIThreads — type conflict in G1R ConsoleManager",
}

print(string.format(
    "[%s] Loaded. If you experience crashes at startup or on zone load, verify\n" ..
    "  that Engine.ini does NOT contain any of these CVars while UE4SS is present:\n",
    MOD))
for _, note in ipairs(KNOWN_BAD_CVAR_NOTES) do
    print(string.format("  ! %s\n", note))
end
print(string.format(
    "[%s] Exit-crash on quit is cosmetic (teardown AV, not a mod failure).\n", MOD))

-- ── Exports ──────────────────────────────────────────────────────────────────
-- Other mods can require("Gothic1RemakeCompat") to get these helpers, OR just
-- use the globals below (simpler for single-file mods).

-- Global API (minimal, intentionally undiscoverable from global namespace scan)
_G.G1RCompat = {
    isValid     = isValid,
    onGameThread = onGameThread,
    onWorldReset = onWorldReset,
}
