/// Manages a persistent Lean query server subprocess.
///
/// The Lean binary runs with `--server` and communicates via
/// line-delimited JSON on stdin/stdout. All filter evaluation
/// is done by the verified Lean core — Rust only handles
/// serialization and display.
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::Value;

use crate::error::CliError;
use crate::filter::{CompareOp, Filter, FrameField};
use crate::model::Move;

/// A persistent connection to the Lean query server.
pub struct LeanServer {
    child: Child,
    stdin: BufWriter<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: u64,
}

/// Result of a query operation.
pub struct QueryResult {
    pub name: String,
    pub total: usize,
    pub count: usize,
    pub moves: Vec<Move>,
}

/// Result of a compare operation.
pub struct CompareResult {
    pub char1_name: String,
    pub char1_moves: Vec<Move>,
    pub char2_name: String,
    pub char2_moves: Vec<Move>,
}

impl LeanServer {
    /// Start the Lean query server subprocess.
    ///
    /// Looks for the Lean binary at standard locations relative to the
    /// data directory or in the project root.
    pub fn start(data_dir: &Path) -> Result<Self, CliError> {
        let binary = find_lean_binary(data_dir).ok_or_else(|| {
            CliError::DataNotFound(
                "Lean binary not found. Run 'lake build' in the project root first.".into(),
            )
        })?;

        let mut child = Command::new(&binary)
            .arg("--server")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| CliError::IoError(format!("failed to start lean server: {e}")))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| CliError::IoError("failed to open lean stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| CliError::IoError("failed to open lean stdout".into()))?;

        Ok(Self {
            child,
            stdin: BufWriter::new(stdin),
            stdout: BufReader::new(stdout),
            next_id: 1,
        })
    }

    /// Load a character from a CSV file into the server's state.
    pub fn load_character(
        &mut self,
        id: &str,
        name: &str,
        csv_path: &Path,
    ) -> Result<usize, CliError> {
        let path_str = csv_path
            .to_str()
            .ok_or_else(|| CliError::IoError("non-UTF-8 path".into()))?;

        let request = serde_json::json!({
            "id": self.next_id(),
            "method": "load",
            "params": {
                "id": id,
                "name": name,
                "path": path_str,
            }
        });

        let response = self.send_request(&request)?;
        let result = get_result(&response)?;

        let moves_loaded = result
            .get("moves_loaded")
            .and_then(Value::as_u64)
            .ok_or_else(|| CliError::ParseError("missing moves_loaded in response".into()))?;

        usize::try_from(moves_loaded)
            .map_err(|_| CliError::ParseError("moves_loaded too large".into()))
    }

    /// Query a loaded character with filters.
    pub fn query(
        &mut self,
        character_id: &str,
        filters: &[Filter],
    ) -> Result<QueryResult, CliError> {
        let filter_json: Vec<Value> = filters.iter().map(filter_to_json).collect();

        let request = serde_json::json!({
            "id": self.next_id(),
            "method": "query",
            "params": {
                "character": character_id,
                "filters": filter_json,
            }
        });

        let response = self.send_request(&request)?;
        let result = get_result(&response)?;
        parse_query_result(result)
    }

    /// Compare a filter across two characters.
    pub fn compare(
        &mut self,
        char1_id: &str,
        char2_id: &str,
        filters: &[Filter],
    ) -> Result<CompareResult, CliError> {
        let filter_json: Vec<Value> = filters.iter().map(filter_to_json).collect();

        let request = serde_json::json!({
            "id": self.next_id(),
            "method": "compare",
            "params": {
                "char1": char1_id,
                "char2": char2_id,
                "filters": filter_json,
            }
        });

        let response = self.send_request(&request)?;
        let result = get_result(&response)?;

        let c1 = result
            .get("char1")
            .ok_or_else(|| CliError::ParseError("missing char1".into()))?;
        let c2 = result
            .get("char2")
            .ok_or_else(|| CliError::ParseError("missing char2".into()))?;

        Ok(CompareResult {
            char1_name: c1
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| CliError::ParseError("missing char1 name".into()))?
                .to_string(),
            char1_moves: parse_moves_array(c1.get("moves"))?,
            char2_name: c2
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| CliError::ParseError("missing char2 name".into()))?
                .to_string(),
            char2_moves: parse_moves_array(c2.get("moves"))?,
        })
    }

    /// Convert a raw CSV file to a clean CSV file via the Lean server.
    ///
    /// Returns the number of moves exported.
    pub fn export_character(
        &mut self,
        raw_path: &Path,
        clean_path: &Path,
    ) -> Result<usize, CliError> {
        let raw_str = raw_path
            .to_str()
            .ok_or_else(|| CliError::IoError("non-UTF-8 raw path".into()))?;
        let clean_str = clean_path
            .to_str()
            .ok_or_else(|| CliError::IoError("non-UTF-8 clean path".into()))?;

        let request = serde_json::json!({
            "id": self.next_id(),
            "method": "convert",
            "params": {
                "raw_path": raw_str,
                "clean_path": clean_str,
            }
        });

        let response = self.send_request(&request)?;
        let result = get_result(&response)?;

        let moves_exported = result
            .get("moves_exported")
            .and_then(Value::as_u64)
            .ok_or_else(|| {
                CliError::ParseError("missing moves_exported in response".into())
            })?;

        usize::try_from(moves_exported)
            .map_err(|_| CliError::ParseError("moves_exported too large".into()))
    }

    /// Send quit and wait for the server to exit.
    pub fn quit(mut self) {
        let request = serde_json::json!({
            "id": self.next_id(),
            "method": "quit"
        });

        // Best-effort: send quit, ignore errors (server might already be dead)
        let _ = self.send_request(&request);
        let _ = self.child.wait();
    }

    /// Send a JSON request and read the response line.
    fn send_request(&mut self, request: &Value) -> Result<Value, CliError> {
        let request_id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| CliError::ParseError("request is missing a numeric id".into()))?;
        let line = serde_json::to_string(request)
            .map_err(|e| CliError::ParseError(format!("serialize request: {e}")))?;

        self.stdin
            .write_all(line.as_bytes())
            .map_err(|e| CliError::IoError(format!("write to lean server: {e}")))?;
        self.stdin
            .write_all(b"\n")
            .map_err(|e| CliError::IoError(format!("write newline: {e}")))?;
        self.stdin
            .flush()
            .map_err(|e| CliError::IoError(format!("flush to lean server: {e}")))?;

        let mut response_line = String::new();
        self.stdout
            .read_line(&mut response_line)
            .map_err(|e| CliError::IoError(format!("read from lean server: {e}")))?;

        if response_line.is_empty() {
            return Err(CliError::IoError("lean server closed unexpectedly".into()));
        }

        let response: Value = serde_json::from_str(&response_line)
            .map_err(|e| CliError::ParseError(format!("parse response: {e}")))?;
        let response_id = response
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| CliError::ParseError("response is missing a numeric id".into()))?;
        if response_id != request_id {
            return Err(CliError::ParseError(format!(
                "response id {response_id} does not match request id {request_id}"
            )));
        }
        Ok(response)
    }

    /// Generate the next request ID.
    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

impl Drop for LeanServer {
    fn drop(&mut self) {
        // Try to kill the subprocess on drop.
        let _ = self.child.kill();
    }
}

// ── Filter serialization ────────────────────────────────────────────

/// Convert a Rust Filter to the JSON format the Lean server expects.
fn filter_to_json(filter: &Filter) -> Value {
    match filter {
        Filter::HitLevel(level) => {
            serde_json::json!({"filter": "hitLevel", "value": level})
        }
        Filter::Throw => serde_json::json!({"filter": "isThrow"}),
        Filter::Plus => serde_json::json!({"filter": "plusOnBlock"}),
        Filter::Negative => serde_json::json!({"filter": "negative"}),
        Filter::Punishable => serde_json::json!({"filter": "punishable"}),
        Filter::Guardable => serde_json::json!({"filter": "guardable"}),
        Filter::StartupLt(n) => {
            serde_json::json!({"filter": "startupLt", "value": n})
        }
        Filter::StartupLe(n) => {
            serde_json::json!({"filter": "startupLe", "value": n})
        }
        Filter::StartupEq(n) => {
            serde_json::json!({"filter": "startupEq", "value": n})
        }
        Filter::StartupGe(n) => {
            serde_json::json!({"filter": "startupGe", "value": n})
        }
        Filter::Tag(tag) => tag_to_property_json(tag),
        Filter::ActiveGe(n) => {
            serde_json::json!({"filter": "activeFramesGe", "value": n})
        }
        Filter::Stance(name) => {
            serde_json::json!({"filter": "stance", "value": name})
        }
        Filter::HasStance => serde_json::json!({"filter": "hasStance"}),
        Filter::CommandContains(q) => {
            serde_json::json!({"filter": "commandContains", "value": q})
        }
        Filter::NameContains(q) => {
            serde_json::json!({"filter": "nameContains", "value": q})
        }
        Filter::NoteContains(q) => {
            serde_json::json!({"filter": "noteContains", "value": q})
        }
        Filter::HeatMove => serde_json::json!({"filter": "heatMove"}),
        Filter::FrameCompare(field, op, value) => {
            let field_str = match field {
                FrameField::Block => "block",
                FrameField::Hit => "hit",
                FrameField::CounterHit => "counterHit",
            };
            let op_str = match op {
                CompareOp::Lt => "lt",
                CompareOp::Le => "le",
                CompareOp::Eq => "eq",
                CompareOp::Ge => "ge",
                CompareOp::Gt => "gt",
            };
            serde_json::json!({
                "filter": "frameCompare",
                "field": field_str,
                "op": op_str,
                "value": value
            })
        }
        Filter::Not(inner) => {
            serde_json::json!({"filter": "not", "inner": filter_to_json(inner)})
        }
    }
}

/// Map a tag code to a Lean `MoveProperty` name.
fn tag_to_property_name(tag: &str) -> Option<String> {
    let name = match tag {
        "he" => "heatEngager",
        "hs" => "heatSmash",
        "hb" => "heatBurst",
        "trn" => "tornado",
        "spk" => "spike",
        "pc" => "powerCrush",
        "js" => "jumpStatus",
        "cs" => "crouchStatus",
        "hom" => "homing",
        "bbr" => "balconyBreak",
        "wbr" => "wallBreak",
        "fbr" => "floorBreak",
        "elb" => "elbow",
        "kne" => "knee",
        "hed" => "headbutt",
        "wpn" => "weapon",
        "rbr" => "reversalBreak",
        "chp" => "chipDamage",
        _ => return None,
    };
    Some(name.to_string())
}

/// Convert a tag filter to the appropriate property JSON.
fn tag_to_property_json(tag: &str) -> Value {
    match tag_to_property_name(tag) {
        Some(prop) => serde_json::json!({"filter": "property", "value": prop}),
        None => serde_json::json!({"filter": "noteContains", "value": tag}),
    }
}

// ── Response parsing ────────────────────────────────────────────────

/// Extract the result from a server response, checking for errors.
fn get_result(response: &Value) -> Result<&Value, CliError> {
    let status = response
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");

    if status == "error" {
        let msg = response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("unknown error");
        return Err(CliError::ParseError(format!("lean server: {msg}")));
    }

    if status != "ok" {
        return Err(CliError::ParseError(format!(
            "unknown lean server response status: {status}"
        )));
    }

    response.get("result").ok_or_else(|| {
        CliError::ParseError("missing result in response".into())
    })
}

/// Parse a query result from the JSON response.
fn parse_query_result(result: &Value) -> Result<QueryResult, CliError> {
    let name = result
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| CliError::ParseError("missing query result name".into()))?
        .to_string();
    let total = result
        .get("total")
        .and_then(Value::as_u64)
        .ok_or_else(|| CliError::ParseError("missing query result total".into()))?;
    let count = result
        .get("count")
        .and_then(Value::as_u64)
        .ok_or_else(|| CliError::ParseError("missing query result count".into()))?;

    let moves = parse_moves_array(result.get("moves"))?;

    Ok(QueryResult {
        name,
        total: usize::try_from(total)
            .map_err(|_| CliError::ParseError("query result total too large".into()))?,
        count: usize::try_from(count)
            .map_err(|_| CliError::ParseError("query result count too large".into()))?,
        moves,
    })
}

/// Parse a JSON array of moves into Vec<Move>.
fn parse_moves_array(moves_val: Option<&Value>) -> Result<Vec<Move>, CliError> {
    let Some(Value::Array(arr)) = moves_val else {
        return Err(CliError::ParseError(
            "missing or invalid moves array in response".into(),
        ));
    };

    let mut moves = Vec::with_capacity(arr.len());
    for item in arr {
        let m: Move = serde_json::from_value(item.clone())
            .map_err(|e| CliError::ParseError(format!("parse move: {e}")))?;
        moves.push(m);
    }
    Ok(moves)
}

// ── Binary location ─────────────────────────────────────────────────

/// Name of the Lean binary (platform-dependent).
fn lean_binary_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "tekken_query.exe"
    } else {
        "tekken_query"
    }
}

/// Find the Lean binary path.
///
/// Search order:
/// 1. Same directory as the running `tekken-cli` executable (release layout)
/// 2. Relative to the data directory's parent (dev layout)
/// 3. Relative to CWD (dev layout fallback)
pub(crate) fn find_lean_binary(data_dir: &Path) -> Option<PathBuf> {
    let name = lean_binary_name();

    // 1. Same directory as the running executable (release distribution)
    if let Ok(exe) = std::env::current_exe()
        && let Some(exe_dir) = exe.parent()
    {
        let candidate = exe_dir.join(name);
        if candidate.exists() {
            return Some(candidate);
        }
    }

    // 2. Relative to data dir parent (project root)
    if let Some(project_root) = data_dir.parent() {
        let candidate = project_root.join(".lake/build/bin").join(name);
        if candidate.exists() {
            return Some(candidate);
        }
    }

    // 3. Relative to CWD
    for base in &[".lake/build/bin", "../.lake/build/bin"] {
        let p = PathBuf::from(base).join(name);
        if p.exists() {
            return Some(p);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{get_result, parse_moves_array, parse_query_result};

    #[test]
    fn rejects_unknown_response_status() {
        let response = json!({"id": 1, "status": "maybe", "result": {}});
        assert!(get_result(&response).is_err());
    }

    #[test]
    fn rejects_missing_moves_array() {
        assert!(parse_moves_array(None).is_err());
        assert!(parse_moves_array(Some(&json!({}))).is_err());
    }

    #[test]
    fn rejects_incomplete_query_result() {
        let result = json!({"name": "Jin", "total": 10, "moves": []});
        assert!(parse_query_result(&result).is_err());
    }
}
