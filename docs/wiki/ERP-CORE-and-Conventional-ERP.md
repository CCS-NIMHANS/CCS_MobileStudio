# ERP CORE & Conventional ERP Laboratory

The Generic / Conventional ERP module (`lib/modules/generic_erp/`) includes all **6 standardized ERP CORE paradigms** plus flexible visual/auditory oddball, N400, P50, MMN, and N170 tasks.

## ERP CORE Paradigms Included
1. **N170** — Faces vs. Cars vs. Scrambled controls (`±` intact vs. scrambled discrimination).
2. **MMN** — Passive auditory oddball (`80%` standard / `20%` deviant tone stream).
3. **N2pc** — Bilateral visual search display with upper/lower Landolt-style gap response.
4. **N400** — Word-pair semantic priming (related vs. unrelated word pairs).
5. **P3b** — Active visual target-letter oddball task.
6. **ERN / LRP Flankers** — Speeded congruent vs. incongruent arrow flanker discrimination.

## Zero-Jitter Timing & Live ERPs
- Visual paradigm event markers emit inside `WidgetsBinding.instance.addPostFrameCallback` immediately after frame presentation across **Generic ERP**, **ANGEL**, and **Adaptive WM**.
- Auditory paradigms use pre-synthesized PCM waveforms paired with deterministic trigger timestamps.
- Enable **Show waveform while recording** and **Overlay difference wave (Target − Standard)** to inspect live baseline-corrected ERPs (`-100..800 ms`) during acquisition without UI stutter.
