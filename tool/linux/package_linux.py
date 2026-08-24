#!/usr/bin/env python3
"""Create self-contained Linux x64 packages from an already verified bundle.

This script deliberately does no download and never replaces a package-managed
installation.  The AppImage is the only artifact eligible for in-app update.
"""
from __future__ import annotations

import argparse
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "app.flclashm.client"


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def copy_bundle(bundle: Path, destination: Path) -> None:
    if not (bundle / "FlClashM").is_file():
        raise SystemExit(f"missing Linux bundle: {bundle}")
    shutil.copytree(bundle, destination, symlinks=True)
    required = ["mihomo", "naiveproxy", "olcrtc", "byedpi", "stormdns", f"{IDENTITY}.helper"]
    runtime = destination / "runtimes" / "linux" / "x86_64"
    for name in required:
        path = runtime / name
        if not path.is_file() or not (path.stat().st_mode & stat.S_IXUSR):
            raise SystemExit(f"missing executable runtime artifact: {path}")


def stage_common(bundle: Path, root: Path) -> None:
    app = root / "usr" / "lib" / IDENTITY
    copy_bundle(bundle, app)
    libexec = root / "usr" / "libexec"
    libexec.mkdir(parents=True)
    shutil.copy2(app / "runtimes" / "linux" / "x86_64" / f"{IDENTITY}.helper", libexec / "flclashm-helper")
    (root / "usr" / "share" / "applications").mkdir(parents=True)
    (root / "usr" / "share" / "metainfo").mkdir(parents=True)
    (root / "usr" / "share" / "polkit-1" / "actions").mkdir(parents=True)
    (root / "usr" / "lib" / "systemd" / "system").mkdir(parents=True)
    (root / "usr" / "lib" / "tmpfiles.d").mkdir(parents=True)
    (root / "usr" / "lib" / "sysusers.d").mkdir(parents=True)
    shutil.copy2(ROOT / "linux" / "packaging" / "app.flclashm.client.desktop", root / "usr" / "share" / "applications" / f"{IDENTITY}.desktop")
    shutil.copy2(ROOT / "linux" / "packaging" / "app.flclashm.client.metainfo.xml", root / "usr" / "share" / "metainfo" / f"{IDENTITY}.metainfo.xml")
    shutil.copy2(ROOT / "linux" / "packaging" / "systemd" / "flclashm-helper.service", root / "usr" / "lib" / "systemd" / "system" / "flclashm-helper.service")
    shutil.copy2(ROOT / "linux" / "packaging" / "systemd" / "flclashm.conf", root / "usr" / "lib" / "tmpfiles.d" / "flclashm.conf")
    shutil.copy2(ROOT / "linux" / "packaging" / "systemd" / "flclashm.conf.sysusers", root / "usr" / "lib" / "sysusers.d" / "flclashm.conf")
    shutil.copy2(ROOT / "linux" / "packaging" / "polkit" / "app.flclashm.client.helper.policy", root / "usr" / "share" / "polkit-1" / "actions" / "app.flclashm.client.helper.policy")


def deb(bundle: Path, output: Path, version: str) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / IDENTITY
        stage_common(bundle, root)
        control = root / "DEBIAN"
        control.mkdir()
        (control / "control").write_text(
            f"Package: {IDENTITY}\nVersion: {version}\nArchitecture: amd64\nMaintainer: makriq-org\nDescription: FlClashM mihomo client\n")
        (control / "postinst").write_text("#!/bin/sh\nset -e\nsystemctl daemon-reload || true\nsystemctl enable --now flclashm-helper.service || true\n")
        (control / "prerm").write_text("#!/bin/sh\nset -e\nsystemctl stop flclashm-helper.service || true\n")
        for script in [control / "postinst", control / "prerm"]: script.chmod(0o755)
        run("dpkg-deb", "--build", "--root-owner-group", str(root), str(output))


def appimage(bundle: Path, output: Path) -> None:
    tool = shutil.which("appimagetool")
    if tool is None:
        raise SystemExit("appimagetool is required to build the AppImage")
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "AppDir"
        usr = root / "usr" / "lib" / IDENTITY
        copy_bundle(bundle, usr)
        shutil.copy2(ROOT / "linux" / "packaging" / "app.flclashm.client.desktop", root / f"{IDENTITY}.desktop")
        icon = ROOT / "assets" / "images" / "icon.png"
        shutil.copy2(icon, root / f"{IDENTITY}.png")
        (root / "AppRun").symlink_to(Path("usr/lib") / IDENTITY / "FlClashM")
        run(tool, str(root), str(output))


def rpm(bundle: Path, output: Path, version: str) -> None:
    if shutil.which("rpmbuild") is None:
        raise SystemExit("rpmbuild is required to build the RPM")
    with tempfile.TemporaryDirectory() as temporary:
        top = Path(temporary) / "rpmbuild"
        for directory in ["BUILD", "BUILDROOT", "RPMS/x86_64", "SOURCES", "SPECS", "SRPMS"]: (top / directory).mkdir(parents=True)
        stage = top / "stage"
        stage_common(bundle, stage)
        spec = top / "SPECS" / f"{IDENTITY}.spec"
        rpm_version, separator, rpm_release = version.partition("-")
        rpm_version = rpm_version.split("+", 1)[0]
        rpm_release = (rpm_release if separator else "1").replace("+", ".")
        spec.write_text(f"""Name: {IDENTITY}
Version: {rpm_version}
Release: {rpm_release}
Summary: FlClashM mihomo client
License: Other
BuildArch: x86_64
%description
FlClashM mihomo client.
%install
mkdir -p %{{buildroot}}
cp -a {stage}/. %{{buildroot}}/
%post
systemctl daemon-reload || :
systemctl enable --now flclashm-helper.service || :
%preun
systemctl stop flclashm-helper.service || :
%files
/usr/lib/{IDENTITY}
/usr/libexec/flclashm-helper
/usr/share/applications/{IDENTITY}.desktop
/usr/share/metainfo/{IDENTITY}.metainfo.xml
/usr/share/polkit-1/actions/{IDENTITY}.helper.policy
/usr/lib/systemd/system/flclashm-helper.service
/usr/lib/tmpfiles.d/flclashm.conf
/usr/lib/sysusers.d/flclashm.conf
""")
        run("rpmbuild", "--define", f"_topdir {top}", "-bb", str(spec))
        built = next((top / "RPMS" / "x86_64").glob("*.rpm"))
        shutil.copy2(built, output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    deb(args.bundle, args.out / f"FlClashM-{args.version}-linux-x64.deb", args.version)
    rpm(args.bundle, args.out / f"FlClashM-{args.version}-linux-x64.rpm", args.version)
    appimage(args.bundle, args.out / "FlClashM-linux-x64.AppImage")


if __name__ == "__main__":
    main()
