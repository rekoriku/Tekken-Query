# Architecture

Two layers with strict separation of concerns — Lean 4 for data logic, Rust for the CLI.

```
GitHub (tekkendocs) --> Rust fetches raw CSVs --> Lean server converts to clean CSVs
                                               --> Lean server evaluates filters
                                               --> Rust displays results
```

The Lean binary runs as a persistent subprocess. Rust starts it once at startup and communicates via line-delimited JSON on stdin/stdout, so filter evaluation and CSV conversion don't pay per-query process startup cost. Raw and clean CSV schemas are detected from their headers and routed through the matching Lean record parser.

## Lean 4 — Data Core

All data logic lives here: CSV parsing, frame data parsing, filtering, comparisons, clean CSV export. Proofs are checked by the Lean kernel; no `sorry`, `unsafe`, `partial`, `implemented_by`, or `native_decide`.

| Module | Purpose |
|--------|---------|
| `TekkenQuery/Csv/Split.lean` | Character-by-character CSV splitter (multiline, quote-aware) |
| `TekkenQuery/Csv/Parser.lean` | Delimiter detection, field cleaning, record building |
| `TekkenQuery/Models.lean` | `TekkenMove`, `TekkenCharacter`, `HitLevel`, `MoveProperty` (19 typed properties) |
| `TekkenQuery/Frame.lean` | Startup / block frame parsing with general proofs (sign, round trip, guard rule, multi-hit) and real-data regression theorems; reused by `frameCompare` for hit and counter-hit |
| `TekkenQuery/Filter.lean` | `Filter` inductive (25+ constructors incl. `frameCompare`), `FrameField`, `CompareOp`, `Filter.eval`, `query`, `queryAll`, `compare`, 14 proofs |
| `TekkenQuery/Export.lean` | Clean CSV export with HTML stripping |
| `TekkenQuery/Json.lean` | JSON serialization: Filter deserialization (from Rust), TekkenMove serialization (to Rust), response envelopes |
| `TekkenQuery/Server.lean` | Pure query server logic: `ServerState`, request parsing, query/compare/convert processing |
| `Main.lean` | Thin IO layer: `--server` mode, `--export` mode, stats mode |
| `FrameCheck.lean` | `lake exe frame_check`: parses every distinct raw frame value and compares the results with a local snapshot |

### Proofs

The filter system includes proofs covering:

- `query_subset` — query results are always a subset of the move list
- `filter_not_not` — double negation is identity
- `filter_and_comm` / `filter_or_comm` — boolean algebra
- `compareOp_lt_neg_ge` / `compareOp_gt_neg_le` — operator duality
- `compareOp_lt_trans` / `compareOp_le_trans` — transitivity
- `compareOp_lt_implies_le` — ordering implications
- Plus reflexivity, empty query identity, AND projection

The frame parsers (`Frame.lean`) prove, for all inputs:

- `parseNatFromChars_append` — a digit run parses to its decimal value and the rest is kept
- `parseSignedValue_nonneg` / `parseSignedValue_nonpos` / `parseSignedValue_minus_eq_neg_plus` / `parseSignedValue_zero` — sign correctness, including `-0` = `+0` = 0
- `parseSignedValue_renderSignedValue`, `parseBlockFrame_renderSignedValue`, `parseBlockFrame_range_renderSignedValue` — values rendered as `+N` / `-N` / `0` (with an optional `g`, or as an `A~B` range) parse back exactly
- `parseStartupFrame_range_toString` — the `i{start}~{end}` form rebuilt from clean CSVs parses back exactly
- `parseBlockFrame_guardable` / `hasGuardSuffix_stop` — the guard flag is decided by the lowercase suffix attached to the leading number; nothing after a space, `(`, `/`, `~` or uppercase stance name affects it
- `parseStartupFrame_first_hit` — text after the first comma or whitespace (later hits) never changes the startup result
- `activeFrames_ge_one` / `activeFrames_of_le` / `activeFrames_of_lt` — active-frame counts, including the current fallback to 1 when a range ends before it starts

Lean's `toString` for negative `Int` is built on the opaque `String.Internal.append`, so the clean export's negative `block_frame` text cannot be reasoned about in the kernel; the round-trip theorems use the transparent `renderSignedValue` instead.

## Rust — Interactive CLI

Handles everything that isn't data logic: network, display, user input, aliases. Enforces `#![forbid(unsafe_code)]`; no `unwrap`, `expect`, `panic!`, `todo!`, or lossy `as` casts. Clippy pedantic with zero warnings.

| Module | Purpose |
|--------|---------|
| `interactive.rs` | Command-centre and selected-character contexts, direct move lookup, global/character-scoped frame-query shortcuts, fuzzy matching, aliases, notation normalization, roster overview |
| `lean_server.rs` | `LeanServer` subprocess: start, load, query, compare, convert, quit; filter→JSON serialization |
| `filter.rs` | Filter parsing for Rust→JSON translation; compact and spaced frame comparisons (`hit>0`, `hit +5`, `startup i15`) |
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

Rust validates every response envelope before using it: the response ID must match the request ID, status must be `ok` or `error`, and method-specific fields must have the expected types. Server diagnostics inherit stderr so they cannot block on an unread pipe.

The interactive REPL starts the server *before* checking for data updates, so `update_if_needed` can route raw→clean conversion through the persistent server instead of spawning a new Lean binary per character.

## Filter Language Status

Current user-facing filters are token based. A query is a whitespace-separated list of filters, combined with implicit AND:

```
pc !stance !cmd:2+3 by:i asc
```

Filtering itself is Lean-only: Rust parses tokens into `Filter` values, serializes them to JSON, and the Lean server evaluates them with `queryAll`. Filter queries require the Lean binary, and missing-backend, protocol, load, and query errors are surfaced without changing evaluator semantics. Output modifiers such as `by:i asc`, `limit:3`, `flat`, and `summary` are presentation logic and stay in Rust.

Supported logical surface today:

- implicit AND: `pc mid !punish`
- unary NOT on any filter: `!high`, `!stance`, `!stance:ZEN`, `!cmd:2+3`
- frame comparisons: `i<15`, `block=-10`, `hit>0`, `ch>=5`
- substring filters: `cmd:`, `name:`, `note:`
- roster output modifiers: `by:i asc`, `by:i desc`, `limit:N`, `flat`, `summary`

At the interactive command centre, `query <filters>` is the canonical explicit
roster-query form. `all` and `roster` remain compatibility aliases; bare frame
queries such as `hit +5` are roster-wide without an explicit command.

Important limitation: Lean already has `Filter.and`, `Filter.or`, and `Filter.not`, but the Rust parser currently exposes only implicit AND plus unary NOT. There is no user-facing OR, grouping, or exact command operator yet. `cmd:` is substring matching, so `!cmd:2+3` excludes every command containing `2+3`.

## Data Directory Layout

```
data/
├── raw/      # dirty CSVs from GitHub (semicolon-delimited, HTML tags, multiline fields)
├── clean/    # normalized CSVs produced by Lean export (HTML stripped, comma-delimited)
└── aliases.json   # user-defined move aliases
```

The character list is never hardcoded — it's discovered from the GitHub API on `fetch`.

Fetches may write newly downloaded raw and clean character files as they progress, but the manifest is updated only if every discovered character succeeds. A partial fetch therefore cannot advertise an incomplete roster as current. Roster queries likewise fail if a manifest-listed character cannot be loaded instead of silently omitting it.

## Verification

CI builds Lean and Rust on every pull request, rejects banned Lean escape hatches, runs Clippy with warnings denied, and runs the Rust test suite. Regression tests cover invalid frame filters and malformed server response shapes; smoke testing also exercises the real Lean server against checked-in clean data.

`lake exe frame_check` parses every distinct startup, block, hit and counter-hit value in the local `data/raw/` and reports unparsed values, values whose parse differs from the snapshot `data/frame_parse_snapshot.tsv` (guard-flag changes counted separately), and values new to the data. It exits with status 1 when a snapshot value changed meaning; new values from a data refresh do not fail it. `data/` is not tracked and CI has no fetched data, so this is a local check: record a snapshot with `lake exe frame_check --update` before changing a frame parser, rerun the check afterwards, review every changed value, then refresh the snapshot.
