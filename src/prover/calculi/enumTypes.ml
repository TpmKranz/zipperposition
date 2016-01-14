
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Inference and simplification rules for Algebraic types} *)

open Libzipperposition

module T = FOTerm
module S = Substs
module Lit = Literal
module Lits = Literals

type term = T.t

let prof_detect = Util.mk_profiler "enum_types.detect"
let prof_instantiate = Util.mk_profiler "enum_types.instantiate_vars"

let stat_declare = Util.mk_stat "enum_types.declare"
let stat_simplify = Util.mk_stat "enum_types.simplify"
let stat_instantiate = Util.mk_stat "enum_types.instantiate_axiom"

let section = Util.Section.make ~parent:Const.section "enum_ty"

(** {2 Inference rules} *)

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  val declare_type : proof:Proof.t -> ty:Type.t -> var:Type.t HVar.t -> term list -> unit
  (** Declare that the given type's domain is the given list of cases
      for the given variable [var] (whose type must be [ty].
      Will be ignored if the type already has a enum declaration. *)

  val instantiate_vars : Env.multi_simpl_rule
  (** Instantiate variables whose type is a known enumerated type,
      with all variables of this type. *)

  (** {6 Registration} *)

  val register : unit -> unit
  (** Register rules in the environment *)
end

let _enable = ref true
let _instantiate_shielded = ref false
let _accept_unary_types = ref false

module Make(E : Env.S) = struct
  module Env = E
  module C = Env.C
  module PS = Env.ProofState
  module Ctx = Env.Ctx

  type decl = {
    decl_ty : Type.t;
    decl_var : Type.t HVar.t;
    decl_cases : term list;
    decl_proof : Proof.t;
    mutable decl_symbols : ID.Set.t; (* set of declared symbols *)
  }

  (* set of enumerated types *)
  let _decls = ref []

  let on_new_decl = Signal.create ()

  (* find whether some declaration matches this type, and return it *)
  let _find_match ?(subst=S.empty) s_decl ty s_ty =
    CCList.find
      (fun decl ->
         try
           let subst = Unif.Ty.matching ~subst ~pattern:(decl.decl_ty,s_decl) (ty,s_ty) in
           Some (decl, subst)
         with Unif.Fail -> None)
      !_decls

  (* check that [var] is the only free variable in all cases *)
  let _check_uniq_var_cond ~var cases =
    List.for_all
      (fun t -> T.Seq.vars t |> Sequence.for_all (HVar.equal var))
      cases

  (* declare an enumerated type *)
  let _declare ~ty ~var ~proof cases =
    if List.exists (fun t -> not (Type.equal ty (T.ty t))) cases
    then failwith "EnumTypes: invalid declaration (type mismatch)";
    if Type.is_var ty
    then failwith "EnumTypes: cannot declare enum for type variable";
    if not (_check_uniq_var_cond ~var cases)
    then failwith "EnumTypes: invalid declaration (free variables)";
    if List.exists (fun decl -> Unif.Ty.are_variant ty decl.decl_ty) !_decls
    then (
      Util.debugf ~section 3 "@[an enum is already declared for type %a@]" (fun k->k Type.pp ty);
      false
    ) else (
      Util.debugf ~section 1 "@[<2>declare new enum type @[%a@]@ @[(cases %a = %a)@]"
        (fun k->k Type.pp ty HVar.pp var (Util.pp_list ~sep:"|" T.pp) cases);
      Util.incr_stat stat_declare;
      (* set of already declared symbols *)
      let decl_symbols = List.fold_left
          (fun set t -> match T.head t with
             | None -> failwith "EnumTypes: non-symbolic case?"
             | Some s -> ID.Set.add s set
          ) ID.Set.empty cases
      in
      let decl = {
        decl_ty=ty;
        decl_var=var;
        decl_cases=cases;
        decl_symbols;
        decl_proof=proof;
      } in
      _decls := decl :: !_decls;
      Signal.send on_new_decl decl;
      true
    )

  let declare_type ~proof ~ty ~var enum =
    ignore (_declare ~proof ~ty ~var enum)

  (* TODO: require that the type is as general as possible: either
     a constant, or a polymorphic type that has only type variables as
     arguments. Enum types for things like [list(int)] are dangerous
     because if we remove the clause, since instantiation is a
     simplification, we won't deal properly with [list(rat)] (no unification
     whatsoever) *)

  (* detect whether the clause [c] is a declaration of enum type *)
  let _detect_declaration c =
    let eq_var_ ~var t = match T.view t with
      | T.Var v' -> HVar.equal var v'
      | _ -> false
    and get_var_ t = match T.view t with
      | T.Var v -> v
      | _ -> assert false
    in
    Util.enter_prof prof_detect;
    (* loop over literals checking whether they are all of the form
       [var = t] for some [t] *)
    let rec _check_all_vars ~ty ~var acc lits = match lits with
      | [] ->
          (* now also check that no case has free variables other than [var],
              and that there are at least 2 cases *)
          if _check_uniq_var_cond ~var acc
          && (!_accept_unary_types || List.length acc >= 2)
          then Some (ty, var, acc)
          else None
      | Lit.Equation (l, r, true) :: lits' when eq_var_ ~var l ->
          _check_all_vars ~ty ~var (r::acc) lits'
      | Lit.Equation (l, r, true) :: lits' when eq_var_ ~var r ->
          _check_all_vars ~ty ~var (l::acc) lits'
      | _ -> None
    in
    let res = match Array.to_list (C.lits c) with
      | Lit.Equation (l,r,true) :: lits when T.is_var l && not (Type.is_var (T.ty l))->
          let var = get_var_ l in
          _check_all_vars ~ty:(T.ty l) ~var [r] lits
      | Lit.Equation (l,r,true) :: lits when T.is_var r && not (Type.is_var (T.ty r))->
          let var = get_var_ r in
          _check_all_vars ~ty:(T.ty r) ~var [l] lits
      | _ -> None
    in
    Util.exit_prof prof_detect;
    res

  (* retrieve variables that are directly under a positive equation *)
  let _vars_under_eq lits =
    Sequence.of_array lits
    |> Sequence.filter Lit.is_eq
    |> Sequence.flatMap Lit.Seq.terms
    |> Sequence.filter T.is_var

  (* variables occurring under some function symbol (at non-0 depth) *)
  let _shielded_vars lits =
    Sequence.of_array lits
    |> Sequence.flatMap Lit.Seq.terms
    |> Sequence.flatMap T.Seq.subterms_depth
    |> Sequence.fmap
      (fun (v,depth) ->
         if depth>0 && T.is_var v then Some v else None
      )
    |> T.Seq.add_set T.Set.empty

  let _naked_vars lits =
    let v =
      _vars_under_eq lits
      |> T.Seq.add_set T.Set.empty
    in
    T.Set.diff v (_shielded_vars lits)
    |> T.Set.elements

  let instantiate_vars c =
    Util.enter_prof prof_instantiate;
    (* which variables are candidate? depends on a CLI flag *)
    let vars =
      if !_instantiate_shielded
      then _vars_under_eq (C.lits c) |> Sequence.to_rev_list
      else _naked_vars (C.lits c)
    in
    let s_c = 0 and s_decl = 1 in
    let res = CCList.find
        (fun v ->
           match _find_match s_decl (T.ty v) s_c with
           | None -> None
           | Some (decl, subst) ->
               (* we found an enum type declaration for [v], replace it
                  with each case for the enum type *)
               Util.incr_stat stat_simplify;
               Some (
                 List.map
                   (fun case ->
                      (* replace [v] with [case] now *)
                      let subst = Unif.FO.unification ~subst (v,s_c) (case,s_decl) in
                      let renaming = S.Renaming.create () in
                      let lits' = Lits.apply_subst ~renaming subst (C.lits c,s_c) in
                      let proof cc = Proof.mk_c_inference ~info:[S.to_string subst]
                          ~rule:"enum_type_case_switch" cc [C.proof c]
                      in
                      let trail = C.trail c in
                      let c' = C.create_a ~trail lits' proof in
                      Util.debugf ~section 3
                        "@[<2>deduce @[%a@]@ from @[%a@]@ @[(enum_type switch on %a)@]@]"
                        (fun k->k C.pp c' C.pp c Type.pp decl.decl_ty);
                      c'
                   ) decl.decl_cases
               )
        ) vars
    in
    Util.exit_prof prof_instantiate;
    res

  let _make_term_of_sym s ty =
    match Type.arity ty with
    | Type.Arity(0,0)
    | Type.NoArity ->
        T.const ~ty s
    | Type.Arity (i,_) ->
        let ty_vars = if i>0 then CCList.range 1 i |> List.map Type.var_of_int else [] in
        let ty' = Type.apply ty ty_vars in
        let ty_args = Type.expected_args ty' in
        let vars = List.mapi (fun i ty -> T.var_of_int ~ty i) ty_args in
        T.app_full (T.const ~ty s) ty_vars vars

  (* check whether the given symbol's return type unifies with the declaration.
     If it does, return a new clause (instance) *)
  let check_decl_ ~ty s decl =
    let t = _make_term_of_sym s ty in
    try
      (* can we unify a generic instancez of [s] (the term [t]) with
         the declaration's variable? *)
      (* TODO call occur-check instead and bind variable *)
      let subst = Unif.FO.unification (t,0) (T.var decl.decl_var,1) in
      if ID.Set.mem s decl.decl_symbols then None
      else (
        (* need to add an axiom instance for this symbol and declaration *)
        decl.decl_symbols <- ID.Set.add s decl.decl_symbols;
        (* create the axiom *)
        let renaming = S.Renaming.create () in
        let lits =
          List.map
            (fun case ->
              Lit.mk_eq
                (S.FO.apply ~renaming subst (t,0))
                (S.FO.apply ~renaming subst (case,1)))
            decl.decl_cases
        in
        let proof cc = Proof.mk_c_inference
            ~rule:"axiom_enum_types" cc [decl.decl_proof] in
        let trail = Trail.empty in
        let c' = C.create ~trail lits proof in
        Util.debugf ~section 3 "@[<2>declare enum type for @[%a@]:@ clause @[%a@]@]"
          (fun k->k ID.pp s C.pp c');
        Util.incr_stat stat_instantiate;
        Some c'
      )
    with Unif.Fail | Exit ->
      None

  (* add axioms for new symbol [s] with type [ty], if needed *)
  let _on_new_symbol s ~ty =
    let clauses =
      CCList.filter_map
        (fun decl -> check_decl_ ~ty s decl)
        !_decls
    in
    PS.PassiveSet.add (Sequence.of_list clauses)

  let _on_new_decl decl =
    let clauses =
      Signature.fold (Ctx.signature ()) []
        (fun acc s ty ->
           match check_decl_ s ~ty decl with
           | None -> acc
           | Some c -> c::acc
        )
    in
    PS.PassiveSet.add (Sequence.of_list clauses)

  (* flag for clauses that are declarations of enumerated types *)
  let flag_enumeration_clause = C.new_flag ()

  let is_trivial c =
    C.get_flag flag_enumeration_clause c

  let register () =
    if !_enable then begin
      Util.debug ~section  1 "register handling of enumerated types";
      Env.add_multi_simpl_rule instantiate_vars;
      Env.add_is_trivial is_trivial;
      (* signals: instantiate axioms upon new symbols, or when new
          declarations are added *)
      Signal.on Ctx.on_new_symbol
        (fun (s, ty) ->
           _on_new_symbol s ~ty;
           Signal.ContinueListening
        );
      Signal.on on_new_decl
        (fun decl ->
           _on_new_decl decl;
           (* need to simplify (instantiate) active clauses that have naked
              variables of the given type *)
           Env.simplify_active_with instantiate_vars;
           Signal.ContinueListening);
      Signature.iter (Ctx.signature ()) (fun s ty -> _on_new_symbol s ~ty);
      (* detect whether the clause is a declaration of enum type, and if it
          is, declare the type! *)
      let _detect_and_declare c =
        begin match _detect_declaration c with
          | None -> ()
          | Some (ty,var,cases) ->
              let is_new = _declare ~ty ~var ~proof:(C.proof c) cases in
              (* clause becomes redundant if it's a new declaration *)
              if is_new then C.set_flag flag_enumeration_clause c true
        end; Signal.ContinueListening
      in
      Signal.on PS.PassiveSet.on_add_clause _detect_and_declare;
      Signal.on PS.ActiveSet.on_add_clause _detect_and_declare;
    end
end

(* TODO: during preprocessing, scan clauses to find declarations asap *)

(** {2 As Extension} *)

let extension =
  let register env =
    let module E = (val env : Env.S) in
    let module ET = Make(E) in
    ET.register ()
  in
  { Extensions.default with
    Extensions.name = "enum_types";
    Extensions.actions=[Extensions.Do register];
  }

let () =
  Extensions.register extension;
  Params.add_opts
    [ "--enum-types"
      , Arg.Bool (fun b -> _enable := b)
      , " enable/disable special handling for enumerated types"
    ; "--enum-shielded"
      , Arg.Bool (fun b -> _instantiate_shielded := b)
      , " enable/disable instantiation of shielded variables of enum type"
    ; "--enum-unary"
      , Arg.Bool (fun b -> _accept_unary_types := b)
      , " enable/disable support for unary enum types (one case)"
    ]