/// Filter engine for querying moves.
/// Parses human-readable filter strings into composable predicates.
use crate::error::CliError;
use crate::model::Move;

/// Which frame data field to compare.
#[derive(Debug, Clone, Copy)]
pub enum FrameField {
    /// Block frame value.
    Block,
    /// Hit frame value.
    Hit,
    /// Counter hit frame value.
    CounterHit,
}

/// Comparison operator for frame data.
#[derive(Debug, Clone, Copy)]
pub enum CompareOp {
    /// Less than.
    Lt,
    /// Less than or equal.
    Le,
    /// Equal.
    Eq,
    /// Greater than or equal.
    Ge,
    /// Greater than.
    Gt,
}

/// A filter that can be applied to a move.
#[derive(Debug, Clone)]
pub enum Filter {
    /// Hit level starts with this prefix (case-insensitive).
    HitLevel(String),
    /// Move is a throw (hit level contains "t").
    Throw,
    /// Plus on block (block frame > 0).
    Plus,
    /// Negative but not punishable (-1 to -9).
    Negative,
    /// Punishable (block frame <= -10).
    Punishable,
    /// Block frame is guardable (g suffix).
    Guardable,
    /// Startup faster than N frames.
    StartupLt(i64),
    /// Startup at most N frames.
    StartupLe(i64),
    /// Startup exactly N frames.
    StartupEq(i64),
    /// Startup at least N frames.
    StartupGe(i64),
    /// Has a specific tag (e.g., "he", "pc", "hom").
    Tag(String),
    /// Move has at least N active frames.
    ActiveGe(i64),
    /// Move is from a specific stance.
    Stance(String),
    /// Move has a stance (any).
    HasStance,
    /// Command contains substring.
    CommandContains(String),
    /// Name contains substring.
    NameContains(String),
    /// Notes contain substring.
    NoteContains(String),
    /// Frame data comparison (block/hit/counter-hit × lt/le/eq/ge/gt).
    FrameCompare(FrameField, CompareOp, i64),
    /// Heat move: heat engager/smash/burst OR heat-state move (H. prefix).
    HeatMove,
    /// Negate a filter.
    Not(Box<Filter>),
}

/// Parse the leading signed integer from a frame string like "+5", "-10", "+13a (+4)".
///
/// Handles optional `+` prefix and stops at first non-digit after sign.
fn parse_frame_value(s: &str) -> Option<i64> {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return None;
    }
    let stripped = trimmed.strip_prefix('+').unwrap_or(trimmed);
    stripped
        .chars()
        .take_while(|c| *c == '-' || c.is_ascii_digit())
        .collect::<String>()
        .parse::<i64>()
        .ok()
}

/// Evaluate a comparison operator.
fn eval_compare(op: CompareOp, actual: i64, threshold: i64) -> bool {
    match op {
        CompareOp::Lt => actual < threshold,
        CompareOp::Le => actual <= threshold,
        CompareOp::Eq => actual == threshold,
        CompareOp::Ge => actual >= threshold,
        CompareOp::Gt => actual > threshold,
    }
}

impl Filter {
    /// Evaluate this filter against a move.
    pub fn matches(&self, m: &Move) -> bool {
        match self {
            Self::HitLevel(level) => m.hit_level.to_lowercase().starts_with(&level.to_lowercase()),
            Self::Throw => m.hit_level.to_lowercase().contains('t'),
            Self::Plus => m.is_plus(),
            Self::Negative => m.block_frame.is_some_and(|v| (-9..0).contains(&v)),
            Self::Punishable => m.is_punishable(),
            Self::Guardable => m.is_guardable(),
            Self::StartupLt(n) => m.startup.is_some_and(|s| s < *n),
            Self::StartupLe(n) => m.startup.is_some_and(|s| s <= *n),
            Self::StartupEq(n) => m.startup.is_some_and(|s| s == *n),
            Self::StartupGe(n) => m.startup.is_some_and(|s| s >= *n),
            Self::Tag(tag) => m.has_tag(tag),
            Self::ActiveGe(n) => m.active_frames.is_some_and(|a| a >= *n),
            Self::Stance(name) => m.stance.eq_ignore_ascii_case(name),
            Self::HasStance => !m.stance.is_empty(),
            Self::CommandContains(q) => m.command.to_lowercase().contains(&q.to_lowercase()),
            Self::NameContains(q) => m.name.to_lowercase().contains(&q.to_lowercase()),
            Self::NoteContains(q) => m.notes.to_lowercase().contains(&q.to_lowercase()),
            Self::HeatMove => {
                m.has_tag("he") || m.has_tag("hs") || m.has_tag("hb")
                    || m.command.starts_with("H.")
            }
            Self::FrameCompare(field, op, value) => {
                let actual = match field {
                    FrameField::Block => m.block_frame,
                    FrameField::Hit => parse_frame_value(&m.hit_frame),
                    FrameField::CounterHit => parse_frame_value(&m.counter_hit_frame),
                };
                actual.is_some_and(|a| eval_compare(*op, a, *value))
            }
            Self::Not(inner) => !inner.matches(m),
        }
    }
}

/// Parse a single filter token from user input.
///
/// Supported tokens:
///   `high`, `mid`, `low`       — hit level prefix
///   `throw`                    — is throw
///   `plus`, `minus`, `punish`  — block frame categories
///   `guard`/`guardable`        — guardable block frame
///   `i15`, `i<15`, `i>15`, `i<=15`, `i>=15` — startup filters
///   `he`, `hs`, `hb`, `pc`, `hom`, `trn`, etc. — tag codes
///   `active3+`                 — active frames >= 3
///   `stance:ZEN`               — specific stance
///   `stance`                   — any stance move
///   `cmd:df+2`                 — command contains
///   `name:uppercut`            — name contains
///   `note:crush`               — notes contain
///   `!<filter>`                — negate
pub fn parse_filter(token: &str) -> Result<Vec<Filter>, CliError> {
    // Handle negation prefix
    if let Some(rest) = token.strip_prefix('!') {
        let inner = parse_filter(rest)?;
        return Ok(inner.into_iter().map(|f| Filter::Not(Box::new(f))).collect());
    }

    let lower = token.to_lowercase();

    match lower.as_str() {
        "high" | "h" => Ok(vec![Filter::HitLevel("h".into())]),
        "mid" | "m" => Ok(vec![Filter::HitLevel("m".into())]),
        "low" | "l" => Ok(vec![Filter::HitLevel("l".into())]),
        "throw" | "t" => Ok(vec![Filter::Throw]),
        "plus" => Ok(vec![Filter::Plus]),
        "minus" | "negative" | "neg" => Ok(vec![Filter::Negative]),
        "punish" | "punishable" => Ok(vec![Filter::Punishable]),
        "guard" | "guardable" => Ok(vec![Filter::Guardable]),
        "stance" => Ok(vec![Filter::HasStance]),
        // Tag codes
        "he" | "heatengager" => Ok(vec![Filter::Tag("he".into())]),
        "hs" | "heatsmash" => Ok(vec![Filter::Tag("hs".into())]),
        "hb" | "heatburst" => Ok(vec![Filter::Tag("hb".into())]),
        "heat" => Ok(vec![Filter::HeatMove]),
        "pc" | "powercrush" => Ok(vec![Filter::Tag("pc".into())]),
        "hom" | "homing" => Ok(vec![Filter::Tag("hom".into())]),
        "trn" | "tornado" => Ok(vec![Filter::Tag("trn".into())]),
        "spk" | "spike" => Ok(vec![Filter::Tag("spk".into())]),
        "js" | "jumpstatus" => Ok(vec![Filter::Tag("js".into())]),
        "cs" | "crouchstatus" => Ok(vec![Filter::Tag("cs".into())]),
        "elb" | "elbow" => Ok(vec![Filter::Tag("elb".into())]),
        "kne" | "knee" => Ok(vec![Filter::Tag("kne".into())]),
        "hed" | "headbutt" => Ok(vec![Filter::Tag("hed".into())]),
        "wpn" | "weapon" => Ok(vec![Filter::Tag("wpn".into())]),
        "bbr" | "balconybreak" => Ok(vec![Filter::Tag("bbr".into())]),
        "wbr" | "wallbreak" => Ok(vec![Filter::Tag("wbr".into())]),
        "fbr" | "floorbreak" => Ok(vec![Filter::Tag("fbr".into())]),
        "rbr" | "reversalbreak" => Ok(vec![Filter::Tag("rbr".into())]),
        "chp" | "chipdamage" => Ok(vec![Filter::Tag("chp".into())]),
        _ => parse_parameterized_filter(&lower),
    }
}

/// Parse filters that take parameters (startup, active, stance:, cmd:, etc.).
fn parse_parameterized_filter(token: &str) -> Result<Vec<Filter>, CliError> {
    // Startup filters: i15, i<15, i>=15, etc.
    if let Some(rest) = token.strip_prefix('i') {
        return parse_startup_filter(rest);
    }

    // Hit frame comparison: hit>0, hit<5, hit<=0, hit>=5, hit=0
    if let Some(rest) = token.strip_prefix("hit") {
        return parse_frame_compare(rest, FrameField::Hit, token);
    }

    // Counter-hit frame comparison: ch>0, ch<5, ch<=0, ch>=5, ch=0
    if let Some(rest) = token.strip_prefix("ch") {
        return parse_frame_compare(rest, FrameField::CounterHit, token);
    }

    // Block frame comparison: block>0, block<5
    if let Some(rest) = token.strip_prefix("block") {
        return parse_frame_compare(rest, FrameField::Block, token);
    }

    // Bare comparison operators → block frame (most common use):
    // <+5, >-10, <=0, >=+3, =0
    if token.starts_with('<') || token.starts_with('>') || token.starts_with('=') {
        return parse_frame_compare(token, FrameField::Block, token);
    }

    // Active frames: active3+, active2
    if let Some(rest) = token.strip_prefix("active") {
        let rest = rest.trim_end_matches('+');
        let n: i64 = rest
            .parse()
            .map_err(|_| CliError::InvalidFilter(format!("bad active frames: {token}")))?;
        return Ok(vec![Filter::ActiveGe(n)]);
    }

    // Prefixed filters: stance:X, cmd:X, name:X, note:X
    if let Some(name) = token.strip_prefix("stance:") {
        return Ok(vec![Filter::Stance(name.to_string())]);
    }
    if let Some(q) = token.strip_prefix("cmd:") {
        return Ok(vec![Filter::CommandContains(q.to_string())]);
    }
    if let Some(q) = token.strip_prefix("name:") {
        return Ok(vec![Filter::NameContains(q.to_string())]);
    }
    if let Some(q) = token.strip_prefix("note:") {
        return Ok(vec![Filter::NoteContains(q.to_string())]);
    }

    Err(CliError::InvalidFilter(format!("unknown filter: {token}")))
}

/// Parse a frame comparison expression: `<+5`, `>=0`, `<=-10`, `=0`, `>+3`.
///
/// Extracts the operator and signed value from the expression.
fn parse_frame_compare(
    expr: &str,
    field: FrameField,
    original: &str,
) -> Result<Vec<Filter>, CliError> {
    let err = || CliError::InvalidFilter(format!("bad frame comparison: {original}"));

    let (op, rest) = if let Some(r) = expr.strip_prefix("<=") {
        (CompareOp::Le, r)
    } else if let Some(r) = expr.strip_prefix(">=") {
        (CompareOp::Ge, r)
    } else if let Some(r) = expr.strip_prefix('<') {
        (CompareOp::Lt, r)
    } else if let Some(r) = expr.strip_prefix('>') {
        (CompareOp::Gt, r)
    } else if let Some(r) = expr.strip_prefix('=') {
        (CompareOp::Eq, r)
    } else {
        return Err(err());
    };

    // Parse signed value: +5, -10, 0
    let value_str = rest.strip_prefix('+').unwrap_or(rest);
    let value: i64 = value_str.parse().map_err(|_| err())?;

    Ok(vec![Filter::FrameCompare(field, op, value)])
}

/// Parse startup frame comparison: `15` → eq, `<15` → lt, `>=15` → ge, etc.
fn parse_startup_filter(s: &str) -> Result<Vec<Filter>, CliError> {
    let err = || CliError::InvalidFilter(format!("bad startup filter: i{s}"));

    if let Some(rest) = s.strip_prefix("<=") {
        let n: i64 = rest.parse().map_err(|_| err())?;
        Ok(vec![Filter::StartupLe(n)])
    } else if let Some(rest) = s.strip_prefix(">=") {
        let n: i64 = rest.parse().map_err(|_| err())?;
        Ok(vec![Filter::StartupGe(n)])
    } else if let Some(rest) = s.strip_prefix('<') {
        let n: i64 = rest.parse().map_err(|_| err())?;
        Ok(vec![Filter::StartupLt(n)])
    } else if let Some(rest) = s.strip_prefix('>') {
        let n: i64 = rest.parse().map_err(|_| err())?;
        Ok(vec![Filter::StartupGe(n + 1)])
    } else {
        let n: i64 = s.parse().map_err(|_| err())?;
        Ok(vec![Filter::StartupEq(n)])
    }
}

/// Parse a full filter string (space-separated tokens, AND'd together).
pub fn parse_filters(input: &str) -> Result<Vec<Filter>, CliError> {
    let mut filters = Vec::new();
    for token in input.split_whitespace() {
        filters.extend(parse_filter(token)?);
    }
    Ok(filters)
}

/// Apply all filters to a move (AND logic).
pub fn matches_all(m: &Move, filters: &[Filter]) -> bool {
    filters.iter().all(|f| f.matches(m))
}
