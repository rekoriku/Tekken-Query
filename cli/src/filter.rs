/// Filter parser for querying moves through the Lean backend.
/// Parses human-readable filter strings into values serialized by `LeanServer`.
use crate::error::CliError;

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
    /// Abnormal source frame data flagged by Lean (likely a wiki typo).
    FrameIssue,
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

/// Parse a single filter token from user input.
///
/// Supported tokens:
///   `high`, `mid`, `low`       — hit level prefix
///   `throw`                    — is throw
///   `plus`, `minus`, `punish`  — block frame categories
///   `guard`/`guardable`        — guardable block frame
///   `broken`                   — abnormal source frame data (Lean `FrameIssue`)
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
    let token = strip_outer_quotes(token);

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
        "broken" => Ok(vec![Filter::FrameIssue]),
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

/// Strip matching outer quotes from a single token.
fn strip_outer_quotes(token: &str) -> &str {
    if token.len() >= 2
        && ((token.starts_with('\'') && token.ends_with('\''))
            || (token.starts_with('"') && token.ends_with('"')))
    {
        &token[1..token.len() - 1]
    } else {
        token
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
        if n < 0 {
            return Err(CliError::InvalidFilter(format!(
                "bad active frames: {token}"
            )));
        }
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

/// Parse startup frame comparison: `15` or `=15` → eq, `<15` → lt, `>=15` → ge, etc.
fn parse_startup_filter(s: &str) -> Result<Vec<Filter>, CliError> {
    let err = || CliError::InvalidFilter(format!("bad startup filter: i{s}"));
    let parse_frames = |value: &str| -> Result<i64, CliError> {
        let frames: i64 = value.parse().map_err(|_| err())?;
        if frames < 0 {
            return Err(err());
        }
        Ok(frames)
    };

    if let Some(rest) = s.strip_prefix("<=") {
        let n = parse_frames(rest)?;
        Ok(vec![Filter::StartupLe(n)])
    } else if let Some(rest) = s.strip_prefix(">=") {
        let n = parse_frames(rest)?;
        Ok(vec![Filter::StartupGe(n)])
    } else if let Some(rest) = s.strip_prefix('<') {
        let n = parse_frames(rest)?;
        Ok(vec![Filter::StartupLt(n)])
    } else if let Some(rest) = s.strip_prefix('>') {
        let n = parse_frames(rest)?;
        Ok(vec![Filter::StartupGe(n + 1)])
    } else if let Some(rest) = s.strip_prefix('=') {
        let n = parse_frames(rest)?;
        Ok(vec![Filter::StartupEq(n)])
    } else {
        let n = parse_frames(s)?;
        Ok(vec![Filter::StartupEq(n)])
    }
}

/// Parse a full filter string (space-separated tokens, AND'd together).
pub fn parse_filters(input: &str) -> Result<Vec<Filter>, CliError> {
    let tokens: Vec<&str> = input.split_whitespace().collect();
    let mut filters = Vec::new();
    let mut index = 0;

    while index < tokens.len() {
        if let Some((normalized, consumed)) = parse_spaced_frame_filter(&tokens[index..]) {
            filters.extend(parse_filter(&normalized)?);
            index += consumed;
        } else {
            filters.extend(parse_filter(tokens[index])?);
            index += 1;
        }
    }
    Ok(filters)
}

/// Normalize a spaced frame expression such as `hit +5` or `startup >= 15`.
fn parse_spaced_frame_filter(tokens: &[&str]) -> Option<(String, usize)> {
    let field = *tokens.first()?;
    if matches!(field, "hit" | "block" | "ch") {
        let next = *tokens.get(1)?;
        if is_compare_operator(next) {
            let value = *tokens.get(2)?;
            return Some((format!("{field}{next}{value}"), 3));
        }
        if starts_with_compare_operator(next) {
            return Some((format!("{field}{next}"), 2));
        }
        return Some((format!("{field}={next}"), 2));
    }

    if field == "startup" {
        let next = *tokens.get(1)?;
        if is_compare_operator(next) {
            let value = *tokens.get(2)?;
            return Some((format!("i{next}{value}"), 3));
        }
        if next.starts_with('i') {
            return Some((next.to_string(), 2));
        }
        return Some((format!("i{next}"), 2));
    }

    None
}

/// Whether a token is a standalone frame comparison operator.
fn is_compare_operator(token: &str) -> bool {
    matches!(token, "<" | "<=" | "=" | ">=" | ">")
}

/// Whether a token starts with a frame comparison operator.
fn starts_with_compare_operator(token: &str) -> bool {
    token.starts_with('<') || token.starts_with('=') || token.starts_with('>')
}

#[cfg(test)]
mod tests {
    use super::{CompareOp, Filter, FrameField, parse_filters};

    #[test]
    fn rejects_negative_startup_frames() {
        assert!(parse_filters("i=-1").is_err());
        assert!(parse_filters("i<-1").is_err());
        assert!(parse_filters("active-1").is_err());
    }

    #[test]
    fn parses_broken_keyword() {
        assert!(matches!(
            parse_filters("broken").as_deref(),
            Ok([Filter::FrameIssue])
        ));
        assert!(matches!(
            parse_filters("!broken").as_deref(),
            Ok([Filter::Not(inner)]) if matches!(**inner, Filter::FrameIssue)
        ));
    }

    #[test]
    fn accepts_signed_block_frames() {
        assert!(parse_filters("block>=-10").is_ok());
        assert!(parse_filters(">=+3").is_ok());
    }

    #[test]
    fn accepts_spaced_frame_queries() {
        assert!(matches!(
            parse_filters("hit +5").as_deref(),
            Ok([Filter::FrameCompare(
                FrameField::Hit,
                CompareOp::Eq,
                5
            )])
        ));
        assert!(matches!(
            parse_filters("block >= +5").as_deref(),
            Ok([Filter::FrameCompare(
                FrameField::Block,
                CompareOp::Ge,
                5
            )])
        ));
        assert!(matches!(
            parse_filters("ch <=-10").as_deref(),
            Ok([Filter::FrameCompare(
                FrameField::CounterHit,
                CompareOp::Le,
                -10
            )])
        ));
        assert!(matches!(
            parse_filters("startup i15").as_deref(),
            Ok([Filter::StartupEq(15)])
        ));
        assert!(matches!(
            parse_filters("startup < 15").as_deref(),
            Ok([Filter::StartupLt(15)])
        ));
    }
}
