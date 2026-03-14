# Lean 4.28 Patterns & API Reference

Discovered patterns that work with Lean 4.28.0. This file exists because
the Lean API has changed significantly and training data may be outdated.

## String API (CHANGED in 4.28)

String is now ByteArray-backed, NOT List Char.

```lean
-- OLD (deprecated):
String.mk charList        -- DON'T USE
⟨charList⟩               -- DON'T USE (tries String.ofByteArray, wrong type)

-- NEW (correct):
String.ofList charList     -- List Char → String
s.toList                   -- String → List Char
```

`String.dropRight` is deprecated → use `String.dropEnd` (returns `String.Slice`,
call `.toString` to get back a `String`).

## Structures

```lean
structure MyStruct where
  field1 : String
  field2 : Option String    -- optional field (None by default if Inhabited)
  field3 : Bool := false    -- default value
  deriving Repr, BEq, DecidableEq, Inhabited

-- Construction
def x : MyStruct := { field1 := "hello", field2 := none, field3 := true }

-- Functional update (creates copy with changed fields)
def y := { x with field3 := false }

-- Field access via dot notation
#eval x.field1
```

## Derivable Type Classes

At definition time: `deriving Repr, BEq, DecidableEq, Inhabited, Hashable, Ord`
After definition: `deriving instance BEq, Repr for MyType`

## Inductive Types (Enums)

```lean
inductive HitLevel where
  | high
  | mid
  | low
  deriving Repr, BEq, DecidableEq, Inhabited
```

## Option

```lean
Option.getD val default   -- unwrap or default
Option.map f val           -- apply function if Some
Option.bind val f          -- monadic chain
Option.isSome / .isNone   -- check
```

## Proofs - What Works

### Structural induction on List
```lean
theorem foo (xs : List α) : ... := by
  induction xs generalizing ... with
  | nil => ...
  | cons x rest ih => ...
```

### split tactic for if/match in hypothesis
`split at h` FAILS if there are `let` bindings hiding the `if`.
Solution: extract the `let`-heavy code into a separate function so `split` can see the `if` directly, or use `dsimp at h` first.

### simp with custom lemmas
```lean
simp [myDef, List.length_map, List.length_append]
```

### List.mem_map for ∈ on mapped lists
```lean
simp [List.mem_map] at hmem
obtain ⟨x, hx_mem, hx_eq⟩ := hmem
```

## String.trim → String.trimAscii (CHANGED in 4.28)

```lean
-- OLD (deprecated):
s.trim                     -- DON'T USE

-- NEW (correct):
s.trimAscii.toString       -- trimAscii returns String.Slice, need .toString
```

## String.containsSubstr (DOES NOT EXIST in 4.28)

There is no built-in `String.containsSubstr`. Implement using `splitOn`:

```lean
def containsSubstr (haystack : String) (needle : String) : Bool :=
  (haystack.splitOn needle).length > 1
```

This works because `splitOn` splits at every occurrence of the needle.
If the needle is found, the result has > 1 parts.

## Int.ofNat and omega

`omega` does NOT understand `Int.ofNat n ≥ 0`. It will fail with
"a possible counterexample may satisfy the constraints a ≤ -1".

For Int proofs, prefer:
- Direct `omega` on `Int.negSucc` (it knows this is always negative)
- Reformulate to avoid `Int.ofNat` in the statement
- Use `Int.negSucc_eq_neg` pattern: `Int.negSucc (n - 1) = -↑n`

## List.length_filter_le

Exists and works for proving filter results are subsets:
```lean
exact List.length_filter_le p someList
```

## Project Build

```bash
nix shell nixpkgs#elan -c lake build
```

## Banned Constructs (per CLAUDE.md)

sorry, unsafe, partial, implemented_by, native_decide, user-defined axiom
