# devsync

Development helper, not part of the game. Lets an open Studio session pull
edited scripts from `LastSignal/src` without rebuilding and reopening the
place file.

1. `node tools/devsync/server.js` (listens on 127.0.0.1:34900)
2. In Studio (Edit mode), run `sync.luau` from the command bar.

It enables `HttpService.HttpEnabled` in the open session so the request can
be made. The shipped place is always built by `scripts/build.sh` from `src/`,
so that setting never reaches the published file.
