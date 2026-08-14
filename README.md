# 9Router "Free usage exceeded" Fix

Patches 9Router's compiled opencode free executor so anonymous free requests carry
the client identity headers the real opencode CLI sends. Without them, requests land
in a shared anonymous bucket and fail with **"Free usage exceeded"** after a couple
of calls.

## Why this happens

9Router forwards your chat to opencode.ai/zen. The real opencode CLI identifies every
request with:

| Header | Value |
|---|---|
| `x-opencode-session` | `ses_<random>` — stable per app run |
| `x-opencode-project` | `p_<random>` — stable per project |
| `x-opencode-request` | `ses_<id>:<timestamp>:<random>` — unique per call |
| `User-Agent` | `opencode/1.17.0` |

9Router's compiled executor sends **none of these** (only `Authorization: Bearer public`),
so zen lumps all anonymous traffic into one sessionless bucket that throttles after a
couple of calls → "Free usage exceeded".

## What the fix does

The script finds the opencode executor chunk (`318.js` under
`app\.next-cli-build\server\chunks\`), then rewrites its `buildHeaders()` to synthesize
the real-client identity:

```js
// injected, stable per app run
this._sid = "ses_" + Math.random()...   // session
this._pid = "p_"  + Math.random()...   // project
// per request
"x-opencode-request": this._sid + ":" + Date.now() + ":" + Math.random()...
"User-Agent": "opencode/1.17.0"
```

Resulting headers look exactly like the real CLI's:

```
x-opencode-session: ses_k73b27pdbv7x9ur1ry6rjfw96ctvbvirrxbk87npj4cb
x-opencode-project: p_cnd42xu0s91tz6l1qnr8p
x-opencode-request: ses_k73b27pdbv7x9ur1ry6rjfw96ctvbvirrxbk87npj4cb:1786654211941:01h20qh79fb9
User-Agent: opencode/1.17.0
```

Session and project are **stable** across calls (cached on the executor instance), the
request id changes every call — exactly the identity zen's free quota keys on.

## Usage

Double-click `fix-9router.bat`, or run in a terminal:

```
powershell -ExecutionPolicy Bypass -File fix-9router.ps1
```

Then **restart 9Router** (the chunk is loaded at startup).

### On another machine / fresh install

Requirements:

- **Windows** with **PowerShell 5.1+** (built in)
- **Node.js** — only used for `node --check` syntax validation; if absent, the script
  warns and still applies the patch
- **9Router installed via npm** (`npm i -g 9router`) so the script can locate it
  through `npm root -g`

> If 9Router is installed somewhere unusual (e.g. under a local `node_modules` or a
> different npm root), the script's fallback paths may miss it — check the paths in
> `Get-9RouterInstall` and add the actual location.

## Safety

- Backs up the chunk to for example `318.js.bak` before touching it
- Patches only the exact `buildHeaders()` signature — if the pattern isn't found
  (version changed), it aborts with **no changes**
- Runs `node --check` after writing; on failure it **restores the backup**
- Idempotent: if `x-opencode-session` is already present, it exits without touching

## Files

| File | Purpose |
|---|---|
| `fix-9router.ps1` | The actual patch logic |
| `fix-9router.bat` | One-click launcher (calls the .ps1) |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: 9Router install not found` | Install via `npm i -g 9router`, or edit `Get-9RouterInstall` paths in the .ps1 |
| `ERROR: opencode executor chunk not found` | The marker `Authorization:"Bearer public"` wasn't found in any chunk under `app\.next-cli-build\server\chunks` — check the folder exists and the chunk content marker is still there |
| `ERROR: buildHeaders signature not found` | 9Router version changed the executor code — send the new executor chunk (`app\.next-cli-build\server\chunks\*.js` containing `Authorization:"Bearer public"`) for a pattern refresh |
| Still "Free usage exceeded" after patching | Restart 9Router; also try restarting the tray app |

## Note on updates

`npm i -g 9router@latest` **overwrites the patched chunk** — re-run the script after
any 9Router update.
