/// Launcher for Tekken Query.
///
/// Finds `tekken-cli` in the same directory and launches interactive mode.
/// On Windows this binary embeds an icon so users can double-click it.
use std::path::PathBuf;
use std::process::{Command, ExitCode};

fn exe_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(std::path::Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn main() -> ExitCode {
    let dir = exe_dir();

    let cli_name = if cfg!(target_os = "windows") {
        "tekken-cli.exe"
    } else {
        "tekken-cli"
    };

    let cli_path = dir.join(cli_name);
    let data_dir = dir.join("data");

    let status = Command::new(&cli_path)
        .arg("-d")
        .arg(&data_dir)
        .arg("interactive")
        .status();

    match status {
        Ok(s) if s.success() => ExitCode::SUCCESS,
        Ok(_) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("Failed to launch tekken-cli: {e}");
            eprintln!("Make sure '{cli_name}' is in the same directory as this launcher.");
            ExitCode::FAILURE
        }
    }
}
