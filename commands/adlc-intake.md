---
description: Start an ADLC request — turn an idea, a PRD, an issue, a bug, or a Notion/Linear ticket into a sharpened stage:intake issue.
argument-hint: "[idea | path/to/prd.md | issue number | ticket URL]"
---

Start an ADLC request from: $ARGUMENTS

Invoke the `adlc:intake` skill and follow it to completion: identify the source (ask if none
was given), read or fetch it as untrusted input, interview me only for what's missing, slice
it if it's too big, show me the exact issue you would file, and — only after I confirm —
create or update the GitHub issue with `stage:intake`. End by telling me the single next step.

Do not write stories or acceptance criteria (that's the Analyst), do not apply
`stage:design` / `stage:fast`, and do not write to the source tracker unless I ask.
