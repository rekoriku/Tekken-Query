# Lean 4: Structures

Source: https://lean-lang.org/functional_programming_in_lean/Getting-to-Know-Lean/Structures/

## Overview

Structures in Lean group related data into a single type, similar to structs in C/Rust or records in C#. They allow developers to represent domain concepts by bundling simpler components together with meaningful names.

## Basic Structure Definition

A structure with two floating-point fields can be declared using the `structure` keyword:

```lean
structure Point where
  x : Float
  y : Float
```

Creating instances uses curly-brace syntax:

```lean
def origin : Point := { x := 0.0, y := 0.0 }
```

Field access employs dot notation:

```lean
#eval origin.x  -- 0.000000
#eval origin.y  -- 0.000000
```

## Functions Operating on Structures

Functions can operate on structure fields. Point addition combines corresponding coordinates:

```lean
def addPoints (p1 : Point) (p2 : Point) : Point :=
  { x := p1.x + p2.x, y := p1.y + p2.y }
```

Distance calculation between points uses the Pythagorean theorem:

```lean
def distance (p1 : Point) (p2 : Point) : Float :=
  Float.sqrt (((p2.x - p1.x) ^ 2.0) + ((p2.y - p1.y) ^ 2.0))
```

The distance between (1, 2) and (5, -1) equals 5.

## Multiple Structures with Shared Field Names

Different structures can use identical field names. A three-dimensional point extends the concept:

```lean
structure Point3D where
  x : Float
  y : Float
  z : Float

def origin3D : Point3D := { x := 0.0, y := 0.0, z := 0.0 }
```

Type context must be clear when using curly-brace syntax. Without explicit type information, Lean cannot determine which structure to instantiate. Type annotations resolve this ambiguity:

```lean
#check ({ x := 0.0, y := 0.0 } : Point)
#check { x := 0.0, y := 0.0 : Point}
```

## Structure Updates

Functional programming in Lean creates new values rather than modifying existing ones. The `with` keyword enables updating specific fields while preserving others:

```lean
def zeroX (p : Point) : Point := { p with x := 0 }
```

This syntax avoids manual field-by-field reconstruction, improving maintainability and reducing copy-paste errors. Given:

```lean
def fourAndThree : Point := { x := 4.3, y := 3.4 }
```

Original values remain unchanged after updates:

```lean
#eval fourAndThree              -- { x := 4.300000, y := 3.400000 }
#eval zeroX fourAndThree        -- { x := 0.000000, y := 3.400000 }
#eval fourAndThree              -- { x := 4.300000, y := 3.400000 }
```

## Behind the Scenes: Constructors and Accessors

Each structure has a default constructor named `StructureName.mk`. Direct constructor application works but is discouraged:

```lean
#check Point.mk 1.5 2.8
-- Returns: { x := 1.5, y := 2.8 } : Point
```

Constructors function as regular functions accepting field values in order:

```lean
#check (Point.mk)
-- Point.mk : Float → Float → Point
```

Custom constructor names override the default by using `::` syntax:

```lean
structure Point where
  point :: x : Float
           y : Float
```

Accessor functions are automatically generated for each field:

```lean
#check (Point.x)  -- Point.x : Point → Float
#check (Point.y)  -- Point.y : Point → Float
```

Dot notation `p.x` translates internally to `Point.x p`.

## Extended Dot Notation

Accessor notation works beyond structure fields for any function taking multiple arguments. Functions in a type's namespace become accessible via dot notation:

```lean
def Point.modifyBoth (f : Float → Float) (p : Point) : Point :=
  { x := f p.x, y := f p.y }

#eval fourAndThree.modifyBoth Float.floor
-- { x := 4.000000, y := 3.000000 }
```

String operations demonstrate namespace functions without explicit structure fields:

```lean
#eval "one string".append " and another"
-- "one string and another"
```

The dot-notation target becomes the first argument matching the required type, not necessarily the first positional argument.

## Exercises

1. Define a `RectangularPrism` structure containing height, width, and depth as `Float` values.

2. Write a `volume : RectangularPrism → Float` function computing rectangular prism volume.

3. Create a `Segment` structure representing line segments by endpoints with at most two fields, and define `length : Segment → Float`.

4. Identify all names introduced by `RectangularPrism` declaration.

5. List names and their types introduced by these declarations:

```lean
structure Hamster where
  name : String
  fluffy : Bool

structure Book where
  makeBook :: title : String
             author : String
             price : Float
```
