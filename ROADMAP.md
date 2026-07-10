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
