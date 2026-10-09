/-
  TekkenQuery.Export
  Clean CSV export. Transforms messy wavu wiki data into normalized,
  machine-readable CSV. Pure functions — no IO.

  Input:  semicolon-delimited, multiline quoted fields, HTML in notes,
          inconsistent case, embedded wiki markup.
  Output: comma-delimited, one row per move, normalized, no HTML,
          structured frame data in separate columns.
-/
import TekkenQuery.Models

namespace TekkenQuery

-- ============================================================
-- HTML / text cleaning
-- ============================================================

/--
  Strip HTML tags from a character list.
  Drops everything between '<' and '>'.
-/
def stripHtmlTagsAux : List Char → Bool → List Char
  | [], _ => []
  | c :: rest, inTag =>
    if c == '<' then stripHtmlTagsAux rest true
    else if c == '>' && inTag then stripHtmlTagsAux rest false
    else if inTag then stripHtmlTagsAux rest true
    else c :: stripHtmlTagsAux rest false

/--
  Strip HTML tags from a string.
-/
def stripHtmlTags (s : String) : String :=
  String.ofList (stripHtmlTagsAux s.toList false)

/--
  Strip leading "* " bullet prefix from a trimmed string.
-/
def stripBullet (s : String) : String :=
  let trimmed := s.trimAscii.toString
  match trimmed.toList with
  | '*' :: ' ' :: rest => (String.ofList rest).trimAscii.toString
  | '*' :: rest => (String.ofList rest).trimAscii.toString
  | _ => trimmed

/--
  Clean a notes field: strip HTML, replace newlines with " | ",
  remove bullet prefixes, produce a single line.
-/
def cleanNotesField (s : String) : String :=
  let stripped := stripHtmlTags s
  let lines := stripped.splitOn "\n"
  let cleaned := lines.map stripBullet
  let nonEmpty := cleaned.filter (fun l => !l.isEmpty)
  String.intercalate " | " nonEmpty

/--
  Normalize a hit level string: lowercase, consistent comma spacing.
  "h, m" → "h,m", "M" → "m", "h, h, m" → "h,h,m"
-/
def normalizeHitLevel (s : String) : String :=
  String.intercalate "," ((s.toLower.splitOn ",").map (fun p => p.trimAscii.toString))

-- ============================================================
-- CSV escaping
-- ============================================================

/--
  Double any quote characters in a list for CSV escaping.
-/
def escapeQuotes : List Char → List Char
  | [] => []
  | c :: rest =>
    if c == '"' then '"' :: '"' :: escapeQuotes rest
    else c :: escapeQuotes rest

/--
  Escape a field for CSV output.
  Wraps in quotes if the field contains commas, quotes, or newlines.
-/
def escapeCsvField (s : String) : String :=
  if s.any (fun c => c == ',' || c == '"' || c == '\n' || c == '\r') then
    "\"" ++ String.ofList (escapeQuotes s.toList) ++ "\""
  else s

-- ============================================================
-- Clean CSV schema
-- ============================================================

/--
  Headers for the clean CSV export.
-/
def cleanCsvHeaders : List String :=
  [ "command", "name", "stance", "hit_level", "damage"
  , "startup", "startup_end", "active_frames"
  , "block_frame", "block_guardable", "block_range_end"
  , "hit_frame", "counter_hit_frame"
  , "tags", "notes", "frame_issues"
  ]

/--
  One-line written value for the `frame_issues` column: surrounding
  whitespace is trimmed, other whitespace becomes a space and ';' (the entry
  separator) becomes ','.
-/
def issueWrittenValue (v : String) : String :=
  String.ofList ((Frame.trimChars v).map fun c =>
    if c.isWhitespace then ' ' else if c == ';' then ',' else c)

/--
  Render frame issues as `column:code:written` entries joined by "; ",
  e.g. "startup:range_end_before_start:i25~16".
-/
def renderFrameIssues (issues : List (String × Frame.FrameIssue × String)) : String :=
  "; ".intercalate (issues.map fun (column, issue, v) =>
    s!"{column}:{issue.code}:{issueWrittenValue v}")

/--
  The `frame_issues` field of a move: computed from its raw frame values, or
  carried over unchanged when the move was loaded from a clean CSV (whose
  rebuilt frame strings no longer hold the abnormal text).
-/
def TekkenMove.frameIssuesField (m : TekkenMove) : String :=
  match m.cleanFrameIssues with
  | some text => text
  | none => renderFrameIssues m.frameIssueList

/--
  Convert a TekkenMove to a clean CSV row.
  All fields are normalized, trimmed, and single-line.
-/
def TekkenMove.toCleanRow (m : TekkenMove) : List String :=
  [ m.command
  , cleanNotesField (m.name.getD "")
  , m.stance.getD ""
  , normalizeHitLevel (m.hitLevel.getD "")
  , m.damage.getD ""
  , match m.startupFrameValue with
    | some d => toString d.startup
    | none => ""
  , match m.startupFrameValue with
    | some d => match d.activeEnd with | some e => toString e | none => ""
    | none => ""
  , match m.startupFrameValue with
    | some d => match d.activeFrames with | some n => toString n | none => ""
    | none => ""
  , match m.blockFrameValue with
    | some d => toString d.value
    | none => ""
  , match m.blockFrameValue with
    | some d => if d.guardable then "true" else "false"
    | none => ""
  , match m.blockFrameValue with
    | some d => match d.rangeEnd with | some v => toString v | none => ""
    | none => ""
  , m.hitFrame.getD ""
  , m.counterHitFrame.getD ""
  , m.tags.getD ""
  , cleanNotesField (m.notes.getD "")
  , m.frameIssuesField
  ]

/--
  Convert a list of fields to a CSV line.
-/
def rowToCsvLine (fields : List String) : String :=
  String.intercalate "," (fields.map escapeCsvField)

-- ============================================================
-- Proofs
-- ============================================================

/--
  Every clean row has exactly as many fields as the header.
  This guarantees valid CSV output.
-/
theorem toCleanRow_length (m : TekkenMove) :
    m.toCleanRow.length = cleanCsvHeaders.length := by
  rfl

/--
  A written value in `frame_issues` is one line and never contains the entry
  separator ';'.
-/
theorem issueWrittenValue_safe (v : String) :
    ∀ c ∈ (issueWrittenValue v).toList, c ≠ ';' ∧ (c.isWhitespace = true → c = ' ') := by
  intro c hc
  simp only [issueWrittenValue, String.toList_ofList, List.mem_map] at hc
  obtain ⟨x, -, rfl⟩ := hc
  by_cases hw : x.isWhitespace = true
  · simp [hw]
  · by_cases hs : x = ';'
    · subst hs; decide
    · simp [hw, hs]

/--
  Clean CSV round trip: a move loaded from a clean record exports the same
  `frame_issues` text it was loaded with.
-/
theorem frameIssuesField_fromCleanRecord (rec : List (String × Option String)) (text : String)
    (h : lookupField rec "frame_issues" = some text) :
    (TekkenMove.fromCleanRecord rec).frameIssuesField = text := by
  simp [TekkenMove.frameIssuesField, TekkenMove.fromCleanRecord, h]

/--
  stripHtmlTagsAux never increases the length of the input.
-/
theorem stripHtmlTagsAux_length (chars : List Char) (inTag : Bool) :
    (stripHtmlTagsAux chars inTag).length ≤ chars.length := by
  induction chars generalizing inTag with
  | nil => simp [stripHtmlTagsAux]
  | cons c rest ih =>
    simp only [stripHtmlTagsAux]
    split
    · exact Nat.le_succ_of_le (ih ..)
    · split
      · exact Nat.le_succ_of_le (ih ..)
      · split
        · exact Nat.le_succ_of_le (ih ..)
        · simp [List.length_cons]
          exact ih ..

end TekkenQuery
