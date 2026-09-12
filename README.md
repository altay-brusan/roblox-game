# LAST SIGNAL

A first-person cooperative horror-survival game for Roblox.
A RIPGAMES production. Chapter One: The Long Grade.

> At 02:17 the last evacuation train leaves an isolated maintenance yard. The
> line runs ninety kilometres north through forest, past five stops that all
> need something before the train can continue. A damaged radio offers guidance
> from a dispatcher. Some of the transmissions are not the dispatcher.
>
> **Keep the train moving. Stay together. Do not trust every voice on the radio.**

---

## Start here

| | |
| --- | --- |
| **Play it** | Open `LastSignal/build/LastSignal.rbxlx` in Roblox Studio and press Play |
| **Project README** | [LastSignal/README.md](LastSignal/README.md) |
| **What is verified and what is not** | [LastSignal/docs/STATUS.md](LastSignal/docs/STATUS.md) |
| **Install and configuration** | [LastSignal/docs/SETUP.md](LastSignal/docs/SETUP.md) |

**Read `STATUS.md` before forming any expectation about what works.** Every
line of this project type-checks in strict mode against the real Roblox API and
the place file builds. None of it has been run, because Roblox Studio was not
available on the machine it was built on.

---

## Repository layout

```
LastSignal/
├── src/shared          configuration, registries, core utilities
├── src/server          20 services and 6 world builders
├── src/client          10 controllers and the interface kit
├── src/replicatedfirst the loading screen
├── docs/               12 documents: setup, status, monetization, admin, ...
├── scripts/            check.sh and build.sh
└── build/              the built place file

tools/                  build toolchain, not committed; see docs/SETUP.md
```

64 Luau modules, roughly 32,000 lines.

---

## Three things ship deliberately switched off

Each fails safely rather than guessing.

- **Monetization IDs are all zero.** The shop shows every product as
  Unavailable and no purchase can be attempted or simulated.
  See [MONETIZATION.md](LastSignal/docs/MONETIZATION.md).
- **Administrator user IDs are zero.** RIPjafar1 and shayanbrusan1234 are
  listed with their roles set, but a role with ID 0 grants nothing.
  See [ADMIN.md](LastSignal/docs/ADMIN.md).
- **Audio asset IDs are zero.** The mixer, ducking, occlusion and the full
  subtitle system all run; they have nothing to play.
  See [AUDIO.md](LastSignal/docs/AUDIO.md).

Robux is paid to whoever owns the published experience. The RIPGAMES name in
the code directs nothing. See [OWNERSHIP.md](LastSignal/docs/OWNERSHIP.md).

---

## Building from source

```bash
cd LastSignal
bash scripts/check.sh    # sourcemap, syntax, strict type check
bash scripts/build.sh    # writes build/LastSignal.rbxlx
```

The toolchain is not committed. [SETUP.md](LastSignal/docs/SETUP.md) has the
exact commands to download Rojo, the Luau compiler and luau-lsp.
