# 9router-opencode-fix
Patches 9Router's compiled opencode free executor so anonymous free requests carry the client identity headers the real opencode CLI sends. Without them, requests land in a shared anonymous bucket and fail with **"Free usage exceeded"** after a couple of calls.
