//! The privileged helper has no TCP listener.  Windows supplies its transport
//! in `windows.rs`; this small fallback keeps accidental non-Windows builds
//! inert instead of turning a developer build into a privileged network API.

pub fn run_service() -> anyhow::Result<()> {
    Ok(())
}
