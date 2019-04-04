module T = Term
module US = Unif_subst
module H = HVar


exception NotUnifiable
exception NotInFragment


type subst = US.t

module S = struct

  let apply s t = Subst.FO.apply Subst.Renaming.none (US.subst s) t

  let apply_ty s ty = Subst.Ty.apply Subst.Renaming.none (US.subst s) ty
  let pp = US.pp

end

let unif_simple ?(subst=Subst.empty) ~scope t s = 
  try 
    let type_unifier = Unif.FO.unify_syn ~subst (t, scope) (s, scope) in
    Some (US.of_subst type_unifier)
  with Unif.Fail -> None

let cast_var v subst sc =
  let ty = Term.ty v in
  if Type.is_ground ty then v
  else (
    match T.view v with
    | T.Var x -> T.var (HVar.cast x ~ty:(S.apply_ty subst (ty, sc)))
    | T.DB i  -> T.bvar ~ty:(S.apply_ty subst (ty, sc)) i
    | _ -> v
  ) 

let vars_equal x y = HVar.equal (fun _ _ -> false) x y

(* Make new list of constraints, prefering the rigid-rigid pairs *)
let build_constraints args1 args2 rest = 
  let zipped = List.combine args1 args2 in
  let rigid, non_rigid = List.partition (fun (s,t) ->
    T.is_const (T.head_term s) && T.is_const (T.head_term t)) zipped in
  rigid @ rest @ non_rigid


(* Given two terms and their lambda prefixes, η-expands one of the terms, if 
   necessary, to have the same size of the lambda prefix as the other term *)
let eta_expand_otf pref1 pref2 t1 t2 =
  let do_exp_otf n types t = 
    let remaining = CCList.drop n types in
    assert(List.length remaining != 0);
    let num_vars = List.length remaining in
    let vars = List.mapi (fun i ty -> T.bvar ~ty (num_vars-1-i)) remaining in
    let shifted = T.DB.shift num_vars t in
    T.app shifted vars in 

  if List.length pref1 = List.length pref2 then (t1, t2, pref1)
  else (
    let n1, n2 = List.length pref1, List.length pref2 in 
    if n1 < n2 then (
      (do_exp_otf n1 pref2 t1,t2,pref2)
    ) else (
      assert(n1 > n2);
      (t1,do_exp_otf n2 pref1 t2,pref1)
    )
  )

let cmp (i, _) (j, _) = compare i j

(* To avoid rather expensive η-reduction of variable arguments,
   we check if arguments actually are only bound variables *)
let rec eligible_arg t =
  match T.view t with
  | T.AppBuiltin _ | T.Const _ | T.Var _ -> false
  | T.DB _ -> true
  | T.Fun (_, body) -> eligible_arg body
  | T.App (f, l) -> eligible_arg f &&
                    List.for_all eligible_arg l

(* If all arguments can be reduced to distinct bound variables we convert
   them to `Some map` where map is the sorted association list that maps de
   Bruijn index of the bound variable to a term that is de Bruijn index of i-th
   argument of a variable

   For example, if args are  [1, 0, 3] we map it to `Some [(0, T.bvar 1); (1,
   T.bvar 2); (3, T.bvar 0)]`.

   If arguments are not all distinct bound variables -- None is returned *)
let get_bvars args =
  let reduced = 
    List.map 
      (fun t -> if (eligible_arg t) then (Lambda.eta_quick_reduce t) else t) 
                (*Lambda.eta_quick_reduce t*)
    args in
  let n = List.length reduced in
  if List.for_all T.is_bvar reduced then (
    let res = List.mapi 
      (fun i a -> (Term.as_bvar_exn a, T.bvar ~ty:(Term.ty a) (n-1-i))) 
      reduced in
    let no_dup = CCList.sort_uniq ~cmp res in
      if List.length no_dup = List.length res 
      then Some (CCArray.of_list no_dup)
      else None) 
  else None

(* Dereference and normalize the head of the term *)
let rec norm_deref subst (t,sc) =
  let pref, tt = T.open_fun t in
  let t' =  
    begin match T.view tt with
      | T.Var _ ->
        let u, _ = US.FO.deref subst (tt,sc) in
        if T.equal tt u then u
        else norm_deref subst (u,sc)
      | T.App (f0, l) ->
        let f = norm_deref subst (f0, sc) in
        let t =
          if T.equal f0 f then tt else T.app f l in
        let u = Lambda.whnf t in
        if T.equal t u
        then t
        else norm_deref subst (u,sc)
      | _ -> tt
    end in
  if T.equal tt t' then t
  else T.fun_l pref t'

(* Given variable var, its bound variables in bvar_map, and a target term t
   return (t',s) where 
    -s is the substitution that prunes away non-unifiable substerms of t
    -t' is the term var should be bound to

  Extends the pattern unification since the constraints are only put
  on variable (which has to be applied to a sequence of distinct bound
  variables). The target term can be any term.  
   *)
let rec build_term ?(depth=0) ~subst ~scope ~counter var bvar_map t =
  let args_same args new_args = 
    List.for_all2 (fun s t -> 
      try 
        let t = CCOpt.get_exn t in
        Term.equal s t
      with Invalid_argument _ -> false
    ) args new_args in

  let t = Lambda.whnf t in
  match T.view t with
  | T.Var _ ->
    let t = cast_var t subst scope in 
    let t' = fst @@ US.FO.deref subst (t,scope) in
    if T.equal t' t then (
      if T.equal var t then raise (Failure "occurs check")
      else (cast_var t subst scope, subst)
    ) 
    else build_term ~depth ~subst ~scope ~counter var bvar_map t'  
  | T.Const _ -> (t, subst)
  | T.App (hd, args) ->
      if T.is_var hd then (
        let old_hd = hd in
        let hd = cast_var hd subst scope in
        if T.equal hd var then
            raise (Failure "Occurs check!");
        (* If the variable is not yet bound, try to bind to target subterm.
           If it is bound then dereference and try again. *)
        if not (US.FO.mem subst (Term.as_var_exn hd, scope)) then (
          let new_args, subst =
          List.fold_right (fun arg (l, subst) -> (
            try (
              let arg', subst = build_term ~depth ~subst ~scope ~counter 
                                            var bvar_map arg in
              Some arg' :: l, subst)
            with  Failure _ ->  None :: l, subst)) 
          args ([], subst) in
          (* While dealing with arguments of variable, we might have bound it.
             Think of F (F 0) for example. If we have bound it, then we need
             to dereference and try again. If we have not then we prune
             away the arguments that cound not be unified.*)
          if not (US.FO.mem subst (Term.as_var_exn hd, scope)) then (
            let pref_types = List.map (fun t-> S.apply_ty subst (Term.ty t, scope)) args in
            let n = List.length pref_types in
            let ret_type = Type.apply_unsafe (Term.ty old_hd) (args :> InnerTerm.t list) in
            let ret_type = S.apply_ty subst (ret_type, scope) in
            let matrix = 
              CCList.filter_map (fun x->x) (List.mapi (fun i opt_arg -> 
                (match opt_arg with
                | Some arg -> Some (T.bvar ~ty:(Term.ty arg) (n-i-1))
                | None -> None)) new_args) in
            if List.length matrix != List.length new_args then (
              let ty = Type.arrow (List.map Term.ty matrix) ret_type in
              let new_hd = T.var @@ H.fresh_cnt ~counter ~ty () in
              let hd_subs = T.fun_l pref_types (T.app new_hd matrix) in
              let subst = US.FO.bind subst (T.as_var_exn hd, scope) (hd_subs, scope) in
              let res_term = T.app new_hd (CCList.filter_map (fun x->x) new_args) in
              res_term, subst
            ) 
            else (
              if T.equal hd old_hd && args_same args new_args then (t,subst)
              else T.app hd (CCList.filter_map (fun x->x) new_args), subst)
          )
          else (
            let hd',_ =  US.FO.deref subst (hd, scope) in
            let t' = T.app hd' args in
            build_term ~depth ~subst ~scope ~counter var bvar_map t' 
          )
        )
        else (
          let hd',_ =  US.FO.deref subst (hd, scope) in
          let t' = T.app hd' args in
          build_term ~depth ~subst ~scope ~counter var bvar_map t' 
        )
      ) else (
        let new_hd, subst = build_term ~depth ~subst ~scope ~counter var bvar_map hd in 
        let new_args, subst =
        List.fold_right (fun arg (l, subst) ->
          let arg', subst = build_term ~depth ~subst ~scope ~counter var bvar_map arg in
          arg' :: l, subst 
        ) args ([], subst) in
        if T.equal new_hd hd && List.for_all2 T.equal args new_args then t,subst
        else T.app new_hd new_args, subst
      )
  | T.Fun(ty, body) -> 
    let b', subst = build_term ~depth:(depth+1) ~subst ~scope ~counter var bvar_map body in
    let new_ty = S.apply_ty subst (ty,scope) in
    if T.equal b' body && Type.equal new_ty ty then t,subst
    else T.fun_ new_ty  b', subst
  | T.DB i -> 
    if i < depth then cast_var t subst scope,subst
    else (
      (* Check which argument of the applied variable a
         given bound variable correspodns to.  *)
      match CCArray.bsearch ~cmp (i-depth, Term.true_) bvar_map with
      | `At idx -> 
        let val_,bvar = CCArray.get bvar_map idx in
        let bvar = cast_var bvar subst scope in
        assert(val_ = (i-depth));
        T.DB.shift depth bvar, subst
      | _ -> raise (Failure "Bound variable not argument to head")
    )
  | T.AppBuiltin(_,_) -> 
      raise (Failure "Trying to bind to a predicate")

let rec unify ~scope ~counter ~subst = function
  | [] -> subst
  | (s,t) :: rest -> (
    let ty_unif = unif_simple ~subst:(US.subst subst) ~scope 
                  (T.of_ty (T.ty s)) (T.of_ty (T.ty t)) in
    
    if CCOpt.is_none ty_unif then
      raise NotUnifiable;
    
    let ty_unif = CCOpt.get_exn ty_unif in
    let subst = US.merge subst ty_unif in
    let s', t' = norm_deref subst (s,scope), norm_deref subst (t,scope) in

    if not (Term.equal s' t') then (
      let pref_s, body_s = T.open_fun s' in
      let pref_t, body_t = T.open_fun t' in 
      let body_s', body_t', _ = eta_expand_otf pref_s pref_t body_s body_t in
      let hd_s, args_s = T.as_app body_s' in
      let hd_t, args_t = T.as_app body_t' in
      let hd_s, hd_t = CCPair.map_same (fun t -> cast_var t subst scope) (hd_s, hd_t) in

      match T.view hd_s, T.view hd_t with 
      | (T.Var x, T.Var y) ->
        let subst =
          (if vars_equal x y then
            flex_same ~counter ~scope ~subst hd_s args_s args_t
          else
            flex_diff ~counter ~scope ~subst hd_s hd_t args_s args_t) in
        unify ~scope ~counter ~subst rest
      | (T.Var _, T.Const _) | (T.Var _, T.DB _) ->
        let subst = flex_rigid ~subst ~counter ~scope  body_s' body_t' in
        unify ~scope ~counter ~subst rest
      | (T.Const _, T.Var _) | (T.DB _, T.Var _) ->
        let subst = flex_rigid ~subst ~counter ~scope  body_t' body_s' in
        unify ~scope ~counter ~subst rest
      | T.Const f , T.Const g when ID.equal f g && List.length args_s = List.length args_t ->
        (* assert(List.length args_s = List.length args_t); *)
        unify ~subst ~counter ~scope @@ build_constraints args_s args_t rest
      | T.DB i, T.DB j when i = j && List.length args_s = List.length args_t ->
        (* assert (List.length args_s = List.length args_t); *)
        unify ~subst ~counter ~scope @@ build_constraints args_s args_t rest
      | _ -> raise NotUnifiable) 
    else (
      unify ~subst ~counter ~scope rest
    )
  )

(* Flex-flex pairs with the same head can be solved only if they are applied
   only to a sequence of distinct bound variables.

   We solve them pruning away the arguments that do not appear at the
   same position.
   
   For example, X 0 3 1 =?= X 1 3 2 is solved by {X -> λλλ. Y 1} *) 
and flex_same ~counter ~scope ~subst var args_s args_t =
  let bvar_s, bvar_t = get_bvars args_s, get_bvars args_t in
  if CCOpt.is_none bvar_s || CCOpt.is_none bvar_t then
    raise NotInFragment;
  
  let bvar_s, bvar_t = CCOpt.get_exn bvar_s, CCOpt.get_exn bvar_t in
  let v = Term.as_var_exn var in
  let ret_ty = Type.apply_unsafe (Term.ty var) (args_s :> InnerTerm.t list) in
  let bvars = 
    CCList.filter_map (fun x->x)
    (CCArray.mapi (fun i si ->
      if si = CCArray.get bvar_t i then Some (snd si) else None) bvar_s
     |> CCArray.to_list) in
  let v_ty = Type.arrow (List.map T.ty bvars) ret_ty in
  let matrix = Term.app (Term.var (H.fresh_cnt ~counter ~ty:v_ty ())) bvars in
  let res_term = Term.fun_l (List.map Term.ty args_s) matrix in
  let subst = US.FO.bind subst (v, scope) (res_term, scope) in  
  subst

(* Flex-flex pairs with the different heads can be solved only if they are applied
   only to a sequence of distinct bound variables.

   We solve them pruning away the arguments that are not in the intersection of the
   arguemnts applied to either variable. The remaining arguments can be
   supplied in any order.
   
   For example, X 0 3 1 =?= Y 1 3 2 5 is solved by 
    {X -> λλλ. Z 1 0, Y -> λλλλ. Z 2 0 } *)
and flex_diff ~counter ~scope ~subst var_s var_t args_s args_t =
  let bvar_s, bvar_t = get_bvars args_s, get_bvars args_t in
  if CCOpt.is_none bvar_s || CCOpt.is_none bvar_t then
    raise NotInFragment;
  
  let bvar_s, bvar_t = CCOpt.get_exn bvar_s, CCOpt.get_exn bvar_t in
  let new_bvars = 
    CCArray.filter_map (fun x->x) (
      CCArray.map (fun si -> 
        match CCArray.bsearch ~cmp (fst si, Term.true_) bvar_t  with
        | `At idx -> Some (cast_var (snd si) subst scope, 
                           cast_var (snd @@ CCArray.get bvar_t idx) subst scope)
        | _ -> None
      ) bvar_s
    ) 
    |> CCArray.to_list in
  let arg_types = List.map (fun (b1, _) -> Term.ty b1) new_bvars in
  let ret_ty = 
    Type.apply_unsafe (Term.ty var_s) 
      (List.map (fun t -> 
        cast_var (Lambda.eta_quick_reduce t) subst scope) args_s :> InnerTerm.t list) in
  let new_var_ty = Type.arrow arg_types ret_ty in
  let new_var = Term.var @@ H.fresh_cnt ~counter ~ty:new_var_ty () in
  let matrix_s = Term.app new_var (List.map fst new_bvars) in
  let matrix_t = Term.app new_var (List.map snd new_bvars) in
  let subs_s = Term.fun_l (List.map Term.ty args_s) matrix_s in
  let subs_t = Term.fun_l (List.map Term.ty args_t) matrix_t in
  let v_s, v_t = Term.as_var_exn var_s, Term.as_var_exn var_t in
  let subst = US.FO.bind subst (v_s, scope) (subs_s, scope) in
  let subst = US.FO.bind subst (v_t, scope) (subs_t, scope) in
  subst  

(* Flex-rigid pairs can be solved if variable is applied to a sequence
   of distinct bound variables. IMPORTANT: Such a requirement is NOT
   imposed on subterms of rigid side.

   For more information see `build_term`.
*)
and flex_rigid ~subst ~counter ~scope flex rigid =
  let hd, args = Term.as_app flex in
  assert(Term.is_var hd);

  let bvars = get_bvars args in
  if CCOpt.is_none bvars then
    raise NotInFragment;

  let bvars = CCOpt.get_exn bvars in
  try
    let matrix, subst = 
      build_term ~subst ~scope ~counter (cast_var hd subst scope) bvars rigid in
    let new_subs_val = T.fun_l (List.map Term.ty args) matrix in
    US.FO.bind subst (T.as_var_exn hd, scope) (new_subs_val, scope)
  with Failure _ -> raise NotUnifiable
 
  
let unify_scoped ?(subst=US.empty) ?(counter = ref 0) t0_s t1_s =
  if US.is_empty subst then (
    let t0',t1',scope,subst = US.FO.rename_to_new_scope ~counter t0_s t1_s in
    unify ~scope ~counter ~subst [(t0', t1')]
  )
  else (
    if Scoped.scope t0_s != Scoped.scope t1_s then (
      raise (Invalid_argument "scopes should be the same")
    )
    else (
      let t0', t1' = S.apply subst t0_s, S.apply subst t1_s in
      unify ~scope:(Scoped.scope t0_s) ~counter ~subst [(t0', t1')]
    )
  )