/// Roster-wide filter queries.
///
/// This keeps roster-wide queries on the same parser/evaluator path as
/// character queries, so math-style filters behave consistently everywhere.
use std::path::Path;

use crate::data::Manifest;
use crate::display;
use crate::error::CliError;
use crate::filter::parse_filters;
use crate::lean_server::LeanServer;
use crate::model::Move;

struct RosterGroup {
    name: String,
    moves: Vec<Move>,
}

/// User interface that initiated a roster query.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum QueryOrigin {
    /// One-shot shell command.
    CommandLine,
    /// Interactive REPL command.
    Interactive,
}

impl QueryOrigin {
    /// Return the unlimited-results syntax valid for this interface.
    fn unlimited_rows_command(self) -> &'static str {
        match self {
            Self::CommandLine => "--limit 0",
            Self::Interactive => "limit:0",
        }
    }
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
/// `query pc limit:0`, `query pc by:i asc`, `query heat summary`.
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
    if input
        .split_whitespace()
        .any(|token| token == "--limit" || token.starts_with("--limit="))
    {
        return Err(CliError::InvalidFilter(
            "use limit:N in the REPL; for all rows, use limit:0".into(),
        ));
    }
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

fn print_results(
    groups: &[RosterGroup],
    filter_text: &str,
    options: RosterQueryOptions,
    origin: QueryOrigin,
) {
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
        origin.unlimited_rows_command(),
    );
}

/// Run a roster-wide filter query and print the result.
pub fn run(
    server: &mut LeanServer,
    data_dir: &Path,
    manifest: &Manifest,
    filter_text: &str,
    options: RosterQueryOptions,
    origin: QueryOrigin,
) -> Result<(), CliError> {
    let filters = parse_filters(filter_text)?;
    if filters.is_empty() {
        return Err(CliError::InvalidFilter(
            "roster query requires at least one filter".into(),
        ));
    }

    let groups = query_with_lean(server, data_dir, manifest, &filters)?;

    print_results(&groups, filter_text, options, origin);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{parse_interactive_options, QueryOrigin};

    #[test]
    fn limit_hints_match_the_query_interface() {
        assert_eq!(QueryOrigin::CommandLine.unlimited_rows_command(), "--limit 0");
        assert_eq!(QueryOrigin::Interactive.unlimited_rows_command(), "limit:0");
    }

    #[test]
    fn repl_rejects_shell_limit_syntax_with_repl_guidance() {
        let result = parse_interactive_options("block=-14 --limit 0");
        assert!(result.is_err_and(|error| error.to_string().contains("use limit:0")));
    }
}
