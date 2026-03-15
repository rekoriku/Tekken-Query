/-
  TekkenQuery.Filter
  Composable, universal move filter system.

  Adding a new filter = adding one constructor to `Filter`.
  No new functions needed. Everything composes automatically.
-/
import TekkenQuery.Frame
import TekkenQuery.Models

namespace TekkenQuery

-- ============================================================
-- Frame comparison types
-- ============================================================

/-- Which frame data field to compare. -/
inductive FrameField where
  | block
  | hit
  | counterHit
  deriving Repr, BEq, Inhabited

/-- Comparison operator for frame data. -/
inductive CompareOp where
  | lt | le | eq | ge | gt
  deriving Repr, BEq, Inhabited

/-- Evaluate a comparison operator on two integers. -/
def CompareOp.eval (op : CompareOp) (a b : Int) : Bool :=
  match op with
  | .lt => a < b
  | .le => a ≤ b
  | .eq => a == b
  | .ge => a ≥ b
  | .gt => a > b

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
  | guardable                           -- block frame has 'g' suffix (opponent can still guard)
  -- Startup frame filters
  | startupEq (frames : Nat)            -- startup == N
  | startupLt (frames : Nat)            -- startup < N (faster than)
  | startupGt (frames : Nat)            -- startup > N (slower than)
  | startupLe (frames : Nat)            -- startup ≤ N
  | startupGe (frames : Nat)            -- startup ≥ N
  | activeFramesGe (n : Nat)            -- at least n active frames
  -- Stance filters
  | stance (name : String)              -- moves from a specific stance
  | hasStance                           -- any stance move
  -- Property filters
  | property (p : MoveProperty)             -- move has this property
  | anyProperty (ps : List MoveProperty)    -- move has any of these
  | noteContains (keyword : String)         -- notes contain keyword
  -- Frame data comparison (block, hit, counter-hit × lt/le/eq/ge/gt)
  | frameCompare (field : FrameField) (op : CompareOp) (value : Int)
  -- Text search
  | nameContains (query : String)       -- name substring match
  | commandContains (query : String)    -- command substring match
  | hitLevelContains (query : String)   -- hit level substring match (for compound levels)
  -- Heat-state moves
  | isHeatMove                         -- heat engager/smash/burst OR command starts with "H."
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
    | some d => d.value > 0
    | none => false
  | .negative =>
    match m.blockFrameValue with
    | some d => d.value < 0 && d.value > -10
    | none => false
  | .punishable =>
    match m.blockFrameValue with
    | some d => d.value ≤ -10
    | none => false
  | .blockFrameBetween lo hi =>
    match m.blockFrameValue with
    | some d => d.value ≥ lo && d.value ≤ hi
    | none => false
  | .guardable =>
    match m.blockFrameValue with
    | some d => d.guardable
    | none => false
  | .startupEq n =>
    match m.startupFrameValue with
    | some d => d.startup == n
    | none => false
  | .startupLt n =>
    match m.startupFrameValue with
    | some d => d.startup < n
    | none => false
  | .startupGt n =>
    match m.startupFrameValue with
    | some d => d.startup > n
    | none => false
  | .startupLe n =>
    match m.startupFrameValue with
    | some d => d.startup ≤ n
    | none => false
  | .startupGe n =>
    match m.startupFrameValue with
    | some d => d.startup ≥ n
    | none => false
  | .activeFramesGe n =>
    match m.startupFrameValue with
    | some d =>
      match d.activeFrames with
      | some af => af ≥ n
      | none => false
    | none => false
  | .stance name =>
    match m.stance with
    | some s => s.toLower == name.toLower
    | none => false
  | .hasStance => m.stance.isSome
  | .property p => hasProperty m.properties p
  | .anyProperty ps => hasAnyProperty m.properties ps
  | .noteContains kw => hasNote m.properties kw
  | .frameCompare field op value =>
    let frameStr := match field with
      | .block => m.blockFrame
      | .hit => m.hitFrame
      | .counterHit => m.counterHitFrame
    match frameStr with
    | none => false
    | some s =>
      match Frame.parseBlockFrame s with
      | none => false
      | some d => op.eval d.value value
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
  | .isHeatMove =>
    hasAnyProperty m.properties [.heatEngager, .heatSmash, .heatBurst]
    || m.command.startsWith "H."
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

/--
  CompareOp.lt and CompareOp.ge are negations of each other.
  If a value is not ≥ threshold, it must be < threshold.
-/
theorem compareOp_lt_neg_ge (a b : Int) :
    CompareOp.eval .lt a b = !CompareOp.eval .ge a b := by
  unfold CompareOp.eval
  by_cases h : a < b <;> simp [h] <;> omega

/--
  CompareOp.gt and CompareOp.le are negations of each other.
  If a value is not ≤ threshold, it must be > threshold.
-/
theorem compareOp_gt_neg_le (a b : Int) :
    CompareOp.eval .gt a b = !CompareOp.eval .le a b := by
  unfold CompareOp.eval
  by_cases h : b < a <;> simp [h] <;> omega

/--
  CompareOp.eval .eq is reflexive.
-/
theorem compareOp_eq_refl (a : Int) :
    CompareOp.eval .eq a a = true := by
  simp [CompareOp.eval]

/--
  CompareOp.eval .le is reflexive.
-/
theorem compareOp_le_refl (a : Int) :
    CompareOp.eval .le a a = true := by
  simp [CompareOp.eval]

/--
  CompareOp.eval .ge is reflexive.
-/
theorem compareOp_ge_refl (a : Int) :
    CompareOp.eval .ge a a = true := by
  simp [CompareOp.eval]

/--
  lt is transitive: if a < b and b < c, then a < c.
-/
theorem compareOp_lt_trans (a b c : Int)
    (hab : CompareOp.eval .lt a b = true)
    (hbc : CompareOp.eval .lt b c = true) :
    CompareOp.eval .lt a c = true := by
  simp [CompareOp.eval] at *; omega

/--
  le is transitive: if a ≤ b and b ≤ c, then a ≤ c.
-/
theorem compareOp_le_trans (a b c : Int)
    (hab : CompareOp.eval .le a b = true)
    (hbc : CompareOp.eval .le b c = true) :
    CompareOp.eval .le a c = true := by
  simp [CompareOp.eval] at *; omega

/--
  If a < b, then a ≤ b (lt implies le).
-/
theorem compareOp_lt_implies_le (a b : Int)
    (h : CompareOp.eval .lt a b = true) :
    CompareOp.eval .le a b = true := by
  simp [CompareOp.eval] at *; omega

end TekkenQuery
