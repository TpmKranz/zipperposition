
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Global environment for an instance of the prover} *)

open Libzipperposition

module T = FOTerm
module PF = PFormula
module Lit = Literal
module Lits = Literals

let section = Util.Section.make ~parent:Const.section "env"

(** {2 Signature} *)
module type S = Env_intf.S

module Make(X : sig
    module Ctx : Ctx.S
    val params : Params.t
  end)
  : S with module Ctx = X.Ctx
= struct

  module Ctx = X.Ctx
  module C = Clause.Make(Ctx)
  module ProofState = ProofState.Make(C)


  type inf_rule = C.t -> C.t list
  (** An inference returns a list of conclusions *)

  type generate_rule = unit -> C.t list
  (** Generation of clauses regardless of current clause *)

  type binary_inf_rule = inf_rule
  type unary_inf_rule = inf_rule

  type simplify_rule = C.t -> C.t SimplM.t
  (** Simplify the clause structurally (basic simplifications),
      in the simplification monad.
      [(c, `Same)] means the clause has not been simplified;
      [(c, `New)] means the clause has been simplified at least once *)

  type active_simplify_rule = simplify_rule
  type rw_simplify_rule = simplify_rule

  type backward_simplify_rule = C.t -> C.CSet.t
  (** backward simplification by a unit clause. It returns a set of
      active clauses that can potentially be simplified by the given clause.
      [backward_simplify c] therefore returns a subset of
      [ProofState.ActiveSet.clauses ()] *)

  type redundant_rule = C.t -> bool
  (** check whether the clause is redundant w.r.t the set *)

  type backward_redundant_rule = C.CSet.t -> C.t -> C.CSet.t
  (** find redundant clauses in [ProofState.ActiveSet] w.r.t the clause.
       first param is the set of already known redundant clause, the rule
       should add clauses to it *)

  type is_trivial_rule = C.t -> bool
  (** Rule that checks whether the clause is trivial (a tautology) *)

  type term_rewrite_rule = FOTerm.t -> FOTerm.t option
  (** Rewrite rule on terms *)

  type lit_rewrite_rule = Literal.t -> Literal.t
  (** Rewrite rule on literals *)

  type multi_simpl_rule = C.t -> C.t list option
  (** (maybe) rewrite a clause to a set of clauses.
      Must return [None] if the clause is unmodified *)

  let _binary_rules : (string * binary_inf_rule) list ref = ref []
  let _unary_rules : (string * unary_inf_rule) list ref = ref []
  let _rewrite_rules : (string * term_rewrite_rule) list ref = ref []
  let _lit_rules : (string * lit_rewrite_rule) list ref = ref []
  let _basic_simplify : simplify_rule list ref = ref []
  let _rw_simplify = ref []
  let _active_simplify = ref []
  let _backward_simplify = ref []
  let _redundant = ref []
  let _backward_redundant : backward_redundant_rule list ref = ref []
  let _is_trivial : is_trivial_rule list ref = ref []
  let _empty_clauses = ref C.CSet.empty
  let _multi_simpl_rule : multi_simpl_rule list ref = ref []
  let _generate_rules : (string * generate_rule) list ref = ref []
  let _step_init = ref []

  let on_start = Signal.create()
  let on_empty_clause = Signal.create ()

  (** {2 Basic operations} *)

  let add_empty c =
    assert (C.is_empty c);
    _empty_clauses := C.CSet.add !_empty_clauses c;
    Signal.send on_empty_clause c;
    ()

  let add_passive cs =
    ProofState.PassiveSet.add cs;
    Sequence.iter
      (fun c -> if C.is_empty c then add_empty c) cs;
    ()

  let add_active cs =
    ProofState.ActiveSet.add cs;
    Sequence.iter
      (fun c -> if C.is_empty c then add_empty c) cs;
    ()

  let add_simpl cs =
    ProofState.SimplSet.add cs

  let remove_active cs =
    ProofState.ActiveSet.remove cs

  let remove_passive cs =
    ProofState.PassiveSet.remove cs

  let remove_passive_id ids =
    ProofState.PassiveSet.remove_by_id ids

  let remove_simpl cs =
    ProofState.SimplSet.remove cs

  let clean_passive () =
    ProofState.PassiveSet.clean ()

  let get_passive () =
    ProofState.PassiveSet.clauses () |> C.CSet.to_seq

  let get_active () =
    ProofState.ActiveSet.clauses () |> C.CSet.to_seq

  let add_binary_inf name rule =
    if not (List.mem_assoc name !_binary_rules)
    then _binary_rules := (name, rule) :: !_binary_rules

  let add_unary_inf name rule =
    if not (List.mem_assoc name !_unary_rules)
    then _unary_rules := (name, rule) :: !_unary_rules

  let add_generate name rule =
    if not (List.mem_assoc name !_generate_rules)
    then _generate_rules := (name, rule) :: !_generate_rules

  let add_rw_simplify r =
    _rw_simplify := r :: !_rw_simplify

  let add_active_simplify r =
    _active_simplify := r :: !_active_simplify

  let add_backward_simplify r =
    _backward_simplify := r :: !_backward_simplify

  let add_redundant r =
    _redundant := r :: !_redundant

  let add_backward_redundant r =
    _backward_redundant := r :: !_backward_redundant

  let add_simplify r =
    _basic_simplify := r :: !_basic_simplify

  let add_is_trivial r =
    _is_trivial := r :: !_is_trivial

  let add_rewrite_rule name rule =
    _rewrite_rules := (name, rule) :: !_rewrite_rules

  let add_lit_rule name rule =
    _lit_rules := (name, rule) :: !_lit_rules

  let add_multi_simpl_rule rule =
    _multi_simpl_rule := rule :: !_multi_simpl_rule

  let add_step_init f = _step_init := f :: !_step_init

  let params = X.params

  let get_empty_clauses () =
    !_empty_clauses

  let get_some_empty_clause () =
    C.CSet.choose !_empty_clauses

  let has_empty_clause () =
    not (C.CSet.is_empty !_empty_clauses)

  let ord () = Ctx.ord ()
  let precedence () = Ordering.precedence (ord ())
  let signature () = Ctx.signature ()

  let pp out () = CCFormat.string out "env"

  let pp_full out () =
    Format.fprintf out "@[<hv2>env(state:@ %a@,)@]" ProofState.debug ()

  (** {2 High level operations} *)

  let prof_generate = Util.mk_profiler "generate"
  let prof_generate_unary = Util.mk_profiler "generate_unary"
  let prof_generate_binary = Util.mk_profiler "generate_binary"
  let prof_back_simplify = Util.mk_profiler "back_simplify"
  let prof_simplify = Util.mk_profiler "simplify"
  let prof_all_simplify = Util.mk_profiler "all_simplify"
  let prof_is_redundant = Util.mk_profiler "is_redundant"
  let prof_subsumed_by = Util.mk_profiler "subsumed_by"

  let stat_inferred = Util.mk_stat "inferred clauses"

  type stats = int * int * int

  let stats () = ProofState.stats ()

  let cnf seq =
    Sequence.fold
      (fun cset pf ->
         let f = PF.form pf in
         Util.debugf ~section 3 "@[<2>reduce@ @[%a@]@ to CNF...@]"
           (fun k->k TypedSTerm.pp f);
         (* reduce to CNF this clause *)
         let stmts = Cnf.cnf_of ~ctx:Ctx.skolem f () in
         let proof cc = Proof.mk_c_esa ~rule:"cnf" cc [PF.proof pf] in
         CCVector.fold
           (fun cset st -> match Statement.view st with
            | Statement.Assert c ->
                let c = Cnf.clause_to_fo c in
                let c = C.of_forms ~trail:Trail.empty c proof in
                C.CSet.add cset c
            | Statement.TyDecl (s, ty) ->
                let ctx = Type.Conv.create() in
                let ty = Type.Conv.of_simple_term_exn ctx ty in
                Util.debugf ~section 5 "declare skolem %a : %a"
                  (fun k->k ID.pp s Type.pp ty);
                Ctx.declare s ty;
                cset)
           cset stmts)
      C.CSet.empty
      seq

  let next_passive () =
    ProofState.PassiveSet.next ()

  (** do binary inferences that involve the given clause *)
  let do_binary_inferences c =
    Util.enter_prof prof_generate_binary;
    Util.debugf ~section 3 "@[<2>do binary inferences with current active set:@ @[%a@]@]"
      (fun k->k C.pp_set (ProofState.ActiveSet.clauses ()));
    (* apply every inference rule *)
    let clauses =
      List.fold_left
        (fun acc (name, rule) ->
           Util.debugf ~section 3 "apply binary rule %s" (fun k->k name);
           let new_clauses = rule c in
           List.rev_append new_clauses acc)
        [] !_binary_rules
    in
    Util.exit_prof prof_generate_binary;
    Sequence.of_list clauses

  (** do unary inferences for the given clause *)
  let do_unary_inferences c =
    Util.enter_prof prof_generate_unary;
    Util.debug ~section 3 "do unary inferences";
    (* apply every inference rule *)
    let clauses = List.fold_left
        (fun acc (name, rule) ->
           Util.debugf ~section 3 "apply unary rule %s" (fun k->k name);
           let new_clauses = rule c in
           List.rev_append new_clauses acc)
        [] !_unary_rules in
    Util.exit_prof prof_generate_unary;
    Sequence.of_list clauses

  let do_generate () =
    let clauses =
      List.fold_left
        (fun acc (name,g) ->
           Util.debugf ~section 3 "apply generating rule %s" (fun k->k name);
           List.rev_append (g()) acc)
        []
        !_generate_rules
    in
    Sequence.of_list clauses

  let is_trivial c =
    if C.get_flag C.flag_persistent c then false else
      match !_is_trivial with
      | [] -> false
      | [f] -> f c
      | [f;g] -> f c || g c
      | l -> List.exists (fun f -> f c) l

  let is_active c =
    C.CSet.mem (ProofState.ActiveSet.clauses ()) c

  let is_passive c =
    C.CSet.mem (ProofState.PassiveSet.clauses ()) c

  module StrSet = Set.Make(String)

  (** Apply rewrite rules AND evaluation functions *)
  let rewrite c =
    Util.debugf ~section 5 "rewrite clause@ @[%a@]..." (fun k->k C.pp c);
    let applied_rules = ref StrSet.empty in
    let rec reduce_term rules t =
      match rules with
      | [] -> t
      | (name, r)::rules' ->
          begin match r t with
          | None -> reduce_term rules' t (* try next rules *)
          | Some t' ->
              applied_rules := StrSet.add name !applied_rules;
              Util.debugf ~section 5 "@[rewrite @[%a@]@ into @[%a@]@]"
                (fun k->k T.pp t T.pp t');
              reduce_term !_rewrite_rules t'  (* re-apply all rules *)
          end
    in
    (* reduce every literal *)
    let lits' =
      Array.map
        (fun lit -> Lit.map (reduce_term !_rewrite_rules) lit)
        (C.lits c)
    in
    if StrSet.is_empty !applied_rules
    then SimplM.return_same c (* no simplification *)
    else (
      let rule = "rw_" ^ (String.concat "_" (StrSet.elements !applied_rules)) in
      let proof c' = Proof.mk_c_simp ~rule c' [C.proof c] in
      let c' = C.create_a ~trail:(C.trail c) lits' proof in
      Util.debugf ~section 3 "@[term rewritten clause @[%a@]@ into @[%a@]"
        (fun k->k C.pp c C.pp c');
      SimplM.return_new c'
    )

  (** Apply literal rewrite rules *)
  let rewrite_lits c =
    let applied_rules = ref StrSet.empty in
    let rec rewrite_lit rules lit = match rules with
      | [] -> lit
      | (name,r)::rules' ->
          let lit' = r lit in  (* apply the rule *)
          if Lit.equal_com lit lit'
          then rewrite_lit rules' lit
          else begin
            applied_rules := StrSet.add name !applied_rules;
            Util.debugf ~section 5 "@[rewritten lit @[%a@]@ into @[%a@]@ (using %s)@]"
              (fun k->k Lit.pp lit Lit.pp lit' name);
            rewrite_lit !_lit_rules lit'
          end
    in
    (* apply lit rules *)
    let lits = Array.map (fun lit -> rewrite_lit !_lit_rules lit) (C.lits c) in
    if Lits.equal_com lits (C.lits c)
    then SimplM.return_same c
    else (
      (* simplifications occurred! *)
      let rule = "lit_rw_" ^ (String.concat "_" (StrSet.elements !applied_rules)) in
      let proof c' = Proof.mk_c_simp ~rule c' [C.proof c]  in
      let c' = C.create_a ~trail:(C.trail c) lits proof in
      Util.debugf ~section 3 "@[lit rewritten @[%a@]@ into @[%a@]@]"
        (fun k->k C.pp c C.pp c');
      SimplM.return_new c'
    )

  (* apply simplification in a fixpoint *)
  let rec fix_simpl
  : (C.t -> C.t SimplM.t) -> C.t -> C.t SimplM.t
  = fun f c ->
    let open SimplM.Infix in
    let new_c = f c in
    if C.equal c (SimplM.get new_c)
      then new_c (* fixpoint reached *)
      else new_c >>= fix_simpl f (* some progress was made *)

  (* All basic simplification of the clause itself *)
  let basic_simplify c =
    let open SimplM.Infix in
    fix_simpl
      (fun c ->
        (* first, rewrite terms *)
        rewrite c >>= fun c ->
        (* rewrite literals (if needed) *)
        begin match !_lit_rules with
          | [] -> SimplM.return_same c
          | _::_ -> rewrite_lits c
        end
        >>= fun c ->
        (* apply simplifications *)
        begin match !_basic_simplify with
          | [] -> SimplM.return_same c
          | [f] -> f c
          | [f;g] -> f c >>= g
          | l -> SimplM.app_list l c
        end)
      c

  (* rewrite clause with simpl_set *)
  let rw_simplify c =
    let open SimplM.Infix in
    fix_simpl
      (fun c ->
        if C.get_flag C.flag_persistent c
        then SimplM.return_same c
        else match !_rw_simplify with
          | [] -> SimplM.return_same c
          | [f] -> f c
          | [f;g] -> f c >>= g
          | l -> SimplM.app_list l c)
      c

  (* simplify clause w.r.t. active set *)
  let active_simplify c =
    let open SimplM.Infix in
    fix_simpl
      (fun c ->
        if C.get_flag C.flag_persistent c
        then SimplM.return_same c
        else match !_active_simplify with
          | [] -> SimplM.return_same c
          | [f] -> f c
          | [f;g] -> f c >>= g
          | l -> SimplM.app_list l c)
      c

  let simplify c =
    let open SimplM.Infix in
    Util.enter_prof prof_simplify;
    let res = fix_simpl
      (fun c ->
        let old_c = c in
        basic_simplify c >>=
        (* simplify with unit clauses, then all active clauses *)
        rewrite >>=
        rw_simplify >>=
        basic_simplify >>=
        active_simplify >>= fun c ->
        if not (Lits.equal_com (C.lits c) (C.lits old_c))
        then
          Util.debugf ~section 2 "@[clause @[%a@]@ simplified into @[%a@]@]"
            (fun k->k C.pp old_c C.pp c);
        SimplM.return_same c)
      c
    in
    Util.exit_prof prof_simplify;
    res

  let multi_simplify c : C.t list option =
    let did_something = ref false in
    (* try rules one by one until some of them succeeds *)
    let rec try_next c rules = match rules with
      | [] -> None
      | r::rules' ->
          match r c with
          | Some l -> Some l
          | None -> try_next c rules'
    in
    (* fixpoint of [try_next] *)
    let set = ref C.CSet.empty in
    let q = Queue.create () in
    Queue.push c q;
    while not (Queue.is_empty q) do
      let c = Queue.pop q in
      if not (C.CSet.mem !set c) then (
        let c, st = basic_simplify c in
        if st = `New then did_something := true;
        match try_next c !_multi_simpl_rule with
        | None ->
            (* keep the clause! *)
            set := C.CSet.add !set c;
        | Some l ->
            did_something := true;
            List.iter (fun c -> Queue.push c q) l;
      )
    done;
    if !did_something
    then Some (C.CSet.to_list !set)
    else None

  (* find candidates for backward simplification in active set *)
  let backward_simplify_find_candidates given =
    match !_backward_simplify with
    | [] -> C.CSet.empty
    | [f] -> f given
    | [f;g] -> C.CSet.union (f given) (g given)
    | l -> List.fold_left (fun set f -> C.CSet.union set (f given)) C.CSet.empty l

  (* Perform backward simplification with the given clause *)
  let backward_simplify given =
    Util.enter_prof prof_back_simplify;
    (* set of candidate clauses, that may be unit-simplifiable *)
    let candidates = backward_simplify_find_candidates given in
    (* try to simplify the candidates. Before is the set of clauses that
       are simplified, after is the list of those clauses after simplification *)
    let before, after =
      C.CSet.fold candidates (C.CSet.empty, [])
        (fun (before, after) _ c ->
           let c', is_new = rw_simplify c in
           match is_new with
           | `Same -> before, after
           | `New ->
               (* the active clause has been simplified! *)
               Util.debugf ~section 2
                 "@[active clause @[%a@]@ simplified into @[%a@]@]"
                 (fun k->k C.pp c C.pp c');
               C.CSet.add before c, c' :: after)
    in
    Util.exit_prof prof_back_simplify;
    before, Sequence.of_list after

  let simplify_active_with f =
    let set =
      C.CSet.fold
        (ProofState.ActiveSet.clauses ()) []
        (fun set _id c ->
           match f c with
           | None -> set
           | Some clauses ->
               let clauses = List.map (fun c -> SimplM.get (basic_simplify c)) clauses in
               Util.debugf ~section 3
                "@[active clause @[%a@]@ simplified into clauses @[%a@]@]"
                 (fun k->k C.pp c (CCFormat.list C.pp) clauses);
               (c, clauses) :: set
        )
    in
    (* remove clauses from active set, put their simplified version into
        the passive set for further processing *)
    ProofState.ActiveSet.remove (Sequence.of_list set |> Sequence.map fst);
    Sequence.of_list set
    |> Sequence.map snd
    |> Sequence.flat_map Sequence.of_list
    |> ProofState.PassiveSet.add;
    ()

  (** Simplify the clause w.r.t to the active set *)
  let forward_simplify c =
    let open SimplM.Infix in
    rewrite c >>= rw_simplify >>= basic_simplify

  (** generate all clauses from inferences *)
  let generate given =
    Util.enter_prof prof_generate;
    (* binary clauses *)
    let binary_clauses = do_binary_inferences given in
    (* unary inferences *)
    let unary_clauses = ref []
    and unary_queue = Queue.create () in
    Queue.push (given, 0) unary_queue;
    while not (Queue.is_empty unary_queue) do
      let c, depth = Queue.pop unary_queue in
      let c, _ = basic_simplify c in (* simplify a bit the clause *)
      if not (is_trivial c) then (
        (* add the clause to set of inferred clauses, if it's not the original clause *)
        (if depth > 0 then unary_clauses := c :: !unary_clauses);
        if depth < params.Params.param_unary_depth
        then (
          (* infer clauses from c, add them to the queue *)
          let new_clauses = do_unary_inferences c in
          Sequence.iter
            (fun c' -> Queue.push (c', depth+1) unary_queue)
            new_clauses
        )
      )
    done;
    (* generating rules *)
    let other_clauses = do_generate () in
    (* combine all clauses *)
    let result = Sequence.(
        append
          (of_list !unary_clauses)
          (append binary_clauses other_clauses))
    in
    Util.add_stat stat_inferred (Sequence.length result);
    Util.exit_prof prof_generate;
    result

  (** check whether the clause is redundant w.r.t the current active_set *)
  let is_redundant c =
    Util.enter_prof prof_is_redundant;
    let res = match !_redundant with
      | [] -> false
      | [f] -> f c
      | [f;g] -> f c || g c
      | l -> List.exists (fun f -> f c) l
    in
    Util.exit_prof prof_is_redundant;
    res

  (** find redundant clauses in current active_set *)
  let subsumed_by c =
    Util.enter_prof prof_subsumed_by;
    let res =
      List.fold_left
        (fun set rule -> rule set c)
        C.CSet.empty
        !_backward_redundant
    in
    Util.exit_prof prof_subsumed_by;
    res

  (** Use all simplification rules to convert a clause into a list of
      maximally simplified clauses *)
  let all_simplify c =
    Util.enter_prof prof_all_simplify;
    let did_simplify = ref false in
    let set = ref C.CSet.empty in
    let q = Queue.create () in
    Queue.push c q;
    while not (Queue.is_empty q) do
      let c = Queue.pop q in
      let c, st = simplify c in
      if st=`New then did_simplify := true;
      if is_trivial c || is_redundant c
      then ()
      else match multi_simplify c with
        | None ->
            (* clause has reached fixpoint *)
            set := C.CSet.add !set c
        | Some l ->
            (* continue processing *)
            did_simplify := true;
            List.iter (fun c -> Queue.push c q) l
    done;
    let res = C.CSet.to_list !set in
    Util.exit_prof prof_all_simplify;
    if !did_simplify
    then SimplM.return_new res
    else SimplM.return_same res

  let step_init () = List.iter (fun f -> f()) !_step_init

  (** {2 Misc} *)

  let mixtbl = CCMixtbl.create 16
end