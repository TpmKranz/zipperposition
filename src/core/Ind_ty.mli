
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Inductive Types} *)

(** Constructor for an inductive type *)
type constructor = {
  cstor_name: ID.t;
  cstor_ty: Type.t;
}

(** {6 Inductive Types} *)

(** An inductive type, along with its set of constructors *)
type t = private {
  id: ID.t; (* name *)
  ty_vars: Type.t HVar.t list; (* list of variables *)
  ty_pattern: Type.t; (* equal to  [id ty_vars] *)
  constructors : constructor list;
    (* constructors, all returning [pattern] and containing
       no other type variables than [ty_vars] *)
}

exception AlreadyDeclaredType of ID.t
exception NotAnInductiveType of ID.t
exception NotAnInductiveConstructor of ID.t

val declare_ty : ID.t -> ty_vars:Type.t HVar.t list -> constructor list -> t
(** Declare the given inductive type.
    @raise Failure if the type is already declared
    @raise Invalid_argument if the list of constructors is empty. *)

val declare_stmt : (_, _, Type.t, _) Statement.t -> unit
(** [declare_stmt stmt] examines [stmt], and, if the statement is a
    declaration of inductive types, it declares them using {!declare_ty}. *)

val as_inductive_ty : ID.t -> t option

val as_inductive_ty_exn : ID.t -> t
(** Unsafe version of {!as_inductive_ty}
    @raise NotAnInductiveType if the ID is not an inductive type *)

val is_inductive_ty : ID.t -> bool

val as_inductive_type : Type.t -> t option

val is_inductive_type : Type.t -> bool
(** [is_inductive_type ty] holds iff [ty] is an instance of some
    registered type (registered with {!declare_ty}). *)

(** {6 Constructors} *)

val is_constructor : ID.t -> bool
(** true if the symbol is an inductive constructor (zero, successor...) *)

val as_constructor : ID.t -> (constructor * t) option
(** if [id] is a constructor of [ity], then [as_constructor id]
    returns [Some (cstor, ity)] *)

val as_constructor_exn : ID.t -> constructor * t
(** Unsafe version of {!as_constructor}
    @raise NotAnInductiveConstructor if it fails *)

val contains_inductive_types : FOTerm.t -> bool
(** [true] iff the term contains at least one subterm with
    an inductive type *)

(**/**)

(** Exceptions used to store information in IDs *)

exception Payload_ind_type of t
exception Payload_ind_cstor of constructor * t

(**/**)