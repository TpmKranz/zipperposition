
(*
Zipperposition: a functional superposition prover for prototyping
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Polynomes of order 1, over several variables}. *)

open Logtk

module T = FOTerm
module S = Symbol

type t = {
  coeffs : Symbol.t T.Map.t;
  constant : Symbol.t;
  divby : Symbol.t;  (* divide everything by this constant (cool for ints) *)
}

let eq m1 m2 =
  Symbol.eq m1.constant m2.constant &&
  Symbol.eq m1.divby m2.divby &&
  T.Map.equal Symbol.eq m1.coeffs m2.coeffs

let compare m1 m2 =
  Util.lexicograph_combine
    [ Symbol.compare m1.constant m2.constant
    ; Symbol.compare m1.divby m2.divby
    ; T.Map.compare Symbol.compare m1.coeffs m2.coeffs
    ]

let hash m =
  Hash.hash_int3
    (Symbol.hash m.constant)
    (Symbol.hash m.divby)
    (T.Map.fold
      (fun t coeff acc -> Hash.hash_int3 acc (Symbol.hash coeff) (T.hash t))
      m.coeffs 13)

let const constant =
  assert (S.is_numeric constant);
  {
    coeffs = T.Map.empty;
    constant;
    divby = S.Arith.one_of_ty (S.Arith.typeof constant);
  }

let singleton ?divby coeff t =
  if S.Arith.is_zero coeff
    then const coeff  (* 0 *)
    else
      let coeffs = T.Map.singleton t coeff in
      let constant = S.Arith.zero_of_ty (S.Arith.typeof coeff) in
      let divby = match divby with
      | Some d -> d
      | None -> S.Arith.one_of_ty (S.Arith.typeof coeff)
      in
      { coeffs; constant; divby; }

let of_list constant l =
  let divby = S.Arith.one_of_ty (S.Arith.typeof constant) in
  let coeffs = List.fold_left
    (fun m (coeff, t) ->
      if S.Arith.is_zero coeff
        then m
        else T.Map.add t coeff m)
    T.Map.empty l
  in
  { constant; coeffs; divby; }

let pp buf monome =
  Buffer.add_char buf '(';
  T.Map.iter
    (fun t coeff -> Printf.bprintf buf "%a×%a +" S.pp coeff T.pp t)
    monome.coeffs;
  S.pp buf monome.constant;
  if S.Arith.is_one monome.divby
    then Buffer.add_char buf ')'
    else Printf.bprintf buf ")/%a" S.pp monome.divby

let to_string monome = Util.on_buffer pp monome

let fmt fmt m = Format.pp_print_string fmt (to_string m)

let mem m t = T.Map.mem t m.coeffs

let find m t = T.Map.find t m.coeffs

let add m coeff t =
  (* compute sum of coeffs for [t], if need be *)
  let c =
    try
      let coeff' = T.Map.find t m.coeffs in
      S.Arith.Op.sum coeff coeff'
    with Not_found -> coeff
  in
  if S.Arith.is_zero c
    then {m with coeffs=T.Map.remove t m.coeffs;}
    else {m with coeffs=T.Map.add t c m.coeffs;}

let remove m t =
  { m with coeffs=T.Map.remove t m.coeffs; }

let type_of m = S.Arith.typeof m.constant

let is_constant m = T.Map.is_empty m.coeffs

let sign m =
  if not (is_constant m) then invalid_arg "sign: require constant monome";
  assert (S.Arith.sign m.divby > 0);
  S.Arith.sign m.constant

let terms m =
  T.Map.fold (fun t coeff acc -> t :: acc) m.coeffs []

let to_list m =
  T.Map.fold (fun t coeff acc -> (coeff,t) :: acc) m.coeffs []

let var_occurs v m =
  List.exists (fun t -> T.var_occurs v t) (terms m)

(* scale: multiply all coeffs by constant, multiply divby by same constant.
  This yields the very same monome *)
let _scale m c =
  assert (S.is_numeric c);
  assert (not (S.Arith.is_zero c));
  assert (S.Arith.sign m.divby > 0);
  if S.Arith.is_one c
    then m  (* same monome *)
    else
      let c = S.Arith.Op.abs c in
      let constant = S.Arith.Op.product c m.constant in
      let coeffs = T.Map.map (fun c' -> S.Arith.Op.product c c') m.coeffs in
      let divby = S.Arith.Op.product m.divby c in
      { constant; coeffs; divby; }

let normalize m = match m.constant with
  | S.Int _ ->
    (* divide by common gcd of coeffs and divby *)
    let gcd = S.Arith.Op.gcd m.constant m.divby in
    let gcd = T.Map.fold (fun _ c gcd -> S.Arith.Op.gcd c gcd) m.coeffs gcd in
    let constant = S.Arith.Op.quotient m.constant gcd in
    let coeffs = T.Map.map (fun c' -> S.Arith.Op.quotient c' gcd) m.coeffs in
    let divby = S.Arith.Op.quotient m.divby gcd in
    { constant; coeffs; divby; }
  | S.Rat _
  | S.Real _ ->
    (* multiply by 1/divby *)
    let constant = S.Arith.Op.quotient m.constant m.divby in
    let coeffs = T.Map.map (fun c' -> S.Arith.Op.quotient c' m.divby) m.coeffs in
    let one = S.Arith.one_of_ty (S.Arith.typeof m.constant) in
    { constant; coeffs; divby=one; }
  | _ -> assert false

(* reduce to same divby (same denominator) *)
let reduce_same_divby m1 m2 =
  match m1.divby, m2.divby with
  | S.Int n1, S.Int n2 ->
    let gcd = Big_int.gcd_big_int n1 n2 in
    assert (Big_int.sign_big_int n1 > 0);
    assert (Big_int.sign_big_int n2 > 0);
    assert (Big_int.sign_big_int gcd > 0);
    (* n1 × n2 = gcd × lcm, so we need to raise both n1 and n2 to lcm.
       to do that, let us introduce  n1 = gcd × d1, and n2 = gcd × d2.
       Then
          n1 × d2 = gcd × d1 × d2, and
          n2 × d1 = gcd × d2 × d1
       so we multiply m1 by d2, and m2 by d1.
    *)
    let d1 = S.mk_bigint (Big_int.div_big_int n1 gcd) in
    let d2 = S.mk_bigint (Big_int.div_big_int n2 gcd) in
    Util.debug 5 "reduce same divby: %a, %a have gcd %s, mult by %a, %a"
      pp m1 pp m2 (Big_int.string_of_big_int gcd) S.pp d2 S.pp d1;
    _scale m1 d2, _scale m2 d1
  | c1, c2 ->
    (* reduce m1 / c1 and m2 / c2 to same denominator. We choose c2
       arbitrarily, so we need to scale m1 with c2/c1. *)
    _scale m1 (S.Arith.Op.quotient c2 c1), m2

let sum m1 m2 =
  let m1, m2 = reduce_same_divby m1 m2 in
  let constant = S.Arith.Op.sum m1.constant m2.constant in
  let coeffs = T.Map.merge
    (fun t c1 c2 -> match c1, c2 with
    | None, Some c
    | Some c, None -> Some c
    | Some c1, Some c2 ->
      let c = S.Arith.Op.sum c1 c2 in
      if S.Arith.is_zero c
        then None
        else Some c
    | None, None -> assert false)
    m1.coeffs m2.coeffs
  in
  { m1 with constant; coeffs; }

let difference m1 m2 =
  let m1, m2 = reduce_same_divby m1 m2 in
  let constant = S.Arith.Op.difference m1.constant m2.constant in
  let coeffs = T.Map.merge
    (fun t c1 c2 -> match c1, c2 with
    | None, Some c -> Some (S.Arith.Op.uminus c)
    | Some c, None -> Some c
    | Some c1, Some c2 ->
      let c = S.Arith.Op.difference c1 c2 in
      if S.Arith.is_zero c
        then None
        else Some c
    | None, None -> assert false)
    m1.coeffs m2.coeffs
  in
  { m1 with constant; coeffs; }

let uminus m =
  let constant = S.Arith.Op.uminus m.constant in
  let coeffs = T.Map.map S.Arith.Op.uminus m.coeffs in
  { m with constant; coeffs; }

(* product by constant *)
let product m c =
  if S.Arith.is_zero c
    then const c  (* 0 *)
  else if S.Arith.Op.divides c m.divby && S.Arith.sign c > 0
    then { m with divby = S.Arith.Op.quotient m.divby c }
  else  (* itemwise product *)
    let constant = S.Arith.Op.product m.constant c in
    let coeffs = T.Map.map (fun c' -> S.Arith.Op.product c c') m.coeffs in
    { m with constant; coeffs; }

let divby m const =
  assert (S.Arith.sign const >= 0);
  if S.Arith.is_zero const
    then raise Division_by_zero
  else
    let divby = S.Arith.Op.product const m.divby in
    normalize { m with divby; }

let succ m =
  let one = S.Arith.one_of_ty (S.Arith.typeof m.constant) in
  sum m (const one)

let pred m =
  let one = S.Arith.one_of_ty (S.Arith.typeof m.constant) in
  difference m (const one)

exception NotLinear
  (** Used by [of_term] *)

let of_term ~signature t =
  let rec of_term ~signature t = match t.T.term with
  | T.Node (s, [t1; t2]) when S.eq s S.Arith.sum ->
    let m1 = of_term ~signature t1 in
    let m2 = of_term ~signature t2 in
    sum m1 m2
  | T.Node (s, [t1; t2]) when S.eq s S.Arith.difference ->
    let m1 = of_term ~signature t1 in
    let m2 = of_term ~signature t2 in
    difference m1 m2
  | T.Node (s, [t']) when S.eq s S.Arith.uminus ->
    let m = of_term ~signature t' in
    uminus m
  | T.Node (s, [{T.term=T.Node (s',[])}; t2])
    when S.eq s S.Arith.product && S.is_numeric s' ->
    let m = of_term ~signature t2 in
    product m s'
  | T.Node (S.Const("$succ",_), [t']) ->
    let m = of_term ~signature t' in
    succ m
  | T.Node (S.Const("$pred",_), [t']) ->
    let m = of_term ~signature t' in
    pred m
  | T.Node (s, [t2; {T.term=T.Node (s',[])}])
    when S.eq s S.Arith.product && S.is_numeric s' ->
    let m = of_term ~signature t2 in
    product m s'
  | T.Node (s, [t2; {T.term=T.Node (s',[])}])
    when S.eq s S.Arith.quotient && S.is_numeric s' && not (S.Arith.is_zero s') ->
    let m = of_term ~signature t2 in
    divby m s'
  | T.Node (s, []) when S.is_numeric s -> const s
  | T.Node (s, [_; _]) when S.Arith.is_arith s ->
    raise NotLinear  (* failure *)
  | T.Var _
  | T.BoundVar _ ->
    let ty = match t.T.type_ with Some ty -> ty | None -> assert false in
    let one = S.Arith.one_of_ty ty in
    singleton one t
  | T.Node _ ->
    let ty = TypeInference.FO.infer_sig signature t in
    let one = S.Arith.one_of_ty ty in
    singleton one t
  in
  try of_term ~signature t
  with Symbol.Arith.TypeMismatch msg ->
    raise NotLinear  (* too hard. *)

let of_term_opt ~signature t =
  try Some (of_term ~signature t)
  with NotLinear -> None
    
let to_term m =
  let add x y = T.mk_node S.Arith.sum [x;y] in
  let add_sym s x = if S.Arith.is_zero s then x else add (T.mk_const s) x in
  let prod s x = if S.Arith.is_one s then x
    else T.mk_node S.Arith.product [T.mk_const s; x]
  in
  let sum =
    if T.Map.is_empty m.coeffs
      then T.mk_const m.constant (* constant *)
    else
      (* remove one coeff to make the basic sum *)
      let t, c = T.Map.choose m.coeffs in
      let map = T.Map.remove t m.coeffs in
      let sum = prod c t in
      (* add coeff*term for the remaining terms *)
      let sum = T.Map.fold
        (fun t' coeff sum ->
          assert (not (S.Arith.is_zero coeff));
          add sum (prod coeff t'))
        map sum 
      in
      (* add the constant (if needed) *)
      add_sym m.constant sum
  in
  if S.Arith.is_one m.divby
    then sum
    else T.mk_node S.Arith.quotient [sum; T.mk_const m.divby]

(** {2 Satisfiability} *)

let has_instances m =
  let res = match m.constant with
  | S.Real _
  | S.Rat _ -> true
  | S.Int _ ->
    if S.Arith.is_one m.divby
      then true  (* gcd is one, always true *)
      else
        let g = T.Map.fold (fun _ c g -> S.Arith.Op.gcd c g) m.coeffs m.divby in
        S.Arith.Op.divides g m.constant
  | _ -> assert false
  in
  Util.debug 5 "monome %a has instances: %B" pp m res;
  res

let total_expression m =
  let m = normalize m in
  let res = match m.constant with
  | S.Real _
  | S.Rat _ -> true
  | S.Int _ ->
    (* either divby is 1, or the monome is an integer constant *)
    S.Arith.is_one m.divby ||
    (T.Map.is_empty m.coeffs && S.Arith.Op.divides m.divby m.constant)
  | _ -> assert false
  in
  Util.debug 5 "monome %a is a total expression: %B" pp m res;
  res

let floor m = match m.constant with
  | S.Int _ when T.Map.is_empty m.coeffs ->
    (* m = m.constant / m.divby *)
    let constant = S.Arith.Op.quotient_f m.constant m.divby in
    let one = S.Arith.one_i in
    { m with constant; divby=one; }
  | _ -> m

let ceil m =
match m.constant with
  | S.Int _ when T.Map.is_empty m.coeffs ->
    (* m = m.constant / m.divby *)
    let constant = match m.constant, m.divby with
    | S.Int a, S.Int b ->
      let q, r = Big_int.quomod_big_int a b in
      if Big_int.sign_big_int b = 0
        then S.mk_bigint q
        else S.mk_bigint (Big_int.succ_big_int q)  (* round up! *)
    | _ -> assert false
    in
    let one = S.Arith.one_i in
    { m with constant; divby=one; }
  | _ -> m

(** {2 Lib} *)

let bij =
  Bij.(map
    ~inject:to_term
    ~extract:(fun t ->
      let tyctx = TypeInference.Ctx.create () in
      ignore (TypeInference.FO.infer tyctx t);
      let signature = TypeInference.Ctx.to_signature tyctx in
      of_term ~signature t)
    T.bij)

(* arbitrary instance for the given constant generators *)
let _arbitrary_for ty any any_nonzero =
  let open QCheck.Arbitrary in
  0 -- 3 >>= fun n ->
  list_repeat n (pair any_nonzero (T.arbitrary_ty ty)) >>= fun terms ->
  any >>= fun constant ->
  any_nonzero >>= fun divby ->
  let m = of_list constant terms in
  return { m with divby; }

let arbitrary_int =
  QCheck.Arbitrary.(
    let any_int = lift Symbol.mk_int small_int in
    let any_int_nonzero = lift Symbol.mk_int (1 -- 10) in
    _arbitrary_for Type.int any_int any_int_nonzero)

let arbitrary_rat =
  QCheck.Arbitrary.(
    let any_rat = lift2 Symbol.mk_rat small_int (1 -- 10) in
    let any_rat_nonzero = lift2 Symbol.mk_rat (1 -- 50) (1 -- 10) in
    _arbitrary_for Type.rat any_rat any_rat_nonzero)

let arbitrary =
  QCheck.Arbitrary.choose [ arbitrary_int; arbitrary_rat ]
