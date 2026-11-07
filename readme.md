#### Decisions made so far

- **Challenge:** three high-beam flashes within 2.5 s, while behind a cruising traffic car. He always accepts.
- **Distance** between the two cars (straight-line, as it works now) stays the core measure. No road-distance system.
- **Health bars** replace the instant win/lose. The driver who is behind loses health, and a bigger gap drains it faster. A small dead zone near zero gap drains nothing. The leader does **not** regenerate.
- **Race ends** when one bar hits zero. At time out, the driver with more health wins.
- **Rival attacks** when you’re ahead: he picks a lane where you aren’t in front of him, and only lanes that exist. He re-evaluates if you switch in front of him, with a cooldown.
- **Rival defends** when he’s ahead, depending on his profile. Mirroring lasts a short burst, then a cooldown gives you an opening.
- **Map:** Shutoko C1 and Wangan. One direction, guard rails, 2 to 4 lanes, high speeds, tight turns on C1.
- **Countdown:** the rival keeps his own speed. If you’re not close in speed and distance when the countdown runs, it’s a **false start** and the race is cancelled. We don’t force the player’s speed.
- **UI is separate:** you write it in JS. The Lua side only sends it data (see below).
- **Profiles:** human-like names, plus a `tier` parameter (rookie, regular, ace, boss). Several sample profiles in a separate data file.

#### Order of work

0. **Your input:** the `TBR` log lines, whether the rival changed lanes at all, and the repo files (raw links or pasted).
1. **Lanes:** attack and basic defense, with lane-count awareness (no swerving into the rail). Depends on whether `ai.laneChange` works.
2. **Health and race rules:** drain by gap, dead zone, time-out result, false-start cancel. The old 120 m / 2 s win condition goes away.
3. **UI data contract:** Lua sends one state table to the UI, and you build the JS side.
4. **Profiles:** the data file with sample profiles, and Lua reads every number from the active profile. A console command to force a profile for testing.
5. **Later:** mirror-defense bursts with the cooldown hint, profile selection by rival car or progress, mistakes for weak drivers.