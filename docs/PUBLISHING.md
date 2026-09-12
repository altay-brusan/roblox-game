# Publishing and place topology

Single-place mode, two-place mode, and how to switch.

---

## The two modes

The brief asks for a lobby separate from the expedition. There are two ways to
do that on Roblox, with very different prerequisites.

### Single place (the default, works now)

The lobby and every active expedition live in one place, far apart in world
space. Crews are moved between them by the server. No teleport is involved, so
none of the teleport failure modes exist.

**Works immediately.** No publishing, no API access, no configuration. Open the
file and press Play.

**The limitation.** Everything shares one server's memory, so the number of
concurrent expeditions is bounded. `GameConfig.MaxConcurrentExpeditions`
defaults to 2, and `MaxServerPlayers` to 12 to match. A third crew is told
plainly that the line is occupied and pointed at another server, rather than
being left waiting.

### Two places (needs publishing)

The lobby is one published place; the expedition is a second place in the same
universe. Crews are teleported to a reserved server for their run.

**The advantage.** Each crew gets a whole server. The concurrent-expedition cap
disappears, the lobby stays light, and the player cap can go up.

**The prerequisite.** Both places must be published in the same universe, and
the lobby place must know the expedition place's ID.

Every teleport path for this mode is written, including the failure branches:
timeout, retry, a departure landing while a player is still loading, and a
reconnect. None of it has been exercised, because it cannot be until both
places exist. See [STATUS.md](STATUS.md).

---

## Switching to two-place mode

1. **Publish the current place.** File, Publish to Roblox As. This becomes the
   lobby place.

2. **Create the second place.** In Creator Hub, open your experience, go to
   **Places**, and create a new place. Name it something like
   "LAST SIGNAL - Expedition".

3. **Publish the same build to it.** In Studio, File, Publish to Roblox As, and
   select the new place. Both places run the same code; `PlaceMode` and the
   place IDs are what make them behave differently.

4. **Collect both place IDs.** In Creator Hub, each place lists its ID. It is
   not the universe ID and it is not the experience ID.

5. **Set the configuration** in `src/shared/Config/GameConfig.luau`:

   ```lua
   GameConfig.PlaceMode = "two"
   GameConfig.LobbyPlaceId = 123456789
   GameConfig.ExpeditionPlaceId = 987654321
   ```

6. **Raise the player cap** if you want to, in Game Settings.

7. **Rebuild and republish both places.**

If `PlaceMode` is `"two"` but either ID is still zero, the server logs a warning
at boot and falls back to single-place behaviour rather than attempting a
teleport that cannot work.

---

## Teleport failure handling

What the code does when a teleport goes wrong, once this mode is live:

- **Timeout.** `GameConfig.TeleportTimeoutSeconds` is 20. After that the client
  is shown recovery options rather than being left on a loading screen.
- **Retry.** `TeleportRetryAttempts` is 3, with backoff.
- **Departure while loading.** A player still loading when their crew departs
  is placed with the crew on arrival rather than being left behind.
- **Reconnect.** A player who drops mid-expedition has their slot held for
  `ReconnectGraceSeconds`, which is 180. Rejoining puts them back with their
  crew.
- **Total failure.** The crew is returned to the lobby with a clear message.
  Nobody is stranded.

---

## Which to choose

**Use single-place mode** while you are testing, tuning and filling in the
audio and monetization IDs. It is simpler and every problem is one server away.

**Move to two-place mode** when the game is public and more than a couple of
crews are playing at once. The signal that you have outgrown single-place is
players reporting that the line is occupied.

The switch is three values and a republish. It is not a rewrite, which is why
both modes are supported rather than one being chosen for you.
