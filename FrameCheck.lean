import TekkenQuery
import Std.Data.HashMap
import Std.Data.HashSet

/-!
  Frame data check (`lake exe frame_check`).

  Parses every distinct startup, block, hit and counter-hit value in the raw
  character CSVs with the verified parsers in `TekkenQuery.Frame` and compares
  each result with a local snapshot (default `data/frame_parse_snapshot.tsv`).
  `data/` is not tracked, so the snapshot stays beside the fetched data it
  describes; record it with `--update` before changing the parser.

  Report (stdout): unparsed values, values whose parse changed relative to the
  snapshot (guard-flag changes are counted separately), and values new to or
  missing from the data. Exits with status 1 when a snapshot value changed
  meaning; values added by a data refresh are reported but do not fail.

  Usage: `lake exe frame_check [--update] [RAW_DIR] [SNAPSHOT]`
  (defaults: `data/raw`, `data/frame_parse_snapshot.tsv`). `--update`
  rewrites the snapshot after a reviewed parser or data change. Exits with
  status 2 when the raw directory is missing.
-/

open TekkenQuery

/-- Render an optional value as its `toString`, or `none`. -/
def showOpt {α : Type} [ToString α] : Option α → String
  | some v => toString v
  | none => "none"

/-- Describe how the startup parser reads a value. -/
def describeStartup (s : String) : String :=
  match Frame.parseStartupFrame s with
  | some d => s!"startup={d.startup} end={showOpt d.activeEnd} active={showOpt d.activeFrames}"
  | none => "UNPARSED"

/-- Describe how the block parser (also used for hit and counter hit) reads a value. -/
def describeBlock (s : String) : String :=
  match Frame.parseBlockFrame s with
  | some d => s!"value={d.value} guard={d.guardable} range={showOpt d.rangeEnd}"
  | none => "UNPARSED"

/-- Escape a raw value so it fits on one tab-separated line. -/
def escapeField (s : String) : String :=
  (s.replace "\\" "\\\\").replace "\t" "\\t" |>.replace "\n" "\\n" |>.replace "\r" "\\r"

/-- Snapshot key: the column name and the escaped raw value. -/
def snapshotKey (column value : String) : String :=
  s!"{column}\t{escapeField value}"

/-- Whether a parse description carries a guard flag set to true. -/
def guardOf (description : String) : Bool :=
  (description.splitOn "guard=true").length > 1

/-- The frame columns checked, with the parser description for each. -/
def frameColumns (m : TekkenMove) : List (String × Option String × (String → String)) :=
  [ ("startup", m.startupFrame, describeStartup)
  , ("block", m.blockFrame, describeBlock)
  , ("hit", m.hitFrame, describeBlock)
  , ("counter_hit", m.counterHitFrame, describeBlock) ]

/-- Snapshot lines (`key\tdescription`) for one raw CSV's moves. -/
def movesSnapshot (moves : List TekkenMove) : List (String × String) :=
  moves.flatMap fun m =>
    (frameColumns m).filterMap fun (column, value, describe) =>
      value.map fun v => (snapshotKey column v, describe v)

theorem describeBlock_unparsed : describeBlock "!" = "UNPARSED" := by decide

/-- Collect distinct (key, description) pairs from every raw CSV in `dir`. -/
def collect (dir : System.FilePath) : IO (Std.HashMap String String) := do
  let entries ← dir.readDir
  let files := entries.filter (fun e => e.path.extension == some "csv")
  let mut acc : Std.HashMap String String := {}
  for file in files do
    let content ← IO.FS.readFile file.path
    match Csv.parse content with
    | .error _ => IO.eprintln s!"frame_check: skipping unparseable CSV {file.path}"
    | .ok result =>
      for (key, description) in movesSnapshot (result.records.map TekkenMove.fromRecord) do
        acc := acc.insert key description
  return acc

/-- Read a snapshot file into a key → description map (missing file = empty). -/
def readSnapshot (path : System.FilePath) : IO (Std.HashMap String String) := do
  if !(← path.pathExists) then return {}
  let content ← IO.FS.readFile path
  return content.splitOn "\n" |>.foldl (init := {}) fun acc line =>
    match line.splitOn "\t" with
    | [column, value, description] => acc.insert s!"{column}\t{value}" description
    | _ => acc

/-- Sort strings ascending. -/
def sortStrings (xs : List String) : List String :=
  xs.mergeSort (fun a b => decide (a ≤ b))

def main (args : List String) : IO UInt32 := do
  let update := args.contains "--update"
  let positional := args.filter (· != "--update")
  let rawDir : System.FilePath := positional.head?.getD "data/raw"
  let snapshotPath : System.FilePath := (positional.drop 1).head?.getD "data/frame_parse_snapshot.tsv"
  if !(← rawDir.isDir) then
    IO.eprintln s!"frame_check: raw data directory {rawDir} not found; fetch data first"
    return 2
  let current ← collect rawDir
  let old ← readSnapshot snapshotPath
  let keys := sortStrings (current.toList.map (·.1))
  let unparsed := keys.filter (fun k => current.get? k == some "UNPARSED")
  let changed := keys.filterMap fun k =>
    match old.get? k, current.get? k with
    | some o, some n => if o != n then some (k, o, n) else none
    | _, _ => none
  let guardChanged := changed.filter (fun (_, o, n) => guardOf o != guardOf n)
  let added := keys.filter (fun k => !old.contains k)
  let removed := sortStrings (old.toList.map (·.1) |>.filter (fun k => !current.contains k))
  IO.println s!"Distinct values: {keys.length} (snapshot: {old.size})"
  IO.println s!"Unparsed: {unparsed.length}"
  for k in unparsed do IO.println s!"  {k}"
  IO.println s!"Changed meaning: {changed.length} (guard flag changed: {guardChanged.length})"
  for (k, o, n) in changed do IO.println s!"  {k}\t{o} -> {n}"
  IO.println s!"New values: {added.length}"
  for k in added do IO.println s!"  {k}"
  IO.println s!"Missing values: {removed.length}"
  for k in removed do IO.println s!"  {k}"
  if update then
    let lines := keys.filterMap fun k => (current.get? k).map fun d => s!"{k}\t{d}\n"
    IO.FS.writeFile snapshotPath (String.join lines)
    IO.eprintln s!"frame_check: wrote {lines.length} entries to {snapshotPath}"
    return 0
  if changed.isEmpty then return 0
  IO.eprintln "frame_check: parse results changed; review them, then rerun with --update"
  return 1
