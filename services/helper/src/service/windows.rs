//! Windows Service endpoint for the product helper protocol.
//!
//! The pipe ACL deliberately grants read/write access only to SYSTEM,
//! administrators and interactive logon sessions.  There is no loopback TCP
//! fallback: an unauthenticated local HTTP port is not a privilege boundary.

use super::windows_runtime::{self, Runtime};
use std::ffi::OsString;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use windows::core::w;
use windows::Win32::Foundation::{GetLastError, LocalFree, ERROR_PIPE_CONNECTED, HANDLE, HLOCAL};
use windows::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
};
use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows::Win32::Storage::FileSystem::{ReadFile, WriteFile, PIPE_ACCESS_DUPLEX};
use windows::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PeekNamedPipe, PIPE_NOWAIT,
    PIPE_READMODE_MESSAGE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE,
};
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher, Result,
};

pub const SERVICE_NAME: &str = "app.flclashm.client.helper";
const PIPE_NAME: windows::core::PCWSTR = w!(r"\\.\pipe\app.flclashm.client.helper.v1");
const PROTOCOL_VERSION: u8 = 1;
const INSTALL_IDENTITY: &str = "app.flclashm.client";
const MAX_MESSAGE: usize = 16 * 1024;

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    protocol_version: u8,
    install_identity: String,
    operation: Operation,
    #[serde(default)]
    runtime_artifact: Option<RuntimeArtifact>,
    parameters: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Operation {
    Ping,
    TunOpen,
    TunClose,
    RouteApply,
    RouteRollback,
    DnsApply,
    DnsRollback,
    RuntimeStart,
    RuntimeStop,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
enum RuntimeArtifact {
    Mihomo,
    Naiveproxy,
    Olcrtc,
    Byedpi,
    Stormdns,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response<'a> {
    state: &'a str,
    message: &'a str,
}

pub fn main() -> Result<()> {
    service_dispatcher::start(SERVICE_NAME, service_main)
}

define_windows_service!(service_main, ffi_service_main);

fn ffi_service_main(_arguments: Vec<OsString>) {
    if let Err(error) = run_windows_service() {
        eprintln!("Windows helper service failed: {error:#}");
    }
}

fn run_windows_service() -> anyhow::Result<()> {
    STOP_REQUESTED.store(false, Ordering::Release);
    let status_handle = service_control_handler::register(SERVICE_NAME, |event| match event {
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        ServiceControl::Stop | ServiceControl::Shutdown => {
            STOP_REQUESTED.store(true, Ordering::Release);

            ServiceControlHandlerResult::NoError
        }
        _ => ServiceControlHandlerResult::NotImplemented,
    })?;
    set_status(
        &status_handle,
        ServiceState::Running,
        ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
    )?;
    let result = serve_pipe();
    let _ = set_status(
        &status_handle,
        ServiceState::Stopped,
        ServiceControlAccept::empty(),
    );
    result
}

fn set_status(
    handle: &windows_service::service_control_handler::ServiceStatusHandle,
    state: ServiceState,
    accepted: ServiceControlAccept,
) -> Result<()> {
    handle.set_service_status(ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: state,
        controls_accepted: accepted,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })
}

fn serve_pipe() -> anyhow::Result<()> {
    let mut runtime: Option<Runtime> = None;
    while !STOP_REQUESTED.load(Ordering::Acquire) {
        let pipe = windows_runtime::OwnedHandle(create_pipe()?);
        loop {
            if STOP_REQUESTED.load(Ordering::Acquire) {
                return Ok(());
            }
            if let Some(active) = runtime.as_mut() {
                match active.reap() {
                    Ok(true) | Err(_) => {
                        runtime.take();
                    }
                    Ok(false) => {}
                }
            }
            let connected = unsafe { ConnectNamedPipe(pipe.0, None) }.is_ok()
                || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
            if connected {
                let _ = serve_client(pipe.0, &mut runtime);
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    Ok(())
}

fn create_pipe() -> anyhow::Result<HANDLE> {
    // Protected DACL: SYSTEM and Administrators fully control the endpoint;
    // Interactive users can only connect, read and write their own request.
    // Network, service and anonymous logons have no ACE.
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            w!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"),
            SDDL_REVISION_1,
            &mut descriptor,
            None,
        )?;
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0 as _,
        bInheritHandle: false.into(),
    };
    let result = unsafe {
        CreateNamedPipeW(
            PIPE_NAME,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            MAX_MESSAGE as u32,
            MAX_MESSAGE as u32,
            1000,
            Some(&attributes),
        )
    };
    let _ = unsafe { LocalFree(HLOCAL(descriptor.0 as _)) };
    anyhow::ensure!(
        !result.is_invalid(),
        "CreateNamedPipeW failed: {}",
        windows::core::Error::from_win32()
    );
    Ok(result)
}

fn serve_client(pipe: HANDLE, runtime: &mut Option<Runtime>) -> anyhow::Result<()> {
    let mut pid = 0;
    unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) }?;
    let authorization = windows_runtime::authenticate(pid);
    let response = match authorization {
        Err(_) => Response {
            state: "failed",
            message: "Client is not the installed FlClashM application.",
        },
        Ok(client) => {
            let deadline = Instant::now() + Duration::from_secs(3);
            let mut input = vec![0_u8; MAX_MESSAGE];
            let mut read = 0_u32;
            loop {
                anyhow::ensure!(
                    !STOP_REQUESTED.load(Ordering::Acquire) && Instant::now() < deadline,
                    "Client request timed out."
                );
                let mut available = 0;
                unsafe { PeekNamedPipe(pipe, None, 0, None, Some(&mut available), None) }?;
                anyhow::ensure!(
                    available as usize <= MAX_MESSAGE,
                    "Helper message is too large."
                );
                if available > 0 {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            unsafe { ReadFile(pipe, Some(input.as_mut_slice()), Some(&mut read), None) }?;
            match serde_json::from_slice::<Request>(&input[..read as usize]) {
                Ok(request) => {
                    let checked = validate(&request);
                    if checked.state != "ready" {
                        checked
                    } else {
                        match request.operation {
                            Operation::Ping => Response { state: "ready", message: "Windows helper is ready." },
                            Operation::RuntimeStart => {
                                if runtime.is_some() {
                                    Response { state: "failed", message: "A Windows TUN runtime is already owned by another session; stop it first." }
                                } else {
                                    let token = value_string(&request.parameters, "runtimeToken");
                                    let port = request.parameters["port"].as_u64().unwrap() as u16;
                                    match Runtime::start(client, token, port) {
                                        Ok(started) => { *runtime = Some(started); Response { state: "ready", message: "Installed mihomo started." } }
                                        Err(error) => { eprintln!("Runtime start failed: {error:#}"); Response { state: "failed", message: "Could not start installed mihomo; check or reinstall the Windows package." } }
                                    }
                                }
                            }
                            Operation::RuntimeStop => {
                                let token = value_string(&request.parameters, "runtimeToken");
                                if runtime.as_ref().is_some_and(|r| !r.owned_by(pid, token)) {
                                    Response { state: "failed", message: "Runtime lease belongs to another client." }
                                } else {
                                    let stopped = runtime.take().map(|mut r| r.stop()).transpose();
                                    if stopped.is_ok() { Response { state: "ready", message: "Mihomo stopped." } }
                                    else { Response { state: "failed", message: "Mihomo required forced shutdown after cleanup timed out." } }
                                }
                            }
                            _ => Response { state: "unavailable", message: "TUN, routes and DNS are managed only by the installed mihomo runtime." },
                        }
                    }
                }
                Err(_) => Response {
                    state: "failed",
                    message: "Malformed helper request.",
                },
            }
        }
    };
    let body = serde_json::to_vec(&response)?;
    let mut written = 0_u32;
    unsafe { WriteFile(pipe, Some(body.as_slice()), Some(&mut written), None) }?;
    anyhow::ensure!(
        written as usize == body.len(),
        "Incomplete helper response."
    );
    Ok(())
}

fn validate(request: &Request) -> Response<'static> {
    if request.protocol_version != PROTOCOL_VERSION || request.install_identity != INSTALL_IDENTITY
    {
        return Response {
            state: "failed",
            message: "Unexpected helper protocol or install identity.",
        };
    }
    let expected = match request.operation {
        Operation::Ping => &[][..],
        Operation::TunOpen => &["interface", "mtu"][..],
        Operation::TunClose => &["interface"][..],
        Operation::RouteApply => &["interface", "routes"][..],
        Operation::RouteRollback | Operation::DnsRollback => &["transaction"][..],
        Operation::DnsApply => &["interface", "servers"][..],
        Operation::RuntimeStart => &["runtimeToken", "port"][..],
        Operation::RuntimeStop => &["runtimeToken"][..],
    };
    let runtime = matches!(
        request.operation,
        Operation::RuntimeStart | Operation::RuntimeStop
    );
    if runtime && !matches!(request.runtime_artifact, Some(RuntimeArtifact::Mihomo))
        || runtime != request.runtime_artifact.is_some()
        || request.parameters.len() != expected.len()
        || expected
            .iter()
            .any(|key| !request.parameters.contains_key(*key))
        || !valid_parameters(&request.operation, &request.parameters)
    {
        return Response {
            state: "failed",
            message: "Invalid helper command schema.",
        };
    }
    // This is intentionally the whole dispatch table.  Operations that need
    // system state are implemented by the service from installed artifacts and
    // validated values only; client paths, command lines and environment are
    // absent from both the wire format and this process.
    Response {
        state: "ready",
        message: "Accepted fixed helper operation.",
    }
}

fn valid_parameters(
    operation: &Operation,
    parameters: &serde_json::Map<String, serde_json::Value>,
) -> bool {
    match operation {
        Operation::Ping => true,
        Operation::TunOpen => {
            valid_interface(value_string(parameters, "interface"))
                && parameters
                    .get("mtu")
                    .and_then(serde_json::Value::as_u64)
                    .is_some_and(|mtu| (576..=65535).contains(&mtu))
        }
        Operation::TunClose => valid_interface(value_string(parameters, "interface")),
        Operation::RouteApply => {
            valid_interface(value_string(parameters, "interface"))
                && valid_string_list(parameters.get("routes"), 128, valid_cidr)
        }
        Operation::RouteRollback | Operation::DnsRollback => {
            valid_token(value_string(parameters, "transaction"), 1)
        }
        Operation::DnsApply => {
            valid_interface(value_string(parameters, "interface"))
                && valid_string_list(parameters.get("servers"), 16, |value| {
                    value.parse::<IpAddr>().is_ok()
                })
        }
        Operation::RuntimeStart => {
            valid_control_token(value_string(parameters, "runtimeToken"))
                && parameters
                    .get("port")
                    .and_then(serde_json::Value::as_u64)
                    .is_some_and(|port| (1..=65535).contains(&port))
        }
        Operation::RuntimeStop => valid_control_token(value_string(parameters, "runtimeToken")),
    }
}

fn value_string<'a>(
    parameters: &'a serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> &'a str {
    parameters
        .get(key)
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
}

fn valid_interface(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first.is_ascii_alphabetic())
        && value.len() <= 64
        && chars.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '_' | '.' | '-')
        })
}

fn valid_token(value: &str, minimum: usize) -> bool {
    (minimum..=128).contains(&value.len())
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
}

fn valid_string_list(
    value: Option<&serde_json::Value>,
    maximum: usize,
    predicate: impl Fn(&str) -> bool,
) -> bool {
    let Some(values) = value.and_then(serde_json::Value::as_array) else {
        return false;
    };
    !values.is_empty()
        && values.len() <= maximum
        && values
            .iter()
            .all(|item| item.as_str().is_some_and(|item| predicate(item)))
}

fn valid_cidr(value: &str) -> bool {
    let Some((address, prefix)) = value.split_once('/') else {
        return false;
    };
    let Ok(address) = address.parse::<IpAddr>() else {
        return false;
    };
    let Ok(prefix) = prefix.parse::<u8>() else {
        return false;
    };
    prefix <= if address.is_ipv4() { 32 } else { 128 }
}

fn valid_control_token(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn runtime_schema_is_closed() {
        let token = "a".repeat(64);
        let body = serde_json::json!({"protocolVersion":1,"installIdentity":INSTALL_IDENTITY,
            "operation":"runtimeStart","runtimeArtifact":"mihomo","parameters":{"runtimeToken":token,"port":49152}});
        let request: Request = serde_json::from_value(body.clone()).unwrap();
        assert_eq!(validate(&request).state, "ready");
        for parameters in [
            serde_json::json!({"runtimeToken":"short","port":49152}),
            serde_json::json!({"runtimeToken":token,"port":0}),
            serde_json::json!({"runtimeToken":token,"port":49152,"path":"evil.exe"}),
        ] {
            let mut changed = body.clone();
            changed["parameters"] = parameters;
            assert_eq!(
                validate(&serde_json::from_value(changed).unwrap()).state,
                "failed"
            );
        }
        let mut changed = body;
        changed["runtimeArtifact"] = "byedpi".into();
        assert_eq!(
            validate(&serde_json::from_value(changed).unwrap()).state,
            "failed"
        );
    }
    #[test]
    fn ping_never_accepts_parameters() {
        let body = serde_json::json!({"protocolVersion":1,"installIdentity":INSTALL_IDENTITY,"operation":"ping","parameters":{}});
        assert_eq!(
            validate(&serde_json::from_value(body.clone()).unwrap()).state,
            "ready"
        );
        let mut changed = body;
        changed["parameters"]["command"] = "shell".into();
        assert_eq!(
            validate(&serde_json::from_value(changed).unwrap()).state,
            "failed"
        );
    }
}
