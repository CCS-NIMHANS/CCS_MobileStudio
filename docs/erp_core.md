# ERP CORE & Conventional ERP Laboratory

CCS Mobile Studio's Conventional ERP module (`lib/modules/generic_erp/`) includes configurable classic paradigms alongside all **6 standardized ERP CORE paradigms** (Kappenman et al., 2021).

## Supported ERP CORE Paradigms

| Paradigm | Primary Component | Task Overview | Default Key / Button Response |
| :--- | :--- | :--- | :--- |
| **N170** | N170 (110–190 ms) | Faces, cars, scrambled faces, and scrambled cars (`±` texture polarity / orientation check) | `Left` = Intact · `Right` = Scrambled |
| **MMN** | Mismatch Negativity (125–225 ms) | Passive auditory oddball (`1000 Hz` standard 80% vs. `1000 Hz` intensity/frequency deviant 20%) | Passive listening |
| **N2pc** | N2pc (200–300 ms) | Bilateral visual search array with Landolt-C / square gap discrimination on cued target color | `Left` / `Right` for top vs. bottom gap |
| **N400** | N400 (300–500 ms) | Word-pair semantic priming (related vs. unrelated prime–target pairs) | `Left` = Related · `Right` = Unrelated |
| **P3b** | P3b (300–600 ms) | Active visual oddball across target/non-target letter stream | `Left` = Rare Target · `Right` = Frequent |
| **ERN / LRP** | ERN (0–100 ms resp.) / LRP | Speeded Eriksen Flankers (`<<<<<`, `>>>>>`, `<<><<`, `>><>>`) | `Left` / `Right` matching center arrow |

## Precision Stimulus & Marker Timing

- **Visual Frame Locking:** Visual markers emit synchronously inside `WidgetsBinding.instance.addPostFrameCallback` right after the rendered stimulus frame commits, avoiding layout/paint jitter.
- **Auditory Scheduling:** MMN and auditory oddball tones use pre-rendered normalized PCM buffers with deterministic stimulus-onset marker emission.
- **Realtime ERP Averaging & Difference Wave:** Live baseline-corrected (`-100 to 0 ms`) ERP waveforms (`0 to 800 ms` post-stimulus) render asynchronously without stalling acquisition, with toggleable **Target − Standard / Congruent − Incongruent Difference Wave** overlay and component latency shading.
- **EDF+ Persistence:** Stimulus condition codes and behavioral responses are written directly into both the companion marker CSV and embedded `EDF Annotations` TAL track.
