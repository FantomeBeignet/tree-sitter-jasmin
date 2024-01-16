From mathcomp Require Import all_ssreflect all_algebra.
From mathcomp Require Import word_ssrZ.
Require Import psem_defs typing typing_proof.

Section Safety_conditions.

Context
  {asm_op syscall_state : Type}
  {ep : EstateParams syscall_state}
  {spp : SemPexprParams}
  {wsw : WithSubWord}
  (wdb : bool)
  (gd : glob_decls).

(* can be used to check that an expression does not evaluate to 0 *)
Definition not_zero_pexpr (e1 e2 : pexpr) (s : @estate nosubword syscall_state ep) :=
forall v n, sem_pexpr (wsw:= nosubword) false gd s e2 = ok v -> 
            to_int v = ok n -> 
n <> 0.

(* checks that a variable is defined in the memory *)
Definition defined_var (x : var_i) (s : @estate nosubword syscall_state ep) : bool :=
is_defined (evm s).[x].

Definition get_len_stype (t : stype) : positive :=
match t with 
| sbool => xH
| sint => xH 
| sarr n => n
| sword w => xH
end.

(* Here len is the array length which is obtained from get_gvar *)
Definition is_align_check (aa : arr_access) (ws : wsize) (e : pexpr) 
(s : @estate nosubword syscall_state ep) :=
forall v i, sem_pexpr (wsw:= nosubword) false gd s e = ok v -> 
            to_int v = ok i -> 
is_align (i * mk_scale aa ws)%Z ws. 

Definition in_range_check (aa : arr_access) (ws : wsize) (x : var_i) (e : pexpr) 
(s : @estate nosubword syscall_state ep) :=
forall v i, sem_pexpr (wsw:= nosubword) false gd s e = ok v -> 
            to_int v = ok i -> 
WArray.in_range (get_len_stype x.(v_var).(vtype)) (i * mk_scale aa ws)%Z ws. 

(* Here len is the array length which is obtained from get_gvar *)
Definition in_sub_range_check (aa : arr_access) (ws : wsize) (slen : positive) (x : var_i) (e : pexpr) 
(s : @estate nosubword syscall_state ep) :=
forall v i, sem_pexpr (wsw:= nosubword) false gd s e = ok v -> 
                to_int v = ok i -> 
((0 <=? (i * mk_scale aa ws))%Z && ((i * mk_scale aa ws + arr_size ws slen) <=? (get_len_stype x.(v_var).(vtype)))%Z).

(* checks if the address is valid or not *)
Definition addr_check (x : var_i) (ws : wsize) (e : pexpr) (s : @estate nosubword syscall_state ep) :=
forall vx ve w1 w2, defined_var vx s ->
              sem_pexpr (wsw:= nosubword) false gd s e = ok ve ->
              to_pointer (evm s).[vx] = ok w1 ->
              to_pointer ve = ok w2 ->
validw (emem s) (w1 + w2)%R ws.

Inductive safe_cond : Type :=
| Defined_var : var_i -> safe_cond
| Not_zero : pexpr -> pexpr -> safe_cond
| Is_align : pexpr -> arr_access -> wsize -> safe_cond
| In_range : pexpr -> arr_access -> wsize -> var_i -> safe_cond
| In_sub_range : pexpr -> arr_access -> wsize -> positive -> var_i -> safe_cond
| Is_valid_addr : pexpr -> var_i -> wsize -> safe_cond.


(* checks the safety condition for operations: except division and modulo, rest of the operations are safe without any 
   explicit condition *)
Definition gen_safe_cond_op2 (op : sop2) (e1 e2 : pexpr) : seq safe_cond :=
match op with 
| Odiv ck => match ck with 
             | Cmp_w u sz => [:: Not_zero e1 e2]
             | Cmp_int => [::]
             end
| Omod ck => match ck with 
             | Cmp_w u sz => [:: Not_zero e1 e2]
             | Cmp_int => [::]
             end
| _ => [::]
end.

Definition interp_safe_cond_op2 (s : @estate nosubword syscall_state ep) (op : sop2) (e1 e2 : pexpr) (sc: seq safe_cond) :=
match sc with 
| [::] => True 
| [:: sc] => not_zero_pexpr e1 e2 s
| _ => True
end. 

Section gen_safe_conds. 

Variable gen_safe_cond : pexpr -> seq safe_cond.

Fixpoint gen_safe_conds (es : seq pexpr) : seq (seq safe_cond) := 
match es with
| [::] => [::]
| e :: es => gen_safe_cond e :: gen_safe_conds es
end. 

End gen_safe_conds.    

Fixpoint gen_safe_cond (e : pexpr) : seq safe_cond :=
match e with   
| Pconst _ | Pbool _ | Parr_init _ => [::] 
| Pvar x => [:: Defined_var (gv x)]
| Pget aa ws x e => gen_safe_cond e ++ [:: Defined_var (gv x); Is_align e aa ws; In_range e aa ws (gv x)] 
| Psub aa ws p x e => gen_safe_cond e ++
                     [:: Defined_var (gv x); Is_align e aa ws; In_sub_range e aa ws p (gv x)]
| Pload ws x e => gen_safe_cond e ++ [:: Defined_var x; Is_valid_addr e x ws] 
| Papp1 op e => gen_safe_cond e
| Papp2 op e1 e2 => gen_safe_cond e1 ++ gen_safe_cond e2 ++ gen_safe_cond_op2 op e1 e2
| PappN op es => flatten (gen_safe_conds (gen_safe_cond) es)
| Pif t e1 e2 e3 => gen_safe_cond e1 ++ gen_safe_cond e2 ++ gen_safe_cond e3
end.

Section safe_pexprs.

Variable safe_pexpr : @estate nosubword syscall_state ep -> pexpr -> seq safe_cond -> Prop.

End safe_pexprs. 

Fixpoint interp_safe_cond (sc : safe_cond) (s : @estate nosubword syscall_state ep) : Prop :=
match sc with 
| Defined_var x => defined_var x s
| Not_zero e1 e2 => not_zero_pexpr e1 e2 s
| Is_align e aa ws => is_align_check aa ws e s
| In_range e aa ws x => in_range_check aa ws x e s
| In_sub_range e aa ws len x => in_sub_range_check aa ws len x e s
| Is_valid_addr e x ws => addr_check x ws e s
end.

Fixpoint interp_safe_conds (sc : seq safe_cond) (s : @estate nosubword syscall_state ep) : Prop :=
match sc with 
| [::] => True 
| sc1 :: sc2 => interp_safe_cond sc1 s /\ interp_safe_conds sc2 s
end.

(*Fixpoint safe_pexpr (s : @estate nosubword syscall_state ep) (e: pexpr) (sc : seq safe_cond)  := 
match e with 
 | Pconst _ | Pbool _ | Parr_init _ => True 
 | Pvar x => defined_var (gv x) s
 | Pget aa ws x e => defined_var (gv x) s /\ safe_pexpr s e sc /\ alignment_range_check aa ws (gv x) e s
 | Psub aa ws p x e => defined_var (gv x) s /\ safe_pexpr s e sc /\ alignment_sub_range_check aa ws p (gv x) e s
 | Pload ws x e => safe_pexpr s e sc /\ defined_var x s /\ addr_check x ws e s
 | Papp1 op e => safe_pexpr s e sc
 | Papp2 op e1 e2 => safe_pexpr s e1 sc /\ safe_pexpr s e2 sc /\ interp_safe_cond_op2 s op e1 e2 sc
 | PappN op es => safe_pexprs (safe_pexpr) s es sc
 | Pif t e1 e2 e3 => safe_pexpr s e1 /\ safe_pexpr s e2 /\ safe_pexpr s e3
end.*)

Lemma interp_safe_concat : forall sc1 sc2 sc3 s,
interp_safe_conds (sc1 ++ sc2 ++ sc3) s ->
interp_safe_conds sc1 s /\ interp_safe_conds sc2 s /\ interp_safe_conds sc3 s.
Proof.
move=> sc1 sc2 sc3 s /=. elim : (sc1 ++ sc2 ++ sc3)=> [h | s1 s2] //=.
+ admit.
move=> hin [] hs1 hs2. by move: (hin hs2)=> [] h1 [] h2 h3.
Admitted.

Lemma wt_safe_truncate_not_error : forall e s v t ty err,
interp_safe_conds (gen_safe_cond e) s ->
sem_pexpr false gd s e = ok v ->
type_of_val v = t ->
subtype ty t ->
truncate_val ty v <> Error err.
Proof.
Admitted.

Lemma safe_not_undef : forall e s he,
interp_safe_conds (gen_safe_cond e) s ->
sem_pexpr false gd s e <> ok (Vundef sbool he).
Proof.
Admitted.

Lemma sem_op1_val_ty : forall tin tout op v vo,
type_of_op1 op = (tin, tout) ->
sem_sop1 op v = ok vo ->
type_of_val vo = tout.
Proof.
move=> tin tout op v vo ht ho.
rewrite /sem_sop1 /= in ho.  move: ho. 
t_xrbindP=> z h1 h2. have := to_valI h2. case: vo h2=> //=.
+ move=> b /= hb [] b' heq; subst. by rewrite -b' /= ht /=. 
+ move=> zi /= hi [] zi' heq; subst. by rewrite -zi' /= ht /=.
+ move=> len a ha [] len' heq; subst. by rewrite -len' /= ht /=.
move=> w w' hw [] wt heq; subst. by rewrite -wt /= ht /=.
Qed.

Lemma wt_safe_sem_op1_not_error : forall pd op tin tout t1 e s v err,
type_of_op1 op = (tin, tout) ->
subtype tin t1 ->
ty_pexpr pd e = ok t1 ->
interp_safe_conds (gen_safe_cond e) s ->
sem_pexpr false gd s e = ok v ->
type_of_val v = t1 ->
sem_sop1 op v <> Error err.
Proof.
Admitted.

Lemma wt_safe_sem_sop2_not_error : forall pd op t1 e1 t2 e2 s ve1 ve2 err,
subtype (type_of_op2 op).1.1 t1 ->
ty_pexpr pd e1 = ok t1 ->
subtype (type_of_op2 op).1.2 t2 ->
ty_pexpr pd e2 = ok t2 ->
interp_safe_conds (gen_safe_cond e1) s ->
interp_safe_conds (gen_safe_cond e2) s ->
interp_safe_conds (gen_safe_cond_op2 op e1 e2) s ->
sem_pexpr false gd s e1 = ok ve1 ->
type_of_val ve1 = t1 ->
sem_pexpr false gd s e2 = ok ve2 ->
type_of_val ve2 = t2 ->
sem_sop2 op ve1 ve2 <> Error err.
Proof.
Admitted.

Lemma wt_safe_read_not_error : forall pd e t (x:var_i) s w ve vp vp' err,
subtype (sword pd) t ->
ty_pexpr pd e = ok t ->
subtype (sword pd) (vtype x) ->
interp_safe_conds (gen_safe_cond e) s ->
interp_safe_conds [:: Defined_var x; Is_valid_addr e x w] s ->
sem_pexpr false gd s e = ok ve ->
type_of_val ve = t ->
to_pointer ve = ok vp ->
to_pointer (evm s).[x] = ok vp' ->
read (emem s) (vp' + vp)%R w <> Error err.
Proof.
Admitted.

Lemma wt_safe_to_pointer_error : forall x s err,
interp_safe_conds [:: (Defined_var x)] s ->
to_pointer (evm s).[x] <> Error err.
Proof.
Admitted.

Lemma wt_safe_exp_to_pointer_error : forall pd e t (x:var_i) s w ve err,
subtype (sword pd) t ->
ty_pexpr pd e = ok t ->
subtype (sword pd) (vtype x) ->
interp_safe_conds (gen_safe_cond e) s ->
interp_safe_conds [:: Is_valid_addr e x w] s ->
sem_pexpr false gd s e = ok ve ->
type_of_val ve = t ->
to_pointer ve <> Error err.
Proof.
Admitted.


Lemma wt_safe_get_gvar_not_error : forall x p s err,
vtype (gv x) = sarr p ->
interp_safe_conds [:: Defined_var (gv x)] s ->
get_gvar false gd (evm s) x <> Error err.
Proof.
Admitted.

Lemma wt_safe_get_gvar_not_undef : forall x p s t i,
vtype (gv x) = sarr p ->
interp_safe_conds [:: Defined_var (gv x)] s ->
get_gvar false gd (evm s) x <> ok (Vundef t i).
Proof.
Admitted.

Lemma wt_arr_ty_not_word : forall x p (s: @estate nosubword syscall_state ep) w sz,
vtype (gv x) = sarr p ->
get_gvar false gd (evm s) x <> ok (Vword (s:=w) sz).
Proof.
Admitted.

Lemma wt_arr_ty_not_int : forall x p (s: @estate nosubword syscall_state ep) z,
vtype (gv x) = sarr p ->
get_gvar false gd (evm s) x <> ok z.
Proof.
Admitted.

Lemma wt_arr_ty_not_bool : forall x p (s: @estate nosubword syscall_state ep) b,
vtype (gv x) = sarr p ->
get_gvar false gd (evm s) x <> ok b.
Proof.
Admitted.

(*Lemma wt_get_gvar_not_bool : forall x p s (b:bool),
vtype (gv x) = sarr p ->
get_gvar false gd (evm s) x <> ok b.
Proof.
Admitted.*)

Lemma wt_safe_read_arr_not_error : forall pd e x p aa sz s arr (p':WArray.array arr) ve vi err,
ty_pexpr pd e = ok sint ->
vtype (gv x) = sarr p ->
interp_safe_conds (gen_safe_cond e ++
          [:: Defined_var (gv x); Is_align e aa sz;
              In_range e aa sz (gv x)]) s ->
get_gvar false gd (evm s) x = ok (Varr p') ->
sem_pexpr false gd s e = ok ve ->
read p' (vi * mk_scale aa sz)%Z sz <> Error err.
Proof.
Admitted.

Lemma wt_safe_to_int_not_error : forall pd e (s: @estate nosubword syscall_state ep) ve err,
ty_pexpr pd e = ok sint ->
sem_pexpr false gd s e = ok ve ->
to_int ve <> Error err.
Proof.
Admitted.

Theorem sem_pexpr_safe : forall pd e s ty,
ty_pexpr pd e = ok ty ->
interp_safe_conds (gen_safe_cond e) s ->
exists v, sem_pexpr (wsw := nosubword) false gd s e = ok v /\ type_of_val v = ty.
Proof.
move=> pd e s. elim: e=> //=.
(* Pconst *)
+ move=> z ty [] ht _; subst. by exists z. 
(* Pbool *)
+ move=> b ty [] ht _; subst. by exists b. 
(* Parr_init *)
+ move=> n ty [] ht _; subst. by exists (Varr (WArray.empty n)).
(* Pvar *)
+ admit.
(* Pget *)
+ move=> aa sz x e hin ty. rewrite /ty_get_set /check_array /=. 
  t_xrbindP=> t hte t'. case ht: (vtype (gv x))=> [  | | p |] //= [] heq; subst.
  rewrite /check_int /check_type /=. case: ifP=> //= /eqP hteq t2 [] hteq' hteq''; subst. move=> hs.
  have [hs1 [hs2 hs3]] := interp_safe_concat (gen_safe_cond e) [:: Defined_var (gv x); Is_align e aa sz;
         In_range e aa sz (gv x)] [::] s hs.
  rewrite /on_arr_var /=. case hg: get_gvar=> [vg | vgr] //=.
  + case hvg: vg=> [b | z | p' arr| w wsz| t i] //=; subst.
    + by have := wt_arr_ty_not_bool x p s b ht.
    + by have := wt_arr_ty_not_int x p s z ht.
    + move: (hin sint hte hs1) => [] ve [] he htve. rewrite he /=. 
      case hi : to_int=> [vi | vr] //=.
      + case hw : WArray.get=> [vw | vwr] //=.
        + exists (Vword (s:=sz) vw). by split=> //=.
        rewrite /WArray.get /= in hw.
        by have := wt_safe_read_arr_not_error pd e x p aa sz s p' arr ve vi vwr hte ht hs hg he.
      by have := wt_safe_to_int_not_error pd e s ve vr hte he. 
    + by have := wt_arr_ty_not_word x p s w wsz ht.
    have [hs1' [hs2' hs3']] := interp_safe_concat [:: Defined_var (gv x)] 
                             [:: Is_align e aa sz] [:: In_range e aa sz (gv x)] s hs2.
    by have := wt_safe_get_gvar_not_undef x p s t i ht hs1'.
  have [hs1' [hs2' hs3']] := interp_safe_concat [:: Defined_var (gv x)] 
                             [:: Is_align e aa sz] [:: In_range e aa sz (gv x)] s hs2.
  by have := wt_safe_get_gvar_not_error x p s vgr ht hs1'.
(* Psub *)
+ move=> aa sz len x e hin ty. rewrite /ty_get_set_sub /check_array /= /check_int /= /check_type /=.
  t_xrbindP => t hte t'. case ht: (vtype (gv x))=> [  | | p |] //= [] heq; subst.
  move=>ti. case: ifP=> //= /eqP hteq [] hteq' hteq''; subst. move=> hs.
  have [hs1 [hs2 hs3]] := interp_safe_concat (gen_safe_cond e) [:: Defined_var (gv x); Is_align e aa sz;
         In_sub_range e aa sz len (gv x)] [::] s hs.
  rewrite /on_arr_var /=. case hg: get_gvar=> [vg | vgr] //=.
  + case hvg: vg=> [b | z | p' arr| w wsz| t i] //=; subst.
    + by have := wt_arr_ty_not_bool x p s b ht.
    + by have := wt_arr_ty_not_int x p s z ht.
    + move: (hin sint hte hs1) => [] ve [] he htve. rewrite he /=. 
      case hi : to_int=> [vi | vr] //=.
      + case hw : WArray.get_sub=> [vw | vwr] //=.
        + exists (Varr vw). by split=> //=.
        rewrite /WArray.get_sub /= in hw. move: hw. case: ifP=> //= /andP [].
        have [hs1' [hs2' hs3']] := interp_safe_concat [:: Defined_var (gv x)] 
                             [:: Is_align e aa sz] [:: In_sub_range e aa sz len (gv x)] s hs2.
        rewrite /interp_safe_conds /= /in_sub_range_check /= ht /= in hs3'. case: hs3'=> hs3' hs3''.
        move: (hs3' ve vi he hi)=> /andP. admit.
      by have := wt_safe_to_int_not_error pd e s ve vr hte he. 
    + by have := wt_arr_ty_not_word x p s w wsz ht.
    have [hs1' [hs2' hs3']] := interp_safe_concat [:: Defined_var (gv x)] 
                             [:: Is_align e aa sz] [:: In_sub_range e aa sz len (gv x)] s hs2.
    by have := wt_safe_get_gvar_not_undef x p s t i ht hs1'.
  have [hs1' [hs2' hs3']] := interp_safe_concat [:: Defined_var (gv x)] 
                             [:: Is_align e aa sz] [:: In_sub_range e aa sz len (gv x)] s hs2.
  by have := wt_safe_get_gvar_not_error x p s vgr ht hs1'.
(* Pload *)
+ move=> w x e hin ty. rewrite /ty_load_store /= /check_ptr /check_type.
  t_xrbindP=> te hte t1. case: ifP=> //= hsub heq t2; subst. 
  case: ifP=> //= hsub' heq' t3 hs; subst. case: heq'=> heq'; subst.
  have [hs1 [hs2 hs3]] := interp_safe_concat (gen_safe_cond e) 
                          ([:: Defined_var x; Is_valid_addr e x w]) [::] s hs.
  move: (hin t2 hte hs1)=> [] ve [] he htve. rewrite he /=.
  case hp: to_pointer=> [vp | vpr] //=.
  + case hp': to_pointer=> [vp' | vpr'] //=.
    + case hr: read=> [vr | vrr] //=.
      + exists (Vword (s:=w) vr). by split=> //=.
      by have /= := wt_safe_read_not_error pd e t2 x s w ve vp vp' vrr hsub' hte hsub hs1 hs2 he htve hp hp'.
    rewrite -cat1s in hs2. 
    have [hs2' [hs2'' hs2''']] := interp_safe_concat ([:: Defined_var x]) ([:: Is_valid_addr e x w]) [::] s hs2.
    by have //= := wt_safe_to_pointer_error x s vpr' hs2'.
  have [hs2' [hs2'' hs2''']] := interp_safe_concat ([:: Defined_var x]) ([:: Is_valid_addr e x w]) [::] s hs2.
  by have //= := wt_safe_exp_to_pointer_error pd e t2 x s w ve vpr hsub' hte hsub hs1 hs2'' he htve.
(* Papp1 *)
+ move=> op e hin ty. case hto: type_of_op1=> [tin tout]. rewrite /check_expr /= /check_type.
  t_xrbindP=> t1 t2 hte. case: ifP=> //= hsub [] heq heq'; subst. 
  move=> hs. move: (hin t1 hte hs)=> [] v [] he ht. rewrite he /=.
  case ho: sem_sop1=> [ vo | vor] //=.
  + exists vo. split=> //=.
    by have := sem_op1_val_ty tin ty op v vo hto ho.
  by have //= := wt_safe_sem_op1_not_error pd op tin ty t1 e s v vor hto hsub hte hs he ht.
(* Papp2 *)
+ move=> op e1 hin1 e2 hin2 ty. rewrite /check_expr /check_type /=.
  t_xrbindP=> t1 t1' ht1. case: ifP=> //= hsub [] hteq t2 t2' ht2; subst.
  case: ifP=> //= hsub' [] hteq' hteq hs; subst.
  have [hs1 [hs2 hs3]]:= interp_safe_concat (gen_safe_cond e1) 
                         (gen_safe_cond e2) (gen_safe_cond_op2 op e1 e2) s hs.
  move: (hin1 t1 ht1 hs1)=> [] ve1 [] he1 hte1.
  move: (hin2 t2 ht2 hs2)=> [] ve2 [] he2 hte2. rewrite he1 /= he2 /=.
  case ho: sem_sop2=> [vo | vor] //=.
  + exists vo. split=> //=. rewrite /sem_sop2 /= in ho.
    move: ho. t_xrbindP=> z h1 z' h2 z1 h3 h4 /=. rewrite -h4 /=. by apply type_of_to_val. 
  by have := wt_safe_sem_sop2_not_error pd op t1 e1 t2 e2 s ve1 ve2 
             vor hsub ht1 hsub' ht2 hs1 hs2 hs3 he1 hte1 he2 hte2 ho.
(* PappN *)
+ move=>op es hin t. admit.
(* Pif *)
move=> t e hin e1 hin1 e2 hin2 ty hty hs. move: hty.
rewrite /check_expr /= /check_type /=. t_xrbindP=> te te' hte. 
case: ifP=> //= /eqP hte' [] heq; subst.
move=> t1 t2 hte1. case: ifP=> //= hsub [] heq; subst.
move=> t2 t3 hte2. case: ifP=> //= hsub' [] heq' heq''; subst.
have [ hs1 [hs2 hs3]]:= interp_safe_concat (gen_safe_cond e) 
                        (gen_safe_cond e1) (gen_safe_cond e2) s hs.
move: (hin sbool hte hs1)=> [] b [] he hbt.
move: (hin1 t1 hte1 hs2)=> [] v1 [] he1 ht1.
move: (hin2 t2 hte2 hs3)=> [] v2 [] he2 ht2.
rewrite he /= he1 /= he2 /=. 
case: b he hbt=> //= b he hbt /=. 
+ case ht: truncate_val=> [vt | vtr] //=.
  + case ht': truncate_val=> [vt' | vtr'] //=.
    + exists (if b then vt' else vt). split=> //=.
      case hb: b he=> //= he.
      + by have := truncate_val_has_type ht'.
      by have := truncate_val_has_type ht.
    by have //= := wt_safe_truncate_not_error e1 s v1 t1 ty vtr' hs2 he1 ht1 hsub.
  by have //= := wt_safe_truncate_not_error e2 s v2 t2 ty vtr hs3 he2 ht2 hsub'.
move=> hbeq; subst. by have //= := safe_not_undef e s he hs1 hbt. 
Admitted.


(*Theorem sem_pexpr_safe : forall e s r,
safe_pexpr s e ->
sem_pexpr (wsw:= nosubword) false gd s e = r ->
is_ok r \/ r = Error ErrType.
Proof.
move=> e s r. move: r s. elim: e.
(* Pconst *)
- move=> z r s /= _ <-. by left.
(* Pbool *)
- move=> b r s /= _ <-. by left.
(* Parr_init *)
- move=> n r s /= _ <-. by left.
(* Pvar *)
- move=> x r s /= hd hg. rewrite /defined_var /is_defined /= in hd.
  rewrite /get_gvar /= in hg. move: hg. case: ifP=> //= -[hlval hgob].
  (* lvar *)
  - rewrite /get_var /= in hgob; subst. by left.
  (* glob *)
  rewrite /get_global /= in hgob. move: hgob. case hgobv : get_global_value=> //=. 
  (* some value *)
  + case: ifP=> //= /eqP ht.
    * move=> <- /=. by left.
    move=> <-. by right.
  (* none *)
  move=> <- /=. by right.
(* Pget *)
- move=> aa sz x e /= hin r s [] hv [] he ha.
  rewrite /on_arr_var /=. case hg : get_gvar=> [vg| er]//=.
  (* get_gvar evaluates to ok *)
  + case hg': vg hg=> [ v1 | v2 | l arr | ws w | t ut ] //=; subst; move=> hg ht; subst.
    * by right.
    * by right.
    * case he': sem_pexpr=> [ve | ver] //=. 
      + case hi : to_int=> [vi | vir ] //=. rewrite /WArray.get /=. 
        rewrite /alignment_range_check /= in ha. move: (ha ve vi l he' hi)=> [] h1 h2.
        case hr: read=> [vr | ver] //=.
        + by left.
        right. by have -> := read_ty_error vi aa sz l arr ver h1 h2 hr.
      right. by have -> := to_int_ty_error s e ve vir he' he hi.
    by move: (hin (Error ver) s he he')=> /=.
    * by right.
    * by right.
  have -> := get_gvar_ty_error s x er hv hg. move=> <- /=. by right.
(* Psub *)
- move=> aa sz len x e /= hin r s [] hd [] hs ha. rewrite /on_arr_var /=. 
  case hg : get_gvar=> [vg | vgr] //=.
  + case hg': vg hg=> [ v1 | v2 | l arr | ws w | t ut ] //=; subst; move=> hg ht; subst.
    * by right.
    * by right.
    * case he': sem_pexpr=> [ve | ver] //=.
      + case hi: to_int=> [vi | vir] //=. case hwa : WArray.get_sub=> [wa | war] //=.
        + by left.
        rewrite /WArray.get_sub in hwa. move: hwa. case: ifP=> //= h.
        rewrite /alignment_sub_range_check in ha. move: (ha ve vi l he' hi)=> [] hal hc.
        by rewrite hc in h.
      have -> := to_int_ty_error s e ve vir he' hs hi. by right.
    by move: (hin (Error ver) s hs he') => /=.
    * by right.
    * by right.
  have -> := get_gvar_ty_error s x vgr hd hg. move=> <- /=. by right.   
(* Pload *)
- move=> sz z e hin r s /= [] hs [] hd ha.
  case hp: to_pointer=> [vp | vpr] //=.
  + case he: sem_pexpr=> [ve | ver] //=.
    + case hp': to_pointer=> [vp' | vpr']//=.
      + case hr: read=> [vr | vre] //=.
        + move=> <-. by left.
        move=> h; subst. rewrite /addr_check in ha.
        move: (ha z ve vp vp' hd he hp hp')=> hw. 
        rewrite /validw in hw. move: hw. move=> /andP [] hal hall. 
        have -> := read_mem_ty_error vp vp' sz s vre hal hr. by right.
       move=> h; subst. have -> := to_pointer_ty_error s e ve vpr' he hs hp'. by right.
     move=> hr; subst. by move: (hin (Error ver) s hs he).
  move=> h; subst. have -> := to_pointer_ty_error' s z vpr hd hp. by right.
(* Papp1 *)
- move=> op e hin r s /= hs /=.
  case he: sem_pexpr=> [ve | ver] //=.
  + rewrite /sem_sop1 /=. case hv: of_val=> [vv | vvr] //=.
    + move=> <-. by left.
    move=> h; subst. have -> := of_val_ty_error (type_of_op1 op).1 s e ve vvr he hs hv.
    by right.
  move=> h; subst. by move: (hin (Error ver) s hs he).
(* Papp2 *)
- move=> op e1 hin e2 hin' r s /= [] hs1 [] hs2 hs3.
  case he2: sem_pexpr=> [ve2 | ver2] //=.
  + case he1: sem_pexpr=> [ve1 | ver1] //=.
    + move=> ho. by have := sem_sop2_safe s op e1 ve1 e2 ve2 r hs3 he1 he2 ho.
    move=> h; subst. by move: (hin (Error ver1) s hs1 he1).
  case he1: sem_pexpr=> [ve1 | ver1] //=. 
  + move=> h; subst. by move: (hin' (Error ver2) s hs2 he2).
  move=>h; subst. by move: (hin (Error ver1) s hs1 he1). 
(* PappN *)
- move=> op es hin r s hs /=. 
  case hm: mapM=> [vm | vmr] //= ho. 
  + case hr: r ho=> [vo | vor] //=.
    + subst. by left.
    move=> ho. have -> := sem_opN_safe s es vm vor op hs hm ho. by right.
  subst. case: es hin hs hm=> //= e es hin [] hse hses.
  case h: sem_pexpr=> [ve | ver] //=.
  + case hm: mapM=> [vs | vsr] //=.
    + move=> [] heq; subst. have heq : e = e \/ List.In e es. + by left.
      have -> := sem_pexprs_ty_error s es vmr hses hm. by right.
    have heq : e = e \/ List.In e es. + by left.
    move=> [] h'; subst. by move: (hin e heq (Error vmr) s hse h)=> /=.
move=> t e hie e1 hie1 e2 hie2 r s /= [] hse [] hse1 hse2.
case he2: sem_pexpr=> [ve2 | ver2] /=. 
+ case he1: sem_pexpr=> [ve1 | ver1] /=. 
  + case he: sem_pexpr=> [ve | ver] /=. 
    + case hb: to_bool=> [vb | vbr] /=. 
      + case ht: truncate_val=> [vt | vtr] /=. 
        + case ht': truncate_val=> [vt' | vtr'] /=. 
          + move=> <- /=. by left.
          have -> := truncate_val_ty_error s e1 ve1 vtr' t he1 hse1 ht'. move=> <-. by right.
        case ht'': truncate_val=> [vt'' | vtr''] /= hr; subst.
        + have -> := truncate_val_ty_error s e2 ve2 vtr t he2 hse2 ht. by right.
        have -> := truncate_val_ty_error s e1 ve1 vtr'' t he1 hse1 ht''. by right.
      move=> h; subst. have -> := to_bool_ty_error s e ve vbr he hse hb. by right.
    move=> h; subst. by move: (hie (Error ver) s hse he).  
  case he: sem_pexpr=> [ve | ver] //=.
  + case hb: to_bool=> [vb | vbr] //=.
    + move=> h; subst. by move: (hie1 (Error ver1) s hse1 he1). 
    move=> h; subst. have -> := to_bool_ty_error s e ve vbr he hse hb. by right.
  move=> h; subst. by move: (hie (Error ver) s hse he).
case he1: sem_pexpr=> [ve1 | ver1] //=.
+ case he: sem_pexpr=> [ve | ver] //=.
  + case hb: to_bool=> [vb | vbr] //=.
    + case ht: truncate_val=> [vt | vtr] //=.
      + move=> h; subst. by move: (hie2 (Error ver2) s hse2 he2).
      move=> h; subst. have -> := truncate_val_ty_error s e1 ve1 vtr t he1 hse1 ht. by right.
    move=> h; subst. have -> := to_bool_ty_error s e ve vbr he hse hb. by right.
  move=> h; subst. by move: (hie (Error ver) s hse he).
case he: sem_pexpr=> [ve | ver] //=.
+ case hb: to_bool=> [vb | vbr] //=.
  + move=> h; subst. by move: (hie1 (Error ver1) s hse1 he1).
  have -> := to_bool_ty_error s e ve vbr he hse hb. move=> <-. by right.
move=> h; subst. by move: (hie (Error ver) s hse he).
Qed.*)
          
          
End Safety_conditions.

