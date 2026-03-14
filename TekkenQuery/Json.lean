/-
  TekkenQuery.Json
  JSON serialization for the query server protocol.
  - Filter deserialization (from Rust requests)
  - TekkenMove serialization (to Rust responses)
  - Request/response envelope helpers
  Pure functions only — no IO.
-/
import Lean.Data.Json
import TekkenQuery.Models
import TekkenQuery.Filter
import TekkenQuery.Export

namespace TekkenQuery

open Lean

-- ============================================================
-- MoveProperty string mapping (for filter JSON)
-- ============================================================

/--
  Parse a MoveProperty from its protocol string name.
  Used when deserializing filter requests from Rust.
-/
def MoveProperty.fromString (s : String) : Option MoveProperty :=
  match s with
  | "heatEngager"      => some .heatEngager
  | "heatSmash"        => some .heatSmash
  | "heatBurst"        => some .heatBurst
  | "tornado"          => some .tornado
  | "spike"            => some .spike
  | "powerCrush"       => some (.powerCrush none)
  | "jumpStatus"       => some (.jumpStatus none)
  | "crouchStatus"     => some (.crouchStatus none)
  | "fullCrouchStatus" => some (.fullCrouchStatus none)
  | "parryStatus"      => some (.parryStatus none)
  | "invincible"       => some (.invincible none)
  | "homing"           => some .homing
  | "balconyBreak"     => some .balconyBreak
  | "wallBreak"        => some .wallBreak
  | "floorBreak"       => some .floorBreak
  | "elbow"            => some .elbow
  | "knee"             => some .knee
  | "headbutt"         => some .headbutt
  | "weapon"           => some .weapon
  | "reversalBreak"    => some .reversalBreak
  | "chipDamage"       => some .chipDamage
  | _                  => none

-- ============================================================
-- Filter JSON deserialization (with fuel for termination)
-- ============================================================

/-- Maximum recursion depth for filter JSON parsing. -/
def maxFilterDepth : Nat := 64

/--
  Parse a single Filter from a JSON object.
  Uses a fuel parameter for structural termination of recursive cases
  (not, and, or combinators).

  Expected JSON format:
    {"filter": "hitLevel", "value": "m"}
    {"filter": "plusOnBlock"}
    {"filter": "not", "inner": {...}}
    {"filter": "and", "left": {...}, "right": {...}}
-/
def parseFilterJson (j : Json) (fuel : Nat) : Except String Filter :=
  match fuel with
  | 0 => .error "filter nesting too deep"
  | fuel + 1 => do
    let filterType ← j.getObjValAs? String "filter"
    match filterType with
    -- Hit level filters
    | "hitLevel" => do
      let v ← j.getObjValAs? String "value"
      return .hitLevel v
    | "isThrow" => return .isThrow
    | "isUnblockable" => return .isUnblockable
    -- Block frame filters
    | "plusOnBlock" => return .plusOnBlock
    | "negative" => return .negative
    | "punishable" => return .punishable
    | "guardable" => return .guardable
    | "blockFrameBetween" => do
      let lo ← j.getObjValAs? Int "lo"
      let hi ← j.getObjValAs? Int "hi"
      return .blockFrameBetween lo hi
    -- Startup frame filters
    | "startupEq" => do
      let v ← j.getObjValAs? Nat "value"
      return .startupEq v
    | "startupLt" => do
      let v ← j.getObjValAs? Nat "value"
      return .startupLt v
    | "startupGt" => do
      let v ← j.getObjValAs? Nat "value"
      return .startupGt v
    | "startupLe" => do
      let v ← j.getObjValAs? Nat "value"
      return .startupLe v
    | "startupGe" => do
      let v ← j.getObjValAs? Nat "value"
      return .startupGe v
    | "activeFramesGe" => do
      let v ← j.getObjValAs? Nat "value"
      return .activeFramesGe v
    -- Stance filters
    | "stance" => do
      let v ← j.getObjValAs? String "value"
      return .stance v
    | "hasStance" => return .hasStance
    -- Property filters
    | "property" => do
      let v ← j.getObjValAs? String "value"
      match MoveProperty.fromString v with
      | some p => return .property p
      | none => .error s!"unknown property: {v}"
    | "anyProperty" => do
      let vs ← j.getObjValAs? (List String) "value"
      let props := vs.filterMap MoveProperty.fromString
      if props.isEmpty then .error "no valid properties in anyProperty"
      else return .anyProperty props
    | "noteContains" => do
      let v ← j.getObjValAs? String "value"
      return .noteContains v
    -- Text search
    | "nameContains" => do
      let v ← j.getObjValAs? String "value"
      return .nameContains v
    | "commandContains" => do
      let v ← j.getObjValAs? String "value"
      return .commandContains v
    | "hitLevelContains" => do
      let v ← j.getObjValAs? String "value"
      return .hitLevelContains v
    -- Combinators (recursive — fuel decreases)
    | "not" => do
      let inner ← j.getObjVal? "inner"
      let f ← parseFilterJson inner fuel
      return .not f
    | "and" => do
      let left ← j.getObjVal? "left"
      let right ← j.getObjVal? "right"
      let f ← parseFilterJson left fuel
      let g ← parseFilterJson right fuel
      return .and f g
    | "or" => do
      let left ← j.getObjVal? "left"
      let right ← j.getObjVal? "right"
      let f ← parseFilterJson left fuel
      let g ← parseFilterJson right fuel
      return .or f g
    | other => .error s!"unknown filter type: {other}"

/-- Parse a list of filter JSON objects into a list of Filters. -/
def parseFiltersJson (arr : List Json) : Except String (List Filter) :=
  arr.mapM (fun j => parseFilterJson j maxFilterDepth)

-- ============================================================
-- TekkenMove JSON serialization
-- ============================================================

/--
  Serialize a TekkenMove to JSON using the clean CSV field format.
  All values are strings, matching the Rust Move struct's serde expectations.
  Piggybacks on the verified `toCleanRow` function.
-/
def moveToJson (m : TekkenMove) : Json :=
  let row := m.toCleanRow
  Json.mkObj (cleanCsvHeaders.zip row |>.map fun (h, v) => (h, Json.str v))

/-- Serialize a list of moves to a JSON array. -/
def movesToJson (moves : List TekkenMove) : Json :=
  Json.arr (moves.map moveToJson).toArray

-- ============================================================
-- Response envelope helpers
-- ============================================================

/-- Create a success response envelope. -/
def mkOkResponse (reqId : Json) (result : Json) : Json :=
  Json.mkObj [("id", reqId), ("status", Json.str "ok"), ("result", result)]

/-- Create an error response envelope. -/
def mkErrorResponse (reqId : Json) (message : String) : Json :=
  Json.mkObj [("id", reqId), ("status", Json.str "error"), ("error", Json.str message)]

-- ============================================================
-- Proofs
-- ============================================================

/-- Parsing a filter with zero fuel always fails. -/
theorem parseFilterJson_zero (j : Json) :
    parseFilterJson j 0 = .error "filter nesting too deep" := by
  rfl

end TekkenQuery
