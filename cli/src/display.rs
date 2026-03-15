/// Display formatting for moves and query results.
use colored::Colorize;

use crate::model::Move;

/// Right-pad a string to a given width with spaces.
fn pad_right(s: &str, width: usize) -> String {
    if s.len() >= width {
        s.to_string()
    } else {
        let padding = " ".repeat(width - s.len());
        format!("{s}{padding}")
    }
}

/// Compute the display command string (with stance prefix if any).
fn display_cmd(m: &Move) -> String {
    if m.stance.is_empty() {
        m.command.trim().to_string()
    } else {
        format!("[{}] {}", m.stance.trim(), m.command.trim())
    }
}

/// Colorize a block frame string based on its numeric value and guardable flag.
/// The string must already be padded to the desired width BEFORE calling this.
fn colorize_block(m: &Move, text: &str) -> String {
    match m.block_frame {
        Some(v) if v > 0 && !m.is_guardable() => text.green().bold().to_string(),
        Some(v) if v > 0 => text.green().to_string(),
        Some(v) if v <= -10 => text.red().to_string(),
        Some(v) if v < 0 => text.yellow().to_string(),
        _ => text.to_string(),
    }
}

/// Colorize a hit frame string based on its leading numeric value.
/// The string must already be padded to the desired width BEFORE calling this.
fn colorize_hit(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed == "?" {
        return text.to_string();
    }
    // Parse leading sign/number for coloring
    let stripped = trimmed.trim_start_matches('+');
    if let Ok(v) = stripped
        .chars()
        .take_while(|c| *c == '-' || c.is_ascii_digit())
        .collect::<String>()
        .parse::<i64>()
    {
        if v > 0 {
            return text.green().to_string();
        } else if v < 0 {
            return text.red().to_string();
        }
    }
    text.to_string()
}

/// Column widths for the table layout.
pub struct Columns {
    cmd: usize,
    level: usize,
    startup: usize,
    block: usize,
    hit: usize,
}

/// Compute column widths from a set of moves for aligned display.
fn compute_columns(moves: &[&Move], cmd_width: usize) -> Columns {
    let mut level: usize = 5;
    let mut startup: usize = 7;
    let mut block: usize = 5;
    let mut hit: usize = 3;

    for m in moves {
        let hl = if m.hit_level.is_empty() { 1 } else { m.hit_level.trim().len() };
        level = level.max(hl);

        startup = startup.max(m.startup_display().len());

        block = block.max(m.block_frame_display().len());

        let h = if m.hit_frame.is_empty() { 1 } else { m.hit_frame.trim().len() };
        hit = hit.max(h);
    }

    Columns {
        cmd: cmd_width,
        level: level + 2,   // padding between columns
        startup: startup + 2,
        block: block + 2,
        hit: hit + 2,
    }
}

/// Format a single move as a compact one-line summary.
///
/// Columns are padded BEFORE colorization so ANSI codes don't break alignment.
pub fn format_move_row(m: &Move, cols: &Columns) -> String {
    let cmd = pad_right(&display_cmd(m), cols.cmd);
    let hl_raw = if m.hit_level.is_empty() { "?" } else { m.hit_level.trim() };
    let hl = pad_right(hl_raw, cols.level);
    let startup = pad_right(&m.startup_display(), cols.startup);
    let block_raw = m.block_frame_display();
    let block_padded = pad_right(&block_raw, cols.block);
    let hit_raw = if m.hit_frame.is_empty() {
        "?".to_string()
    } else {
        m.hit_frame.trim().to_string()
    };
    let hit_padded = pad_right(&hit_raw, cols.hit);

    // Colorize AFTER padding so escape codes don't affect width
    let block_colored = colorize_block(m, &block_padded);
    let hit_colored = colorize_hit(&hit_padded);

    let name = m.name.trim();
    let name_part = if name.is_empty() {
        String::new()
    } else {
        name.dimmed().to_string()
    };

    format!("{cmd} {hl} {startup} {block_colored} {hit_colored} {name_part}")
}

/// Print a header line for move listings.
pub fn print_header(cols: &Columns) {
    let header = format!(
        "{} {} {} {} {} {}",
        pad_right("Command", cols.cmd),
        pad_right("Level", cols.level),
        pad_right("Startup", cols.startup),
        pad_right("Block", cols.block),
        pad_right("Hit", cols.hit),
        "Name",
    );
    eprintln!("{}", header.bold());
    let total = cols.cmd + cols.level + cols.startup + cols.block + cols.hit + 5 + 20;
    eprintln!("{}", "─".repeat(total));
}

/// Compute column layout from a set of moves.
pub fn layout_for(moves: &[&Move]) -> Columns {
    let cmd_width = moves
        .iter()
        .map(|m| display_cmd(m).len())
        .max()
        .unwrap_or(7)
        .clamp(7, 30);
    compute_columns(moves, cmd_width)
}

/// Format a move with full details (single-move view).
pub fn format_move_detail(m: &Move) -> String {
    let moves = [m];
    let refs: Vec<&Move> = moves.to_vec();
    let cols = layout_for(&refs);
    let mut lines = vec![format_move_row(m, &cols)];

    if !m.damage.is_empty() {
        lines.push(format!("    Damage: {}", m.damage.trim()));
    }
    if m.block_range_end.is_some() {
        lines.push(format!("    Block:  {}", block_range_display(m)));
    }
    if !m.hit_frame.is_empty() {
        lines.push(format!("    Hit:    {}", m.hit_frame.trim()));
    }
    if !m.counter_hit_frame.is_empty() {
        lines.push(format!("    CH:     {}", m.counter_hit_frame.trim()));
    }
    if !m.tags.is_empty() {
        lines.push(format!("    Tags:   {}", m.tags.trim()));
    }
    if !m.notes.is_empty() {
        let notes = m.notes.trim();
        let truncated = if notes.len() > 100 {
            format!("{}...", &notes[..100])
        } else {
            notes.to_string()
        };
        lines.push(format!("    Notes:  {}", truncated.dimmed()));
    }

    lines.join("\n")
}

/// Format block frame range for detail display.
pub fn block_range_display(m: &Move) -> String {
    match (m.block_frame, m.block_range_end) {
        (Some(lo), Some(hi)) => {
            let sign_lo = if lo >= 0 { "+" } else { "" };
            let sign_hi = if hi >= 0 { "+" } else { "" };
            format!("{sign_lo}{lo}~{sign_hi}{hi}")
        }
        _ => m.block_frame_display(),
    }
}

/// Print summary stats for a character.
pub fn print_character_stats(name: &str, moves: &[Move]) {
    let total = moves.len();
    let plus = moves.iter().filter(|m| m.is_plus()).count();
    let punish = moves.iter().filter(|m| m.is_punishable()).count();
    let homing = moves.iter().filter(|m| m.has_tag("hom")).count();
    let heat = moves
        .iter()
        .filter(|m| m.has_tag("he") || m.has_tag("hs") || m.has_tag("hb"))
        .count();
    let pc = moves.iter().filter(|m| m.has_tag("pc")).count();

    eprintln!("{} — {} moves", name.bold(), total);
    eprintln!(
        "  Plus: {plus}  Punishable: {punish}  Homing: {homing}  Heat: {heat}  PC: {pc}"
    );
}
