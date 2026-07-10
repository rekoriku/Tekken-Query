# Roadmap

This document tracks planned design work that is not part of the current architecture yet.

## Filter Expression Parser

Current filters are token based: whitespace means implicit AND, and `!` negates a single filter token. Lean already has `Filter.and`, `Filter.or`, and `Filter.not`, but the Rust parser does not yet expose full user-facing boolean expressions.

The next planned filter-language improvement is a real expression parser that maps directly onto the existing Lean filter combinators:

```text
pc & !stance & by:i asc
pc & !(stance | cmd=2+3)
pc & (mid | low) & !punish
pc & !level:h & by:i asc
```

Target semantics:

- `&` maps to Lean `Filter.and`
- `|` maps to Lean `Filter.or`
- `!` maps to Lean `Filter.not`
- parentheses control grouping
- bare whitespace may remain shorthand for `&`
- exact text operators should be added, e.g. `cmd=2+3`, alongside substring operators like `cmd:2+3`
- output modifiers such as `by:i asc`, `limit:N`, `flat`, and `summary` remain separate from filters and should not become Lean predicates

The rule for this work is the same as the rest of the project: Lean owns data/query semantics; Rust owns parsing, orchestration, display, networking, and interactive ergonomics.

## Versioned Frame-Data History

A future history feature should allow queries against earlier game versions and show how individual moves changed between patches. Historical frame data and official patch notes must remain separate but linked sources: snapshots describe the data that was observed, while patch notes describe what Bandai Namco said changed.

### Source and provenance model

Maintain a reviewed version registry containing:

- the complete game version, release date, and preceding version
- the official patch-note URL
- the selected upstream TekkenDocs commit
- an import revision and hashes of the raw and normalized data
- roster completeness and a confidence value: `verified`, `inferred`, `approximate`, or `missing`

TekkenDocs commits do not necessarily correspond one-to-one with game releases. Backfilling should therefore inspect commits around each official release date and record uncertainty instead of presenting the nearest commit as exact history.

Each imported version is an immutable, complete normalized snapshot. Imports should pass through the Lean CSV pipeline, and the current version manifest must not be reused as historical provenance. If normalization changes later, create a new import revision rather than rewriting the old snapshot.

Suggested canonical layout:

```text
data/history/
├── versions.json
├── identity-overrides.json
└── snapshots/
    ├── 1.08.01/
    │   ├── manifest.json
    │   └── clean/
    └── 2.00.01/
```

### Stable move identity

Commands alone are not permanent identifiers: notation can change, moves can be split or merged, and follow-ups can be added or removed. Assign each logical move a stable internal ID and map its representation in every version.

Automated matching between adjacent snapshots should try exact normalized command and stance first, then name and surrounding move attributes. Ambiguous matches must be placed in a review queue and resolved through a version-controlled override file; they must not be silently accepted through fuzzy matching.

### Computed changes and official notes

Generate structured field-level changes between adjacent snapshots, including:

- moves added or removed
- command or stance changes
- startup, active, block, hit, counter-hit, damage, and hit-level changes
- properties or tags added and removed
- note changes

Official patch-note entries should be stored as annotations linked to a stable move ID where possible. They must not overwrite computed changes because official notes can describe behavior—such as tracking, pushback, or opponent reactions—that is not represented by frame-data columns. Disagreements between the snapshot diff and official notes should remain visible.

### Generated database and interfaces

Keep reviewed registries, snapshots, overrides, and patch-note annotations as canonical files in Git. Generate an SQLite database for efficient CLI, website, and Discord queries rather than editing the database directly.

Potential interfaces:

```text
query jin mid plus --version 1.08.01
history jin df+2
changes jin --from 1.08.01 --to 2.00.01
compare-versions jin 1.08.01 2.00.01
```

The Lean protocol can eventually address characters by `(version, character)` or load an active version snapshot. Historical import and diff generation should remain an offline, reproducible build step; online requests should only query already normalized and reviewed data.

Suggested implementation order:

1. Build the official version registry.
2. Write a TekkenDocs Git-history importer.
3. Import two adjacent versions as a proof of concept.
4. Implement stable move matching and manual overrides.
5. Generate and review structured diffs.
6. Add version selection to the Lean protocol and shared Rust client.
7. Expose history through CLI, web, or Discord frontends.
