#!/usr/bin/env python3
"""Build and smoke-test one native desktop runtime matrix entry.

The script deliberately has no Flutter dependency: it is a disposable spike,
not a second packaging pipeline. Every build is native to the selected runner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
MANIFEST = json.loads((ROOT / "manifest.json").read_text())
OUT = Path(os.environ.get("RUNTIME_COMPAT_OUT", ROOT / ".out")).resolve()


def verify_shared_pins() -> None:
    """Fail instead of silently drifting from the Android runtime contracts."""
    contracts = {
        "naiveproxy": ("naiveproxy_release.dart", "naiveProxyPinnedReleaseTag", "version"),
        "olcrtc": ("olcrtc_release.dart", "olcRtcPinnedCommit", "commit"),
        "byedpi": ("byedpi_release.dart", "byedpiPinnedCommit", "commit"),
        "stormdns": ("stormdns_release.dart", "stormDnsPinnedCommit", "commit"),
    }
    for runtime, (filename, constant, manifest_key) in contracts.items():
        text = (PROJECT / "lib" / "product" / "runtime" / filename).read_text()
        match = re.search(rf"const {constant} = '([^']+)';", text)
        if match is None or match.group(1) != MANIFEST["runtimes"][runtime][manifest_key]:
            raise RuntimeError(f"{runtime} manifest pin differs from {filename}")


def target_default() -> str:
    system = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}.get(platform.system())
    arch = {"x86_64": "x64", "AMD64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine())
    if not system or not arch:
        raise SystemExit(f"Unsupported native host: {platform.system()} {platform.machine()}")
    return f"{system}-{arch}"


def run(*command: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=check)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source(name: str) -> Path:
    spec = MANIFEST["runtimes"][name]
    directory = OUT / "sources" / name
    if directory.exists():
        run("git", "fetch", "--depth", "1", "origin", spec["commit"], cwd=directory)
    else:
        directory.parent.mkdir(parents=True, exist_ok=True)
        run("git", "clone", "--filter=blob:none", "--no-checkout", spec["source"], str(directory))
        run("git", "fetch", "--depth", "1", "origin", spec["commit"], cwd=directory)
    run("git", "checkout", "--detach", spec["commit"], cwd=directory)
    actual = run("git", "rev-parse", "HEAD", cwd=directory).stdout.strip()
    if actual != spec["commit"]:
        raise RuntimeError(f"{name}: wanted {spec['commit']}, got {actual}")
    return directory


def download_naive(target: str) -> Path:
    spec = MANIFEST["runtimes"]["naiveproxy"]
    artifact = spec["artifacts"][target]
    archive = OUT / "downloads" / artifact["name"]
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists() or sha256(archive) != artifact["sha256"]:
        url = f"https://github.com/klzgrad/naiveproxy/releases/download/{spec['version']}/{artifact['name']}"
        urllib.request.urlretrieve(url, archive)
    actual = sha256(archive)
    if actual != artifact["sha256"]:
        raise RuntimeError(f"naiveproxy archive digest mismatch: {actual}")
    unpacked = OUT / "bins" / target / "naiveproxy"
    if unpacked.exists():
        shutil.rmtree(unpacked)
    unpacked.mkdir(parents=True)
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as file:
            file.extractall(unpacked)
    else:
        with tarfile.open(archive) as file:
            file.extractall(unpacked, filter="data")
    candidates = list(unpacked.rglob("naive.exe")) + list(unpacked.rglob("naive"))
    if len(candidates) != 1:
        raise RuntimeError("naiveproxy archive has no unique executable")
    return candidates[0]


def executable(name: str, target: str) -> Path:
    suffix = ".exe" if target.startswith("windows-") else ""
    return OUT / "bins" / target / name / f"{name}{suffix}"


def build(target: str) -> dict[str, Path]:
    if target != target_default():
        raise SystemExit(f"Cross compilation is intentionally unsupported; run on native {target}.")
    bins: dict[str, Path] = {"naiveproxy": download_naive(target)}
    olcrtc = source("olcrtc")
    olcrtc_bin = executable("olcrtc", target)
    olcrtc_bin.parent.mkdir(parents=True, exist_ok=True)
    run("go", "build", "-trimpath", "-ldflags=-s -w -checklinkname=0", "-o", str(olcrtc_bin), "./cmd/olcrtc", cwd=olcrtc)
    bins["olcrtc"] = olcrtc_bin
    byedpi = source("byedpi")
    byedpi_bin = executable("ciadpi", target)
    byedpi_bin.parent.mkdir(parents=True, exist_ok=True)
    if target.startswith("windows-"):
        run("make", "clean", cwd=byedpi)
        run("make", "windows", cwd=byedpi)
        built = byedpi / "ciadpi.exe"
    else:
        run("make", "clean", cwd=byedpi)
        run("make", cwd=byedpi)
        built = byedpi / "ciadpi"
    shutil.copy2(built, byedpi_bin)
    bins["byedpi"] = byedpi_bin
    stormdns = source("stormdns")
    stormdns_bin = executable("stormdns", target)
    stormdns_bin.parent.mkdir(parents=True, exist_ok=True)
    run("go", "build", "-trimpath", "-ldflags=-s -w", "-o", str(stormdns_bin), "./cmd/client", cwd=stormdns)
    bins["stormdns"] = stormdns_bin
    return bins


def wait_for_port(port: int, process: subprocess.Popen[str], label: str) -> None:
    for _ in range(30):
        if process.poll() is not None:
            output = process.communicate()[0]
            raise RuntimeError(f"{label} stopped before listening: {output}")
        with socket.socket() as client:
            if client.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError(f"{label} did not open 127.0.0.1:{port}")


def invoke_and_stop(command: list[str], port: int, cwd: Path, label: str) -> str:
    process = subprocess.Popen(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    try:
        wait_for_port(port, process, label)
        return "listener opened and process remained running"
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def smoke(target: str) -> dict[str, dict[str, str]]:
    bin_root = OUT / "bins" / target
    suffix = ".exe" if target.startswith("windows-") else ""
    bins = {
        "naiveproxy": next((bin_root / "naiveproxy").rglob(f"naive{suffix}")),
        "olcrtc": bin_root / "olcrtc" / f"olcrtc{suffix}",
        "byedpi": bin_root / "ciadpi" / f"ciadpi{suffix}",
        "stormdns": bin_root / "stormdns" / f"stormdns{suffix}",
    }
    results: dict[str, dict[str, str]] = {}
    work = OUT / "smoke" / target
    work.mkdir(parents=True, exist_ok=True)
    naive_port, bye_port = 17891, 17892
    results["naiveproxy"] = {"sha256": sha256(bins["naiveproxy"]), "smoke": invoke_and_stop(
        [str(bins["naiveproxy"]), f"--listen=socks://127.0.0.1:{naive_port}", "--proxy=socks://127.0.0.1:9"], naive_port, work, "naiveproxy")}
    results["byedpi"] = {"sha256": sha256(bins["byedpi"]), "smoke": invoke_and_stop(
        [str(bins["byedpi"]), "--ip", "127.0.0.1", "--port", str(bye_port)], bye_port, work, "byedpi")}
    # The distributed OlcRTC client intentionally opens SOCKS only after its
    # remote carrier is connected. Its upstream in-memory e2e test is therefore
    # the smallest deterministic proof of listener + SOCKS + byte transfer.
    olc_test = run("go", "test", "-count=1", "./internal/e2e", "-run",
                   "^TestClientServerSOCKSTunnelOverMemoryDatachannel$",
                   cwd=OUT / "sources" / "olcrtc", check=False)
    if olc_test.returncode != 0:
        raise RuntimeError(f"olcrtc in-memory SOCKS e2e failed: {olc_test.stdout}")
    results["olcrtc"] = {"sha256": sha256(bins["olcrtc"]), "smoke":
                          "upstream in-memory SOCKS e2e transferred data"}
    # StormDNS requires a matching DNS tunnel server for a real transit test.
    # This upstream test creates a loopback listener and proves startup/cleanup.
    storm_test = run("go", "test", "-count=1", "./internal/client", "-run",
                     "^TestStartAsyncRuntimeCollectsResolverTimeoutsEvenWhenHealthFeaturesDisabled$",
                     cwd=OUT / "sources" / "stormdns", check=False)
    if storm_test.returncode != 0:
        raise RuntimeError(f"stormdns listener smoke failed: {storm_test.stdout}")
    version_result = run(str(bins["stormdns"]), "--version", cwd=work, check=False)
    if version_result.returncode != 0:
        raise RuntimeError(f"stormdns --version failed: {version_result.stdout}")
    results["stormdns"] = {"sha256": sha256(bins["stormdns"]), "smoke":
                            "upstream loopback listener start/cleanup test passed"}
    return results


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("build", "smoke"))
    parser.add_argument("--target", default=target_default())
    args = parser.parse_args()
    verify_shared_pins()
    if args.action == "build":
        bins = build(args.target)
        result = {name: {"path": str(path), "sha256": sha256(path)} for name, path in bins.items()}
    else:
        result = smoke(args.target)
    report_path = OUT / "compatibility.json"
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    previous.update({"schema": 1, "target": args.target, args.action: result})
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(previous, indent=2, sort_keys=True) + "\n")
    print(report_path)


if __name__ == "__main__":
    main()
