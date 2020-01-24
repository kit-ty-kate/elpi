(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1 or later           *)
(* ------------------------------------------------------------------------- *)

(* Internal term representation *)

module Fmt = Format
module F = Ast.Func
open Util

(******************************************************************************
  Terms: data type definition and printing
 ******************************************************************************)

(* Heap and Stack
 *
 * We use the same data type (term) the following beasts:
 *   preterm = Pure term <= Heap term <= Stack term
 *
 * - only Stack terms can contain Arg nodes
 * - Heap terms can contain UVar nodes
 * - Pure terms contain no Arg and no UVar nodes
 * - a preterm is a Pure term that may contain "%Arg3" constants.  These
 *   constants morally represent Arg nodes
 *
 * Preterms are only used during compilation.  Beta-reduction, needed for
 * macro expansion for example, is only defined on Heap terms.  We hence
 * separate the compilation of clauses into:
 *   AST -> preterm -> term -> clause
 *
 * Heap and Stack terms are used during execution. The query if the
 * root of Heap terms, clauses are Stack terms and are eventually copied
 * to the Heap.
 * Invariant: a Heap term never points to a Stack term.
 *
 *)

module Term = struct

(* Used by pretty printers, to be later instantiated in module Constants *)
let pp_const = mk_spaghetti_printer ()
type constant = int (* De Bruijn levels *)
[@printer (pp_spaghetti pp_const)]
[@@deriving show, eq]

(* To be instantiated after the dummy term is defined *)
let pp_oref = mk_spaghetti_printer ()

let id_term = UUID.make ()
type term =
  (* Pure terms *)
  | Const of constant
  | Lam of term
  | App of constant * term * term list
  (* Optimizations *)
  | Cons of term * term
  | Nil
  | Discard
  (* FFI *)
  | Builtin of constant * term list
  | CData of CData.t
  (* Heap terms: unif variables in the query *)
  | UVar of uvar_body * (*depth:*)int * (*argsno:*)int
  | AppUVar of uvar_body * (*depth:*)int * term list
  (* Clause terms: unif variables used in clauses *)
  | Arg of (*id:*)int * (*argsno:*)int
  | AppArg of (*id*)int * term list
and uvar_body = {
  mutable contents : term [@printer (pp_spaghetti_any ~id:id_term pp_oref)];
  mutable rest : stuck_goal list [@printer fun _ _ -> ()]
                                 [@equal fun _ _ -> true];
}
and stuck_goal = {
  mutable blockers : blockers;
  kind : stuck_goal_kind;
}
and blockers = uvar_body list
and stuck_goal_kind =
 | Constraint of constraint_def
 | Unification of unification_def 
and unification_def = {
  adepth : int;
  env : term array;
  bdepth : int;
  a : term;
  b : term;
  matching: bool;
}
and constraint_def = {
  cdepth : int;
  prog : prolog_prog [@equal fun _ _ -> true]
               [@printer (fun fmt _ -> Fmt.fprintf fmt "<prolog_prog>")];
  context : clause_src list;
  conclusion : term;
}
and clause_src = { hdepth : int; hsrc : term }
and prolog_prog = {
  src : clause_src list; (* hypothetical context in original form, for CHR *)
  index : index;
}
and index = second_lvl_idx Ptmap.t
and second_lvl_idx =
| TwoLevelIndex of {
    mode : mode;
    argno : int; 
    all_clauses : clause list;         (* when the query is flexible *)
    flex_arg_clauses : clause list;       (* when the query is rigid but arg_id ha nothing *)
    arg_idx : clause list Ptmap.t;   (* when the query is rigid (includes in each binding flex_arg_clauses) *)
  }
| BitHash of {
    mode : mode;
    args : int list;
    time : int; (* time is used to recover the total order *)
    args_idx : (clause * int) list Ptmap.t; (* clause, insertion time *)
  }
and clause = {
    depth : int;
    args : term list;
    hyps : term list;
    vars : int;
    mode : mode; (* CACHE to avoid allocation in get_clause *)
}
and mode = bool list (* true=input, false=output *)
[@@deriving show, eq]

type constraints = stuck_goal list
type hyps = clause_src list
type extra_goals = term list

type indexing =
  | MapOn of int
  | Hash of int list
[@@deriving show]

let mkLam x = Lam x [@@inline]
let mkApp c x xs = App(c,x,xs) [@@inline]
let mkCons hd tl = Cons(hd,tl) [@@inline]
let mkNil = Nil
let mkDiscard = Discard
let mkBuiltin c args = Builtin(c,args) [@@inline]
let mkCData c = CData c [@@inline]
let mkUVar r d ano = UVar(r,d,ano) [@@inline]
let mkAppUVar r d args = AppUVar(r,d,args) [@@inline]
let mkArg i ano = Arg(i,ano) [@@inline]
let mkAppArg i args = AppArg(i,args) [@@inline]

module C = struct

  let { CData.cin = in_int; isc = is_int; cout = out_int } as int =
    Ast.cint
  let is_int = is_int
  let to_int = out_int
  let of_int x = CData (in_int x)

  let { CData.cin = in_float; isc = is_float; cout = out_float } as float =
    Ast.cfloat
  let is_float = is_float
  let to_float = out_float
  let of_float x = CData (in_float x)
  
  let { CData.cin = in_string; isc = is_string; cout = out_string } as string =
    Ast.cstring
  let is_string = is_string
  let to_string x = out_string x
  let of_string x = CData (in_string x)

  let loc = Ast.cloc
  let is_loc = loc.CData.isc
  let to_loc = loc.CData.cout
  let of_loc x = CData (loc.CData.cin x)

end

let destConst = function Const x -> x | _ -> assert false

(* Our ref data type: creation and dereference.  Assignment is defined
   After the constraint store, since assigning may wake up some constraints *)
let oref x = { contents = x; rest = [] }
let (!!) { contents = x } = x

(* Arg/AppArg point to environments, here the empty one *)
type env = term array
let empty_env = [||]
end
include Term


(* Object oriented State.t: borns at compilation time and survives as run time *)
module State : sig

  (* filled in with components *)
  type 'a component
  val declare :
    name:string -> pp:(Format.formatter -> 'a -> unit) ->
    init:(unit -> 'a) ->
    clause_compilation_is_over:('a -> 'a) ->
    goal_compilation_is_over:(args:uvar_body StrMap.t -> 'a -> 'a option) ->
    compilation_is_over:('a -> 'a option) ->
     'a component

  (* an instance of the State.t type *)
  type t

  val init : unit -> t
  val end_clause_compilation : t -> t
  val end_goal_compilation : uvar_body StrMap.t -> t -> t
  val end_compilation : t -> t
  val get : 'a component -> t -> 'a
  val set : 'a component -> t -> 'a -> t
  val drop : 'a component -> t -> t
  val update : 'a component -> t -> ('a -> 'a) -> t
  val update_return : 'a component -> t -> ('a -> 'a * 'b) -> t * 'b
  val pp : Format.formatter -> t -> unit

end = struct

  type t = Obj.t StrMap.t

  type 'a component = string
  type extension = {
    init : unit -> Obj.t;
    end_clause : Obj.t -> Obj.t;
    end_goal : args:uvar_body StrMap.t -> Obj.t -> Obj.t option;
    end_comp : Obj.t -> Obj.t option;
    pp   : Format.formatter -> Obj.t -> unit;
  }
  let extensions : extension StrMap.t ref = ref StrMap.empty

  let get name t =
    try Obj.obj (StrMap.find name t)
    with Not_found ->
       anomaly ("State.get: component " ^ name ^ " not found")

  let set name t v = StrMap.add name (Obj.repr v) t
  let drop name t = StrMap.remove name t
  let update name t f =
    StrMap.add name (Obj.repr (f (Obj.obj (StrMap.find name t)))) t
  let update_return name t f =
    let x = get name t in
    let x, res = f x in
    let t = set name t x in
    t, res

  let declare ~name ~pp ~init ~clause_compilation_is_over ~goal_compilation_is_over ~compilation_is_over =
    if StrMap.mem name !extensions then
      anomaly ("Extension "^name^" already declared");
    extensions := StrMap.add name {
        init = (fun x -> Obj.repr (init x));
        pp = (fun fmt x -> pp fmt (Obj.obj x));
        end_goal = (fun ~args x -> option_map Obj.repr (goal_compilation_is_over ~args (Obj.obj x)));
        end_clause = (fun x -> Obj.repr (clause_compilation_is_over (Obj.obj x)));
        end_comp = (fun x -> option_map Obj.repr (compilation_is_over (Obj.obj x)));
      }
      !extensions;
    name

  let init () =
    StrMap.fold (fun name { init } -> StrMap.add name (init ()))
      !extensions StrMap.empty

  let end_clause_compilation m =
    StrMap.fold (fun name obj acc ->
      let o = (StrMap.find name !extensions).end_clause obj in
      StrMap.add name o acc) m StrMap.empty

  let end_goal_compilation args m =
    StrMap.fold (fun name obj acc ->
      match (StrMap.find name !extensions).end_goal ~args obj with
      | None -> acc
      | Some o -> StrMap.add name o acc) m StrMap.empty

  let end_compilation m =
    StrMap.fold (fun name obj acc ->
      match (StrMap.find name !extensions).end_comp obj with
      | None -> acc
      | Some o -> StrMap.add name o acc) m StrMap.empty

  let pp fmt t =
    StrMap.iter (fun name { pp } ->
      try pp fmt (StrMap.find name t)
      with Not_found -> ())
    !extensions

end

let elpi_initialized = ref false

let while_compiling = State.declare ~name:"elpi:compiling"
  ~pp:(fun fmt _ -> ())
  ~clause_compilation_is_over:(fun b -> b)
  ~goal_compilation_is_over:(fun ~args:_ b -> Some b)
  ~compilation_is_over:(fun _ -> Some false)
  ~init:(fun () -> false)

module Symbols : sig

  (* Table used at runtime *)
  type t
  val current_table : t Fork.local_ref

  (* Table used at compilation time *)
  type t_comp
  val table : t_comp State.component

  (* Read the table after OCaml module initialization *)
  val static_table : unit -> t_comp

  (* Compile the symbol table *)
  val compile : t_comp -> t


  (* Static initialization, eg link time *)
  val declare_global_symbol : string -> constant

  val cutc     : constant
  val andc     : constant
  val orc      : constant
  val implc    : constant
  val rimplc   : constant
  val pic      : constant
  val sigmac   : constant
  val eqc      : constant
  val rulec    : constant
  val consc    : constant
  val nilc     : constant
  val entailsc : constant
  val nablac   : constant
  val asc      : constant
  val arrowc   : constant
  val uvarc    : constant
  val propc    : constant

  val ctypec   : constant
  val variadic : constant

  val spillc   : constant
  val truec    : constant

  val declare_constraintc : constant
  val print_constraintsc  : constant

  (* Compilation phase *)
  val allocate_global_symbol     : State.t -> F.t -> State.t * (constant * term)
  val allocate_global_symbol_str : State.t -> string -> State.t * constant
  val allocate_Arg_symbol        : State.t -> int -> State.t * constant
  val allocate_bound_symbol      : State.t -> int -> State.t * term
  val get_global_or_allocate_bound_symbol        : State.t -> int -> State.t * term
  val get_canonical              : State.t -> int -> term
  val get_global_symbol          : State.t -> F.t -> constant * term
  val get_global_symbol_str      : State.t -> string -> constant * term
  val show                       : State.t -> constant -> string

  (* Private (Runtime) *)
  val __show : constant -> string
  val __get_global : F.t -> constant
  val __get_global_str : string -> constant
  val __mkConst : int -> term
  val __fresh_global_constant : unit -> constant * term

end = struct

type t = {
  (* Ast (functor name) -> negative int n (constant) * hashconsed (Const n) *)
  ast2ct : (F.t, constant * term) Hashtbl.t;
  (* constant -> string *)
  c2s : (constant, string) Hashtbl.t;
(* constant n -> hashconsed (Const n) *)
  c2t : (constant, term) Hashtbl.t;
  mutable last_global : int;
}
[@@deriving show]

let empty_table () = {
  last_global = 0;
  ast2ct = Hashtbl.create 37;
  c2s = Hashtbl.create 37;
  c2t = Hashtbl.create 17;
}

let current_table = Fork.new_local (empty_table ())

type t_comp = {
  cc_ast2ct : (constant * term) F.Map.t;
  cc_c2s : string IntMap.t;
  cc_c2t : term IntMap.t;
  cc_last_global : int;
}
[@@deriving show]

let static_table () =
  let { ast2ct; c2s; c2t; last_global } = !current_table in
  {
    cc_ast2ct = Hashtbl.fold F.Map.add ast2ct F.Map.empty;
    cc_c2s = Hashtbl.fold IntMap.add c2s IntMap.empty;
    cc_c2t = Hashtbl.fold IntMap.add c2t IntMap.empty;
    cc_last_global = last_global;
  }

let compile { cc_ast2ct; cc_c2s; cc_c2t; cc_last_global } =
  let t = empty_table () in
  IntMap.iter (Hashtbl.add t.c2s) cc_c2s;
  IntMap.iter (Hashtbl.add t.c2t) cc_c2t;
  F.Map.iter (Hashtbl.add t.ast2ct) cc_ast2ct;
  t.last_global <- cc_last_global;
  t


let table = State.declare ~name:"elpi:compiler:table"
  ~pp:pp_t_comp
  ~clause_compilation_is_over:(fun x -> x)
  ~goal_compilation_is_over:(fun ~args:_ x -> Some x)
  ~compilation_is_over:(fun _ -> None)
  ~init:static_table

let declare_global_symbol x =
  if !elpi_initialized then anomaly ("global symbols cannot be declared after initialization");
  let x = F.from_string x in
  try fst (Hashtbl.find !current_table.ast2ct x)
  with Not_found ->
    !current_table.last_global <- !current_table.last_global - 1;
    let n = !current_table.last_global in
    let xx = Term.Const n in
    let p = n,xx in
    Hashtbl.add !current_table.c2s n (F.show x);
    Hashtbl.add !current_table.c2t n xx;
    Hashtbl.add !current_table.ast2ct x p;
    n

let andc                = declare_global_symbol F.(show andf)
let arrowc              = declare_global_symbol F.(show arrowf)
let asc                 = declare_global_symbol "as"
let consc               = declare_global_symbol F.(show consf)
let cutc                = declare_global_symbol F.(show cutf)
let entailsc            = declare_global_symbol "?-"
let eqc                 = declare_global_symbol F.(show eqf)
let uvarc               = declare_global_symbol "uvar"
let implc               = declare_global_symbol F.(show implf)
let nablac              = declare_global_symbol "nabla"
let nilc                = declare_global_symbol F.(show nilf)
let orc                 = declare_global_symbol F.(show orf)
let pic                 = declare_global_symbol F.(show pif)
let rimplc              = declare_global_symbol F.(show rimplf)
let rulec               = declare_global_symbol "rule"
let sigmac              = declare_global_symbol F.(show sigmaf)
let spillc              = declare_global_symbol F.(show spillf)
let truec               = declare_global_symbol F.(show truef)
let ctypec              = declare_global_symbol F.(show ctypef)
let propc               = declare_global_symbol "prop"
let variadic            = declare_global_symbol "variadic"
let declare_constraintc = declare_global_symbol "declare_constraint"
let print_constraintsc  = declare_global_symbol "print_constraints"

let allocate_global_symbol state x =
  if not (State.get while_compiling state) then anomaly ("global symbols can only be allocated during compilation");
  State.update_return table state
    (fun ({ cc_c2s; cc_c2t; cc_ast2ct; cc_last_global } as table) ->
      try table, F.Map.find x cc_ast2ct
      with Not_found ->
        let cc_last_global = cc_last_global - 1 in
        let n = cc_last_global in
        let xx = Term.Const n in
        let p = n,xx in
        let cc_c2s = IntMap.add n (F.show x) cc_c2s in
        let cc_c2t = IntMap.add n xx cc_c2t in
        let cc_ast2ct = F.Map.add x p cc_ast2ct in
        { cc_c2s; cc_c2t; cc_ast2ct; cc_last_global }, p)

let allocate_global_symbol_str st x =
  let x = F.from_string x in
  let st, (c,_) = allocate_global_symbol st x in
  st, c

let allocate_Arg_symbol st n =
  let x = Printf.sprintf "%%Arg%d" n in
  allocate_global_symbol_str st x

let show state n =
  try IntMap.find n (State.get table state).cc_c2s
  with Not_found -> "SYMBOL" ^ string_of_int n

let allocate_bound_symbol state n =
  if not (State.get while_compiling state) then
    anomaly "bound symbols can only be allocated during compilation";
  if n < 0 then
    anomaly "bound variables are positive";
  State.update_return table state
    (fun ({ cc_c2s; cc_c2t; cc_ast2ct; cc_last_global } as table) ->
      try table, IntMap.find n cc_c2t
      with Not_found ->
        let xx = Const n in
        let cc_c2s = IntMap.add n ("c" ^ string_of_int n) cc_c2s in
        let cc_c2t = IntMap.add n xx cc_c2t in
        { cc_c2s; cc_c2t; cc_ast2ct; cc_last_global }, xx)
;;

let get_canonical state c =
  if not (State.get while_compiling state) then
    anomaly "get_canonical can only be used during compilation";
  try IntMap.find c (State.get table state).cc_c2t
  with Not_found -> anomaly ("unknown symbol " ^ string_of_int c)

let get_global_or_allocate_bound_symbol state n =
  if n >= 0 then allocate_bound_symbol state n
  else state, get_canonical state n

let get_global_symbol state s =
  if not (State.get while_compiling state) then
    anomaly "get_global_symbol can only be used during compilation";
  try F.Map.find s (State.get table state).cc_ast2ct
  with Not_found -> anomaly ("unknown symbol " ^ F.show s)

let get_global_symbol_str state s = get_global_symbol state (F.from_string s)

let __show n =
  try Hashtbl.find !current_table.c2s n
  with Not_found -> "SYMBOL" ^ string_of_int n

let __get_global x =
  try fst (Hashtbl.find !current_table.ast2ct x)
  with Not_found -> anomaly ("global symbol "^F.show x^" never declared")

let __get_global_str x =
  let x = F.from_string x in
  __get_global x

let __mkConst x =
  try Hashtbl.find !current_table.c2t x
  with Not_found ->
    let xx = Const x in
    Hashtbl.add !current_table.c2s x ("c" ^ string_of_int x);
    Hashtbl.add !current_table.c2t x xx;
    xx
  [@@inline]

let __fresh_global_constant () =
   !current_table.last_global <- !current_table.last_global - 1;
   let n = !current_table.last_global in
   let xx = Const n in
   Hashtbl.add !current_table.c2s n ("frozen-" ^ string_of_int n);
   Hashtbl.add !current_table.c2t n xx;
   n, xx

end

module Constants : sig

  type t = constant
  val compare : t -> t -> int

  module Map : Map.S with type key = constant
  module Set : Set.S with type elt = constant

  val show : t -> string
  val pp : Fmt.formatter -> t -> unit

  val mkConst : constant -> term
  val mkAppL : constant -> term list -> term
  val mkAppS : string -> term -> term list -> term
  val mkAppSL : string -> term list -> term

  val fresh_global_constant : unit -> constant * term

  (* mkinterval d n 0 = [d; ...; d+n-1] *)
  val mkinterval : int -> int -> int -> term list

end = struct

module Self = struct
  type t = constant
  let compare x y = x - y
  let pp fmt c = pp_spaghetti pp_const fmt c
  let show n = Symbols.__show n
end
include Self

let () = Util.set_spaghetti_printer pp_const (fun fmt i ->
  Format.fprintf fmt "%s" (show i))

module Map = Map.Make(Self)
module Set = Set.Make(Self)

(* - negative constants are global names
   - constants are hashconsed (terms)
   - we use special constants to represent !, pi, sigma *)

let fresh_global_constant = Symbols.__fresh_global_constant
let mkConst x = Symbols.__mkConst x [@@inline]

(* mkinterval d n 0 = [d; ...; d+n-1] *)
let rec mkinterval depth argsno n =
 if n = argsno then []
 else mkConst (n+depth)::mkinterval depth argsno (n+1)
;;

let mkAppL c = function
  | [] -> mkConst c
  | x::xs -> mkApp c x xs [@@inline]
let mkAppS s x args = mkApp (Symbols.__get_global_str s) x args [@@inline]
let mkAppSL s args = mkAppL (Symbols.__get_global_str s) args [@@inline]

end (* }}} *)

let dummy = App (Symbols.cutc,Constants.mkConst Symbols.cutc,[])

module CHR : sig

  (* a set of rules *)
  type t

  (* a set of predicates contributing to represent a constraint *)
  type clique 

  type sequent = { eigen : term; context : term; conclusion : term }
  and rule = {
    to_match : sequent list;
    to_remove : sequent list;
    patsno : int;
    guard : term option;
    new_goal : sequent option;
    nargs : int [@default 0];
    pattern : constant list;
    rule_name : string
  }
  val pp_sequent : Fmt.formatter -> sequent -> unit
  val show_sequent : sequent -> string
  val pp_rule : Fmt.formatter -> rule -> unit
  val show_rule : rule -> string

  val empty : t

  val new_clique : constant list -> t -> t * clique
  val clique_of : constant -> t -> Constants.Set.t option
  val add_rule : clique -> rule -> t -> t
  val in_clique : clique -> constant -> bool
  
  val rules_for : constant -> t -> rule list

  val pp : Fmt.formatter -> t -> unit
  val show : t -> string

end = struct (* {{{ *)

  type sequent = { eigen : term; context : term; conclusion : term }
  and rule = {
    to_match : sequent list;
    to_remove : sequent list;
    patsno : int;
    guard : term option;
    new_goal : sequent option;
    nargs : int [@default 0];
    pattern : constant list;
    rule_name : string;
  }
  [@@ deriving show]
  type t = {
    cliques : Constants.Set.t Constants.Map.t;
    rules : rule list Constants.Map.t
  }
  [@@ deriving show]
  type clique = Constants.Set.t

  let empty = { cliques = Constants.Map.empty; rules = Constants.Map.empty }

  let in_clique m c = Constants.Set.mem c m

  let new_clique cl ({ cliques } as chr) =
    if cl = [] then error "empty clique";
    let c = List.fold_right Constants.Set.add cl Constants.Set.empty in
    Constants.Map.iter (fun _ c' ->
      if not (Constants.Set.is_empty (Constants.Set.inter c c')) && not (Constants.Set.equal c c') then
        error ("overlapping constraint cliques: {" ^
          String.concat "," (List.map Constants.show (Constants.Set.elements c))^"} {" ^
          String.concat "," (List.map Constants.show (Constants.Set.elements c'))^ "}")
    ) cliques;
    let cliques =
      List.fold_right (fun x cliques -> Constants.Map.add x c cliques) cl cliques in
    { chr with cliques }, c

  let clique_of c { cliques } =
    try Some (Constants.Map.find c cliques)
    with Not_found -> None

  let add_rule cl r ({ rules } as chr) =
    let rules = Constants.Set.fold (fun c rules ->
      try
        let rs = Constants.Map.find c rules in
        Constants.Map.add c (rs @ [r]) rules
      with Not_found -> Constants.Map.add c [r] rules)
      cl rules in
    { chr with rules }


  let rules_for c { rules } =
    try Constants.Map.find c rules
    with Not_found -> []

end (* }}} *)

(* An elpi program, as parsed.  But for idx and query_depth that are threaded
   around in the main loop, chr and modes are globally stored in Constraints
   and Clausify. *)
type clause_w_info = {
  clloc : CData.t;
  clargsname : string list;
  clbody : clause;
}
[@@ deriving show]

type macro_declaration = (Ast.Term.t * Loc.t) F.Map.t
[@@ deriving show]

exception No_clause
exception No_more_steps
type 'a solution = {
  assignments : term StrMap.t;
  constraints : constraints;
  state : State.t;
  output : 'a;
  pp_ctx : (string PtrMap.t * int) ref;
}
type 'a outcome = Success of 'a solution | Failure | NoMoreSteps


module Conversion = struct

  type ty_ast = TyName of string | TyApp of string * ty_ast * ty_ast list
  [@@deriving show]

  type 'a embedding =
    depth:int ->
    State.t -> 'a -> State.t * term * extra_goals

  type 'a readback =
    depth:int ->
    State.t -> term -> State.t * 'a * extra_goals

  type 'a t = {
    ty : ty_ast;
    pp_doc : Format.formatter -> unit -> unit [@opaque];
    pp : Format.formatter -> 'a -> unit [@opaque];
    embed : 'a embedding [@opaque];   (* 'a -> term *)
    readback : 'a readback [@opaque]; (* term -> 'a *)
  }
  [@@deriving show]

  exception TypeErr of ty_ast * int * term (* a type error at data conversion time *)

let rec show_ty_ast ?(outer=true) = function
  | TyName s -> s
  | TyApp (s,x,xs) ->
      let t = String.concat " " (s :: List.map (show_ty_ast ~outer:false) (x::xs)) in
      if outer then t else "("^t^")"


end

module ContextualConversion = struct

  type ty_ast = Conversion.ty_ast = TyName of string | TyApp of string * ty_ast * ty_ast list
  [@@deriving show]

  type ('a,'hyps,'constraints) embedding =
    depth:int -> 'hyps -> 'constraints ->
    State.t -> 'a -> State.t * term * extra_goals

  type ('a,'hyps,'constraints) readback =
    depth:int -> 'hyps -> 'constraints ->
    State.t -> term -> State.t * 'a * extra_goals

  type ('a,'hyps,'constraints) t = {
    ty : ty_ast;
    pp_doc : Format.formatter -> unit -> unit [@opaque];
    pp : Format.formatter -> 'a -> unit [@opaque];
    embed : ('a,'hyps,'constraints) embedding [@opaque];   (* 'a -> term *)
    readback : ('a,'hyps,'constraints) readback [@opaque]; (* term -> 'a *)
  }
  [@@deriving show]

  type ('hyps,'constraints) ctx_readback =
    depth:int -> hyps -> constraints -> State.t -> State.t * 'hyps * 'constraints * extra_goals

  let unit_ctx : (unit,unit) ctx_readback = fun ~depth:_ _ _ s -> s, (), (), []
  let raw_ctx : (hyps,constraints) ctx_readback = fun ~depth:_ h c s -> s, h, c, []


  let (!<) { ty; pp_doc; pp; embed; readback; } = {
    Conversion.ty; pp; pp_doc;
    embed = (fun ~depth s t -> embed ~depth () () s t);
    readback = (fun ~depth s t -> readback ~depth () () s t);
  }

  let (!>) { Conversion.ty; pp_doc; pp; embed; readback; } = {
    ty; pp; pp_doc;
    embed = (fun ~depth _ _ s t -> embed ~depth s t);
    readback = (fun ~depth _ _ s t -> readback ~depth s t);
  }

  let (!>>) (f : 'a Conversion.t -> 'b Conversion.t) cc =
  let mk h c { ty; pp_doc; pp; embed; readback; } = {
    Conversion.ty; pp; pp_doc;
    embed = (fun ~depth s t -> embed ~depth h c s t);
    readback = (fun ~depth s t -> readback ~depth h c s t);
  } in
  let mk_pp { ty; pp_doc; pp; } = {
    Conversion.ty; pp; pp_doc;
    embed = (fun ~depth s t -> assert false);
    readback = (fun ~depth s t -> assert false);
  } in
  let { Conversion.ty; pp; pp_doc } = f (mk_pp cc) in
  {
    ty;
    pp;
    pp_doc;
    embed = (fun ~depth h c s t -> (f (mk h c cc)).embed ~depth s t);
    readback = (fun ~depth h c s t -> (f (mk h c cc)).readback ~depth s t);
  }
  
  let (!>>>) (f : 'a Conversion.t -> 'b Conversion.t -> 'c Conversion.t) cc dd = 
  let mk h c { ty; pp_doc; pp; embed; readback; } = {
    Conversion.ty; pp; pp_doc;
    embed = (fun ~depth s t -> embed ~depth h c s t);
    readback = (fun ~depth s t -> readback ~depth h c s t);
  } in
  let mk_pp { ty; pp_doc; pp; } = {
    Conversion.ty; pp; pp_doc;
    embed = (fun ~depth s t -> assert false);
    readback = (fun ~depth s t -> assert false);
  } in
  let { Conversion.ty; pp; pp_doc } = f (mk_pp cc)  (mk_pp dd) in
  {
    ty;
    pp;
    pp_doc;
    embed = (fun ~depth h c s t -> (f (mk h c cc) (mk h c dd)).embed ~depth s t);
    readback = (fun ~depth h c s t -> (f (mk h c cc) (mk h c dd)).readback ~depth s t);
  }

  end

module BuiltInPredicate = struct

type name = string
type doc = string

type 'a oarg = Keep | Discard
type 'a ioarg = Data of 'a | NoData

type ('function_type, 'inernal_outtype_in, 'internal_hyps, 'internal_constraints) ffi =
  | In    : 't Conversion.t * doc * ('i, 'o,'h,'c) ffi -> ('t -> 'i,'o,'h,'c) ffi
  | Out   : 't Conversion.t * doc * ('i, 'o * 't option,'h,'c) ffi -> ('t oarg -> 'i,'o,'h,'c) ffi
  | InOut : 't ioarg Conversion.t * doc * ('i, 'o * 't option,'h,'c) ffi -> ('t ioarg -> 'i,'o,'h,'c) ffi

  | CIn    : ('t,'h,'c) ContextualConversion.t * doc * ('i, 'o,'h,'c) ffi -> ('t -> 'i,'o,'h,'c) ffi
  | COut   : ('t,'h,'c) ContextualConversion.t * doc * ('i, 'o * 't option,'h,'c) ffi -> ('t oarg -> 'i,'o,'h,'c) ffi
  | CInOut : ('t ioarg,'h,'c) ContextualConversion.t * doc * ('i, 'o * 't option,'h,'c) ffi -> ('t ioarg -> 'i,'o,'h,'c) ffi

  | Easy : doc -> (depth:int -> 'o, 'o,unit,unit) ffi
  | Read : ('h,'c) ContextualConversion.ctx_readback * doc -> (depth:int -> 'h -> 'c -> State.t -> 'o, 'o,'h,'c) ffi
  | Full : ('h,'c) ContextualConversion.ctx_readback * doc -> (depth:int -> 'h -> 'c -> State.t -> State.t * 'o * extra_goals, 'o,'h,'c) ffi
  | VariadicIn    : ('h,'c) ContextualConversion.ctx_readback * ('t,'h,'c) ContextualConversion.t * doc -> ('t list -> depth:int -> 'h -> 'c -> State.t -> State.t * 'o, 'o,'h,'c) ffi
  | VariadicOut   : ('h,'c) ContextualConversion.ctx_readback * ('t,'h,'c) ContextualConversion.t * doc -> ('t oarg list -> depth:int -> 'h -> 'c -> State.t -> State.t * ('o * 't option list option), 'o,'h,'c) ffi
  | VariadicInOut : ('h,'c) ContextualConversion.ctx_readback * ('t ioarg,'h,'c) ContextualConversion.t * doc -> ('t ioarg list -> depth:int -> 'h -> 'c -> State.t -> State.t * ('o * 't option list option), 'o,'h,'c) ffi

type t = Pred : name * ('a,unit,'h,'c) ffi * 'a -> t

type doc_spec = DocAbove | DocNext

let pp_comment fmt doc =
  Fmt.fprintf fmt "@?";
  let orig_out = Fmt.pp_get_formatter_out_functions fmt () in
  Fmt.pp_set_formatter_out_functions fmt
    { orig_out with
      Fmt.out_newline = fun () -> orig_out.Fmt.out_string "\n% " 0 3 };
  Fmt.fprintf fmt "@[<hov>";
  Fmt.pp_print_text fmt doc;
  Fmt.fprintf fmt "@]@?";
  Fmt.pp_set_formatter_out_functions fmt orig_out
;;
let pp_ty sep fmt (_,s,_) = Fmt.fprintf fmt " %s%s" s sep
let pp_ty_args = pplist (pp_ty "") " ->" ~pplastelem:(pp_ty "")

module ADT = struct

type ('match_stateful_t,'match_t, 't) match_t =
  | M of (
        (* continuation to call passing subterms *)
        ok:'match_t ->
        (* continuation to call to signal pattern matching failure *)
        ko:(unit -> term) ->
        (* match 't and pass its subterms to ~ok or just call ~ko *)
        't -> term)
  | MS of (
        (* continuation to call passing subterms *)
        ok:'match_stateful_t ->
        (* continuation to call to signal pattern matching failure *)
        ko:(State.t -> State.t * term * extra_goals) ->
        (* match 't and pass its subterms to ~ok or just call ~ko *)
        't -> State.t -> State.t * term * extra_goals)
type ('build_stateful_t,'build_t) build_t =
  | B of 'build_t
  | BS of 'build_stateful_t

type ('stateful_builder,'builder, 'stateful_matcher, 'matcher,  'self, 'hyps,'constraints) constructor_arguments =
  (* No arguments *)
  | N : (State.t -> State.t * 'self, 'self, State.t -> State.t * term * extra_goals, term, 'self, 'hyps,'constraints) constructor_arguments
  (* An argument of type 'a *)
  | A : 'a Conversion.t * ('bs,'b, 'ms,'m, 'self, 'hyps,'constraints) constructor_arguments -> ('a -> 'bs, 'a -> 'b, 'a -> 'ms, 'a -> 'm, 'self, 'hyps,'constraints) constructor_arguments
  (* An argument of type 'a in context 'hyps,'constraints *)
  | CA : ('a,'hyps,'constraints) ContextualConversion.t * ('bs,'b, 'ms,'m, 'self, 'hyps,'constraints) constructor_arguments -> ('a -> 'bs, 'a -> 'b, 'a -> 'ms, 'a -> 'm, 'self, 'hyps,'constraints) constructor_arguments
  (* An argument of type 'self *)
  | S : ('bs,'b, 'ms, 'm, 'self, 'hyps,'constraints) constructor_arguments -> ('self -> 'bs, 'self -> 'b, 'self -> 'ms, 'self -> 'm, 'self, 'hyps,'constraints) constructor_arguments
  (* An argument of type `T 'self` for a constainer `T`, like a `list 'self`.
     `S args` above is a shortcut for `C(fun x -> x, args)` *)
  | C : (('self,'hyps,'constraints) ContextualConversion.t -> ('a,'hyps,'constraints) ContextualConversion.t) * ('bs,'b,'ms,'m,'self, 'hyps,'constraints) constructor_arguments -> ('a -> 'bs, 'a -> 'b, 'a -> 'ms,'a -> 'm, 'self, 'hyps,'constraints) constructor_arguments

type ('t,'h,'c) constructor =
  K : name * doc *
      ('build_stateful_t,'build_t,'match_stateful_t,'match_t,'t,'h,'c) constructor_arguments *   (* args ty *)
      ('build_stateful_t,'build_t) build_t *
      ('match_stateful_t,'match_t,'t) match_t
    -> ('t,'h,'c) constructor

type ('t,'h,'c) declaration = {
  ty : Conversion.ty_ast;
  doc : doc;
  pp : Format.formatter -> 't -> unit;
  constructors : ('t,'h,'c) constructor list;
}

type ('b,'m,'t,'h,'c) compiled_constructor_arguments =
  | XN : (State.t -> State.t * 't,State.t -> State.t * term * extra_goals, 't,'h,'c) compiled_constructor_arguments
  | XA : ('a,'h,'c) ContextualConversion.t * ('b,'m,'t,'h,'c) compiled_constructor_arguments -> ('a -> 'b, 'a -> 'm, 't,'h,'c) compiled_constructor_arguments

type ('match_t, 't) compiled_match_t =
  (* continuation to call passing subterms *)
  ok:'match_t ->
  (* continuation to call to signal pattern matching failure *)
  ko:(State.t -> State.t * term * extra_goals) ->
  (* match 't and pass its subterms to ~ok or just call ~ko *)
  't -> State.t -> State.t * term * extra_goals

type ('t,'h,'c) compiled_constructor =
    XK : ('build_t,'matched_t,'t,'h,'c) compiled_constructor_arguments *
    'build_t * ('matched_t,'t) compiled_match_t
  -> ('t,'h,'c) compiled_constructor

type ('t,'h,'c) compiled_adt = (('t,'h,'c) compiled_constructor) Constants.Map.t

let buildk kname = function
| [] -> Constants.mkConst kname
| x :: xs -> mkApp kname x xs

let rec readback_args : type a m t h c.
  look:(depth:int -> term -> term) ->
  Conversion.ty_ast -> depth:int -> h -> c -> State.t -> extra_goals list -> term ->
  (a,m,t,h,c) compiled_constructor_arguments -> a -> term list ->
    State.t * t * extra_goals
= fun ~look ty ~depth hyps constraints state extra origin args convert l ->
    match args, l with
    | XN, [] ->
        let state, x = convert state in
        state, x, List.(concat (rev extra))
    | XN, _ -> raise (Conversion.TypeErr(ty,depth,origin))
    | XA _, [] -> assert false
    | XA(d,rest), x::xs ->
      let state, x, gls = d.readback ~depth hyps constraints state x in
      readback_args ~look ty ~depth hyps constraints state (gls :: extra) origin
        rest (convert x) xs

and readback : type t h c.
  look:(depth:int -> term -> term) ->
  alloc:(?name:string -> State.t -> State.t * 'uk) ->
  mkUnifVar:('uk -> args:term list -> State.t -> term) ->
  Conversion.ty_ast -> (t,h,c) compiled_adt -> depth:int -> h -> c -> State.t -> term ->
    State.t * t * extra_goals
= fun ~look ~alloc ~mkUnifVar ty adt ~depth hyps constraints state t ->
  try match look ~depth t with
  | Const c ->
      let XK(args,read,_) = Constants.Map.find c adt in
      readback_args ~look ty ~depth hyps constraints state [] t args read []
  | App(c,x,xs) ->
      let XK(args,read,_) = Constants.Map.find c adt in
      readback_args ~look ty ~depth hyps constraints state [] t args read (x::xs)
  | (UVar _ | AppUVar _) ->
      let XK(args,read,_) = Constants.Map.find Symbols.uvarc adt in
      readback_args ~look ty ~depth hyps constraints state [] t args read [t]
  | Discard ->
      let XK(args,read,_) = Constants.Map.find Symbols.uvarc adt in
      let state, k = alloc state in
      readback_args ~look ty ~depth hyps constraints state [] t args read
        [mkUnifVar k ~args:(Constants.mkinterval 0 depth 0) state]
  | _ -> raise (Conversion.TypeErr(ty,depth,t))
  with Not_found -> raise (Conversion.TypeErr(ty,depth,t))

and adt_embed_args : type m a t h c.
  Conversion.ty_ast -> (t,h,c) compiled_adt -> constant ->
  depth:int -> h -> c ->
  (a,m,t,h,c) compiled_constructor_arguments ->
  (State.t -> State.t * term * extra_goals) list ->
    m
= fun ty adt kname ~depth hyps constraints args acc ->
    match args with
    | XN -> fun state ->
        let state, ts, gls =
          List.fold_left (fun (state,acc,gls) f ->
            let state, t, goals = f state in
            state, t :: acc, goals :: gls)
            (state,[],[]) acc in
        state, buildk kname ts, List.(flatten gls)
    | XA(d,args) ->
        fun x ->
          adt_embed_args ty adt kname ~depth hyps constraints
            args ((fun state -> d.embed ~depth hyps constraints state x) :: acc)

and embed : type a h c.
  Conversion.ty_ast -> (Format.formatter -> a -> unit) ->
  (a,h,c) compiled_adt ->
  depth:int -> h -> c -> State.t ->
    a -> State.t * term * extra_goals
= fun ty pp adt ->
  let bindings = Constants.Map.bindings adt in
  fun ~depth hyps constraints state t ->
    let rec aux l state =
      match l with
      | [] -> type_error
                  ("Pattern matching failure embedding: " ^ Conversion.show_ty_ast ty ^ Format.asprintf ": %a" pp t)
      | (kname, XK(args,_,matcher)) :: rest ->
        let ok = adt_embed_args ty adt kname ~depth hyps constraints args [] in
        matcher ~ok ~ko:(aux rest) t state in
     aux bindings state

let rec compile_arguments : type b bs m ms t h c.
  (bs,b,ms,m,t,h,c) constructor_arguments -> (t,h,c) ContextualConversion.t -> (bs,ms,t,h,c) compiled_constructor_arguments =
fun arg self ->
  match arg with
  | N -> XN
  | A(d,rest) -> XA(ContextualConversion.(!>) d,compile_arguments rest self)
  | CA(d,rest) -> XA(d,compile_arguments rest self)
  | S rest -> XA(self,compile_arguments rest self)
  | C(fs, rest) -> XA(fs self, compile_arguments rest self)

let rec compile_builder_aux : type bs b m ms t h c. (bs,b,ms,m,t,h,c) constructor_arguments -> b -> bs
  = fun args f ->
    match args with
    | N -> fun state -> state, f
    | A(_,rest) -> fun a -> compile_builder_aux rest (f a)
    | CA(_,rest) -> fun a -> compile_builder_aux rest (f a)
    | S rest -> fun a -> compile_builder_aux rest (f a)
    | C(_,rest) -> fun a -> compile_builder_aux rest (f a)

let compile_builder : type bs b m ms t h c. (bs,b,ms,m,t,h,c) constructor_arguments -> (bs,b) build_t -> bs
  = fun a -> function
    | B f -> compile_builder_aux a f
    | BS f -> f

let rec compile_matcher_ok : type bs b m ms t h c.
  (bs,b,ms,m,t,h,c) constructor_arguments -> ms -> extra_goals ref -> State.t ref -> m
  = fun args f gls state ->
    match args with
    | N -> let state', t, gls' = f !state in
           state := state';
           gls := gls';
           t
    | A(_,rest) -> fun a -> compile_matcher_ok rest (f a) gls state
    | CA(_,rest) -> fun a -> compile_matcher_ok rest (f a) gls state
    | S rest -> fun a -> compile_matcher_ok rest (f a) gls state
    | C(_,rest) -> fun a -> compile_matcher_ok rest (f a) gls state

let compile_matcher_ko f gls state () =
  let state', t, gls' = f !state in
  state := state';
  gls := gls';
  t

let compile_matcher : type bs b m ms t h c. (bs,b,ms,m,t,h,c) constructor_arguments -> (ms,m,t) match_t -> (ms,t) compiled_match_t
  = fun a -> function
    | M f ->
        fun ~ok ~ko t state ->
          let state = ref state in
          let gls = ref [] in
          !state, f ~ok:(compile_matcher_ok a ok gls state)
                   ~ko:(compile_matcher_ko ko gls state) t, !gls
    | MS f -> f

let rec tyargs_of_args : type a b c d e. string -> (a,b,c,d,e) compiled_constructor_arguments -> (bool * string * string) list =
  fun self -> function
  | XN -> [false,self,""]
  | XA ({ ty },rest) -> (false,Conversion.show_ty_ast ty,"") :: tyargs_of_args self rest

let compile_constructors ty self self_name l =
  let names =
    List.fold_right (fun (K(name,_,_,_,_)) -> StrSet.add name) l StrSet.empty in
  if StrSet.cardinal names <> List.length l then
    anomaly ("Duplicate constructors name in ADT: " ^ Conversion.show_ty_ast ty);
  List.fold_left (fun (acc,sacc) (K(name,_,a,b,m)) ->
    let c = Symbols.declare_global_symbol name in
    let args = compile_arguments a self in
    Constants.(Map.add c (XK(args,compile_builder a b,compile_matcher a m)) acc),
    StrMap.add name (tyargs_of_args self_name args) sacc)
      (Constants.Map.empty,StrMap.empty) l

let document_constructor fmt name doc argsdoc =
  Fmt.fprintf fmt "@[<hov2>type %s@[<hov>%a.%s@]@]@\n"
    name pp_ty_args argsdoc (if doc = "" then "" else " % " ^ doc)

let document_kind fmt = function
  | Conversion.TyApp(s,_,l) ->
      let n = List.length l + 2 in
      let l = Array.init n (fun _ -> "type") in
      Fmt.fprintf fmt "@[<hov 2>kind %s %s.@]@\n"
        s (String.concat " -> " (Array.to_list l))
  | Conversion.TyName s -> Fmt.fprintf fmt "@[<hov 2>kind %s type.@]@\n" s

let document_adt doc ty ks cks fmt () =
  if doc <> "" then
    begin pp_comment fmt ("% " ^ doc); Fmt.fprintf fmt "@\n" end;
  document_kind fmt ty;
  List.iter (fun (K(name,doc,_,_,_)) ->
    if name <> "uvar" then
      let argsdoc = StrMap.find name cks in
      document_constructor fmt name doc argsdoc) ks

let adt ~look ~alloc ~mkUnifVar { ty; constructors; doc; pp } =
  let readback_ref = ref (fun ~depth _ _ _ _ -> assert false) in
  let embed_ref = ref (fun ~depth _ _ _ _ -> assert false) in
  let sconstructors_ref = ref StrMap.empty in
  let self = {
    ContextualConversion.ty;
    pp;
    pp_doc = (fun fmt () ->
      document_adt doc ty constructors !sconstructors_ref fmt ());
    readback = (fun ~depth hyps constraints state term ->
      !readback_ref ~depth hyps constraints state term);
    embed = (fun ~depth hyps constraints state term ->
      !embed_ref ~depth hyps constraints state term);
  } in
  let cconstructors, sconstructors = compile_constructors ty self (Conversion.show_ty_ast ty) constructors in
  sconstructors_ref := sconstructors;
  readback_ref := readback ~look ~alloc ~mkUnifVar ty cconstructors;
  embed_ref := embed ty pp cconstructors;
  self

end

type declaration =
  | MLCode of t * doc_spec
  | MLData : 'a Conversion.t -> declaration
  | MLDataC : ('a,'h,'c) ContextualConversion.t -> declaration
  | LPDoc  of string
  | LPCode of string

(* doc *)
let pp_tab_arg i sep fmt (dir,ty,doc) =
  let dir = if dir then "i" else "o" in
  if i = 0 then Fmt.pp_set_tab fmt () else ();
  Fmt.fprintf fmt "%s:%s%s" dir ty sep;
  if i = 0 then Fmt.pp_set_tab fmt () else Fmt.pp_print_tab fmt ();
  if doc <> "" then begin Fmt.fprintf fmt " %% %s" doc end;
  Fmt.pp_print_tab fmt ()
;;

let pp_tab_args fmt l =
  let n = List.length l - 1 in
  Fmt.pp_open_tbox fmt ();
  List.iteri (fun i x ->
    let sep = if i = n then "." else "," in
    pp_tab_arg i sep fmt x) l;
  Fmt.pp_close_tbox fmt ()
;;

let pp_arg sep fmt (dir,ty,doc) =
  let dir = if dir then "i" else "o" in
  Fmt.fprintf fmt "%s:%s%s" dir ty sep
;;

let pp_args = pplist (pp_arg "") ", " ~pplastelem:(pp_arg "")

let pp_pred fmt docspec name doc_pred args =
  let args = List.rev args in
  match docspec with
  | DocNext ->
     Fmt.fprintf fmt "@[<v 2>external pred %s %% %s@;%a@]@."
       name doc_pred pp_tab_args args
  | DocAbove ->
    let doc =
       "[" ^ String.concat " " (name :: List.map (fun (_,_,x) -> x) args) ^
       "] " ^ doc_pred in
     Fmt.fprintf fmt "@[<v>%% %a@.external pred %s @[<hov>%a.@]@]@.@."
       pp_comment doc name pp_args args
;;

let pp_variadictype fmt name doc_pred ty args =
  let parens s = if String.contains s ' ' then "("^s^")" else s in
  let args = List.rev ((false,"variadic " ^ parens ty ^ " prop","") :: args) in
  let doc =
    "[" ^ String.concat " " (name :: List.map (fun (_,_,x) -> x) args) ^
    "...] " ^ doc_pred in
  Fmt.fprintf fmt "@[<v>%% %a@.external type %s@[<hov>%a.@]@]@.@."
        pp_comment doc name pp_ty_args args
;;

let document_pred fmt docspec name ffi =
  let rec doc
  : type i o h c. (bool * string * string) list -> (i,o,h,c) ffi -> unit
  = fun args -> function
    | In( { Conversion.ty }, s, ffi) -> doc ((true,Conversion.show_ty_ast ty,s) :: args) ffi
    | Out( { Conversion.ty }, s, ffi) -> doc ((false,Conversion.show_ty_ast ty,s) :: args) ffi
    | InOut( { Conversion.ty }, s, ffi) -> doc ((false,Conversion.show_ty_ast ty,s) :: args) ffi
    | CIn( { ContextualConversion.ty }, s, ffi) -> doc ((true,Conversion.show_ty_ast ty,s) :: args) ffi
    | COut( { ContextualConversion.ty }, s, ffi) -> doc ((false,Conversion.show_ty_ast ty,s) :: args) ffi
    | CInOut( { ContextualConversion.ty }, s, ffi) -> doc ((false,Conversion.show_ty_ast ty,s) :: args) ffi
    | Read (_,s) -> pp_pred fmt docspec name s args
    | Easy s -> pp_pred fmt docspec name s args
    | Full (_,s) -> pp_pred fmt docspec name s args
    | VariadicIn( _,{ ContextualConversion.ty }, s) -> pp_variadictype fmt name s (Conversion.show_ty_ast ty) args
    | VariadicOut( _,{ ContextualConversion.ty }, s) -> pp_variadictype fmt name s (Conversion.show_ty_ast ty) args
    | VariadicInOut( _,{ ContextualConversion.ty }, s) -> pp_variadictype fmt name s (Conversion.show_ty_ast ty) args
  in
    doc [] ffi
;;

let document fmt l =
  let omargin = Fmt.pp_get_margin fmt () in
  Fmt.pp_set_margin fmt 75;
  Fmt.fprintf fmt "@[<v>";
  Fmt.fprintf fmt "@\n@\n";
  List.iter (function
    | MLCode(Pred(name,ffi,_), docspec) -> document_pred fmt docspec name ffi
    | MLData { pp_doc } -> Fmt.fprintf fmt "%a@\n" pp_doc ()
    | MLDataC { pp_doc } -> Fmt.fprintf fmt "%a@\n" pp_doc ()
    | LPCode s -> Fmt.fprintf fmt "%s" s; Fmt.fprintf fmt "@\n@\n"
    | LPDoc s -> pp_comment fmt ("% " ^ s); Fmt.fprintf fmt "@\n@\n") l;
  Fmt.fprintf fmt "@\n@\n";
  Fmt.fprintf fmt "@]@.";
  Fmt.pp_set_margin fmt omargin
;;


let builtins : (StrSet.t * Constants.Set.t * t list) State.component = State.declare ~name:"elpi:compiler:builtins"
  ~pp:(fun fmt (s,_,_) -> StrSet.pp fmt s)
  ~init:(fun () -> StrSet.empty, Constants.Set.empty, [])
  ~clause_compilation_is_over:(fun x -> x)
  ~goal_compilation_is_over:(fun ~args x -> Some x)
  ~compilation_is_over:(fun _ -> None)
;;

let all state =
  let _, csts, _ = State.get builtins state in
  csts

let register state (Pred(s,_,_) as b) =
  if s = "" then anomaly "Built-in predicate name must be non empty";
  if not (State.get while_compiling state) then
    anomaly "Built-in can only be declared at compile time";
  let state, idx = Symbols.allocate_global_symbol_str state s in
  let _, declared, _ = State.get builtins state in
  if Constants.Set.mem idx declared then
    anomaly ("Duplicate built-in predicate " ^ s);
  State.update builtins state (fun (w,i,l) -> StrSet.add s w, Constants.Set.add idx i, b :: l)
;;

let is_declared_str state x =
  let declared, _, _ = State.get builtins state in
  StrSet.mem x declared
  || x == Symbols.(show state declare_constraintc)
  || x == Symbols.(show state print_constraintsc)
  || x == Symbols.(show state cutc)
;;

let is_declared state x =
  let _, declared, _ = State.get builtins state in
  Constants.Set.mem x declared
  || x == Symbols.(declare_constraintc)
  || x == Symbols.(print_constraintsc)
  || x == Symbols.(cutc)
;;

type builtin_table = (int, t) Hashtbl.t

end

module Query = struct
  type name = string
  type _ arguments =
    | N : unit arguments
    | D : 'a Conversion.t * 'a *    'x arguments -> 'x arguments
    | Q : 'a Conversion.t * name * 'x arguments -> ('a * 'x) arguments

  type 'x t =
    | Query of { predicate : name; arguments : 'x arguments }

end

type 'a executable = {
  (* the lambda-Prolog program: an indexed list of clauses *) 
  compiled_program : prolog_prog;
  (* chr rules *)
  chr : CHR.t;
  (* initial depth (used for both local variables and CHR (#eigenvars) *)
  initial_depth : int;
  (* query *)
  initial_goal: term;
  (* constraints coming from compilation *)
  initial_runtime_state : State.t;
  (* Hashconsed symbols *)
  symbol_table : Symbols.t;
  (* Indexed FFI entry points *)
  builtins : BuiltInPredicate.builtin_table;
  (* solution *)
  assignments : term Util.StrMap.t;
  (* type of the query, reified *)
  query_arguments: 'a Query.arguments;
}
