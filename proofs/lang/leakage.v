From mathcomp Require Import all_ssreflect all_algebra.
From mathcomp Require Import word_ssrZ.
Require Import Psatz xseq.
Require Export array gen_map low_memory warray_ sem_type var.
Import Utf8.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Declare Scope leakage_scope.
Delimit Scope leakage_scope with leakage.
Open Scope leakage_scope.


Variant align := 
  | Align
  | NoAlign.

Inductive leak_e :=
| LEmpty : leak_e (* no leak *)
| LIdx : Z -> leak_e (* array access at given index *)
| LAdr : pointer -> leak_e (* memory access at given address *)
| LSub: (seq leak_e) -> leak_e. (* forest of leaks *)
(*| Lop : forall ws, word ws -> leak_e. *)

Class LeakOp := {
   div_leak_ : signedness -> forall (sz:wsize), word sz -> word sz -> word sz -> leak_e;
   mem_leak_ : word Uptr -> word Uptr;
}.

Section Section.
 
Context {LO:LeakOp}.

Definition div_leak s (sz : wsize) (hi lo div: word sz) : exec leak_e := ok (div_leak_ s hi lo div).

End Section.

Notation leak_es := (seq leak_e).

Inductive leak_i : Type :=
  | Lopn  : leak_e -> leak_i   (* leak_es -> leak_es -> leak_i *)
  | Lcond  : leak_e -> bool -> seq leak_i -> leak_i                          
  | Lwhile_true : seq leak_i -> leak_e -> seq leak_i -> leak_i -> leak_i     
  | Lwhile_false : seq leak_i -> leak_e -> leak_i
  | Lfor : leak_e -> seq (seq leak_i) -> leak_i                              
  | Lcall : leak_es -> (funname * seq leak_i) -> leak_es -> leak_i.

Notation leak_c := (seq leak_i).

Notation leak_for := (seq leak_c) (only parsing).

Notation leak_fun := (funname * leak_c)%type.

(* ------------------------------------------------------------------------ *)
(* Leakage trees and leakage transformations. *)

Inductive leak_tr_p :=
  | LS_const of pointer
  | LS_stk
  | LS_Add of leak_tr_p & leak_tr_p
  | LS_Mul of leak_tr_p & leak_tr_p.

Fixpoint leak_tr_p_beq x x' : bool :=
  match x, x' with
  | LS_const p, LS_const p' => p == p'
  | LS_stk, LS_stk => true
  | LS_Add y z, LS_Add y' z'
  | LS_Mul y z, LS_Mul y' z' => (leak_tr_p_beq y y') && (leak_tr_p_beq z z')
  | _, _ => false
  end.

Lemma leak_tr_p_beq_axiom : Equality.axiom leak_tr_p_beq.
Proof.
  elim => [ p | | y hy z hz | y hy z hz ] [ p' | | y' z' | y' z' ] /=.
  2-10, 12-15: by constructor.
  - case: eqP => [ <- | k ]; constructor; congruence.
  all: case: andP.
  1, 3: by case => /hy -> /hz ->; constructor.
  all: by move => k; constructor => - [] /hy ? /hz ?; apply: k.
Qed.

Definition leak_tr_p_eqMixin     := Equality.Mixin leak_tr_p_beq_axiom.
Canonical  leak_tr_p_eqType      := Eval hnf in EqType leak_tr_p leak_tr_p_eqMixin.

(* Leakage transformer for expressions *)
Inductive leak_e_tr :=
  | LT_id (* preserve *)
  | LT_remove (* remove *)
  | LT_const : leak_tr_p -> leak_e_tr
  | LT_subi : nat -> leak_e_tr (* projection *)
  | LT_lidx : (Z -> leak_tr_p) -> leak_e_tr
  | LT_map : seq leak_e_tr -> leak_e_tr (* parallel transformations *)
  | LT_seq : seq leak_e_tr -> leak_e_tr
  | LT_compose: leak_e_tr -> leak_e_tr -> leak_e_tr (* compositon of transformations *)
  .

(* Smart constructor for LT_compose *)
Definition lt_compose (a b: leak_e_tr) : leak_e_tr :=
  if a is LT_id then b else if b is LT_id then a else LT_compose a b.

Fixpoint eval_leak_tr_p stk lp : pointer :=
  match lp with
  | LS_const p => p 
  | LS_stk     => stk
  | LS_Add p1 p2 => (eval_leak_tr_p stk p1 + eval_leak_tr_p stk p2)%R
  | LS_Mul p1 p2 => (eval_leak_tr_p stk p1 * eval_leak_tr_p stk p2)%R
  end.

Section Section.

Context {LO: LeakOp}.

Fixpoint leak_E (stk:pointer) (lt : leak_e_tr) (l : leak_e) : leak_e :=
  match lt, l with
  | LT_map lts, LSub xs => LSub (map2 (leak_E stk) lts xs)
  | LT_seq lts, _ => LSub (map (fun lt => leak_E stk lt l) lts)
  | LT_lidx f, LIdx i => LAdr (mem_leak_ (eval_leak_tr_p stk (f i)))
  | LT_const f, _     => LAdr (mem_leak_ (eval_leak_tr_p stk f))
  | LT_id, _ => l
  | LT_remove, _ => LEmpty
  | LT_subi i, LSub xs => nth LEmpty xs i
  | LT_compose lt1 lt2, _ => leak_E stk lt2 (leak_E stk lt1 l)
  | _, _ => LEmpty
  end.

Definition leak_E_S (stk: pointer) (lts: seq leak_e_tr) (ls : seq leak_e) : seq leak_e :=
  map2 (leak_E stk) lts ls.

Lemma lt_composeE p x y :
  leak_E p (lt_compose x y) =1 leak_E p (LT_compose x y).
Proof.
  rewrite /lt_compose.
  case: x; first by [].
  all: by case: y.
Qed.
Global Opaque lt_compose.

(* Transformation from leakage to sequence of leakage *)
Local Notation π₀ := (LT_subi 0).
Local Notation π₁ := (LT_subi 1).

Definition LT_leseq : leak_e_tr := LT_seq [:: LT_subi 0 ].
Definition LT_emseq : leak_e_tr := LT_remove.
Definition LT_subseq (lte: leak_e_tr) : leak_e_tr := LT_seq [:: LT_compose (LT_subi 0) lte ].
Definition LT_idseq (lte: leak_e_tr) : leak_e_tr := LT_compose (LT_subi 0) lte.
Definition LT_idseq' (lte: leak_e_tr) : leak_e_tr := LT_seq [:: LT_compose lte (LT_compose π₀ (LT_compose π₀ π₀)); LT_compose lte (LT_compose π₀ π₁) ].
Definition LT_dfst : leak_e_tr := LT_seq [:: LT_remove ; LT_remove ; LT_remove ; LT_remove ; LT_remove ; LT_id ; LT_remove ].
Definition LT_dsnd : leak_e_tr := LT_seq [:: LT_remove ; LT_remove ; LT_remove ; LT_remove ; LT_remove ; LT_remove ; LT_id ].

Definition LT_iconditionl : seq leak_e_tr := [:: LT_seq [:: π₀ ; π₁ ; LT_seq [:: LT_remove; LT_remove; LT_remove; LT_remove; LT_remove] ] ].
Definition LT_iemptyl : seq leak_e_tr := [::].

End Section.

Inductive leak_i_tr :=
(* structural transformation *)
| LT_ikeep : leak_i_tr             (* same as source *)
| LT_iopn : seq leak_e_tr -> leak_i_tr  (* assign and op *)
| LT_icondl : seq leak_e_tr -> leak_e_tr -> seq leak_i_tr -> seq leak_i_tr -> leak_i_tr (* if *)
| LT_iwhile : seq leak_i_tr -> leak_e_tr -> seq leak_i_tr -> leak_i_tr (* while *)      
| LT_ifor : leak_e_tr -> seq leak_i_tr -> leak_i_tr                  
| LT_icall : funname -> seq leak_e_tr -> seq leak_e_tr -> leak_i_tr

(* modify the control flow *)
| LT_iremove : leak_i_tr                                         
| LT_icond_eval : bool -> seq leak_i_tr -> leak_i_tr    
| LT_ifor_unroll: nat -> seq leak_i_tr -> leak_i_tr
| LT_icall_inline: nat -> funname -> nat -> nat -> leak_i_tr

(* lowering leak transformers *)
| LT_iwhilel :  seq leak_e_tr -> leak_e_tr -> seq leak_i_tr -> seq leak_i_tr -> leak_i_tr
.

Notation LT_ile lt := (LT_iopn [:: lt ]).
Notation LT_icond := (LT_icondl [::]).

Section Section.

Context {LO: LeakOp}.

(* Transformation from expression leakage to instruction leakage *)
Definition leak_EI (stk: pointer) (lti: seq leak_e_tr) (le: leak_e) : seq leak_i :=
  [seq Lopn (leak_E stk lte le) | lte <- lti ].

Section Leak_I.

  Variable leak_I : pointer -> leak_i -> leak_i_tr -> seq leak_i.

  Definition leak_Is (stk : pointer) (lts : seq leak_i_tr) (ls : seq leak_i) : seq leak_i :=
    flatten (map2 (leak_I stk) ls lts).

  Definition leak_Iss (stk: pointer) (ltss : seq leak_i_tr) (ls : seq (seq leak_i)) : seq (seq leak_i) :=
    (map (leak_Is stk ltss) ls). 

End Leak_I.

Section Leak_Call.

Variable leak_Fun : funname -> seq leak_i_tr.

Definition dummy_lit := Lopn LEmpty.

Definition leak_assgn := 
  Lopn (LSub [:: LEmpty ; LEmpty]).

Fixpoint leak_I (stk:pointer) (l : leak_i) (lt : leak_i_tr) {struct l} : seq leak_i :=
  match lt, l with
  | LT_ikeep, _ => 
    [::l]

  | LT_iopn ltes, Lopn le =>
      [seq Lopn (leak_E stk lte le) | lte <- ltes ]

  | LT_icondl lti' lte ltt ltf, Lcond le b lti =>
     leak_EI stk lti' le ++
     [:: Lcond (leak_E stk lte le) b (leak_Is leak_I stk (if b then ltt else ltf) lti) ]

  | LT_iwhile ltis lte ltis', Lwhile_true lts le lts' lw => 
    [:: Lwhile_true (leak_Is leak_I stk ltis lts)
                     (leak_E stk lte le)
                     (leak_Is leak_I stk ltis' lts')
                     (head dummy_lit (leak_I stk lw lt))]

  | LT_iwhile ltis lte ltis', Lwhile_false lts le => 
    [::Lwhile_false (leak_Is leak_I stk ltis lts)
                     (leak_E stk lte le)]

  | LT_ifor lte ltiss, Lfor le ltss => 
    [:: Lfor (leak_E stk lte le)
             (leak_Iss leak_I stk ltiss ltss) ]

  | LT_icall _f lte lte', Lcall le (f, lts) le' => 
    (* _f should be equal to f *)
    [:: Lcall (map2 (leak_E stk) lte le)
              (f, (leak_Is leak_I stk (leak_Fun f) lts))
              (map2 (leak_E stk) lte' le') ]


  (** Modification of the control flow *)
  | LT_iremove, _ => 
    [::]

  | LT_icond_eval _b lts, Lcond _ b lti => 
    (* _b should be equal b *)
    leak_Is leak_I stk lts lti

  | LT_icond_eval _b lts, Lwhile_false lti le => 
    leak_Is leak_I stk lts lti

  | LT_ifor_unroll _n ltiss, Lfor le ltss => 
    (* _n should be equal to size ltss *)
    flatten (map (fun l => leak_assgn :: l) (leak_Iss leak_I stk ltiss ltss))

  | LT_icall_inline nargs _fn ninit nres, Lcall le (f, lts) le' => 
    (* nargs = size le, _fn = fn, nres = size le') *)
    map (fun x => (Lopn (LSub [:: x; LEmpty]))) le ++
    nseq ninit (Lopn (LSub [:: LEmpty; LEmpty])) ++ 
    leak_Is leak_I stk (leak_Fun f) lts ++
    map (fun y => (Lopn (LSub [:: LEmpty; y]))) le'

  (* lowering *)
    (* lti ->  b = [e] (* makes boolean expression as b = [e] *) (* trasforms expression leakage to instruction Copn leakage *)
       lte -> leak_e_tr 
       ltt -> leak_i_tr for true branch 
       ltf -> leak_i_tr for false branch *)
  | LT_iwhilel lti lte ltis ltis', Lwhile_true lts le lts' lw => 
    [:: Lwhile_true ((leak_Is leak_I stk ltis lts) ++ (leak_EI stk lti le))
                     (leak_E stk lte le)
                     (leak_Is leak_I stk ltis' lts')
                     (head dummy_lit (leak_I stk lw lt))]

  | LT_iwhilel lti lte ltis ltis', Lwhile_false lts le => 
    [::Lwhile_false ((leak_Is leak_I stk ltis lts) ++ (leak_EI stk lti le)) (leak_E stk lte le)]


  | _, _ => [:: l]
  end.

Inductive leak_WF : leak_i_tr -> leak_i -> Prop :=
 | LT_ikeepWF : forall le, leak_WF LT_ikeep (Lopn le)
 | LT_iopnWF : forall le ltes, leak_WF (LT_iopn ltes) (Lopn le)
 | LT_icondltWF : forall lti' lte ltt ltf le lti,
                  leak_WFs ltt lti ->
                  leak_WF (LT_icondl lti' lte ltt ltf) (Lcond le true lti)
 | LT_icondlfWF : forall lti' lte ltt ltf le lti,
                  leak_WFs ltf lti ->
                  leak_WF (LT_icondl lti' lte ltt ltf) (Lcond le false lti)
 | LT_iwhiletWF : forall ltis lte ltis' lts le lts' lw,
                  leak_WFs ltis lts ->
                  leak_WFs ltis' lts' ->
                  leak_WF (LT_iwhile ltis lte ltis') lw ->
                  leak_WF (LT_iwhile ltis lte ltis') (Lwhile_true lts le lts' lw)
 | LT_iwhilefWF : forall ltis lte ltis' lts le,
                  leak_WFs ltis lts ->
                  leak_WF (LT_iwhile ltis lte ltis') (Lwhile_false lts le)
 | LT_iforWF: forall lte ltiss le ltss,
              leak_WFss ltiss ltss ->
              leak_WF (LT_ifor lte ltiss) (Lfor le ltss)
 | LT_icallWF : forall f lte lte' le lts le',
                leak_WFs (leak_Fun f) lts ->
                leak_WF (LT_icall f lte lte') (Lcall le (f, lts) le')
 | LT_iremoveWF : forall l,
                  leak_WF LT_iremove l
 | LT_icond_evalWF : forall b lts le lti,
                     leak_WFs lts lti ->
                     leak_WF (LT_icond_eval b lts) (Lcond le b lti)
 | LT_icond_evalWF' : forall lts lti le,
                      leak_WFs lts lti ->
                      leak_WF (LT_icond_eval false lts) (Lwhile_false lti le)
 | LT_ifor_unrollWF : forall ltiss le ltss,
                      leak_WFss ltiss ltss ->
                      leak_WF (LT_ifor_unroll (size ltss) ltiss) (Lfor le ltss)
 | LT_icall_inlineWF : forall ninit les f lts les',
                       leak_WFs (leak_Fun f) lts ->
                       leak_WF (LT_icall_inline (size les) f ninit (size les')) (Lcall les (f, lts) les')
 (* Lowering *)
 | LT_iwhilelWF : forall lti lte ltis ltis' lts le lts' lw,
                  leak_WFs ltis lts ->
                  leak_WFs ltis' lts' ->
                  leak_WF (LT_iwhilel lti lte ltis ltis') lw ->
                  leak_WF (LT_iwhilel lti lte ltis ltis') (Lwhile_true lts le lts' lw)  
 | LT_iwhilelWF' : forall lti lte ltis ltis' lts le,
                   leak_WFs ltis lts ->
                   leak_WF (LT_iwhilel lti lte ltis ltis') (Lwhile_false lts le)

with leak_WFs : seq leak_i_tr -> leak_c -> Prop :=
 | WF_empty : leak_WFs [::] [::]
 | WF_seq : forall li lc lt1 lt1',
            leak_WF lt1 li ->
            leak_WFs lt1' lc ->
            leak_WFs (lt1 :: lt1') (li::lc)

with leak_WFss : seq leak_i_tr -> seq leak_c -> Prop :=
 | WF_empty' : forall lt, leak_WFss lt [::]
 | WF_seq' : forall lc lcs lt,
            leak_WFs lt lc ->
            leak_WFss lt lcs ->
            leak_WFss lt (lc :: lcs).

End Leak_Call.

End Section.

Notation leak_c_tr := (seq leak_i_tr).

Definition leak_f_tr := seq (funname * leak_c_tr).

Section Leak_Call_Imp.

Variable Fs: leak_f_tr.

Definition leak_Fun (f: funname) : leak_c_tr := odflt [::] (assoc Fs f).

End Leak_Call_Imp.

Section Section.

Context {LO: LeakOp}.

Fixpoint leak_compile (stk : pointer) (lts: seq leak_f_tr) (lf: leak_fun) := 
  match lts with 
  | [::] => lf.2
  | x :: xs => 
    let r := leak_Is (leak_I (leak_Fun x)) stk (leak_Fun x lf.1) lf.2 in 
    leak_compile stk xs (lf.1, r)
  end.

(** Leakage for intermediate-level **)

Variant leak_il : Type :=
  | Lempty0 : leak_il
  | Lempty : int -> leak_il 
  | Lopnl : leak_e -> leak_il
  | Lcondl : int -> leak_e -> bool -> leak_il. 

Notation leak_funl := (funname * seq leak_il).

Definition leak_cl := seq leak_il.

Inductive leak_i_il_tr : Type :=
  | LT_ilopn : leak_e_tr -> leak_i_il_tr
  | LT_ilcond_0 : leak_e_tr -> seq leak_i_il_tr -> leak_i_il_tr (*c1 is empty*)
  | LT_ilcond_0' : leak_e_tr -> seq leak_i_il_tr -> leak_i_il_tr (*c2 is empty*)
  | LT_ilcond : leak_e_tr -> seq leak_i_il_tr -> seq leak_i_il_tr -> leak_i_il_tr (* c1 and c2 are not empty *)
  | LT_ilwhile_c'0 : align -> seq leak_i_il_tr -> leak_i_il_tr
  | LT_ilwhile_f : seq leak_i_il_tr -> leak_i_il_tr
  | LT_ilwhile : align -> seq leak_i_il_tr -> seq leak_i_il_tr -> leak_i_il_tr.

End Section.

(* Computes the leakage depending on alignment *) 
Definition get_align_leak_il a : seq leak_il :=
  match a with 
  | NoAlign => [::]
  | Align => [:: Lempty0]
  end.

Definition get_align_size a : nat :=
match a with 
 | NoAlign => 0
 | Align => 1
end.

Definition incr n (l:seq (nat * leak_il)) := map (fun p => (p.1 + n, p.2)) l.

Definition get_linear_size_c (f : leak_i_il_tr -> nat) (ltc : seq leak_i_il_tr) :=
foldr (fun lti n => f lti + n) 0 ltc. 

Fixpoint get_linear_size (lti : leak_i_il_tr) : nat :=
  match lti with
  | LT_ilopn _ => 1
  | LT_ilcond_0 lte lti => get_linear_size_c get_linear_size lti + 2
  | LT_ilcond_0' lte lti => get_linear_size_c get_linear_size lti + 2
  | LT_ilcond lte lti lti' => get_linear_size_c get_linear_size lti + get_linear_size_c get_linear_size lti' + 4
  | LT_ilwhile_c'0 a lti => get_linear_size_c get_linear_size lti + (get_align_size a) + 2
  | LT_ilwhile_f lti => get_linear_size_c get_linear_size lti 
  (* goto L1; align; Lilabel L2; c'; Lilabel L1; c; Lcond e L2 *)
  | LT_ilwhile a lti lti' => get_linear_size_c get_linear_size lti + get_linear_size_c get_linear_size lti' + (get_align_size a) + 4
  end.

Definition get_linear_size_C := get_linear_size_c get_linear_size.

Section Section.

Context {LO: LeakOp}.

Section Leak_IL.

  Variable leak_i_iL : pointer -> leak_i ->  leak_i_il_tr -> seq leak_il.

  Definition leak_i_iLs (stk : pointer) (lts : seq leak_i_il_tr) (ls : seq leak_i) : seq leak_il :=
    flatten (map2 (leak_i_iL stk) ls lts).

  (* align; Lilabel L1; c ; Licond e L1 *)
  Fixpoint ilwhile_c'0 (stk: pointer) (lti : seq leak_i_il_tr) (li : leak_i) : seq leak_il :=
    match li with 
    | Lwhile_false lis le => 
      leak_i_iLs stk lti lis ++ [:: Lcondl 1 le false]
    | Lwhile_true lis le lis' li' => 
      leak_i_iLs stk lti lis ++ [:: Lcondl (-(Posz (get_linear_size_C lti))%R) le true] ++ ilwhile_c'0 stk lti li'
    | _ => [::]
    end.

  (* Lilabel L2; c'; Lilabel L1; c; Lcond e L2 *)
  Fixpoint ilwhile (stk : pointer) (lts : seq leak_i_il_tr) (lts' : seq leak_i_il_tr) (li : leak_i) 
             : seq leak_il :=
    match li with 
    | Lwhile_false lis le => 
      leak_i_iLs stk lts lis ++ [:: Lcondl 1 le false]
    | Lwhile_true lis le lis' li' =>
      leak_i_iLs stk lts lis ++ [:: Lcondl (-(Posz (get_linear_size_C lts + get_linear_size_C lts' +1)))%R le true] ++ 
      leak_i_iLs stk lts' lis' ++ [:: Lempty0] ++ ilwhile stk lts lts' li'
    | _ => [::]
    end.

End Leak_IL.

Fixpoint leak_i_iL (stk:pointer) (li : leak_i) (l : leak_i_il_tr) {struct li} : seq leak_il :=
  match l, li with
  | LT_ilopn tr , Lopn le =>
    [:: Lopnl (leak_E stk tr le) ]

    (*if e then [::] else c2*) (* Licond e l; c2; label l (n+2)*)
  | LT_ilcond_0 lte lti, Lcond le b lis => 
    if b then [:: Lcondl (Posz (get_linear_size_C lti) + 2)%R (leak_E stk lte le) b] ++ [::] 
    else [:: Lcondl 1 (leak_E stk lte le) b] ++ leak_i_iLs leak_i_iL stk lti lis ++ [:: Lempty0]

    (*[:: Lcondl 0 (leak_E stk lte le) b] ++ 
    if b then [::] 
    else leak_i_iLs leak_i_iL stk lti lis ++ [:: Lempty0]*)

    (*let lcn := leak_i_iLs leak_i_iL stk lti lis in
    ([:: 0, Lcondl (leak_E stk lte le) b] ++ 
    incr 1 (if b then [::] else lcn.1 ++ [:: lcn.2, Lempty0]),
    lcn.2 + 2)*)
  | LT_ilcond_0' lte lti, Lcond le b lis => 
    if negb b then [:: Lcondl (Posz (get_linear_size_C lti) + 2) (leak_E stk lte le) (negb b)] ++ [::]
    else [:: Lcondl 1 (leak_E stk lte le) (negb b)] ++ leak_i_iLs leak_i_iL stk lti lis ++ [:: Lempty0]

    (*[:: Lcondl 0 (leak_E stk lte le) (negb b)] ++ 
    if negb b then [::] 
    else leak_i_iLs leak_i_iL stk lti lis ++ [:: Lempty0]*)

    (*let lcn := leak_i_iLs leak_i_iL stk lti lis in
    ([:: 0, Lcondl (leak_E stk lte le) (negb b)] ++ 
    incr 1 (if negb b then [::] else lcn.1 ++ [:: lcn.2, Lempty0]),
    lcn.2 + 2)*)
    
    (* if e then c1 else c2 *)
    (* Licond e L1; c2; Ligoto L2; Lilabel L1; c1; Lilabel L2 (*n1+n2+4*) *)
  | LT_ilcond lte lti lti', Lcond le b lis => 
    if b then [:: Lcondl (Posz (get_linear_size_C lti') + 3) (leak_E stk lte le) b] ++ leak_i_iLs leak_i_iL stk lti lis 
              ++ [:: Lempty0]
    else [:: Lcondl 1 (leak_E stk lte le) b] ++ leak_i_iLs leak_i_iL stk lti' lis ++ [:: Lempty (Posz (get_linear_size_C lti) +3)]


    (*[:: Lcondl 1 (leak_E stk lte le) b] ++ 
    if b then leak_i_iLs leak_i_iL stk lti lis ++ [:: Lempty0]
    else leak_i_iLs leak_i_iL stk lti' lis ++ [:: Lempty (n2+1)]*)

    (*let lcn := 
      leak_i_iLs leak_i_iL stk (if b then lti else lti') lis in 
    let lc := lcn.1 ++ [:: (lcn.2, if b then Lempty0 else Lempty)] in
    [:: (0, Lcondl (leak_E stk lte le) b)] ++ incr 1 lc, lcn.2 + 2) *)
    
    (* align; Lilabel L1; c ; Licond e L1 *)
    (* while a c e [::] *)
  | LT_ilwhile_c'0 a lti, _ => 
    get_align_leak_il a ++ [:: Lempty0 & ilwhile_c'0 leak_i_iL stk lti li]

    
  | LT_ilwhile_f lti, Lwhile_false lis le => 
    leak_i_iLs leak_i_iL stk lti lis

    (* Ligoto L1; align; Lilabel L2; c'; Lilabel L1; c; Lcond e L2 ; 
         c'; Lilabel L1; c; Lcond e L2; .....*)
    (* while a c e c' *)
  | LT_ilwhile a lti lti', _ => 
    [:: Lempty (Posz (get_linear_size_C lti' + (get_align_size a + 3)))] ++ 
      ilwhile leak_i_iL stk lti lti' li 

  | _, _ => [::]
  end.

End Section.

Notation leak_c_il_tr := (seq leak_i_il_tr).

Definition leak_f_lf_tr := seq (funname * seq leak_i_il_tr).

Inductive leak_i_WF : leak_i_il_tr -> leak_i -> Prop :=
| LT_ilopnWF : forall tr le, leak_i_WF (LT_ilopn tr) (Lopn le)
| LT_ilcond_0tWF : forall le lte lti,
                  leak_i_WF (LT_ilcond_0 lte lti) (Lcond le true [::])
| LT_ilcond_0fWF : forall le lis lte lti,
                  leak_is_WF lti lis ->
                  leak_i_WF (LT_ilcond_0 lte lti) (Lcond le false lis)
| LT_icond_0tWF' : forall le lis lte lti,
                  leak_is_WF lti lis ->
                  leak_i_WF (LT_ilcond_0' lte lti) (Lcond le true lis)
| LT_icond_0fWF' : forall le lte lti,
                  leak_i_WF (LT_ilcond_0' lte lti) (Lcond le false [::])
| LT_ilcondtWF : forall le lis lte lti lti',
                leak_is_WF lti lis ->
                leak_i_WF (LT_ilcond lte lti lti') (Lcond le true lis)
| LT_ilcondfWF : forall le lis lte lti lti',
                leak_is_WF lti' lis ->
                leak_i_WF (LT_ilcond lte lti lti') (Lcond le false lis)
| LT_ilwhile_fWF : forall le lis lti,
                   leak_is_WF lti lis ->
                   leak_i_WF (LT_ilwhile_f lti) (Lwhile_false lis le)
| LT_ilwhile_c'0WF : forall li a lti,
                     leak_w0_WF lti li ->
                     leak_i_WF (LT_ilwhile_c'0 a lti) li 
| LT_ilwhileWF : forall a li lti lti',
                 leak_w_WF lti lti' li ->
                 leak_i_WF (LT_ilwhile a lti lti') li

with leak_is_WF : seq leak_i_il_tr -> leak_c -> Prop :=
 | WF_i_empty : leak_is_WF [::] [::]
 | WF_i_seq : forall li lc lt1 lt1',
            leak_i_WF lt1 li ->
            leak_is_WF lt1' lc ->
            leak_is_WF (lt1 :: lt1') (li::lc)

with leak_w0_WF  : seq leak_i_il_tr -> leak_i -> Prop := 
 | LW0_false : forall lti lis le, leak_is_WF lti lis -> leak_w0_WF lti (Lwhile_false lis le)
 | LW0_true  : forall lti lis le lis' li', 
      leak_is_WF lti lis ->
      leak_w0_WF lti li' -> 
      leak_w0_WF lti (Lwhile_true lis le lis' li')

with leak_w_WF  : seq leak_i_il_tr -> seq leak_i_il_tr -> leak_i -> Prop := 
    | LW_false : forall lti lti' lis le, leak_is_WF lti lis -> leak_w_WF lti lti' (Lwhile_false lis le)
    | LW_true  : forall lti lti' lis le lis' li', 
      leak_is_WF lti lis ->
      leak_is_WF lti' lis' ->
      leak_w_WF lti lti' li' -> 
      leak_w_WF lti lti' (Lwhile_true lis le lis' li').

Section Section.

Context {LO: LeakOp}.

Fixpoint leak_WF_rec fn stk (lts:seq (seq (funname * leak_c_tr))) lc := 
  match lts with 
  | [::] => True
  | lF :: lts => leak_WFs (leak_Fun lF) (leak_Fun lF fn) lc /\
               let lc := leak_Is (leak_I (leak_Fun lF)) stk (leak_Fun lF fn) lc in
               leak_WF_rec fn stk lts lc
  end.

Lemma leak_WF_rec_cat fn stk lts1 lts2 lc :
  leak_WF_rec fn stk lts1 lc -> 
  leak_WF_rec fn stk lts2 (leak_compile stk lts1 (fn, lc)) ->
  leak_WF_rec fn stk (lts1 ++ lts2) lc.
Proof. by elim: lts1 lc => //= lF lts1 hrec lc [?] h1 h2; split => //; apply hrec. Qed.

End Section.

Section Leak_Call_Imp_L.

Variable Fs: leak_f_lf_tr.

Definition leak_Fun_L (f: funname) : seq leak_i_il_tr := odflt [::] (assoc Fs f).

End Leak_Call_Imp_L.

(** Leakage for assembly-level **)

Inductive leak_asm : Type :=
  | Laempty0 : leak_asm
  | Laempty : int -> leak_asm
  | Lacond : int -> bool -> leak_asm (* bool represents the condition in conditional jump *)
  | Laop : seq pointer -> leak_asm.

(* Extracts the sequence of pointers from leak_e *)
Fixpoint leak_e_asm (l : leak_e) : seq pointer :=
  match l with 
  | LEmpty => [::]
  | LIdx i => [::]
  | LAdr p => [:: p]
  | LSub l => flatten (map leak_e_asm l)
  end.

(* Transforms leakage for intermediate langauge to leakage for assembly *)
Definition leak_i_asm (l : leak_il) : leak_asm :=
  match l with 
  | Lempty0 => Laempty0
  | Lempty i => Laempty i
  | Lopnl le => Laop (leak_e_asm le)
  | Lcondl i le b => Lacond i b
  end.

Section Section.

Context {LO: LeakOp}. 

Lemma leak_compile_cat stk lts1 lts2 lf: 
  leak_compile stk (lts1 ++ lts2) lf = leak_compile stk lts2 (lf.1, (leak_compile stk lts1 lf)).
Proof. case: lf => fn lc; elim: lts1 lc => //=. Qed.

Definition leak_compile_prog (stk: pointer) (lts: seq leak_f_tr * leak_f_lf_tr) (lf: leak_fun) : seq leak_il :=
  let r  := leak_compile stk lts.1 lf in
  leak_i_iLs leak_i_iL stk (leak_Fun_L lts.2 lf.1) r.

Definition leak_compile_x86 (stk: pointer) (lts: seq leak_f_tr * leak_f_lf_tr) (lf: leak_fun) : seq leak_asm :=
  let r := leak_compile_prog stk lts lf in
  map (fun x=> leak_i_asm x) r.

End Section.
