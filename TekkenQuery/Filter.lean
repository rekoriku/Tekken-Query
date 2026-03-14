/-
  TekkenQuery.Filter
  Composable, universal move filter system.

  Adding a new filter = adding one constructor to `Filter`.
  No new functions needed. Everything composes automatically.
-/
import TekkenQuery.Frame
import TekkenQuery.Models

namespace TekkenQuery

/--
  Check if a MoveProperty matches a given kind, ignoring frame range data.
  e.g., matchesKind (.powerCrush (some ⟨7, some 16⟩)) (.powerCrush none) = true
-/
def MoveProperty.matchesKind (actual : MoveProperty) (pattern : MoveProperty) : Bool :=
  match actual, pattern with
  | .heatEngager,       .heatEngager       => true
  | .heatSmash,         .heatSmash         => true
  | .heatBurst,         .heatBurst         => true
  | .tornado,           .tornado           => true
  | .spike,             .spike             => true
  | .powerCrush _,      .powerCrush _      => true
  | .jumpStatus _,      .jumpStatus _      => true
  | .crouchStatus _,    .crouchStatus _    => true
  | .fullCrouchStatus _, .fullCrouchStatus _ => true
  | .parryStatus _,     .parryStatus _     => true
  | .invincible _,      .invincible _      => true
  | .homing,            .homing            => true
  | .balconyBreak,      .balconyBreak      => true
  | .wallBreak,         .wallBreak         => true
  | .floorBreak,        .floorBreak        => true
  | .elbow,             .elbow             => true
  | .knee,              .knee              => true
  | .headbutt,          .headbutt          => true
  | .weapon,            .weapon            => true
  | .reversalBreak,     .reversalBreak     => true
  | .chipDamage,        .chipDamage        => true
  | _,                  _                  => false

/--
  Check if a move has a specific property (ignoring frame ranges).
-/
def hasProperty (props : MoveProperties) (p : MoveProperty) : Bool :=
  props.properties.any (fun actual => actual.matchesKind p)

/--
  Check if a move has any of the given properties.
-/
def hasAnyProperty (props : MoveProperties) (ps : List MoveProperty) : Bool :=
  ps.any (fun p => hasProperty props p)

/--
  Check if notes contain a keyword (already lowered).
-/
def hasNote (props : MoveProperties) (keyword : String) : Bool :=
  props.notes.any (fun n => containsSubstr n keyword)

/--
  A filter criterion for querying moves.
  Each constructor represents one way to filter.
  To add a new filter type, just add a constructor here —
  then add its evaluation logic in `Filter.eval`.
-/
inductive Filter where
  -- Hit level filters
  | hitLevel (level : String)           -- "h", "m", "l" (prefix match on hit level string)
  | isThrow                             -- hit level contains "t"
  | isUnblockable                       -- hit level contains "!"
  -- Block frame filters
  | plusOnBlock                          -- block frame > 0
  | negative                            -- block frame -1 to -9 (negative but not punishable)
  | punishable                          -- block frame ≤ -10
  | blockFrameBetween (lo hi : Int)     -- lo ≤ block frame ≤ hi
  -- Startup frame filters
  | startupEq (frames : Nat)            -- startup == N
  | startupLt (frames : Nat)            -- startup < N (faster than)
  | startupGt (frames : Nat)            -- startup > N (slower than)
  | startupLe (frames : Nat)            -- startup ≤ N
  | startupGe (frames : Nat)            -- startup ≥ N
  -- Stance filters
  | stance (name : String)              -- moves from a specific stance
  | hasStance                           -- any stance move
  -- Property filters
  | property (p : MoveProperty)             -- move has this property
  | anyProperty (ps : List MoveProperty)    -- move has any of these
  | noteContains (keyword : String)         -- notes contain keyword
  -- Text search
  | nameContains (query : String)       -- name substring match
  | commandContains (query : String)    -- command substring match
  | hitLevelContains (query : String)   -- hit level substring match (for compound levels)
  -- Combinators
  | not (f : Filter)                    -- negate a filter
  | and (f g : Filter)                  -- both must match
  | or (f g : Filter)                   -- either must match
  deriving Repr, Inhabited

/--
  Evaluate a filter against a single move.
  Returns true if the move matches the filter.
  This is the ONE function that does all filtering.
-/
def Filter.eval (f : Filter) (m : TekkenMove) : Bool :=
  match f with
  | .hitLevel level =>
    match m.hitLevel with
    | some hl => hl.toLower.startsWith level.toLower
    | none => false
  | .isThrow =>
    match m.hitLevel with
    | some hl => containsSubstr hl.toLower "t"
    | none => false
  | .isUnblockable =>
    match m.hitLevel with
    | some hl => containsSubstr hl "!"
    | none => false
  | .plusOnBlock =>
    match m.blockFrameValue with
    | some v => v > 0
    | none => false
  | .negative =>
    match m.blockFrameValue with
    | some v => v < 0 && v > -10
    | none => false
  | .punishable =>
    match m.blockFrameValue with
    | some v => v ≤ -10
    | none => false
  | .blockFrameBetween lo hi =>
    match m.blockFrameValue with
    | some v => v ≥ lo && v ≤ hi
    | none => false
  | .startupEq n =>
    match m.startupFrameValue with
    | some v => v == n
    | none => false
  | .startupLt n =>
    match m.startupFrameValue with
    | some v => v < n
    | none => false
  | .startupGt n =>
    match m.startupFrameValue with
    | some v => v > n
    | none => false
  | .startupLe n =>
    match m.startupFrameValue with
    | some v => v ≤ n
    | none => false
  | .startupGe n =>
    match m.startupFrameValue with
    | some v => v ≥ n
    | none => false
  | .stance name =>
    match m.stance with
    | some s => s.toLower == name.toLower
    | none => false
  | .hasStance => m.stance.isSome
  | .property p => hasProperty m.properties p
  | .anyProperty ps => hasAnyProperty m.properties ps
  | .noteContains kw => hasNote m.properties kw
  | .nameContains q =>
    match m.name with
    | some name => containsCI name q
    | none => false
  | .commandContains q =>
    containsCI m.command q
  | .hitLevelContains q =>
    match m.hitLevel with
    | some hl => containsCI hl q
    | none => false
  | .not inner => !inner.eval m
  | .and f g => f.eval m && g.eval m
  | .or f g => f.eval m || g.eval m

/--
  Apply a filter to a character's move list.
  This is the universal query function.
-/
def query (char : TekkenCharacter) (f : Filter) : List TekkenMove :=
  char.moves.filter (Filter.eval f)

/--
  Apply a list of filters (AND'd together) to a character.
  This handles chained filters like "mid+plus+homing".
-/
def queryAll (char : TekkenCharacter) (filters : List Filter) : List TekkenMove :=
  match filters with
  | [] => char.moves
  | [f] => query char f
  | f :: rest => query char (rest.foldl .and f)

/--
  Compare a filter across two characters.
  Returns (char1 matches, char2 matches).
-/
def compare (char1 char2 : TekkenCharacter) (f : Filter) : List TekkenMove × List TekkenMove :=
  (query char1 f, query char2 f)

-- ============================================================
-- Proofs about the filter system
-- ============================================================

/--
  query always returns a subset of the character's moves.
-/
theorem query_subset (char : TekkenCharacter) (f : Filter) :
    (query char f).length ≤ char.moves.length := by
  unfold query
  exact List.length_filter_le (Filter.eval f) char.moves

/--
  NOT NOT is identity — double negation.
-/
theorem filter_not_not (f : Filter) (m : TekkenMove) :
    Filter.eval (.not (.not f)) m = Filter.eval f m := by
  simp [Filter.eval, Bool.not_not]

/--
  AND is commutative.
-/
theorem filter_and_comm (f g : Filter) (m : TekkenMove) :
    Filter.eval (.and f g) m = Filter.eval (.and g f) m := by
  simp [Filter.eval, Bool.and_comm]

/--
  OR is commutative.
-/
theorem filter_or_comm (f g : Filter) (m : TekkenMove) :
    Filter.eval (.or f g) m = Filter.eval (.or g f) m := by
  simp [Filter.eval, Bool.or_comm]

/--
  Querying with an empty filter list returns all moves unchanged.
-/
theorem queryAll_empty (char : TekkenCharacter) :
    queryAll char [] = char.moves := by
  rfl

/--
  If a move passes (f AND g), it passes f.
-/
theorem filter_and_left (f g : Filter) (m : TekkenMove)
    (h : Filter.eval (.and f g) m = true) :
    Filter.eval f m = true := by
  simp [Filter.eval] at h
  exact h.1

/--
  If a move passes (f AND g), it passes g.
-/
theorem filter_and_right (f g : Filter) (m : TekkenMove)
    (h : Filter.eval (.and f g) m = true) :
    Filter.eval g m = true := by
  simp [Filter.eval] at h
  exact h.2

end TekkenQuery
