---
description: Open ADLC Mission Control, the live view of this repo's pipeline (stations, requests, tokens, cost).
---

Open ADLC Mission Control for this repository.

1. Start it in the background with `adlc-mission-control --open` (the plugin puts this on the
   Bash PATH; it keeps running until stopped). If it says Mission Control is already running,
   that is fine: use the address it prints.
2. Tell me the address (default `http://localhost:4319`) and one line on what the page shows.
3. If the page will have no token or cost figures because telemetry is off, say so, and offer to
   add the `env` block from the plugin's `templates/settings.mission-control.json` to this
   repo's `.claude/settings.local.json`. Show me the block and ask before writing. New Claude
   Code sessions pick it up; running ones do not.

Mission Control only reads: it never changes labels, merges, or comments. If `gh` is not signed
in or the directory is not a GitHub repo, report what the launcher printed instead of working
around it. To see it without a real pipeline, use `adlc-mission-control --demo --open`.
