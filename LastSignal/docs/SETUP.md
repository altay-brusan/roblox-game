# Setup

What to install, and how to open, play, edit and rebuild the project.

---

## 1. Roblox Studio

**Not currently installed on this machine.** You need it; nothing else can open
a Roblox place.

1. Go to <https://create.roblox.com/> and sign in with the account that will
   own the game. If the game will belong to the RIPGAMES group, sign in with
   an account that has permission to publish to that group.
2. Click **Create** or **Download Studio**. Run the installer.
3. Launch Studio once and let it finish signing in.

Studio is free. It installs to `%LOCALAPPDATA%\Roblox` on Windows.

---

## 2. Open the game

The place file is already built:

```
C:\Projects\roblox\LastSignal\build\LastSignal.rbxlx
```

Double-click it, or in Studio use **File, Open from File** and select it.

Press **Play** (F5). The world builds itself at runtime: the yard first, then
an expedition lane in the background. Watch the **Output** window (View,
Output, or F9 while playing) for the boot log. It prints every service as it
starts, then a configuration report telling you exactly what is switched off
and why.

You do not need anything else installed to play it.

---

## 3. Editing the source

Two ways, depending on what you want to do.

### Option A: edit in Studio directly

Open the place, edit the scripts in the Explorer, and save the place. This is
fine for a quick change. The downside is that your edits live in the `.rbxlx`
file and not in `src/`, so they will be lost the next time anybody rebuilds
from source.

### Option B: edit the source files and rebuild (recommended)

The source of truth is `src/`. The toolchain that turns it into a place is
already downloaded to `tools/bin`:

- **Rojo 7.7.0** builds `src/` into a `.rbxlx`
- **luau-lsp 1.69.0** type-checks the whole project against the real Roblox API
- **luau-compile 0.738** checks that every file parses

To verify and rebuild:

```bash
cd C:/Projects/roblox/LastSignal
bash scripts/check.sh      # sourcemap, syntax, strict type check
bash scripts/build.sh      # writes build/LastSignal.rbxlx
```

Then reopen the built file in Studio.

Run `check.sh` before every build. It has caught real defects repeatedly and it
takes a couple of seconds.

### Option C: live sync with the Rojo plugin

If you want source edits to appear in Studio without rebuilding:

1. Download `Rojo.rbxm` from <https://github.com/rojo-rbx/rojo/releases> and
   drop it into Studio's plugins folder, or install Rojo from the Studio
   plugin marketplace.
2. Run the server:
   ```bash
   cd C:/Projects/roblox/LastSignal
   ./../tools/bin/rojo.exe serve default.project.json
   ```
3. In Studio, open the Rojo plugin and click **Connect**.

Changes to files in `src/` now appear in Studio as you save them.

---

## 4. If `tools/bin` is missing

The binaries are downloaded rather than committed. To reinstall them:

```bash
mkdir -p /c/Projects/roblox/tools/bin /c/Projects/roblox/tools/dl
cd /c/Projects/roblox/tools/dl

# Rojo
curl -sL -o rojo.zip https://github.com/rojo-rbx/rojo/releases/download/v7.7.0/rojo-7.7.0-windows-x86_64.zip

# Luau compiler and analyzer
curl -sL -o luau.zip https://github.com/luau-lang/luau/releases/download/0.738/luau-windows.zip

# luau-lsp, which is what does the strict type check
curl -sL -o lsp.zip https://github.com/JohnnyMorganz/luau-lsp/releases/download/1.69.0/luau-lsp-win64.zip

# Roblox API type definitions
curl -sL -o globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau

cd /c/Projects/roblox/tools/bin
unzip -o ../dl/rojo.zip
unzip -o ../dl/luau.zip
unzip -o ../dl/lsp.zip
```

---

## 5. Configuration, in the order it matters

Everything below fails safely if you skip it. Nothing guesses.

### Administrator user IDs

**File:** `src/shared/Config/Admin.luau`

```lua
Admin.Roles = {
    { userId = 0, username = "RIPjafar1",        role = "owner" },
    { userId = 0, username = "shayanbrusan1234", role = "admin" },
}
```

Replace each `0` with the account's numeric user ID. Find it by opening the
profile in a browser: `roblox.com/users/`**`1234567`**`/profile`. The number in
the URL is the user ID.

A role with `userId = 0` grants nothing at all. Until you fill these in, nobody
has administrative access, which is the correct default.

See [ADMIN.md](ADMIN.md).

### Monetization product IDs

**File:** `src/shared/Config/Monetization.luau`

Every product has `id = 0`. Create the Game Passes and Developer Products on
your published experience, then paste each numeric ID into the matching entry.
Zero means the shop shows the item as Unavailable and no purchase can be
attempted.

See [MONETIZATION.md](MONETIZATION.md) for which products to create, what to
call them, and where each ID goes.

### Audio asset IDs

**File:** `src/shared/Config/Audio.luau`

Every cue has `id = 0`. The game runs silently until you fill them in, with
subtitles carrying every informational cue. About an hour of work with the
Studio audio browser.

See [AUDIO.md](AUDIO.md).

### Optional: two-place mode

**File:** `src/shared/Config/GameConfig.luau`

```lua
GameConfig.PlaceMode = "single"
GameConfig.LobbyPlaceId = 0
GameConfig.ExpeditionPlaceId = 0
```

Single-place mode works immediately and needs nothing published. Two-place mode
gives each crew its own reserved server and removes the concurrent-expedition
cap. See [PUBLISHING.md](PUBLISHING.md).

---

## 6. Studio testing notes

**DataStores.** Studio usually cannot reach live DataStores, and using live
data from Studio risks overwriting real player progress.
`GameConfig.UseMockDataInStudio` is `true`, so Studio uses an in-memory store
instead. The full progression loop is testable; nothing touches production. The
boot log says `Data: Studio mock store` when this is active.

If you specifically want to test against live DataStores, enable **Game
Settings, Security, Enable Studio Access to API Services**, and set
`UseMockDataInStudio = false`. Be aware that you are then editing real data.

**Leaderboards** use OrderedDataStores and are disabled in Studio. The panel
says so rather than showing an empty list.

**Purchases** cannot be completed in Studio. The prompt opens; it will not
finish. ProcessReceipt is only exercised on a published experience.

**Multiplayer.** Use **Test, Clients and Servers**, set two or more players,
and click Start. This is the only way to test crews, revives and the
simultaneous objective at Tolbridge before publishing.

---

## 7. Project layout in the Explorer

After opening the built place:

```
ReplicatedStorage
└── LastSignal
    ├── Config      GameConfig, Balance, Monetization, Admin, Audio
    ├── Core        Signal, Maid, Net, Guard, Logger, Spring, Format, ...
    ├── Registry    Items, Weapons, Trains, Stations, Quests, Cosmetics, ...
    └── Remotes     created at boot by Net.initServer

ServerScriptService
└── LastSignalServer          (Script: the boot sequence)
    ├── Services              20 service modules
    └── World                 BuildKit and the five builders

StarterPlayer
└── StarterPlayerScripts
    └── LastSignalClient      (LocalScript: the client boot)
        ├── Controllers       10 controllers
        └── UI                Theme and Widgets

ReplicatedFirst
└── LoadingScreen             (LocalScript)

Workspace
└── LastSignalWorld           created at runtime
    ├── Lobby
    ├── Lane1
    └── Lane2
```

Nothing is stored in `Workspace` in the saved file. The world is built at
runtime, which is why the place file is small and why editing the world means
editing a builder rather than dragging parts.
