# Documentation

## UniVoidDistro

| File | What |
|---|---|
| [uni/ROADMAP.md](uni/ROADMAP.md) | this distribution's plan: the adaptive architecture, tracks, milestones M0, U1-U6 and V, measurements, success criteria, risks |
| [uni/principles.md](uni/principles.md) | the rules of adaptivity on top of the upstream rules; the protective properties per architecture |
| [uni/hardware.md](uni/hardware.md) | what hardware is supported, how each piece is detected, what the plan does with it, what is not supported |

## Upstream (void-hardperf-light)

The plan and the documents of the shared tracks, merged from upstream unchanged.

| File | What |
|---|---|
| [ROADMAP.md](ROADMAP.md) | the development plan: context, components, milestones, measurements, verification, risks |
| [principles.md](principles.md) | the rules every change follows, and what changes against the predecessor |
| [19-benchmarks.md](19-benchmarks.md) | the measurements from v0.1 on: stage 1 (runit-void shell against vh-stage1) |
| [runbook-gf63.md](runbook-gf63.md) | procedures for the laptop, run by its owner: v0.1 vh-stage1 install, check, measure, rollback |
| [ru/](ru/) | the Russian guide of Void-Hardened-Refurs, chapters 00-18: the system this repository starts from |

English chapters are written per milestone: `spikes/S*.md` for the spikes, `recovery.md` for
the laptop, the rewritten guide with 1.0.
Until then the Russian chapters in `ru/` are the source material; where a program's message is
quoted there, the English program now prints the English equivalent (see
`tests/vm/vmlib.py` for the machine-readable contract).
