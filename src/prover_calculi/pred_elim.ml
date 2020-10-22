
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Blocked Clause Elimination} *)

open Logtk
open Libzipperposition

let k_enabled = Flex_state.create_key ()
let k_check_at = Flex_state.create_key ()
let k_inprocessing = Flex_state.create_key ()
let k_max_resolvents = Flex_state.create_key ()

let section = Util.Section.make ~parent:Const.section "pred-elim"

module type S = sig
  module Env : Env.S

  (** {6 Registration} *)
  val setup : unit -> unit
end

module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module L = Literal
  module T = Term

  type logic = 
    | NEqFO  (* nonequational FO *)
    | EqFO (* equational FO *)
    | Unsupported   (* HO or FO with theories *)

  exception UnsupportedLogic
  
  type pred_elim_info =
  {
    sym : ID.t;
    (* clauses with single pos/neg occurrence of a symbol *)
    mutable pos_cls : C.ClauseSet.t;
    mutable neg_cls : C.ClauseSet.t;
    (* clauses with multiple occurrences of a symbol *)
    mutable offending_cls : C.ClauseSet.t;
    (* clauses that have the gate shape (occurs in pos/neg cls)  *)
    mutable possible_gates : C.ClauseSet.t;
    (* do the clauses in the possible_gates form a gate, and if so which one? *)
    mutable is_gate : (C.t list * C.t list) option;
    (* square of number of different variables stored in this clause set *)
    mutable sq_var_weight : float;
    (* number of literals stored in this clause set *)
    mutable num_lits : int;
    (* what was this number during the last check *)
    mutable last_check : (float * int) option;
    mutable heap_idx : int;
  }

  let pp_task out task =
    CCFormat.fprintf out 
      "%a {@. +: @[%d@];@. -:@[%d@];@. ?:@[%d@]@. g:@[%b@]@. v^2:@[%g@]; |l|:@[%d@]; @.}@."
      ID.pp task.sym (C.ClauseSet.cardinal task.pos_cls) (C.ClauseSet.cardinal task.neg_cls)
      (C.ClauseSet.cardinal task.offending_cls) (CCOpt.is_some task.is_gate) task.sq_var_weight
      task.num_lits

  module TaskWrapper = struct
    type t = pred_elim_info
    let idx task = task.heap_idx
    let set_idx task idx = 
      task.heap_idx <- idx
    let lt a b =
      let card t = 
        C.ClauseSet.cardinal t.pos_cls + C.ClauseSet.cardinal t.neg_cls
      in
      let card_a = card a and card_b = card b in
      card_a < card_b || (card_a = card_b && ID.compare a.sym b.sym < 0)
  end

  module TaskSet = CCSet.Make(struct
    type t = pred_elim_info
    let compare t1 t2 = ID.compare t1.sym t2.sym
  end)

  let _task_queue = ref TaskSet.empty
  (* an optimization -- profiler showed that much time is spent in
     doing evaluation queue functions for added clauses -- instead
     we temporarily store the clauses in this set and then
     when we are sure that the clause is retained we 
     add it to the passive set *)
  let _newly_added = ref C.ClauseSet.empty

  let _logic = ref NEqFO
  let refine_logic new_val =
    if !_logic != Unsupported then (
      _logic := new_val
    )
  
  let _ignored_symbols = ref ID.Set.empty

  let mk_pred_elim_info sym =
    {
      sym; pos_cls = C.ClauseSet.empty; neg_cls = C.ClauseSet.empty; 
      offending_cls=C.ClauseSet.empty; possible_gates = C.ClauseSet.empty;
      is_gate=None; sq_var_weight=0.0; last_check=None; heap_idx=(-1); num_lits=0;
    }
  
  let _pred_sym_idx = ref ID.Map.empty

  let calc_sq_var cl =
    let n = List.length (Literals.vars (C.lits cl)) in
    float_of_int (n * n)

  let get_sym_sign lit =
    match lit with
    | L.Equation(lhs,rhs,_) ->
      let sign = L.is_pos lit in
      let is_poly = 
        not (Type.VarSet.is_empty (T.ty_vars lhs))
        || not (Type.VarSet.is_empty (T.ty_vars rhs))
      in
      if not is_poly && T.is_fo_term lhs && T.is_fo_term rhs then (
        if Type.is_prop (T.ty lhs) then (
          if L.is_predicate_lit lit then (
            let hd_sym = T.head_exn lhs in
            Some (hd_sym, sign)
          ) else (
            (* reasoning with formulas is currently unsupported *)
            Util.debugf ~section 1 "unsupported because of @[%a@]@." (fun k -> k L.pp lit);
            _logic := Unsupported;
            raise UnsupportedLogic;
        )) else (refine_logic EqFO; None)
      ) else (
        _logic := Unsupported; 
        Util.debugf ~section 1 "unsupported because of @[%a@]@." (fun k -> k L.pp lit);
        raise UnsupportedLogic)
    | L.Int _ | L.Rat _  -> 
      Util.debugf ~section 1 "theories are not supported@." CCFun.id;
      _logic := Unsupported;
      raise UnsupportedLogic
    | _ -> None

  let possibly_ignore_sym entry =
    let card s = C.ClauseSet.cardinal s in
    let possible_resolvents = 
      match entry.is_gate with
      | Some(pos_gates,neg_gates) ->
        List.length pos_gates * card entry.neg_cls +
        List.length neg_gates * card entry.pos_cls
      | None -> 
        card entry.neg_cls * card entry.pos_cls
    in
    if Env.flex_get k_max_resolvents < 0 then ()
    else (
      if possible_resolvents > Env.flex_get k_max_resolvents then (
        _pred_sym_idx := ID.Map.remove entry.sym !_pred_sym_idx;
        _ignored_symbols := ID.Set.add entry.sym !_ignored_symbols;
        if TaskSet.mem entry !_task_queue then (
          _task_queue := TaskSet.remove entry !_task_queue
        )
      )
    )
  
  let scan_cl_lits ?(handle_gates=true) cl =
    let num_vars = List.length @@ Literals.vars (C.lits cl) in
    let is_flat = function
    | L.Equation(lhs,_,_) as lit ->
      assert (L.is_predicate_lit lit);
      let args = T.args lhs in
      List.for_all T.is_var args &&
      T.Set.cardinal (T.Set.of_list args) == List.length args
    | _ -> assert false
    in

    let update_idx pos neg offending gates num_vars cl =
      let update ~action sym =
        _pred_sym_idx := ID.Map.update sym (fun old ->
          let entry = CCOpt.get_or ~default:(mk_pred_elim_info sym) old in
          begin match action with
          | `Pos ->
            entry.pos_cls <- C.ClauseSet.add cl entry.pos_cls;
          | `Neg ->
            entry.neg_cls <- C.ClauseSet.add cl entry.neg_cls;
            possibly_ignore_sym entry;
          | `Offending ->
            entry.offending_cls <- C.ClauseSet.add cl entry.offending_cls;
            if TaskSet.mem entry !_task_queue then (
               _task_queue := TaskSet.remove entry !_task_queue;
            )
          | `Gates ->
            if handle_gates then(
              entry.possible_gates <- C.ClauseSet.add cl entry.possible_gates
            )
          end;
          if action != `Gates then (
            entry.sq_var_weight <- entry.sq_var_weight +. calc_sq_var cl;
            entry.num_lits <- entry.num_lits + C.length cl
          );
          possibly_ignore_sym entry;
          if ID.Set.mem entry.sym !_ignored_symbols 
          then None 
          else Some entry
        ) !_pred_sym_idx
      in

      ID.Set.iter (update ~action:`Pos) pos;
      ID.Set.iter (update ~action:`Neg) neg;
      ID.Set.iter (update ~action:`Offending) offending;
      ID.Set.iter (update ~action:`Gates) gates;
    in

      
    let pos,neg,offending,gates = CCArray.foldi (fun ((pos,neg,offending,gates) as acc) idx lit ->
      let symbol_is_fresh sym =
        not (ID.Set.mem sym pos) && not (ID.Set.mem sym neg) &&
        not (ID.Set.mem sym offending) && not (ID.Set.mem sym !_ignored_symbols)
      in
      (match get_sym_sign lit with
      | Some (sym, sign) when symbol_is_fresh sym ->
        let is_offending = ref false in
        for i = idx+1 to (C.length cl)-1 do
          (match get_sym_sign (C.lits cl).(i) with
           | Some(sym', _) ->
             is_offending := !is_offending || ID.equal sym sym'
           | None -> () )
        done;
        if !is_offending then (
          pos,neg,ID.Set.add sym offending,gates
        ) else (
          let gates = if is_flat lit then ID.Set.add sym gates else gates in
          if sign then (ID.Set.add sym pos,neg,offending,gates)
          else (pos, ID.Set.add sym neg,offending,gates))
      | _ -> acc)
    ) (ID.Set.empty, ID.Set.empty, ID.Set.empty, ID.Set.empty) (C.lits cl) in

    update_idx pos neg offending gates num_vars cl

  let react_clause_addded cl =
  if !_logic != Unsupported then(
    scan_cl_lits ~handle_gates:false cl;
    Signal.ContinueListening
  ) else Signal.StopListening
  
  let react_clause_removed cl =
    if !_logic != Unsupported then (
      let should_retry task =
        C.ClauseSet.is_empty task.offending_cls &&
        not (ID.Set.mem task.sym !_ignored_symbols) &&
        (match task.last_check with
        | Some(old_sq_var_sum, old_num_lit) -> 
          task.sq_var_weight < old_sq_var_sum || task.num_lits < old_num_lit
        | None -> true)
      in

      let handle_gate sign task cl =
        match task.is_gate with
        | Some(pos_cls, neg_cls) ->
          if sign && CCList.mem ~eq:C.equal cl pos_cls
             || (not sign) && CCList.mem ~eq:C.equal cl neg_cls then (
            (* reintroduce gate clauses *)
            task.pos_cls <- C.ClauseSet.add_list task.pos_cls pos_cls;
            task.neg_cls <- C.ClauseSet.add_list task.neg_cls neg_cls;
            task.is_gate <- None
          )
        | None -> ()
      in

      let handled = ref ID.Set.empty in
      if not (C.ClauseSet.mem cl !_newly_added) then (
        Array.iteri (fun idx lit -> 
          match get_sym_sign lit with
          | Some(sym, sign) when not (ID.Set.mem sym !handled) ->
            let is_offending = ref false in
            for i = idx+1 to (C.length cl) -1 do
              match get_sym_sign (C.lits cl).(i) with
              | Some (sym', sign) ->
                is_offending := !is_offending || ID.equal sym sym'
              | None -> ()
            done;
            _pred_sym_idx := ID.Map.update sym (function
              | Some task ->
                task.sq_var_weight <- task.sq_var_weight -. calc_sq_var cl;
                task.num_lits <- task.num_lits - C.length cl;
                if !is_offending then (
                  task.offending_cls <- C.ClauseSet.remove cl task.offending_cls
                ) else if sign then (
                  handle_gate sign task cl;
                  task.pos_cls <- C.ClauseSet.remove cl task.pos_cls;
                ) else (
                  handle_gate sign task cl;
                  task.neg_cls <- C.ClauseSet.remove cl task.neg_cls;
                );
                if not (TaskSet.mem task !_task_queue) && should_retry task then (
                  _task_queue := TaskSet.add task !_task_queue
                );
                Some task
              | None -> None (*probably the symbol became ignored*) ) !_pred_sym_idx;
          | _ -> ()
        ) (C.lits cl));
      Signal.ContinueListening)
    else Signal.StopListening

  let replace_clauses task clauses =
    Util.debugf ~section 2 "replacing %a" (fun k -> k ID.pp task.sym); 
    Util.debugf ~section 2 "resolvents: @[%a@]@." (fun k -> k (CCList.pp C.pp) clauses);
    _ignored_symbols := ID.Set.add task.sym !_ignored_symbols;
    let remove iter =
      Env.remove_active iter;
      Env.remove_passive iter;
      Env.remove_simpl iter;
      Iter.iter (fun c -> (C.mark_redundant c);
        if C.ClauseSet.mem c !_newly_added then (
          _newly_added := C.ClauseSet.remove c !_newly_added;
          ignore (react_clause_removed c);
        )
      ) iter;
    in
    assert(C.ClauseSet.is_empty task.offending_cls);
    remove (C.ClauseSet.to_iter task.pos_cls);
    remove (C.ClauseSet.to_iter task.neg_cls);
    (match task.is_gate with
    | Some(pos_cls, neg_cls) ->
      remove (CCList.to_iter pos_cls);
      remove (CCList.to_iter neg_cls)
    | None -> ());
    (* Env.add_passive (CCList.to_iter clauses); *)
    _newly_added := C.ClauseSet.add_list !_newly_added clauses;
    List.iter (fun cl -> ignore (react_clause_addded cl)) clauses;

    _pred_sym_idx := ID.Map.remove task.sym !_pred_sym_idx

  let check_if_gate task =
    let sym = task.sym in
    let gates_l = C.ClauseSet.to_list task.possible_gates in
    let filter_gates ~sign ~lit_num_filter =
      List.filter (fun cl -> 
        lit_num_filter (Array.length (C.lits cl)) &&
        Array.exists (fun lit -> 
          match get_sym_sign lit with 
          | Some(sym', sign') -> ID.equal sym sym' && sign = sign'
          | None -> false) 
        (C.lits cl)
      ) gates_l
    in

    let find_and_or bin_clauses long_clauses =
      (* both AND and OR definitions are of the form (~)name \/ literals
         and a bunch of binary clauses (~)name \/ lit   *)
      CCList.find_map (fun long_cl ->
        let sym_lits, other_lits = List.partition (fun lit ->
          match get_sym_sign lit with
          | Some(sym',_) -> ID.equal sym sym'
          | _ -> false
        ) (CCArray.to_list @@ C.lits long_cl) in
        assert (List.length sym_lits = 1);
        let sym_name_lit = List.hd sym_lits in
        let bin_gates = CCArray.of_list bin_clauses in
        if List.length other_lits > CCArray.length bin_gates then None
        else (
          (* bit vector remembering which binary clauses we have already used *)
          let matched = CCBV.create ~size:(CCArray.length bin_gates) false in
          let is_gate = List.for_all (fun lit ->
            let found = ref false in
            let i = ref 0 in
            while not !found && !i < CCArray.length bin_gates do
              let cl = bin_gates.(!i) in
              if not (CCBV.get matched !i) then (
                let idx_name_opt = CCArray.find_idx (fun lit ->
                  match get_sym_sign lit with
                  | Some(sym',_) -> ID.equal sym sym'
                  | None -> false
                ) (C.lits cl) in
                let idx_name, _ = CCOpt.get_exn idx_name_opt in
                let name_lit = L.negate (C.lits cl).(idx_name) in
                let other_lit = L.negate (C.lits cl).(1 - idx_name) in
                let is_matched = 
                  not @@ Iter.is_empty
                    (L.variant (lit,0) (other_lit,1)
                    |> Iter.filter (fun (subst,_) -> 
                        not @@ Iter.is_empty @@ 
                          L.variant ~subst (sym_name_lit, 0) (name_lit,1)))
                in
                if is_matched then (
                  CCBV.set matched !i;
                  found := true
                ));
                incr i;
            done;
            !found
          ) other_lits in
          let bin_cls = CCBV.select matched bin_gates in
          if is_gate then Some(long_cl, bin_cls)
          else None))
      long_clauses
    in

    let check_and () =
      let pos_gates = filter_gates ~sign:true ~lit_num_filter:(fun n -> n >= 3) in
      let neg_gates = filter_gates ~sign:false ~lit_num_filter:((=) 2) in
      match find_and_or neg_gates pos_gates with
      | Some (pos_cl, neg_cls) ->
        let to_remove = C.ClauseSet.of_list (pos_cl :: neg_cls) in
        task.neg_cls <- C.ClauseSet.diff task.neg_cls to_remove;
        task.pos_cls <- C.ClauseSet.diff task.pos_cls to_remove;
        task.is_gate <- Some([pos_cl], neg_cls);
        true
      | None -> false
    in
    let check_or () =
      let pos_gates = filter_gates ~sign:true ~lit_num_filter:((=) 2) in
      let neg_gates = filter_gates ~sign:false ~lit_num_filter:(fun n -> n >= 3) in
      match find_and_or pos_gates neg_gates with
      | Some(neg_cl, pos_cls) ->
        let to_remove = C.ClauseSet.of_list (neg_cl :: pos_cls) in
        task.neg_cls <- C.ClauseSet.diff task.neg_cls to_remove;
        task.pos_cls <- C.ClauseSet.diff task.pos_cls to_remove;
        task.is_gate <- Some(pos_cls, [neg_cl]);
        true
      | None -> false
    in
    (* not yet implemented *)
    let check_ite () = false in
    ignore (check_and () || check_or () || check_ite ())

  let schedule_tasks () =
    ID.Map.iter (fun _ task -> 
      check_if_gate task;

      Util.debugf ~section 3 "initially: @[%a@]" (fun k -> k pp_task task);

      if C.ClauseSet.is_empty task.offending_cls then (
        Util.debugf ~section 3 "inserting to queue" CCFun.id;
        _task_queue := TaskSet.add task !_task_queue 
    )) !_pred_sym_idx

  let find_lit_by_sym sym sign cl =
    CCOpt.get_exn (CCArray.find_map_i (fun idx lit -> 
      match get_sym_sign lit with
      | Some (sym', sign') when ID.equal sym sym' && sign = sign' -> 
        Some (idx, CCOpt.get_exn (L.View.get_lhs lit))
      | _ -> None
    ) (C.lits cl))

  let is_tauto c =
    Literals.is_trivial (C.lits c) || Trail.is_trivial (C.trail c)

  let neq_resolver ~sym ~pos_cl ~neg_cl =
    let pos_sc, neg_sc = 0, 1 in
    let pos_idx, pos_term = find_lit_by_sym sym true pos_cl in  
    let neg_idx, neg_term = find_lit_by_sym sym false neg_cl in
    try
      let subst = Unif.FO.unify_syn (pos_term, pos_sc) (neg_term, neg_sc) in
      let renaming = Subst.Renaming.create () in
      let lits = 
        (List.map (fun lit -> 
          L.apply_subst renaming subst (lit, pos_sc)) 
        (CCArray.except_idx (C.lits pos_cl) pos_idx)) @
        (List.map (fun lit -> 
          L.apply_subst renaming subst (lit, neg_sc)) 
        (CCArray.except_idx (C.lits neg_cl) neg_idx))
      in
      let proof =
        Proof.Step.simp 
          ~tags:[Proof.Tag.T_cannot_orphan]
          ~rule:(Proof.Rule.mk "dp-resolution") 
          [C.proof_parent_subst renaming (pos_cl,pos_sc) subst;
           C.proof_parent_subst renaming (neg_cl,neg_sc) subst]
      in
      let c =
        C.create ~penalty:(max (C.penalty pos_cl) (C.penalty neg_cl))
                 ~trail:(C.trail_l [pos_cl; neg_cl]) lits proof
      in
      CCOpt.return_if (not (is_tauto c)) c
    with Unif.Fail -> None
  
  let eq_resolver ~sym ~pos_cl ~neg_cl =
    let pos_sc, neg_sc = 0, 1 in
    let renaming = Subst.Renaming.create () in
    let subst = Subst.empty in
    let pos_cl' = C.apply_subst ~renaming (pos_cl, pos_sc) subst in
    let neg_cl' = C.apply_subst ~renaming (neg_cl, neg_sc) subst in
    let pos_idx, pos_term = find_lit_by_sym sym true pos_cl' in  
    let neg_idx, neg_term = find_lit_by_sym sym false neg_cl' in
    let pos_args, neg_args = CCPair.map_same T.args (pos_term, neg_term) in
    let lits =
      (List.map (fun (p,n) -> L.mk_neq p n) (List.combine pos_args neg_args)) @ 
      (CCArray.except_idx (C.lits pos_cl') pos_idx) @
      (CCArray.except_idx (C.lits neg_cl') neg_idx)
    in
    let proof =
      Proof.Step.simp 
        ~tags:[Proof.Tag.T_cannot_orphan] 
        ~rule:(Proof.Rule.mk "dp-resolution") 
        [C.proof_parent_subst renaming (pos_cl,pos_sc) subst;
          C.proof_parent_subst renaming (neg_cl,neg_sc) subst]
    in
    let c = 
      C.create ~penalty:(max (C.penalty pos_cl') (C.penalty neg_cl'))
                ~trail:(C.trail_l [pos_cl'; neg_cl']) lits proof
    in
    CCOpt.return_if (not (is_tauto c)) c

  let get_resolver () =
    if !_logic = NEqFO then neq_resolver else eq_resolver

  let calc_resolvents ~sym ~pos ~neg =
    CCList.flat_map (fun pos_cl ->
      CCList.filter_map (fun neg_cl -> 
        get_resolver () ~sym ~pos_cl ~neg_cl
      ) neg
    ) pos 

  let do_pred_elim () =
    let process_task task =
      assert(C.ClauseSet.is_empty task.offending_cls);
      let pos_cls, neg_cls = 
        CCPair.map_same C.ClauseSet.to_list (task.pos_cls, task.neg_cls)
      in
      let sym = task.sym in
      let resolvents, pos_gates, neg_gates =
        match task.is_gate with
        | Some (pos_gates, neg_gates) ->
          ((calc_resolvents ~sym ~pos:pos_gates ~neg:neg_cls)
           @ (calc_resolvents ~sym ~pos:pos_cls ~neg:neg_gates)), pos_gates, neg_gates
        | None -> calc_resolvents ~sym ~pos:pos_cls ~neg:neg_cls, [], []
      in
      let new_sq_var_weight, new_lit_num = 
        List.fold_left (fun (acc_sq, acc_lit_num) cl -> 
          acc_sq +. calc_sq_var cl, acc_lit_num + C.length cl) (0.0, 0) resolvents
      in
      let old_clauses =
        C.ClauseSet.cardinal task.pos_cls + C.ClauseSet.cardinal task.neg_cls +
        List.length pos_gates + List.length neg_gates
      in
      if new_sq_var_weight <= task.sq_var_weight ||
         new_lit_num <= task.num_lits ||
         List.length resolvents < old_clauses then (
        Util.debugf ~section 1 "Var weight: %g / %g" (fun k -> k new_sq_var_weight task.sq_var_weight);
        Util.debugf ~section 1 "Lit num: %d / %d" (fun k -> k new_lit_num task.num_lits);
        Util.debugf ~section 1 "Clauses num: %d / %d" (fun k -> k (List.length resolvents) old_clauses);
        replace_clauses task resolvents
      ) else (
        task.last_check <- Some (task.sq_var_weight, task.num_lits)
      )
    in

    let module S = TaskSet in
    while not (S.is_empty !_task_queue) do
      let task = S.min_elt !_task_queue in
      _task_queue := S.remove task !_task_queue;
      if not (ID.Set.mem task.sym !_ignored_symbols) then(
        Util.debugf ~section 1 "checking: @[%a@]" (fun k -> k pp_task task);
        process_task (task)
      )
    done;
    
    (* storing all newly computed clauses *)
    Env.add_passive (C.ClauseSet.to_iter !_newly_added);
    _newly_added := C.ClauseSet.empty

  let steps = ref 0
  (* driver that does that every k-th step of given-clause loop *)
  let do_predicate_elimination () =
    steps := (!steps + 1) mod (Env.flex_get k_check_at);

    if !steps = 0 then do_pred_elim ()

  let initialize () =
    let init_clauses =
      C.ClauseSet.to_list (Env.ProofState.ActiveSet.clauses ())
      @ C.ClauseSet.to_list (Env.ProofState.PassiveSet.clauses ())
    in
    begin try
      Util.debugf ~section 3 "init_cl: @[%a@]@."
        (fun k -> k (CCList.pp C.pp) init_clauses);

      let init_clause_num = List.length init_clauses in

      CCFormat.printf "%% PE start: %d@." init_clause_num;
      
      List.iter (fun cl -> 
        scan_cl_lits cl;
      ) init_clauses;

      schedule_tasks ();

      Util.debugf ~section 1 "logic has%sequalities"
        (fun k -> k (if !_logic == EqFO then " " else " no "));

      Signal.on Env.ProofState.PassiveSet.on_add_clause react_clause_addded;
      Signal.on Env.ProofState.PassiveSet.on_remove_clause react_clause_removed;
      Signal.on Env.ProofState.ActiveSet.on_remove_clause react_clause_removed;

      
      Signal.on Env.on_forward_simplified (fun (c, new_state) -> 
        if !_logic != Unsupported then (
          ignore(react_clause_removed c);
          begin match new_state with
          | Some c' -> ignore(react_clause_addded c')
          | _ -> (* c is redundant *) () end;
          Signal.ContinueListening
        ) else Signal.StopListening
      );

      do_pred_elim ();

      let clause_diff =
        init_clause_num -
        (Iter.length (Env.get_active ()) + Iter.length (Env.get_passive ())) in
      CCFormat.printf "%% PE eliminated: %d@." clause_diff;

      if Env.flex_get k_inprocessing then (
        Env.add_clause_elimination_rule ~priority:2 "pred_elim" 
          do_predicate_elimination
      ) else raise UnsupportedLogic
    with UnsupportedLogic ->
      Util.debugf ~section 1 "logic is unsupported" CCFun.id;
      (* releasing possibly used memory *)
      _logic := Unsupported;
      _pred_sym_idx := ID.Map.empty
    end;
    Signal.StopListening

  let register () =
    Signal.on Env.on_start initialize
  
  let setup () =
    if Env.flex_get k_enabled then (
      if not (Env.flex_get Avatar.k_avatar_enabled) then (register ())
      else (
        CCFormat.printf "AVATAR is not yet compatible with PredElim@."
      )
    )
end

let _enabled = ref false
let _inprocessing = ref false
let _check_at = ref 10
let _max_resolvents = ref (-1)


let extension =
  let action env =
    let module E = (val env : Env.S) in
    let module PredElim = Make(E) in

    E.flex_add k_enabled !_enabled;
    E.flex_add k_check_at !_check_at;
    E.flex_add k_inprocessing !_inprocessing;
    E.flex_add k_max_resolvents !_max_resolvents;
    
    PredElim.setup ()
  in
  { Extensions.default with Extensions.
                         name="pred_elim";
                         env_actions=[action];
  }

let () =
  Options.add_opts [
    "--pred-elim", Arg.Bool ((:=) _enabled), " enable predicate elimination";
    "--pred-elim-inprocessing", Arg.Bool ((:=) _inprocessing), " predicate elimination as inprocessing rule";
    "--pred-elim-check-at", Arg.Int ((:=) _check_at), " when to perform predicate elimination inprocessing";
    "--pred-elim-max-resolvents", Arg.Int ((:=) _max_resolvents), " after how many resolvents to stop tracking a symbol";
  ]