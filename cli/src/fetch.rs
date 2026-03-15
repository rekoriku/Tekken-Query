/// Data fetching from GitHub.
///
/// Rust handles network I/O (fetching raw CSVs, checking commits).
/// Lean handles data transformation (raw CSV → clean CSV) via its
/// formally verified pipeline. This preserves the architecture:
/// Lean = verified data handler, Rust = CLI presentation layer.
use std::path::Path;

use crate::data::{CharacterMeta, Manifest};
use crate::error::CliError;

// ── GitHub API URLs ─────────────────────────────────────────────────

const API_URL: &str =
    "https://api.github.com/repos/pbruvoll/tekkendocs/contents/data/wavuConvertedCsv";
const BASE_URL: &str =
    "https://raw.githubusercontent.com/pbruvoll/tekkendocs/refs/heads/main/data/wavuConvertedCsv";
const COMMITS_URL: &str =
    "https://api.github.com/repos/pbruvoll/tekkendocs/commits?path=data/wavuConvertedCsv&per_page=1";

// ── GitHub API types ────────────────────────────────────────────────

/// Entry from the GitHub contents API.
#[derive(Debug, serde::Deserialize)]
struct GitHubContentEntry {
    name: String,
    #[serde(rename = "type")]
    entry_type: String,
}

/// Commit from the GitHub commits API.
#[derive(Debug, serde::Deserialize)]
struct GitHubCommit {
    sha: String,
}

// ── Network functions ───────────────────────────────────────────────

/// Discover character IDs from the GitHub API.
fn fetch_character_list() -> Result<Vec<String>, CliError> {
    let response = ureq::get(API_URL)
        .set("User-Agent", "tekken-cli")
        .call()
        .map_err(|e| CliError::NetworkError(format!("character list: {e}")))?;

    let entries: Vec<GitHubContentEntry> = response
        .into_json()
        .map_err(|e| CliError::ParseError(format!("character list JSON: {e}")))?;

    let mut chars: Vec<String> = entries
        .into_iter()
        .filter(|e| e.entry_type == "dir" && e.name.to_lowercase() != "test")
        .map(|e| e.name)
        .collect();

    chars.sort();
    Ok(chars)
}

/// Fetch a single character's raw CSV from GitHub.
fn fetch_raw_csv(id: &str) -> Result<String, CliError> {
    let primary = format!("{BASE_URL}/{id}/{id}-special.csv");
    let fallback = format!("{BASE_URL}/{id}.csv");

    if let Ok(resp) = ureq::get(&primary)
        .set("User-Agent", "tekken-cli")
        .call()
    {
        resp.into_string()
            .map_err(|e| CliError::NetworkError(format!("{id}: {e}")))
    } else {
        let resp = ureq::get(&fallback)
            .set("User-Agent", "tekken-cli")
            .call()
            .map_err(|e| CliError::NetworkError(format!("{id}: {e}")))?;
        resp.into_string()
            .map_err(|e| CliError::NetworkError(format!("{id}: {e}")))
    }
}

/// Fetch the latest commit SHA from GitHub.
fn fetch_latest_sha() -> Result<String, CliError> {
    let response = ureq::get(COMMITS_URL)
        .set("User-Agent", "tekken-cli")
        .call()
        .map_err(|e| CliError::NetworkError(format!("commits API: {e}")))?;

    let commits: Vec<GitHubCommit> = response
        .into_json()
        .map_err(|e| CliError::ParseError(format!("commits JSON: {e}")))?;

    let latest = commits
        .first()
        .ok_or_else(|| CliError::ParseError("no commits returned".into()))?;

    Ok(latest.sha.clone())
}

// ── Lean binary integration ─────────────────────────────────────────

/// Find the Lean binary path. Checks standard locations.
fn find_lean_binary() -> Option<String> {
    let candidates = [
        ".lake/build/bin/tekken_query",
        "../.lake/build/bin/tekken_query",
    ];
    for path in &candidates {
        if std::path::Path::new(path).exists() {
            return Some((*path).to_string());
        }
    }
    None
}

/// Convert a raw CSV to clean CSV using the Lean binary.
///
/// The Lean pipeline is formally verified — this ensures the
/// clean CSV output is provably correct.
fn convert_with_lean(lean_binary: &str, raw_path: &Path) -> Result<String, CliError> {
    let output = std::process::Command::new("lake")
        .args(["env", lean_binary, "--export"])
        .arg(raw_path)
        .output()
        .map_err(|e| CliError::IoError(format!("lean binary: {e}")))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(CliError::ParseError(format!(
            "lean export failed: {stderr}"
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Count moves in a clean CSV string (lines minus header).
fn count_csv_moves(csv: &str) -> usize {
    let lines = csv.lines().count();
    if lines > 0 { lines - 1 } else { 0 }
}

// ── Display name conversion ─────────────────────────────────────────

/// Convert a character ID to a display name.
///
/// `"devil-jin"` → `"Devil Jin"`, `"jack-8"` → `"Jack-8"`.
fn to_display_name(id: &str) -> String {
    id.split('-')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(c) => {
                    let upper: String = c.to_uppercase().collect();
                    format!("{upper}{}", chars.as_str())
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

// ── Orchestration ───────────────────────────────────────────────────

/// Write the manifest file.
fn write_manifest(data_dir: &Path, manifest: &Manifest) -> Result<(), CliError> {
    let path = data_dir.join("characters.json");
    let json = serde_json::to_string_pretty(manifest)
        .map_err(|e| CliError::ParseError(format!("manifest JSON: {e}")))?;
    std::fs::write(&path, json)
        .map_err(|e| CliError::IoError(format!("{}: {e}", path.display())))
}

/// Fetch all characters from GitHub, convert via Lean, and write to disk.
///
/// Returns the updated manifest.
pub fn fetch_all(data_dir: &Path) -> Result<Manifest, CliError> {
    let lean_binary = find_lean_binary().ok_or_else(|| {
        CliError::DataNotFound(
            "Lean binary not found. Run 'lake build' in the project root first.".into(),
        )
    })?;

    let raw_dir = data_dir.join("raw");
    let clean_dir = data_dir.join("clean");
    std::fs::create_dir_all(&raw_dir)
        .map_err(|e| CliError::IoError(format!("create {}: {e}", raw_dir.display())))?;
    std::fs::create_dir_all(&clean_dir)
        .map_err(|e| CliError::IoError(format!("create {}: {e}", clean_dir.display())))?;

    eprintln!("Fetching character list...");
    let char_ids = fetch_character_list()?;
    eprintln!("Found {} characters", char_ids.len());

    let sha = fetch_latest_sha().unwrap_or_else(|_| "unknown".to_string());

    let mut characters = Vec::new();
    let mut failed = 0u32;

    for id in &char_ids {
        match fetch_and_convert(id, &lean_binary, &raw_dir, &clean_dir) {
            Ok(move_count) => {
                let display_name = to_display_name(id);
                eprintln!("  OK   {id} ({move_count} moves)");
                characters.push(CharacterMeta {
                    id: id.clone(),
                    name: display_name,
                    moves: u32::try_from(move_count).unwrap_or(0),
                });
            }
            Err(e) => {
                eprintln!("  FAIL {id}: {e}");
                failed += 1;
            }
        }
    }

    let manifest = Manifest {
        updated: utc_now(),
        commit_sha: sha,
        characters,
    };

    write_manifest(data_dir, &manifest)?;

    eprintln!(
        "\nDone: {} ok, {failed} failed",
        manifest.characters.len()
    );

    Ok(manifest)
}

/// Fetch a single character's raw CSV and convert via Lean.
fn fetch_and_convert(
    id: &str,
    lean_binary: &str,
    raw_dir: &Path,
    clean_dir: &Path,
) -> Result<usize, CliError> {
    // Fetch raw CSV
    let csv_text = fetch_raw_csv(id)?;

    // Write raw CSV
    let raw_path = raw_dir.join(format!("{id}.csv"));
    std::fs::write(&raw_path, &csv_text)
        .map_err(|e| CliError::IoError(format!("{}: {e}", raw_path.display())))?;

    // Convert via Lean verified pipeline
    let clean_csv = convert_with_lean(lean_binary, &raw_path)?;

    // Write clean CSV
    let clean_path = clean_dir.join(format!("{id}.csv"));
    std::fs::write(&clean_path, &clean_csv)
        .map_err(|e| CliError::IoError(format!("{}: {e}", clean_path.display())))?;

    Ok(count_csv_moves(&clean_csv))
}

/// Check if upstream data has been updated, and fetch if so.
///
/// Returns `(manifest, was_updated)`. On network failure, falls back to
/// local data if available.
pub fn update_if_needed(data_dir: &Path) -> Result<(Manifest, bool), CliError> {
    let existing = crate::data::load_manifest(data_dir).ok();

    match fetch_latest_sha() {
        Ok(remote_sha) => {
            let local_sha = existing.as_ref().map_or("", |m| m.commit_sha.as_str());
            if local_sha == remote_sha && !local_sha.is_empty() {
                let short = if remote_sha.len() >= 7 {
                    &remote_sha[..7]
                } else {
                    &remote_sha
                };
                eprintln!("Data up to date ({short})");
                return existing
                    .map(|m| (m, false))
                    .ok_or_else(|| CliError::DataNotFound("manifest missing".into()));
            }

            let short = if remote_sha.len() >= 7 {
                &remote_sha[..7]
            } else {
                &remote_sha
            };
            eprintln!("Update available ({short}), fetching...");
            let manifest = fetch_all(data_dir)?;
            Ok((manifest, true))
        }
        Err(e) => {
            eprintln!("Network check failed: {e}");
            match existing {
                Some(m) => {
                    eprintln!("Using local data ({})", m.updated);
                    Ok((m, false))
                }
                None => Err(CliError::DataNotFound(
                    "no local data and network unavailable".into(),
                )),
            }
        }
    }
}

/// Simple UTC timestamp.
fn utc_now() -> String {
    let output = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout).trim().to_string()
        }
        _ => "unknown".to_string(),
    }
}
