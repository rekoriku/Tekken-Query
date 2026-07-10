/// Interactive REPL for querying Tekken frame data.
///
/// Two-level loop: character selection → move query.
/// On startup, checks for upstream updates and fetches if needed.
/// Uses rustyline for tab completion and command history.
///
/// When the Lean binary is available, filter evaluation is routed
/// through the verified Lean query server. Falls back to Rust-side
/// evaluation if unavailable.
use std::path::Path;

use colored::Colorize;
use rustyline::error::ReadlineError;
use rustyline::Editor;

use crate::aliases::{self, CustomAliases};
use crate::completion::ReplHelper;
use crate::data::Manifest;
use crate::display;
use crate::error::CliError;
use crate::filter::{matches_all, parse_filters};
use crate::lean_server::LeanServer;
use crate::model::{Character, Move};

/// Action returned from the inner character loop.
enum LoopAction {
    /// Go back to character selection.
    Back,
    /// Exit the program.
    Quit,
}

// ── Fuzzy matching ──────────────────────────────────────────────────

/// Compute similarity ratio between two strings (0.0 to 1.0).
///
/// Uses longest common subsequence length as the similarity metric.
/// This avoids the Python `SequenceMatcher` bug where fuzzy results
/// could override exact matches — we always check exact first.
fn similarity(a: &str, b: &str) -> f64 {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    let a_len = a_chars.len();
    let b_len = b_chars.len();

    if a_len == 0 || b_len == 0 {
        return 0.0;
    }

    // LCS via two-row DP
    let mut prev = vec![0u32; b_len + 1];
    let mut curr = vec![0u32; b_len + 1];

    for i in 1..=a_len {
        for j in 1..=b_len {
            if a_chars[i - 1] == b_chars[j - 1] {
                curr[j] = prev[j - 1] + 1;
            } else {
                curr[j] = prev[j].max(curr[j - 1]);
            }
        }
        std::mem::swap(&mut prev, &mut curr);
        curr.fill(0);
    }

    let lcs_len = prev[b_len];
    // Precision loss is acceptable: character names are always short
    #[allow(clippy::cast_precision_loss)]
    let max_len = a_len.max(b_len) as f64;
    f64::from(lcs_len) / max_len
}

/// Minimum similarity threshold for fuzzy matching.
const FUZZY_THRESHOLD: f64 = 0.5;

// ── Character resolution ────────────────────────────────────────────

/// Find a character in the manifest.
///
/// Priority order (never let fuzzy override exact):
/// 1. Exact ID match
/// 2. Exact name match (case-insensitive)
/// 3. Prefix match on ID (e.g., "kaz" → "kazuya")
/// 4. Substring match (unique only)
/// 5. First-word match on display name (e.g., "devil" → "devil-jin")
/// 6. Fuzzy match (highest similarity above threshold)
fn find_character<'a>(
    input: &str,
    manifest: &'a Manifest,
) -> Option<&'a crate::data::CharacterMeta> {
    let lower = input.to_lowercase();

    // 1. Exact ID match
    if let Some(c) = manifest.characters.iter().find(|c| c.id == lower) {
        return Some(c);
    }

    // 2. Exact name match (case-insensitive)
    if let Some(c) = manifest
        .characters
        .iter()
        .find(|c| c.name.to_lowercase() == lower)
    {
        return Some(c);
    }

    // 3. Prefix match on ID
    let prefix_matches: Vec<_> = manifest
        .characters
        .iter()
        .filter(|c| c.id.starts_with(&lower))
        .collect();
    if prefix_matches.len() == 1 {
        return Some(prefix_matches[0]);
    }

    // 4. Substring match on ID or name (unique only)
    let substr_matches: Vec<_> = manifest
        .characters
        .iter()
        .filter(|c| c.id.contains(&lower) || c.name.to_lowercase().contains(&lower))
        .collect();
    if substr_matches.len() == 1 {
        return Some(substr_matches[0]);
    }

    // 5. First-word match on display name
    if let Some(c) = manifest.characters.iter().find(|c| {
        c.name
            .to_lowercase()
            .split_whitespace()
            .next()
            .is_some_and(|first| first == lower)
    }) {
        return Some(c);
    }

    // 6. Fuzzy match (best score above threshold)
    let mut best: Option<(&crate::data::CharacterMeta, f64)> = None;
    for c in &manifest.characters {
        let id_sim = similarity(&lower, &c.id);
        let name_sim = similarity(&lower, &c.name.to_lowercase());
        let score = id_sim.max(name_sim);
        if score >= FUZZY_THRESHOLD
            && best.as_ref().is_none_or(|(_, s)| score > *s)
        {
            best = Some((c, score));
        }
    }
    best.map(|(c, _)| c)
}

/// Load a character's moves from clean CSV.
fn load_character(
    data_dir: &Path,
    meta: &crate::data::CharacterMeta,
) -> Result<Character, CliError> {
    crate::data::load_character(data_dir, &meta.id, &meta.name)
}

// ── Player aliases ──────────────────────────────────────────────────

/// Search criteria for a player alias (community terminology).
struct MoveAlias {
    /// Display label for the alias (shown when resolved).
    label: &'static str,
    /// Command substrings to search for (case-insensitive).
    commands: &'static [&'static str],
    /// Name substrings to search for (case-insensitive).
    names: &'static [&'static str],
}

/// Look up a player alias and return search criteria.
///
/// Returns `None` if the term is not a known alias.
fn lookup_alias(term: &str) -> Option<MoveAlias> {
    let lower = term.to_lowercase();
    match lower.as_str() {
        // Mishima staples
        "ewgf" | "dorya" => Some(MoveAlias {
            label: "Electric Wind God Fist",
            commands: &["f,n,d,df:2"],
            names: &["electric wind god fist", "electric"],
        }),
        "wgf" => Some(MoveAlias {
            label: "Wind God Fist",
            commands: &["f,n,d,df+2"],
            names: &["wind god fist"],
        }),
        "hellsweep" => Some(MoveAlias {
            label: "Hellsweep (crouch dash low)",
            commands: &["f,n,d,DF+4", "f,n,d,df+4"],
            names: &["spinning demon", "hell sweep", "inferno"],
        }),

        // Universal-ish moves
        "hopkick" => Some(MoveAlias {
            label: "Hopkick (uf+4 launcher)",
            commands: &["uf+4"],
            names: &["hop kick", "hopkick"],
        }),
        "dickjab" => Some(MoveAlias {
            label: "Dickjab (d+1 poke)",
            commands: &["d+1"],
            names: &["dickjab", "crouch jab"],
        }),
        "magic4" => Some(MoveAlias {
            label: "Magic 4 (counter-hit launcher)",
            commands: &[],
            names: &["magic 4"],
        }),
        "rageart" => Some(MoveAlias {
            label: "Rage Art",
            commands: &[],
            names: &["rage art"],
        }),
        "ragedrive" => Some(MoveAlias {
            label: "Rage Drive",
            commands: &[],
            names: &["rage drive"],
        }),

        // Character-specific aliases
        "snakeedge" => Some(MoveAlias {
            label: "Snake Edge",
            commands: &[],
            names: &["snake edge"],
        }),
        "orbital" => Some(MoveAlias {
            label: "Orbital Heel",
            commands: &[],
            names: &["orbital"],
        }),
        "tombstone" => Some(MoveAlias {
            label: "Tombstone Pile Driver",
            commands: &[],
            names: &["tombstone"],
        }),
        "giantswing" => Some(MoveAlias {
            label: "Giant Swing",
            commands: &[],
            names: &["giant swing"],
        }),
        "demonspaw" | "demonpaw" => Some(MoveAlias {
            label: "Demon's Paw (f,F+2)",
            commands: &["f,F+2"],
            names: &["demon's paw"],
        }),

        // Crouch dash moves
        "cd" | "crouchdash" => Some(MoveAlias {
            label: "Crouch dash moves",
            commands: &["f,n,d,df", "f,n,d,DF"],
            names: &[],
        }),

        _ => None,
    }
}

/// A resolved alias with owned data (unified across custom and built-in).
struct ResolvedAlias {
    label: String,
    commands: Vec<String>,
    names: Vec<String>,
}

/// Resolve an alias, checking custom aliases first, then built-in.
fn resolve_alias(term: &str, custom: &CustomAliases) -> Option<ResolvedAlias> {
    // Custom aliases take priority
    if let Some(ca) = custom.lookup(term) {
        return Some(ResolvedAlias {
            label: ca.label.clone(),
            commands: ca.commands.clone(),
            names: ca.names.clone(),
        });
    }
    // Fall back to built-in
    lookup_alias(term).map(|a| ResolvedAlias {
        label: a.label.to_string(),
        commands: a.commands.iter().map(|s| (*s).to_string()).collect(),
        names: a.names.iter().map(|s| (*s).to_string()).collect(),
    })
}

/// Check if a move matches a resolved alias.
fn move_matches_alias(m: &Move, alias: &ResolvedAlias) -> bool {
    let cmd_lower = m.command.to_lowercase();
    let name_lower = m.name.to_lowercase();
    alias
        .commands
        .iter()
        .any(|c| cmd_lower.contains(&c.to_lowercase()))
        || alias
            .names
            .iter()
            .any(|n| name_lower.contains(&n.to_lowercase()))
}

// ── Notation normalization ────────────────────────────────────────────

/// Normalize shorthand Tekken notation to match CSV command format.
///
/// Handles common abbreviations users type without `+`:
///   `df2` → `df+2`, `uf4` → `uf+4`, `db1` → `db+1`
///   `b4`  → `b+4`,  `f2`  → `f+2`,  `d1`  → `d+1`
///   `ff2` → `f,F+2`, `bb3` → `b,B+3`
///
/// Returns `None` if the input is already in standard form or
/// doesn't match any known pattern.
fn normalize_notation(input: &str) -> Option<String> {
    let s = input.to_lowercase();

    // Crouch dash shorthand: cd2 → f,n,d,df+2, cd+2 → f,n,d,df+2
    if let Some(rest) = s.strip_prefix("cd") {
        let rest = rest.strip_prefix('+').unwrap_or(rest);
        if rest.starts_with(|c: char| c.is_ascii_digit()) {
            return Some(format!("f,n,d,df+{rest}"));
        }
    }

    // Order matters: compound/double directions before single
    let mappings: &[(&str, &str)] = &[
        ("df", "df+"),
        ("uf", "uf+"),
        ("db", "db+"),
        ("ub", "ub+"),
        ("ff", "f,F+"),
        ("bb", "b,B+"),
        ("f", "f+"),
        ("b", "b+"),
        ("d", "d+"),
        ("u", "u+"),
    ];

    for &(prefix, replacement) in mappings {
        if let Some(rest) = s.strip_prefix(prefix) {
            // Rest must start with a digit (button number)
            if rest.starts_with(|c: char| c.is_ascii_digit()) {
                return Some(format!("{replacement}{rest}"));
            }
        }
    }

    None
}

// ── Move lookup with fuzzy matching ─────────────────────────────────

/// Normalize a command string for comparison.
///
/// Lowercases and strips whitespace.
fn normalize_cmd(s: &str) -> String {
    s.to_lowercase().split_whitespace().collect::<Vec<_>>().join("")
}

/// Check if a normalized command matches either the raw or notation-normalized input.
fn cmd_matches(move_cmd: &str, norm_input: &str, norm_alt: Option<&str>) -> bool {
    let nc = normalize_cmd(move_cmd);
    nc == norm_input || norm_alt.is_some_and(|alt| nc == normalize_cmd(alt))
}

/// Check if a normalized command starts with either the raw or notation-normalized input.
fn cmd_starts_with(move_cmd: &str, norm_input: &str, norm_alt: Option<&str>) -> bool {
    let nc = normalize_cmd(move_cmd);
    nc.starts_with(norm_input) || norm_alt.is_some_and(|alt| nc.starts_with(&normalize_cmd(alt)))
}

/// Check if a normalized command contains either the raw or notation-normalized input.
fn cmd_contains(move_cmd: &str, norm_input: &str, norm_alt: Option<&str>) -> bool {
    let nc = normalize_cmd(move_cmd);
    nc.contains(norm_input) || norm_alt.is_some_and(|alt| nc.contains(&normalize_cmd(alt)))
}

/// Try to find a move by command string.
///
/// Priority: exact > alias > normalized exact > prefix > substring > name > fuzzy.
fn try_move_lookup(character: &Character, input: &str, custom_aliases: &CustomAliases) {
    let norm_input = normalize_cmd(input);
    let notation_alt = normalize_notation(input);
    let alt_ref = notation_alt.as_deref();

    // 1. Exact command match (case-insensitive, tries normalized notation too)
    let exact: Vec<&Move> = character
        .moves
        .iter()
        .filter(|m| cmd_matches(&m.command, &norm_input, alt_ref))
        .collect();
    if !exact.is_empty() {
        for m in &exact {
            eprintln!("{}", display::format_move_detail(m));
        }
        return;
    }

    // 2. Alias lookup (custom first, then built-in)
    if let Some(alias) = resolve_alias(input, custom_aliases) {
        let results: Vec<&Move> = character
            .moves
            .iter()
            .filter(|m| move_matches_alias(m, &alias))
            .collect();
        if results.is_empty() {
            eprintln!("No '{input}' moves for this character");
        } else {
            eprintln!("{} → {}", input, alias.label);
            show_move_table(&results, input);
        }
        return;
    }

    // 3. Prefix match on command (tries normalized notation too)
    let prefix: Vec<&Move> = character
        .moves
        .iter()
        .filter(|m| cmd_starts_with(&m.command, &norm_input, alt_ref))
        .collect();
    if !prefix.is_empty() && prefix.len() <= 20 {
        show_move_table(&prefix, input);
        return;
    }

    // 4. Substring match on command (tries normalized notation too)
    let cmd_substr: Vec<&Move> = character
        .moves
        .iter()
        .filter(|m| cmd_contains(&m.command, &norm_input, alt_ref))
        .collect();
    if !cmd_substr.is_empty() && cmd_substr.len() <= 20 {
        show_move_table(&cmd_substr, input);
        return;
    }

    // 5. Name substring match (case-insensitive)
    let lower = input.to_lowercase();
    let name_match: Vec<&Move> = character
        .moves
        .iter()
        .filter(|m| m.name.to_lowercase().contains(&lower))
        .collect();
    if !name_match.is_empty() {
        show_move_table(&name_match, input);
        return;
    }

    // 6. Fuzzy match on command (best matches)
    let mut scored: Vec<(&Move, f64)> = character
        .moves
        .iter()
        .map(|m| (m, similarity(&norm_input, &normalize_cmd(&m.command))))
        .filter(|(_, score)| *score >= 0.4)
        .collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
    scored.truncate(10);

    if scored.is_empty() {
        eprintln!("No moves matching '{input}'");
    } else {
        let results: Vec<&Move> = scored.iter().map(|(m, _)| *m).collect();
        show_move_table(&results, input);
    }
}

/// Display a table of moves with a match header.
fn show_move_table(moves: &[&Move], query: &str) {
    eprintln!("{} matches for '{query}':", moves.len());
    let cols = display::layout_for(moves);
    display::print_header(&cols);
    for m in moves {
        eprintln!("{}", display::format_move_row(m, &cols));
    }
}

// ── Global move lookup ───────────────────────────────────────────────

/// Check if input looks like a move command rather than a character name.
///
/// Heuristics: contains digits, `+`, or is a known alias.
fn looks_like_move_input(input: &str, custom_aliases: &CustomAliases) -> bool {
    if input.chars().any(|c| c.is_ascii_digit()) {
        return true;
    }
    if input.contains('+') {
        return true;
    }
    resolve_alias(input, custom_aliases).is_some()
}

/// Look up a move command across all characters.
///
/// Used from the character select screen to compare a specific move
/// (e.g., `df1`) across the entire roster.
fn global_move_lookup(
    data_dir: &Path,
    manifest: &Manifest,
    input: &str,
    custom_aliases: &CustomAliases,
) {
    let norm_input = normalize_cmd(input);
    let notation_alt = normalize_notation(input);
    let alt_ref = notation_alt.as_deref();
    let resolved = resolve_alias(input, custom_aliases);

    if let Some(ref alias) = resolved {
        eprintln!("{input} → {}", alias.label);
    }

    let characters: Vec<Character> = manifest
        .characters
        .iter()
        .filter_map(|meta| load_character(data_dir, meta).ok())
        .collect();

    let mut found: Vec<(&str, &Move)> = Vec::new();

    for character in &characters {
        for m in &character.moves {
            let is_match = cmd_matches(&m.command, &norm_input, alt_ref)
                || resolved
                    .as_ref()
                    .is_some_and(|alias| move_matches_alias(m, alias));

            if is_match {
                found.push((&character.name, m));
            }
        }
    }

    if found.is_empty() {
        eprintln!("No character has a move matching '{input}'");
        return;
    }

    display::print_global_move_table(&found, input);
}

/// Print character overview stats (list-all).
///
/// Shows per-character: plus-on-block count, plus-on-hit lows count,
/// and heat smash startup.
fn cmd_list_all(data_dir: &Path, manifest: &Manifest) {
    let mut overviews: Vec<display::CharOverview> = Vec::new();

    for meta in &manifest.characters {
        let Ok(character) = load_character(data_dir, meta) else {
            continue;
        };

        let plus_on_block = character.moves.iter().filter(|m| m.is_plus()).count();
        let plus_on_hit_lows = character
            .moves
            .iter()
            .filter(|m| m.is_low() && m.is_plus_on_hit())
            .count();

        // Collect ALL heat smashes — some characters have 2.
        // Multi-hit moves can have concatenated startup values (data issue),
        // so filter to sane values (<=100 frames for both startup and end).
        let hs_startups: Vec<String> = character
            .moves
            .iter()
            .filter(|m| {
                m.has_tag("hs")
                    && m.startup.is_some_and(|s| s <= 100)
                    && m.startup_end.is_none_or(|e| e <= 100)
            })
            .map(Move::startup_display)
            .collect();
        // Deduplicate (some characters have identical HS startups)
        let mut unique_hs: Vec<String> = Vec::new();
        for s in &hs_startups {
            if !unique_hs.contains(s) {
                unique_hs.push(s.clone());
            }
        }
        let hs_startup = if unique_hs.is_empty() {
            "?".to_string()
        } else {
            unique_hs.join(" / ")
        };

        overviews.push(display::CharOverview {
            name: character.name,
            plus_on_block,
            plus_on_hit_lows,
            hs_startup,
        });
    }

    display::print_character_overview(&overviews);
}

// ── Help text ───────────────────────────────────────────────────────

/// Print the character list.
fn print_character_list(manifest: &Manifest) {
    eprintln!(
        "{}",
        format!("Characters ({}):", manifest.characters.len()).bold()
    );
    for c in &manifest.characters {
        eprintln!("  {:<16} {:<20} {} moves", c.id, c.name, c.moves);
    }
}

/// Print help for the character selection screen.
fn print_char_help() {
    eprintln!("{}", "Commands:".bold());
    eprintln!("  <name>     Select a character (fuzzy match: jin, kaz, devil, yoshi...)");
    eprintln!("  <move>     Look up a move across all characters (df1, ewgf, hopkick...)");
    eprintln!("  all <filters>  Query moves across all characters (all pc, all i<15 hom)");
    eprintln!("               Options: limit:N, flat, summary, by:i asc|desc");
    eprintln!("  list       Show all characters");
    eprintln!("  list-all   Character overview (+OB, +OH lows, HS startup)");
    eprintln!();
    eprintln!("{}", "Aliases:".bold());
    eprintln!("  alias <name> cmd:<pattern> [name:<pattern>]");
    eprintln!("               Create a custom move alias");
    eprintln!("  unalias <name>  Remove a custom alias");
    eprintln!("  aliases    List custom aliases");
    eprintln!();
    eprintln!("  quit       Exit");
}

/// Print help for the move query screen.
fn print_query_help() {
    eprintln!("{}", "Filter tokens (AND'd together):".bold());
    eprintln!("  {:<20} hit level", "high, mid, low");
    eprintln!("  {:<20} block frame category", "plus, minus, punish");
    eprintln!("  {:<20} startup frames", "i15, i=15, i<15, i>=15");
    eprintln!("  {:<20} block frames", "<0, <=-10, =0, block>=+3");
    eprintln!("  {:<20} hit / CH frames", "hit>0, hit=0, ch>=5");
    eprintln!("  {:<20} move tags", "hom, pc, he, hs, heat, trn");
    eprintln!("  {:<20} stance moves", "stance, stance:ZEN");
    eprintln!(
        "  {:<20} substring search",
        "cmd:df+2, name:kick, note:crush"
    );
    eprintln!("  {:<20} negate any filter", "!punish, !hom");
    eprintln!();
    eprintln!("{}", "Move lookup:".bold());
    eprintln!("  <command>  Look up a move (df2, uf4, ws4, b+1+2...)");
    eprintln!("  <alias>    Move aliases:");
    eprintln!("             ewgf, wgf, hellsweep, hopkick, dickjab,");
    eprintln!("             snakeedge, orbital, tombstone, giantswing,");
    eprintln!("             demonspaw, rageart, cd, magic4");
    eprintln!();
    eprintln!("{}", "Notation shortcuts:".bold());
    eprintln!("  df2 → df+2, uf4 → uf+4, ff2 → f,F+2, b4 → b+4");
    eprintln!();
    eprintln!("{}", "Aliases:".bold());
    eprintln!("  alias <name> cmd:<pattern> [name:<pattern>]");
    eprintln!("               Create a custom move alias");
    eprintln!("  unalias <name>  Remove a custom alias");
    eprintln!("  aliases    List custom aliases");
    eprintln!();
    eprintln!("{}", "Other:".bold());
    eprintln!("  list       Show full movelist");
    eprintln!("  stats      Show character stats");
    eprintln!("  back       Return to character selection");
    eprintln!("  quit       Exit");
}

// ── REPL loops ──────────────────────────────────────────────────────

/// Build a `MoveQuery` helper for a loaded character.
fn make_query_helper(character: &Character) -> ReplHelper {
    let move_commands = character.moves.iter().map(|m| m.command.clone()).collect();
    let mut seen = std::collections::HashSet::new();
    let stances = character
        .moves
        .iter()
        .filter(|m| !m.stance.is_empty())
        .filter_map(|m| {
            if seen.insert(m.stance.clone()) {
                Some(m.stance.clone())
            } else {
                None
            }
        })
        .collect();

    ReplHelper::MoveQuery {
        move_commands,
        stances,
    }
}

/// Read a line from the editor, handling Ctrl-C and Ctrl-D.
///
/// Returns `Ok(Some(line))` on input, `Ok(None)` on EOF/quit.
fn read_line(
    rl: &mut Editor<ReplHelper, rustyline::history::DefaultHistory>,
    prompt: &str,
) -> Result<Option<String>, CliError> {
    loop {
        match rl.readline(prompt) {
            Ok(line) => {
                let trimmed = line.trim().to_string();
                if trimmed.is_empty() {
                    continue;
                }
                if let Err(e) = rl.add_history_entry(&trimmed) {
                    eprintln!("history: {e}");
                }
                return Ok(Some(trimmed));
            }
            Err(ReadlineError::Interrupted) => {}
            Err(ReadlineError::Eof) => return Ok(None),
            Err(e) => return Err(CliError::IoError(format!("readline: {e}"))),
        }
    }
}

/// Execute a filter query using the Lean server if available, falling back to Rust.
///
/// Returns owned moves from the server or references to local moves.
/// Either way, displays results using the same layout/format pipeline.
fn run_query(
    server: Option<&mut LeanServer>,
    character: &Character,
    input: &str,
) -> Result<(), CliError> {
    let filters = parse_filters(input)?;
    if filters.is_empty() {
        return Ok(());
    }

    // Try Lean server first (verified evaluation)
    if let Some(srv) = server {
        match srv.query(&character.id, &filters) {
            Ok(qr) => {
                eprintln!(
                    "{} matches (out of {})",
                    qr.count,
                    qr.total,
                );
                if !qr.moves.is_empty() {
                    let refs: Vec<&Move> = qr.moves.iter().collect();
                    let cols = display::layout_for(&refs);
                    display::print_header(&cols);
                    for m in &refs {
                        eprintln!("{}", display::format_move_row(m, &cols));
                    }
                }
                return Ok(());
            }
            Err(e) => return Err(e),
        }
    }

    // Fallback: Rust-side evaluation (unverified)
    let results: Vec<&Move> = character
        .moves
        .iter()
        .filter(|m| matches_all(m, &filters))
        .collect();

    eprintln!(
        "{} matches (out of {})",
        results.len(),
        character.moves.len()
    );

    if !results.is_empty() {
        let cols = display::layout_for(&results);
        display::print_header(&cols);
        for m in &results {
            eprintln!("{}", display::format_move_row(m, &cols));
        }
    }
    Ok(())
}

/// Run the inner move query loop for a selected character.
fn character_loop(
    rl: &mut Editor<ReplHelper, rustyline::history::DefaultHistory>,
    character: &Character,
    server: &mut Option<LeanServer>,
    custom_aliases: &mut CustomAliases,
    data_dir: &Path,
) -> Result<LoopAction, CliError> {
    eprintln!(
        "\n{} ({} moves)",
        character.name.bold(),
        character.moves.len()
    );

    rl.set_helper(Some(make_query_helper(character)));
    let prompt_str = format!("{} > ", character.name.green());

    loop {
        let Some(input) = read_line(rl, &prompt_str)? else {
            return Ok(LoopAction::Quit);
        };

        match input.as_str() {
            "quit" | "q" | "exit" => return Ok(LoopAction::Quit),
            "back" | "b" | "new" => return Ok(LoopAction::Back),
            "help" | "?" => {
                print_query_help();
                continue;
            }
            "stats" => {
                display::print_character_stats(&character.name, &character.moves);
                continue;
            }
            "list" | "ls" | "all" => {
                let refs: Vec<&Move> = character.moves.iter().collect();
                eprintln!("{} — {} moves", character.name.bold(), refs.len());
                let cols = display::layout_for(&refs);
                display::print_header(&cols);
                for m in &refs {
                    eprintln!("{}", display::format_move_row(m, &cols));
                }
                continue;
            }
            "aliases" => {
                print_aliases(custom_aliases);
                continue;
            }
            _ => {}
        }

        // Alias management commands
        if let Some(rest) = input.strip_prefix("alias ") {
            handle_alias_add(rest.trim(), custom_aliases, data_dir);
            continue;
        }
        if let Some(rest) = input.strip_prefix("unalias ") {
            handle_alias_remove(rest.trim(), custom_aliases, data_dir);
            continue;
        }

        // Try as filter query first
        match parse_filters(&input) {
            Ok(filters) if !filters.is_empty() => {
                drop(filters); // parsed only to check validity
                if let Err(e) = run_query(server.as_mut(), character, &input) {
                    eprintln!("{e}");
                }
            }
            _ => {
                // Try as move command lookup (with fuzzy)
                try_move_lookup(character, &input, custom_aliases);
            }
        }
    }
}

/// Try to start the Lean query server.
///
/// Returns `None` if the binary is not found — the REPL will fall back
/// to Rust-side filter evaluation.
fn try_start_server(data_dir: &Path) -> Option<LeanServer> {
    if let Ok(server) = LeanServer::start(data_dir) {
        eprintln!("Lean query server started (verified filter evaluation)");
        Some(server)
    } else {
        eprintln!("Lean binary not found — using local filter evaluation");
        eprintln!("  (run 'lake build' in the project root for verified queries)");
        None
    }
}

/// Load a character on the Lean server, returning success/failure.
fn server_load_character(
    server: &mut LeanServer,
    data_dir: &Path,
    meta: &crate::data::CharacterMeta,
) -> bool {
    let csv_path = data_dir.join("clean").join(format!("{}.csv", meta.id));
    match server.load_character(&meta.id, &meta.name, &csv_path) {
        Ok(n) => {
            eprintln!("  (server: {n} moves loaded)");
            true
        }
        Err(e) => {
            eprintln!("  server load failed: {e} (using local fallback)");
            false
        }
    }
}

// ── Alias management ─────────────────────────────────────────────────

/// Handle `alias <name> cmd:<pattern> [name:<pattern>]`.
fn handle_alias_add(args: &str, custom_aliases: &mut CustomAliases, data_dir: &Path) {
    match aliases::parse_alias_command(args) {
        Ok((name, alias)) => {
            eprintln!("Alias '{}' → {}", name, alias.label);
            if !alias.commands.is_empty() {
                eprintln!("  commands: {}", alias.commands.join(", "));
            }
            if !alias.names.is_empty() {
                eprintln!("  names: {}", alias.names.join(", "));
            }
            custom_aliases.add(&name, alias);
            if let Err(e) = custom_aliases.save(data_dir) {
                eprintln!("warning: failed to save aliases: {e}");
            }
        }
        Err(e) => eprintln!("{e}"),
    }
}

/// Handle `unalias <name>`.
fn handle_alias_remove(name: &str, custom_aliases: &mut CustomAliases, data_dir: &Path) {
    if name.is_empty() {
        eprintln!("usage: unalias <name>");
        return;
    }
    if custom_aliases.remove(name) {
        eprintln!("Removed alias '{name}'");
        if let Err(e) = custom_aliases.save(data_dir) {
            eprintln!("warning: failed to save aliases: {e}");
        }
    } else {
        eprintln!("No custom alias '{name}'");
    }
}

/// Print all custom aliases.
fn print_aliases(custom_aliases: &CustomAliases) {
    if custom_aliases.len() == 0 {
        eprintln!("No custom aliases. Add one with: alias <name> cmd:<pattern>");
        return;
    }
    eprintln!("Custom aliases ({}):", custom_aliases.len());
    for (name, alias) in custom_aliases.iter() {
        let mut parts = Vec::new();
        for c in &alias.commands {
            parts.push(format!("cmd:{c}"));
        }
        for n in &alias.names {
            parts.push(format!("name:{n}"));
        }
        eprintln!("  {:<16} {} [{}]", name, alias.label, parts.join(" "));
    }
}

/// Handle `all <filters...>` / `roster <filters...>` at character select.
fn handle_roster_query(
    server: Option<&mut LeanServer>,
    data_dir: &Path,
    manifest: &Manifest,
    input: &str,
) -> bool {
    let Some(rest) = input
        .strip_prefix("all ")
        .or_else(|| input.strip_prefix("roster "))
    else {
        return false;
    };

    match crate::roster_query::parse_interactive_options(rest.trim()) {
        Ok((options, filter_text)) => {
            if let Err(e) =
                crate::roster_query::run(server, data_dir, manifest, &filter_text, options)
            {
                eprintln!("{e}");
            }
        }
        Err(e) => eprintln!("{e}"),
    }
    true
}

/// Initialize the REPL: start server, check updates, load manifest.
///
/// Returns the server, manifest, and whether data was updated.
fn init_repl(
    data_dir: &Path,
) -> Result<(Option<LeanServer>, Manifest, bool), CliError> {
    eprintln!("{}", "Tekken 8 Frame Data Query".bold());
    eprintln!();

    // Start the Lean query server BEFORE update check so it can handle
    // raw → clean conversion during fetch (faster than spawning per-character)
    let mut server = try_start_server(data_dir);

    // Check for updates and load manifest (uses server for conversion if available)
    let (manifest, updated) =
        crate::fetch::update_if_needed(data_dir, server.as_mut())?;

    if updated {
        eprintln!();
    }
    eprintln!(
        "{} characters loaded ({})\n",
        manifest.characters.len(),
        manifest.updated
    );

    Ok((server, manifest, updated))
}

/// Run the interactive REPL.
///
/// On startup: checks for upstream data updates and fetches if needed.
/// Tries to start the Lean query server for verified filter evaluation.
/// Then enters a two-level loop: character selection → move query.
/// Uses rustyline for tab completion and command history.
pub fn run_interactive(data_dir: &Path) -> Result<(), CliError> {
    let (mut server, manifest, _updated) = init_repl(data_dir)?;

    // Load custom aliases
    let mut custom_aliases = CustomAliases::load(data_dir);

    // Set up rustyline editor
    let mut rl = Editor::<ReplHelper, rustyline::history::DefaultHistory>::new()
        .map_err(|e| CliError::IoError(format!("readline init: {e}")))?;

    let history_path = data_dir.join(".tekken_history");
    // History file may not exist yet on first run
    let _ = rl.load_history(&history_path);

    let char_helper = ReplHelper::CharacterSelect {
        characters: manifest.characters.iter().map(|c| c.id.clone()).collect(),
    };
    rl.set_helper(Some(char_helper));

    // Character selection loop
    while let Some(input) = read_line(&mut rl, "Character? > ")? {
        match input.as_str() {
            "quit" | "q" | "exit" => break,
            "list" | "ls" => {
                print_character_list(&manifest);
                continue;
            }
            "list-all" | "la" => {
                cmd_list_all(data_dir, &manifest);
                continue;
            }
            "help" | "?" => {
                print_char_help();
                continue;
            }
            "aliases" => {
                print_aliases(&custom_aliases);
                continue;
            }
            _ => {}
        }

        // Alias management commands (available from character select too)
        if let Some(rest) = input.strip_prefix("alias ") {
            handle_alias_add(rest.trim(), &mut custom_aliases, data_dir);
            continue;
        }
        if let Some(rest) = input.strip_prefix("unalias ") {
            handle_alias_remove(rest.trim(), &mut custom_aliases, data_dir);
            continue;
        }

        if handle_roster_query(server.as_mut(), data_dir, &manifest, &input) {
            continue;
        }

        // Find character (with fuzzy matching)
        let Some(meta) = find_character(&input, &manifest) else {
            // If it looks like a move command, do a global lookup
            if looks_like_move_input(&input, &custom_aliases) {
                global_move_lookup(data_dir, &manifest, &input, &custom_aliases);
                continue;
            }

            // Show close matches
            let lower = input.to_lowercase();
            let suggestions: Vec<_> = manifest
                .characters
                .iter()
                .filter(|c| {
                    c.id.contains(&lower) || c.name.to_lowercase().contains(&lower)
                })
                .collect();

            if suggestions.is_empty() {
                eprintln!("Unknown character '{input}'. Type 'list' to see all.");
            } else {
                eprintln!("Did you mean:");
                for s in &suggestions {
                    eprintln!("  {} ({})", s.id, s.name);
                }
            }
            continue;
        };

        // Load character data locally (for fuzzy matching, tab completion, move lookup)
        let character = match load_character(data_dir, meta) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Failed to load {}: {e}", meta.id);
                continue;
            }
        };

        // Also load on Lean server for verified queries
        if let Some(ref mut srv) = server
            && !server_load_character(srv, data_dir, meta)
        {
            server = None;
        }

        // Enter character query loop
        match character_loop(&mut rl, &character, &mut server, &mut custom_aliases, data_dir)? {
            LoopAction::Back => {
                // Restore character selection completer
                let char_helper = ReplHelper::CharacterSelect {
                    characters: manifest
                        .characters
                        .iter()
                        .map(|c| c.id.clone())
                        .collect(),
                };
                rl.set_helper(Some(char_helper));
            }
            LoopAction::Quit => break,
        }
    }

    // Shut down Lean server gracefully
    if let Some(srv) = server {
        srv.quit();
    }

    // Save history (ignore errors — non-critical)
    let _ = rl.save_history(&history_path);

    Ok(())
}
