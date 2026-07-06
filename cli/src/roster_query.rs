/// Roster-wide filter queries.
///
/// This keeps `all <filters...>` on the same parser/evaluator path as
/// character queries, so math-style filters behave consistently everywhere.
use std::path::Path;

use crate::data::{self, Manifest};
use crate::display;
use crate::error::CliError;
use crate::filter::{matches_all, parse_filters};
use crate::lean_server::LeanServer;
use crate::model::{Character, Move};

struct RosterGroup {
    name: String,
    moves: Vec<Move>,
}

/// Sort direction for roster-wide query output.
#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub enum SortDirection {
    #[default]
    Asc,
    Desc,
}

impl SortDirection {
    /// Parse a user-facing sort direction.
    pub fn parse(value: &str) -> Result<Self, CliError> {
        match value {
            "asc" | "ascending" => Ok(Self::Asc),
            "desc" | "descending" => Ok(Self::Desc),
            _ => Err(CliError::InvalidFilter(format!("unknown order: {value}"))),
        }
    }
}

/// Sort order for roster-wide query output.
#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub enum RosterSort {
    #[default]
    Character,
    Startup,
}

impl RosterSort {
    /// Parse a user-facing sort key.
    pub fn parse(value: &str) -> Result<Self, CliError> {
        match value {
            "character" | "char" => Ok(Self::Character),
            "startup" | "speed" | "fastest" | "i" => Ok(Self::Startup),
            _ => Err(CliError::InvalidFilter(format!("unknown sort: {value}"))),
        }
    }
}

/// Output options for roster-wide queries.
#[derive(Debug, Clone, Copy)]
pub struct RosterQueryOptions {
    pub per_character_limit: Option<usize>,
    pub flat: bool,
    pub summary: bool,
    pub sort: RosterSort,
    pub direction: SortDirection,
}

impl Default for RosterQueryOptions {
    fn default() -> Self {
        Self {
            per_character_limit: Some(5),
            flat: false,
            summary: false,
            sort: RosterSort::Character,
            direction: SortDirection::Asc,
        }
    }
}

/// Parse output modifier tokens and return the remaining filter text.
///
/// Compact tokens keep the syntax aligned with the existing filter language:
/// `all pc limit:0`, `all pc by:i asc`, `all heat summary`.
pub fn parse_inline_options(input: &str) -> Result<(RosterQueryOptions, String), CliError> {
    let mut options = RosterQueryOptions::default();
    let mut filters = Vec::new();

    for token in input.split_whitespace() {
        match token {
            "flat" => options.flat = true,
            "summary" => options.summary = true,
            "fastest" => options.sort = RosterSort::Startup,
            "slowest" => {
                options.sort = RosterSort::Startup;
                options.direction = SortDirection::Desc;
            }
            "asc" | "ascending" => options.direction = SortDirection::Asc,
            "desc" | "descending" => options.direction = SortDirection::Desc,
            _ if token.starts_with("by:") => {
                let value = token.trim_start_matches("by:");
                options.sort = RosterSort::parse(value)?;
            }
            _ if token.starts_with("sort:") => {
                let value = token.trim_start_matches("sort:");
                options.sort = RosterSort::parse(value)?;
            }
            _ if token.starts_with("order:") => {
                let value = token.trim_start_matches("order:");
                options.direction = SortDirection::parse(value)?;
            }
            _ if token.starts_with("limit:") => {
                let value = token.trim_start_matches("limit:");
                let n = value
                    .parse::<usize>()
                    .map_err(|_| CliError::InvalidFilter(format!("bad limit: {token}")))?;
                options.per_character_limit = if n == 0 { None } else { Some(n) };
            }
            _ => filters.push(token),
        }
    }

    Ok((options, filters.join(" ")))
}

/// Backwards-compatible name for the REPL call site.
pub fn parse_interactive_options(input: &str) -> Result<(RosterQueryOptions, String), CliError> {
    parse_inline_options(input)
}

fn compare_startup(
    a: Option<i64>,
    b: Option<i64>,
    direction: SortDirection,
) -> std::cmp::Ordering {
    match (a, b) {
        (Some(left), Some(right)) => match direction {
            SortDirection::Asc => left.cmp(&right),
            SortDirection::Desc => right.cmp(&left),
        },
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    }
}

fn sorted_flat_results(
    groups: &[RosterGroup],
    sort: RosterSort,
    direction: SortDirection,
) -> Vec<(&str, &Move)> {
    let mut flat: Vec<(&str, &Move)> = groups
        .iter()
        .flat_map(|group| group.moves.iter().map(move |m| (group.name.as_str(), m)))
        .collect();

    if sort == RosterSort::Startup {
        flat.sort_by(|(char_a, move_a), (char_b, move_b)| {
            compare_startup(move_a.startup, move_b.startup, direction)
                .then_with(|| char_a.cmp(char_b))
                .then_with(|| move_a.command.cmp(&move_b.command))
        });
    }

    flat
}

fn query_with_lean(
    server: &mut LeanServer,
    data_dir: &Path,
    manifest: &Manifest,
    filters: &[crate::filter::Filter],
) -> Result<Vec<RosterGroup>, CliError> {
    let mut groups = Vec::new();

    for meta in &manifest.characters {
        let csv_path = data_dir.join("clean").join(format!("{}.csv", meta.id));
        server.load_character(&meta.id, &meta.name, &csv_path)?;
        let result = server.query(&meta.id, filters)?;

        if !result.moves.is_empty() {
            groups.push(RosterGroup {
                name: result.name,
                moves: result.moves,
            });
        }
    }

    Ok(groups)
}

fn query_with_rust(
    data_dir: &Path,
    manifest: &Manifest,
    filters: &[crate::filter::Filter],
) -> Vec<RosterGroup> {
    let characters: Vec<Character> = manifest
        .characters
        .iter()
        .filter_map(|meta| data::load_character(data_dir, &meta.id, &meta.name).ok())
        .collect();

    let mut groups = Vec::new();

    for character in characters {
        let moves: Vec<Move> = character
            .moves
            .into_iter()
            .filter(|m| matches_all(m, filters))
            .collect();

        if !moves.is_empty() {
            groups.push(RosterGroup {
                name: character.name,
                moves,
            });
        }
    }

    groups
}

fn print_results(groups: &[RosterGroup], filter_text: &str, options: RosterQueryOptions) {
    let total_matches: usize = groups.iter().map(|group| group.moves.len()).sum();

    if options.summary {
        let counts: Vec<(&str, usize)> = groups
            .iter()
            .map(|group| (group.name.as_str(), group.moves.len()))
            .collect();
        display::print_roster_query_summary(&counts, filter_text, total_matches);
        return;
    }

    if options.sort != RosterSort::Character {
        let flat = sorted_flat_results(groups, options.sort, options.direction);
        display::print_global_move_table(&flat, filter_text);
        return;
    }

    if options.flat {
        let flat = sorted_flat_results(groups, options.sort, options.direction);
        display::print_global_move_table(&flat, filter_text);
        return;
    }

    let borrowed: Vec<(&str, Vec<&Move>)> = groups
        .iter()
        .map(|group| (group.name.as_str(), group.moves.iter().collect()))
        .collect();

    display::print_roster_query_grouped(
        &borrowed,
        filter_text,
        options.per_character_limit,
        total_matches,
    );
}

/// Run a roster-wide filter query and print the result.
pub fn run(
    server: Option<&mut LeanServer>,
    data_dir: &Path,
    manifest: &Manifest,
    filter_text: &str,
    options: RosterQueryOptions,
) -> Result<(), CliError> {
    let filters = parse_filters(filter_text)?;
    if filters.is_empty() {
        return Err(CliError::InvalidFilter(
            "all requires at least one filter".into(),
        ));
    }

    let groups = match server {
        Some(server) => query_with_lean(server, data_dir, manifest, &filters)
            .unwrap_or_else(|_| query_with_rust(data_dir, manifest, &filters)),
        None => query_with_rust(data_dir, manifest, &filters),
    };

    print_results(&groups, filter_text, options);
    Ok(())
}
