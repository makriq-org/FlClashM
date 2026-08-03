# Runtime compatibility spike

This directory is intentionally independent from the application runtime path.
It tests the four embedded nodes on one native `OS × arch` runner and emits
`compatibility.json`; it does not produce release assets.

The existing Android release contracts remain the source of truth for versions
and commits. `manifest.json` mirrors those pins only because this spike must run
without Flutter. NaiveProxy desktop archives have upstream SHA-256 pins. The
other nodes are built from pinned commits and their resulting SHA-256 digests
are recorded in the report, since reproducible desktop digests have not yet
been established.

Run on a native host:

```bash
tool/runtime_compat/build.sh --target linux-x64
tool/runtime_compat/smoke.sh --target linux-x64
```

Set `RUNTIME_COMPAT_OUT` to place temporary sources, binaries and the report
outside the checkout. CI uses `runtime-compat-out/` and uploads it as an artifact.
