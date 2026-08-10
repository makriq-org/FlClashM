#!/usr/bin/env python3
"""Build, smoke-test and verify one native desktop runtime bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import stat
import struct
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
RUNTIME_NAMES = ("mihomo", "naiveproxy", "olcrtc", "byedpi", "stormdns")


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(*command: str, cwd: Path | None = None, check: bool = True,
        env: dict[str, str] | None = None, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False, env=env,
                            timeout=timeout)
    if check and result.returncode != 0:
        fail(f"command failed ({' '.join(command)}):\n{result.stdout}")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_shared_pins() -> None:
    if MANIFEST.get("schema") != 2:
        fail("desktop runtime manifest must use schema 2")
    contracts = {
        "naiveproxy": ("naiveproxy_release.dart", "naiveProxyPinnedReleaseTag", "version"),
        "olcrtc": ("olcrtc_release.dart", "olcRtcPinnedCommit", "commit"),
        "byedpi": ("byedpi_release.dart", "byedpiPinnedCommit", "commit"),
        "stormdns": ("stormdns_release.dart", "stormDnsPinnedCommit", "commit"),
    }
    for runtime, (filename, constant, manifest_key) in contracts.items():
        text = (PROJECT / "lib" / "product" / "runtime" / filename).read_text()
        match = re.search(rf"const {constant} = '([^']+)';", text)
        wanted = MANIFEST["runtimes"][runtime][manifest_key]
        if match is None or match.group(1) != wanted:
            fail(f"{runtime} manifest pin differs from {filename}: expected {wanted}")
    go_mod = (PROJECT / "core" / "go.mod").read_text()
    mihomo = re.search(r"github\.com/metacubex/mihomo\s+(v[\d.]+)", go_mod)
    wanted_mihomo = MANIFEST["runtimes"]["mihomo"]["version"]
    if mihomo is None or mihomo.group(1) != wanted_mihomo:
        fail(f"mihomo manifest pin differs from core/go.mod: expected {wanted_mihomo}")
    for filename, constant in (
        ("olcrtc_release.dart", "olcRtcPinnedGoVersion"),
        ("stormdns_release.dart", "stormDnsPinnedGoVersion"),
    ):
        text = (PROJECT / "lib" / "product" / "runtime" / filename).read_text()
        if f"const {constant} = '{MANIFEST['go']}';" not in text:
            fail(f"desktop Go pin differs from {filename}: expected {MANIFEST['go']}")


def target_default() -> str:
    system = {"Linux": "linux", "Windows": "windows", "Darwin": "macos"}.get(platform.system())
    arch = {"x86_64": "x64", "AMD64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine())
    if not system or not arch:
        raise SystemExit(f"Unsupported native host: {platform.system()} {platform.machine()}")
    return f"{system}-{arch}"


def target_spec(target: str, *, require_native: bool = False) -> dict[str, str]:
    spec = MANIFEST["targets"].get(target)
    if spec is None:
        supported = ", ".join(MANIFEST["targets"])
        raise SystemExit(f"Unsupported desktop runtime target {target}; supported: {supported}")
    if require_native and target != target_default():
        raise SystemExit(f"Cross compilation is unsupported; run {target} on its native host")
    return spec


def suffix(target: str) -> str:
    return ".exe" if target.startswith("windows-") else ""


def install_root(target: str) -> Path:
    spec = MANIFEST["targets"][target]
    return OUT / "install" / "runtimes" / spec["os"] / spec["architecture"]


def installed_path(name: str, target: str) -> Path:
    return install_root(target) / f"{name}{suffix(target)}"


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
        fail(f"{name}: expected commit {spec['commit']}, got {actual}")
    return directory


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as packed:
            members = packed.infolist()
            for member in members:
                if not (root / member.filename).resolve().is_relative_to(root):
                    fail(f"unsafe path in {archive.name}: {member.filename}")
            packed.extractall(destination)
    else:
        with tarfile.open(archive) as packed:
            members = packed.getmembers()
            for member in members:
                if not (root / member.name).resolve().is_relative_to(root):
                    fail(f"unsafe path in {archive.name}: {member.name}")
            packed.extractall(destination, filter="data")


def download_naive(target: str) -> Path:
    spec = MANIFEST["runtimes"]["naiveproxy"]
    artifact = spec["artifacts"].get(target)
    if artifact is None:
        fail(f"naiveproxy has no pinned archive for {target}")
    archive = OUT / "downloads" / artifact["name"]
    archive.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/klzgrad/naiveproxy/releases/download/{spec['version']}/{artifact['name']}"
    if not archive.exists() or sha256(archive) != artifact["sha256"]:
        temporary = archive.with_suffix(archive.suffix + ".part")
        temporary.unlink(missing_ok=True)
        urllib.request.urlretrieve(url, temporary)
        actual = sha256(temporary)
        if actual != artifact["sha256"]:
            temporary.unlink(missing_ok=True)
            fail(f"naiveproxy archive digest mismatch for {target}: expected {artifact['sha256']}, got {actual}")
        temporary.replace(archive)
    actual = sha256(archive)
    if actual != artifact["sha256"]:
        fail(f"naiveproxy archive digest mismatch for {target}: expected {artifact['sha256']}, got {actual}")
    unpacked = OUT / "unpacked" / target / "naiveproxy"
    shutil.rmtree(unpacked, ignore_errors=True)
    safe_extract(archive, unpacked)
    candidates = list(unpacked.rglob(f"naive{suffix(target)}"))
    if len(candidates) != 1:
        fail(f"naiveproxy archive for {target} has no unique executable")
    return candidates[0]


def copy_executable(source_path: Path, destination: Path) -> None:
    if not source_path.is_file():
        fail(f"required runtime artifact is missing: {source_path}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_path, destination)
    if os.name != "nt":
        destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def go_build(output: Path, package: str, cwd: Path, ldflags: str,
             tags: str | None = None) -> None:
    environment = dict(os.environ, CGO_ENABLED="0")
    command = ["go", "build", "-trimpath", f"-ldflags={ldflags}"]
    if tags:
        command.append(f"-tags={tags}")
    command.extend(("-o", str(output), package))
    run(*command, cwd=cwd, env=environment)


def build(target: str) -> dict[str, dict[str, str]]:
    target_spec(target, require_native=True)
    verify_shared_pins()
    go_version = run("go", "version").stdout
    if MANIFEST["go"] not in go_version:
        fail(f"runtime artifacts require {MANIFEST['go']}; found {go_version.strip()}")
    root = install_root(target)
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)

    go_build(installed_path("mihomo", target), ".", PROJECT / "core",
             f"-s -w -X github.com/metacubex/mihomo/constant.Version={MANIFEST['runtimes']['mihomo']['version']}",
             tags="with_gvisor,cmfa")
    copy_executable(download_naive(target), installed_path("naiveproxy", target))

    olcrtc = source("olcrtc")
    go_build(installed_path("olcrtc", target), "./cmd/olcrtc", olcrtc,
             "-s -w -checklinkname=0")

    byedpi = source("byedpi")
    run("make", "clean", cwd=byedpi)
    run("make", "windows" if target.startswith("windows-") else "-j2", cwd=byedpi)
    copy_executable(byedpi / f"ciadpi{suffix(target)}", installed_path("byedpi", target))

    stormdns = source("stormdns")
    go_build(installed_path("stormdns", target), "./cmd/client", stormdns, "-s -w")

    # Go outputs are executable already, but normalize every POSIX artifact.
    if os.name != "nt":
        for name in RUNTIME_NAMES:
            path = installed_path(name, target)
            path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    inventory = write_inventory(target)
    return {entry["name"]: {"path": entry["path"], "sha256": entry["sha256"]}
            for entry in inventory["artifacts"]}


def wait_for_port(port: int, process: subprocess.Popen[str], label: str) -> None:
    for _ in range(50):
        if process.poll() is not None:
            output = process.communicate()[0]
            fail(f"{label} stopped before listening: {output}")
        with socket.socket() as client:
            if client.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    fail(f"{label} did not open 127.0.0.1:{port}")


def invoke_and_stop(command: list[str], port: int, cwd: Path, label: str) -> str:
    process = subprocess.Popen(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    try:
        wait_for_port(port, process, label)
        return "listener opened; process terminated cleanly by the harness"
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def invoke_to_exit(command: list[str], label: str) -> str:
    result = run(*command, check=False, timeout=15)
    if result.returncode < 0:
        fail(f"{label} terminated by signal {-result.returncode}: {result.stdout}")
    return f"process launched and exited with code {result.returncode}"


def smoke(target: str) -> dict[str, dict[str, str]]:
    target_spec(target, require_native=True)
    verify_inventory(target)
    bins = {name: installed_path(name, target) for name in RUNTIME_NAMES}
    work = OUT / "smoke" / target
    work.mkdir(parents=True, exist_ok=True)
    results: dict[str, dict[str, str]] = {}
    results["mihomo"] = {"sha256": sha256(bins["mihomo"]), "smoke":
                          invoke_to_exit([str(bins["mihomo"])], "mihomo")}
    results["naiveproxy"] = {"sha256": sha256(bins["naiveproxy"]), "smoke": invoke_and_stop(
        [str(bins["naiveproxy"]), "--listen=socks://127.0.0.1:17891", "--proxy=socks://127.0.0.1:9"],
        17891, work, "naiveproxy")}
    results["byedpi"] = {"sha256": sha256(bins["byedpi"]), "smoke": invoke_and_stop(
        [str(bins["byedpi"]), "--ip", "127.0.0.1", "--port", "17892"],
        17892, work, "byedpi")}

    olc_test = run("go", "test", "-count=1", "-timeout=90s", "./internal/e2e", "-run",
                   "^TestClientServerSOCKSTunnelOverMemoryDatachannel$",
                   cwd=OUT / "sources" / "olcrtc", check=False)
    if olc_test.returncode != 0:
        fail(f"olcrtc in-memory SOCKS proof failed: {olc_test.stdout}")
    invoke_to_exit([str(bins["olcrtc"]), "--help"], "olcrtc")
    results["olcrtc"] = {"sha256": sha256(bins["olcrtc"]), "smoke":
                          "process launch/exit and upstream in-memory SOCKS transfer passed; no Internet e2e claimed"}

    storm_test = run("go", "test", "-count=1", "-timeout=90s", "./internal/client", "-run",
                     "^TestStartAsyncRuntimeCollectsResolverTimeoutsEvenWhenHealthFeaturesDisabled$",
                     cwd=OUT / "sources" / "stormdns", check=False)
    if storm_test.returncode != 0:
        fail(f"stormdns loopback listener proof failed: {storm_test.stdout}")
    invoke_to_exit([str(bins["stormdns"]), "--version"], "stormdns")
    results["stormdns"] = {"sha256": sha256(bins["stormdns"]), "smoke":
                            "process launch/exit and upstream loopback startup/cleanup passed; no Internet e2e claimed"}
    return results


def binary_architecture(path: Path, target: str) -> str:
    data = path.read_bytes()[:4096]
    if target.startswith("linux-"):
        if data[:4] != b"\x7fELF":
            fail(f"wrong binary format for {path}: expected ELF")
        machine = struct.unpack("<H" if data[5] == 1 else ">H", data[18:20])[0]
        return {62: "x86_64", 183: "arm64"}.get(machine, f"unknown-{machine}")
    if target.startswith("windows-"):
        if data[:2] != b"MZ":
            fail(f"wrong binary format for {path}: expected PE")
        offset = struct.unpack("<I", data[60:64])[0]
        if data[offset:offset + 4] != b"PE\0\0":
            fail(f"invalid PE header for {path}")
        machine = struct.unpack("<H", data[offset + 4:offset + 6])[0]
        return {0x8664: "x86_64", 0xAA64: "arm64"}.get(machine, f"unknown-{machine}")
    magic = data[:4]
    expected = MANIFEST["targets"][target]["architecture"]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        count = struct.unpack(">I", data[4:8])[0]
        record_size = 32 if magic == b"\xca\xfe\xba\xbf" else 20
        architectures = set()
        for index in range(count):
            offset = 8 + index * record_size
            cpu = struct.unpack(">I", data[offset:offset + 4])[0]
            architecture = {0x01000007: "x86_64", 0x0100000C: "arm64"}.get(cpu)
            if architecture:
                architectures.add(architecture)
        return expected if expected in architectures else "fat-without-required-architecture"
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        fail(f"wrong binary format for {path}: expected thin 64-bit Mach-O")
    byte_order = "<" if magic == b"\xcf\xfa\xed\xfe" else ">"
    cpu = struct.unpack(f"{byte_order}I", data[4:8])[0]
    return {0x01000007: "x86_64", 0x0100000C: "arm64"}.get(cpu, f"unknown-{cpu}")


def inventory_path(target: str) -> Path:
    return install_root(target) / "runtime-inventory.json"


def write_inventory(target: str) -> dict[str, object]:
    spec = MANIFEST["targets"][target]
    artifacts = []
    for name in RUNTIME_NAMES:
        path = installed_path(name, target)
        if not path.is_file():
            fail(f"required runtime artifact is missing: {path}")
        architecture = binary_architecture(path, target)
        if architecture != spec["architecture"]:
            fail(f"wrong architecture for {path}: expected {spec['architecture']}, got {architecture}")
        artifacts.append({"name": name, "path": path.name, "sha256": sha256(path),
                          "size": path.stat().st_size, "architecture": architecture})
    inventory: dict[str, object] = {"schema": 1, "target": target, "os": spec["os"],
                                    "architecture": spec["architecture"], "artifacts": artifacts}
    inventory_path(target).write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
    return inventory


def verify_inventory(target: str) -> dict[str, object]:
    target_spec(target)
    path = inventory_path(target)
    if not path.is_file():
        fail(f"runtime inventory is missing for {target}: {path}")
    inventory = json.loads(path.read_text())
    spec = MANIFEST["targets"][target]
    if (inventory.get("schema"), inventory.get("target"), inventory.get("os"), inventory.get("architecture")) != (
            1, target, spec["os"], spec["architecture"]):
        fail(f"runtime inventory metadata does not match {target}")
    entries = inventory.get("artifacts")
    if not isinstance(entries, list) or [entry.get("name") for entry in entries] != list(RUNTIME_NAMES):
        fail(f"runtime inventory for {target} must contain exactly: {', '.join(RUNTIME_NAMES)}")
    for entry in entries:
        artifact = installed_path(entry["name"], target)
        if entry.get("path") != artifact.name or not artifact.is_file():
            fail(f"required runtime artifact is missing: {artifact}")
        if entry.get("size") != artifact.stat().st_size:
            fail(f"runtime artifact size mismatch: {artifact}")
        actual = sha256(artifact)
        if entry.get("sha256") != actual:
            fail(f"runtime artifact digest mismatch for {artifact}: expected {entry.get('sha256')}, got {actual}")
        architecture = binary_architecture(artifact, target)
        if entry.get("architecture") != architecture or architecture != spec["architecture"]:
            fail(f"wrong architecture for {artifact}: expected {spec['architecture']}, got {architecture}")
        if os.name != "nt" and artifact.stat().st_mode & 0o111 == 0:
            fail(f"runtime artifact is not executable: {artifact}")
    return inventory


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("build", "smoke", "verify"))
    parser.add_argument("--target", default=target_default())
    args = parser.parse_args()
    if args.action == "build":
        result = build(args.target)
    elif args.action == "smoke":
        result = smoke(args.target)
    else:
        result = verify_inventory(args.target)
    report_path = OUT / "runtime-report.json"
    previous = json.loads(report_path.read_text()) if report_path.exists() else {}
    previous.update({"schema": 2, "target": args.target, args.action: result})
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(previous, indent=2, sort_keys=True) + "\n")
    print(report_path)


if __name__ == "__main__":
    main()
