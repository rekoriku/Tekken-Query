/-
  TekkenQuery.Csv.Types
  Core types for the verified CSV parser.
-/

namespace TekkenQuery.Csv

/-- Which delimiter was detected. -/
inductive Delimiter where
  | semicolon
  | comma
  deriving Repr, BEq, DecidableEq

/-- Convert a Delimiter to its character. -/
def Delimiter.toChar : Delimiter → Char
  | .semicolon => ';'
  | .comma => ','

/-- Possible parse errors. -/
inductive ParseError where
  | emptyInput
  | noHeader
  | singleColumn
  deriving Repr, BEq

end TekkenQuery.Csv
