# Tekken Query

Formally verified Tekken 8 frame data query tool.

All data logic — CSV parsing, frame data parsing, filtering, comparisons — is implemented in [Lean 4](https://lean-lang.org/) with mathematical proofs checked by the Lean kernel. The interactive CLI is written in Rust. No `sorry`, no `unsafe`, no shortcuts.

## Screenshots

<p align="center">
  <img src="assets/not_selected_move.png" width="520" alt="Global move lookup — df1 across all characters">
  <br><em>Global move lookup — compare df+1 across all 40 characters</em>
</p>

<p align="center">
  <img src="assets/selected_char.png" width="520" alt="Character queries — move lookup, filters, heat search">
  <br><em>Move lookup, notation shortcuts, filter queries, heat search</em>
</p>

<p align="center">
  <img src="assets/list.png" width="520" alt="Full move list with color-coded frame data">
  <br><em>Color-coded frame data — green (plus), yellow (safe), red (punishable)</em>
</p>

<p align="center">
  <img src="assets/chars.png" width="520" alt="Character list with move counts">
  <br><em>Full roster with move counts</em>
</p>

## Quick Start

### Download

Grab the latest release for your platform from [Releases](../../releases):

```
tekken-query-linux-x86_64.tar.gz
tekken-query-macos-arm64.tar.gz
tekken-query-windows-x86_64.zip
```

Each archive contains:
- `tekken-query` — **double-click this to launch** (launcher with icon)
- `tekken-cli` — the full CLI with all commands
- `tekken_query` — the verified Lean core

Place all files in the same directory.

> **macOS note:** If Gatekeeper blocks the binaries, run:
> `xattr -d com.apple.quarantine tekken-cli tekken_query`

### Run

```bash
# Double-click tekken-query, or from a terminal:
./tekken-query

# Or use the full CLI directly:
tekken-cli interactive

# One-shot query
tekken-cli query jin mid plus homing

# Compare two characters
tekken-cli compare jin kazuya mid plus
```

## Usage

### Interactive REPL

```bash
tekken-cli interactive
```

Two-level interface: pick a character, then query their moves.

**Character selection:**
```
Character? > jin          # fuzzy match: jin, kaz, devil, yoshi...
Character? > df1          # global move lookup across all characters
Character? > ewgf         # aliases work too
Character? > list         # show all characters
Character? > list-all     # roster overview (+OB count, HS startup)
```

**Move queries** (filters are AND'd together):
```
Jin > mid plus            # plus-on-block mids
Jin > i<15 hom            # fast homing moves
Jin > low !punish         # safe lows
Jin > heat                # all heat moves (engager + smash + burst + H. state)
Jin > hit>0 mid           # mids that are plus on hit
Jin > ch>=5 low           # lows with counter-hit advantage >= +5
Jin > <+5                 # moves with block frame < +5
Jin > stance:ZEN          # moves from a specific stance
Jin > cmd:df+2            # search by command notation
Jin > pc !high            # non-high power crushes
```

**Move lookup** (with fuzzy matching and notation shortcuts):
```
Jin > df2                 # auto-expands to df+2
Jin > cd2                 # crouch dash shorthand: f,n,d,df+2
Jin > ewgf                # move alias
Jin > hopkick             # universal alias
Jin > hellsweep           # character-specific alias
```

### CLI Commands

```bash
tekken-cli interactive          # interactive REPL (alias: i)
tekken-cli query <char> <filters...>   # one-shot query
tekken-cli move <char> <command>       # look up a specific move
tekken-cli compare <char1> <char2> <filters...>  # side-by-side comparison
tekken-cli chars                # list all characters
tekken-cli stats <char>         # character stats summary
tekken-cli check                # check for upstream data updates
tekken-cli fetch                # download/update frame data
```

### Filter Reference

| Filter | Meaning |
|--------|---------|
| `high`, `mid`, `low` | Hit level |
| `throw` | Throw moves |
| `plus` | Plus on block (> 0) |
| `minus` | Negative but safe (-1 to -9) |
| `punish` | Punishable (<= -10) |
| `guardable` | Opponent can still guard on block |
| `i15`, `i<15`, `i>=15` | Startup frame comparisons |
| `<+5`, `>-10`, `<=0`, `>=+3` | Block frame comparisons |
| `block<+5` | Explicit block frame comparison |
| `hit>0`, `hit>=5` | Hit frame comparison |
| `ch>0`, `ch>=5` | Counter-hit frame comparison |
| `he`, `hs`, `hb` | Heat engager / smash / burst |
| `heat` | All heat moves (engager + smash + burst + heat-state `H.` moves) |
| `pc` | Power crush |
| `hom` | Homing |
| `trn` | Tornado (tailspin) |
| `spk` | Spike |
| `js`, `cs` | Jump status / crouch status |
| `elb`, `kne`, `hed`, `wpn` | Elbow / knee / headbutt / weapon (unparryable) |
| `bbr`, `wbr`, `fbr` | Balcony / wall / floor break |
| `active3+` | Active frames >= 3 |
| `stance`, `stance:ZEN` | Any stance move / specific stance |
| `cmd:df+2` | Command substring search |
| `name:uppercut` | Move name search |
| `note:crush` | Notes search |
| `!<filter>` | Negate any filter |

### Aliases

Built-in aliases for common community terminology:

| Alias | Expands to |
|-------|-----------|
| `ewgf`, `dorya` | Electric Wind God Fist |
| `wgf` | Wind God Fist |
| `hellsweep` | Crouch dash low sweep |
| `hopkick` | uf+4 launcher |
| `dickjab` | d+1 crouch jab |
| `magic4` | Counter-hit launcher |
| `cd` | All crouch dash moves |
| `snakeedge` | Snake Edge |
| `orbital` | Orbital Heel |
| `tombstone` | Tombstone Pile Driver |
| `giantswing` | Giant Swing |
| `rageart`, `ragedrive` | Rage Art / Rage Drive |

#### Custom Aliases

Create your own aliases — saved to `data/aliases.json` and persisted across sessions:

```
Character? > alias pewgf cmd:f,n,d,df:2 name:perfect electric
Character? > alias mysetup cmd:df+2 name:wind god

Jin > pewgf                # uses your custom alias
Jin > aliases              # list all custom aliases
Jin > unalias pewgf        # remove an alias
```

Custom aliases override built-in ones, so you can redefine anything.

### Notation Shortcuts

Type shorthand in the REPL — it auto-expands:

| You type | Expands to |
|----------|-----------|
| `df2` | `df+2` |
| `uf4` | `uf+4` |
| `ff2` | `f,F+2` |
| `cd2` | `f,n,d,df+2` |
| `b4` | `b+4` |

## Architecture

Two layers with strict separation of concerns:

```
GitHub (tekkendocs) --> Rust fetches raw CSVs --> Lean server converts to clean CSVs
                                               --> Lean server evaluates filters
                                               --> Rust displays results
```

### Lean 4 — Verified Core

All data logic lives here. The Lean kernel mathematically verifies correctness.

| Module | Purpose |
|--------|---------|
| `TekkenQuery/Csv/Split.lean` | Character-by-character CSV parser (multiline, quote-aware) |
| `TekkenQuery/Csv/Parser.lean` | Delimiter detection, field cleaning, record building |
| `TekkenQuery/Models.lean` | `TekkenMove`, `TekkenCharacter`, `MoveProperty` (19 typed properties) |
| `TekkenQuery/Frame.lean` | Startup/block frame parsing with proofs |
| `TekkenQuery/Filter.lean` | 25+ composable filters with 14 proofs (subset, commutativity, transitivity...) |
| `TekkenQuery/Export.lean` | Clean CSV export with HTML stripping |
| `TekkenQuery/Json.lean` | JSON serialization for server protocol |
| `TekkenQuery/Server.lean` | Query server logic (load, query, compare, convert) |
| `Main.lean` | IO layer: `--server` mode, `--export` mode |

### Rust — Interactive CLI

Handles everything that isn't data logic: network, display, user input.

| Module | Purpose |
|--------|---------|
| `interactive.rs` | REPL loop, fuzzy matching, aliases, notation normalization |
| `lean_server.rs` | Lean subprocess management (persistent server over stdin/stdout) |
| `filter.rs` | Filter token parsing, Rust-side eval fallback |
| `display.rs` | Color-coded terminal output, column alignment |
| `fetch.rs` | GitHub API, raw CSV downloading |
| `model.rs` | `Move`, `Character` structs |
| `aliases.rs` | Custom user-defined move aliases (JSON config) |
| `completion.rs` | Tab completion (filters, aliases, move commands, stances) |

### Query Server Protocol

The Lean binary runs as a persistent subprocess. Rust communicates via line-delimited JSON on stdin/stdout:

| Method | Params | Response |
|--------|--------|----------|
| `load` | `id`, `name`, `path` | `moves_loaded` |
| `query` | `character`, `filters` | `name`, `total`, `count`, `moves` |
| `compare` | `char1`, `char2`, `filters` | `char1: {name, moves}`, `char2: ...` |
| `convert` | `raw_path`, `clean_path` | `moves_exported` |
| `quit` | -- | -- |

The server protocol is designed to be reusable — a REST API or other frontend could use the same Lean binary.

## Building from Source

### Requirements

- [elan](https://github.com/leanprover/elan) (Lean 4 toolchain manager)
- [Rust](https://rustup.rs/) (stable)
- On NixOS: `nix shell nixpkgs#elan nixpkgs#rustup`

### Build

```bash
# Build everything
./scripts/build.sh

# Or manually:
lake build                          # Lean core
cd cli && cargo build --release     # Rust CLI
```

### Verify

```bash
# No banned constructs in Lean
grep -rn 'sorry\|unsafe\|partial\|implemented_by\|native_decide' --include='*.lean' .
# Should return nothing

# Rust checks
cd cli
cargo clippy -- -D warnings         # zero warnings
cargo test                          # all tests pass
```

## Data Source

Frame data is sourced from [tekkendocs](https://github.com/pbruvoll/tekkendocs) (wavu.wiki). The CLI auto-fetches and converts data on first run. Updates are checked automatically in interactive mode.

Data flow:
```
Raw CSVs (messy, semicolon-delimited) --> Lean parser (verified) --> Clean CSVs --> queries
```

## Strictness Guarantees

### Lean (verified by kernel)

- No `sorry` — every proof is complete
- No `unsafe` — no unchecked operations
- No `partial` — all functions terminate on all inputs
- No `implemented_by` — no escape hatches to unverified code
- No `native_decide` — no runtime-only evaluation
- No user-defined `axiom` — no unproven assumptions
- All functions are pure, all data is immutable

### Rust (enforced by compiler + clippy)

- No `unsafe` — forbidden via `#![forbid(unsafe_code)]`
- No `unwrap()`/`expect()`/`panic!()` — all errors handled via `Result`/`Option`
- No lossy `as` casts — `TryFrom`/`From` only
- Full clippy pedantic with zero warnings

### Proofs

The filter system includes 14+ mathematical proofs:

- `query_subset` — query results are always a subset of the move list
- `filter_not_not` — double negation is identity
- `filter_and_comm` / `filter_or_comm` — boolean algebra
- `compareOp_lt_neg_ge` / `compareOp_gt_neg_le` — operator duality
- `compareOp_lt_trans` / `compareOp_le_trans` — transitivity
- `compareOp_lt_implies_le` — ordering implications
- And more (reflexivity, empty query identity, AND projection)

## License

[MIT](LICENSE)
