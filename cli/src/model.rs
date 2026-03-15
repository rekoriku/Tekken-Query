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
    pub active_frames: Option<i64>,
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
