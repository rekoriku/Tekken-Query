/// Data loading from clean CSVs and character manifest.
use std::path::{Path, PathBuf};

use crate::error::CliError;
use crate::model::{Character, Move};

/// Metadata for a character from the manifest.
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct CharacterMeta {
    pub id: String,
    pub name: String,
    pub moves: u32,
}

/// The manifest file structure.
#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub struct Manifest {
    pub updated: String,
    #[serde(default)]
    pub commit_sha: String,
    pub characters: Vec<CharacterMeta>,
}

/// Response from GitHub commits API (only the fields we need).
#[derive(Debug, serde::Deserialize)]
pub struct GitHubCommit {
    pub sha: String,
    pub commit: GitHubCommitDetail,
}

/// Nested commit detail from GitHub API.
#[derive(Debug, serde::Deserialize)]
pub struct GitHubCommitDetail {
    pub message: String,
}

const COMMITS_URL: &str =
    "https://api.github.com/repos/pbruvoll/tekkendocs/commits?path=data/wavuConvertedCsv&per_page=1";

/// Check the upstream repo for updates.
///
/// Returns `(latest_sha, message, is_newer)`.
pub fn check_upstream(local_sha: &str) -> Result<(String, String, bool), CliError> {
    let response = ureq::get(COMMITS_URL)
        .set("User-Agent", "tekken-cli")
        .call()
        .map_err(|e| CliError::DataNotFound(format!("GitHub API request failed: {e}")))?;

    let commits: Vec<GitHubCommit> = response
        .into_json()
        .map_err(|e| CliError::ParseError(format!("GitHub API response: {e}")))?;

    let latest = commits
        .first()
        .ok_or_else(|| CliError::ParseError("no commits returned".into()))?;

    let first_line = latest.commit.message.lines().next().unwrap_or("");
    let is_newer = local_sha != latest.sha && local_sha != "unknown";

    Ok((latest.sha.clone(), first_line.to_string(), is_newer))
}

/// Load the character manifest from `data/characters.json`.
pub fn load_manifest(data_dir: &Path) -> Result<Manifest, CliError> {
    let path = data_dir.join("characters.json");
    let contents = std::fs::read_to_string(&path)
        .map_err(|e| CliError::DataNotFound(format!("{}: {e}", path.display())))?;
    serde_json::from_str(&contents)
        .map_err(|e| CliError::ParseError(format!("manifest: {e}")))
}

/// Load a character's moves from their clean CSV.
pub fn load_character(data_dir: &Path, id: &str, display_name: &str) -> Result<Character, CliError> {
    let csv_path: PathBuf = data_dir.join("clean").join(format!("{id}.csv"));
    let mut reader = csv::Reader::from_path(&csv_path)
        .map_err(|e| CliError::DataNotFound(format!("{}: {e}", csv_path.display())))?;

    let mut moves = Vec::new();
    for result in reader.deserialize() {
        let m: Move = result.map_err(|e| CliError::ParseError(format!("{id}: {e}")))?;
        moves.push(m);
    }

    Ok(Character {
        id: id.to_string(),
        name: display_name.to_string(),
        moves,
    })
}

