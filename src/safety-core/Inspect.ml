module JP = Sawja_pack.JProgram
module JB = Javalib_pack.JBasics

let gen_ir classpath class_name =
  let cn  = JB.make_cn class_name in
  let cms = JB.make_cms cn JP.main_signature in
  let proc_id = ref (0) in
  let parse = Parse.parse proc_id classpath cn in

  (* Create an IR procedure representing the entire program starting
     from the entrypoint. *)
  JBirToIr.mk_proc parse cms

let expr_graph ir =
  ir
  (* The IR procedure can be converted into a graph which shows the control
     flow of the program. The edges of the graph are lists of instructions and
     the nodes are program locations.*)
  |> IrToGraph.translate

  (* Perform some graph simplifications to reduce the number of edges. *)
  |> Simplify.concatenate_consecutive_paths
  |> Simplify.remove_empty_paths
  |> Simplify.remove_non_asserting_nodes

  (* Annotate each program node with the variables relevant across that node's
     program location. *)
  |> VariableAnalysis.annotate_nodes

  (* Transform the graph by:
    1) Changing each edge by converting a list of instructions into a single
        conjunction.
    2) Aliasing all appropriate variables in the nodes. *)
  |> PathToExpr.translate

  (* Remove any trivial edges (those which are simply `EBool true`). *)
  |> Simplify.remove_empty_exprs
  |> Simplify.concatenate_consecutive_exprs

let inspect ir =
  expr_graph ir

  (* Transform the edges from conjunctions to horn clauses by bringing the
     pre and post conditions in from the nodes. *)
  |> ExprsToClauses.translate

  |> Simplify.remove_unaffecting_relations

  (* |> Simplify.inline_relations *)

  (* Simplify certain clauses by substituting simple equality statements. *)
  |> List.map Expr.optimize
