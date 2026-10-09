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
  The guard flag describes the leading value only (see `hasGuardSuffix`):
  "-12~+26g" → { value := -12, guardable := false, rangeEnd := some 26 }.
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
  Handles +N, -N, and unsigned N; "-0" and "+0" both parse to 0.
-/
def parseSignedValue (chars : List Char) : Option (Int × List Char) :=
  match chars with
  | '+' :: rest =>
    match parseNatFromChars rest with
    | some (n, remaining) => some (Int.ofNat n, remaining)
    | none => none
  | '-' :: rest =>
    match parseNatFromChars rest with
    | some (n, remaining) => some (-(Int.ofNat n), remaining)
    | none => none
  | _ =>
    match parseNatFromChars chars with
    | some (n, remaining) => some (Int.ofNat n, remaining)
    | none => none

/--
  Check if a character can be part of a frame suffix code: a lowercase ASCII
  letter. Uppercase letters start stance abbreviations ("BT", "GMH", "JGR").
-/
def isSuffixChar (c : Char) : Bool :=
  c.val ≥ 97 && c.val ≤ 122

/--
  The suffix code attached to a number: the longest run of lowercase ASCII
  letters directly after its digits. "cg rest" → "cg"; " JGR" → "".
-/
def attachedSuffix (remaining : List Char) : List Char :=
  remaining.takeWhile isSuffixChar

/--
  Guard rule: a value is guardable iff the suffix attached to its leading
  number contains 'g'. Anything after the first character that is not a
  lowercase letter — a space, '(', '/', ',', '?', '~' or an uppercase stance
  abbreviation — never affects the result.

  Evidence (data/raw, 41 characters, 2026-10-09): the attached suffix codes
  that occur on block, hit and counter-hit values are a, b, c, d, f, g, s and
  the combinations cg, gc and cs. Real values the rule must reject:
  "+12 JGR" and "+5 GMH" (stance names), "+14 (+24g)" and "+6 (+20g)" (the g
  belongs to the parenthetical value). Ambiguous: "+13c g" (Lee df+3,2,3 hit)
  is read conservatively as not guardable because the g is detached, while
  "+19g c" is guardable.
-/
def hasGuardSuffix (remaining : List Char) : Bool :=
  (attachedSuffix remaining).contains 'g'

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
  -- Take characters up to comma or space (multi-hit separators)
  -- Raw data uses spaces between per-hit startups: "i13 i32~75"
  let chars := chars.takeWhile (fun c => c != ',' && !c.isWhitespace)
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
  Regression: "-0" (Lee b+1, b+2,4,3 on block) parses to 0, not -1.
-/
theorem parseBlockFrame_neg_zero :
    parseBlockFrame "-0" = some { value := 0 } := by
  rfl

/--
  Negative values keep their magnitude: "-10" parses to -10.
-/
theorem parseBlockFrame_neg_ten :
    parseBlockFrame "-10" = some { value := -10 } := by
  rfl

/--
  Regression: uppercase stance abbreviations after a space ("JGR", "GMH")
  are not guard suffixes.
-/
theorem parseBlockFrame_stance_jgr :
    parseBlockFrame "+12 JGR" = some { value := 12 } := by
  rfl

theorem parseBlockFrame_stance_gmh :
    parseBlockFrame "+5 GMH" = some { value := 5 } := by
  rfl

theorem parseBlockFrame_suffix_then_stance :
    parseBlockFrame "+9c JGR" = some { value := 9 } := by
  rfl

/--
  Regression: a 'g' inside a parenthetical value belongs to that value.
-/
theorem parseBlockFrame_parenthetical_guard :
    parseBlockFrame "+14 (+24g)" = some { value := 14 } := by
  rfl

/--
  Attached guard suffixes, alone or combined with other codes, still count.
-/
theorem parseBlockFrame_guard_suffix :
    parseBlockFrame "+15g" = some { value := 15, guardable := true } := by
  rfl

theorem parseBlockFrame_combined_guard_suffix :
    parseBlockFrame "+18cg" = some { value := 18, guardable := true } := by
  rfl

theorem parseBlockFrame_guard_then_detached_code :
    parseBlockFrame "+19g c" = some { value := 19, guardable := true } := by
  rfl

/--
  Ambiguous "+13c g": the detached g is not read as a guard suffix.
-/
theorem parseBlockFrame_detached_guard :
    parseBlockFrame "+13c g" = some { value := 13 } := by
  rfl

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

/--
  Multi-hit startup: space-separated hits only take first hit.
  "i13 i32~75" → startup 13, no activeEnd (not 75 from second hit).
  Regression test: prevents the bug where tilde from subsequent hits
  contaminated the first hit's activeEnd.
-/
theorem parseStartupFrame_multi_hit_space :
    parseStartupFrame "i13 i32~75" = some { startup := 13, activeEnd := none } := by
  rfl

/--
  Multi-hit startup: comma-separated hits only take first hit.
-/
theorem parseStartupFrame_multi_hit_comma :
    parseStartupFrame "i10,i12" = some { startup := 10, activeEnd := none } := by
  rfl

/--
  Single-hit startup with active frame range is preserved.
  "i12~13" → startup 12, activeEnd 13.
-/
theorem parseStartupFrame_preserves_range :
    parseStartupFrame "i12~13" = some { startup := 12, activeEnd := some 13 } := by
  rfl

/--
  Plain startup without range.
  "i15" → startup 15, no activeEnd.
-/
theorem parseStartupFrame_plain :
    parseStartupFrame "i15" = some { startup := 15, activeEnd := none } := by
  rfl

end TekkenQuery.Frame
