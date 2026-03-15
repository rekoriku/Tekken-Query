mod aliases;
mod completion;
mod data;
mod display;
mod error;
mod fetch;
mod filter;
mod interactive;
mod lean_server;
mod model;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use crate::error::CliError;
use crate::filter::{matches_all, parse_filters};
use crate::lean_server::LeanServer;
use crate::model::Move;

/// Tekken 8 frame data query tool.
/// Reads clean CSVs produced by the verified Lean pipeline.
#[derive(Parser)]
#[command(name = "tekken", version, about)]
struct Cli {
    /// Path to data directory (default: ./data)
    #[arg(short, long, default_value = "data")]
    data_dir: PathBuf,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Check if upstream data has been updated.
    Check,

    /// List all available characters.
    Chars,

    /// Show character stats.
    Stats {
        /// Character ID (e.g., jin, kazuya, yoshimitsu)
        character: String,
    },

    /// Query moves with filters.
    ///
    /// Filters are space-separated and AND'd together.
    /// Examples:
    ///   tekken query jin mid plus homing
    ///   tekken query kazuya i<15 plus
    ///   tekken query yoshimitsu pc mid !punish
    Query {
        /// Character ID
        character: String,
        /// Filter tokens (AND'd together)
        filters: Vec<String>,
    },

    /// Show detailed info for a specific move.
    #[command(name = "move")]
    MoveDetail {
        /// Character ID
        character: String,
        /// Command string to look up (e.g., "df+2", "4~3")
        command: String,
    },

    /// Compare a filter across two characters.
    Compare {
        /// First character ID
        char1: String,
        /// Second character ID
        char2: String,
        /// Filter tokens
        filters: Vec<String>,
    },

    /// Interactive REPL with auto-update on startup.
    #[command(name = "interactive", alias = "i")]
    Interactive,

    /// Fetch/update data from GitHub (no Lean dependency).
    Fetch,
}

fn run() -> Result<(), CliError> {
    let cli = Cli::parse();

    match &cli.command {
        Command::Check => cmd_check(&cli.data_dir),
        Command::Chars => cmd_chars(&cli.data_dir),
        Command::Stats { character } => cmd_stats(&cli.data_dir, character),
        Command::Query {
            character,
            filters,
        } => cmd_query(&cli.data_dir, character, filters),
        Command::MoveDetail { character, command } => {
            cmd_move_detail(&cli.data_dir, character, command)
        }
        Command::Compare {
            char1,
            char2,
            filters,
        } => cmd_compare(&cli.data_dir, char1, char2, filters),
        Command::Interactive => interactive::run_interactive(&cli.data_dir),
        Command::Fetch => cmd_fetch(&cli.data_dir),
    }
}

fn cmd_check(data_dir: &Path) -> Result<(), CliError> {
    let manifest = data::load_manifest(data_dir)?;
    let local_sha = &manifest.commit_sha;
    let short_local = if local_sha.len() >= 7 { &local_sha[..7] } else { local_sha.as_str() };

    eprintln!("Local data:  {} ({})", manifest.updated, short_local);
    eprintln!("Checking upstream...");

    let (remote_sha, message, is_newer) = data::check_upstream(local_sha)?;
    let short_remote = if remote_sha.len() >= 7 { &remote_sha[..7] } else { remote_sha.as_str() };

    if is_newer {
        eprintln!("Update available: {short_remote}");
        eprintln!("  {message}");
        eprintln!("\nRun 'tekken fetch' or 'tekken interactive' to update.");
    } else {
        eprintln!("Up to date: {short_remote}");
    }
    Ok(())
}

fn cmd_chars(data_dir: &Path) -> Result<(), CliError> {
    let manifest = data::load_manifest(data_dir)?;
    eprintln!("Characters ({}):", manifest.characters.len());
    for c in &manifest.characters {
        eprintln!("  {:<16} {:<20} {} moves", c.id, c.name, c.moves);
    }
    eprintln!("\nLast updated: {}", manifest.updated);
    Ok(())
}

fn cmd_stats(data_dir: &Path, character_id: &str) -> Result<(), CliError> {
    let char = load_char(data_dir, character_id)?;
    display::print_character_stats(&char.name, &char.moves);
    Ok(())
}

fn cmd_query(
    data_dir: &Path,
    character_id: &str,
    filter_tokens: &[String],
) -> Result<(), CliError> {
    let char = load_char(data_dir, character_id)?;
    let filter_str = filter_tokens.join(" ");
    let filters = parse_filters(&filter_str)?;

    // Try Lean server for verified evaluation
    if let Ok(mut server) = LeanServer::start(data_dir) {
        let csv_path = data_dir.join("clean").join(format!("{}.csv", char.id));
        if server.load_character(&char.id, &char.name, &csv_path).is_ok()
            && let Ok(qr) = server.query(&char.id, &filters)
        {
            eprintln!(
                "{} — {} matches (out of {})",
                qr.name,
                qr.count,
                qr.total,
            );
            let refs: Vec<&Move> = qr.moves.iter().collect();
            let cols = display::layout_for(&refs);
            display::print_header(&cols);
            for m in &refs {
                eprintln!("{}", display::format_move_row(m, &cols));
            }
            server.quit();
            return Ok(());
        }
        server.quit();
    }

    // Fallback: Rust-side evaluation
    let results: Vec<_> = char
        .moves
        .iter()
        .filter(|m| matches_all(m, &filters))
        .collect();

    eprintln!(
        "{} — {} matches (out of {})",
        char.name,
        results.len(),
        char.moves.len()
    );
    let cols = display::layout_for(&results);
    display::print_header(&cols);
    for m in &results {
        eprintln!("{}", display::format_move_row(m, &cols));
    }
    Ok(())
}

fn cmd_move_detail(
    data_dir: &Path,
    character_id: &str,
    command: &str,
) -> Result<(), CliError> {
    let char = load_char(data_dir, character_id)?;

    let found: Vec<_> = char
        .moves
        .iter()
        .filter(|m| m.command.eq_ignore_ascii_case(command))
        .collect();

    if found.is_empty() {
        // Try substring match
        let partial: Vec<_> = char
            .moves
            .iter()
            .filter(|m| m.command.to_lowercase().contains(&command.to_lowercase()))
            .collect();

        if partial.is_empty() {
            return Err(CliError::UnknownCharacter(format!(
                "no move matching '{command}' for {}",
                char.name
            )));
        }

        eprintln!("No exact match for '{command}'. Similar:");
        for m in &partial {
            eprintln!("{}", display::format_move_detail(m));
        }
    } else {
        for m in &found {
            eprintln!("{}", display::format_move_detail(m));
        }
    }
    Ok(())
}

fn cmd_compare(
    data_dir: &Path,
    char1_id: &str,
    char2_id: &str,
    filter_tokens: &[String],
) -> Result<(), CliError> {
    let char1 = load_char(data_dir, char1_id)?;
    let char2 = load_char(data_dir, char2_id)?;
    let filter_str = filter_tokens.join(" ");
    let filters = parse_filters(&filter_str)?;

    // Try Lean server for verified evaluation
    if let Ok(mut server) = LeanServer::start(data_dir) {
        let csv1 = data_dir.join("clean").join(format!("{}.csv", char1.id));
        let csv2 = data_dir.join("clean").join(format!("{}.csv", char2.id));
        let load1 = server.load_character(&char1.id, &char1.name, &csv1).is_ok();
        let load2 = server.load_character(&char2.id, &char2.name, &csv2).is_ok();
        if load1 && load2
            && let Ok(cr) = server.compare(&char1.id, &char2.id, &filters)
        {
            let refs1: Vec<&Move> = cr.char1_moves.iter().collect();
            let refs2: Vec<&Move> = cr.char2_moves.iter().collect();
            let all: Vec<&Move> = refs1.iter().chain(refs2.iter()).copied().collect();
            let cols = display::layout_for(&all);

            eprintln!("--- {} ({} matches) ---", cr.char1_name, refs1.len());
            display::print_header(&cols);
            for m in &refs1 {
                eprintln!("{}", display::format_move_row(m, &cols));
            }
            eprintln!();
            eprintln!("--- {} ({} matches) ---", cr.char2_name, refs2.len());
            display::print_header(&cols);
            for m in &refs2 {
                eprintln!("{}", display::format_move_row(m, &cols));
            }
            server.quit();
            return Ok(());
        }
        server.quit();
    }

    // Fallback: Rust-side evaluation
    let results1: Vec<_> = char1
        .moves
        .iter()
        .filter(|m| matches_all(m, &filters))
        .collect();
    let results2: Vec<_> = char2
        .moves
        .iter()
        .filter(|m| matches_all(m, &filters))
        .collect();

    let all_results: Vec<&Move> = results1.iter().chain(results2.iter()).copied().collect();
    let cols = display::layout_for(&all_results);

    eprintln!("--- {} [{}] ({} matches) ---", char1.name, char1.id, results1.len());
    display::print_header(&cols);
    for m in &results1 {
        eprintln!("{}", display::format_move_row(m, &cols));
    }

    eprintln!();
    eprintln!("--- {} [{}] ({} matches) ---", char2.name, char2.id, results2.len());
    display::print_header(&cols);
    for m in &results2 {
        eprintln!("{}", display::format_move_row(m, &cols));
    }
    Ok(())
}

fn cmd_fetch(data_dir: &Path) -> Result<(), CliError> {
    // Try to start Lean server for faster conversion, fall back to subprocess
    let mut server = LeanServer::start(data_dir).ok();
    fetch::fetch_all(data_dir, server.as_mut())?;
    if let Some(srv) = server {
        srv.quit();
    }
    Ok(())
}

/// Load a character, resolving the ID against the manifest.
fn load_char(data_dir: &Path, id: &str) -> Result<model::Character, CliError> {
    let manifest = data::load_manifest(data_dir)?;
    let lower = id.to_lowercase();
    let meta = manifest
        .characters
        .iter()
        .find(|c| c.id == lower)
        .ok_or_else(|| CliError::UnknownCharacter(lower.clone()))?;
    data::load_character(data_dir, &meta.id, &meta.name)
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Error: {e}");
            ExitCode::FAILURE
        }
    }
}
