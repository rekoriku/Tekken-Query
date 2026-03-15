import TekkenQuery

open TekkenQuery
open Lean

/--
  Load a character from a CSV file.
  Auto-detects whether the file is a clean (exported) or raw CSV based on the
  first header. Uses the appropriate record parser for each format.
-/
def loadCharacterFromCsv (id name path : String) : IO (Except String TekkenCharacter) := do
  try
    let content ← IO.FS.readFile path
    match Csv.parse content with
    | .error .emptyInput   => return .error "empty CSV file"
    | .error .noHeader     => return .error "CSV has no header"
    | .error .singleColumn => return .error "CSV has single column (wrong delimiter?)"
    | .ok result =>
      -- Detect format: clean CSVs start with "command", raw with "Command"
      let isClean := result.headers.head? == some "command"
      let moves := if isClean then
        result.records.map TekkenMove.fromCleanRecord
      else
        result.records.map TekkenMove.fromRecord
      return .ok { id := id, name := name, moves := moves }
  catch _ =>
    return .error s!"failed to read file: {path}"

/--
  Convert raw CSV content to clean CSV content (pure).
  Parses the raw CSV, converts each record to a clean row, and produces
  the clean CSV string with headers.
-/
def exportRawToClean (rawContent : String) : Except String String :=
  match Csv.parse rawContent with
  | .error .emptyInput   => .error "empty CSV file"
  | .error .noHeader     => .error "CSV has no header"
  | .error .singleColumn => .error "CSV has single column (wrong delimiter?)"
  | .ok result =>
    let moves := result.records.map TekkenMove.fromRecord
    let headerLine := rowToCsvLine cleanCsvHeaders
    let dataLines := moves.map (fun m => rowToCsvLine m.toCleanRow)
    .ok (String.intercalate "\n" (headerLine :: dataLines) ++ "\n")

/--
  Convert a raw CSV file to a clean CSV file (IO wrapper).
  Returns the number of moves exported, or an error message.
-/
def convertFileIO (rawPath cleanPath : String) : IO (Except String Nat) := do
  try
    let rawContent ← IO.FS.readFile rawPath
    match exportRawToClean rawContent with
    | .error e => return .error e
    | .ok cleanContent =>
      IO.FS.writeFile cleanPath cleanContent
      -- Count moves (lines minus header)
      let lineCount := (cleanContent.splitOn "\n").filter (fun l => !l.isEmpty) |>.length
      return .ok (lineCount - 1)
  catch _ =>
    return .error s!"failed to read file: {rawPath}"

/--
  Send a JSON response on stdout (one line, then flush).
-/
def sendResponse (stdout : IO.FS.Stream) (response : Json) : IO Unit := do
  stdout.putStr (Json.compress response ++ "\n")
  stdout.flush

/--
  Server loop with bounded iterations (fuel parameter for totality).
  Reads JSON requests from stdin, processes them, writes responses to stdout.
  Exits on EOF, "quit" method, or fuel exhaustion.
-/
def serverLoop (fuel : Nat) (state : ServerState) (stdin stdout : IO.FS.Stream) : IO Unit :=
  match fuel with
  | 0 => IO.eprintln "server: max request limit reached"
  | fuel + 1 => do
    let line ← stdin.getLine
    -- Empty string from getLine = EOF (pipe closed)
    if line.isEmpty then return
    let trimmed := line.trimAscii.toString
    -- Skip blank lines
    if trimmed.isEmpty then
      serverLoop fuel state stdin stdout
    else
      match processRequest state trimmed with
      | .respond newState response => do
        sendResponse stdout response
        serverLoop fuel newState stdin stdout
      | .loadFile currentState id name path reqId => do
        match ← loadCharacterFromCsv id name path with
        | .ok char =>
          let newState := currentState.addCharacter id char
          let response := mkOkResponse reqId (Json.mkObj [
            ("moves_loaded", toJson char.moves.length)
          ])
          sendResponse stdout response
          serverLoop fuel newState stdin stdout
        | .error e =>
          sendResponse stdout (mkErrorResponse reqId e)
          serverLoop fuel currentState stdin stdout
      | .convertFile currentState rawPath cleanPath reqId => do
        match ← convertFileIO rawPath cleanPath with
        | .ok moveCount =>
          let response := mkOkResponse reqId (Json.mkObj [
            ("moves_exported", toJson moveCount)
          ])
          sendResponse stdout response
          serverLoop fuel currentState stdin stdout
        | .error e =>
          sendResponse stdout (mkErrorResponse reqId e)
          serverLoop fuel currentState stdin stdout
      | .quit response => do
        sendResponse stdout response

/--
  Run the query server: reads JSON from stdin, writes JSON to stdout.
  Status messages go to stderr.
-/
def serverMain : IO Unit := do
  IO.eprintln "tekken_query server ready"
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  serverLoop 10_000_000 ({} : ServerState) stdin stdout

def main (args : List String) : IO Unit := do
  let serverMode := args.any (· == "--server")
  let exportMode := args.any (· == "--export")
  let filePaths := args.filter (fun a => a != "--export" && a != "--server")

  if serverMode then
    serverMain
  else
    let csvText ← match filePaths.head? with
      | some path =>
        if !exportMode then IO.eprintln s!"Reading: {path}"
        IO.FS.readFile path
      | none =>
        IO.eprintln "Usage: tekken_query [--export|--server] <file.csv>"
        IO.Process.exit 1

    match Csv.parse csvText with
    | .error .emptyInput   => IO.eprintln "Error: empty input"
    | .error .noHeader     => IO.eprintln "Error: no header row"
    | .error .singleColumn => IO.eprintln "Error: single column (wrong delimiter?)"
    | .ok result =>
      let moves := result.records.map TekkenMove.fromRecord
      let char : TekkenCharacter := { id := "test", name := "Test", moves := moves }

      if exportMode then
        -- Clean CSV export to stdout
        IO.println (rowToCsvLine cleanCsvHeaders)
        for move in moves do
          IO.println (rowToCsvLine move.toCleanRow)
        IO.eprintln s!"Exported {moves.length} moves"
      else
        -- Stats mode (default)
        IO.println s!"Headers ({result.headers.length}): {result.headers}"
        IO.println s!"Records: {result.records.length}"
        IO.println ""

        IO.println "--- First 10 moves ---"
        for move in (char.moves.take 10) do
          let startup := match move.startupFrameValue with
            | some d =>
              let base := s!"i{d.startup}"
              match d.activeEnd with
              | some e => s!"{base}~{e}"
              | none => base
            | none => "?"
          let block := match move.blockFrameValue with
            | some d =>
              let base := if d.value ≥ 0 then s!"+{d.value}" else s!"{d.value}"
              let suffix := if d.guardable then "g" else ""
              s!"{base}{suffix}"
            | none => "?"
          let stance := match move.stance with
            | some s => s!"[{s}] "
            | none => ""
          IO.println s!"  {stance}{move.command} | {move.hitLevel.getD "?"} | {startup} | {block} | {move.name.getD ""}"

        IO.println ""
        IO.println "--- Stats ---"
        IO.println s!"Total:   {char.moves.length}"
        IO.println s!"Highs:   {(query char (.hitLevel "h")).length}"
        IO.println s!"Mids:    {(query char (.hitLevel "m")).length}"
        IO.println s!"Lows:    {(query char (.hitLevel "l")).length}"
        IO.println s!"Plus:    {(query char .plusOnBlock).length}"
        IO.println s!"Punish:  {(query char .punishable).length}"
        IO.println s!"Heat:    {(query char (.anyProperty [.heatEngager, .heatSmash, .heatBurst])).length}"
        IO.println s!"  Eng:   {(query char (.property .heatEngager)).length}"
        IO.println s!"  Smash: {(query char (.property .heatSmash)).length}"
        IO.println s!"  Burst: {(query char (.property .heatBurst)).length}"
        IO.println s!"PC:      {(query char (.property .powerCrush)).length}"
        IO.println s!"Homing:  {(query char (.property .homing)).length}"
        IO.println s!"Tornado: {(query char (.property .tornado)).length}"
        IO.println s!"Throws:  {(query char .isThrow).length}"
        IO.println s!"Unblk:   {(query char .isUnblockable).length}"
        IO.println s!"Neg:     {(query char .negative).length}"
        IO.println s!"Guard:   {(query char .guardable).length}"
        IO.println s!"Active2+:{(query char (.activeFramesGe 2)).length}"
        IO.println s!"Stances: {char.getStances}"

        let noStartup := moves.filter (fun m =>
          m.startupFrame.isSome && m.startupFrameValue.isNone)
        if !noStartup.isEmpty then
          IO.println s!"\nUnparseable startup ({noStartup.length}):"
          for m in noStartup.take 5 do
            IO.println s!"  {m.command}: '{m.startupFrame.getD ""}'"

        let noBlock := moves.filter (fun m =>
          m.blockFrame.isSome && m.blockFrameValue.isNone)
        if !noBlock.isEmpty then
          IO.println s!"\nUnparseable block frame ({noBlock.length}):"
          for m in noBlock.take 5 do
            IO.println s!"  {m.command}: '{m.blockFrame.getD ""}'"
