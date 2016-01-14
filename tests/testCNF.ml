
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** Tests for CNF *)

open Libzipperposition
open Libzipperposition_arbitrary
open QCheck

module T = TypedSTerm
module F = T.Form

let pp = T.to_string

let check_cnf_gives_clauses =
  let gen = Arbitrary.(lift F.close_forall ArForm.default) in
  let name = "cnf_gives_clauses" in
  (* check that the CNf of a formula is in clausal form *)
  let prop f =
    Cnf.cnf_of f ()
    |> CCVector.filter_map
      (fun st -> match Statement.view st with
        | Statement.TyDecl _ -> None
        | Statement.Assert c -> Some c)
    |> CCVector.map
      (fun c -> F.or_ (List.map SLiteral.to_form c))
    |> CCVector.for_all Cnf.is_clause
  in
  mk_test ~name ~pp gen prop

let check_miniscope_db_closed =
  let gen = Arbitrary.(lift F.close_forall ArForm.default) in
  let name = "cnf_miniscope_db_closed" in
  (* check that miniscoping preserved db_closed *)
  let prop f =
    let f = Cnf.miniscope f in
    T.closed f
  in
  mk_test ~name ~pp gen prop

let props =
  [ check_cnf_gives_clauses
  ; check_miniscope_db_closed
  ]