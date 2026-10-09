/// Tab completion helpers for the interactive REPL.
///
/// Two completion contexts: the command centre and a selected character.
use rustyline::completion::{Completer, Pair};
use rustyline::highlight::Highlighter;
use rustyline::hint::Hinter;
use rustyline::validate::Validator;
use rustyline::Context;
use rustyline::Helper;

/// All known filter tokens for tab completion.
const FILTER_TOKENS: &[&str] = &[
    "high", "mid", "low", "throw",
    "plus", "minus", "punish", "guardable", "broken",
    "he", "hs", "hb", "heat", "pc", "hom", "trn", "spk",
    "js", "cs", "elb", "kne", "hed", "wpn",
    "bbr", "wbr", "fbr", "rbr", "chp",
    "stance",
    "cmd:", "name:", "note:", "stance:",
    "active",
    "i", "i<", "i<=", "i=", "i>=", "i>",
    "hit>", "hit<", "hit>=", "hit<=", "hit=",
    "ch>", "ch<", "ch>=", "ch<=", "ch=",
    "block>", "block<", "block>=", "block<=", "block=",
];

/// All known alias terms for tab completion.
const ALIAS_TERMS: &[&str] = &[
    "ewgf", "wgf", "dorya", "hellsweep", "hopkick", "dickjab",
    "snakeedge", "orbital", "tombstone", "giantswing",
    "demonspaw", "demonpaw", "rageart", "ragedrive",
    "magic4", "cd", "crouchdash",
];

/// Commands available from the top-level command centre.
const COMMAND_CENTRE_COMMANDS: &[&str] = &[
    "characters", "chars", "list", "overview", "list-all", "query", "broken",
    "aliases", "alias", "unalias", "clear", "help", "quit",
];

/// Presentation modifiers accepted after a roster query.
const ROSTER_MODIFIERS: &[&str] = &[
    "flat", "summary", "limit:", "by:i", "sort:", "order:", "asc", "desc",
];

/// Natural frame-query prefixes accepted at the command centre.
const FRAME_QUERY_PREFIXES: &[&str] = &["hit", "block", "ch", "startup", "i"];

/// REPL helper that provides context-aware tab completion.
pub enum ReplHelper {
    /// Top-level command-centre context.
    CommandCentre {
        /// Character IDs for completion.
        characters: Vec<String>,
    },
    /// Move query context.
    MoveQuery {
        /// Move commands from the loaded character.
        move_commands: Vec<String>,
        /// Unique stance names from the loaded character.
        stances: Vec<String>,
    },
}

/// Find completions matching a prefix from a list of candidates.
fn prefix_matches(prefix: &str, candidates: &[&str]) -> Vec<Pair> {
    let lower = prefix.to_lowercase();
    candidates
        .iter()
        .filter(|c| c.to_lowercase().starts_with(&lower))
        .map(|c| Pair {
            display: (*c).to_string(),
            replacement: (*c).to_string(),
        })
        .collect()
}

/// Find completions matching a prefix from a list of owned strings.
fn prefix_matches_owned(prefix: &str, candidates: &[String]) -> Vec<Pair> {
    let lower = prefix.to_lowercase();
    candidates
        .iter()
        .filter(|c| c.to_lowercase().starts_with(&lower))
        .map(|c| Pair {
            display: c.clone(),
            replacement: c.clone(),
        })
        .collect()
}

impl Completer for ReplHelper {
    type Candidate = Pair;

    fn complete(
        &self,
        line: &str,
        pos: usize,
        _ctx: &Context<'_>,
    ) -> rustyline::Result<(usize, Vec<Pair>)> {
        // Find the start of the current word
        let line_to_cursor = &line[..pos];
        let word_start = line_to_cursor
            .rfind(char::is_whitespace)
            .map_or(0, |i| i + 1);
        let prefix = &line_to_cursor[word_start..];

        if prefix.is_empty() {
            return Ok((pos, Vec::new()));
        }

        let matches = match self {
            Self::CommandCentre { characters } => {
                let first_word = line_to_cursor.split_whitespace().next().unwrap_or("");
                let mut results = if word_start > 0
                    && matches!(first_word, "query" | "all" | "roster")
                {
                    let mut roster = prefix_matches(prefix, FILTER_TOKENS);
                    roster.extend(prefix_matches(prefix, ROSTER_MODIFIERS));
                    roster
                } else if word_start > 0
                    && characters
                        .iter()
                        .any(|character| character.eq_ignore_ascii_case(first_word))
                {
                    let mut character_query = prefix_matches(prefix, FRAME_QUERY_PREFIXES);
                    character_query.extend(prefix_matches(prefix, ALIAS_TERMS));
                    character_query
                } else {
                    let mut centre = prefix_matches(prefix, COMMAND_CENTRE_COMMANDS);
                    centre.extend(prefix_matches(prefix, FRAME_QUERY_PREFIXES));
                    centre.extend(prefix_matches(prefix, ALIAS_TERMS));
                    centre.extend(prefix_matches_owned(prefix, characters));
                    centre
                };
                results.sort_by(|left, right| left.display.cmp(&right.display));
                results.dedup_by(|left, right| left.replacement == right.replacement);
                results
            }
            Self::MoveQuery {
                move_commands,
                stances,
            } => {
                let mut results = prefix_matches(
                    prefix,
                    &[
                        "query", "moves", "list", "stats", "home", "back", "clear", "help",
                        "quit",
                    ],
                );
                results.extend(prefix_matches(prefix, FILTER_TOKENS));
                results.extend(prefix_matches(prefix, ALIAS_TERMS));
                results.extend(prefix_matches_owned(prefix, move_commands));

                // Complete stance: prefix with actual stance names
                if let Some(stance_prefix) = prefix.strip_prefix("stance:") {
                    let stance_completions: Vec<Pair> = stances
                        .iter()
                        .filter(|s| s.to_lowercase().starts_with(&stance_prefix.to_lowercase()))
                        .map(|s| Pair {
                            display: format!("stance:{s}"),
                            replacement: format!("stance:{s}"),
                        })
                        .collect();
                    results.extend(stance_completions);
                }

                results
            }
        };

        Ok((word_start, matches))
    }
}

impl Hinter for ReplHelper {
    type Hint = String;

    fn hint(&self, _line: &str, _pos: usize, _ctx: &Context<'_>) -> Option<String> {
        None
    }
}

impl Highlighter for ReplHelper {}
impl Validator for ReplHelper {}
impl Helper for ReplHelper {}
