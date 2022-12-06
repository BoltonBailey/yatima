import LSpec
import Lurk.Evaluation.Eval
import Lurk.Evaluation.FromAST
import Yatima.Datatypes.Cid
import Yatima.Compiler.Compiler
import Yatima.Compiler.Printing
import Yatima.Converter.Converter
import Yatima.Typechecker.Typechecker
import Yatima.Transpiler.Transpiler
import Yatima.Ipld.FromIpld

open LSpec Yatima Compiler

def compileAndExtractTests (fixture : String)
  (extractors : List (CompileState → TestSeq) := []) (setPaths : Bool := true) :
    IO TestSeq := do
  if setPaths then setLibsPaths
  return withExceptOk s!"Compiles '{fixture}'" (← compile fixture)
    fun stt => (extractors.map fun extr => extr stt).foldl (init := .done)
      (· ++ ·)

def compileAndExtractTests' (fixtures : Array String)
  (extractors : List (CompileState → TestSeq) := []) (setPaths : Bool := true) :
    IO TestSeq := do
  if setPaths then setLibsPaths
  let mut ret := .done
  let mut compStt := default
  for fixture in fixtures do
    match (← compile (stt := compStt) fixture) with
    | .ok stt =>
      compStt := stt
      ret := test s!"Compiles '{fixture}'" true $ (extractors.map fun extr => extr stt).foldl (init := ret)
          (· ++ ·)
    | .error e => ret := test s!"Compiles '{fixture}'" (ExpectationFailure "ok _" s!"error {e}")
  return ret

section AnonCidGroups

/-
This section defines an extractor that consumes a list of groups of names and
creates tests that assert that:
1. Each pair of constants in the same group has the same anon CID
2. Each pair of constants in different groups has different anon CIDs
-/

def extractCidGroups (groups : List (List Lean.Name)) (stt : CompileState) :
    Except String (Array (Array (Lean.Name × IR.ConstCid .anon))) := Id.run do
  let mut notFound : Array Lean.Name := #[]
  let mut cidGroups : Array (Array (Lean.Name × IR.ConstCid .anon)) := #[]
  for group in groups do
    let mut cidGroup : Array (Lean.Name × IR.ConstCid .anon) := #[]
    for name in group do
      match stt.cache.find? name with
      | none          => notFound := notFound.push name
      | some (cid, _) => cidGroup := cidGroup.push (name, cid.anon)
    cidGroups := cidGroups.push cidGroup
  if notFound.isEmpty then
    return .ok cidGroups
  else
    return .error s!"Not found: {", ".intercalate (notFound.data.map toString)}"

def extractAnonCidGroupsTests (groups : List (List Lean.Name))
    (stt : CompileState) : TestSeq :=
  withExceptOk "All constants can be found" (extractCidGroups groups stt)
    fun anonCidGroups =>
      let cidEqTests := anonCidGroups.foldl (init := .done) fun tSeq cidGroup =>
        cidGroup.data.pairwise.foldl (init := tSeq) fun tSeq (x, y) =>
          tSeq ++ test s!"{x.1}ₐₙₒₙ = {y.1}ₐₙₒₙ" (x.2 == y.2)
      anonCidGroups.data.pairwise.foldl (init := cidEqTests) fun tSeq (g, g') =>
        (g.data.cartesian g'.data).foldl (init := tSeq) fun tSeq (x, y) =>
          tSeq ++ test s!"{x.1}ₐₙₒₙ ≠ {y.1}ₐₙₒₙ" (x.2 != y.2)

end AnonCidGroups

section Converting

open Converter

/-
This section defines an extractor that validates that the Ipld conversion
roundtrips for every constant in the `CompileState.store`.
-/

@[specialize]
def find? [BEq α] (as : List α) (f : α → Bool) : Option (Nat × α) := Id.run do
  for x in as.enum do
    if f x.2 then return some x
  return none

abbrev NatNatMap := Std.RBMap Nat Nat compare

open TC

instance : Ord Const where
  compare x y := compare x.name y.name

def pairConstants (x y : Array Const) :
    Except String ((Array (Const × Const)) × NatNatMap) := Id.run do
  let mut pairs : Array (Const × Const) := #[]
  let mut map : NatNatMap := default
  let mut notFound : Array Name := #[]
  for (i, c) in x.data.enum do
    match find? y.data fun c' => c.name == c'.name with
    | some (i', c') => pairs := pairs.push (c, c'); map := map.insert i i'
    | none          => notFound := notFound.push c.name
  if notFound.isEmpty then
    return .ok (pairs, map)
  else
    return .error s!"Not found: {", ".intercalate (notFound.data.map toString)}"

def reindexExpr (map : NatNatMap) : Expr → Expr
  | e@(.var ..)
  | e@(.sort _)
  | e@(.lit ..) => e
  | .const n i ls => .const n (map.find! i) ls
  | .app e₁ e₂ => .app (reindexExpr map e₁) (reindexExpr map e₂)
  | .lam n bi e₁ e₂ => .lam n bi (reindexExpr map e₁) (reindexExpr map e₂)
  | .pi n bi e₁ e₂ => .pi n bi (reindexExpr map e₁) (reindexExpr map e₂)
  | .letE n e₁ e₂ e₃ =>
    .letE n (reindexExpr map e₁) (reindexExpr map e₂) (reindexExpr map e₃)
  | .proj n e => .proj n (reindexExpr map e)

def reindexCtor (map : NatNatMap) (ctor : Constructor) : Constructor :=
  { ctor with type := reindexExpr map ctor.type, rhs := reindexExpr map ctor.rhs, all := ctor.all.map map.find!}

def reindexConst (map : NatNatMap) : Const → Const
  | .axiom x => .axiom { x with type := reindexExpr map x.type }
  | .theorem x => .theorem { x with
    type := reindexExpr map x.type, value := reindexExpr map x.value }
  | .inductive x => .inductive { x with
    type := reindexExpr map x.type,
    struct := x.struct.map (reindexCtor map) }
  | .opaque x => .opaque { x with
    type := reindexExpr map x.type, value := reindexExpr map x.value }
  | .definition x => .definition { x with
    type := reindexExpr map x.type,
    value := reindexExpr map x.value,
    all := x.all.map map.find! }
  | .constructor x => .constructor $ reindexCtor map x
  | .extRecursor x =>
    let rules := x.rules.map fun r => { r with
      rhs := reindexExpr map r.rhs,
      ctor := reindexCtor map r.ctor }
    .extRecursor { x with
      type := reindexExpr map x.type, rules := rules, ind := map.find! x.ind}
  | .intRecursor x => .intRecursor { x with type := reindexExpr map x.type, ind := map.find! x.ind }
  | .quotient x => .quotient { x with type := reindexExpr map x.type }

def extractConverterTests (stt : CompileState) : TestSeq :=
  withExceptOk "`extractPureStore` succeeds"
    (extractPureStore stt.irStore) fun pStore =>
      withExceptOk "Pairing succeeds" (pairConstants stt.tcStore.consts pStore.consts) $
        fun (pairs, map) => pairs.foldl (init := .done) fun tSeq (c₁, c₂) =>
          tSeq ++ test s!"{c₁.name} ({c₁.ctorName}) roundtrips" (reindexConst map c₁ == c₂)

end Converting

section Typechecking

open Typechecker

/-
Here we define the following extractors:

* `extractPositiveTypecheckTests` asserts that our typechecker doesn't have
false negatives by requiring that everything that typechecks in Lean 4 should
also be accepted by our implementation

* `extractNegativeTypecheckTests` filters constants with type/value pairs
(theorems, opaques and definitions), skipping constants with repeated types,
and scrambles type/value pairs with a certain number of List rotations. For
example, if we have the pairs `(t₁, v₁)`, `(t₂, v₂)` and `(t₃, v₃)`, the first
rotation of types gives us `(t₂, v₁)`, `(t₃, v₂)` and `(t₁, v₃)`, producing
pairs that shouldn't typecheck. Similarly, the first rotation of values gives us
`(t₁, v₂)`, `(t₂, v₃)` and `(t₃, v₁)`, which shouldn't typecheck either.
Rotating types and values are different operations because constants have more
attributes than just types and values (e.g. universe levels). Note that, with
`n` pairs, we can't allow more than `n - 1` rotations because that would take us
back to the original pairs.
-/

def typecheckConstByNameM (name : Name) : TypecheckM Unit := do
  ((← read).store.consts.toList.enum.filter fun (_, const) => const.name == name).forM
    fun (i, const) => checkConst const i

def typecheckConstByName (store : TC.Store) (name : Name) : Except String Unit :=
  match TypecheckM.run (.init store) (.init store) (typecheckConstByNameM name) with
  | .ok u => .ok u
  | .error err => throw $ toString err

inductive FoundConstFailure (constName : String) : Prop

instance : Testable (FoundConstFailure constName) :=
  .isFailure $ .some s!"Could not find constant {constName}"

def extractPositiveTypecheckTests (stt : CompileState) : TestSeq :=
  stt.tcStore.consts.foldl (init := .done) fun tSeq const =>
    if true then
    --if const.name == `Prod.noConfusion then
      tSeq ++ withExceptOk s!"{const.name} ({const.ctorName}) typechecks"
        (typecheckConstByName stt.tcStore const.name) fun _ => .done
    else
      tSeq

def typecheckConst (store : TC.Store) (const : TC.Const) (idx : Nat) : Except String Unit :=
  match TypecheckM.run (.init store) (.init store) (checkConst const idx) with
  | .ok u => .ok u
  | .error err => throw $ toString err

def extractNegativeTypecheckTests (maxRounds : Nat) (stt : CompileState) : TestSeq :=
  let store := stt.tcStore
  let (testConsts, types, values, indices, _) : (List TC.Const) ×
      (List TC.Expr) × (List TC.Expr) × (List Nat) × Std.RBSet TC.Expr compare :=
    store.consts.toList.enum.foldr (init := default)
      fun (idx, c) x@(consts, types, values, indices, seenTypes) => match c with
        | c@(.theorem    ⟨_, _, type, value⟩)
        | c@(.opaque     ⟨_, _, type, value, _⟩)
        | c@(.definition ⟨_, _, type, value, _, _⟩) =>
          if !seenTypes.contains type then
            (c::consts, type::types, value::values, idx::indices, seenTypes.insert type)
          else x
        | _ => x

  -- we can't allow the cycling to roundtrip
  let nRounds := min maxRounds (testConsts.length - 1)

  -- rotating types
  let tSeq := List.range nRounds |>.foldl (init := .done) fun tSeq iRound =>
    let testPairs : List (TC.Const × Nat) :=
      (testConsts.zip $ (types.rotate iRound.succ).zip indices).map fun (c, t, i) =>
        match c with
        | .theorem    x => (.theorem    { x with type := t }, i)
        | .opaque     x => (.opaque     { x with type := t }, i)
        | .definition x => (.definition { x with type := t }, i)
        | _ => unreachable!
    testPairs.foldl (init := tSeq) fun tSeq (c, i) =>
      tSeq ++ withExceptError s!"{c.name} ({c.ctorName}) doesn't typecheck"
        (typecheckConst store c i) fun _ => .done

  -- rotating values
  let tSeq := List.range nRounds |>.foldl (init := tSeq) fun tSeq iRound =>
    let testPairs : List (TC.Const × Nat) :=
      (testConsts.zip $ (values.rotate iRound.succ).zip indices).map fun (c, v, i) =>
        match c with
        | .theorem    x => (.theorem    { x with value := v }, i)
        | .opaque     x => (.opaque     { x with value := v }, i)
        | .definition x => (.definition { x with value := v }, i)
        | _ => unreachable!
    testPairs.foldl (init := tSeq) fun tSeq (c, i) =>
      tSeq ++ withExceptError s!"{c.name} ({c.ctorName}) doesn't typecheck"
        (typecheckConst store c i) fun _ => .done

  tSeq

end Typechecking

section Transpilation

open Transpiler Lurk Evaluation

instance [BEq α] [BEq β] : BEq (Except α β) where beq
  | .ok x, .ok y => x == y
  | .error x, .error y => x == y
  | _, _ => false

def extractTranspilationTests (expect : List (String × Value))
    (stt : CompileState) : TestSeq :=
  expect.foldl (init := .done) fun tSeq (root, expected) =>
    withExceptOk s!"Transpilation of {root} succeeds" (transpile stt.irStore root) fun ast =>
      withExceptOk s!"Conversion of {root} to expression succeeds" ast.toExpr fun expr =>
        withExceptOk s!"Evaluation of {root} succeeds" expr.eval fun val =>
          tSeq ++ test s!"Evaluation of {root}, resulting in {val}, yields {expected}"
            (val == expected)

end Transpilation

section Ipld

def extractIpldTests (stt : CompileState) : TestSeq :=
  let store := stt.irStore
  let ipld := Ipld.storeToIpld stt.ipldStore
  withOptionSome "Ipld deserialization succeeds" (Ipld.storeFromIpld ipld)
    fun store' => test "IPLD SerDe roundtrips" (store == store')

end Ipld
