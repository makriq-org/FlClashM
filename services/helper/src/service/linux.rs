//! Linux-only privileged boundary.  The GUI never receives a shell and this
//! process never accepts an executable name, a path, or an argument vector.
//!
//! The wire format deliberately mirrors `DesktopHelperProtocol` in Dart: one
//! JSON request and one JSON response per Unix stream connection.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::Command;

const APPLICATION_ID: &str = "app.flclashm.client";
const PROTOCOL_VERSION: u8 = 1;
const SOCKET_PATH: &str = "/run/flclashm/helper.sock";
const STATE_PATH: &str = "/run/flclashm/transaction.json";
const APPIMAGE_PEER_UID_PATH: &str = "/run/flclashm/appimage-peer-uid";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    protocol_version: u8,
    install_identity: String,
    operation: String,
    #[serde(default)]
    runtime_artifact: Option<String>,
    #[serde(default)]
    parameters: BTreeMap<String, Value>,
}

#[derive(Debug, Serialize)]
struct Response<'a> {
    state: &'a str,
    message: String,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct Transaction {
    interface: Option<String>,
    routes: Vec<String>,
    dns_interface: Option<String>,
}

pub fn main() -> Result<()> {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
        Some("--self-test") => self_test(),
        Some("--rollback") => rollback(),
        Some("--bootstrap") => bootstrap(),
        Some("--socket") => serve(arguments.next().context("missing socket path")?.as_str()),
        Some("--request") => request_client(arguments.next().as_deref().unwrap_or(SOCKET_PATH)),
        None => serve(SOCKET_PATH),
        _ => bail!("unsupported Linux helper mode"),
    }
}

fn self_test() -> Result<()> {
    // This is intentionally unprivileged: CI uses it to prove schema and peer
    // authentication without pretending that a network namespace e2e ran.
    validate(&Request {
        protocol_version: PROTOCOL_VERSION,
        install_identity: APPLICATION_ID.into(),
        operation: "routeApply".into(),
        runtime_artifact: None,
        parameters: BTreeMap::from([
            ("interface".into(), Value::String("flclashm0".into())),
            ("routes".into(), serde_json::json!(["10.0.0.0/8"])),
        ]),
    })?;
    Ok(())
}

fn serve(socket_path: &str) -> Result<()> {
    let socket = Path::new(socket_path);
    if let Some(parent) = socket.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
        configure_parent(parent)?;
    }
    if socket.exists() {
        fs::remove_file(socket).with_context(|| format!("remove stale {}", socket.display()))?;
    }
    let listener =
        UnixListener::bind(socket).with_context(|| format!("bind {}", socket.display()))?;
    configure_socket(socket)?;
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle(stream) {
                    eprintln!("rejected Linux helper request: {error:#}");
                }
            }
            Err(error) => eprintln!("Linux helper socket error: {error}"),
        }
    }
    Ok(())
}

fn configure_parent(path: &Path) -> Result<()> {
    // Package-managed installations must not grant every desktop user access
    // merely because a package-owned group exists.  The service socket stays
    // root-only and package clients enter through the polkit-approved helper.
    fs::set_permissions(path, fs::Permissions::from_mode(0o711))?;
    Ok(())
}

fn configure_socket(path: &Path) -> Result<()> {
    // AppImage has no package-owned service. pkexec supplies the one user
    // which authorized bootstrap; persist that UID and accept no other user.
    // A package service has no PKEXEC_UID, so its socket is root-only.
    let appimage_uid = std::env::var("PKEXEC_UID")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|uid| *uid != 0);
    if let Some(uid) = appimage_uid {
        let entry = unsafe { libc::getpwuid(uid) };
        if entry.is_null() {
            bail!("cannot resolve AppImage helper client");
        }
        fs::write(APPIMAGE_PEER_UID_PATH, uid.to_string())?;
        fs::set_permissions(APPIMAGE_PEER_UID_PATH, fs::Permissions::from_mode(0o600))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        return chown(path, uid, unsafe { (*entry).pw_gid });
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let _ = fs::remove_file(APPIMAGE_PEER_UID_PATH);
    Ok(())
}

fn chown(path: &Path, uid: u32, gid: libc::gid_t) -> Result<()> {
    let encoded_path = CString::new(path.as_os_str().as_encoded_bytes())?;
    if unsafe { libc::chown(encoded_path.as_ptr(), uid, gid) } != 0 {
        bail!("cannot assign flclashm group");
    }
    Ok(())
}

fn bootstrap() -> Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        bail!("bootstrap requires pkexec");
    }
    match unsafe { libc::fork() } {
        -1 => bail!("cannot fork helper daemon"),
        0 => {
            unsafe {
                libc::setsid();
            }
            // Do not retain Process.run pipes in the daemon: pkexec waits for
            // EOF and otherwise hangs until the helper exits.
            let null = CString::new("/dev/null")?;
            let descriptor = unsafe { libc::open(null.as_ptr(), libc::O_RDWR) };
            if descriptor < 0 {
                bail!("cannot redirect helper stdio");
            }
            for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
                if unsafe { libc::dup2(descriptor, target) } < 0 {
                    bail!("cannot redirect helper stdio");
                }
            }
            if descriptor > libc::STDERR_FILENO {
                unsafe { libc::close(descriptor) };
            }
            serve(SOCKET_PATH)
        }
        _ => Ok(()),
    }
}

fn handle(mut stream: UnixStream) -> Result<()> {
    verify_peer(&stream)?;
    let mut line = String::new();
    BufReader::new(stream.try_clone()?).read_line(&mut line)?;
    if line.len() > 16 * 1024 {
        bail!("request is too large");
    }
    let response = match serde_json::from_str::<Request>(&line)
        .map_err(anyhow::Error::from)
        .and_then(|request| validate(&request).map(|_| request))
    {
        Ok(request) => execute(request),
        Err(error) => Response {
            state: "failed",
            message: error.to_string(),
        },
    };
    writeln!(stream, "{}", serde_json::to_string(&response)?)?;
    Ok(())
}

fn request_client(socket_path: &str) -> Result<()> {
    let mut request = String::new();
    std::io::stdin().read_line(&mut request)?;
    if request.len() > 16 * 1024 {
        bail!("request is too large");
    }
    let mut stream =
        UnixStream::connect(socket_path).with_context(|| format!("connect {socket_path}"))?;
    stream.write_all(request.as_bytes())?;
    if !request.ends_with('\n') {
        stream.write_all(b"\n")?;
    }
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response)?;
    print!("{response}");
    Ok(())
}

fn verify_peer(stream: &UnixStream) -> Result<()> {
    let mut credential: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credential as *mut _ as *mut libc::c_void,
            &mut length,
        )
    };
    if result != 0 || length as usize != std::mem::size_of::<libc::ucred>() {
        bail!("cannot verify Unix socket peer credentials");
    }
    if credential.uid == 0 {
        // Package installations use a new pkexec-authenticated request client
        // for each operation.  Root is valid only after polkit has approved
        // that client; direct desktop users cannot open the 0600 socket.
        return Ok(());
    }
    let allowed_uid = fs::read_to_string(APPIMAGE_PEER_UID_PATH)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .context("helper does not have an authorized desktop peer")?;
    if credential.uid != allowed_uid {
        bail!("unexpected Linux helper peer UID");
    }
    Ok(())
}

fn execute(request: Request) -> Response<'static> {
    let result = match request.operation.as_str() {
        "tunOpen" => tun_open(&request),
        "tunClose" => rollback(),
        "routeApply" => route_apply(&request),
        "routeRollback" => rollback(),
        "dnsApply" => dns_apply(&request),
        "dnsRollback" => rollback_dns(),
        // Runtime processes are deliberately owned by the unprivileged Dart
        // supervisor.  The helper acknowledges only bundled artifact names.
        "runtimeStart" | "runtimeStop" => Ok(()),
        _ => Err(anyhow::anyhow!("unsupported operation")),
    };
    match result {
        Ok(()) => Response {
            state: "ready",
            message: String::new(),
        },
        Err(error) => {
            let _ = rollback();
            Response {
                state: "failed",
                message: error.to_string(),
            }
        }
    }
}

fn validate(request: &Request) -> Result<()> {
    if request.protocol_version != PROTOCOL_VERSION {
        bail!("unsupported protocol version");
    }
    if request.install_identity != APPLICATION_ID {
        bail!("unexpected install identity");
    }
    let required: &[&str] = match request.operation.as_str() {
        "tunOpen" => &["interface", "mtu"],
        "tunClose" => &["interface"],
        "routeApply" => &["interface", "routes"],
        "routeRollback" => &["transaction"],
        "dnsApply" => &["interface", "servers"],
        "dnsRollback" => &["transaction"],
        "runtimeStart" | "runtimeStop" => &["runtimeToken"],
        _ => bail!("unknown operation"),
    };
    if request.parameters.len() != required.len()
        || required
            .iter()
            .any(|key| !request.parameters.contains_key(*key))
    {
        bail!("invalid parameter schema");
    }
    let runtime = matches!(request.operation.as_str(), "runtimeStart" | "runtimeStop");
    if runtime != request.runtime_artifact.is_some() {
        bail!("invalid runtime artifact");
    }
    if let Some(artifact) = &request.runtime_artifact {
        if !["mihomo", "naiveproxy", "olcrtc", "byedpi", "stormdns"].contains(&artifact.as_str()) {
            bail!("runtime artifact is not bundled");
        }
    }
    match request.operation.as_str() {
        "tunOpen" => {
            interface(request)?;
            if request.parameters["mtu"]
                .as_u64()
                .filter(|mtu| (576..=65535).contains(mtu))
                .is_none()
            {
                bail!("invalid MTU");
            }
        }
        "tunClose" => {
            interface(request)?;
        }
        "routeApply" => {
            interface(request)?;
            routes(request)?;
        }
        "dnsApply" => {
            interface(request)?;
            servers(request)?;
        }
        "routeRollback" | "dnsRollback" => transaction(request)?,
        _ => {
            if !token(request) {
                bail!("invalid runtime token");
            }
        }
    }
    Ok(())
}

fn interface(request: &Request) -> Result<&str> {
    let value = request.parameters["interface"]
        .as_str()
        .context("invalid interface")?;
    if value.len() > 64
        || !value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.') && index > 0
        })
    {
        bail!("invalid interface");
    }
    Ok(value)
}

fn routes(request: &Request) -> Result<Vec<&str>> {
    let values = request.parameters["routes"]
        .as_array()
        .context("invalid routes")?;
    if values.is_empty() || values.len() > 128 {
        bail!("invalid routes");
    }
    values
        .iter()
        .map(|value| {
            let route = value.as_str().context("invalid route")?;
            if route == "0.0.0.0/0" || route == "::/0" || !route.contains('/') || route.len() > 64 {
                bail!("default or malformed route");
            }
            Ok(route)
        })
        .collect()
}

fn servers(request: &Request) -> Result<Vec<&str>> {
    let values = request.parameters["servers"]
        .as_array()
        .context("invalid servers")?;
    if values.is_empty() || values.len() > 16 {
        bail!("invalid DNS servers");
    }
    values
        .iter()
        .map(|value| {
            let address = value.as_str().context("invalid DNS server")?;
            if address.parse::<std::net::IpAddr>().is_err() {
                bail!("invalid DNS server");
            }
            Ok(address)
        })
        .collect()
}

fn transaction(request: &Request) -> Result<()> {
    let value = request.parameters["transaction"]
        .as_str()
        .context("invalid transaction")?;
    if value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        bail!("invalid transaction");
    }
    Ok(())
}

fn token(request: &Request) -> bool {
    request.parameters["runtimeToken"]
        .as_str()
        .is_some_and(|token| {
            token.len() >= 16
                && token.len() <= 128
                && token
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
        })
}

fn command(program: &str, arguments: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(arguments)
        .status()
        .with_context(|| format!("run {program}"))?;
    if !status.success() {
        bail!("{program} failed with {status}");
    }
    Ok(())
}

fn read_state() -> Transaction {
    fs::read_to_string(STATE_PATH)
        .ok()
        .and_then(|value| serde_json::from_str(&value).ok())
        .unwrap_or_default()
}

fn write_state(state: &Transaction) -> Result<()> {
    let temporary = format!("{STATE_PATH}.tmp");
    fs::write(&temporary, serde_json::to_vec(state)?)?;
    fs::rename(temporary, STATE_PATH)?;
    Ok(())
}

fn tun_open(request: &Request) -> Result<()> {
    let interface = interface(request)?;
    command(
        "/usr/sbin/ip",
        &["tuntap", "add", "dev", interface, "mode", "tun"],
    )?;
    if let Err(error) = command(
        "/usr/sbin/ip",
        &[
            "link",
            "set",
            "dev",
            interface,
            "up",
            "mtu",
            request.parameters["mtu"]
                .as_u64()
                .unwrap()
                .to_string()
                .as_str(),
        ],
    ) {
        let _ = command("/usr/sbin/ip", &["link", "delete", "dev", interface]);
        return Err(error);
    }
    write_state(&Transaction {
        interface: Some(interface.into()),
        ..read_state()
    })
}

fn route_apply(request: &Request) -> Result<()> {
    let interface = interface(request)?;
    let routes = routes(request)?;
    let mut state = read_state();
    state.interface = Some(interface.into());
    for route in &routes {
        // `replace` overwrites an unrelated route and cannot reconstruct all
        // route attributes reliably. `add` leaves an existing route intact;
        // every successfully added route is journalled before the next step.
        command(
            "/usr/sbin/ip",
            &["route", "add", route, "dev", interface],
        )?;
        state.routes.push((*route).into());
        if let Err(error) = write_state(&state) {
            let _ = command("/usr/sbin/ip", &["route", "del", route, "dev", interface]);
            return Err(error);
        }
    }
    Ok(())
}

fn dns_apply(request: &Request) -> Result<()> {
    let interface = interface(request)?;
    let servers = servers(request)?;
    // systemd-resolved owns transient interface DNS and provides `revert`.
    // Without it we fail closed rather than editing resolv.conf or a persistent
    // NetworkManager profile.
    command(
        "/usr/bin/resolvectl",
        &["dns", interface, &servers.join(" ")],
    )?;
    write_state(&Transaction {
        dns_interface: Some(interface.into()),
        ..read_state()
    })
}

fn rollback_dns() -> Result<()> {
    let state = read_state();
    if let Some(interface) = state.dns_interface {
        command("/usr/bin/resolvectl", &["revert", &interface])?;
    }
    Ok(())
}

fn rollback() -> Result<()> {
    let state = read_state();
    if let Some(interface) = &state.dns_interface {
        let _ = command("/usr/bin/resolvectl", &["revert", interface]);
    }
    for route in &state.routes {
        if let Some(interface) = &state.interface {
            let _ = command("/usr/sbin/ip", &["route", "del", route, "dev", interface]);
        }
    }
    if let Some(interface) = &state.interface {
        let _ = command("/usr/sbin/ip", &["link", "delete", "dev", interface]);
    }
    let _ = fs::remove_file(STATE_PATH);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(operation: &str, parameters: BTreeMap<String, Value>) -> Request {
        Request {
            protocol_version: PROTOCOL_VERSION,
            install_identity: APPLICATION_ID.into(),
            operation: operation.into(),
            runtime_artifact: None,
            parameters,
        }
    }

    #[test]
    fn rejects_default_routes_and_path_like_parameters() {
        let default_route = request(
            "routeApply",
            BTreeMap::from([
                ("interface".into(), Value::String("flclashm0".into())),
                ("routes".into(), serde_json::json!(["0.0.0.0/0"])),
            ]),
        );
        assert!(validate(&default_route).is_err());
        let path = request(
            "tunOpen",
            BTreeMap::from([
                ("interface".into(), Value::String("flclashm0".into())),
                ("path".into(), Value::String("/bin/sh".into())),
            ]),
        );
        assert!(validate(&path).is_err());
    }
}
