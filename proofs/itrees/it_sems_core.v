
From Jasmin Require Import oseq.
(* problematic *)
From Jasmin Require Import expr.
From Jasmin Require Import it_jasmin_lib.

(* FIXME clean this *)
From Coq Require Import
     Arith.PeanoNat
     Lists.List
     Strings.String
     Morphisms
     Setoid
     RelationClasses
     EquivDec
     Equality
     Program.Tactics.

From ExtLib Require Import
     Data.String
     Structures.Monad
     Structures.Traversable
     Data.List
     Core.RelDec
     Structures.Maps
     Data.Map.FMapAList.

From ITree Require Import
     ITree
     ITreeFacts
     Monad
     Basics.HeterogeneousRelations
     Events.Map
     Events.State
     Events.StateFacts
     Events.Reader
     Events.Exception
     Events.FailFacts.

Require Import Paco.paco.
Require Import Psatz.
Require Import ProofIrrelevance.
Require Import FunctionalExtensionality.

From mathcomp Require Import ssreflect ssrfun ssrbool ssrnat seq eqtype fintype.

From ITree Require Import
     Basics.Category
     Basics.Basics
     Basics.Function
     Core.ITreeDefinition
     Core.KTree
     Eq.Eqit
     Eq.UpToTaus
     Eq.Paco2
     Indexed.Sum
     Indexed.Function
     Indexed.Relation
     Interp.Handler
     Interp.Interp
     Interp.InterpFacts
     Interp.Recursion.

From ITree Require Import Rutt RuttFacts.

From ITree Require Import EqAxiom.

From Jasmin Require Import expr psem_defs psem oseq.
From Jasmin Require Import it_gen_lib it_jasmin_lib it_exec.
From Jasmin Require Import compiler_util.
(* problematic *)

(* End FIXME *)
Import Monads.
Import MonadNotation.
Local Open Scope monad_scope.
Local Open Scope option_scope.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

(* Set Universe Polymorphism. *)

(* This files contains semantic models distinguished by use of either
mutual or double recursion, and by either modular, error-aware or flat
structure. There are fives models (MM: mutual modular; ME: mutual
error; MF: mutual flat; DE: double error; DF double flat) *)

(**** ERROR SEMANTICS *******************************************)
Section Errors.

(* type of errors (this might becom richer) *)
  (* Variant ErrType : Type := Err : ErrType. *)
(* error events *)


Definition ErrEvent : Type -> Type := exceptE error_data.

(*
sem_I : prog -> estate -> instr -> itree syscall_Event (state_error + estate)
sem_i : prog -> estate -> instr_r -> itree syscall_Event (state_error + estate)
sem_c : prog -> estate -> cmd -> itree syscall_Event (state_error + estate)
sem_fun : prog -> mem -> syscall -> funname -> values -> itree syscall_Event (state_error + (mem * syscall * values))
*)

(* failT (itree E) R = itree E (option R) *)
Definition handle_Err {E} : ErrEvent ~> execT (itree E) :=
  fun _ e =>
    match e with
    | Throw e' => Ret (ESerror _ e')
    end.

(* Err handler *)
Definition ext_handle_Err {E: Type -> Type} :
  ErrEvent +' E ~> execT (itree E) :=
  fun _ e =>
  match e with
  | inl1 e' => handle_Err e'
  | inr1 e' => Vis e' (pure (fun x => ESok x)) end.

(* ErrEvent interpreter *)
Definition interp_Err {E: Type -> Type} {A}
  (t: itree (ErrEvent +' E) A) : execT (itree E) A :=
  interp_exec ext_handle_Err t.

(*** auxiliary error functions *)

Definition ioget {E: Type -> Type} `{ErrEvent -< E} {V} (err: error_data) (o: option V) : itree E V :=
  match o with
  | Some v => Ret v
  | None => throw err
  end.

Definition err_result {E: Type -> Type} `{ErrEvent -< E} (Err : error -> error_data) :
  result error ~> itree E :=
  fun _ t => match t with
             | Ok v => Ret v
             | Error e => throw (Err e) end.

End Errors.

Section WSW.
Context
  {asm_op: Type}
  {asmop: asmOp asm_op}
  {wsw: WithSubWord}
  {dc: DirectCall}
  {syscall_state : Type}
  {ep : EstateParams syscall_state}
  {spp : SemPexprParams}
  {sip : SemInstrParams asm_op syscall_state}
  {pT : progT}
  {scP : semCallParams}
  (pr : prog)
  (ev : extra_val_t).

Definition mk_error_data (s:estate) (e:error)  := (e, tt).

Definition mk_errtype := fun s => mk_error_data s ErrType.

Definition iget_fundef {E} `{ErrEvent -< E}
  (fn: funname) (s:estate) : itree E fundef :=
  ioget (mk_errtype s) (get_fundef (p_funcs pr) fn).

Definition iresult  {E} `{ErrEvent -< E} {T} (s:estate) (F : exec T)  : itree E T :=
  err_result (mk_error_data s) F.

Definition iwrite_var {E} `{ErrEvent -< E}
   (wdb : bool) (x : var_i) (v : value) (s : estate) : itree E estate :=
  iresult s (write_var wdb x v s).

Definition iwrite_lval {E} `{ErrEvent -< E}
   (wdb : bool) (gd : glob_decls) (x : lval) (v : value) (s : estate) : itree E estate :=
  iresult s (write_lval wdb gd x v s).

Definition iwrite_lvals {E} `{ErrEvent -< E}
   (wdb : bool) (gd : glob_decls) (s : estate) (xs : lvals) (vs : values) : itree E estate :=
  iresult s (write_lvals wdb gd s xs vs).

Definition isem_pexpr {E} `{ErrEvent -< E}
   (wdb : bool) (gd : glob_decls) (s : estate) (e: pexpr) : itree E value :=
  iresult s (sem_pexpr wdb gd s e).

Definition isem_pexprs {E} `{ErrEvent -< E}
   (wdb : bool) (gd : glob_decls) (s : estate) (es: pexprs) : itree E values :=
  iresult s (sem_pexprs wdb gd s es).

Definition eval_assgn
  (x: lval) (tg: assgn_tag) (ty: stype) (e: pexpr)
  (st1: estate) : exec estate :=
   (Let v := sem_pexpr true (p_globs pr) st1 e in
    Let v' := truncate_val ty v in
    write_lval true (p_globs pr) x v' st1).

Definition eval_syscall
   (xs: lvals) (o: syscall_t)
   (es: pexprs) (s: estate) : exec estate :=
  Let ves := sem_pexprs true (p_globs pr) s es in
  Let: (scs, m, vs) := exec_syscall s.(escs) s.(emem) o ves in
  write_lvals true (p_globs pr)
     (with_scs (with_mem s m) scs) xs vs.

(** Auxiliary functions for recursion on list (seq) *)

Fixpoint sem_cmd_ {E} (sem_i: instr_r -> estate -> itree E estate)
   (c: cmd) (st: estate) : itree E estate :=
  match c with
  | nil => Ret st
  | (MkI _ i) :: c' => st' <- sem_i i st ;; sem_cmd_ sem_i c' st'
  end.

Fixpoint sem_for {E} `{ErrEvent -< E}
   (sem_cmd : cmd -> estate -> itree E estate)
   (i: var_i) (c: cmd)
   (ls: list Z) (s: estate) : itree E estate :=
  match ls with
  | nil => ret s
  | (w :: ws) =>
    s <- iwrite_var true i (Vint w) s;;
    s <- sem_cmd c s;;
    sem_for sem_cmd i c ws s
  end.

(**********************************************************************)
(** error-aware interpreter with mutual recursion *)

(* mutual recursion events *)
(* FIXME : should we find a better name ? *)
(* FIXME :  introduce a record for (syscall_state_t * mem * values) *)
Variant FCState : Type -> Type :=
 | FLCode (c: cmd) (st: estate) : FCState estate
 | FFCall (scs : syscall_state_t) (m:mem)
          (f: funname) (vs:values) : FCState (syscall_state_t * mem * values).

(* Make global definition *)
Local Notation continue_loop st := (ret (inl st)).
Local Notation exit_loop st := (ret (inr st)).
Local Notation rec_call := (trigger_inl1).

Local Notation gd := (p_globs pr).

Definition sem_cond {E} `{ErrEvent -< E} (e:pexpr) (s: estate) :
   itree E bool :=
  iresult s (sem_pexpr true gd s e >>r= to_bool).

Definition sem_bound {E} `{ErrEvent -< E} (e:pexpr) (s: estate) :
   itree E Z :=
  iresult s (sem_pexpr true gd s e >>r= to_int).

Definition msem_i {E} `{ErrEvent -< E} (i : instr_r) (s1: estate) : itree (FCState +' E) estate :=
(*  let R := st_cmd_map_r meval_instr in *)
  let R := (fun c s => rec_call (FLCode c s)) in
  match i with
  | Cassgn x tg ty e => iresult s1 (eval_assgn x tg ty e s1)
  | Copn xs tg o es => iresult s1 (sem_sopn gd o s1 xs es)
  | Csyscall xs o es => iresult s1 (eval_syscall xs o es s1)
  | Cif e c1 c2 =>
      b <- sem_cond e s1;;
      R (if b then c1 else c2) s1
  | Cwhile a c1 e c2 =>
      ITree.iter (fun s1 =>
           s2 <- R c1 s1 ;;
           b <- sem_cond e s2 ;;
           if b then s3 <- R c2 s2 ;; continue_loop s3
           else exit_loop s2) s1
  | Cfor i (d, lo, hi) c =>
     vlo <- sem_bound lo s1 ;;
     vhi <- sem_bound hi s1 ;;
     sem_for R i c (wrange d vlo vhi) s1

  | Ccall xs fn args =>
      vargs <- isem_pexprs  (~~direct_call) gd s1 args;;
      res <- rec_call (FFCall (escs s1) (emem s1) fn vargs);;
      let: (scs2, m2, vs) := res in
      iwrite_lvals (~~direct_call) gd (with_scs (with_mem s1 m2) scs2) xs vs
end.

Definition initialize_call (scs1 : syscall_state_t) (m1 : mem)
   (fd : fundef) (vargs : values) : exec estate :=
  let sinit := (Estate scs1 m1 Vm.init) in
  Let vargs' := mapM2 ErrType dc_truncate_val fd.(f_tyin) vargs in
  Let s0 := init_state fd.(f_extra) (p_extra pr) ev sinit in
  write_vars (~~direct_call) fd.(f_params) vargs' s0.

Definition finalize_call (fd : fundef) (s:estate) :=
  Let vres := get_var_is (~~ direct_call) s.(evm) fd.(f_res) in
  Let vres' := mapM2 ErrType dc_truncate_val fd.(f_tyout) vres in
  let scs := s.(escs) in
  let m := finalize fd.(f_extra) s.(emem) in
  ok (scs, m, vres').

Definition msem_call {E} `{ErrEvent -< E}
   (scs1 : syscall_state_t) (m1 : mem)
   (fn : funname) (vargs : values) : itree (FCState +' E) (syscall_state_t * mem * values) :=
  (* FIXME: this is durty : sinit*)
  let sinit := (Estate scs1 m1 Vm.init) in
  fd <- iget_fundef fn sinit;;
  s1 <- iresult sinit (initialize_call scs1 m1 fd vargs);;
  s2 <- rec_call (FLCode fd.(f_body) s1);;
  iresult s2 (finalize_call fd s2).

Definition msem_fcstate {E} `{ErrEvent -< E} : FCState ~> itree (FCState +' E) :=
 fun _ fs =>
   match fs with
   | FLCode c st => sem_cmd_ msem_i c st
   | FFCall scs m fn vs => msem_call scs m fn vs
   end.

Definition rsem_call {E} `{ErrEvent -< E}
   (scs1 : syscall_state_t) (m1 : mem)
   (fn : funname) (vargs : values) : itree E (syscall_state_t * mem * values) :=
 mrec msem_fcstate (FFCall scs1 m1 fn vargs).

(* This should be the final semantics *)
Definition sem_call (scs1 : syscall_state_t) (m1 : mem)
   (fn : funname) (vargs : values) : execT (itree void1) (syscall_state_t * mem * values) :=
  interp_Err (rsem_call scs1 m1 fn vargs).

End WSW.


