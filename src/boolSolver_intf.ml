
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

type 'a printer = Format.formatter -> 'a -> unit

type lit = Qbf.Lit.t

let fresh_lit () = Qbf.Lit.fresh()

(** One instance of boolean solver. *)
module type SAT = sig

  type result =
    | Sat
    | Unsat

  val add_clause : ?tag:int -> lit list -> unit

  val add_clauses : ?tag:int -> lit list list -> unit

  val add_form : ?tag:int -> Qbf.Formula.t -> unit
  (** Add the given boolean formula. *)

  val add_clause_seq : ?tag:int -> lit list Sequence.t -> unit

  val check : unit -> result
  (** Is the current problem satisfiable? *)

  val valuation : lit -> bool
  (** Assuming the last call to {!check} returned {!Sat}, get the boolean
      valuation for this (positive) literal in the current model.
      @raise Invalid_argument if [lit <= 0]
      @raise Failure if the last result wasn't {!Sat} *)

  val set_printer : lit printer -> unit
  (** How to print literals? *)

  val name : string
  (** Name of the solver *)

  val unsat_core : int Sequence.t option
  (** If [Some seq], [seq] is a sequence of integers
      that are the tags used to obtain [Unsat].
      @raise Invalid_argument if the last result isn't [Unsat] *)

  (** {6 Incrementality}
  We manage a stack for backtracking to older states *)

  type save_level

  val root_save_level : save_level

  val save : unit -> save_level
  (** Save current state on the stack *)

  val restore : save_level -> unit
  (** Restore to a level below in the stack *)
end

module type QBF = sig
  include SAT

  type quantifier = Qbf.quantifier

  module LitSet : Set.S with type elt = lit
  (** Set of literals *)

  (** {2 Quantifier Stack}

  A stack of quantifiers is maintained, along with a set of literals
  at each stage. *)

  type quant_level = private int
  (** Quantification level *)

  val level0 : quant_level
  (** Level 0 is the outermost level, existentially quantified. *)

  val push : quantifier -> lit list -> quant_level
  (** Push a new level on top of the others *)

  val quantify_lit : quant_level -> lit -> unit

  val quantify_lits : quant_level -> lit list -> unit
  (** Add some literals at the given quantification level *)

  (** The functions from {!SAT}, such as {!SAT.check}, still work. They
      convert the current formulas to CNF and send the whole problem to
      the QBF solver. *)
end
