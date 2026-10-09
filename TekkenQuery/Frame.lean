/-
  TekkenQuery.Frame
  Verified frame data parsers.
  Converts strings like "i13", "+5", "-10", "i12~13" into structured data.
  Preserves range information and guard suffix — no data loss.
  Every parser is total and pure — no crashes, no exceptions.

  Proved properties (general, over all inputs): digit runs parse to their
  decimal value and keep the rest; '+'/unsigned values are ≥ 0 and '-'
  values ≤ 0, with "-0" = "+0" = 0; `renderSignedValue` (+N / -N / 0) and
  `toString`-based startup ranges round-trip; the guard flag depends only on
  the suffix attached to the leading number; later multi-hit startups never
  change the result. Real data values are kept as `rfl` regression theorems.
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
  Drop one optional impact-frame prefix 'i' or 'I' ("i13" → "13").
-/
def dropImpactPrefix : List Char → List Char
  | c :: rest => if c == 'i' || c == 'I' then rest else c :: rest
  | [] => []

/--
  The first hit's startup token: leading whitespace and one 'i'/'I' prefix
  removed, cut at the first comma or whitespace (multi-hit separators).
  Raw data uses spaces between per-hit startups: "i13 i32~75" → "13".
-/
def startupToken (chars : List Char) : List Char :=
  (dropImpactPrefix (chars.dropWhile Char.isWhitespace)).takeWhile
    (fun c => c != ',' && !c.isWhitespace)

/--
  Startup range separators. '~' is the canonical form; '-' is hand-typed in
  the data ("i13-14", Lee df+4). Startup frames are never negative, so a '-'
  inside a startup value can only separate a range.
-/
def isRangeSep (c : Char) : Bool :=
  c == '~' || c == '-'

/--
  The first hit's startup range exactly as written: start and optional end,
  before their order is checked.
  The range end may be written "~N", "-N", "~iN" or "-iN": the separator is
  '~' or '-', and the end may repeat the impact-frame prefix 'i'/'I'
  ("i15-i16" → (15, some 16)). "i25~16" → (25, some 16).
-/
def parseStartupRange (s : String) : Option (Nat × Option Nat) :=
  let chars := startupToken s.toList
  let beforeSep := chars.takeWhile (fun c => !isRangeSep c)
  let afterSep := dropImpactPrefix ((chars.dropWhile (fun c => !isRangeSep c)).drop 1)
  match parseNatFromChars beforeSep with
  | some (n, _) =>
    let writtenEnd := match parseNatFromChars afterSep with
      | some (m, _) => some m
      | none => none
    some (n, writtenEnd)
  | none => none

/--
  Keep a written range end only when it does not precede the start. An end
  before the start cannot be explained ("i25~16"); it is dropped as unknown
  and reported by `startupIssues` instead of being guessed.
-/
def orderedEnd (start : Nat) : Option Nat → Option Nat
  | some e => if start ≤ e then some e else none
  | none => none

/--
  Parse a startup frame string into structured data.
  "i13"     → some { startup := 13 }
  "i12~13"  → some { startup := 12, activeEnd := some 13 }
  "i10,i12" → some { startup := 10 } (comma = multi-hit, take first)
  "i13-14"  → some { startup := 13, activeEnd := some 14 }
  "i25~16"  → some { startup := 25 } (end before start: unknown, flagged)
-/
def parseStartupFrame (s : String) : Option StartupData :=
  (parseStartupRange s).map fun r => { startup := r.1, activeEnd := orderedEnd r.1 r.2 }

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

/--
  Render a frame value in the data's notation: "+N" for positive values,
  "-N" for negative values and "0" for zero. `parseSignedValue` inverts it
  exactly (`parseSignedValue_renderSignedValue`).
-/
def renderSignedValue : Int → String
  | .ofNat 0 => "0"
  | .ofNat (n + 1) => "+" ++ toString (n + 1)
  | .negSucc m => "-" ++ toString (m + 1)

-- ============================================================
-- Abnormal source data
-- ============================================================

/--
  A frame value that the notation cannot explain: most likely a human typo
  in the source data (the Wavu wiki), reported so it can be fixed there.
  Parsers never guess a correction.
-/
inductive FrameIssue where
  /-- A startup range whose written end precedes its start ("i25~16"). -/
  | rangeEndBeforeStart (start finish : Nat)
  /-- Two signs or range separators in a row ("--3", "i39~-41"). -/
  | doubledSign
  /-- Neither a frame value nor a known notation (counter hit "js"). -/
  | unrecognized
  deriving Repr, BEq, DecidableEq

/-- Stable machine-readable code, used in the clean CSV `frame_issues` column. -/
def FrameIssue.code : FrameIssue → String
  | .rangeEndBeforeStart _ _ => "range_end_before_start"
  | .doubledSign => "doubled_sign"
  | .unrecognized => "unrecognized"

/-- Whether two characters satisfying `marks` stand next to each other. -/
def hasAdjacent (marks : Char → Bool) : List Char → Bool
  | [] => false
  | a :: rest => (marks a && (rest.head?.map marks).getD false) || hasAdjacent marks rest

/-- Signs of block, hit and counter-hit values. -/
def isSignChar (c : Char) : Bool :=
  c == '+' || c == '-'

/-- Signs and range separators of startup values (startups are unsigned). -/
def isStartupMark (c : Char) : Bool :=
  c == '+' || c == '-' || c == '~'

/-- A value's characters without surrounding whitespace. -/
def trimChars (s : String) : List Char :=
  ((s.toList.dropWhile Char.isWhitespace).reverse.dropWhile Char.isWhitespace).reverse

/--
  Known non-numeric block, hit and counter-hit notation (data/raw,
  2026-10-09): "!" unblockable, "N/A" not applicable, "KND" knockdown and
  "LNC" launch results, "th" becomes a throw on hit.
-/
def knownFrameNotations : List (List Char) :=
  [['!'], ['N', '/', 'A'], ['K', 'N', 'D'], ['L', 'N', 'C'], ['t', 'h']]

/-- Whether a block, hit or counter-hit value is known non-numeric notation. -/
def knownFrameNotation (s : String) : Bool :=
  knownFrameNotations.contains (trimChars s)

/--
  Known non-numeric startup notation (data/raw, 2026-10-09): a leading comma
  (",i14~15": the first hit has no startup of its own), jump status "js12",
  per-state variants starting "N/A" ("N/A / i26~i31 Heat") and "(depends)".
-/
def knownStartupNotation (s : String) : Bool :=
  match trimChars s with
  | ',' :: _ => true
  | 'j' :: 's' :: d :: _ => isDigit d
  | 'N' :: '/' :: 'A' :: _ => true
  | cs => cs == ['(', 'd', 'e', 'p', 'e', 'n', 'd', 's', ')']

/--
  Abnormal startup values: a first-hit range ending before it starts, two
  signs or separators in a row anywhere in the value, or a value that does
  not parse and is not known notation.
-/
def startupIssues (s : String) : List FrameIssue :=
  let inverted := match parseStartupRange s with
    | some (n, some e) => if e < n then [FrameIssue.rangeEndBeforeStart n e] else []
    | _ => []
  let doubled := if hasAdjacent isStartupMark s.toList then [FrameIssue.doubledSign] else []
  let unrecognized :=
    if (parseStartupRange s).isNone && !knownStartupNotation s &&
        !hasAdjacent isStartupMark s.toList then
      [FrameIssue.unrecognized]
    else []
  inverted ++ doubled ++ unrecognized

/--
  Abnormal block, hit or counter-hit values: two signs in a row anywhere in
  the value, or a value that does not parse and is not known notation.
-/
def frameIssues (s : String) : List FrameIssue :=
  if hasAdjacent isSignChar s.toList then [FrameIssue.doubledSign]
  else if (parseBlockFrame s).isNone && !knownFrameNotation s then [FrameIssue.unrecognized]
  else []

-- ============================================================
-- Proofs
-- ============================================================

-- ------------------------------------------------------------
-- Character facts
-- ------------------------------------------------------------

/-- Characters that start a signed value are never whitespace. -/
theorem isWhitespace_of_isDigit {c : Char} (h : isDigit c = true) :
    c.isWhitespace = false := by
  cases hw : c.isWhitespace
  · rfl
  · simp only [Char.isWhitespace, Bool.or_eq_true, decide_eq_true_eq] at hw
    rcases hw with ((hw | hw) | hw) | hw <;> subst hw <;> simp [isDigit] at h

/-- Suffix code letters are never digits. -/
theorem isDigit_of_isSuffixChar {c : Char} (h : isSuffixChar c = true) :
    isDigit c = false := by
  simp [isSuffixChar, isDigit, UInt32.le_iff_toNat_le] at *
  omega

/-- Digits are not the range separator '~'. -/
theorem ne_tilde_of_isDigit {c : Char} (h : isDigit c = true) : c ≠ '~' := by
  intro hc; subst hc; simp [isDigit] at h

/-- Digits are neither multi-hit separator: not ',' and not whitespace. -/
theorem startupChar_of_isDigit {c : Char} (h : isDigit c = true) :
    (c != ',' && !c.isWhitespace) = true := by
  have hw := isWhitespace_of_isDigit h
  have hc : c ≠ ',' := by intro hc; subst hc; simp [isDigit] at h
  simp [hw, hc]

/-- Suffix code letters are not the range separator '~'. -/
theorem ne_tilde_of_isSuffixChar {c : Char} (h : isSuffixChar c = true) : c ≠ '~' := by
  intro hc; subst hc; simp [isSuffixChar] at h

-- ------------------------------------------------------------
-- Natural numbers: parseNatFromChars
-- ------------------------------------------------------------

/-- One step of reading a decimal digit, most significant first. -/
def digitStep (acc : Nat) (c : Char) : Nat :=
  acc * 10 + (c.val.toNat - 48)

/-- Decimal value of a list of digit characters. -/
def digitsValue (ds : List Char) : Nat :=
  ds.foldl digitStep 0

theorem digitToNat_of_isDigit {c : Char} (h : isDigit c = true) :
    digitToNat c = some (c.val.toNat - 48) := by
  simp [digitToNat, h]

theorem digitToNat_of_not_isDigit {c : Char} (h : isDigit c = false) :
    digitToNat c = none := by
  simp [digitToNat, h]

/-- `parseNatFromChars` fails on input that does not start with a digit. -/
theorem parseNatFromChars_eq_none (cs : List Char)
    (h : ∀ c ∈ cs.head?, isDigit c = false) : parseNatFromChars cs = none := by
  cases cs with
  | nil => rfl
  | cons c cs =>
    simp [parseNatFromChars, digitToNat_of_not_isDigit (h c rfl)]

/-- The digit loop consumes exactly the digit run and keeps the rest. -/
theorem parseNatFromChars_go_append (acc : Nat) (ds rest : List Char)
    (hds : ∀ c ∈ ds, isDigit c = true) (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    parseNatFromChars.go acc (ds ++ rest) = (ds.foldl digitStep acc, rest) := by
  induction ds generalizing acc with
  | nil =>
    cases rest with
    | nil => rfl
    | cons c rest =>
      simp [parseNatFromChars.go, digitToNat_of_not_isDigit (hrest c rfl)]
  | cons d ds ih =>
    simp only [List.cons_append, parseNatFromChars.go,
      digitToNat_of_isDigit (hds d (by simp)), List.foldl_cons]
    exact ih _ (fun c hc => hds c (by simp [hc]))

/--
  For any non-empty digit run followed by a non-digit (or the end),
  `parseNatFromChars` returns the run's decimal value and exactly the rest.
-/
theorem parseNatFromChars_append (ds rest : List Char) (hne : ds ≠ [])
    (hds : ∀ c ∈ ds, isDigit c = true) (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    parseNatFromChars (ds ++ rest) = some (digitsValue ds, rest) := by
  cases ds with
  | nil => exact absurd rfl hne
  | cons d ds =>
    simp only [List.cons_append, parseNatFromChars, digitToNat_of_isDigit (hds d (by simp))]
    rw [parseNatFromChars_go_append _ ds rest (fun c hc => hds c (by simp [hc])) hrest]
    simp [digitsValue, digitStep]

theorem digitChar_spec : ∀ k, k < 10 →
    isDigit (Nat.digitChar k) = true ∧ (Nat.digitChar k).val.toNat - 48 = k := by
  decide

theorem toDigitsCore_spec (fuel n : Nat) (ds : List Char) (h : n < fuel) :
    ∃ l, Nat.toDigitsCore 10 fuel n ds = l ++ ds ∧ l ≠ [] ∧
      (∀ c ∈ l, isDigit c = true) ∧ l.foldl digitStep 0 = n := by
  induction fuel generalizing n ds with
  | zero => omega
  | succ fuel ih =>
    have hdig := digitChar_spec (n % 10) (Nat.mod_lt _ (by omega))
    simp only [Nat.toDigitsCore]
    split
    · refine ⟨[Nat.digitChar (n % 10)], rfl, by simp, by simpa using hdig.1, ?_⟩
      simp only [List.foldl_cons, List.foldl_nil, digitStep, hdig.2]
      omega
    · obtain ⟨l, hl, -, hall, hval⟩ := ih (n / 10) (Nat.digitChar (n % 10) :: ds) (by omega)
      refine ⟨l ++ [Nat.digitChar (n % 10)], by simp [hl], by simp, ?_, ?_⟩
      · intro c hc
        simp only [List.mem_append, List.mem_singleton] at hc
        rcases hc with hc | hc
        · exact hall c hc
        · subst hc; exact hdig.1
      · simp only [List.foldl_append, hval, List.foldl_cons, List.foldl_nil, digitStep, hdig.2]
        omega

/-- `toString n` is a non-empty digit run whose value is `n`. -/
theorem toString_digits (n : Nat) :
    (toString n).toList ≠ [] ∧ (∀ c ∈ (toString n).toList, isDigit c = true) ∧
      digitsValue (toString n).toList = n := by
  obtain ⟨l, hl, hne, hall, hval⟩ := toDigitsCore_spec (n + 1) n [] (by omega)
  have : (toString n).toList = l := by
    simp only [toString, Nat.repr, String.toList_ofList, Nat.toDigits, hl, List.append_nil]
  rw [this]
  exact ⟨hne, hall, hval⟩

/-- Round trip for naturals: parsing `toString n` gives `n` and keeps the rest. -/
theorem parseNatFromChars_toString (n : Nat) (rest : List Char)
    (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    parseNatFromChars ((toString n).toList ++ rest) = some (n, rest) := by
  obtain ⟨hne, hall, hval⟩ := toString_digits n
  rw [parseNatFromChars_append _ _ hne hall hrest, hval]

-- ------------------------------------------------------------
-- Signed values: parseSignedValue
-- ------------------------------------------------------------

theorem parseSignedValue_plus (cs : List Char) :
    parseSignedValue ('+' :: cs) =
      (parseNatFromChars cs).map (fun p => (Int.ofNat p.1, p.2)) := by
  simp only [parseSignedValue]
  cases parseNatFromChars cs <;> rfl

theorem parseSignedValue_minus (cs : List Char) :
    parseSignedValue ('-' :: cs) =
      (parseNatFromChars cs).map (fun p => (-Int.ofNat p.1, p.2)) := by
  simp only [parseSignedValue]
  cases parseNatFromChars cs <;> rfl

theorem parseSignedValue_unsigned (cs : List Char)
    (hplus : cs.head? ≠ some '+') (hminus : cs.head? ≠ some '-') :
    parseSignedValue cs = (parseNatFromChars cs).map (fun p => (Int.ofNat p.1, p.2)) := by
  unfold parseSignedValue
  split
  · simp at hplus
  · simp at hminus
  · cases parseNatFromChars cs <;> rfl

/-- A '-' sign negates exactly what the same digits give with '+'. -/
theorem parseSignedValue_minus_eq_neg_plus (cs : List Char) :
    parseSignedValue ('-' :: cs) =
      (parseSignedValue ('+' :: cs)).map (fun p => (-p.1, p.2)) := by
  rw [parseSignedValue_minus, parseSignedValue_plus]
  cases parseNatFromChars cs <;> rfl

/-- Sign correctness: input without a leading '-' never parses negative. -/
theorem parseSignedValue_nonneg {cs : List Char} {v : Int} {rest : List Char}
    (hminus : cs.head? ≠ some '-') (h : parseSignedValue cs = some (v, rest)) : 0 ≤ v := by
  cases cs with
  | nil => simp [parseSignedValue, parseNatFromChars] at h
  | cons c cs =>
    by_cases hc : c = '+'
    · subst hc
      rw [parseSignedValue_plus] at h
      cases hp : parseNatFromChars cs <;> simp [hp] at h
      omega
    · rw [parseSignedValue_unsigned _ (by simpa using hc) hminus] at h
      cases hp : parseNatFromChars (c :: cs) <;> simp [hp] at h
      omega

/-- Sign correctness: input with a leading '-' never parses positive. -/
theorem parseSignedValue_nonpos {cs : List Char} {v : Int} {rest : List Char}
    (h : parseSignedValue ('-' :: cs) = some (v, rest)) : v ≤ 0 := by
  rw [parseSignedValue_minus] at h
  cases hp : parseNatFromChars cs <;> simp [hp] at h
  omega

/-- "-0", "+0" and "0" all parse to 0, whatever non-digit text follows. -/
theorem parseSignedValue_zero (rest : List Char) (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    parseSignedValue ('-' :: '0' :: rest) = some (0, rest) ∧
    parseSignedValue ('+' :: '0' :: rest) = some (0, rest) ∧
    parseSignedValue ('0' :: rest) = some (0, rest) := by
  have h0 := parseNatFromChars_append ['0'] rest (by simp) (by decide) hrest
  have hv : digitsValue ['0'] = 0 := by decide
  rw [hv] at h0
  refine ⟨?_, ?_, ?_⟩
  · rw [parseSignedValue_minus, List.singleton_append] at *; simp [h0]
  · rw [parseSignedValue_plus, List.singleton_append] at *; simp [h0]
  · rw [List.singleton_append] at h0
    rw [parseSignedValue_unsigned _ (by simp) (by simp), h0]; rfl

/-- A sign prefix: none, '+' or '-'. -/
def IsSign (sign : List Char) : Prop :=
  sign = [] ∨ sign = ['+'] ∨ sign = ['-']

/-- An optional sign and a digit run are consumed exactly; the rest is kept. -/
theorem parseSignedValue_sign_digits (sign ds rest : List Char) (hsign : IsSign sign)
    (hne : ds ≠ []) (hds : ∀ c ∈ ds, isDigit c = true)
    (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    ∃ v, parseSignedValue (sign ++ ds ++ rest) = some (v, rest) := by
  have hn := parseNatFromChars_append ds rest hne hds hrest
  rcases hsign with rfl | rfl | rfl
  · cases ds with
    | nil => exact absurd rfl hne
    | cons d ds =>
      have hd := hds d (by simp)
      have hplus : d ≠ '+' := by intro h; subst h; simp [isDigit] at hd
      have hminus : d ≠ '-' := by intro h; subst h; simp [isDigit] at hd
      refine ⟨Int.ofNat (digitsValue (d :: ds)), ?_⟩
      rw [List.nil_append, parseSignedValue_unsigned _ (by simpa using hplus)
        (by simpa using hminus), hn]
      rfl
  · exact ⟨Int.ofNat (digitsValue ds),
      by rw [List.singleton_append, List.cons_append, parseSignedValue_plus, hn]; rfl⟩
  · exact ⟨-Int.ofNat (digitsValue ds),
      by rw [List.singleton_append, List.cons_append, parseSignedValue_minus, hn]; rfl⟩

/-- Round trip: rendering in the data's notation and parsing gives the value back. -/
theorem parseSignedValue_renderSignedValue (v : Int) (rest : List Char)
    (hrest : ∀ c ∈ rest.head?, isDigit c = false) :
    parseSignedValue ((renderSignedValue v).toList ++ rest) = some (v, rest) := by
  match v with
  | .ofNat 0 =>
    exact (parseSignedValue_zero rest hrest).2.2
  | .ofNat (n + 1) =>
    simp only [renderSignedValue, String.toList_append, List.append_assoc]
    rw [show ("+" : String).toList = ['+'] from rfl, List.singleton_append,
      parseSignedValue_plus, parseNatFromChars_toString _ _ hrest]
    rfl
  | .negSucc m =>
    simp only [renderSignedValue, String.toList_append, List.append_assoc]
    rw [show ("-" : String).toList = ['-'] from rfl, List.singleton_append,
      parseSignedValue_minus, parseNatFromChars_toString _ _ hrest]
    rfl

-- ------------------------------------------------------------
-- Guard rule
-- ------------------------------------------------------------

/-- The guard rule, stated: guardable iff the attached suffix contains 'g'. -/
theorem hasGuardSuffix_iff (remaining : List Char) :
    hasGuardSuffix remaining = true ↔ 'g' ∈ attachedSuffix remaining := by
  simp [hasGuardSuffix]

/--
  Text after the first non-suffix character (a space, '(', '/', ',', '~',
  an uppercase letter, a digit, ...) never affects the attached suffix.
-/
theorem attachedSuffix_stop (pre : List Char) (c : Char) (rest₁ rest₂ : List Char)
    (hc : isSuffixChar c = false) :
    attachedSuffix (pre ++ c :: rest₁) = attachedSuffix (pre ++ c :: rest₂) := by
  induction pre with
  | nil => simp [attachedSuffix, hc]
  | cons x pre ih =>
    simp only [attachedSuffix] at *
    by_cases hx : isSuffixChar x = true
    · simp [hx, ih]
    · simp [hx]

/-- Text after a non-suffix character never affects the guard flag. -/
theorem hasGuardSuffix_stop (pre : List Char) (c : Char) (rest₁ rest₂ : List Char)
    (hc : isSuffixChar c = false) :
    hasGuardSuffix (pre ++ c :: rest₁) = hasGuardSuffix (pre ++ c :: rest₂) := by
  simp only [hasGuardSuffix, attachedSuffix_stop pre c rest₁ rest₂ hc]

/-- A run of suffix letters ended by a non-suffix character is the whole suffix. -/
theorem attachedSuffix_append (sfx tail : List Char)
    (hsfx : ∀ c ∈ sfx, isSuffixChar c = true)
    (htail : ∀ c ∈ tail.head?, isSuffixChar c = false) :
    attachedSuffix (sfx ++ tail) = sfx := by
  simp only [attachedSuffix]
  rw [List.takeWhile_append_of_pos hsfx]
  cases tail with
  | nil => simp
  | cons c tail => simp [htail c rfl]

theorem head_takeWhile {p : Char → Bool} {l : List Char} {c : Char}
    (h : c ∈ (l.takeWhile p).head?) : c ∈ l.head? := by
  cases l with
  | nil => simp at h
  | cons x l =>
    by_cases hx : p x = true
    · simp [hx] at h; simp [h]
    · simp [hx] at h

/--
  The guard flag of a block/hit value is exactly whether the suffix attached
  to its leading number contains 'g'. Here the value is an optional sign, a
  digit run and a run of suffix letters, followed by any `tail` that is empty
  or starts with a character that is neither a digit nor a suffix letter:
  nothing in `tail` can change the flag.
-/
theorem parseBlockFrame_guardable (sign ds sfx tail : List Char) (hsign : IsSign sign)
    (hne : ds ≠ []) (hds : ∀ c ∈ ds, isDigit c = true)
    (hsfx : ∀ c ∈ sfx, isSuffixChar c = true)
    (htail : ∀ c ∈ tail.head?, isSuffixChar c = false ∧ isDigit c = false) :
    (parseBlockFrame (String.ofList (sign ++ ds ++ sfx ++ tail))).map (·.guardable) =
      some (sfx.contains 'g') := by
  have hsign_ne : ∀ c ∈ sign, c != '~' := by
    rcases hsign with rfl | rfl | rfl <;> simp
  have hds_ne : ∀ c ∈ ds, c != '~' := fun c hc => by simpa using ne_tilde_of_isDigit (hds c hc)
  have hsfx_ne : ∀ c ∈ sfx, c != '~' := fun c hc => by
    simpa using ne_tilde_of_isSuffixChar (hsfx c hc)
  -- Leading whitespace: the first character is a sign or a digit.
  have hdrop : (sign ++ ds ++ sfx ++ tail).dropWhile Char.isWhitespace =
      sign ++ ds ++ sfx ++ tail := by
    cases ds with
    | nil => exact absurd rfl hne
    | cons d ds =>
      have hd := isWhitespace_of_isDigit (hds d (by simp))
      rcases hsign with rfl | rfl | rfl <;> simp [hd]
  -- The range split keeps sign, digits and suffix; the tail may shrink.
  let tail' := tail.takeWhile (fun c => c != '~')
  have htake : (sign ++ ds ++ sfx ++ tail).takeWhile (fun c => c != '~') =
      sign ++ ds ++ (sfx ++ tail') := by
    simp only [List.append_assoc]
    rw [List.takeWhile_append_of_pos hsign_ne, List.takeWhile_append_of_pos hds_ne,
      List.takeWhile_append_of_pos hsfx_ne]
  have htail' : ∀ c ∈ tail'.head?, isSuffixChar c = false ∧ isDigit c = false :=
    fun c hc => htail c (head_takeWhile hc)
  have hrest : ∀ c ∈ (sfx ++ tail').head?, isDigit c = false := by
    intro c hc
    cases sfx with
    | nil => exact (htail' c (by simpa using hc)).2
    | cons x sfx =>
      simp only [List.cons_append, List.head?_cons, Option.mem_def, Option.some.injEq] at hc
      subst hc
      exact isDigit_of_isSuffixChar (hsfx _ (by simp))
  obtain ⟨v, hv⟩ := parseSignedValue_sign_digits sign ds (sfx ++ tail') hsign hne hds hrest
  have hsuffix : attachedSuffix (sfx ++ tail') = sfx :=
    attachedSuffix_append sfx tail' hsfx (fun c hc => (htail' c hc).1)
  simp only [parseBlockFrame, String.toList_ofList, hdrop, htake, hv, Option.map_some,
    hasGuardSuffix, hsuffix]

-- ------------------------------------------------------------
-- Block round trips
-- ------------------------------------------------------------

/-- A rendered value is an optional sign followed by a non-empty digit run. -/
theorem renderSignedValue_shape (v : Int) :
    ∃ sign ds, (renderSignedValue v).toList = sign ++ ds ∧ IsSign sign ∧ ds ≠ [] ∧
      ∀ c ∈ ds, isDigit c = true := by
  match v with
  | .ofNat 0 => exact ⟨[], ['0'], rfl, Or.inl rfl, by simp, by decide⟩
  | .ofNat (n + 1) =>
    obtain ⟨hne, hall, -⟩ := toString_digits (n + 1)
    refine ⟨['+'], (toString (n + 1)).toList, ?_, Or.inr (Or.inl rfl), hne, hall⟩
    simp only [renderSignedValue, String.toList_append]
    rfl
  | .negSucc m =>
    obtain ⟨hne, hall, -⟩ := toString_digits (m + 1)
    refine ⟨['-'], (toString (m + 1)).toList, ?_, Or.inr (Or.inr rfl), hne, hall⟩
    simp only [renderSignedValue, String.toList_append]
    rfl

/-- A rendered value starts with a sign or digit, never whitespace. -/
theorem renderSignedValue_head (v : Int) :
    ∀ c ∈ (renderSignedValue v).toList.head?, c.isWhitespace = false := by
  obtain ⟨sign, ds, hr, hsign, hne, hds⟩ := renderSignedValue_shape v
  rw [hr]
  cases ds with
  | nil => exact absurd rfl hne
  | cons d ds =>
    have hd := isWhitespace_of_isDigit (hds d (by simp))
    rcases hsign with rfl | rfl | rfl <;> simp [hd] <;> decide

/-- A rendered value never contains the range separator '~'. -/
theorem renderSignedValue_no_tilde (v : Int) :
    ∀ c ∈ (renderSignedValue v).toList, (c != '~') = true := by
  obtain ⟨sign, ds, hr, hsign, -, hds⟩ := renderSignedValue_shape v
  rw [hr]
  intro c hc
  rcases List.mem_append.mp hc with hc | hc
  · rcases hsign with rfl | rfl | rfl <;> simp_all
  · simpa using ne_tilde_of_isDigit (hds c hc)

/--
  Without a '~', and with no leading whitespace, a block value parses as a
  single signed value whose remaining text decides the guard flag.
-/
theorem parseBlockFrame_no_tilde (s : String)
    (hhead : ∀ c ∈ s.toList.head?, c.isWhitespace = false)
    (htilde : ∀ c ∈ s.toList, (c != '~') = true) :
    parseBlockFrame s = (parseSignedValue s.toList).map
      (fun p => { value := p.1, guardable := hasGuardSuffix p.2 }) := by
  have hdrop : s.toList.dropWhile Char.isWhitespace = s.toList := by
    cases h : s.toList with
    | nil => rfl
    | cons c cs => rw [h] at hhead; simp [hhead c rfl]
  have htake : s.toList.takeWhile (fun c => c != '~') = s.toList := by
    simpa using List.takeWhile_append_of_pos (l₂ := []) htilde
  have hdropT : s.toList.dropWhile (fun c => c != '~') = [] := by
    simpa using List.dropWhile_append_of_pos (l₂ := []) htilde
  simp only [parseBlockFrame, hdrop, htake, hdropT]
  cases parseSignedValue s.toList <;> rfl

/--
  Round trip in the data's notation: a rendered value with an optional "g"
  suffix parses back to the same value and guard flag, with no range.
-/
theorem parseBlockFrame_renderSignedValue (v : Int) (g : Bool) :
    parseBlockFrame (renderSignedValue v ++ (if g then "g" else "")) =
      some { value := v, guardable := g } := by
  have hG : (if g then "g" else "").toList = (if g then ['g'] else []) := by cases g <;> rfl
  have hstr : (renderSignedValue v ++ (if g then "g" else "")).toList =
      (renderSignedValue v).toList ++ (if g then ['g'] else []) := by
    rw [String.toList_append, hG]
  have hGd : ∀ c ∈ (if g then ['g'] else []).head?, isDigit c = false := by
    cases g <;> decide
  have hhead : ∀ c ∈ (renderSignedValue v ++ (if g then "g" else "")).toList.head?,
      c.isWhitespace = false := by
    obtain ⟨sign, ds, hr, -, hne, -⟩ := renderSignedValue_shape v
    have hne' : (renderSignedValue v).toList ≠ [] := by rw [hr]; simp [hne]
    intro c hc
    rw [hstr, List.head?_append] at hc
    cases h : (renderSignedValue v).toList with
    | nil => exact absurd h hne'
    | cons x xs =>
      rw [h] at hc
      simp only [List.head?_cons, Option.some_or, Option.mem_def, Option.some.injEq] at hc
      subst hc
      exact renderSignedValue_head v x (by simp [h])
  have htilde : ∀ c ∈ (renderSignedValue v ++ (if g then "g" else "")).toList,
      (c != '~') = true := by
    rw [hstr]
    intro c hc
    rcases List.mem_append.mp hc with hc | hc
    · exact renderSignedValue_no_tilde v c hc
    · cases g <;> simp_all
  rw [parseBlockFrame_no_tilde _ hhead htilde, hstr, parseSignedValue_renderSignedValue v _ hGd]
  cases g <;> rfl

/--
  Range round trip: "A~B" in the data's notation parses to value A with
  range end B.
-/
theorem parseBlockFrame_range_renderSignedValue (a b : Int) :
    parseBlockFrame (renderSignedValue a ++ "~" ++ renderSignedValue b) =
      some { value := a, rangeEnd := some b } := by
  have hstr : (renderSignedValue a ++ "~" ++ renderSignedValue b).toList =
      (renderSignedValue a).toList ++ '~' :: (renderSignedValue b).toList := by
    simp only [String.toList_append, List.append_assoc]
    rfl
  obtain ⟨sign, ds, hr, -, hne, -⟩ := renderSignedValue_shape a
  have hne' : (renderSignedValue a).toList ≠ [] := by rw [hr]; simp [hne]
  have hdrop : ((renderSignedValue a).toList ++ '~' :: (renderSignedValue b).toList).dropWhile
      Char.isWhitespace = (renderSignedValue a).toList ++ '~' :: (renderSignedValue b).toList := by
    cases h : (renderSignedValue a).toList with
    | nil => exact absurd h hne'
    | cons c cs =>
      have hc := renderSignedValue_head a c (by simp [h])
      simp [hc]
  have hnt := renderSignedValue_no_tilde a
  have hnil : ∀ c ∈ ([] : List Char).head?, isDigit c = false := by simp
  have ha := parseSignedValue_renderSignedValue a [] hnil
  have hb := parseSignedValue_renderSignedValue b [] hnil
  rw [List.append_nil] at ha hb
  simp only [parseBlockFrame, hstr, hdrop, List.takeWhile_append_of_pos hnt,
    List.dropWhile_append_of_pos hnt, List.takeWhile_cons, List.dropWhile_cons,
    bne_self_eq_false, Bool.false_eq_true, if_false, List.append_nil, ha, hb, List.drop_succ_cons,
    List.drop_zero]
  rfl

-- ------------------------------------------------------------
-- Startup frames
-- ------------------------------------------------------------

/--
  Multi-hit startup: everything after the first comma or whitespace that
  follows the first hit's text never changes the result.
-/
theorem startupToken_first_hit (first rest : List Char) (sep : Char) (hne : first ≠ [])
    (hfirst : ∀ c ∈ first, (c != ',' && !c.isWhitespace) = true)
    (hsep : (sep != ',' && !sep.isWhitespace) = false) :
    startupToken (first ++ sep :: rest) = startupToken first := by
  cases first with
  | nil => exact absurd rfl hne
  | cons x xs =>
    have hx := hfirst x (by simp)
    have hxw : x.isWhitespace = false := by simp at hx; exact hx.2
    have hxs : ∀ c ∈ xs, (c != ',' && !c.isWhitespace) = true :=
      fun c hc => hfirst c (by simp [hc])
    simp only [startupToken, List.cons_append, List.dropWhile_cons, hxw, Bool.false_eq_true,
      if_false, dropImpactPrefix]
    by_cases hi : (x == 'i' || x == 'I') = true
    · simp only [hi, if_true]
      rw [List.takeWhile_append_of_pos hxs, List.takeWhile_cons, if_neg (by simp [hsep])]
      simpa using (List.takeWhile_append_of_pos (l₂ := []) hxs).symm
    · simp only [hi, Bool.false_eq_true, if_false]
      rw [← List.cons_append, List.takeWhile_append_of_pos hfirst, List.takeWhile_cons,
        if_neg (by simp [hsep])]
      simpa using (List.takeWhile_append_of_pos (l₂ := []) hfirst).symm

/-- Multi-hit startup, for strings: later hits never change the written range. -/
theorem parseStartupRange_first_hit (first rest : List Char) (sep : Char) (hne : first ≠ [])
    (hfirst : ∀ c ∈ first, (c != ',' && !c.isWhitespace) = true)
    (hsep : (sep != ',' && !sep.isWhitespace) = false) :
    parseStartupRange (String.ofList (first ++ sep :: rest)) =
      parseStartupRange (String.ofList first) := by
  simp only [parseStartupRange, String.toList_ofList,
    startupToken_first_hit first rest sep hne hfirst hsep]

/-- Multi-hit startup: later hits never change the parsed startup. -/
theorem parseStartupFrame_first_hit (first rest : List Char) (sep : Char) (hne : first ≠ [])
    (hfirst : ∀ c ∈ first, (c != ',' && !c.isWhitespace) = true)
    (hsep : (sep != ',' && !sep.isWhitespace) = false) :
    parseStartupFrame (String.ofList (first ++ sep :: rest)) =
      parseStartupFrame (String.ofList first) := by
  simp only [parseStartupFrame, parseStartupRange_first_hit first rest sep hne hfirst hsep]

/-- An optional impact-frame prefix: none, 'i' or 'I'. -/
def IsImpactPrefix (p : List Char) : Prop :=
  p = [] ∨ p = ['i'] ∨ p = ['I']

/-- Digits are not the impact-frame prefix. -/
theorem not_impact_of_isDigit {c : Char} (h : isDigit c = true) :
    (c == 'i' || c == 'I') = false := by
  have hi : c ≠ 'i' := by intro hc; subst hc; simp [isDigit] at h
  have hI : c ≠ 'I' := by intro hc; subst hc; simp [isDigit] at h
  simp [hi, hI]

/-- Digits are not range separators. -/
theorem not_rangeSep_of_isDigit {c : Char} (h : isDigit c = true) : isRangeSep c = false := by
  have ht : c ≠ '~' := ne_tilde_of_isDigit h
  have hm : c ≠ '-' := by intro hc; subst hc; simp [isDigit] at h
  simp [isRangeSep, ht, hm]

/-- An optional prefix in front of a digit run is dropped; the digits stay. -/
theorem dropImpactPrefix_append (p ds rest : List Char) (hp : IsImpactPrefix p)
    (hne : ds ≠ []) (hds : ∀ c ∈ ds, isDigit c = true) :
    dropImpactPrefix (p ++ (ds ++ rest)) = ds ++ rest := by
  rcases hp with rfl | rfl | rfl
  · cases ds with
    | nil => exact absurd rfl hne
    | cons d ds => simp [dropImpactPrefix, not_impact_of_isDigit (hds d (by simp))]
  · simp [dropImpactPrefix]
  · simp [dropImpactPrefix]

/-- `parseStartupFrame` only looks at the characters of its input. -/
theorem parseStartupFrame_congr {s t : String} (h : s.toList = t.toList) :
    parseStartupFrame s = parseStartupFrame t := by
  simp only [parseStartupFrame, parseStartupRange, h]

/--
  Every spelling of a startup range in the data reads the same: an optional
  'i'/'I' before the start, '~' or '-' between, and an optional 'i'/'I'
  before the end. "i13~14", "i13-14", "i13~i14", "i13-i14" and "13-14" all
  give start 13 and written end 14.
-/
theorem parseStartupRange_range (a b : Nat) (p₁ p₂ : List Char) (sep : Char)
    (hp₁ : IsImpactPrefix p₁) (hp₂ : IsImpactPrefix p₂) (hsep : isRangeSep sep = true) :
    parseStartupRange
        (String.ofList (p₁ ++ ((toString a).toList ++ sep :: (p₂ ++ (toString b).toList)))) =
      some (a, some b) := by
  obtain ⟨hnea, hda, -⟩ := toString_digits a
  obtain ⟨hneb, hdb, -⟩ := toString_digits b
  -- The input starts with a prefix letter or a digit, never whitespace.
  have hdrop : (p₁ ++ ((toString a).toList ++ sep :: (p₂ ++ (toString b).toList))).dropWhile
      Char.isWhitespace = p₁ ++ ((toString a).toList ++ sep :: (p₂ ++ (toString b).toList)) := by
    cases h : (toString a).toList with
    | nil => exact absurd h hnea
    | cons d ds =>
      have hd := isWhitespace_of_isDigit (hda d (by simp [h]))
      rcases hp₁ with rfl | rfl | rfl <;> simp [hd] <;> decide
  have hsepc : sep = '~' ∨ sep = '-' := by simpa [isRangeSep] using hsep
  have hp₂c : ∀ c ∈ p₂, c = 'i' ∨ c = 'I' := by
    rcases hp₂ with rfl | rfl | rfl <;> simp
  -- Every character is a digit, the separator or a prefix letter.
  have htok : ∀ c ∈ (toString a).toList ++ sep :: (p₂ ++ (toString b).toList),
      (c != ',' && !c.isWhitespace) = true := by
    intro c hc
    simp only [List.mem_append, List.mem_cons] at hc
    rcases hc with hc | hc | hc | hc
    · exact startupChar_of_isDigit (hda c hc)
    · subst hc; rcases hsepc with rfl | rfl <;> decide
    · rcases hp₂c c hc with rfl | rfl <;> decide
    · exact startupChar_of_isDigit (hdb c hc)
  have htw : ((toString a).toList ++ sep :: (p₂ ++ (toString b).toList)).takeWhile
      (fun c => c != ',' && !c.isWhitespace) =
      (toString a).toList ++ sep :: (p₂ ++ (toString b).toList) := by
    simpa using List.takeWhile_append_of_pos (l₂ := []) htok
  have hns : ∀ c ∈ (toString a).toList, (!isRangeSep c) = true :=
    fun c hc => by simp [not_rangeSep_of_isDigit (hda c hc)]
  have hnil : ∀ c ∈ ([] : List Char).head?, isDigit c = false := by simp
  have ha := parseNatFromChars_toString a [] hnil
  have hb := parseNatFromChars_toString b [] hnil
  rw [List.append_nil] at ha hb
  have hend : dropImpactPrefix (p₂ ++ (toString b).toList) = (toString b).toList := by
    simpa using dropImpactPrefix_append p₂ (toString b).toList [] hp₂ hneb hdb
  simp only [parseStartupRange, startupToken, String.toList_ofList, hdrop,
    dropImpactPrefix_append p₁ _ _ hp₁ hnea hda, htw, List.takeWhile_append_of_pos hns,
    List.dropWhile_append_of_pos hns, List.takeWhile_cons, List.dropWhile_cons, hsep,
    Bool.not_true, Bool.false_eq_true, if_false, List.append_nil, List.drop_succ_cons,
    List.drop_zero, hend, ha, hb]

/--
  Every spelling of an ordered startup range (start ≤ end) parses to that
  start and end; an end before the start is dropped (`orderedEnd`).
-/
theorem parseStartupFrame_range (a b : Nat) (p₁ p₂ : List Char) (sep : Char)
    (hp₁ : IsImpactPrefix p₁) (hp₂ : IsImpactPrefix p₂) (hsep : isRangeSep sep = true) :
    parseStartupFrame
        (String.ofList (p₁ ++ ((toString a).toList ++ sep :: (p₂ ++ (toString b).toList)))) =
      some { startup := a, activeEnd := if a ≤ b then some b else none } := by
  simp only [parseStartupFrame, parseStartupRange_range a b p₁ p₂ sep hp₁ hp₂ hsep,
    Option.map_some, orderedEnd]

/--
  Startup round trip for the clean CSV export, which stores `toString` of
  the start and end frames and rebuilds "i{start}~{end}" when loading.
-/
theorem parseStartupFrame_range_toString (a b : Nat) (hab : a ≤ b) :
    parseStartupFrame ("i" ++ toString a ++ "~" ++ toString b) =
      some { startup := a, activeEnd := some b } := by
  rw [parseStartupFrame_congr (t := String.ofList
    (['i'] ++ ((toString a).toList ++ '~' :: ([] ++ (toString b).toList))))]
  · rw [parseStartupFrame_range a b ['i'] [] '~' (Or.inr (Or.inl rfl)) (Or.inl rfl) rfl,
      if_pos hab]
  · simp only [String.toList_append, String.toList_ofList, List.nil_append, List.append_assoc]
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

/-- Active frame count for a well-formed range: end − start + 1. -/
theorem activeFrames_of_le (d : StartupData) (e : Nat) (he : d.activeEnd = some e)
    (hle : d.startup ≤ e) : d.activeFrames = some (e - d.startup + 1) := by
  simp [StartupData.activeFrames, he, hle]

/--
  Current behaviour for a range ending before it starts (real data:
  "i25~16", "i16~15 i14~15"): the count falls back to 1.
-/
theorem activeFrames_of_lt (d : StartupData) (e : Nat) (he : d.activeEnd = some e)
    (hlt : e < d.startup) : d.activeFrames = some 1 := by
  simp [StartupData.activeFrames, he, Nat.not_le.mpr hlt]

-- ------------------------------------------------------------
-- Abnormal source data
-- ------------------------------------------------------------

theorem orderedEnd_le {n e : Nat} {x : Option Nat} (h : orderedEnd n x = some e) : n ≤ e := by
  cases x with
  | none => simp [orderedEnd] at h
  | some x =>
    simp only [orderedEnd] at h
    split at h
    · injection h with h; omega
    · contradiction

/-- `parseStartupFrame` is the written range with an unexplainable end dropped. -/
theorem parseStartupFrame_of_range {s : String} {n : Nat} {x : Option Nat}
    (h : parseStartupRange s = some (n, x)) :
    parseStartupFrame s = some { startup := n, activeEnd := orderedEnd n x } := by
  simp [parseStartupFrame, h]

/-- A parsed startup never ends before it starts. -/
theorem parseStartupFrame_activeEnd_ge {s : String} {d : StartupData} {e : Nat}
    (h : parseStartupFrame s = some d) (he : d.activeEnd = some e) : d.startup ≤ e := by
  simp only [parseStartupFrame, Option.map_eq_some_iff] at h
  obtain ⟨r, -, rfl⟩ := h
  exact orderedEnd_le he

/-- So the active frame count of parsed data is always end − start + 1. -/
theorem parseStartupFrame_activeFrames {s : String} {d : StartupData} {e : Nat}
    (h : parseStartupFrame s = some d) (he : d.activeEnd = some e) :
    d.activeFrames = some (e - d.startup + 1) :=
  activeFrames_of_le d e he (parseStartupFrame_activeEnd_ge h he)

/-- An inverted range is flagged exactly when its written end precedes its start. -/
theorem startupIssues_inverted_iff {s : String} {n e : Nat}
    (h : parseStartupRange s = some (n, some e)) :
    FrameIssue.rangeEndBeforeStart n e ∈ startupIssues s ↔ e < n := by
  simp only [startupIssues, h]
  by_cases hen : e < n
  · simp [hen]
  · simp [hen]

/-- A written end is dropped from the parse exactly when it is flagged. -/
theorem parseStartupFrame_end_dropped_iff {s : String} {n e : Nat}
    (h : parseStartupRange s = some (n, some e)) :
    parseStartupFrame s = some { startup := n } ↔
      FrameIssue.rangeEndBeforeStart n e ∈ startupIssues s := by
  rw [startupIssues_inverted_iff h, parseStartupFrame_of_range h]
  simp only [orderedEnd, Option.some.injEq, StartupData.mk.injEq, true_and]
  by_cases hne : n ≤ e
  · simp [hne] <;> omega
  · simp [hne] <;> omega

/-- Two marked characters stand next to each other somewhere in the list. -/
theorem hasAdjacent_iff (marks : Char → Bool) (cs : List Char) :
    hasAdjacent marks cs = true ↔
      ∃ pre a b post, cs = pre ++ a :: b :: post ∧ marks a = true ∧ marks b = true := by
  induction cs with
  | nil => simp [hasAdjacent]
  | cons x rest ih =>
    simp only [hasAdjacent, Bool.or_eq_true, Bool.and_eq_true, ih]
    constructor
    · rintro (⟨hx, hy⟩ | ⟨pre, a, b, post, rfl, ha, hb⟩)
      · cases rest with
        | nil => simp at hy
        | cons y rest => exact ⟨[], x, y, rest, rfl, hx, by simpa using hy⟩
      · exact ⟨x :: pre, a, b, post, rfl, ha, hb⟩
    · rintro ⟨pre, a, b, post, hcs, ha, hb⟩
      cases pre with
      | nil =>
        simp only [List.nil_append, List.cons.injEq] at hcs
        obtain ⟨rfl, rfl⟩ := hcs
        exact Or.inl ⟨ha, by simpa using hb⟩
      | cons p pre =>
        simp only [List.cons_append, List.cons.injEq] at hcs
        obtain ⟨-, rfl⟩ := hcs
        exact Or.inr ⟨pre, a, b, post, rfl, ha, hb⟩

/--
  A block, hit or counter-hit value is unflagged exactly when it has no
  doubled sign and either parses or is known notation.
-/
theorem frameIssues_eq_nil_iff (s : String) :
    frameIssues s = [] ↔
      hasAdjacent isSignChar s.toList = false ∧
        ((parseBlockFrame s).isSome = true ∨ knownFrameNotation s = true) := by
  unfold frameIssues
  cases hadj : hasAdjacent isSignChar s.toList <;>
    cases hp : parseBlockFrame s <;> cases hk : knownFrameNotation s <;> simp

/-- A startup value is flagged for a doubled sign iff two marks are adjacent. -/
theorem doubledSign_mem_startupIssues_iff (s : String) :
    FrameIssue.doubledSign ∈ startupIssues s ↔ hasAdjacent isStartupMark s.toList = true := by
  unfold startupIssues
  cases hadj : hasAdjacent isStartupMark s.toList <;>
    cases hr : parseStartupRange s <;> simp_all <;> split <;> simp_all <;> split <;> simp_all

/--
  A startup value is flagged unrecognized iff it does not parse, is not
  known notation and has no doubled sign.
-/
theorem unrecognized_mem_startupIssues_iff (s : String) :
    FrameIssue.unrecognized ∈ startupIssues s ↔
      parseStartupRange s = none ∧ knownStartupNotation s = false ∧
        hasAdjacent isStartupMark s.toList = false := by
  unfold startupIssues
  cases hadj : hasAdjacent isStartupMark s.toList <;>
    cases hk : knownStartupNotation s <;>
    cases hr : parseStartupRange s <;> simp_all <;> split <;> simp_all <;> split <;> simp_all

-- ------------------------------------------------------------
-- Regression examples (real data values)
-- ------------------------------------------------------------

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

/--
  "+0" and "-0" both parse to 0 (real data has both).
-/
theorem parseBlockFrame_plus_zero :
    parseBlockFrame "+0" = some { value := 0 } := by
  rfl

/--
  The guard flag belongs to the leading value only; a range end's own "g"
  is not stored ("+6~+11g", "-12~+26g" on block).
-/
theorem parseBlockFrame_range_end_guard :
    parseBlockFrame "+6~+11g" = some { value := 6, rangeEnd := some 11 } := by
  rfl

theorem parseBlockFrame_negative_range_end_guard :
    parseBlockFrame "-12~+26g" = some { value := -12, rangeEnd := some 26 } := by
  rfl

theorem parseBlockFrame_guard_before_code :
    parseBlockFrame "+14gc" = some { value := 14, guardable := true } := by
  rfl

/--
  A range that ends before it starts (Miary Zo uf+3+4 "i25~16", Jun IZU.3
  "i16~15 i14~15") keeps its start; the end is unknown and flagged.
-/
theorem parseStartupFrame_end_before_start :
    parseStartupFrame "i25~16" = some { startup := 25 } := by
  rfl

theorem startupIssues_end_before_start :
    startupIssues "i25~16" = [.rangeEndBeforeStart 25 16] := by
  rfl

theorem startupIssues_end_before_start_multi_hit :
    startupIssues "i16~15 i14~15" = [.rangeEndBeforeStart 16 15] := by
  rfl

/-- Raven H.b+2,4,2: a minus sign after the separator of a later hit. -/
theorem startupIssues_doubled_separator :
    startupIssues "i15~17, ,i19~20, i39~-41" = [.doubledSign] := by
  rfl

/-- Asuka db+4,1+4 on block: a doubled minus. -/
theorem frameIssues_doubled_minus :
    frameIssues "--3" = [.doubledSign] := by
  rfl

/-- Lee 4,u+3 counter hit "js": neither a frame value nor known notation. -/
theorem frameIssues_unrecognized_js :
    frameIssues "js" = [.unrecognized] := by
  rfl

/-- Known non-numeric notation is not flagged. -/
theorem frameIssues_known_notation :
    frameIssues "!" = [] ∧ frameIssues "N/A" = [] ∧ frameIssues "KND" = [] ∧
    frameIssues "LNC" = [] ∧ frameIssues "th" = [] := by
  decide

theorem startupIssues_known_notation :
    startupIssues "(depends)" = [] ∧ startupIssues "js12" = [] ∧
    startupIssues ",i14~15" = [] ∧ startupIssues "N/A / i26~i31 Heat" = [] := by
  decide

/-- Ordinary values, including hand-typed ranges, are not flagged. -/
theorem issues_ordinary_values :
    frameIssues "+12 JGR" = [] ∧ frameIssues "-12~+26g" = [] ∧
    startupIssues "i13-14" = [] ∧ startupIssues "i15-i16" = [] := by
  decide

/--
  A leading comma means the first hit has no startup listed (",i14~15").
-/
theorem parseStartupFrame_leading_comma :
    parseStartupFrame ",i14~15" = none := by
  rfl

/--
  Hand-typed range spellings from real data: '-' instead of '~' (Lee df+4
  "i13-14", Clive qcf+1 "i20-31") and a repeated impact prefix on the end
  (Asuka f+3 "i31~i33", Lars/Reina uf+2 "i15-i16").
-/
theorem parseStartupFrame_dash_range :
    parseStartupFrame "i13-14" = some { startup := 13, activeEnd := some 14 } := by
  rfl

theorem parseStartupFrame_dash_range_long :
    parseStartupFrame "i20-31" = some { startup := 20, activeEnd := some 31 } := by
  rfl

theorem parseStartupFrame_tilde_impact_end :
    parseStartupFrame "i31~i33" = some { startup := 31, activeEnd := some 33 } := by
  rfl

theorem parseStartupFrame_dash_impact_end :
    parseStartupFrame "i15-i16" = some { startup := 15, activeEnd := some 16 } := by
  rfl

theorem parseStartupFrame_dash_range_multi_hit :
    parseStartupFrame "i13-14, i22-23" = some { startup := 13, activeEnd := some 14 } := by
  rfl

end TekkenQuery.Frame
