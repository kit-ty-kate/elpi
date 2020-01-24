(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

open Util
open Data

type flags = {
  defined_variables : StrSet.t;
  allow_untyped_builtin : bool;
  print_passes : bool; (* debug *)
}
val default_flags : flags
val compiler_flags : flags State.component

val init_state : flags -> State.t

type program
type 'a query

(* Flags are threaded *)
val program_of_ast : State.t -> Ast.Program.t -> State.t * program
val query_of_ast : State.t -> program -> Ast.Goal.t -> unit query
val query_of_term :
  State.t -> program -> (depth:int -> State.t -> State.t * (Loc.t * term)) -> unit query
val query_of_data :
  State.t -> program -> Loc.t -> 'a Query.t -> 'a query
val executable_of_query : 'a query -> 'a executable
val term_of_ast : depth:int -> State.t -> Loc.t * Ast.Term.t -> State.t * term

val pp_query : (depth:int -> Format.formatter -> term -> unit) -> Format.formatter -> 'a query -> unit



type quotation = depth:int -> State.t -> Loc.t -> string -> State.t * term
val set_default_quotation : quotation -> unit
val register_named_quotation : name:string -> quotation -> unit

val lp : quotation

val is_Arg : State.t -> term -> bool
val get_Args : State.t -> term StrMap.t
val mk_Arg :
  State.t -> name:string -> args:term list ->
    State.t * term
val get_Arg : State.t -> name:string -> args:term list -> term

(* Quotes the program and the query, see elpi-quoted_syntax.elpi *)
val quote_syntax : State.t -> 'a query -> State.t * term list * term

(* false means a type error was found *)
val static_check : Ast.Program.t -> (* header *)
  exec:(unit executable -> unit outcome) ->
  ?checker:Ast.Program.t ->
  ?flags:flags ->
  'a query -> bool

module CustomFunctorCompilation : sig

  val declare_singlequote_compilation : string -> (State.t -> F.t -> State.t * term) -> unit
  val declare_backtick_compilation : string -> (State.t -> F.t -> State.t * term) -> unit

  val compile_singlequote : State.t -> F.t -> State.t * term
  val compile_backtick : State.t -> F.t -> State.t * term

  val is_singlequote : F.t -> bool
  val is_backtick : F.t -> bool

end
