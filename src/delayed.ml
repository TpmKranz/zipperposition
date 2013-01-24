(*
zipperposition: a functional superposition prover for prototyping
copyright (c) 2012 simon cruanes

this is free software; you can redistribute it and/or
modify it under the terms of the gnu general public license
as published by the free software foundation; either version 2
of the license, or (at your option) any later version.

this is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.  see the
gnu general public license for more details.

you should have received a copy of the gnu general public license
along with this program; if not, write to the free software
foundation, inc., 51 franklin street, fifth floor, boston, ma
02110-1301 usa.
*)

(** module for superposition with equivalence reasoning and delayed clausal form *)

open Types
open Symbols
open Calculus

module T = Terms
module C = Clauses
module O = Orderings
module S = FoSubst
module Utils = FoUtils
module Sup = Superposition
module PS = ProofState

let prof_elim = Utils.mk_profiler "eliminate"

(** special predicate/connective symbols, in decreasing order *)
let special_preds =
  [eq_symbol; imply_symbol; forall_symbol; exists_symbol; lambda_symbol;
   or_symbol; and_symbol; not_symbol; false_symbol; true_symbol]

let special_set = List.fold_left (fun set s -> SSet.add s set) SSet.empty special_preds

type symbol_kind = 
  | Predicate | DeBruijn | Skolem | Function | Special

(** order on kinds of symbols *)
let order k1 k2 =
  match k1, k2 with
  | _, _ when k1 = k2 -> 0
  | Predicate, _ -> 1
  | _, Predicate -> -1
  | DeBruijn, _ -> 1
  | _, DeBruijn -> -1
  | Skolem, _ -> 1
  | _, Skolem -> -1
  | Function, _ -> 1
  | Special, _ -> -1

(* classify symbol into categories *)
let classify signature s =
  match s with
  | _ when s == db_symbol -> DeBruijn
  | _ when attrs_symbol s land attr_skolem <> 0 -> Skolem
  | _ when SSet.mem s special_set -> Special
  | _ -> (* classify between predicate and function by the sort *)
    let _, sort = SMap.find s signature in
    if sort == bool_sort then Predicate else Function

(** constraint on the ordering *)
let symbol_constraint clauses =
  let signature = C.signature clauses in
  [Precedence.min_constraint special_preds;
   fun x y -> order (classify signature x) (classify signature y)]

(* ----------------------------------------------------------------------
 * elimination rules
 * ---------------------------------------------------------------------- *)

(** equation simplified into a disjunction of conjunctions of equations *)
type tableau_rule =
  | Alpha of tableau_rule * tableau_rule  (** alpha elimination *)
  | List of literal list                  (** list of literals, after transformation *)
  | Keep of literal                       (** keep this equation unchanged *)

(** helper for alpha elimination *)
let alpha_eliminate ~ord a signa b signb =
  Alpha (List [C.mk_lit ~ord a T.true_term signa],
         List [C.mk_lit ~ord b T.true_term signb])

(** helper for beta elimination *)
let beta_eliminate ~ord a signa b signb =
  List [C.mk_lit ~ord a T.true_term signa;
        C.mk_lit ~ord b T.true_term signb]

(** helper for gamma elimination *)
let gamma_eliminate ~ord offset t sign =
  assert (t.sort = bool_sort);
  let i = !offset in
  incr offset;
  let new_t =
    match T.look_db_sort 0 t with
    | None -> T.db_unlift t (* the variable is not present *)
    | Some sort ->
      (* sort is the sort of the first DB symbol *)
      let new_var = T.mk_var i sort in
      T.db_unlift (T.db_replace t new_var)
  in
  List [C.mk_lit ~ord new_t T.true_term sign]

(** helper for delta elimination (remove idx-th literal from clause
    and adds t where De Bruijn 0 is replaced by a skolem
    of free variables of t) *)
let delta_eliminate ~ord t sign =
  assert (t.sort = bool_sort);
  let new_t =
    match T.look_db_sort 0 t with
    | None -> T.db_unlift t (* the variable is not present *)
    | Some sort ->
      (* sort is the sort of the first DB symbol *)
      !T.skolem ~ord t sort
  in
  List [C.mk_lit ~ord new_t T.true_term sign]

(** Just keep the equation as it is *)
let keep eqn = Keep eqn

(** TODO Miniscoping for reduction to CNF *)
let miniscope ~ord hc = hc

(** perform at most one simplification on each literal. It
    returns an array of tableau_rule. *)
let eliminate_lits ~ord hc =
  let offset = ref ((max 0 (T.max_var hc.hcvars)) + 1) in  (* offset to create variables *)
  (* eliminate propositions (connective and quantifier eliminations) *)
  let prop eqn p sign =
    assert (p.sort = bool_sort);
    match p.term with
    | BoundVar _ | Var _ -> assert false
    | Node (s, [a; b]) when s == and_symbol && sign -> alpha_eliminate ~ord a true b true
    | Node (s, [a; b]) when s == and_symbol && not sign -> beta_eliminate ~ord a false b false
    | Node (s, [a; b]) when s == or_symbol && sign -> beta_eliminate ~ord a true b true
    | Node (s, [a; b]) when s == or_symbol && not sign -> alpha_eliminate ~ord a false b false
    | Node (s, [a; b]) when s == imply_symbol && sign -> beta_eliminate ~ord a false b true
    | Node (s, [a; b]) when s == imply_symbol && not sign -> alpha_eliminate ~ord a true b false
    | Bind (s, t) when s == forall_symbol && sign ->
      gamma_eliminate ~ord offset t true
    | Bind (s, t) when s == forall_symbol && not sign ->
      delta_eliminate ~ord (T.mk_not t) true
    | Bind (s, t) when s == exists_symbol && sign ->
      delta_eliminate ~ord t true
    | Bind (s, t) when s == exists_symbol && not sign ->
      gamma_eliminate ~ord offset t false
    | Bind _ | Node _ -> keep eqn
  (* eliminate equivalence *)
  and equiv eqn l r sign =
    match ord#compare l r with
    | Gt when sign && not (T.atomic l) -> (* l <=> r -> (l => r) & (r => l)*)
      Alpha (List [C.mk_neq ~ord l T.true_term; C.mk_eq ~ord r T.true_term],
             List [C.mk_neq ~ord r T.true_term; C.mk_eq ~ord l T.true_term])
    | Lt when sign && not (T.atomic r) ->
      Alpha (List [C.mk_neq ~ord l T.true_term; C.mk_eq ~ord r T.true_term],
             List [C.mk_neq ~ord r T.true_term; C.mk_eq ~ord l T.true_term])
    | Incomparable when sign && (not (T.atomic l) || not (T.atomic r)) ->
      Alpha (List [C.mk_neq ~ord l T.true_term; C.mk_eq ~ord r T.true_term],
             List [C.mk_neq ~ord r T.true_term; C.mk_eq ~ord l T.true_term])
    | _ when not sign -> (* not (l <=> r) -> (l | r) & (not l | not r) *)
      Alpha (List [C.mk_eq ~ord l T.true_term; C.mk_eq ~ord r T.true_term],
             List [C.mk_neq ~ord r T.true_term; C.mk_neq ~ord l T.true_term])
    | _ -> keep eqn
  in
  (* try to eliminate each literal that is eligible for resolution *)
  let tableau_rules =
    Array.map
      (fun lit -> 
        match lit with
        | Equation (l, r, sign, _) when T.eq_term r T.true_term -> prop lit l sign
        | Equation (l, r, sign, _) when T.eq_term l T.true_term -> prop lit r sign
        | Equation (l, r, sign, _) when l.sort = bool_sort -> equiv lit l r sign
        | _ -> keep lit)  (* equation between terms *)
      hc.hclits
  in
  tableau_rules

(** Produce a list of clauses from an array of tableau_rule, or None *)
let tableau_to_clauses ~ord hc a =
  if Utils.array_forall (function | Keep _ -> true | _ -> false) a then None (* just keep all literals *)
  else begin
    let clauses = ref []
    and eqns = Vector.create (Array.length a * 2) in
    let proof = Proof ("elim", [C.base_clause hc, [], S.id_subst])
    and parents = [hc] in
    (* explore all combinations of tableau splits *)
    let rec explore_splits i =
      if i = Array.length a
        then  (* produce new clause *)
          let clause = C.mk_hclause_a ~ord (Vector.to_array eqns) proof parents in
          clauses := clause :: !clauses
        else begin
          let len = Vector.size eqns in
          explore_branch i len a.(i)
        end
    (* recurse in sub-tableau *)
    and explore_branch i len rule =
      (match rule with
      | Keep eqn ->  (* push equation *)
        Vector.push eqns eqn; explore_splits (i+1)
      | List l ->    (* push equations *)
        List.iter (Vector.push eqns) l; explore_splits (i+1)
      | Alpha (left, right) ->  (* explore left, then right *)
        explore_branch i len left;
        explore_branch i len right);
      Vector.shrink eqns len  (* restore state *)
    in explore_splits 0;
    (* return the vector of clauses *)
    Some !clauses
  end

(** Perform eliminations recursively, until no elimination is possible *)
let recursive_eliminations ~ord ~select hc =
  Utils.enter_prof prof_elim;
  let clauses = ref [] in
  (* process clauses until none of them is simplifiable *)
  let rec simplify hc =
    let hc' = C.clause_of_fof ~ord hc in
    (* miniscoping *)
    let hc' = miniscope ~ord hc' in
    (* one step of reduction to clauses *)
    let tableau_rules = eliminate_lits ~ord hc' in
    match tableau_to_clauses ~ord hc' tableau_rules with
    | None -> clauses := hc' :: !clauses (* done with this clause *)
    | Some clauses ->
      Utils.debug 3 (lazy (Utils.sprintf "@[<hov 4>@[<h>%a@]@ simplified into clauses @[<hv>%a@]@]"
                    !C.pp_clause#pp_h hc' (Utils.pp_list !C.pp_clause#pp_h) clauses));
      List.iter (fun hc -> simplify (C.select_clause ~select hc)) clauses (* simplify recursively new clauses *)
  in
  simplify hc;
  Utils.exit_prof prof_elim;
  !clauses

(* ----------------------------------------------------------------------
 * syntactic simplification
 * ---------------------------------------------------------------------- *)

(** Simplify the inner formula (double negation, trivial equalities...) *)
let simplify_inner ~ord hc =
  let simplified = ref false in
  let mark_simplified t = T.set_flag T.flag_simplified t true in
  (* simplify a term *)
  let rec simp_term t =
    if T.get_flag T.flag_simplified t then t else  (* maybe it's already simplified *)
    match t.term with
    | Var _ | Node (_, []) | BoundVar _ -> (mark_simplified t; t)
    | Bind (f, t') when not (T.db_contains t' 0) ->
      simp_term t'  (* eta-reduction: binder binds nothing, remove it *)
    | Bind (f, t') -> T.mk_bind f (simp_term t')
    | Node (s, [{term=Node (s', [t'])}]) when s = not_symbol && s' = not_symbol ->
      simp_term t'  (* double negation *)
    | Node (s, [t']) when s = not_symbol && T.eq_term t' T.true_term ->
      T.false_term  (* not true -> false *)
    | Node (s, [t']) when s = not_symbol && T.eq_term t' T.false_term ->
      T.true_term   (* not false -> true *)
    | Node (s, [{term=Node (s', [t'])}])
      when (s = forall_symbol || s = exists_symbol) && s' = lambda_symbol
        && not (T.db_contains t' 0) ->
        simp_term (T.db_unlift t') (* eta-reduction *)
    | Node (s, [a; b]) when s = and_symbol && (T.eq_term a T.false_term || T.eq_term b T.false_term) ->
      T.false_term  (* a and false -> false *)
    | Node (s, [a; b]) when s = or_symbol && (T.eq_term a T.true_term || T.eq_term b T.true_term) ->
      T.true_term  (* a or true -> true *)
    | Node (s, [a; b]) when s = or_symbol && T.eq_term a T.false_term ->
      simp_term b  (* b or false -> b *)
    | Node (s, [a; b]) when s = or_symbol && T.eq_term b T.false_term ->
      simp_term a  (* a or false -> a *)
    | Node (s, [a; b]) when s = and_symbol && T.eq_term a T.true_term ->
      simp_term b  (* b and true -> b *)
    | Node (s, [a; b]) when s = and_symbol && T.eq_term b T.true_term ->
      simp_term a  (* a and true -> a *)
    | Node (s, [a; b]) when s = imply_symbol && (T.eq_term a T.false_term || T.eq_term b T.true_term) ->
      T.true_term  (* (false => a) or (a => true) -> true *)
    | Node (s, [a; b]) when s = imply_symbol && T.eq_term a T.true_term ->
      simp_term b  (* (true => a) -> a *)
    | Node (s, [a; b]) when s = eq_symbol && T.eq_term a b ->
      T.true_term  (* a = a -> true *)
    | Node (s, [a; b]) when s = eq_symbol && 
      ((T.eq_term a T.true_term && T.eq_term b T.false_term) ||
       (T.eq_term b T.true_term && T.eq_term a T.false_term)) ->
      T.false_term (* true = false -> false *)
    | Node (s, [a; b]) when s = eq_symbol && T.eq_term b T.true_term ->
      simp_term a  (* a = true -> a *)
    | Node (s, [a; b]) when s = eq_symbol && T.eq_term a T.true_term ->
      simp_term b  (* b = true -> b *)
    | Node (s, [a; b]) when s = eq_symbol && T.eq_term b T.false_term ->
      simp_term (T.mk_not a)  (* a = false -> not a *)
    | Node (s, [a; b]) when s = eq_symbol && T.eq_term a T.false_term ->
      simp_term (T.mk_not b)  (* b = false -> not b *)
    | Node (s, l) ->
      let l' = List.map simp_term l in
      if List.for_all2 (==) l l'
        then (mark_simplified t; t)
        else 
          let new_t = T.mk_node s t.sort (List.map simp_term l) in
          simp_term new_t
  (* simplify a lit *)
  and simp_lit (Equation (l,r,sign,_) as lit) =
    let lit' = C.mk_lit ~ord (simp_term l) (simp_term r) sign in
    (if not (C.eq_literal lit lit') then simplified := true);
    lit'
  in
  let lits = Array.map simp_lit hc.hclits in
  if !simplified
    then C.mk_hclause_a ~ord lits hc.hcproof hc.hcparents
    else hc  (* no simplification *)

(* ----------------------------------------------------------------------
 * the calculus object
 * ---------------------------------------------------------------------- *)

let delayed : calculus =
  object (self)
    method binary_rules = ["superposition_active", Sup.infer_active;
                           "superposition_passive", Sup.infer_passive]

    method unary_rules = ["equality_resolution", Sup.infer_equality_resolution;
                          "equality_factoring", Sup.infer_equality_factoring; ]

    method basic_simplify ~ord hc = Sup.basic_simplify ~ord (simplify_inner ~ord hc)

    method rw_simplify ~select (simpl : PS.simpl_set) hc =
      let ord = simpl#ord in
      let hc = C.select_clause ~select hc in
      (* rename for demodulation *)
      let c = simpl#relocate hc in
      let hc = Sup.basic_simplify ~ord (Sup.demodulate simpl c) in
      (* rename for simplify reflect *)
      let c = simpl#relocate hc in
      let hc = Sup.positive_simplify_reflect simpl c in
      (* rename for simplify reflect *)
      let c =  simpl#relocate hc in
      let hc = Sup.negative_simplify_reflect simpl c in
      let hc = C.select_clause ~select hc in
      hc

    method active_simplify ~select actives hc =
      (* condensation *)
      let hc = Sup.condensation ~ord:actives#ord hc in
      (* contextual literal cutting *)
      let hc = Sup.contextual_literal_cutting actives hc in
      let hc = C.select_clause ~select hc in
      hc

    method backward_simplify actives hc =
      let set = C.CSet.empty in
      let c = actives#relocate hc in
      Sup.backward_demodulate actives set c

    method redundant actives hc =
      let c = actives#relocate hc in
      Sup.subsumed_by_set actives c

    method backward_redundant actives hc =
      let c = actives#relocate hc in
      Sup.subsumed_in_set actives c

    (* use elimination rules as simplifications rather than inferences, here *)
    method list_simplify ~ord ~select hc =
      let hc = C.select_clause ~select (self#basic_simplify ~ord hc) in
      let l = recursive_eliminations ~ord ~select hc in
      let l = List.filter (fun hc -> not (Sup.is_tautology hc)) l in
      let l = List.map (C.select_clause ~select) l in
      l

    method is_trivial hc = Sup.is_tautology hc

    method axioms = []

    method constr clauses = symbol_constraint clauses

    method preprocess ~ord ~select l =
      Utils.list_flatmap
        (fun hc ->
          let hc = C.reord_hclause ~ord hc in
          let hc = Sup.basic_simplify ~ord (C.clause_of_fof ~ord hc) in
          C.check_ord_hclause ~ord hc;
          let clauses = self#list_simplify ~ord ~select hc in
          List.fold_left
            (fun clauses hc ->
              let hc = C.clause_of_fof ~ord hc in
              C.check_ord_hclause ~ord hc;
              let hc = C.select_clause ~select hc in
              if not (Sup.is_tautology hc) then hc :: clauses else clauses)
            [] clauses)
        l
  end
