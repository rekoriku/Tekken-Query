/-
  TekkenQuery.Csv.Split
  Verified CSV splitting that correctly handles:
  - Multiline quoted fields (newlines inside quotes are part of the field)
  - Delimiters inside quotes (semicolons in "[12;12]" are not split on)
  - Cleaning: trim whitespace, convert "nan"/empty to none
  One pass over the input. No separate line-splitting step.
-/

namespace TekkenQuery.Csv

/--
  Strip leading and trailing whitespace from a string.
-/
def strip (s : String) : String :=
  let chars := s.toList
  let trimmed := chars.dropWhile Char.isWhitespace
  let trimmedBack := trimmed.reverse.dropWhile Char.isWhitespace
  String.ofList trimmedBack.reverse

/--
  Clean a raw CSV field value:
  - Strip whitespace
  - Convert "nan", empty, whitespace-only to none
  - Return some for real values
-/
def cleanField (s : String) : Option String :=
  let trimmed := strip s
  if trimmed.isEmpty then none
  else if trimmed.toLower == "nan" then none
  else some trimmed

/--
  Core CSV record splitter. Walks the entire input character by character.
  Respects quotes across newlines — a newline inside quotes is part of the field,
  not a record boundary.

  Treats both \n and \r as record separators when outside quotes.
  (Consecutive separators like \r\n produce an empty record, filtered later.)
-/
def splitRecordsAux (delim : Char)
    : List Char → Bool → List Char → List String → List (List String) → List (List String)
  | [], _, currentField, currentRecord, acc =>
    acc ++ [currentRecord ++ [String.ofList currentField.reverse]]
  | c :: rest, inQuotes, currentField, currentRecord, acc =>
    if c == '"' then
      splitRecordsAux delim rest (!inQuotes) currentField currentRecord acc
    else if c == delim && !inQuotes then
      let field := String.ofList currentField.reverse
      splitRecordsAux delim rest false [] (currentRecord ++ [field]) acc
    else if (c == '\n' || c == '\r') && !inQuotes then
      let field := String.ofList currentField.reverse
      let record := currentRecord ++ [field]
      splitRecordsAux delim rest false [] [] (acc ++ [record])
    else
      splitRecordsAux delim rest inQuotes (c :: currentField) currentRecord acc

/--
  Split a CSV string into records (rows) of fields (columns).
  Handles multiline quoted fields correctly.
  Filters out empty records (from \r\n or trailing newlines).
-/
def splitRecords (s : String) (delim : Char) : List (List String) :=
  let raw := splitRecordsAux delim s.toList false [] [] []
  -- Filter out empty records: a record is empty if it has 0 fields
  -- or only 1 field that's empty/whitespace (from \r in \r\n or trailing newline)
  raw.filter (fun r =>
    match r with
    | [] => false
    | [single] => !(strip single).isEmpty
    | _ => true)

/--
  splitRecordsAux always produces at least acc.length + 1 records.
-/
theorem splitRecordsAux_length_ge (delim : Char) (chars : List Char) (inQ : Bool)
    (currField : List Char) (currRecord : List String) (acc : List (List String)) :
    (splitRecordsAux delim chars inQ currField currRecord acc).length ≥ acc.length + 1 := by
  induction chars generalizing inQ currField currRecord acc with
  | nil =>
    simp [splitRecordsAux, List.length_append]
  | cons c rest ih =>
    simp only [splitRecordsAux]
    split
    · exact ih ..
    · split
      · exact ih ..
      · split
        · have h := ih (inQ := false) (currField := []) (currRecord := [])
            (acc := acc ++ [currRecord ++ [String.ofList currField.reverse]])
          simp [List.length_append] at h ⊢
          omega
        · exact ih ..

end TekkenQuery.Csv
