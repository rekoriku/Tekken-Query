/-
  TekkenQuery.Server
  Pure request processing logic for the query server protocol.
  All IO is handled in Main.lean — this module only does pure computation.

  Protocol: line-delimited JSON on stdin/stdout.
  Requests:
    {"id": N, "method": "load",    "params": {"id": "jin", "name": "Jin Kazama", "path": "data/clean/jin.csv"}}
    {"id": N, "method": "query",   "params": {"character": "jin", "filters": [...]}}
    {"id": N, "method": "compare", "params": {"char1": "jin", "char2": "kazuya", "filters": [...]}}
    {"id": N, "method": "quit"}
  Responses:
    {"id": N, "status": "ok",    "result": {...}}
    {"id": N, "status": "error", "error": "message"}
-/
import TekkenQuery.Json

namespace TekkenQuery

open Lean

-- ============================================================
-- Server state
-- ============================================================

/-- Server state: loaded characters indexed by ID. -/
structure ServerState where
  characters : List (String × TekkenCharacter) := []
  deriving Inhabited

/-- Find a loaded character by ID. -/
def ServerState.findCharacter (state : ServerState) (id : String) : Option TekkenCharacter :=
  match state.characters.find? (fun p => p.1 == id) with
  | some (_, char) => some char
  | none => none

/-- Add or replace a character in the state. -/
def ServerState.addCharacter (state : ServerState) (id : String) (char : TekkenCharacter) : ServerState :=
  let filtered := state.characters.filter (fun p => p.1 != id)
  { characters := (id, char) :: filtered }

-- ============================================================
-- Request parsing
-- ============================================================

/-- A parsed server request. -/
inductive ParsedRequest where
  | load (id : String) (name : String) (csvPath : String)
  | query (characterId : String) (filters : List Filter)
  | compare (char1Id : String) (char2Id : String) (filters : List Filter)
  | quit
  deriving Repr

/-- Extract the request ID from a JSON request, defaulting to null. -/
def getRequestId (json : Json) : Json :=
  match json.getObjVal? "id" with
  | .ok v => v
  | .error _ => Json.null

/-- Parse filters from a params JSON object. -/
def parseFiltersFromParams (params : Json) : Except String (List Filter) := do
  let filtersJson ← params.getObjVal? "filters"
  let arr ← filtersJson.getArr?
  parseFiltersJson arr.toList

/-- Parse a request line into a structured request. -/
def parseRequest (line : String) : Except String (Json × ParsedRequest) := do
  let json ← Json.parse line
  let method ← json.getObjValAs? String "method"
  match method with
  | "load" => do
    let params ← json.getObjVal? "params"
    let id ← params.getObjValAs? String "id"
    let name ← params.getObjValAs? String "name"
    let path ← params.getObjValAs? String "path"
    return (json, .load id name path)
  | "query" => do
    let params ← json.getObjVal? "params"
    let charId ← params.getObjValAs? String "character"
    let filters ← parseFiltersFromParams params
    return (json, .query charId filters)
  | "compare" => do
    let params ← json.getObjVal? "params"
    let char1 ← params.getObjValAs? String "char1"
    let char2 ← params.getObjValAs? String "char2"
    let filters ← parseFiltersFromParams params
    return (json, .compare char1 char2 filters)
  | "quit" => return (json, .quit)
  | other => .error s!"unknown method: {other}"

-- ============================================================
-- Request processing (pure)
-- ============================================================

/-- Result of processing a server request. -/
inductive RequestResult where
  /-- Send a response, continue with updated state. -/
  | respond (state : ServerState) (json : Json)
  /-- Need to load a CSV file (IO required by Main.lean). -/
  | loadFile (state : ServerState) (id : String) (name : String)
      (csvPath : String) (reqId : Json)
  /-- Server should shut down after sending this response. -/
  | quit (json : Json)

/-- Build a query response from a character and filter results. -/
def buildQueryResponse (reqId : Json) (char : TekkenCharacter)
    (filters : List Filter) : Json :=
  let results := queryAll char filters
  mkOkResponse reqId (Json.mkObj [
    ("name", Json.str char.name),
    ("total", toJson char.moves.length),
    ("count", toJson results.length),
    ("moves", movesToJson results)
  ])

/-- Build a compare response from two characters and filter results. -/
def buildCompareResponse (reqId : Json) (char1 char2 : TekkenCharacter)
    (filters : List Filter) : Json :=
  let results1 := queryAll char1 filters
  let results2 := queryAll char2 filters
  mkOkResponse reqId (Json.mkObj [
    ("char1", Json.mkObj [
      ("name", Json.str char1.name),
      ("count", toJson results1.length),
      ("moves", movesToJson results1)
    ]),
    ("char2", Json.mkObj [
      ("name", Json.str char2.name),
      ("count", toJson results2.length),
      ("moves", movesToJson results2)
    ])
  ])

/--
  Process a single request line.
  Returns a RequestResult indicating what the IO layer should do.
-/
def processRequest (state : ServerState) (line : String) : RequestResult :=
  match parseRequest line with
  | .error e => .respond state (mkErrorResponse Json.null e)
  | .ok (json, req) =>
    let reqId := getRequestId json
    match req with
    | .load id name path =>
      .loadFile state id name path reqId
    | .query charId filters =>
      match state.findCharacter charId with
      | none => .respond state (mkErrorResponse reqId s!"character not loaded: {charId}")
      | some char => .respond state (buildQueryResponse reqId char filters)
    | .compare char1Id char2Id filters =>
      match state.findCharacter char1Id, state.findCharacter char2Id with
      | some char1, some char2 =>
        .respond state (buildCompareResponse reqId char1 char2 filters)
      | none, _ =>
        .respond state (mkErrorResponse reqId s!"character not loaded: {char1Id}")
      | _, none =>
        .respond state (mkErrorResponse reqId s!"character not loaded: {char2Id}")
    | .quit => .quit (mkOkResponse reqId Json.null)

-- ============================================================
-- Proofs
-- ============================================================

/-- Finding a just-added character always succeeds. -/
theorem findCharacter_addCharacter (state : ServerState) (id : String)
    (char : TekkenCharacter) :
    (state.addCharacter id char).findCharacter id = some char := by
  simp [ServerState.addCharacter, ServerState.findCharacter]

end TekkenQuery
