/// Custom user-defined move aliases.
///
/// Stored as JSON in the data directory. Users can add, remove,
/// and list aliases via REPL commands. Custom aliases take
/// priority over built-in ones.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// A single custom alias definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomAlias {
    /// Display label shown when the alias is resolved.
    pub label: String,
    /// Command substrings to match (case-insensitive).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub commands: Vec<String>,
    /// Name substrings to match (case-insensitive).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub names: Vec<String>,
}

/// Collection of custom aliases, loaded from and saved to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomAliases {
    #[serde(flatten)]
    entries: BTreeMap<String, CustomAlias>,
}

impl CustomAliases {
    /// Create an empty alias collection.
    fn empty() -> Self {
        Self {
            entries: BTreeMap::new(),
        }
    }

    /// Path to the aliases config file.
    fn config_path(data_dir: &Path) -> PathBuf {
        data_dir.join("aliases.json")
    }

    /// Load aliases from disk. Returns empty collection if file doesn't exist.
    pub fn load(data_dir: &Path) -> Self {
        let path = Self::config_path(data_dir);
        let Ok(contents) = std::fs::read_to_string(&path) else {
            return Self::empty();
        };
        serde_json::from_str(&contents).unwrap_or_else(|e| {
            eprintln!("warning: invalid aliases.json: {e}");
            Self::empty()
        })
    }

    /// Save aliases to disk.
    pub fn save(&self, data_dir: &Path) -> Result<(), String> {
        let path = Self::config_path(data_dir);
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| format!("serialize aliases: {e}"))?;
        std::fs::write(&path, json).map_err(|e| format!("write aliases: {e}"))
    }

    /// Look up a custom alias by name.
    pub fn lookup(&self, name: &str) -> Option<&CustomAlias> {
        self.entries.get(&name.to_lowercase())
    }

    /// Add or update an alias.
    pub fn add(&mut self, name: &str, alias: CustomAlias) {
        self.entries.insert(name.to_lowercase(), alias);
    }

    /// Remove an alias. Returns true if it existed.
    pub fn remove(&mut self, name: &str) -> bool {
        self.entries.remove(&name.to_lowercase()).is_some()
    }

    /// Iterator over all aliases.
    pub fn iter(&self) -> impl Iterator<Item = (&String, &CustomAlias)> {
        self.entries.iter()
    }

    /// Number of aliases.
    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

/// Parse an `alias` REPL command and return the alias name and definition.
///
/// Syntax: `alias <name> cmd:<pattern> [name:<pattern>] [label:<text>]`
///
/// At least one of `cmd:` or `name:` is required.
pub fn parse_alias_command(args: &str) -> Result<(String, CustomAlias), String> {
    let parts: Vec<&str> = args.split_whitespace().collect();
    if parts.is_empty() {
        return Err("usage: alias <name> cmd:<pattern> [name:<pattern>]".into());
    }

    let name = parts[0];
    let rest = &parts[1..];

    if rest.is_empty() {
        return Err("need at least one of cmd:<pattern> or name:<pattern>".into());
    }

    let mut commands = Vec::new();
    let mut names = Vec::new();
    let mut label_parts = Vec::new();

    for part in rest {
        if let Some(cmd) = part.strip_prefix("cmd:") {
            if !cmd.is_empty() {
                commands.push(cmd.to_string());
            }
        } else if let Some(n) = part.strip_prefix("name:") {
            if !n.is_empty() {
                names.push(n.to_string());
            }
        } else {
            label_parts.push(*part);
        }
    }

    if commands.is_empty() && names.is_empty() {
        return Err("need at least one of cmd:<pattern> or name:<pattern>".into());
    }

    let label = if label_parts.is_empty() {
        name.to_string()
    } else {
        label_parts.join(" ")
    };

    Ok((
        name.to_string(),
        CustomAlias {
            label,
            commands,
            names,
        },
    ))
}
