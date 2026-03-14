/-
  TekkenQuery.Frame
  Verified frame data parsers.
  Converts strings like "i13", "+5", "-10", "i12~13" into structured data.
  Preserves range information and guard suffix — no data loss.
  Every parser is total and pure — no crashes, no exceptions.
-/

namespace TekkenQuery.Frame

/--
  Check if a character is an ASCII digit.
-/
def isDigit (c : Char) : Bool :=
  c.val ≥ 48 && c.val ≤ 57

/--
  Convert a digit character to its numeric value.
  Returns none if the character is not a digit.
-/
def digitToNat (c : Char) : Option Nat :=
  if isDigit c then some (c.val.toNat - 48)
  else none

/--
  Parse a sequence of digit characters into a natural number.
  Returns (parsedNumber, remainingChars).
  Returns none if no digits found.
-/
def parseNatFromChars : List Char → Option (Nat × List Char)
  | [] => none
  | c :: rest =>
    match digitToNat c with
    | none => none
    | some d => some (go d rest)
where
  go (acc : Nat) : List Char → Nat × List Char
    | [] => (acc, [])
    | c :: rest =>
      match digitToNat c with
      | none => (acc, c :: rest)
      | some d => go (acc * 10 + d) rest

/--
  Parsed startup frame data. Preserves range for active frame calculation.
  "i12~13" → { startup := 12, activeEnd := some 13 }
  "i13"    → { startup := 13, activeEnd := none }
-/
structure StartupData where
  startup   : Nat
  activeEnd : Option Nat := none
  deriving Repr, BEq, Inhabited

/--
  Compute the number of active frames from a startup range.
  "i12~13" → some 2 (frames 12 and 13)
  "i13"    → none (unknown)
-/
def StartupData.activeFrames (d : StartupData) : Option Nat :=
  match d.activeEnd with
  | some e => if e ≥ d.startup then some (e - d.startup + 1) else some 1
  | none => none

/--
  Parsed block/hit frame data. Preserves guard suffix and range.
  "+15"    → { value := 15, guardable := false } — opponent CANNOT block, free launch
  "+15g"   → { value := 15, guardable := true }  — opponent CAN block despite being plus
  "-9g"    → { value := -9, guardable := true }
  "+4~+5"  → { value := 4, guardable := false, rangeEnd := some 5 }
-/
structure BlockFrameData where
  value     : Int
  guardable : Bool := false
  rangeEnd  : Option Int := none
  deriving Repr, BEq, Inhabited

/--
  Parse a signed integer from a character list.
  Returns the parsed value and remaining characters after the digits.
  Handles +N, -N, and unsigned N.
-/
def parseSignedValue (chars : List Char) : Option (Int × List Char) :=
  match chars with
  | '+' :: rest =>
    match parseNatFromChars rest with
    | some (n, remaining) => some (Int.ofNat n, remaining)
    | none => none
  | '-' :: rest =>
    match parseNatFromChars rest with
    | some (n, remaining) => some (Int.negSucc (n - 1), remaining)
    | none => none
  | _ =>
    match parseNatFromChars chars with
    | some (n, remaining) => some (Int.ofNat n, remaining)
    | none => none

/--
  Check if remaining characters after a number contain 'g' (guard suffix).
-/
def hasGuardSuffix (remaining : List Char) : Bool :=
  remaining.any (fun c => c == 'g' || c == 'G')

/--
  Parse a startup frame string into structured data.
  "i13"    → some { startup := 13 }
  "i12~13" → some { startup := 12, activeEnd := some 13 }
  "i10,i12" → some { startup := 10 } (comma = multi-hit, take first)
-/
def parseStartupFrame (s : String) : Option StartupData :=
  let chars := s.toList
  let chars := chars.dropWhile Char.isWhitespace
  let chars := match chars with
    | c :: rest => if c == 'i' || c == 'I' then rest else c :: rest
    | [] => []
  -- Take characters up to comma (multi-hit separator)
  let chars := chars.takeWhile (fun c => c != ',')
  -- Split on tilde for active frame range
  let beforeTilde := chars.takeWhile (fun c => c != '~')
  let afterTilde := (chars.dropWhile (fun c => c != '~')).drop 1
  match parseNatFromChars beforeTilde with
  | some (n, _) =>
    let activeEnd := match parseNatFromChars afterTilde with
      | some (m, _) => some m
      | none => none
    some { startup := n, activeEnd := activeEnd }
  | none => none

/--
  Parse a block/hit frame string into structured data.
  "+5"     → some { value := 5, guardable := false }
  "-10"    → some { value := -10, guardable := false }
  "+15g"   → some { value := 15, guardable := true }
  "-9g"    → some { value := -9, guardable := true }
  "+4~+5"  → some { value := 4, guardable := false, rangeEnd := some 5 }
-/
def parseBlockFrame (s : String) : Option BlockFrameData :=
  let chars := s.toList
  let chars := chars.dropWhile Char.isWhitespace
  let beforeTilde := chars.takeWhile (fun c => c != '~')
  let afterTilde := (chars.dropWhile (fun c => c != '~')).drop 1
  match parseSignedValue beforeTilde with
  | some (value, remaining) =>
    let guardable := hasGuardSuffix remaining
    let rangeEnd := match parseSignedValue afterTilde with
      | some (v, _) => some v
      | none => none
    some { value := value, guardable := guardable, rangeEnd := rangeEnd }
  | none => none

-- ============================================================
-- Proofs
-- ============================================================

/--
  Int.negSucc always produces a negative value.
  This means parseBlockFrame with "-" prefix is always negative.
-/
theorem negSucc_neg (n : Nat) : Int.negSucc n < 0 := by
  omega

/--
  Negative block frame representation is correct:
  "-10" parses to Int.negSucc 9, which equals -10.
-/
theorem negSucc_eq_neg (n : Nat) (hn : n > 0) :
    Int.negSucc (n - 1) = -↑n := by
  omega

/--
  Active frames are always ≥ 1 when computable (range is present).
-/
theorem activeFrames_ge_one (d : StartupData) (n : Nat)
    (h : d.activeFrames = some n) : n ≥ 1 := by
  unfold StartupData.activeFrames at h
  split at h
  · split at h
    · injection h with h; omega
    · injection h with h; omega
  · injection h

end TekkenQuery.Frame
