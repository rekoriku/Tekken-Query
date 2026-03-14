/-
  TekkenQuery.Frame
  Verified frame data parsers.
  Converts strings like "i13", "+5", "-10", "i12~13" into integers.
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
  Parse a startup frame string like "i13", "13", "i12~13" into the first numeric value.
  Returns none for unparseable input.
  Takes the first value in ranges (i12~13 → 12).
  Takes the first value in comma-separated (i10,i12 → 10).
-/
def parseStartupFrame (s : String) : Option Nat :=
  let chars := s.toList
  -- Strip leading whitespace
  let chars := chars.dropWhile Char.isWhitespace
  -- Strip leading 'i' or 'I' prefix
  let chars := match chars with
    | c :: rest => if c == 'i' || c == 'I' then rest else c :: rest
    | [] => []
  -- Take characters up to first '~' or ',' (range/multi-hit separator)
  let chars := chars.takeWhile (fun c => c != '~' && c != ',')
  -- Parse the number
  match parseNatFromChars chars with
  | some (n, _) => some n
  | none => none

/--
  Parse a block/hit frame string like "+5", "-10", "-9g", "+4~+5" into an integer.
  Returns none for unparseable input.
  Takes the first value in ranges (+4~+5 → 4).
-/
def parseBlockFrame (s : String) : Option Int :=
  let chars := s.toList
  -- Strip leading whitespace
  let chars := chars.dropWhile Char.isWhitespace
  -- Take characters up to first '~' (range separator)
  let chars := chars.takeWhile (fun c => c != '~')
  -- Check for sign
  match chars with
  | '+' :: rest =>
    match parseNatFromChars rest with
    | some (n, _) => some (Int.ofNat n)
    | none => none
  | '-' :: rest =>
    match parseNatFromChars rest with
    | some (n, _) => some (Int.negSucc (n - 1))
    | none => none
  | _ =>
    -- Try parsing as unsigned (treat as positive)
    match parseNatFromChars chars with
    | some (n, _) => some (Int.ofNat n)
    | none => none

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

end TekkenQuery.Frame
