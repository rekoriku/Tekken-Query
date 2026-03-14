/-
  TekkenQuery.Csv.Parser
  Verified CSV parser with integrated cleaning.
  Handles multiline quoted fields, delimiter detection, and value cleaning
  in a single pipeline. Output records have clean Option String values.
-/
import TekkenQuery.Csv.Types
import TekkenQuery.Csv.Split

namespace TekkenQuery.Csv

/--
  A clean record: each field is (headerName, cleanedValue).
  None means the field was empty, "nan", or whitespace-only.
-/
abbrev CleanRecord := List (String × Option String)

/--
  Zip headers with raw field values, cleaning each value.
  If values is shorter than headers, missing values become none.
  If values is longer than headers, extra values are dropped.
-/
def zipAndClean (headers : List String) (values : List String) : CleanRecord :=
  match headers, values with
  | [], _ => []
  | h :: hs, [] => (h, none) :: zipAndClean hs []
  | h :: hs, v :: vs => (h, cleanField v) :: zipAndClean hs vs

/--
  zipAndClean always produces exactly as many pairs as there are headers.
-/
theorem zipAndClean_length (headers values : List String) :
    (zipAndClean headers values).length = headers.length := by
  induction headers generalizing values with
  | nil => simp [zipAndClean]
  | cons h hs ih =>
    cases values with
    | nil => simp [zipAndClean, ih]
    | cons v vs => simp [zipAndClean, ih]

/--
  Every key in a zipAndClean result comes from the headers list.
-/
theorem zipAndClean_keys (headers values : List String) :
    (zipAndClean headers values).map Prod.fst = headers := by
  induction headers generalizing values with
  | nil => simp [zipAndClean]
  | cons h hs ih =>
    cases values with
    | nil => simp [zipAndClean, ih]
    | cons v vs => simp [zipAndClean, ih]

/--
  Detect the delimiter used in a CSV header line.
  Prefers semicolon if present (matching the tekkendocs format).
-/
def detectDelimiter (headerLine : String) : Delimiter :=
  if headerLine.toList.any (· == ';') then .semicolon
  else .comma

/--
  Parse a single raw record into a CleanRecord using headers.
-/
def parseRecord (headers : List String) (rawFields : List String) : CleanRecord :=
  zipAndClean headers rawFields

/--
  parseRecord always produces exactly headers.length fields.
-/
theorem parseRecord_length (headers rawFields : List String) :
    (parseRecord headers rawFields).length = headers.length := by
  unfold parseRecord
  exact zipAndClean_length headers rawFields

/--
  Build clean records from headers and raw record data.
-/
def buildRecords (headers : List String) (rawRecords : List (List String)) : List CleanRecord :=
  rawRecords.map (parseRecord headers)

/--
  buildRecords preserves record count.
-/
theorem buildRecords_length (headers : List String) (rawRecords : List (List String)) :
    (buildRecords headers rawRecords).length = rawRecords.length := by
  unfold buildRecords
  exact List.length_map ..

/--
  Every record from buildRecords has exactly headers.length fields.
-/
theorem buildRecords_field_count (headers : List String)
    (rawRecords : List (List String)) (rec : CleanRecord)
    (hmem : rec ∈ buildRecords headers rawRecords) :
    rec.length = headers.length := by
  unfold buildRecords at hmem
  simp [List.mem_map] at hmem
  obtain ⟨rawRec, _, rfl⟩ := hmem
  exact parseRecord_length headers rawRec

/--
  Result of a successful parse.
-/
structure ParseResult where
  headers : List String
  records : List CleanRecord
  deriving Repr

/--
  Parse a full CSV string.
  - Detects delimiter from header row
  - Handles multiline quoted fields
  - Cleans all values (trim, nan → none)
  - Returns error for empty input or single-column data
-/
def parse (input : String) : Except ParseError ParseResult :=
  -- First, detect delimiter from the first line (before any multiline fields)
  let firstLineEnd := input.toList.takeWhile (fun c => c != '\n' && c != '\r')
  let headerLine := String.ofList firstLineEnd
  if headerLine.isEmpty then
    .error .emptyInput
  else
    let delim := detectDelimiter headerLine
    let delimChar := delim.toChar
    -- Now parse the entire input respecting quotes across newlines
    let allRecords := splitRecords input delimChar
    -- Filter out empty records (blank lines)
    let nonEmptyRecords := allRecords.filter (fun r => r.length > 1 || (r.length == 1 && !(strip (r.head!)).isEmpty))
    match nonEmptyRecords with
    | [] => .error .emptyInput
    | headerFields :: dataRecords =>
      let headers := headerFields.map strip
      if headers.length ≤ 1 then
        .error .singleColumn
      else
        let cleanRecords := buildRecords headers dataRecords
        .ok { headers, records := cleanRecords }

end TekkenQuery.Csv
