//! Owns one installed mihomo child. Never accepts a path, argv, or environment
//! from IPC. GUI death, service stop, and IPC stop all release the same lease.
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context};
use windows::Win32::Foundation::LocalFree;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Security::Authorization::ConvertSidToStringSidW;
use windows::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};
use windows::Win32::System::Threading::{
    OpenProcess, OpenProcessToken, QueryFullProcessImageNameW, WaitForSingleObject,
    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
};
use windows::Win32::UI::Shell::{FOLDERID_ProgramFiles, SHGetKnownFolderPath, KF_FLAG_DEFAULT};

pub struct OwnedHandle(pub HANDLE);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        let _ = unsafe { CloseHandle(self.0) };
    }
}

fn known_folder(id: &windows::core::GUID) -> anyhow::Result<PathBuf> {
    let value = unsafe { SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None) }?;
    let result = unsafe { value.to_string() };
    unsafe { CoTaskMemFree(Some(value.0 as _)) };
    Ok(PathBuf::from(result?))
}

pub fn install_root() -> anyhow::Result<PathBuf> {
    Ok(known_folder(&FOLDERID_ProgramFiles)?.join("FlClashM"))
}

pub struct Client {
    pub process: OwnedHandle,
    pub pid: u32,
    pub sid: String,
}

pub fn authenticate(pid: u32) -> anyhow::Result<Client> {
    let process = OwnedHandle(unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            pid,
        )
    }?);
    let mut name = vec![0_u16; 32768];
    let mut length = name.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(
            process.0,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(name.as_mut_ptr()),
            &mut length,
        )
    }?;
    let actual = PathBuf::from(String::from_utf16(&name[..length as usize])?);
    let expected = install_root()?.join("FlClashM.exe");
    ensure!(
        same_file(&actual, &expected)?,
        "Client is not the installed FlClashM application."
    );
    let mut raw_token = HANDLE::default();
    unsafe { OpenProcessToken(process.0, TOKEN_QUERY, &mut raw_token) }?;
    let token = OwnedHandle(raw_token);
    let mut required = 0_u32;
    let _ = unsafe { GetTokenInformation(token.0, TokenUser, None, 0, &mut required) };
    ensure!(required > 0 && required < 65536, "Invalid client token.");
    // usize allocation preserves TOKEN_USER alignment.
    let mut buffer = vec![0_usize; (required as usize).div_ceil(std::mem::size_of::<usize>())];
    unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            Some(buffer.as_mut_ptr() as _),
            required,
            &mut required,
        )
    }?;
    let user = unsafe { &*(buffer.as_ptr() as *const TOKEN_USER) };
    let mut sid = windows::core::PWSTR::null();
    unsafe { ConvertSidToStringSidW(user.User.Sid, &mut sid) }?;
    let value = unsafe { sid.to_string() };
    let _ = unsafe { LocalFree(windows::Win32::Foundation::HLOCAL(sid.0 as _)) };
    let sid = value?;
    ensure!(
        sid.starts_with("S-1-5-") && sid != "S-1-5-18",
        "Interactive user required."
    );
    Ok(Client { process, pid, sid })
}

fn same_file(a: &Path, b: &Path) -> anyhow::Result<bool> {
    Ok(a.canonicalize()?
        .to_string_lossy()
        .eq_ignore_ascii_case(&b.canonicalize()?.to_string_lossy()))
}

pub struct Runtime {
    child: Child,
    client: Client,
    token: String,
    _job: OwnedHandle,
}

impl Runtime {
    pub fn start(client: Client, token: &str, port: u16) -> anyhow::Result<Self> {
        verify_listener(client.pid, port)?;
        let root = install_root()?;
        let helper = root.join("runtimes/windows/x86_64/app.flclashm.client.helper.exe");
        ensure!(
            same_file(&std::env::current_exe()?, &helper)?,
            "Helper is not installed in the protected layout."
        );
        let home = root.join("service-data").join(&client.sid);
        // Setup creates/protects the parent before the service starts. Ordinary
        // users cannot replace it or plant junctions under the core's home.
        ensure!(
            home.parent().is_some_and(Path::is_dir),
            "Protected runtime directory is missing; reinstall FlClashM."
        );
        std::fs::create_dir_all(&home)?;
        let job = OwnedHandle(unsafe { CreateJobObjectW(None, None) }?);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as _,
                std::mem::size_of_val(&limits) as u32,
            )
        }?;
        let mut command = Command::new(root.join("runtimes/windows/x86_64/mihomo.exe"));
        command
            .arg(port.to_string())
            .current_dir(&home)
            .env_clear()
            .env(
                "SystemRoot",
                std::env::var_os("SystemRoot").context("SystemRoot is missing")?,
            )
            .env("FLCLASHM_CONTROL_TOKEN", token)
            .env("FLCLASHM_SERVICE_HOME", &home)
            .env("SAFE_PATHS", &home)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        let mut child = command.spawn()?;
        if let Err(error) =
            unsafe { AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle())) }
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error.into());
        }
        Ok(Self {
            child,
            client,
            token: token.to_owned(),
            _job: job,
        })
    }

    pub fn owned_by(&self, pid: u32, token: &str) -> bool {
        self.client.pid == pid && self.token == token
    }

    pub fn reap(&mut self) -> anyhow::Result<bool> {
        if unsafe { WaitForSingleObject(self.client.process.0, 0) } == WAIT_OBJECT_0 {
            self.stop()?;
            return Ok(true);
        }
        Ok(self.child.try_wait()?.is_some())
    }

    pub fn stop(&mut self) -> anyhow::Result<()> {
        // Closing stdin requests cleanup in the core before forced fallback.
        drop(self.child.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.child.try_wait()?.is_none() {
            if Instant::now() >= deadline {
                self.child.kill()?;
                self.child.wait()?;
                bail!("Mihomo exceeded its graceful shutdown deadline.");
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        Ok(())
    }
}

fn verify_listener(pid: u32, port: u16) -> anyhow::Result<()> {
    use windows::Win32::NetworkManagement::IpHelper::{
        GetExtendedTcpTable, MIB_TCPTABLE_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER,
    };
    let mut required = 0_u32;
    let _ = unsafe {
        GetExtendedTcpTable(
            None,
            &mut required,
            false,
            2,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        )
    };
    ensure!(
        required >= 4 && required < 16 * 1024 * 1024,
        "Invalid TCP table size."
    );
    let mut buffer = vec![0_u64; (required as usize).div_ceil(8)];
    ensure!(
        unsafe {
            GetExtendedTcpTable(
                Some(buffer.as_mut_ptr() as _),
                &mut required,
                false,
                2,
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            )
        } == 0,
        "Could not inspect the control listener."
    );
    let table = unsafe { &*(buffer.as_ptr() as *const MIB_TCPTABLE_OWNER_PID) };
    let rows =
        unsafe { std::slice::from_raw_parts(table.table.as_ptr(), table.dwNumEntries as usize) };
    ensure!(
        rows.iter().any(|row| row.dwOwningPid == pid
            && row.dwLocalAddr == u32::from_ne_bytes([127, 0, 0, 1])
            && u16::from_be(row.dwLocalPort as u16) == port),
        "Control listener does not belong to the installed client."
    );
    Ok(())
}

impl Drop for Runtime {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}
