# tekken_query

Formally verified Tekken 8 frame data query tool written in Lean 4.

Core logic (CSV parsing, frame parsing, data models, filtering) is implemented in Lean 4
with formal proofs. No `sorry`, `unsafe`, `partial`, `implemented_by`, `native_decide`,
or user-defined `axiom` — the Lean kernel verifies everything.

## Architecture

```
CSV file (semicolon-delimited, messy human-edited data)
  │
  ▼
┌─────────────────────────────────────────────────┐
│  Csv.Split    — character-by-character parser    │
│                 handles multiline quoted fields   │
│                 respects quotes across newlines   │
├─────────────────────────────────────────────────┤
│  Csv.Parser   — delimiter detection, cleaning    │
│                 nan/empty → none, trim whitespace │
│                 outputs List CleanRecord          │
├─────────────────────────────────────────────────┤
│  Models       — TekkenMove, MoveProperty, etc.   │
│                 pure data, no IO                  │
│                 tag strings → typed properties    │
├─────────────────────────────────────────────────┤
│  Frame        — "i13" → 13, "+5" → 5, "-10" → -10│
│                 total parsers, no crashes          │
├─────────────────────────────────────────────────┤
│  Filter       — composable filter DSL             │
│                 one eval function does everything  │
│                 proven: subset, commutativity, etc.│
└─────────────────────────────────────────────────┘
  │
  ▼
Query results (List TekkenMove)
```

## Modules

### `TekkenQuery.Csv.Split`
Core CSV record splitter. Walks the entire input character by character in a single pass.
Correctly handles:
- Multiline quoted fields (newlines inside quotes are part of the field)
- Delimiters inside quotes (`[12;12]` in damage values)
- Both `\n` and `\r\n` line endings

**Key function:** `splitRecords` — splits a CSV string into `List (List String)`.

**Proof:** `splitRecordsAux_length_ge` — the parser always produces at least one record.

### `TekkenQuery.Csv.Parser`
High-level CSV parser. Detects delimiter (semicolon or comma), splits records,
zips with headers, and cleans all values in one pipeline.

**Key type:** `CleanRecord = List (String × Option String)` — each field is a
`(headerName, cleanedValue)` pair where `None` means empty/nan/whitespace.

**Key function:** `parse` — full CSV string → `Except ParseError ParseResult`.

**Proofs:**
- `zipAndClean_length` — output always has exactly `headers.length` pairs
- `zipAndClean_keys` — output keys are exactly the header names
- `buildRecords_length` — record count is preserved
- `buildRecords_field_count` — every record has exactly `headers.length` fields

### `TekkenQuery.Frame`
Verified frame data parsers. Converts messy frame strings into clean numeric values.

| Input | Output | Notes |
|-------|--------|-------|
| `"i13"` | `some 13` | Startup frame |
| `"i12~13"` | `some 12` | Range — takes first value |
| `"+5"` | `some 5` | Positive block frame |
| `"-10"` | `some (-10)` | Negative block frame |
| `"-9g"` | `some (-9)` | Strips trailing letters |
| `"+4~+5"` | `some 4` | Range — takes first value |

**Proofs:**
- `negSucc_neg` — negative representation is always < 0
- `negSucc_eq_neg` — `Int.negSucc (n-1) = -n` for positive n

### `TekkenQuery.Models`
Pure data models. No IO, no side effects, all fields immutable.

#### `MoveProperty` — typed move properties
Every known CSV tag is a proper type constructor, not a raw string:

```
MoveProperty
├── Heat system:     heatEngager, heatSmash, heatBurst
├── Combo:           tornado, spike
├── Defensive:       powerCrush, jumpStatus, crouchStatus,
│                    fullCrouchStatus, parryStatus, invincible
│                    (each with optional FrameRange)
├── Tracking:        homing
├── Stage:           balconyBreak, wallBreak, floorBreak
├── Parry immunity:  elbow, knee, headbutt, weapon
└── Other:           reversalBreak, chipDamage
```

#### CSV tag → MoveProperty mapping
Tags are parsed from the `Tags` column via `parseRawTag`:

| CSV tag | MoveProperty | Meaning |
|---------|-------------|---------|
| `he` | `.heatEngager` | Activates heat on hit |
| `hs` | `.heatSmash` | H.command, consumes heat |
| `hb` | `.heatBurst` | 2+3, universal heat activation |
| `trn` | `.tornado` | Launches for combo (tailspin) |
| `spk` | `.spike` | Spikes grounded opponent |
| `pc` | `.powerCrush` | Absorbs hits during startup |
| `js` | `.jumpStatus` | Airborne, crushes lows |
| `cs` | `.crouchStatus` | Crouching, crushes highs |
| `fs` | `.fullCrouchStatus` | Full crouch status |
| `ps` | `.parryStatus` | Auto-parry window |
| `is` | `.invincible` | Full invincibility |
| `hom` | `.homing` | Tracks sidesteps |
| `bbr` | `.balconyBreak` | Triggers balcony break |
| `wbr` | `.wallBreak` | Triggers wall break |
| `fbr` | `.floorBreak` | Triggers floor break |
| `elb` | `.elbow` | Unparryable (elbow) |
| `kne` | `.knee` | Unparryable (knee) |
| `hed` | `.headbutt` | Unparryable (headbutt) |
| `wpn` | `.weapon` | Unparryable (weapon) |
| `rbr` | `.reversalBreak` | Breaks reversals |
| `chp` | `.chipDamage` | Does chip damage on block |

Frame-ranged tags like `pc7~16` carry a `FrameRange` indicating active frames.

#### Adding a new property
1. Add a constructor to `MoveProperty` in `Models.lean`
2. Add a line in `parseRawTag` mapping the CSV tag code to the constructor
3. Add a line in `MoveProperty.matchesKind` in `Filter.lean`

That's it. No new functions, no new filter types, no booleans to thread through.

#### Other key types
- **`TekkenMove`** — a single move with all frame data and properties
- **`TekkenCharacter`** — a character with their move list
- **`FrameRange`** — optional start/end frame for status properties

### `TekkenQuery.Filter`
Composable filter DSL. One `Filter` type, one `eval` function, infinite combinations.

#### Filter constructors

| Filter | What it matches |
|--------|----------------|
| `.hitLevel "m"` | Hit level starts with "m" (mid) |
| `.isThrow` | Hit level contains "t" |
| `.isUnblockable` | Hit level contains "!" |
| `.plusOnBlock` | Block frame > 0 |
| `.negative` | Block frame -1 to -9 |
| `.punishable` | Block frame ≤ -10 |
| `.blockFrameBetween lo hi` | lo ≤ block frame ≤ hi |
| `.startupEq n` | Startup == n frames |
| `.startupLt n` | Startup < n (faster than) |
| `.startupGt n` | Startup > n (slower than) |
| `.startupLe n` | Startup ≤ n |
| `.startupGe n` | Startup ≥ n |
| `.stance "ZEN"` | From specific stance |
| `.hasStance` | Any stance move |
| `.property .powerCrush` | Has power crush property |
| `.anyProperty [.heatEngager, .heatSmash, .heatBurst]` | Has any of these |
| `.noteContains "rage art"` | Notes contain keyword |
| `.nameContains "uppercut"` | Move name substring match |
| `.commandContains "df"` | Command substring match |
| `.hitLevelContains "m"` | Hit level substring match |
| `.not f` | Negate a filter |
| `.and f g` | Both must match |
| `.or f g` | Either can match |

#### Query functions

```lean
-- Find all plus-on-block mids
query char (.and (.hitLevel "m") .plusOnBlock)

-- Find all homing power crushes
query char (.and (.property .homing) (.property .powerCrush))

-- All heat moves (engager, smash, or burst)
query char (.anyProperty [.heatEngager, .heatSmash, .heatBurst])

-- All unparryable moves
query char (.anyProperty [.elbow, .knee, .headbutt, .weapon])

-- Moves faster than i15 that are plus on block
query char (.and (.startupLt 15) .plusOnBlock)

-- Chain multiple filters
queryAll char [.hitLevel "m", .plusOnBlock, .property .homing]

-- Compare two characters
compare jin kazuya (.property .heatEngager)
```

#### Proofs
- `query_subset` — query results are always a subset of the move list
- `filter_not_not` — double negation is identity
- `filter_and_comm` — AND is commutative
- `filter_or_comm` — OR is commutative
- `queryAll_empty` — empty filter list returns all moves
- `filter_and_left` / `filter_and_right` — AND implies each operand

## Data pipeline

```
Raw CSV ("hb pc7~16")
  → splitRecords (character-by-character, quote-aware)
  → zipAndClean (pair with headers, clean nan/empty)
  → TekkenMove.fromRecord (build typed move)
    → parseStance ("ZEN.1+2" → stance="ZEN", cmd="1+2")
    → parseTags ("hb pc7~16" → [.heatBurst, .powerCrush ⟨7, some 16⟩])
    → startupFrameValue ("i13" → some 13)
    → blockFrameValue ("-10" → some (-10))
  → query/queryAll/compare (composable filters)
```

## Building

Requires [elan](https://github.com/leanprover/elan) (Lean toolchain manager).

```bash
# NixOS
nix shell nixpkgs#elan -c lake build

# Other systems (with elan installed)
lake build
```

## Running

```bash
lake env .lake/build/bin/tekken_query path/to/character.csv
```

CSV files are semicolon-delimited frame data from
[wavu.wiki](https://wavu.wiki/) (tekkendocs format).

## Strictness guarantees

Enforced by `CLAUDE.md` rules and verified by the Lean kernel:

- No `sorry` — every proof is complete
- No `unsafe` — no unchecked operations
- No `partial` — all functions are total (terminate on all inputs)
- No `implemented_by` — no escape hatches
- No `native_decide` — no runtime-only evaluation
- No user-defined `axiom` — no unproven assumptions
- All functions are pure — no side effects, no mutation
- All data is immutable
