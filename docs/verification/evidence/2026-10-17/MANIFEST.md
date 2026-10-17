# Evidence manifest

Mode: **safe (metadata only)**

Source evidence: `C:\Users\13930\Desktop\DevRelay\.p0-evidence`

## Policy

- Safe mode never writes prompts, business answers or model output — only statuses,
  exit codes, timings, and byte count + SHA-256 of captured streams.
- Personal paths and token-shaped strings are stripped (`scripts/lib/verification-lib.ps1`).
- Raw Pi session transcripts are never exported in any mode.
- Raw model output is refused inside the git working tree (`-IncludeModelOutput` guard).

Redactions applied: **2** (path/token patterns)

## Exported files

| file | sha256 | bytes |
| --- | --- | --- |
| `p0-01/environment.txt` | `da8847fb0693553938397f267a25e01d4875970710daed5ce4d9bdb7bd9b74f4` | 16639 |
| `p0-02/integration-status.txt` | `4a18dc63703eb2a319c4dd89ec498496a6e8cbad712154414b7d2681ff44f5a9` | 245 |
| `p0-03/workflow-info.txt` | `b7792ee066ffd2c299c5bc6e014cb5d48c76623dd2cccee9ca1db23d4dbe4848` | 584 |
| `verification-summary.md` | `87fa05089be39ff01921392ecc473ad53deb0474ece432b1cc6b13046a6996e2` | 2214 |
| `summary.redacted.json` | `3ba2d88dca030886fc0e12f0a59e77f31fec523b09bcbcd5c1ba890776f1f7d5` | 5342 |
| `run-state-snapshot.md` | `a6ec1b4b88fdaccbc10d4eef8729218144db1afd5dc3fb7b303a389e2f0fbfaf` | 26415 |

## Withheld local evidence

Present locally, intentionally not exported. Reproduce with `scripts\verify-p0.ps1`.

| local path | bytes | sha256 | reason |
| --- | --- | --- | --- |
| `summary.json` | 8237 | `2ae6ee02fc54fe925d65ee79b05ff3297a193b0b0ada1aea1e750159e154b5b9` | full check details may quote model output; redacted version exported as summary.redacted.json |
| `full-run-console.txt` | 15182 | `f23ddd23f9a6b45e430895ed63336492fb7630bee2fda566bfb04f6bdf650730` | raw runner transcript containing model output / business text |
| `p0-01/pi-empty-dir-smoke.txt` | 280 | `6fb349ec5fac749a7ef0757221e4b38fa01dde9d576b8343d6cdf12818bd5c47` | raw runner transcript containing model output / business text |
| `p0-02/probe-run.txt` | 665 | `e27a17df93ce669b6c00a74ce408049bacd31469a4b151825281baf1fa3716ad` | raw runner transcript containing model output / business text |
| `p0-02/capture-probe.txt` | 349 | `d288ca0fb3d31a39944682daa95785659947c62fa3658acbb011599e28b63003` | raw runner transcript containing model output / business text |
| `p0-03/phase1-run.txt` | 2803 | `509c396b7f84abdee49156d32a0f07f4bf605a85e81d45172bce31f51acaed81` | raw runner transcript containing model output / business text |
| `p0-03/phase2-resume.txt` | 10703 | `2b76ed96c03e323b21572815c583fced424b31e7cdf9761ef877a16db56f26eb` | raw runner transcript containing model output / business text |
| `p0-03/phase3-resume.txt` | 5312 | `20176db8518ba21cc7ac999e09db5db1071c7207a5fe843384dfc8cf836af057` | raw runner transcript containing model output / business text |
| `p0-03/final-status.txt` | 474 | `3c9ac30dba9d369cc272e180096d5c161fcc366081bb01125c7612941d687e4c` | raw runner transcript containing model output / business text |
| `p0-03/reject-path.txt` | 1164 | `1cb447fdeb477e0f6d75d69bb4d1194976abae724a326f380007de19411c8aa9` | raw runner transcript containing model output / business text |
| `pi-sessions/` | 170350 | `c101b0eef43617c5bc3b2942234e1812cca0fb4e732daf8867dc7209a8b6e1b9` | raw Pi session transcripts (never exported) (directory: 6 files, aggregate digest of per-file SHA-256) |

## Run directories covered

- `020a02ca`
- `06d136cf`
- `17105496`
- `216c8040`
- `29c3a7e4`
- `3f3e5a61`
- `5223705e`
- `57c6370a`
- `6df6aafe`
- `6e3501e1`
- `7c0167a8`
- `8c26e9a8`
- `a6ae2440`
- `aca6ce2b`
- `bfae1471`
- `c7b34a9b`
- `c7bb434d`
- `cb9bfdc9`
- `cbd0b65d`
- `ce8b32eb`
- `d511e16a`
- `d5268d9c`
- `d7c9be1d`