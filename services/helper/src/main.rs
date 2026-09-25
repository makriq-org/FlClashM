mod service;

#[cfg(all(feature = "windows-service", target_os = "windows"))]
pub fn main() -> windows_service::Result<()> {
    service::windows::main()
}

#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
fn main() {
    // The real helper is a Windows service.  Do not expose a developer-mode
    // fallback listener on other platforms.
    let _ = service::hub::run_service();
}
