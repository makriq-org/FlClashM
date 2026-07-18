use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufRead, Error, Read};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::{io, thread};
use warp::{Filter, Reply};

const LISTEN_PORT: u16 = 47890;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct StartParams {
    pub path: String,
    pub arg: String,
    pub home_dir: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ReplaceParams {
    pub pending: String,
    pub target: String,
}

fn sha256_file(path: &str) -> Result<String, Error> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0; 4096];

    loop {
        let bytes_read = file.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        hasher.update(&buffer[..bytes_read]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

fn allowed_hash_path() -> Option<std::path::PathBuf> {
    Some(
        std::env::current_exe()
            .ok()?
            .parent()?
            .join("allowed_core.sha256"),
    )
}

/// Core updates delivered by the app rewrite this file (admin-writable only in
/// per-machine installs); the compiled-in TOKEN covers fresh installs.
fn allowed_hash() -> String {
    if let Some(path) = allowed_hash_path() {
        if let Ok(content) = std::fs::read_to_string(&path) {
            let hash = content.trim().to_lowercase();
            if hash.len() == 64 && hash.chars().all(|c| c.is_ascii_hexdigit()) {
                return hash;
            }
        }
    }
    env!("TOKEN").to_string()
}

static LOGS: Lazy<Arc<Mutex<VecDeque<String>>>> =
    Lazy::new(|| Arc::new(Mutex::new(VecDeque::with_capacity(100))));
static PROCESS: Lazy<Arc<Mutex<Option<std::process::Child>>>> =
    Lazy::new(|| Arc::new(Mutex::new(None)));

fn start(start_params: StartParams) -> impl Reply {
    let sha256 = sha256_file(start_params.path.as_str()).unwrap_or("".to_string());
    let allowed = allowed_hash();
    if sha256 != allowed {
        return format!("The SHA256 hash of the program requesting execution is: {}. The helper program only allows execution of applications with the SHA256 hash: {}.", sha256, allowed,);
    }
    stop();
    let mut process = PROCESS.lock().unwrap();
    let mut command = Command::new(&start_params.path);
    command.stderr(Stdio::piped()).arg(&start_params.arg);
    
    // Set SAFE_PATHS to prevent "path is not subpath of home directory" errors
    // This ensures the core can access provider files before SetHomeDir is called
    if let Some(home_dir) = start_params.home_dir {
        command.env("SAFE_PATHS", home_dir);
    }
    
    match command.spawn() {
        Ok(child) => {
            *process = Some(child);
            if let Some(ref mut child) = *process {
                let stderr = child.stderr.take().unwrap();
                let reader = io::BufReader::new(stderr);
                thread::spawn(move || {
                    for line in reader.lines() {
                        match line {
                            Ok(output) => {
                                log_message(output);
                            }
                            Err(_) => {
                                break;
                            }
                        }
                    }
                });
            }
            "".to_string()
        }
        Err(e) => {
            log_message(e.to_string());
            e.to_string()
        }
    }
}

/// Swap in a downloaded core update. The service runs as SYSTEM, so it can
/// write into Program Files where the unelevated app cannot (the app's own
/// rename fails with access-denied for a per-machine install). Stops the core
/// first to release the exe lock, moves pending->target, then refreshes the
/// allow-list hash so the new binary passes the /start check — all as SYSTEM,
/// no UAC prompt. Returns "" on success or an error string.
fn replace_core(params: ReplaceParams) -> impl Reply {
    stop();
    if let Err(e) = std::fs::rename(&params.pending, &params.target) {
        // Cross-device or transient lock: fall back to copy+remove.
        if std::fs::copy(&params.pending, &params.target).is_err() {
            return format!("replace_core failed: {}", e);
        }
        let _ = std::fs::remove_file(&params.pending);
    }
    if let Ok(hash) = sha256_file(&params.target) {
        if let Some(path) = allowed_hash_path() {
            let _ = std::fs::write(&path, hash);
        }
    }
    "".to_string()
}

fn stop() -> impl Reply {
    let mut process = PROCESS.lock().unwrap();
    if let Some(mut child) = process.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    *process = None;
    "".to_string()
}

fn log_message(message: String) {
    let mut log_buffer = LOGS.lock().unwrap();
    if log_buffer.len() == 100 {
        log_buffer.pop_front();
    }
    log_buffer.push_back(format!("{}\n", message));
}

fn get_logs() -> impl Reply {
    let log_buffer = LOGS.lock().unwrap();
    let value = log_buffer
        .iter()
        .cloned()
        .collect::<Vec<String>>()
        .join("\n");
    warp::reply::with_header(value, "Content-Type", "text/plain")
}

pub async fn run_service() -> anyhow::Result<()> {
    let api_ping = warp::get().and(warp::path("ping")).map(allowed_hash);

    let api_start = warp::post()
        .and(warp::path("start"))
        .and(warp::body::json())
        .map(|start_params: StartParams| start(start_params));

    let api_stop = warp::post().and(warp::path("stop")).map(|| stop());

    let api_replace = warp::post()
        .and(warp::path("replace_core"))
        .and(warp::body::json())
        .map(|params: ReplaceParams| replace_core(params));

    let api_logs = warp::get().and(warp::path("logs")).map(|| get_logs());


    warp::serve(
        api_ping
            .or(api_start)
            .or(api_stop)
            .or(api_replace)
            .or(api_logs),
    )
    .run(([127, 0, 0, 1], LISTEN_PORT))
    .await;

    Ok(())
}
