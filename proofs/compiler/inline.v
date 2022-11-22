(* * Prove properties about semantics of dmasm input language *)

(* ** Imports and settings *)
Require Import ZArith.
From mathcomp Require Import all_ssreflect.
Require Import expr compiler_util leakage allocation.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Local Open Scope vmap.
Local Open Scope seq_scope.

(* ** inlining
 * -------------------------------------------------------------------- *)

Section INLINE.

Context (inline_var: var -> bool).

(* checks the annotation for inlining *)
Definition get_flag (x:lval) flag :=
  match x with
  | Lvar x => if inline_var x then AT_inline else flag
  | _      => flag
  end.

(* translate into assignment instruction *)
Definition assgn_tuple iinfo (xs:lvals) flag (tys:seq stype) (es:pexprs) :=
  let assgn xe := MkI iinfo (Cassgn xe.1 (get_flag xe.1 flag) xe.2.1 xe.2.2) in
  map assgn (zip xs (zip tys es)).

(* inlining sequence of instructions *)
Definition inline_c (inline_i: instr -> Sv.t -> ciexec (Sv.t * cmd * leak_i_tr)) c s 
            : ciexec(Sv.t * cmd * leak_c_tr) :=
  foldr (fun i r =>
    Let r := r in
    Let ri := inline_i i r.1.1 in
    ciok (ri.1.1, ri.1.2 ++ r.1.2, ri.2 :: r.2)) (ciok (s,[::], [::])) c.

(* Variables representing the parameters of the function *)
Definition sparams fd :=
  vrvs_rec Sv.empty (map Lvar fd.(f_params)).

(* Variables present in body and the results of the function *)
Definition locals_p fd :=
  let s := read_es (map Pvar fd.(f_res)) in
  let w := write_c_rec s fd.(f_body) in
  let r := read_c_rec w fd.(f_body) in
  vrvs_rec r (map Lvar fd.(f_params)).

Definition locals fd :=
  Sv.diff (locals_p fd) (sparams fd).

(* checks if there is no same variable is used for two different purposes *)
Definition check_rename iinfo f fd1 fd2 (s:Sv.t) :=
  Let _ := add_infun iinfo (CheckAllocReg.check_fundef (f,fd1) (f,fd2)) in
  let s2 := locals_p fd2 in
  if disjoint s s2 then ciok tt
  else cierror iinfo (Cerr_inline s s2).

Definition get_fun (p:fun_decls) iinfo (f:funname) :=
  match get_fundef p f with
  | Some fd => ciok fd
  | None    => cierror iinfo (Cerr_unknown_fun f "inlining")
  end.

Variable rename_fd : instr_info -> funname -> fundef -> fundef.

Definition dummy_info := xH.

Definition mkdV x := {| v_var := x; v_info := dummy_info |}.

Definition arr_init p := Parr_init p.

(*Definition array_init iinfo (X: Sv.t) :=
  let assgn x c :=
    match x.(vtype) with
    | sarr p =>
      MkI iinfo (Cassgn (Lvar (mkdV x)) AT_rename x.(vtype) (arr_init p)) :: c
    | _      => c
    end in
  Sv.fold assgn X [::].*)

Definition array_init iinfo (X: Sv.t) : cmd :=
  let assgn x cl :=
    match x.(vtype) with
    | sarr p =>
      MkI iinfo (Cassgn (Lvar (mkdV x)) AT_rename x.(vtype) (arr_init p)) :: cl
    | _      => cl
    end in
  Sv.fold assgn X [::].

Fixpoint inline_i (p:fun_decls) (i:instr) (X:Sv.t) : ciexec (Sv.t * cmd * leak_i_tr) :=
  match i with
  | MkI iinfo ir =>
    match ir with
    | Cassgn x _ _ e => ciok (Sv.union (read_i ir) X, [::i], LT_ikeep)
    | Copn xs _ o es => ciok (Sv.union (read_i ir) X, [::i], LT_ikeep)
    | Cif e c1 c2  =>
      Let cr1 := inline_c (inline_i p) c1 X in
      Let cr2 := inline_c (inline_i p) c2 X in
      ciok (read_e_rec (Sv.union cr1.1.1 cr2.1.1) e, 
            [::MkI iinfo (Cif e cr1.1.2 cr2.1.2)], LT_icond LT_id cr1.2 cr2.2)
    | Cfor x (d,lo,hi) c =>
      let X := Sv.union (read_i ir) X in
      Let c := inline_c (inline_i p) c X in
      ciok (X, [::MkI iinfo (Cfor x (d, lo, hi) c.1.2)], LT_ifor LT_id c.2)
    | Cwhile a c e c' =>
      let X := Sv.union (read_i ir) X in
      Let c := inline_c (inline_i p) c X in
      Let c' := inline_c (inline_i p) c' X in
      ciok (X, [::MkI iinfo (Cwhile a c.1.2 e c'.1.2)], LT_iwhile c.2 LT_id c'.2)
    | Ccall inline xs f es =>
      let X := Sv.union (read_i ir) X in
      if inline is InlineFun then
        Let fd := get_fun p iinfo f in
        let fd' := rename_fd iinfo f fd in
        (* FIXME : locals is computed 2 times (one in check_rename) *)
        Let _ := check_rename iinfo f fd fd' (Sv.union (vrvs xs) X) in
        let init_array := array_init iinfo (locals fd') in
        ciok (X,  assgn_tuple iinfo (map Lvar fd'.(f_params)) AT_rename fd'.(f_tyin) es ++
                  init_array ++
                  (fd'.(f_body) ++
                  assgn_tuple iinfo xs AT_rename fd'.(f_tyout) (map Pvar fd'.(f_res))),
              LT_icall_inline (size es) f (size init_array) (size xs))

      else ciok (X, [::i], lt_icall_id f xs es)
    end
  end.

Definition inline_fd (p:fun_decls) (fd:fundef) : ciexec (fundef * leak_c_tr) :=
  match fd with
  | MkFun ii tyin params c tyout res =>
    let s := read_es (map Pvar res) in
    Let c := inline_c (inline_i p) c s in
    ok (MkFun ii tyin params c.1.2 tyout res, c.2)
  end.

Definition inline_fd_cons (ffd:funname * fundef) (p:cfexec (fun_decls * leak_f_tr)) 
           : cfexec (fun_decls * leak_f_tr) :=
  Let p' := p in
  let f := ffd.1 in
  Let fd := add_finfo f f (inline_fd p'.1 ffd.2) in
  cfok ((f, fd.1) :: p'.1, 
        (f, fd.2) :: p'.2).

(* Need to change this *)
Definition inline_prog (p:fun_decls) :=  
  foldr inline_fd_cons 
  (cfok ([::], [::])) p.

Definition inline_prog_err (p:prog) :=
  if uniq [seq x.1 | x <- p_funcs p] then
    Let fds := inline_prog (p_funcs p) in
    ok ({| p_globs := p_globs p; p_funcs := fds.1 |}, fds.2)
  else cferror Ferr_uniqfun.

Definition is_array_init e :=
  match e with
  | Parr_init _ => true
  | _           => false
  end.

Fixpoint remove_init_i i : (cmd * leak_i_tr) :=
  match i with
  | MkI ii ir =>
    match ir with
    | Cassgn x _ _ e => if is_array_init e 
                        then ([::], LT_iremove) 
                        else ([::i], LT_ikeep)
    | Copn _ _ _ _   => ([::i], LT_ikeep)
    | Cif e c1 c2  =>
      let r1 := foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2)) ([::], [::]) c1 in
      let r2 := foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2))  ([::], [::]) c2 in
      ([:: MkI ii (Cif e r1.1 r2.1) ], LT_icond (LT_id) r1.2 r2.2) 
    | Cfor x r c   =>
      let r1 := foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2)) ([::], [::]) c in
      ([:: MkI ii (Cfor x r r1.1) ], LT_ifor LT_id r1.2)
    | Cwhile a c e c' =>
      let r1 := foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2)) ([::], [::]) c in
      let r2 := foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2)) ([::], [::]) c' in
      ([:: MkI ii (Cwhile a r1.1 e r2.1) ], LT_iwhile r1.2 LT_id r2.2)
    | Ccall _ xs f es => ([::i], lt_icall_id f xs es)
    end
  end.

Definition remove_init_c c :=  foldr (fun i r =>  
                       let ri := remove_init_i i in 
                       ((ri.1 ++ r.1), ri.2 :: r.2)) ([::], [::]) c.

Definition remove_init_fd fd :=
  ({| f_iinfo  := fd.(f_iinfo);
     f_tyin   := fd.(f_tyin);
     f_params := fd.(f_params);
     f_body   := (remove_init_c fd.(f_body)).1;
     f_tyout   := fd.(f_tyout);
     f_res    := fd.(f_res); |}, (remove_init_c fd.(f_body)).2).


Definition remove_init_prog (p:prog) := 
  let funcs := map_prog_leak remove_init_fd (p_funcs p) in
  ({| p_globs := p_globs p; p_funcs := funcs.1 |}, funcs.2).

End INLINE.


