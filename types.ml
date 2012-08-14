(** Most of the useful types *)


type symbol = string

(** a sort for terms (only the return sort is kept) *)
type sort = string

(** exception raised when sorts are mismatched *)
exception SortError of string

(** hashconsed term *)
type foterm = typed_term Hashcons.hash_consed
(** term with a simple sort *)
and typed_term = {
  term : foterm_cell;   (* the term itself *)
  sort : sort;          (* the sort of the term *)
  vars : foterm list Lazy.t;   (* the variables of the term *)
}
(** content of the term *)
and foterm_cell =
  | Leaf of symbol        (** constant *)
  | Var of int            (** variable *)
  | Node of foterm list   (** term application *)

(** list of variables *)
type varlist = foterm list            

(** substitution, a list of variables -> term *)
type substitution = (foterm * foterm) list

(** partial order comparison *)
type comparison = Lt | Eq | Gt | Incomparable | Invertible

(** direction of an equation (for rewriting) *)
type direction = Left2Right | Right2Left | Nodir

(** position in a term *)
type position = int list

(** a literal, that is, a signed equation *)
type literal = 
 | Equation of    foterm  (* lhs *)
                * foterm  (* rhs *)
                * bool    (* sign *)
                * comparison (* orientation *)

(** a hashconsed first order clause *)
type hclause = clause Hashcons.hash_consed
(** a first order clause (TODO add selected literals?) *)
and clause = {
  clits : literal list;     (** the equations *)
  cvars : foterm list;      (** the free variables *)
  cproof : proof Lazy.t;    (** the proof for this clause (lazy...) *)
}
(** a proof step for a clause *)
and proof = Axiom of string
          | Proof of string * (clause * position * substitution) list

(** the interface of a total ordering on symbols *)
class type symbol_ordering =
  object
    method refresh : unit -> symbol_ordering  (** refresh the signature *)
    method signature : symbol list            (** current symbols in decreasing order *)
    method compare : symbol -> symbol -> int  (** total order on symbols *)
    method weight : symbol -> int             (** weight of symbol *)
  end

(** the interface of an ordering type *)
class type ordering =
  object
    method symbol_ordering : symbol_ordering
    method compare : foterm -> foterm -> comparison
    method compute_clause_weight : clause -> int
    method name : string
  end

exception UnificationFailure of string Lazy.t
