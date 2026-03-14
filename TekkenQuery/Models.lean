/-
  TekkenQuery.Models
  Data models for Tekken frame data.
  Pure structures with no IO, no side effects.
-/
import TekkenQuery.Frame

namespace TekkenQuery

/--
  Hit level classification for a move.
-/
inductive HitLevel where
  | high
  | mid
  | low
  | special (raw : String)  -- for compound levels like "h, m" or "m, m"
  deriving Repr, BEq, DecidableEq, Inhabited

/--
  Parse a hit level string into a HitLevel.
  Handles the common cases and falls back to .special for compound levels.
-/
def HitLevel.parse (s : String) : Option HitLevel :=
  let trimmed := s.toLower.trimAscii.toString
  if trimmed.isEmpty then none
  else if trimmed == "h" then some .high
  else if trimmed == "m" then some .mid
  else if trimmed == "l" then some .low
  else some (.special s)

/--
  Optional frame range for status properties.
  e.g., power crush active on frames 7–16.
-/
structure FrameRange where
  startFrame : Nat
  endFrame   : Option Nat := none
  deriving Repr, BEq, DecidableEq, Inhabited

/--
  Every known move property as a proper type.
  Adding a new property = one constructor + one line in parseRawTag.
-/
inductive MoveProperty where
  -- Heat system
  | heatEngager
  | heatSmash
  | heatBurst
  -- Combo properties
  | tornado
  | spike
  -- Defensive properties
  | powerCrush   (range : Option FrameRange := none)
  | jumpStatus   (range : Option FrameRange := none)  -- crushes lows
  | crouchStatus (range : Option FrameRange := none)  -- crushes highs
  | fullCrouchStatus (range : Option FrameRange := none)
  | parryStatus  (range : Option FrameRange := none)
  | invincible   (range : Option FrameRange := none)
  -- Tracking
  | homing
  -- Stage interaction
  | balconyBreak
  | wallBreak
  | floorBreak
  -- Parry immunity (unparryable attack types)
  | elbow
  | knee
  | headbutt
  | weapon
  -- Other
  | reversalBreak
  | chipDamage
  deriving Repr, BEq, Inhabited

/--
  Move properties: parsed tags + lowercased notes.
-/
structure MoveProperties where
  properties : List MoveProperty := []
  notes      : List String       := []
  deriving Repr, BEq, Inhabited

/--
  A single Tekken move with all its frame data.
  All fields are pure data — no side effects, no IO.
  Optional fields use Option to make absence explicit.
-/
structure TekkenMove where
  command           : String
  name              : Option String := none
  hitLevel          : Option String := none
  damage            : Option String := none
  startupFrame      : Option String := none
  blockFrame        : Option String := none
  hitFrame          : Option String := none
  counterHitFrame   : Option String := none
  recovery          : Option String := none
  notes             : Option String := none
  tags              : Option String := none
  transitions       : Option String := none
  image             : Option String := none
  video             : Option String := none
  stance            : Option String := none
  commandWithoutStance : Option String := none
  properties        : MoveProperties := {}
  deriving Repr, BEq, Inhabited

/--
  Get the parsed startup frame data (preserves active frame range).
-/
def TekkenMove.startupFrameValue (m : TekkenMove) : Option Frame.StartupData :=
  match m.startupFrame with
  | none => none
  | some s => Frame.parseStartupFrame s

/--
  Get the parsed block frame data (preserves guard suffix and range).
-/
def TekkenMove.blockFrameValue (m : TekkenMove) : Option Frame.BlockFrameData :=
  match m.blockFrame with
  | none => none
  | some s => Frame.parseBlockFrame s

/--
  A Tekken character with their move list.
-/
structure TekkenCharacter where
  id    : String
  name  : String
  moves : List TekkenMove
  deriving Repr, BEq, Inhabited

/-- Set of known non-stance prefixes (H for Heat, R for Rage). -/
def nonStancePrefixes : List String := ["H", "R"]

/--
  Parse stance from a command string.
  "ZEN.1+2" → (some "ZEN", "1+2")
  "H.1+2"   → (none, "H.1+2")  -- H is a non-stance prefix
  "df+2"    → (none, "df+2")
-/
def parseStance (command : String) : Option String × String :=
  match command.splitOn "." with
  | [prefix_, rest] =>
    if prefix_.isEmpty then (none, command)
    else if nonStancePrefixes.any (· == prefix_) then (none, command)
    else (some prefix_, rest)
  | _ => (none, command)

/--
  Check if haystack contains needle as a substring.
  Uses splitOn: if splitting produces more than 1 part, the needle was found.
-/
def containsSubstr (haystack : String) (needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

/--
  Check if a string contains a substring (case-insensitive).
-/
def containsCI (haystack : String) (needle : String) : Bool :=
  containsSubstr haystack.toLower needle.toLower

/--
  Parse a frame range suffix like "7~16", "7~", "7" from a character list.
  Returns none if no digits present.
-/
def parseFrameRange (chars : List Char) : Option FrameRange :=
  if chars.isEmpty then none
  else
    let rangeStr := String.ofList chars
    let normalized := String.ofList (rangeStr.toList.map (fun c => if c == '-' then '~' else c))
    match normalized.splitOn "~" with
    | [startStr, endStr] =>
      let cleanStart := String.ofList (startStr.toList.filter (· != '?'))
      match cleanStart.toNat? with
      | some s =>
        let endVal := if endStr.isEmpty then none else
          (String.ofList (endStr.toList.filter (· != '?'))).toNat?
        some { startFrame := s, endFrame := endVal }
      | none => none
    | [startStr] =>
      let cleaned := String.ofList (startStr.toList.filter (· != '?'))
      match cleaned.toNat? with
      | some s => some { startFrame := s }
      | none => none
    | _ => none

/--
  Map a raw tag code + optional frame range to a typed MoveProperty.
  Adding a new tag = one line here.
-/
def parseRawTag (code : String) (range : Option FrameRange) : Option MoveProperty :=
  match code with
  | "he"  => some .heatEngager
  | "hs"  => some .heatSmash
  | "hb"  => some .heatBurst
  | "trn" => some .tornado
  | "spk" => some .spike
  | "pc"  => some (.powerCrush range)
  | "js"  => some (.jumpStatus range)
  | "cs"  => some (.crouchStatus range)
  | "fs"  => some (.fullCrouchStatus range)
  | "ps"  => some (.parryStatus range)
  | "is"  => some (.invincible range)
  | "hom" => some .homing
  | "bbr" => some .balconyBreak
  | "wbr" => some .wallBreak
  | "fbr" => some .floorBreak
  | "elb" => some .elbow
  | "kne" => some .knee
  | "hed" => some .headbutt
  | "wpn" => some .weapon
  | "rbr" => some .reversalBreak
  | "chp" => some .chipDamage
  | _     => none

/--
  Parse a single raw tag string like "pc7~16" into a MoveProperty.
-/
def parseTagStr (s : String) : Option MoveProperty :=
  let lower := s.toLower
  let chars := lower.toList
  let codeChars := chars.takeWhile (fun c => !c.isDigit)
  let rest := chars.dropWhile (fun c => !c.isDigit)
  let code := String.ofList codeChars
  let range := parseFrameRange rest
  parseRawTag code range

/--
  Parse the tags column into a list of MoveProperties.
  Tags are space-separated: "hb pc7~16" → [.heatBurst, .powerCrush (some ⟨7, some 16⟩)]
  Unknown tags are silently dropped.
-/
def parseTags (tags : Option String) : List MoveProperty :=
  match tags with
  | none => []
  | some s =>
    let parts := s.splitOn " "
    parts.filter (fun p => !p.isEmpty) |>.filterMap parseTagStr

/--
  Parse move properties from tags and notes strings.
-/
def parseProperties (tags : Option String) (notes : Option String) : MoveProperties :=
  { properties := parseTags tags
    notes := match notes with | none => [] | some s => [s.toLower] }

/--
  Look up a field value in a clean CSV record by key name.
  Values are already cleaned (nan/empty → none) by the parser.
-/
def lookupField (rec : List (String × Option String)) (key : String) : Option String :=
  match rec.find? (fun p => p.1 == key) with
  | none => none
  | some (_, v) => v

/--
  Build a TekkenMove from a clean CSV record.
  This is the pure equivalent of Python's TekkenMove.from_csv_dict.
  Values are already cleaned by the CSV parser — no separate nan handling needed.
-/
def TekkenMove.fromRecord (rec : List (String × Option String)) : TekkenMove :=
  let command := (lookupField rec "Command").getD ""
  let (stance, cmdWithoutStance) := parseStance command
  let tags := lookupField rec "Tags"
  let notes := lookupField rec "Notes"
  {
    command           := command
    name              := lookupField rec "Name" |>.orElse (fun _ => lookupField rec "Move Name")
    hitLevel          := lookupField rec "Hit level"
    damage            := lookupField rec "Damage"
    startupFrame      := lookupField rec "Start up frame"
    blockFrame        := lookupField rec "Block frame"
    hitFrame          := lookupField rec "Hit frame"
    counterHitFrame   := lookupField rec "Counter hit frame"
    recovery          := lookupField rec "Recovery"
    notes             := notes
    tags              := tags
    transitions       := lookupField rec "Transitions"
    image             := lookupField rec "Image"
    video             := lookupField rec "Video"
    stance            := stance
    commandWithoutStance := some cmdWithoutStance
    properties        := parseProperties tags notes
  }

/--
  Build a TekkenMove from a clean (exported) CSV record.
  Clean CSVs use snake_case headers and pre-parsed frame values.
  Reconstructs the raw frame strings so startupFrameValue/blockFrameValue work.
-/
def TekkenMove.fromCleanRecord (rec : List (String × Option String)) : TekkenMove :=
  let command := (lookupField rec "command").getD ""
  let (stance, cmdWithoutStance) := parseStance command
  let tags := lookupField rec "tags"
  let notes := lookupField rec "notes"
  -- Reconstruct startup frame string: "i13" or "i12~13"
  let startupFrame := match lookupField rec "startup" with
    | some s =>
      match lookupField rec "startup_end" with
      | some e => some s!"i{s}~{e}"
      | none => some s!"i{s}"
    | none => none
  -- Reconstruct block frame string: "-10" or "+5g"
  let blockFrame := match lookupField rec "block_frame" with
    | some bf =>
      let guard := match lookupField rec "block_guardable" with
        | some "true" => "g"
        | _ => ""
      some (bf ++ guard)
    | none => none
  {
    command           := command
    name              := lookupField rec "name"
    hitLevel          := lookupField rec "hit_level"
    damage            := lookupField rec "damage"
    startupFrame      := startupFrame
    blockFrame        := blockFrame
    hitFrame          := lookupField rec "hit_frame"
    counterHitFrame   := lookupField rec "counter_hit_frame"
    notes             := notes
    tags              := tags
    stance            := stance
    commandWithoutStance := some cmdWithoutStance
    properties        := parseProperties tags notes
  }

/--
  Find a move by exact command match (case-insensitive).
  This is the one lookup function that isn't a filter — it returns a single result.
-/
def TekkenCharacter.findMoveByCommand (char : TekkenCharacter) (cmd : String) : Option TekkenMove :=
  char.moves.find? (fun m => m.command.toLower == cmd.toLower)

/--
  Get all unique stances for a character.
-/
def TekkenCharacter.getStances (char : TekkenCharacter) : List String :=
  let stances := char.moves.filterMap (fun m => m.stance)
  stances.eraseDups

end TekkenQuery
