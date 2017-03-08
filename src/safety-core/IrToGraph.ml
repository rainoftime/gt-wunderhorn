module G = Graph
module PG = ProgramGraph
module LS = LangState
module QID = QualifiedIdentity
module Set = Core.Std.Set.Poly

module T = Type
module E = Expr
module I = Instr

(** To inspect the type of an object, the global class array is accessed
    and the contents under the object are compared to the expected value. *)
let check_type obj t =
  E.mk_eq (E.Select (E.Var LS.class_array, obj)) t

let rec instr proc (I.Instr (this, i)) =
  let next = Lbl.next this in

  let unconditional here there assigns =
    G.singleton (here, there, PG.Body (E.Bool true, assigns)) in

  (** Many instruction types simply proceed to the next program location with
      some instructions on the edge. *)
  let linear instrs = unconditional this next instrs in

  (** A call has a few important parts:
        1. An edge is generated which contains the assignments of the formal
           parameters of the target procedure to the call arguments.
        2. An edge is generated which assigns the callers assignment variable
           to the return variable of the callee. It also relates the return
           site to the call site. (In other words, it distinguishes between
           the returns of different calls to the same function.)
        3. An edge is generated which links the call site to the return site.
           This edge allows variables (which are not live in the target
           procedure) to be passed.
        4. A separate graph is evaluated for the callee. *)
  let call pred proc v args =
    let assignments = List.map2 I.mk_assign proc.I.params args
                      |> List.sort (fun (v1, e1) (v2, e2) -> compare v1 v2) in
    let entr = I.entrance proc in
    let exit = I.exit     proc in

    G.union
      (G.of_conns
         [ this, entr, PG.ScopeIn  (proc.I.id, pred, assignments)
         ; exit, next, PG.ScopeOut proc.I.id
         ; this, next, PG.CallLink (exit, entr, exit, assignments, v)
         ])
      (translate proc)
  in

  match i with
  | I.Assign (v, e)          -> linear [I.mk_assign v e]
  | I.Invoke (p, v, args)    -> call (E.Bool true) p v args
  | I.Return e               ->
    let exit = Lbl.At (proc.I.id, Lbl.Exit) in
    G.singleton (this, exit,
                 (PG.Return
                    (I.entrance proc
                    , I.exit proc
                    , proc.I.params
                    , E.Bool true
                    , []
                    , e)))
  | I.Goto d                 -> unconditional this d []

  (** An if statement generates a graph with two edges diverging from one
      starting node. One edge proceeds to the target destination if the
      condition is true. The other proceeds to the next location if the
      condition is false *)
  | I.If (e, dest) ->
    G.of_conns
      [ (this, dest, PG.Body (e, []))
      ; (this, next, PG.Body (E.mk_not e, []))
      ]

  (** A dynamic dispatch generates a graph with many edges diverging from
      one node. Each divergent edge is predicated by a check to see which
      version of the dispatch should be used. *)
  | I.Dispatch (obj, ps, v, args) ->
    let call_meth (t, proc) =
      call (check_type obj t) proc v (obj :: args) in
    G.unions_map call_meth ps

  | I.Assert (e, at) ->
    G.union
      (G.singleton (this, Lbl.Nowhere, PG.Assert (e, at)))
      (unconditional this next [])

and subgraph_set = ref (Set.empty)

and translate proc =
  (** A subgraph should only be generated for a function if it has not been done
      so already. This allows for function recursion. *)
  if Set.mem !subgraph_set proc.I.id
  then G.empty
  else
    let i = Lbl.At (proc.I.id, Lbl.Entrance) in
    let t = Lbl.At (proc.I.id, Lbl.Line 0) in

    let e =
      if QID.most_specific proc.I.id = "<init>"
      then
        let this = Var.Mk (QID.specify proc.I.id "this", T.Int) in
        [ I.mk_assign LS.id (E.mk_iadd (E.Var LS.id) (E.Int 1))
        ; I.mk_assign this (E.Var LS.id)
        ; LS.update_field LS.class_array (E.Var this) proc.I.class_t
        ]
      else if proc.I.id = QID.of_list ["Test"; "main"]
      then [LS.id, E.Int 0]
      else [] in

    ( subgraph_set := Set.add !subgraph_set proc.I.id
      ;
      List.map (instr proc) (Lazy.force proc.I.content)
      |> G.unions
      |> G.add (i, t, PG.Body (E.Bool true, e))
    )