/// Data models for Tekken frame data.
/// Deserialized from clean CSVs produced by the verified Lean pipeline.
use serde::Deserialize;

/// A single Tekken move with all frame data.
#[derive(Debug, Clone, Deserialize)]
pub struct Move {
    pub command: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub stance: String,
    #[serde(default)]
    pub hit_level: String,
    #[serde(default)]
    pub damage: String,
    #[serde(default, deserialize_with = "deserialize_opt_i64")]
    pub startup: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_opt_i64")]
    pub startup_end: Option<i64>,
    #[serde(default, deserialize_with = "deserialize_opt_i64")]
    pub block_frame: Option<i64>,
    #[serde(default)]
    pub block_guardable: String,
    #[serde(default, deserialize_with = "deserialize_opt_i64")]
    pub block_range_end: Option<i64>,
    #[serde(default)]
    pub hit_frame: String,
    #[serde(default)]
    pub counter_hit_frame: String,
    #[serde(default)]
    pub tags: String,
    #[serde(default)]
    pub notes: String,
    /// Abnormal source values flagged by Lean: `column:code:written` entries
    /// joined by `"; "`. Empty for ordinary moves and older clean CSVs.
    #[serde(default)]
    pub frame_issues: String,
}

/// A frame column that Lean can flag as abnormal source data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameColumn {
    Startup,
    Block,
    Hit,
    CounterHit,
}

impl FrameColumn {
    /// Map a clean CSV column name to a frame column.
    fn from_column_name(name: &str) -> Option<Self> {
        match name {
            "startup" => Some(Self::Startup),
            "block_frame" => Some(Self::Block),
            "hit_frame" => Some(Self::Hit),
            "counter_hit_frame" => Some(Self::CounterHit),
            _ => None,
        }
    }

    /// Human-readable column label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Startup => "startup",
            Self::Block => "block",
            Self::Hit => "hit",
            Self::CounterHit => "counter hit",
        }
    }
}

/// Why Lean flagged a frame value (codes of `Frame.FrameIssue`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IssueKind {
    /// A startup range whose written end precedes its start.
    RangeEndBeforeStart,
    /// Two signs or range separators in a row.
    DoubledSign,
    /// Neither a frame value nor known notation.
    Unrecognized,
    /// A code from a newer Lean export that this CLI does not know.
    Other(String),
}

impl IssueKind {
    fn from_code(code: &str) -> Self {
        match code {
            "range_end_before_start" => Self::RangeEndBeforeStart,
            "doubled_sign" => Self::DoubledSign,
            "unrecognized" => Self::Unrecognized,
            other => Self::Other(other.to_string()),
        }
    }

    /// Short explanation of the issue.
    pub fn description(&self) -> &str {
        match self {
            Self::RangeEndBeforeStart => "range ends before it starts",
            Self::DoubledSign => "two signs in a row",
            Self::Unrecognized => "not a frame value or known notation",
            Self::Other(code) => code,
        }
    }
}

/// One abnormal frame value of a move, as reported by Lean.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameIssue {
    /// The flagged column.
    pub column: FrameColumn,
    /// Why it was flagged.
    pub kind: IssueKind,
    /// The value as written in the source data.
    pub written: String,
}

/// A character with their move list.
#[derive(Debug, Clone)]
pub struct Character {
    pub id: String,
    pub name: String,
    pub moves: Vec<Move>,
}

impl Move {
    /// Check if move has a specific tag code (e.g., "he", "pc", "hom").
    pub fn has_tag(&self, tag: &str) -> bool {
        self.tags
            .split_whitespace()
            .any(|t| t.starts_with(tag) && t[tag.len()..].chars().all(|c| c.is_ascii_digit() || c == '~'))
    }

    /// Whether block frame is guardable (opponent can still block).
    pub fn is_guardable(&self) -> bool {
        self.block_guardable == "true"
    }

    /// Whether move is plus on block.
    pub fn is_plus(&self) -> bool {
        self.block_frame.is_some_and(|v| v > 0)
    }

    /// Whether move is punishable (block frame <= -10).
    pub fn is_punishable(&self) -> bool {
        self.block_frame.is_some_and(|v| v <= -10)
    }

    /// Parse the hit frame string to an optional numeric value.
    ///
    /// Handles formats like "+7", "-3", "KND", "Launch", etc.
    /// Returns `None` for non-numeric values.
    pub fn hit_frame_value(&self) -> Option<i64> {
        let trimmed = self.hit_frame.trim();
        if trimmed.is_empty() {
            return None;
        }
        let stripped = trimmed.trim_start_matches('+');
        stripped
            .chars()
            .take_while(|c| *c == '-' || c.is_ascii_digit())
            .collect::<String>()
            .parse::<i64>()
            .ok()
    }

    /// Whether this move is plus on hit.
    pub fn is_plus_on_hit(&self) -> bool {
        self.hit_frame_value().is_some_and(|v| v > 0)
    }

    /// Whether this move is a low (hit level starts with "l").
    pub fn is_low(&self) -> bool {
        self.hit_level.to_lowercase().starts_with('l')
    }

    /// Format block frame for display.
    pub fn block_frame_display(&self) -> String {
        match self.block_frame {
            Some(v) => {
                let sign = if v >= 0 { "+" } else { "" };
                let guard = if self.is_guardable() { "g" } else { "" };
                format!("{sign}{v}{guard}")
            }
            None => "?".to_string(),
        }
    }

    /// Abnormal source values of this move, decoded from `frame_issues`.
    ///
    /// Entries for columns this CLI does not know are skipped.
    pub fn frame_issue_list(&self) -> Vec<FrameIssue> {
        self.frame_issues
            .split(';')
            .filter_map(|entry| {
                let mut parts = entry.trim().splitn(3, ':');
                let column = FrameColumn::from_column_name(parts.next()?)?;
                let kind = IssueKind::from_code(parts.next()?);
                let written = parts.next().unwrap_or_default().to_string();
                Some(FrameIssue { column, kind, written })
            })
            .collect()
    }

    /// Whether Lean flagged this column of the move as abnormal source data.
    pub fn has_frame_issue(&self, column: FrameColumn) -> bool {
        self.frame_issue_list().iter().any(|i| i.column == column)
    }

    /// Format startup frame for display.
    pub fn startup_display(&self) -> String {
        match self.startup {
            Some(s) => match self.startup_end {
                Some(e) => format!("i{s}~{e}"),
                None => format!("i{s}"),
            },
            None => "?".to_string(),
        }
    }
}

/// Deserialize an optional i64 from a CSV field that may be empty.
fn deserialize_opt_i64<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    if s.is_empty() {
        Ok(None)
    } else {
        s.parse::<i64>().map(Some).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn move_with_issues(frame_issues: &str) -> Result<Move, csv::Error> {
        let data = format!("command,frame_issues\nIZU.3,\"{frame_issues}\"\n");
        let mut reader = csv::Reader::from_reader(data.as_bytes());
        reader.deserialize().next().unwrap_or_else(|| {
            Err(csv::Error::from(std::io::Error::other("no row")))
        })
    }

    #[test]
    fn decodes_frame_issue_entries() -> Result<(), csv::Error> {
        let m = move_with_issues(
            "startup:range_end_before_start:i16~15 i14~15; counter_hit_frame:unrecognized:js",
        )?;
        assert_eq!(
            m.frame_issue_list(),
            vec![
                FrameIssue {
                    column: FrameColumn::Startup,
                    kind: IssueKind::RangeEndBeforeStart,
                    written: "i16~15 i14~15".to_string(),
                },
                FrameIssue {
                    column: FrameColumn::CounterHit,
                    kind: IssueKind::Unrecognized,
                    written: "js".to_string(),
                },
            ]
        );
        assert!(m.has_frame_issue(FrameColumn::Startup));
        assert!(!m.has_frame_issue(FrameColumn::Block));
        Ok(())
    }

    #[test]
    fn written_value_may_contain_colons_and_unknown_entries_are_skipped() -> Result<(), csv::Error> {
        let m = move_with_issues("block_frame:new_code:a:b; recovery:doubled_sign:x")?;
        assert_eq!(
            m.frame_issue_list(),
            vec![FrameIssue {
                column: FrameColumn::Block,
                kind: IssueKind::Other("new_code".to_string()),
                written: "a:b".to_string(),
            }]
        );
        Ok(())
    }

    #[test]
    fn older_clean_csv_without_column_has_no_issues() -> Result<(), csv::Error> {
        let mut reader = csv::Reader::from_reader("command,startup\n1,10\n".as_bytes());
        let rows: Vec<Move> = reader.deserialize().collect::<Result<_, _>>()?;
        assert!(rows.iter().all(|m| m.frame_issue_list().is_empty()));
        Ok(())
    }
}
