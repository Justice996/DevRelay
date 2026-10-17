# Evidence manifest

Mode: **safe (metadata only)**

Source evidence: `%USERPROFILE%\Desktop\DevRelay\.p0-evidence`

## Policy

- Safe mode never writes prompts, business answers, model output, or raw engine
  error strings — only statuses, exit codes, timings, controlled error classes,
  and byte count + SHA-256 of captured streams.
- Every artefact (this manifest included) passes through one choke point that
  strips local identity/token shapes and then re-runs a leak detector; a
  detection means the file is not written and the export exits non-zero.
- Unclassified free text is not exported at all. Pattern scrubbing is defence in
  depth, not a guarantee.
- Raw Pi session transcripts are never exported in any mode.
- Raw model output is refused inside the git working tree (`-IncludeModelOutput` guard).

Redactions applied: **2** (path/token patterns)

## Exported files

| file | sha256 | bytes |
| --- | --- | --- |
| `p0-01/environment.txt` | `15dded92406a6040e978a073a45559fea8233851d03fd4891fb01360139df72d` | 17070 |
| `p0-02/integration-status.txt` | `4a18dc63703eb2a319c4dd89ec498496a6e8cbad712154414b7d2681ff44f5a9` | 245 |
| `p0-03/workflow-info.txt` | `b7792ee066ffd2c299c5bc6e014cb5d48c76623dd2cccee9ca1db23d4dbe4848` | 584 |
| `verification-summary.md` | `62240f240001a4d95f48a92c63f4d7ee6755264a0026a694bc9945432e111ce1` | 2460 |
| `summary.redacted.json` | `a5039bda9ff7a10b19a2fff03a2aac78417a8269ed63553fb8323210c4fc4541` | 5355 |
| `run-state-snapshot.md` | `005c9cb8c33c428cf9f7f969b874fd0af07bd6fc739c8ec96f98b9b074c35b1a` | 36266 |

(A manifest cannot list or hash itself; it is written last and also passes the choke point.)

## Withheld local evidence

Present locally, intentionally not exported. Reproduce with `scripts\verify-p0.ps1`.

| local path | bytes | sha256 | reason |
| --- | --- | --- | --- |
| `summary.json` | 8295 | `e26f2e303009b7fd67c5c2df691f6d3f0635bd6e1b2512137428cba780162a55` | full check details may quote model output; redacted version exported as summary.redacted.json |
| `full-run-console.txt` | 15298 | `4960eb739c05b806d5e5e67bf84aa7d75ac881dac4c1a0694c240b41685eea6d` | raw runner transcript containing model output / business text |
| `p0-01/pi-empty-dir-smoke.txt` | 319 | `74009d9f992638cf9afda2b1fd4b044d087c36d07390fb3aed5b81720ea317cc` | raw runner transcript containing model output / business text |
| `p0-02/probe-run.txt` | 659 | `24c8ef1385a1d8371937a4bd78cd58b59f63002e15daa9bbcc2ab8351f15defa` | raw runner transcript containing model output / business text |
| `p0-02/capture-probe.txt` | 349 | `8cd30c432e052ba678de4cc91f722d2d5586bbd6b0580a606854111a37b1d505` | raw runner transcript containing model output / business text |
| `p0-03/phase1-run.txt` | 2746 | `5709ff57dbe36207c7598ad85cecfcd3b51c556a4e1b1e8ab3d500829b8de7b8` | raw runner transcript containing model output / business text |
| `p0-03/phase2-resume.txt` | 10293 | `94baea7f6d2fdf7c8cc0d98b64c33744baae46d036cc490136a14f9cbaa5ad4f` | raw runner transcript containing model output / business text |
| `p0-03/phase3-resume.txt` | 5787 | `1f43d6c615de18da5adb0fa3d6c58e40435e4579944a71395226facc3a570362` | raw runner transcript containing model output / business text |
| `p0-03/final-status.txt` | 474 | `eae96b0bd3d1d462b7ae060df0c958894b2f257abb17e28f7e127b6768526769` | raw runner transcript containing model output / business text |
| `p0-03/reject-path.txt` | 1164 | `c6a50dd135015d92982e8f4a0a1a11f78ecfcfc948f655994e38a1b1a482421f` | raw runner transcript containing model output / business text |
| `pi-sessions/` | 229939 | `04500c35f82b6596466a62d3ee9988c578f57bc6a0a939dd39c25087709fd342` | raw Pi session transcripts (never exported) (directory: 6 files, aggregate digest of per-file SHA-256) |

## Run directories covered

- `020a02ca`
- `06d136cf`
- `0806e9c2`
- `17105496`
- `216c8040`
- `29c3a7e4`
- `2d32f2d5`
- `3f3e5a61`
- `5223705e`
- `5654ddf5`
- `57c6370a`
- `6df6aafe`
- `6e3501e1`
- `7c0167a8`
- `8c26e9a8`
- `922a364e`
- `99544051`
- `a6ae2440`
- `aca6ce2b`
- `b44e5b69`
- `bfae1471`
- `c7b34a9b`
- `c7bb434d`
- `cb9bfdc9`
- `cbd0b65d`
- `ce8b32eb`
- `d511e16a`
- `d5268d9c`
- `d7c9be1d`
- `da687c21`
- `fa20064e`