//! Windows Service endpoint for the product helper protocol.
//!
//! The pipe ACL deliberately grants read/write access only to SYSTEM,
//! administrators and interactive logon sessions.  There is no loopback TCP
//! fallback: an unauthenticated local HTTP port is not a privilege boundary.

use std::ffi::OsString;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use windows::core::w;
use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, HANDLE, HLOCAL};
use windows::Win32::Security::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, PSECURITY_DESCRIPTOR, SDDL_REVISION_1,
    SECURITY_ATTRIBUTES,
};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_ATTRIBUTE_NORMAL, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    FILE_SHARE_NONE, OPEN_EXISTING,
};
use windows::Win32::System::Memory::LocalFree;
use windows::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, PIPE_ACCESS_DUPLEX, PIPE_READMODE_MESSAGE,
    PIPE_TYPE_MESSAGE, PIPE_WAIT,
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
            wake_pipe();
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
    while !STOP_REQUESTED.load(Ordering::Acquire) {
        let pipe = create_pipe()?;
        // A named-pipe client can connect between CreateNamedPipe and
        // ConnectNamedPipe. ERROR_PIPE_CONNECTED is that expected race.
        let connected = unsafe { ConnectNamedPipe(pipe, None) }.is_ok()
            || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        if connected {
            let _ = serve_client(pipe);
        }
        unsafe { CloseHandle(pipe) }?;
    }
    Ok(())
}

/// `ConnectNamedPipe` is synchronous so a service-control request needs to
/// wake it.  The service account itself is allowed by the pipe DACL; opening
/// and immediately closing this client does not execute a command.
fn wake_pipe() {
    if let Ok(pipe) = unsafe {
        CreateFileW(
            PIPE_NAME,
            FILE_GENERIC_READ | FILE_GENERIC_WRITE,
            FILE_SHARE_NONE,
            None,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            None,
        )
    } {
        let _ = unsafe { CloseHandle(pipe) };
    }
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
            PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
            1,
            MAX_MESSAGE as u32,
            MAX_MESSAGE as u32,
            1000,
            Some(&attributes),
        )
    };
    let _ = unsafe { LocalFree(HLOCAL(descriptor.0 as _)) };
    Ok(result?)
}

fn serve_client(pipe: HANDLE) -> anyhow::Result<()> {
    let mut input = vec![0_u8; MAX_MESSAGE];
    let mut read = 0_u32;
    unsafe { ReadFile(pipe, Some(input.as_mut_slice()), Some(&mut read), None) }?;
    let response = match serde_json::from_slice::<Request>(&input[..read as usize]) {
        Ok(request) => validate(&request),
        Err(_) => Response {
            state: "failed",
            message: "Malformed helper request.",
        },
    };
    let body = serde_json::to_vec(&response)?;
    let mut written = 0_u32;
    unsafe { WriteFile(pipe, Some(body.as_slice()), Some(&mut written), None) }?;
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
        Operation::TunOpen => &["interface", "mtu"][..],
        Operation::TunClose => &["interface"][..],
        Operation::RouteApply => &["interface", "routes"][..],
        Operation::RouteRollback | Operation::DnsRollback => &["transaction"][..],
        Operation::DnsApply => &["interface", "servers"][..],
        Operation::RuntimeStart | Operation::RuntimeStop => &["runtimeToken"][..],
    };
    let runtime = matches!(
        request.operation,
        Operation::RuntimeStart | Operation::RuntimeStop
    );
    if runtime != request.runtime_artifact.is_some()
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
        Operation::RuntimeStart | Operation::RuntimeStop => {
            valid_token(value_string(parameters, "runtimeToken"), 16)
        }
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
