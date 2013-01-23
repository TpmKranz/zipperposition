(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)


open Types
open Hashcons

module T = Terms
module S = FoSubst
module Utils = FoUtils

let enable = true

let prof_unification = Utils.mk_profiler "unification"
let prof_matching = Utils.mk_profiler "matching"

(** does [var] appear in [t] (even when expanding bindings)? *)
let occurs_check var t =
  let rec check var t =
    if T.is_ground_term t then false else match t.term with
      | Var _ when var == t -> true
      | Var _ when t != (T.get_binding t) ->
        check var (T.get_binding t)  (* recurse in binding *)
      | Var _ | BoundVar _ -> false
      | Bind (_, t') -> check var t'
      | Node (_, l) -> check_list var l
  and check_list var l = match l with
  | [] -> false
  | x::l' -> check var x || check_list var l'
  in
  check var t

(** if t is a variable, return its current binding *)
let rec get_var_binding t =
  if T.is_var t && not (T.eq_term (T.get_binding t) t)
    then get_var_binding (T.get_binding t)
    else t

let unification subst a b =
  Utils.enter_prof prof_unification;
  (* recursive unification *)
  let rec unif subst s t =
    (if s.sort <> t.sort then raise UnificationFailure);
    let s = get_var_binding s
    and t = get_var_binding t in
    match s.term, t.term with
    | _, _ when T.eq_term s t -> subst
    | _, _ when T.is_ground_term s && T.is_ground_term t -> raise UnificationFailure
        (* distinct ground terms cannot be unified *)
    | Var _, _ when occurs_check s t -> raise UnificationFailure
    | Var _, _ ->
      T.set_binding s (T.expand_bindings t);
      S.update_binding subst s
    | _, Var _ when occurs_check t s -> raise UnificationFailure
    | _, Var _ ->
      T.set_binding t (T.expand_bindings s);
      S.update_binding subst t
    | Bind (f, t1'), Bind (g, t2') when f == g -> unif subst t1' t2'
    | BoundVar i, BoundVar j -> if i = j then subst else raise UnificationFailure
    | Node (f, l1), Node (g, l2) when f == g && List.length l1 = List.length l2 ->
      let subst = unify_composites subst l1 l2 in (* unify non-vars *)
      unify_vars subst l1 l2  (* unify vars *)
    | _, _ -> raise UnificationFailure
  (* unify pairwise when pairs contain no variable at root *)
  and unify_composites subst l1 l2 =
    match l1, l2 with
    | [], [] -> subst
    | x1::l1', x2::l2' ->
      let subst = if T.is_var x1 || T.is_var x2 then subst else unif subst x1 x2 in
      unify_composites subst l1' l2'
    | _ -> assert false
  (* unify pairwise when pairs contain at least one variable at root *)
  and unify_vars subst l1 l2 =
    match l1, l2 with
    | [], [] -> subst
    | x1::l1', x2::l2' ->
      let subst = if T.is_var x1 || T.is_var x2 then unif subst x1 x2 else subst in
      unify_vars subst l1' l2'
    | _ -> assert false
  in
  (* setup and cleanup *)
  T.reset_vars a;
  T.reset_vars b;
  S.apply_subst_bind subst;
  try
    let subst = unif subst a b in
    Utils.exit_prof prof_unification;
    subst
  with UnificationFailure as e ->
    Utils.exit_prof prof_unification;
    raise e

let matching_locked ~locked subst a b =
  Utils.enter_prof prof_matching;
  (* recursive matching *)
  let rec unif subst s t =
    (if s.sort <> t.sort then raise UnificationFailure);
    let s = get_var_binding s
    and t = get_var_binding t in
    match s.term, t.term with
    | _ when T.eq_term s t -> subst
    | _ when T.is_ground_term s -> raise UnificationFailure 
    | Var _, _ when T.THashSet.member locked s || occurs_check s t ->
      raise UnificationFailure
    | Var _, _ ->
      T.set_binding s (T.expand_bindings t);
      S.update_binding subst s
    | Bind (f, t1'), Bind (g, t2') when f == g -> unif subst t1' t2'
    | BoundVar i, BoundVar j -> if i = j then subst else raise UnificationFailure
    | Node (f, l1), Node (g, l2) when f == g && List.length l1 = List.length l2 ->
      List.fold_left2 unif subst l1 l2
    | _ -> raise UnificationFailure
  in
  T.reset_vars a;
  T.reset_vars b;
  S.apply_subst_bind subst;
  try
    let subst = unif subst a b in
    Utils.exit_prof prof_matching;
    subst
  with UnificationFailure as e ->
    Utils.exit_prof prof_matching;
    raise e

let matching subst a b =
  let locked = T.THashSet.create () in
  T.add_vars locked b;
  matching_locked ~locked subst a b
