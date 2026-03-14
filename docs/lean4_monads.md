# Lean 4: Monads

Source: https://lean-lang.org/functional_programming_in_lean/Monads/

## Overview

This chapter introduces monads as a unified computational pattern. Rather than requiring language designers to anticipate every use case (null-checking, exception handling, logging), monads provide "one API, many applications" -- a single interface that solves diverse programming problems.

---

## 1. One API, Many Applications

### The Problem: Repetitive Error Propagation

When extracting multiple elements from a list, nested null checks become verbose:

```lean
def firstThirdFifthSeventh (xs : List α) : Option (α × α × α × α) :=
  match xs[0]? with
  | none => none
  | some first => match xs[2]? with
    | none => none
    | some third => match xs[4]? with
      | none => none
      | some fifth => match xs[6]? with
        | none => none
        | some seventh => some (first, third, fifth, seventh)
```

### The andThen Pattern

This repetitive error-propagation pattern can be factored into a helper function:

```lean
def andThen (opt : Option α) (next : α → Option β) : Option β :=
  match opt with
  | none => none
  | some x => next x
```

Using an infix operator improves readability:

```lean
infixl:55 " ~~> " => andThen

def firstThirdFifthSeventh (xs : List α) : Option (α × α × α × α) :=
  xs[0]? ~~> fun first =>
  xs[2]? ~~> fun third =>
  xs[4]? ~~> fun fifth =>
  xs[6]? ~~> fun seventh =>
  some (first, third, fifth, seventh)
```

### Except Type Pattern

Error messages require similar chaining logic but with richer information:

```lean
inductive Except (ε : Type) (α : Type) where
  | error : ε → Except ε α
  | ok : α → Except ε α
```

List lookups can now return informative errors:

```lean
def get (xs : List α) (i : Nat) : Except String α :=
  match xs[i]? with
  | none => Except.error s!"Index {i} not found"
  | some x => Except.ok x
```

The same `andThen` pattern applies to `Except`:

```lean
def andThen (attempt : Except e α) (next : α → Except e β) : Except e β :=
  match attempt with
  | Except.error msg => Except.error msg
  | Except.ok x => next x
```

### Key Insight

Each example -- Option, Except, logging -- follows an identical structure:
- Check/transform the intermediate result
- Propagate failure or special conditions automatically
- Continue with the next computation
- Combine final results

This consistency suggests a unified abstraction: the Monad type class.

---

## 2. The Monad Type Class

### Core Definition

```lean
class Monad (m : Type → Type) where
  pure : α → m α
  bind : m α → (α → m β) → m β
```

These correspond to "wrapping" a value and sequencing monadic computations.

### Standard Instances

#### Option Monad

```lean
instance : Monad Option where
  pure x := some x
  bind opt next := match opt with
    | none => none
    | some x => next x
```

#### Except Monad

```lean
instance : Monad (Except ε) where
  pure x := Except.ok x
  bind attempt next := match attempt with
    | Except.error e => Except.error e
    | Except.ok x => next x
```

#### State Monad

```lean
instance : Monad (State σ) where
  pure x := fun s => (s, x)
  bind first next := fun s =>
    let (s', x) := first s
    next x s'
```

#### WithLog Monad (Logging)

```lean
instance : Monad (WithLog logged) where
  pure x := {log := [], val := x}
  bind result next :=
    let {log := thisOut, val := thisRes} := result
    let {log := nextOut, val := nextRes} := next thisRes
    {log := thisOut ++ nextOut, val := nextRes}
```

### Polymorphic Functions

The polymorphic nature of Monad enables writing functions that work across multiple monad types:

```lean
def firstThirdFifthSeventh [Monad m]
    (lookup : List α → Nat → m α)
    (xs : List α) : m (α × α × α × α) :=
  lookup xs 0 >>= fun first =>
  lookup xs 2 >>= fun third =>
  lookup xs 4 >>= fun fifth =>
  lookup xs 6 >>= fun seventh =>
  pure (first, third, fifth, seventh)
```

The infix operator `>>=` represents bind.

### General Monad Operations

`mapM` demonstrates monad polymorphism -- applying a monadic function across list elements:

```lean
def mapM [Monad m] (f : α → m β) : List α → m (List β)
  | [] => pure []
  | x :: xs => f x >>= fun hd =>
      mapM f xs >>= fun tl =>
      pure (hd :: tl)
```

### The Identity Monad

The identity monad encodes no effects, allowing pure code within monadic APIs:

```lean
def Id (t : Type) : Type := t

instance : Monad Id where
  pure x := x
  bind x f := f x
```

Since `Id α` reduces to just `α`, the identity monad essentially becomes function application.

### The Monad Contract (Laws)

Every Monad instance should satisfy three laws:

1. **Left Identity:** `bind (pure v) f` equals `f v`
2. **Right Identity:** `bind v pure` equals `v`
3. **Associativity:** `bind (bind v f) g` equals `bind v (fun x => bind (f x) g)`

These laws ensure that sequencing effects behaves predictably -- `pure` contributes no effects, and the order of sequencing operations doesn't alter results.

---

## 3. Example: Arithmetic in Monads

### Expression Types

```lean
inductive Expr (op : Type) where
  | const : Int → Expr op
  | prim : op → Expr op → Expr op → Expr op

inductive Arith where
  | plus
  | minus
  | times
  | div
```

### Example Expressions

```lean
open Expr in open Arith in
def twoPlusThree : Expr Arith :=
  prim plus (const 2) (const 3)

open Expr in open Arith in
def fourteenDivided : Expr Arith :=
  prim div (const 14)
    (prim minus (const 45)
      (prim times (const 5) (const 9)))
```

### Option-Based Evaluator (Silent Failure)

```lean
def evaluateOption : Expr Arith → Option Int
  | Expr.const i => pure i
  | Expr.prim p e1 e2 =>
    evaluateOption e1 >>= fun v1 =>
    evaluateOption e2 >>= fun v2 =>
    match p with
    | Arith.plus => pure (v1 + v2)
    | Arith.minus => pure (v1 - v2)
    | Arith.times => pure (v1 * v2)
    | Arith.div =>
      if v2 == 0 then none else pure (v1 / v2)
```

### Except-Based Evaluator (Error Messages)

```lean
def evaluateExcept : Expr Arith → Except String Int
  | Expr.const i => pure i
  | Expr.prim p e1 e2 =>
    evaluateExcept e1 >>= fun v1 =>
    evaluateExcept e2 >>= fun v2 =>
    match p with
    | Arith.plus => pure (v1 + v2)
    | Arith.minus => pure (v1 - v2)
    | Arith.times => pure (v1 * v2)
    | Arith.div =>
      if v2 == 0 then
        Except.error s!"Tried to divide {v1} by zero"
      else pure (v1 / v2)
```

### Polymorphic Evaluator (Generalized)

```lean
inductive Prim (special : Type) where
  | plus
  | minus
  | times
  | other : special → Prim special

inductive CanFail where
  | div

def divOption : CanFail → Int → Int → Option Int
  | CanFail.div, x, y =>
    if y == 0 then none else pure (x / y)

def divExcept : CanFail → Int → Int → Except String Int
  | CanFail.div, x, y =>
    if y == 0 then Except.error s!"Tried to divide {x} by zero"
    else pure (x / y)

def applyPrim [Monad m]
    (applySpecial : special → Int → Int → m Int) :
    Prim special → Int → Int → m Int
  | Prim.plus, x, y => pure (x + y)
  | Prim.minus, x, y => pure (x - y)
  | Prim.times, x, y => pure (x * y)
  | Prim.other op, x, y => applySpecial op x y

def evaluateM [Monad m]
    (applySpecial : special → Int → Int → m Int) :
    Expr (Prim special) → m Int
  | Expr.const i => pure i
  | Expr.prim p e1 e2 =>
    evaluateM applySpecial e1 >>= fun v1 =>
    evaluateM applySpecial e2 >>= fun v2 =>
    applyPrim applySpecial p v1 v2
```

### No Effects (Identity Monad)

Using `Empty` as the special operator type indicates no additional operations:

```lean
def applyEmpty [Monad m]
    (op : Empty) (_ : Int) (_ : Int) : m Int :=
  nomatch op

open Expr Prim in
#eval evaluateM (m := Id) applyEmpty
  (prim plus (const 5) (const (-14)))
-- Result: -9
```

### Nondeterministic Search (Many Monad)

```lean
inductive Many (α : Type) where
  | none : Many α
  | more : α → (Unit → Many α) → Many α

def Many.one (x : α) : Many α :=
  Many.more x (fun () => Many.none)

def Many.union : Many α → Many α → Many α
  | Many.none, ys => ys
  | Many.more x xs, ys =>
    Many.more x (fun () => union (xs ()) ys)

def Many.fromList : List α → Many α
  | [] => Many.none
  | x :: xs =>
    Many.more x (fun () => fromList xs)
```

---

## 4. do-Notation for Monads

### Translation Rules

1. **Single Expression**: `do E` translates to `E`
2. **Monadic Bind**: `do let x ← E₁; stmts` translates to `E₁ >>= fun x => do stmts`
3. **Expression Statement**: `do E₁; stmts` translates to `E₁ >>= fun () => do stmts`
4. **Regular Let**: `do let x := E₁; stmts` translates to `let x := E₁; do stmts`

### Before do-notation:

```lean
def firstThirdFifthSeventh [Monad m] (lookup : List α → Nat → m α)
    (xs : List α) : m (α × α × α × α) :=
  lookup xs 0 >>= fun first =>
  lookup xs 2 >>= fun third =>
  lookup xs 4 >>= fun fifth =>
  lookup xs 6 >>= fun seventh =>
  pure (first, third, fifth, seventh)
```

### After do-notation:

```lean
def firstThirdFifthSeventh [Monad m] (lookup : List α → Nat → m α)
    (xs : List α) : m (α × α × α × α) := do
  let first ← lookup xs 0
  let third ← lookup xs 2
  let fifth ← lookup xs 4
  let seventh ← lookup xs 6
  pure (first, third, fifth, seventh)
```

### mapM with do-notation:

```lean
def mapM [Monad m] (f : α → m β) : List α → m (List β)
  | [] => pure []
  | x :: xs => do
      let hd ← f x
      let tl ← mapM f xs
      pure (hd :: tl)
```

### mapM with nested actions:

```lean
def mapM [Monad m] (f : α → m β) : List α → m (List β)
  | [] => pure []
  | x :: xs => do pure ((← f x) :: (← mapM f xs))
```

### Tree Numbering with do-notation:

```lean
def increment : State Nat Nat := do
  let n ← get
  set (n + 1)
  pure n

def number (t : BinTree α) : BinTree (Nat × α) :=
  let rec helper : BinTree α → State Nat (BinTree (Nat × α))
    | BinTree.leaf => pure BinTree.leaf
    | BinTree.branch left x right => do
        let numberedLeft ← helper left
        let n ← get
        set (n + 1)
        let numberedRight ← helper right
        pure (BinTree.branch numberedLeft (n, x) numberedRight)
  (helper t 0).snd
```

### Tree Numbering with nested actions:

```lean
def number (t : BinTree α) : BinTree (Nat × α) :=
  let rec helper : BinTree α → State Nat (BinTree (Nat × α))
    | BinTree.leaf => pure BinTree.leaf
    | BinTree.branch left x right => do
        pure (BinTree.branch (← helper left)
          ((← increment), x) (← helper right))
  (helper t 0).snd
```

---

## 5. Key Benefits of the Monad Approach

1. **Type-Level Effect Documentation:** Function signatures explicitly reveal all effects used
2. **Effect Flexibility:** Code remains unchanged while swapping between different computational strategies
3. **Separation of Concerns:** Business logic (evaluation) separates from effect implementation (failure handling)
4. **Code Reuse:** Write once with `[Monad m]`, use with Option, Except, State, IO, or any custom monad

---

## Exercises

1. Implement `BinTree.mapM` applying a monadic function to each tree node in preorder traversal:

```lean
def BinTree.mapM [Monad m] (f : α → m β) : BinTree α → m (BinTree β)
```

2. Evaluate the faulty Option Monad instance that always returns `none` -- it violates the left identity law.

3. Rewrite `evaluateM` and related functions using `do`-notation.

4. Rewrite `firstThirdFifthSeventh` using nested actions.
