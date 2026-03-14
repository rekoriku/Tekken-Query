# Lean 4: Polymorphism

Source: https://lean-lang.org/functional_programming_in_lean/Getting-to-Know-Lean/Polymorphism/

## Overview

This chapter covers polymorphism -- a fundamental concept in functional programming where datatypes and definitions accept type arguments. This differs from object-oriented polymorphism based on inheritance.

## Polymorphic Structures

### PPoint Structure

The document introduces polymorphic types through `PPoint`, a generic point structure that accepts a type parameter:

```lean
structure PPoint (α : Type) where
  x : α
  y : α
```

This structure demonstrates how type arguments work similarly to function arguments. When instantiating `PPoint` with `Nat`, both fields become natural numbers.

An example usage shows creating a natural number origin point:

```lean
def natOrigin : PPoint Nat := {
  x := Nat.zero,
  y := Nat.zero
}
```

### Polymorphic Functions

Functions can also take types as arguments. The `replaceX` function demonstrates this pattern:

```lean
def replaceX (α : Type) (point : PPoint α) (newX : α) : PPoint α := {
  point with x := newX
}
```

When checking this function's type, Lean reveals the structure:

```lean
#check (replaceX)
-- replaceX : (α : Type) → PPoint α → α → PPoint α
```

Providing the `Nat` argument specializes the type:

```lean
#check replaceX Nat
-- replaceX Nat : PPoint Nat → Nat → PPoint Nat
```

Evaluation works despite type arguments being provided:

```lean
#eval replaceX Nat natOrigin 5
-- { x := 5, y := 0 }
```

## Dependent Types Through Pattern Matching

Types can depend on runtime values through pattern matching:

```lean
inductive Sign where
  | pos
  | neg

def posOrNegThree (s : Sign) : match s with
  | Sign.pos => Nat
  | Sign.neg => Int :=
  match s with
  | Sign.pos => (3 : Nat)
  | Sign.neg => (-3 : Int)
```

Because types are first class and can be computed using the ordinary rules of the Lean language, they can be computed by pattern-matching against a datatype.

## Linked Lists

### List Datatype

Lean's standard library includes a polymorphic `List` type:

```lean
inductive List (α : Type) where
  | nil : List α
  | cons : α → List α → List α
```

Lists have convenient bracket syntax for construction:

```lean
def primesUnder10 : List Nat := [2, 3, 5, 7]
```

This is equivalent to the explicit constructor form:

```lean
def explicitPrimesUnder10 : List Nat :=
  List.cons 2 (List.cons 3 (List.cons 5 (List.cons 7 List.nil)))
```

### Length Function

A polymorphic recursive function demonstrates how functions follow the shape of recursive datatypes:

```lean
def length (α : Type) (xs : List α) : Nat :=
  match xs with
  | List.nil => Nat.zero
  | List.cons y ys => Nat.succ (length α ys)
```

Using infix notation `::` for `cons` and `[]` for `nil` improves readability:

```lean
def length (α : Type) (xs : List α) : Nat :=
  match xs with
  | [] => 0
  | y :: ys => Nat.succ (length α ys)
```

## Implicit Arguments

Arguments in curly braces become implicit, allowing Lean to infer them from context:

```lean
def replaceX {α : Type} (point : PPoint α) (newX : α) : PPoint α := {
  point with x := newX
}
```

The function can now be called without explicitly providing the type:

```lean
#eval replaceX natOrigin 5
-- { x := 5, y := 0 }
```

Similarly, `length` with implicit type argument:

```lean
def length {α : Type} (xs : List α) : Nat :=
  match xs with
  | [] => 0
  | y :: ys => Nat.succ (length ys)
```

Can be applied directly:

```lean
#eval length primesUnder10
-- 4
```

The standard library version supports dot notation:

```lean
#eval primesUnder10.length
-- 4
```

When Lean cannot infer implicit arguments, they can be provided explicitly using named syntax:

```lean
#check List.length (α := Int)
-- List.length : List Int → Nat
```

## Option Type

The `Option` datatype represents potentially missing values:

```lean
inductive Option (α : Type) : Type where
  | none : Option α
  | some (val : α) : Option α
```

A function finding the first list element demonstrates usage:

```lean
def List.head? {α : Type} (xs : List α) : Option α :=
  match xs with
  | [] => none
  | y :: _ => some y
```

When applied to a non-empty list:

```lean
#eval primesUnder10.head?
-- some 2
```

For empty lists, explicit type specification is needed since the element type cannot be inferred:

```lean
#eval ([] : List Int).head?
-- none
```

## Product Type (Prod)

The `Prod` structure pairs two values of potentially different types:

```lean
structure Prod (α : Type) (β : Type) : Type where
  fst : α
  snd : β
```

The type `Prod α β` has special syntax `α × β`, and values use tuple notation:

```lean
def fives : String × Int := ("five", 5)
```

Right-associativity allows multi-element tuples:

```lean
def sevens : String × Int × Nat := ("VII", 7, 4 + 3)
-- Equivalent to: String × (Int × Nat) := ("VII", (7, 4 + 3))
```

## Sum Type

The `Sum` datatype represents a choice between two types (similar to Either in Haskell):

```lean
inductive Sum (α : Type) (β : Type) : Type where
  | inl : α → Sum α β
  | inr : β → Sum α β
```

## Sigma Type

For dependent pairs where the second type depends on the first value:

```lean
structure Sigma {α : Type} (β : α → Type) where
  fst : α
  snd : β fst
```

## Key Type Arguments in Functions

Type arguments make functions generic. Combined with implicit arguments, this enables writing polymorphic code that works with any type while keeping call sites clean:

```lean
-- Explicit type argument (must provide Nat)
def length (α : Type) (xs : List α) : Nat := ...
#eval length Nat primesUnder10

-- Implicit type argument (Lean infers Nat)
def length {α : Type} (xs : List α) : Nat := ...
#eval length primesUnder10
```
