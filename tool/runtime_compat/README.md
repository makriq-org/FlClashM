# Desktop runtime artifacts

This directory is the production source of desktop runtime artifacts. It grows
the original native compatibility spike into a self-contained install layout
for mihomo, NaiveProxy, OlcRTC, ByeDPI and StormDNS.

`manifest.json` is the only desktop matrix and pin table. The build fails when
its versions or commits differ from the Android contracts. Downloaded
NaiveProxy archives are verified against their pinned SHA-256 before extraction.

Run the complete native pipeline with:

```bash
tool/runtime_compat/build.sh --target linux-x64
tool/runtime_compat/smoke.sh --target linux-x64
tool/runtime_compat/verify.sh --target linux-x64
```

Set `RUNTIME_COMPAT_OUT` to move temporary sources and output outside the
checkout. The produced bundle root is `install/`; copy it to
`.dart_tool/desktop-runtime-assets/` before invoking a Flutter desktop packager.
The packagers fail closed if the target inventory or any required binary is
missing, has the wrong architecture, or no longer matches its SHA-256.

NaiveProxy and ByeDPI are exercised as local listeners. OlcRTC uses its pinned
upstream in-memory SOCKS transfer test, while StormDNS uses its pinned upstream
loopback startup/cleanup test. These are deterministic native proofs and are
intentionally not described as external Internet end-to-end tests.
