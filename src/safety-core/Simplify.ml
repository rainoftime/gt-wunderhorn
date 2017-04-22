module G = Graph
module PG = ProgramGraph
module Set = Core.Std.Set.Poly
module Map = Core.Std.Map.Poly
module QID = QualifiedIdentity

module V = Var
module T = Type
module E = Expr
module I = Instr

(* If a relation never appears on the rhs of a horn clause, then it can be safely
   removed from any expression which refers to it. *)
let remove_unaffecting_relations es =
  let rhs_rels = ref Set.empty in

  let get_rhs_rels e = match E.to_horn_clause e with
    | Some (lhs, E.Relation (r, args)) ->
      rhs_rels := Set.union !rhs_rels (E.rels (E.Relation (r, args)))
    | _ -> ()
  in

  let replace e =
    let special = function
      | E.Relation (r, es) ->
        Some (if Set.mem !rhs_rels r
              then E.Relation (r, es)
              else E.Bool true)
      | _ -> None
    in
    E.map special e
  in

  List.iter get_rhs_rels es;
  List.map replace es

(** If there is a node in the graph which does not lead to an assertion, it can
    be removed safely *)
let remove_non_asserting_nodes g =
  let edge_is_assertion = function
    | PG.Assert _ -> true
    | _ -> false in

  let has_assertion =
    List.exists (fun (i, t, e) -> edge_is_assertion e) in

  let leads_to_assertion n =
    List.exists has_assertion (G.walks_from g n) in

  G.filter_conns (fun (i, t, e) ->
      edge_is_assertion e || leads_to_assertion t) g

let concatenate_consecutive_paths g =
  let concat ((ps1, e1), n, (ps2, e2)) = match (e1, e2) with
    | (PG.Body (p, as1), PG.Body (E.Bool true, as2)) ->
      Some (ps1, PG.Body (p, as1 @ as2))
    | ( PG.Body (p, as1)
      , PG.Return (ent, ex, ps, E.Bool true, as2, value)) ->
      Some (ps1, PG.Return (ent, ex, ps, p, as1 @ as2, value))
    | _ -> None
  in
  G.splice concat g

let concatenate_consecutive_exprs g =
  let concat (e1, n, e2) = match (e1, e2) with
    | (PG.EBody e1, PG.EBody e2) ->
      Some (PG.EBody (E.mk_and [e1;e2]))
    | (PG.EBody e1, PG.EReturn (e2, rhs)) ->
      Some (PG.EReturn (E.mk_and [e1;e2], rhs))
    | _ -> None
  in
  G.splice concat g

let remove_empty_paths g =
  let remove (i, t, e) = match e with
    | (_, PG.Body (_, [])) -> Some t
    | _ -> None
  in
  G.pinch remove g

let remove_empty_exprs g =
  let remove (i, t, e) =  match e with
    | PG.EBody E.Bool true -> Some t
    | _ -> None
  in
  G.pinch remove g

(* Some low level languages (including JVM Bytecode) do not represent booleans
   directly. This results in strange clauses. This transforms instructions
   sequences which conditionally assign integers to a boolean assignment. *)
let simplify_boolean_assignment is =
  let rec replace_instrs = function
    | (I.Instr (l1, I.If (c, ll1)))
      :: (I.Instr (l2, I.Assign (v1, E.Int 1)))
      :: (I.Instr (l3, I.Goto ll2))
      :: (I.Instr (l4, I.Assign (v2, E.Int 0)))
      :: (I.Instr (l5, ins))
      :: rest when ll1 = l4 &&
                   ll2 = l5 &&
                   (* from the Java Docs on variable naming:
                      the dollar sign character, by convention, is never used at all.
                      You may find some situations where auto-generated names will
                      contain the dollar sign, but your variable names should always
                      avoid using it.
                      must be compiled with '-g' though *)
                   (Var.basename v1).[0] = '$' &&
                   v1 = v2 ->
      let (m, rest) = replace_instrs (I.Instr ((l5, ins)) :: rest) in
      let v = Var.with_type v1 T.Bool in
      let m' = Map.add ~key:v1 ~data:v m in
      (m',
           (I.Instr (l1, I.If (c, l4)))
        :: (I.Instr (l2, I.Assign (v, E.Bool true)))
        :: (I.Instr (l3, I.Goto l5))
        :: (I.Instr (l4, I.Assign (v, E.Bool false)))
        :: rest)
    | (i :: is) ->
      let (m, rest) = replace_instrs is in
      (m, i :: rest)
    | [] -> (Map.empty, [])
  in

  let (m, is') = replace_instrs is in

  let lookup v = match Map.find m v with
    | None -> v
    | Some v' -> v' in


  let ex =
    let special = function
      | E.Var v -> Some (E.Var (lookup v))
      | e -> None in
    E.map special
  in

  let replace_vars = function
    | I.Assign (V.Mk (var, T.Bool), E.Int (0 | 1 as bin)) ->
      let to_bool = if bin = 1 then true else false in
      I.Assign (V.Mk (var, T.Bool), E.Bool (to_bool))
    | I.Assign (v, e)           -> I.Assign (lookup v, ex e)
    | I.Goto l                  -> I.Goto l
    | I.If (e, l)               -> I.If (ex e, l)
    | I.Return e                -> I.Return (ex e)
    | I.Invoke (p, v, es)       -> I.Invoke (p, lookup v, List.map ex es)
    | I.Dispatch (e, ps, v, es) -> I.Dispatch (ex e, ps, lookup v, List.map ex es)
    | I.Assert (e, at)          -> I.Assert (ex e, at)
  in
  List.map
    (fun (I.Instr (lbl, i)) -> I.Instr (lbl, replace_vars i)) is'

let expr_replacement replacer is =
  let ex = E.map replacer in
  let replace_vars = function
    | I.Assign (v, e)           -> I.Assign (v, ex e)
    | I.Goto l                  -> I.Goto l
    | I.If (e, l)               -> I.If (ex e, l)
    | I.Return e                -> I.Return (ex e)
    | I.Invoke (p, v, es)       -> I.Invoke (p, v, List.map ex es)
    | I.Dispatch (e, ps, v, es) -> I.Dispatch (ex e, ps, v, List.map ex es)
    | I.Assert (e, at)          -> I.Assert (ex e, at)
  in
  List.map
    (fun (I.Instr (lbl, i)) -> I.Instr (lbl, replace_vars i))
    is

let is_global_assignment = function
  | E.Var var when (LangState.is_global var) -> true
  | _ -> false


let rec gotos_reaching target min max = function
  | (I.Instr (from, I.Goto towards)) :: _
    when (Lbl.compare_lines false (=) towards target)
      && ((Lbl.compare_lines false (<) from min)
         || (Lbl.compare_lines false (>) from max)) ->
    true
  | (I.Instr (from, I.If (_, towards))) :: _
    when (Lbl.compare_lines false (=) towards target)
      && ((Lbl.compare_lines false (<) from min)
         || (Lbl.compare_lines false (>) from max)) ->
    true
  | i :: rest -> gotos_reaching target min max rest
  | [] -> false


(* changes (my_bool = true) -> (my_bool) *)
let simplify_boolean_checks is =
  let replacer = function
    | E.Apply (E.Biop (E.Eq), [E.Var (V.Mk (_, T.Bool)) as var; E.Int (0 | 1 as bin)]) ->
      if bin = 1
      then Some (var)
      else Some (E.Apply (E.Unop (E.Not), [var]))
    | _ -> None
  in
  expr_replacement replacer is

let inline_assignments is =

  let rec slice_linear min max = function
    (* TODO is checking for jumps going _out_ of the region necessary? *)
    (* | ((I.Instr (_, I.Goto towards)) as curr_instr) :: rest *)
    (*   when (Lbl.compare_lines false (<) towards min) *)
    (*     || (Lbl.compare_lines false (>) towards max) -> *)
    (*   ([], curr_instr :: rest) *)
    (* | ((I.Instr (_, I.If (_, towards))) as curr_instr) :: rest *)
    (*   when (Lbl.compare_lines false (<) towards min) *)
    (*     || (Lbl.compare_lines false (>) towards max) -> *)
    (*   ([], curr_instr :: rest) *)
    | ((I.Instr (lbl, _)) as curr_instr) :: rest ->
      if gotos_reaching lbl min max is
      then ([], curr_instr :: rest)
      else
        let (sliced, leftover) = slice_linear min max rest in
        (curr_instr :: sliced, leftover)
    | [] -> ([], [])
  in

  let into_linear_region region = match region with
    | (I.Instr (lbl, _)) :: rest ->
      let min = Lbl.map_ln ((+) (-1)) lbl in
      let max = Lbl.map_ln ((+) (List.length region)) lbl in
      slice_linear min max region
    | [] -> ([], [])
  in

  let rec find_region var dep_vars = function
    | ((I.Instr (lbl, I.Assign (assigned, _))) as curr_instr) :: rest
      when (Set.mem dep_vars assigned) -> ([], curr_instr :: rest)
    | i :: rest ->
      let (region, leftover) = find_region var dep_vars rest in
      (i :: region, leftover)
    | [] -> ([], [])
  in
  let process_region var dep_vars assignment intrs =
    let (region, leftover) = find_region var dep_vars intrs in
    let (linear_region, slice_leftover) = into_linear_region region in
    let rec replacer = function
      | E.Var v when v = var -> Some(assignment)
      | _ -> None
    in
    (expr_replacement replacer linear_region, List.flatten [slice_leftover; leftover])
  in
  let rec find_regions = function
    | (I.Instr (lbl, I.Assign (var, assign))) :: rest
      when (V.is_local var lbl)
        && (V.is_scalar var)
        && (not (is_global_assignment assign)) ->
      let dep_vars = E.vars assign in
      let curr_instr = I.Instr (lbl, I.Assign (var, assign)) in
      if Set.mem dep_vars var
      then curr_instr :: find_regions rest
      else
        let (inlined, leftover) = process_region var (Set.add dep_vars var) assign rest in
        curr_instr :: (find_regions (List.flatten [inlined; leftover]))
    | (i :: rest) -> i :: (find_regions rest)
    | [] -> []
  in
  find_regions is

let remove_unused_vars is =
  let check_used var = function
    | E.Var v when v = var -> Some(true)
    | _ -> None
  in
  let is_used_in_expr var expr = E.fold (check_used var) (||) false expr in

  let rec slice_linear min max = function
    | ((I.Instr (_, I.Goto towards)) as curr_instr) :: rest
      when (Lbl.compare_lines false (<) towards min)
        || (Lbl.compare_lines false (>) towards max) ->
      ([], curr_instr :: rest)
    | ((I.Instr (_, I.If (_, towards))) as curr_instr) :: rest
      when (Lbl.compare_lines false (<) towards min)
        || (Lbl.compare_lines false (>) towards max) ->
      ([], curr_instr :: rest)
    | ((I.Instr (lbl, _)) as curr_instr) :: rest ->
      if gotos_reaching lbl min max is
      then ([], curr_instr :: rest)
      else
        let (sliced, leftover) = slice_linear min max rest in
        (curr_instr :: sliced, leftover)
    | [] -> ([], [])
  in

  let into_linear_region region = match region with
    | (I.Instr (lbl, _)) :: rest ->
      let min = Lbl.map_ln ((+) (-1)) lbl in
      let max = Lbl.map_ln ((+) (List.length region)) lbl in
      slice_linear min max region
    | [] -> ([], [])
  in

  let rec is_used var acc = function
    | (I.Instr (_, (I.Assign (v, e)))) :: _ when is_used_in_expr var e -> true
    | (I.Instr (_, (I.If (e, j))))     :: _ when is_used_in_expr var e -> true
    | (I.Instr (_, (I.Return e)))      :: _ when is_used_in_expr var e -> true
    | (I.Instr (_, (I.Assert (e, _)))) :: _ when is_used_in_expr var e -> true
    | (I.Instr (_, (I.Invoke (_, _, es)))) :: _
      when List.exists (is_used_in_expr var) es       -> true
    | (I.Instr (_, (I.Dispatch (e, _, _, es)))) :: _
      when (is_used_in_expr var e)
        || (List.exists (is_used_in_expr var) es)     -> true
    | (I.Instr (lbl, (I.Assign (v, _)))) :: _ when var = v ->
      let (_, leftover) = into_linear_region (List.rev acc) in
      leftover != []
    | i :: rest -> is_used var (i :: acc) rest
    | [] ->
      let (used, leftover) = into_linear_region (List.rev acc) in
      leftover != []
  in

  let rec find_unused = function
    | (I.Instr (lbl, I.Assign (var, assign)) as curr_instr)
      :: (I.Instr (next, _) as next_instr)
      :: rest
      when (V.is_local var lbl)
        && (V.is_scalar var)
        && (not (is_global_assignment assign)) ->
      if is_used var [curr_instr] (next_instr :: rest)
      then curr_instr :: (find_unused (next_instr :: rest))
      else (I.Instr (lbl, I.Goto next)) :: (find_unused (next_instr :: rest))
    | (i :: rest) -> i :: (find_unused rest)
    | [] -> []
  in

  find_unused is


(* If a relation only appears on the right hand side of a Horn Clause once, then
   other references to that relation can be inlined. *)
let inline_relations es =
  let loop es =
    let appearances (once, more) e = match E.to_horn_clause e with
      | Some (_, E.Relation (r, _)) ->
        if List.mem r more
        then (once, more)
        else if List.mem r once
        then (List.filter ((<>) r) once, r :: more)
        else (r :: once, more)
      | _ -> (once, more) in
    let appear_once = fst (List.fold_left appearances ([], []) es) in

    let collect_bodies m e = match E.to_horn_clause e with
      | Some (lhs, E.Relation (r, args)) ->
        if List.mem r appear_once
        then Map.add m r (lhs, args)
        else m
      | _ -> m in
    let bodies = ref (List.fold_left collect_bodies Map.empty es) in

    let substitute es =
      let alias =
        let special = function
          | E.Var v -> Some (E.Var (Var.qualify "v" v))
          | _ -> None in
        E.map special in

      bodies := Map.map !bodies (fun (lhs, args) -> (alias lhs, List.map alias args));

      let subst e =
        let special = function
          | E.Relation (r, args) ->
            Some (match Map.find !bodies r with
                | Some (lhs, args') ->
                  E.mk_and (lhs :: List.map2 E.mk_eq args args')
                | _ -> E.Relation (r, args))
          | _ -> None
        in

        let special e = match E.to_horn_clause e with
          | Some (lhs, rhs) ->
            Some (E.from_horn_clause (E.map special lhs) rhs)
          | _ -> None in
        E.map special e
      in
      List.map subst es
    in

    let is_removable e = match E.to_horn_clause e with
      | Some (lhs, E.Relation (r, args)) -> List.mem r appear_once
      | _ -> false in

    let targets = List.filter (fun e -> not (is_removable e)) es in

    Algorithm.converge (=) substitute targets
  in
  (* loop es *)
  Algorithm.converge (=) loop es
