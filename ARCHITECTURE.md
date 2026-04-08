# Architecture

Two layers with strict separation of concerns — Lean 4 for data logic, Rust for the CLI.

```
GitHub (tekkendocs) --> Rust fetches raw CSVs --> Lean server converts to clean CSVs
                                               --> Lean server evaluates filters
                                               --> Rust displays results
```

The Lean binary runs as a persistent subprocess. Rust starts it once at startup and communicates via line-delimited JSON on stdin/stdout, so filter evaluation and CSV conversion don't pay per-query process startup cost.

## Lean 4 — Data Core

All data logic lives here: CSV parsing, frame data parsing, filtering, comparisons, clean CSV export. Proofs are checked by the Lean kernel; no `sorry`, `unsafe`, `partial`, `implemented_by`, or `native_decide`.

| Module | Purpose |
|--------|---------|
| `TekkenQuery/Csv/Split.lean` | Character-by-character CSV splitter (multiline, quote-aware) |
| `TekkenQuery/Csv/Parser.lean` | Delimiter detection, field cleaning, record building |
| `TekkenQuery/Models.lean` | `TekkenMove`, `TekkenCharacter`, `HitLevel`, `MoveProperty` (19 typed properties) |
| `TekkenQuery/Frame.lean` | Startup / block frame parsing with proofs; reused by `frameCompare` for hit and counter-hit |
| `TekkenQuery/Filter.lean` | `Filter` inductive (25+ constructors incl. `frameCompare`), `FrameField`, `CompareOp`, `Filter.eval`, `query`, `queryAll`, `compare`, 14 proofs |
| `TekkenQuery/Export.lean` | Clean CSV export with HTML stripping |
| `TekkenQuery/Json.lean` | JSON serialization: Filter deserialization (from Rust), TekkenMove serialization (to Rust), response envelopes |
| `TekkenQuery/Server.lean` | Pure query server logic: `ServerState`, request parsing, query/compare/convert processing |
| `Main.lean` | Thin IO layer: `--server` mode, `--export` mode, stats mode |

### Proofs

The filter system includes proofs covering:

- `query_subset` — query results are always a subset of the move list
- `filter_not_not` — double negation is identity
- `filter_and_comm` / `filter_or_comm` — boolean algebra
- `compareOp_lt_neg_ge` / `compareOp_gt_neg_le` — operator duality
- `compareOp_lt_trans` / `compareOp_le_trans` — transitivity
- `compareOp_lt_implies_le` — ordering implications
- Plus reflexivity, empty query identity, AND projection

## Rust — Interactive CLI

Handles everything that isn't data logic: network, display, user input, aliases. Enforces `#![forbid(unsafe_code)]`; no `unwrap`, `expect`, `panic!`, `todo!`, or lossy `as` casts. Clippy pedantic with zero warnings.

| Module | Purpose |
|--------|---------|
| `interactive.rs` | REPL loop, fuzzy matching, aliases, notation normalization (incl. `cd` → crouch dash), global move lookup, list-all overview |
| `lean_server.rs` | `LeanServer` subprocess: start, load, query, compare, convert, quit; filter→JSON serialization |
| `filter.rs` | Filter token parsing (Rust→JSON translation); frame comparison syntax (`<+5`, `hit>0`, `ch>=5`); Rust-side eval fallback |
| `fetch.rs` | GitHub API, raw CSV fetching, upstream commit checking, conversion via `LeanServer` |
| `display.rs` | Column layout, color formatting (pad-then-colorize for ANSI alignment), per-component hit level coloring, single-move detail headers |
| `model.rs` | `Move`, `Character` structs (deserialized from clean CSV) |
| `data.rs` | Manifest loading, upstream commit checking |
| `aliases.rs` | Custom user-defined move aliases (`data/aliases.json`), add/remove/list |
| `completion.rs` | Tab completion for REPL (filter tokens, aliases, move commands, stances) |

## Query Server Protocol

Line-delimited JSON on stdin/stdout. The protocol is designed to be reusable — a REST API or alternate frontend could drive the same Lean binary.

| Method | Params | Response |
|--------|--------|----------|
| `load` | `id`, `name`, `path` (clean CSV) | `moves_loaded` |
| `convert` | `raw_path`, `clean_path` | `moves_exported` |
| `query` | `character`, `filters` | `name`, `total`, `count`, `moves` |
| `compare` | `char1`, `char2`, `filters` | `char1: {name, count, moves}`, `char2: ...` |
| `quit` | — | — |

The interactive REPL starts the server *before* checking for data updates, so `update_if_needed` can route raw→clean conversion through the persistent server instead of spawning a new Lean binary per character.

## Data Directory Layout

```
data/
├── raw/      # dirty CSVs from GitHub (semicolon-delimited, HTML tags, multiline fields)
├── clean/    # normalized CSVs produced by Lean export (HTML stripped, comma-delimited)
└── aliases.json   # user-defined move aliases
```

The character list is never hardcoded — it's discovered from the GitHub API on `fetch`.
