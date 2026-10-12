#[cfg(not(all(feature = "windows-service", target_os = "windows")))]
pub mod hub;
#[cfg(all(feature = "windows-service", target_os = "windows"))]
pub mod windows;
#[cfg(all(feature = "windows-service", target_os = "windows"))]
mod windows_runtime;
