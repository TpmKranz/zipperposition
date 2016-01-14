
(* This file is free software, part of Libzipperposition. See file "license" for more details. *)

(** {1 Global CLI options}

    Those options can be used by any program that parses command
    line arguments using the standard module {!Arg}. It may modify some
    global parameters, and return a parameter type for other options.
*)

val stats : bool ref
(** Enable printing of statistics? *)

val output : [`Normal | `TPTP] ref
(** Output format *)

val make : unit -> (string * Arg.spec * string) list
(** Produce of list of options suitable for {!Arg.parse}, that may
    modify global parameters and the given option reference. *)
