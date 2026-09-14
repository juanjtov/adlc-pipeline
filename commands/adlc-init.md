---
description: Launch the ADLC adoption wizard in this repo (dual-mode greenfield/brownfield setup).
---

Run the ADLC bootstrap wizard for this repository.

Invoke the `adlc:bootstrap` skill and follow it to completion: detect whether this repo is
greenfield (PRD only) or brownfield (existing codebase), ask the clarifying questions,
generate the project-specific skills and config, optionally wire the GitHub labels and
Actions, and finish by telling me the single next step to a first pipeline run.

Do not commit or push anything — write the files for me to review. Confirm before any
GitHub write or before overwriting an existing file.
