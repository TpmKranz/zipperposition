
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

(** {6 Formulas with Proofs} *)

open Logtk

type t = private {
  form : FOFormula.t;
  proof : Proof.t;
  mutable id : int;
  mutable simpl_to : t option;
}

type pform = t

val get_form : t -> FOFormula.t
val get_proof : t -> Proof.t

val eq : t -> t -> bool
val hash : t -> int
val cmp : t -> t -> int

val eq_noproof : t -> t -> bool
val cmp_noproof : t -> t -> int
  (** Compare only by formula, not by proof *)

val create : ?follow:bool -> FOFormula.t -> Proof.t -> t
  (** Create a formula from a proof. If the formula already has a proof,
      then the old proof is kept. PFormulas are hashconsed.
      @param follow follow simpl_to links if the formula has any (default false) *)

val of_sourced : ?role:string -> FOFormula.sourced_form -> t
val to_sourced : t -> FOFormula.sourced_form option

val follow_simpl : t -> t
  (** Follow the "simplify to" links until the formula has None *)

val simpl_to : from:t -> into:t -> unit
  (** [simpl_to ~from ~into] sets the link of [from] to [into], so that
      the simplification of [from] into [into] is cached. *)

val symbols : ?init:Symbol.Set.t -> t -> Symbol.Set.t

val pp : Buffer.t -> t -> unit
val pp_tstp : Buffer.t -> t -> unit
val to_string : t -> string
val fmt : Format.formatter -> t -> unit

val bij : t Bij.t

(** {2 Set of formulas} *)

(** PFormulas are compared by their formulas, not their proofs. A set
    can contain at most one proof for a given formula. *)

module Set : sig
  include Sequence.Set.S with type elt = pform

  val symbols : ?init:Symbol.Set.t -> t -> Symbol.Set.t
end
