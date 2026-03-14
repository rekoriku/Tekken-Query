# Lean 4: Datatypes and Patterns

Source: https://lean-lang.org/functional_programming_in_lean/Getting-to-Know-Lean/Datatypes-and-Patterns/

## Overview

This section explains how inductive datatypes work in Lean, distinguishing them from structures. While structures group independent data pieces, inductive datatypes handle multiple choices (sum types) and recursive structures.

## Inductive Datatypes

### Bool Definition

The `Bool` type demonstrates a simple inductive datatype with two constructors:

```lean
inductive Bool where
| false : Bool
| true : Bool
```

This creates a new type with two mutually exclusive options, similar to sealed abstract classes in object-oriented languages.

### Nat Definition

Natural numbers use recursion within the datatype definition:

```lean
inductive Nat where
| zero : Nat
| succ (n : Nat) : Nat
```

The `succ` constructor takes another `Nat` argument, allowing representation of arbitrary natural numbers. For example, 4 is represented as `Nat.succ (Nat.succ (Nat.succ (Nat.succ Nat.zero)))`.

## Pattern Matching

Pattern matching simultaneously identifies which constructor was used and extracts its arguments. This replaces the instance-of checks found in object-oriented languages.

### isZero Example

```lean
def isZero (n : Nat) : Bool := match n with
| Nat.zero => true
| Nat.succ k => false
```

Evaluation of `isZero Nat.zero` returns `true`, while `isZero 5` returns `false`.

### pred Function

The `pred` function demonstrates extracting data from constructors:

```lean
def pred (n : Nat) : Nat := match n with
| Nat.zero => Nat.zero
| Nat.succ k => k
```

The variable `k` captures the `Nat` argument to `succ`, which becomes the predecessor. Results show `pred 5` yields `4`, `pred 839` yields `838`, and `pred 0` yields `0`.

### Structure Pattern Matching

Pattern matching works with structures too:

```lean
def depth (p : Point3D) : Float := match p with
| { x:= h, y := w, z := d } => d
```

## Recursive Functions

Recursive datatypes pair naturally with recursive functions. A recursive function must eventually reach a base case through structural recursion.

### even Function

```lean
def even (n : Nat) : Bool := match n with
| Nat.zero => true
| Nat.succ k => not (even k)
```

This function identifies `Nat.zero` as even, then notes that successive numbers alternate parity.

### Termination Requirements

Lean enforces termination by default. This definition fails:

```lean
def evenLoops (n : Nat) : Bool := match n with
| Nat.zero => true
| Nat.succ k => not (evenLoops n)  -- ERROR: n instead of k
```

Error message states: "failed to infer structural recursion: Not considering parameter n of evenLoops: it is unchanged in the recursive calls"

The recursive call must operate on a structurally smaller argument.

### plus Function

Addition demonstrates recursive functions with multiple arguments:

```lean
def plus (n : Nat) (k : Nat) : Nat := match k with
| Nat.zero => n
| Nat.succ k' => Nat.succ (plus n k')
```

Only one parameter needs inspection. Evaluating `plus 3 2` proceeds through successive pattern matches until reaching the base case, yielding `5`.

### times and minus Functions

```lean
def times (n : Nat) (k : Nat) : Nat := match k with
| Nat.zero => Nat.zero
| Nat.succ k' => plus n (times n k')

def minus (n : Nat) (k : Nat) : Nat := match k with
| Nat.zero => n
| Nat.succ k' => pred (minus n k')
```

Multiplication applies addition iteratively; subtraction applies the predecessor function iteratively.

### Division Challenge

Division using iterated subtraction presents a problem:

```lean
def div (n : Nat) (k : Nat) : Nat :=
  if n < k then 0
  else Nat.succ (div (n - k) k)
```

This isn't structurally recursive because the recursive call applies to a computed result rather than a constructor's argument. The error message indicates: "Cannot use parameter k: failed to eliminate recursive application div [(n - k) k]"

The solution requires manual termination proofs, addressed in later chapters.

## Key Concepts

- **Product types**: Structures combining independent data
- **Sum types**: Inductive datatypes with multiple constructors
- **Recursive datatypes**: Datatypes containing instances of themselves
- **Inductive datatypes**: Recursive sum types
- **Pattern matching**: Simultaneously identifying constructors and extracting data
- **Structural recursion**: Recursive functions that reduce arguments toward base cases
- **Base cases**: Non-recursive branches handling the smallest inputs

The distinction between datatypes and structures enables Lean to elegantly express both fixed-field groupings and variable-choice alternatives while maintaining termination guarantees essential for theorem proving.
