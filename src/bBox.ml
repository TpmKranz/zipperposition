
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


module T = Logtk.FOTerm
module Util = Logtk.Util
module Lits = Literals
module StringTbl = CCHashtbl.Make(struct
  type t = string
  let hash = CCString.hash
  let equal = CCString.equal
end)

module type S = BBox_intf.S

let section = Util.Section.make ~parent:Const.section "bbox"

module Make(Any : sig end) = struct
  type bool_lit = int
  type inductive_cst = T.t

  let neg i = -i
  let sign i = i>=0
  let set_sign sign i =
    if sign then (abs i) else - (abs i)

  [@@@warning "-39"]

  (** Predicate attached to a set of literals *)
  type lits_predicate =
    | TrailOk (** Some trail that proves lits is true *)
    [@@deriving ord]

  type ctx_predicate =
    | InLoop (** lits = ctx[i], where ctx in loop(i) *)
    | InitOk (** Ctx is initialized *or* it's not in loop *)
    | ExpressesMinimality
    | ExpressesMinimalityAux
    [@@deriving ord]

  type injected =
    | Clause_component of Literals.t
    | Lits of Literals.t * lits_predicate
    | Ctx of ClauseContext.t * (inductive_cst [@compare T.cmp]) * ctx_predicate
    | Name of string  (* name for CNF *)
    [@@deriving ord]

  let string_of_lits_pred lits = function
    | TrailOk -> Util.sprintf "⟦trail_ok(%a)⟧" Lits.pp lits

  let string_of_ctx_pred ctx i = function
    | InLoop -> Util.sprintf "⟦%a ∈ loop(%a)⟧" ClauseContext.pp ctx T.pp i
    | InitOk ->
        Util.sprintf "⟦%a initialized(%a)⟧" ClauseContext.pp ctx T.pp i
    | ExpressesMinimality ->
        Util.sprintf "⟦loop(%a) minimal by %a⟧" T.pp i ClauseContext.pp ctx
    | ExpressesMinimalityAux ->
        Util.sprintf "⟦loop(%a) minimal by %a (aux)⟧" T.pp i ClauseContext.pp ctx

  let pp_injected buf = function
    | Clause_component lits ->
        Printf.bprintf buf "⟦%a⟧" (Util.pp_array ~sep:" ∨ " Literal.pp) lits
    | Lits (lits, pred) ->
        let s = string_of_lits_pred lits pred in
        Buffer.add_string buf s
    | Ctx (lits, ind, pred) ->
        let s = string_of_ctx_pred lits ind pred in
        Buffer.add_string buf s
    | Name s ->
        Printf.bprintf buf "⟦%s⟧" s

  module FV = Logtk.FeatureVector.Make(struct
    type t = Lits.t * injected * bool_lit
    let cmp (l1,i1,j1)(l2,i2,j2) =
      CCOrd.(Lits.compare l1 l2 <?> (compare_injected, i1, i2) <?> (int_, j1, j2))
    let to_lits (l,_,_) = Lits.Seq.abstract l
  end)
  module ITbl = Hashtbl.Make(CCInt)

  let _next = ref 1 (* next lit *)
  let _clause_set = ref (FV.empty())
  let _lit2inj = ITbl.create 56
  let _names = StringTbl.create 15

  let _fresh () =
    let i = !_next in
    incr _next;
    i

  let _apply_sign sign b =
    if sign then b else neg b

  let _retrieve_alpha_equiv lits =
    let dummy_injected = Clause_component lits in
    let dummy_bool_lit = 1 in
    FV.retrieve_alpha_equiv_c !_clause_set (lits,dummy_injected,dummy_bool_lit) ()
      |> Sequence.map2 (fun _ l -> l)

  let _save injected bool_lit =
    ITbl.add _lit2inj bool_lit injected;
    Util.debug ~section 4 "save bool_lit %d = %a" bool_lit pp_injected injected;
    match injected with
    | Clause_component lits
    | Lits (lits, _) ->
        (* also be able to retrieve by lits *)
        _clause_set := FV.add !_clause_set (lits, injected, bool_lit)
    | Ctx (cc, cst, _) ->
        _clause_set := FV.add !_clause_set
          (ClauseContext.apply cc cst, injected, bool_lit)
    | Name s ->
        StringTbl.add _names s (injected, bool_lit)


  (* clause -> boolean lit *)
  let inject_lits lits  =
    (* special case: one negative literal. *)
    let lits, sign =
      if Array.length lits = 1 && Literal.is_neq lits.(0)
        then [| Literal.negate lits.(0) |], false
        else lits, true
    in
    (* retrieve clause. the index doesn't matter for retrieval *)
    _retrieve_alpha_equiv lits
      |> Sequence.filter_map
        (function
          | lits', Clause_component _, blit when Lits.are_variant lits lits' ->
              Some blit
          | _ -> None
        )
      |> Sequence.head
      |> (function
          | Some bool_lit -> _apply_sign sign bool_lit
          | None ->
              let i = _fresh() in
              (* maintain mapping *)
              let lits_copy = Array.copy lits in
              _save (Clause_component lits_copy) i;
              _apply_sign sign i
          )

  let inject_lits_pred lits pred =
    _retrieve_alpha_equiv lits
      |> Sequence.filter_map
        (function
          | lits', Lits (_, pred'), blit
            when Lits.are_variant lits lits'
            && compare_lits_predicate pred pred' = 0 -> Some blit
          | _ -> None
        )
      |> Sequence.head
      |> (function
          | Some blit -> blit
          | None ->
              let i = _fresh() in
              (* maintain mapping *)
              let lits_copy = Array.copy lits in
              _save (Lits (lits_copy, pred)) i;
              i
          )

  let inject_ctx ctx t pred =
    let lits = ClauseContext.apply ctx t in
    _retrieve_alpha_equiv lits
      |> Sequence.filter_map
        (function
          | lits', Ctx (_, t', pred'), blit
            when Lits.are_variant lits lits'
            && T.eq t t' && compare_ctx_predicate pred pred' = 0 -> Some blit
          | _ -> None
        )
      |> Sequence.head
      |> (function
          | Some blit -> blit
          | None ->
              let i = _fresh() in
              (* maintain mapping *)
              _save (Ctx (ctx, t, pred)) i;
              i
          )

  let inject_name s =
    try snd (StringTbl.find _names s)
    with Not_found ->
      let i = _fresh () in
      _save (Name s) i;
      i

  let inject_name' fmt =
    let buf = Buffer.create 16 in
    Printf.kbprintf
      (fun _ -> inject_name (Buffer.contents buf))
      buf fmt

  (* boolean lit -> injected *)
  let extract i =
    if i<=0 then failwith "BBox.extract: require integer > 0";
    try Some (ITbl.find _lit2inj i)
    with Not_found -> None

  let extract_exn i =
    if i<=0 then failwith "BBox.extract: require integer > 0";
    try ITbl.find _lit2inj i
    with Not_found -> failwith "BBox.extact: not a proper injected lit"

  let inductive_cst b = match extract_exn b with
    | Name _
    | Clause_component _ -> None
    | Lits (_, pred) ->
        begin match pred with
        | TrailOk -> None
        end
    | Ctx (_, t, _) -> Some t

  let pp buf i =
    if i<0 then Buffer.add_string buf "¬";
    let i = abs i in
    match extract i with
    | None -> Printf.bprintf buf "L%d" i
    | Some inj -> pp_injected buf inj

  let print fmt i =
    if i<0 then Format.pp_print_string fmt "¬";
    let i = abs i in
    match extract i with
    | None -> Format.fprintf fmt "L%d" i
    | Some (Clause_component lits) ->
        Format.fprintf fmt "@[⟦%a⟧@]"
          (CCArray.print ~sep:" ∨ " Literal.fmt) lits
    | Some (Lits (lits, pred)) ->
        let s = string_of_lits_pred lits pred in
        Format.pp_print_string fmt s
    | Some (Ctx (lits, ind, pred)) ->
        let s = string_of_ctx_pred lits ind pred in
        Format.pp_print_string fmt s
    | Some (Name s) ->
        Format.fprintf fmt "⟦%s⟧" s
end
