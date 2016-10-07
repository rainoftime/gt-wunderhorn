type label = int

type sort =
  | Array of sort
  | Int
  | Bool

type variable = Variable of string * sort

type 'a procedure =
  { id       : string
  ; params   : variable list
  ; ret_sort : sort
  ; content  : 'a
  }

let map (f : 'a -> 'b) proc =
  { id       = proc.id
  ; params   = proc.params
  ; ret_sort = proc.ret_sort
  ; content  = f (proc.content)
  }

let ret_var p = Variable (p.id ^ "_ret", p.ret_sort)
let entry_label p = p.id ^ "_0"
let exit_label  p = p.id ^ "_exit"

type expression =
  | Relation  of string * variable list
  | Query     of expression
  | Var       of variable
  | ArrStore  of expression * expression * expression
  | ArrSelect of expression * expression
  | Add       of expression * expression
  | Eq        of expression * expression
  | Ge        of expression * expression
  | Gt        of expression * expression
  | Le        of expression * expression
  | Lt        of expression * expression
  | Implies   of expression * expression
  | And       of expression list
  | Not       of expression
  | Int_lit   of int
  | True
  | False

type linear_instruction =
  | Assign  of variable * expression
  | Call    of expression
  | Assert  of expression

type non_linear_instruction =
  | If      of expression * label
  | Goto    of label
  | Invoke  of variable * ((instruction list) procedure) * expression list
  | Return  of expression
and instruction =
  | Linear     of linear_instruction
  | Non_linear of non_linear_instruction

module Var_set = Set_ext.Make(
  struct type t = variable;; let compare = compare;; end)

module Rel_set = Set_ext.Make(
  struct
    type t = string * variable list
    let compare (lbl1, _) (lbl2, _) = compare lbl1 lbl2
  end)

let rec expr_sort = function
  | ArrStore _ -> Int (* TODO *)
  | ArrSelect (arr, _) -> (match expr_sort arr with
      | Array s -> s
      | _       -> assert false (* array select from non-array *))
  | Relation _            -> Bool
  | Query _               -> Bool
  | Var (Variable (_, s)) -> s
  | Add _                 -> Int
  | Eq _                  -> Bool
  | Ge _                  -> Bool
  | Gt _                  -> Bool
  | Le _                  -> Bool
  | Lt _                  -> Bool
  | Implies _             -> Bool
  | And _                 -> Bool
  | Not _                 -> Bool
  | Int_lit _             -> Int
  | True                  -> Bool
  | False                 -> Bool

let expr_vars =
  let rec ex = function
    | Relation (_, vs)      -> Var_set.unions_map Var_set.singleton vs
    | Query e               -> ex e
    | Var v                 -> Var_set.singleton v
    | ArrStore (e1, e2, e3) -> Var_set.unions [ex e1; ex e2; ex e3]
    | ArrSelect (e1, e2)    -> Var_set.union (ex e1) (ex e2)
    | Add (e1, e2)          -> Var_set.union (ex e1) (ex e2)
    | Eq (e1, e2)           -> Var_set.union (ex e1) (ex e2)
    | Ge (e1, e2)           -> Var_set.union (ex e1) (ex e2)
    | Gt (e1, e2)           -> Var_set.union (ex e1) (ex e2)
    | Le (e1, e2)           -> Var_set.union (ex e1) (ex e2)
    | Lt (e1, e2)           -> Var_set.union (ex e1) (ex e2)
    | Implies (e1, e2)      -> Var_set.union (ex e1) (ex e2)
    | And es                -> Var_set.unions_map ex es
    | Not e                 -> ex e
    | Int_lit _             -> Var_set.empty
    | True                  -> Var_set.empty
    | False                 -> Var_set.empty
  in ex

let expr_rels =
  let rec ex = function
    | Relation (l, vs)     -> Rel_set.singleton (l, vs)
    | Query v              -> Rel_set.empty
    | Var v                -> Rel_set.empty
    | ArrStore (v, e1, e2) -> Rel_set.union (ex e1) (ex e2)
    | ArrSelect (e1, e2)   -> Rel_set.union (ex e1) (ex e2)
    | Add (e1, e2)         -> Rel_set.union (ex e1) (ex e2)
    | Eq (e1, e2)          -> Rel_set.union (ex e1) (ex e2)
    | Ge (e1, e2)          -> Rel_set.union (ex e1) (ex e2)
    | Gt (e1, e2)          -> Rel_set.union (ex e1) (ex e2)
    | Le (e1, e2)          -> Rel_set.union (ex e1) (ex e2)
    | Lt (e1, e2)          -> Rel_set.union (ex e1) (ex e2)
    | Implies (e1, e2)     -> Rel_set.union (ex e1) (ex e2)
    | And es               -> Rel_set.unions_map ex es
    | Not e                -> ex e
    | Int_lit _            -> Rel_set.empty
    | True                 -> Rel_set.empty
    | False                -> Rel_set.empty
  in ex

(** Which variables are used by a given instruction? *)
let instruction_useds = function
  | Assign (v, e)     -> expr_vars e
  | Call e            -> expr_vars e
  | Assert e          -> expr_vars e

(** Which variables are mutated by a given instruction? *)
let instruction_mutables = function
  | Assign (v, _)    -> Var_set.singleton v
  | _                -> Var_set.empty

let instruction_variables i =
  Var_set.union (instruction_useds i) (instruction_mutables i)

let mk_not = function
  | Not e -> e
  | e     -> Not e

let mk_and = function
  | [e] -> e
  | es  -> And es

let rec num_queries es =
  let rec count = function
    | Query _          -> 1
    | Eq (e1, e2)      -> count e1 + count e2
    | Implies (e1, e2) -> count e1 + count e2
    | And es           -> num_queries es
    | Not e            -> count e
    | _                -> 0 in
  List.map count es |> List.fold_left (+) 0
