# Lean 4: Standard Classes

Source: https://lean-lang.org/functional_programming_in_lean/Overloading-and-Type-Classes/Standard-Classes/

## Overview

This chapter covers the standard type classes used for operator overloading in Lean 4, including arithmetic, comparison, hashing, equality, and automatic instance deriving.

## Type Definitions Used in Examples

```lean
inductive Pos where
  | one
  | succ : Pos → Pos

structure NonEmptyList (α : Type) where
  head : α
  tail : List α

inductive BinTree (α : Type) where
  | leaf : BinTree α
  | branch : BinTree α → α → BinTree α → BinTree α

inductive Ordering where
  | lt
  | eq
  | gt
```

## Arithmetic Operators

The page explains heterogeneous arithmetic operations (prefixed with "H") like `HAdd`, `HSub`, `HMul`, etc., with homogeneous variants by removing the "h". These allow overloading `+`, `-`, `*`, `/`, `%`, `^`, and negation.

| Class | Operator | Homogeneous Version |
|-------|----------|-------------------|
| HAdd  | `+`      | Add               |
| HSub  | `-`      | Sub               |
| HMul  | `*`      | Mul               |
| HDiv  | `/`      | Div               |
| HMod  | `%`      | Mod               |
| HPow  | `^`      | Pow               |

## Bitwise Operations

Classes like `HAnd`, `HOr`, `HXor` for operators `&&&`, `|||`, `^^^`, with shift operations `>>>` and `<<<`. Note that `AndOp` and `OrOp` are used for homogeneous versions to avoid conflicts with logical connectives.

## Equality (BEq)

Boolean equality uses the `BEq` class (returning `Bool`), while propositional equality uses `=` (a mathematical statement requiring proof).

```lean
def eqBinTree [BEq α] : BinTree α → BinTree α → Bool
  | BinTree.leaf, BinTree.leaf => true
  | BinTree.branch l x r, BinTree.branch l2 x2 r2 =>
    x == x2 && eqBinTree l l2 && eqBinTree r r2
  | _, _ => false

instance [BEq α] : BEq (BinTree α) where
  beq := eqBinTree
```

## Comparison and Ordering (LT, LE, Ord)

Comparison uses `LT` and `LE` classes for `<` and `<=`. The `Ord` class implements comparisons returning `Ordering` type with variants `lt`, `eq`, `gt`.

```lean
instance : LT Pos where
  lt x y := LT.lt x.toNat y.toNat

instance : LE Pos where
  le x y := LE.le x.toNat y.toNat

instance {x : Pos} {y : Pos} : Decidable (x < y) :=
  inferInstanceAs (Decidable (x.toNat < y.toNat))

instance {x : Pos} {y : Pos} : Decidable (x ≤ y) :=
  inferInstanceAs (Decidable (x.toNat ≤ y.toNat))

def Pos.comp : Pos → Pos → Ordering
  | Pos.one, Pos.one => Ordering.eq
  | Pos.one, Pos.succ _ => Ordering.lt
  | Pos.succ _, Pos.one => Ordering.gt
  | Pos.succ n, Pos.succ k => comp n k

instance : Ord Pos where
  compare := Pos.comp
```

## Hashing (Hashable)

The `Hashable` class provides hash computation via `UInt64`. The utility function `mixHash` combines hashes for multiple fields. Hash consistency requires that equal values produce equal hashes.

```lean
def hashPos : Pos → UInt64
  | Pos.one => 0
  | Pos.succ n => mixHash 1 (hashPos n)

instance : Hashable Pos where
  hash := hashPos

instance [Hashable α] : Hashable (NonEmptyList α) where
  hash xs := mixHash (hash xs.head) (hash xs.tail)

def hashBinTree [Hashable α] : BinTree α → UInt64
  | BinTree.leaf => 0
  | BinTree.branch left x right =>
    mixHash 1 (mixHash (hashBinTree left)
      (mixHash (hash x) (hashBinTree right)))

instance [Hashable α] : Hashable (BinTree α) where
  hash := hashBinTree
```

## Instance Deriving

Lean can automatically generate instances for `BEq`, `Repr`, `Hashable`, `Ord`, and `Inhabited` classes using the `deriving` syntax, reducing boilerplate code:

```lean
deriving instance BEq, Hashable for Pos
deriving instance BEq, Hashable for NonEmptyList
```

Deriving can also be done inline with the type definition:

```lean
inductive Pos where
  | one
  | succ : Pos → Pos
deriving BEq, Hashable, Repr, Ord
```

## Appending (Append, HAppend)

The `HAppend` and `Append` classes overload the `++` operator for concatenation operations:

```lean
instance : Append (NonEmptyList α) where
  append xs ys := {
    head := xs.head,
    tail := xs.tail ++ ys.head :: ys.tail
  }
```

## Summary of Key Type Classes

| Type Class | Purpose | Operator/Method |
|-----------|---------|----------------|
| BEq      | Boolean equality | `==` |
| Ord      | Comparison | `compare` returns `Ordering` |
| Hashable | Hashing | `hash` returns `UInt64` |
| Repr     | String representation for debugging | `repr` |
| ToString | String conversion | `toString` |
| Inhabited| Default value | `default` |
| Append   | Concatenation | `++` |
| Add/Sub/Mul/Div | Arithmetic | `+`, `-`, `*`, `/` |
