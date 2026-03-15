/// Tab completion helpers for the interactive REPL.
///
/// Two completion contexts: character selection and move query.
use rustyline::completion::{Completer, Pair};
use rustyline::highlight::Highlighter;
use rustyline::hint::Hinter;
use rustyline::validate::Validator;
use rustyline::Context;
use rustyline::Helper;

/// All known filter tokens for tab completion.
const FILTER_TOKENS: &[&str] = &[
    "high", "mid", "low", "throw",
    "plus", "minus", "punish", "guardable",
    "he", "hs", "hb", "heat", "pc", "hom", "trn", "spk",
    "js", "cs", "elb", "kne", "hed", "wpn",
    "bbr", "wbr", "fbr", "rbr", "chp",
    "stance",
    "cmd:", "name:", "note:", "stance:",
    "active",
];

/// All known slang terms for tab completion.
const SLANG_TERMS: &[&str] = &[
    "ewgf", "wgf", "dorya", "hellsweep", "hopkick", "dickjab",
    "snakeedge", "orbital", "tombstone", "giantswing",
    "demonspaw", "demonpaw", "rageart", "ragedrive",
    "magic4", "cd", "crouchdash",
];

/// REPL helper that provides context-aware tab completion.
pub enum ReplHelper {
    /// Character selection context.
    CharacterSelect {
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
            Self::CharacterSelect { characters } => {
                let mut results = prefix_matches(prefix, &["list", "help", "quit"]);
                results.extend(prefix_matches_owned(prefix, characters));
                results
            }
            Self::MoveQuery {
                move_commands,
                stances,
            } => {
                let mut results =
                    prefix_matches(prefix, &["stats", "back", "help", "quit"]);
                results.extend(prefix_matches(prefix, FILTER_TOKENS));
                results.extend(prefix_matches(prefix, SLANG_TERMS));
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
