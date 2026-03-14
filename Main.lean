import TekkenQuery

open TekkenQuery in
open TekkenQuery.Csv in
def main (args : List String) : IO Unit := do
  let csvText ← match args.head? with
    | some path =>
      IO.println s!"Reading: {path}"
      IO.FS.readFile path
    | none =>
      IO.eprintln "Usage: tekken_query <file.csv>"
      IO.Process.exit 1

  match parse csvText with
  | .error .emptyInput   => IO.eprintln "Error: empty input"
  | .error .noHeader     => IO.eprintln "Error: no header row"
  | .error .singleColumn => IO.eprintln "Error: single column (wrong delimiter?)"
  | .ok result =>
    let moves := result.records.map TekkenMove.fromRecord
    let char : TekkenCharacter := { id := "test", name := "Test", moves := moves }

    IO.println s!"Headers ({result.headers.length}): {result.headers}"
    IO.println s!"Records: {result.records.length}"
    IO.println ""

    -- First 10 moves
    IO.println "--- First 10 moves ---"
    for move in (char.moves.take 10) do
      let startup := match move.startupFrameValue with
        | some n => s!"i{n}"
        | none => "?"
      let block := match move.blockFrameValue with
        | some v => if v ≥ 0 then s!"+{v}" else s!"{v}"
        | none => "?"
      let stance := match move.stance with
        | some s => s!"[{s}] "
        | none => ""
      IO.println s!"  {stance}{move.command} | {move.hitLevel.getD "?"} | {startup} | {block} | {move.name.getD ""}"

    -- Stats via composable filters
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
    IO.println s!"Stances: {char.getStances}"

    -- Diagnostics
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
