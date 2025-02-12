(* ** Imports and settings *)
From mathcomp Require Import ssreflect ssrfun ssrbool ssrnat seq eqtype fintype.
From mathcomp Require Import div ssralg.
From mathcomp Require Import word_ssrZ.
Require Import psem psem_facts compiler_util low_memory.
Require Export stack_alloc.
Require slh_lowering_proof.
Require Import byteset.
Import Utf8 Lia.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Local Open Scope seq_scope.
Local Open Scope Z_scope.

(* --------------------------------------------------------------------------- *)

(* Size of a value. *)
Notation size_val v := (size_of (type_of_val v)).

Lemma size_of_gt0 ty : 0 < size_of ty.
Proof. by case: ty. Qed.

Lemma size_slot_gt0 s : 0 < size_slot s.
Proof. by apply size_of_gt0. Qed.

Lemma size_of_le ty ty' : subtype ty ty' -> size_of ty <= size_of ty'.
Proof.
  case: ty => [||p|ws]; case:ty' => [||p'|ws'] //.
  + by move=> /eqP ->; lia.
  move=> /wsize_size_le.
  by apply Z.divide_pos_le.
Qed.

(* TODO : move elsewhere *)
(* but not clear where
   Uptr is defined in memory_model, no stype there
   stype is defined in type, no Uptr there
*)
Notation spointer := (sword Uptr) (only parsing).

Section WITH_PARAMS.

Context
  {wsw : WithSubWord}
  {dc:DirectCall}
  {asm_op syscall_state : Type}
  {ep : EstateParams syscall_state}
  {spp : SemPexprParams}
  {sip : SemInstrParams asm_op syscall_state}
  (pmap : pos_map)
  (glob_size : Z)
  (rsp rip : pointer).

Context
  (Slots : Sv.t)
  (Addr : slot -> pointer)
  (Writable : slot -> bool)
  (Align : slot -> wsize).

(* Any pointer in a slot is valid. *)
Definition slot_valid m := forall s p, Sv.In s Slots ->
  between (Addr s) (size_slot s) p U8 -> validw m Aligned p U8.

(* NOTE: disjoint_zrange already contains no_overflow conditions *)
(* Slots are disjoint from the source memory [ms]. *)
Definition disjoint_source ms :=
  forall s p, Sv.In s Slots -> validw ms Aligned p U8 ->
  disjoint_zrange (Addr s) (size_slot s) p (wsize_size U8).

(* Addresses of slots can be manipulated without risking overflows. *)
Hypothesis addr_no_overflow : forall s, Sv.In s Slots ->
  no_overflow (Addr s) (size_slot s).

(* Two distinct slots, with at least one of them writable, are disjoint. *)
Hypothesis disjoint_writable : forall s1 s2,
  Sv.In s1 Slots -> Sv.In s2 Slots -> s1 <> s2 ->
  Writable s1 ->
  disjoint_zrange (Addr s1) (size_slot s1) (Addr s2) (size_slot s2).

(* The address [Addr s] of a slot [s] is aligned w.r.t. [Align s]. *)
Hypothesis slot_align :
  forall s, Sv.In s Slots -> is_align (Addr s) (Align s).

(* Writable slots are disjoint from globals. *)
Hypothesis writable_not_glob : forall s, Sv.In s Slots -> Writable s ->
  0 < glob_size -> disjoint_zrange rip glob_size (Addr s) (size_slot s).

(* All pointers valid in memory [m0] are valid in memory [m].
   It is supposed to be applied with [m0] the initial target memory
   and [m] the current target memory.
*)
Definition valid_incl m0 m :=
  forall p, validw m0 Aligned p U8 -> validw m Aligned p U8.

(* ms: current source memory
   m0: initial target memory (just before the call to the current function)
   m : current target memory

   ms:
                                                    --------------------
                                                    |    mem source    |
                                                    --------------------

   m0:
                       --------------- ------------ --------------------
                       | other stack | |   glob   | |    mem source    |
                       --------------- ------------ --------------------

                                  ||
                                  || function call
                                  \/

   m:
   ------------------- --------------- ------------ --------------------
   |   stack frame   | | other stack | |   glob   | |    mem source    |
   ------------------- --------------- ------------ --------------------

*)

(* The memory zones that are not in a writable slot remain unchanged. *)
Definition mem_unchanged ms m0 m :=
  forall p, validw m0 Aligned p U8 -> ~ validw ms Aligned p U8 ->
  (forall s, Sv.In s Slots -> Writable s -> disjoint_zrange (Addr s) (size_slot s) p (wsize_size U8)) ->
  read m0 Aligned p U8 = read m Aligned p U8.

Record wf_global g ofs ws := {
  wfg_slot : Sv.In g Slots;
  wfg_writable : ~ Writable g;
  wfg_align : Align g = ws;
  wfg_offset : Addr g = (rip + wrepr Uptr ofs)%R
}.

Definition wbase_ptr sc :=
  if sc == Sglob then rip else rsp.

Record wf_direct (x : var) (s : slot) ofs ws cs sc := {
  wfd_slot : Sv.In s Slots;
  wfd_size : size_slot x <= cs.(cs_len);
  wfd_zone : 0 <= cs.(cs_ofs) /\ cs.(cs_ofs) + cs.(cs_len) <= size_slot s;
  wfd_writable : Writable s = (sc != Sglob);
  wfd_align : Align s = ws;
  wfd_offset : Addr s = (wbase_ptr sc + wrepr Uptr ofs)%R
}.

Record wf_regptr x xr := {
  wfr_type : is_sarr (vtype x);
  wfr_rtype : vtype xr = spointer;
  wfr_not_vrip : xr <> pmap.(vrip);
  wfr_not_vrsp : xr <> pmap.(vrsp);
  wfr_new : Sv.In xr pmap.(vnew);
  wfr_distinct : forall y yr,
    get_local pmap y = Some (Pregptr yr) -> x <> y -> xr <> yr
}.

Record wf_stkptr (x : var) (s : slot) ofs ws cs (xf : var) := {
  wfs_slot : Sv.In s Slots;
  wfs_type : is_sarr (vtype x);
  wfs_size : wsize_size Uptr <= cs.(cs_len);
  wfs_zone : 0 <= cs.(cs_ofs) /\ cs.(cs_ofs) + cs.(cs_len) <= size_slot s;
  wfs_writable : Writable s;
  wfs_align : Align s = ws;
  wfs_align_ptr : (Uptr <= ws)%CMP;
  wfs_offset_align : is_align (wrepr _ cs.(cs_ofs))%R Uptr;
  wfs_offset : Addr s = (rsp + wrepr Uptr ofs)%R;
  wfs_new : Sv.In xf pmap.(vnew);
  wfs_distinct : forall y s' ofs' ws' z' yf,
    get_local pmap y = Some (Pstkptr s' ofs' ws' z' yf) -> x <> y -> xf <> yf
}.

Definition wf_local x pk :=
  match pk with
  | Pdirect s ofs ws z sc => wf_direct x s ofs ws z sc
  | Pregptr xr => wf_regptr x xr
  | Pstkptr s ofs ws z xf => wf_stkptr x s ofs ws z xf
  end.

Class wf_pmap := {
  wt_len      : vtype pmap.(vxlen) = spointer;
  len_in_new  : Sv.In pmap.(vxlen) pmap.(vnew);
  len_neq_rip : pmap.(vxlen) <> pmap.(vrip);
  len_neq_rsp : pmap.(vxlen) <> pmap.(vrsp);
  len_neq_ptr : forall x p, Mvar.get pmap.(locals) x = Some (Pregptr p) -> pmap.(vxlen) <> p;
  wt_rip     : vtype pmap.(vrip) = spointer;
  wt_rsp     : vtype pmap.(vrsp) = spointer;
  rip_in_new : Sv.In pmap.(vrip) pmap.(vnew);
  rsp_in_new : Sv.In pmap.(vrsp) pmap.(vnew);
  wf_globals : forall g ofs ws, Mvar.get pmap.(globals) g = Some (ofs, ws) -> wf_global g ofs ws;
  wf_locals  : forall x pk, Mvar.get pmap.(locals) x = Some pk -> wf_local x pk;
  wf_vnew    : forall x pk, Mvar.get pmap.(locals) x = Some pk -> ~ Sv.In x pmap.(vnew)
}.

(* Registers (not introduced by the compiler) hold the same value in [vm1] and [vm2] *)
Definition eq_vm (vm1 vm2:Vm.t) :=
  forall (x:var),
    Mvar.get pmap.(locals) x = None ->
    ~ Sv.In x pmap.(vnew) ->
    vm1.[x] = vm2.[x].

(* Well-formedness of a [table] *)
Definition wft_VARS table :=
  forall x e,
    Mvar.get table.(bindings) x = Some e ->
    Sv.Subset (read_e e) table.(vars).

Definition wft_UNDEF table vme :=
  forall x,
    ~ Sv.In x table.(vars) ->
    vme.[x] = undef_addr x.(vtype).

Definition wft_SEM table se vm1 :=
  forall x e v1,
    Mvar.get table.(bindings) x = Some e ->
    get_var true vm1 x = ok v1 ->
    exists2 v2,
      sem_pexpr true [::] se e = ok v2 &
      value_uincl v1 v2.

Record wf_table table se vm1 := {
  wft_vars : wft_VARS table;
  wft_undef : wft_UNDEF table se.(evm);
  wft_sem : wft_SEM table se vm1;
}.

(* Well-formedness of a [region]. *)
Record wf_region (r : region) := {
  wfr_slot     : Sv.In r.(r_slot) Slots;
  wfr_writable : Writable r.(r_slot) = r.(r_writable);
  wfr_align    : Align r.(r_slot) = r.(r_align);
}.

(* We interpret a symbolic_slice as a concrete_slice *)
(* [se] is for symbolic estate *)
Definition sem_slice (se:estate) (s : symbolic_slice) : result error concrete_slice :=
  Let ofs := sem_pexpr true [::] se s.(ss_ofs) >>= to_int in
  Let len := sem_pexpr true [::] se s.(ss_len) >>= to_int in
  ok {| cs_ofs := ofs; cs_len := len |}.

Definition sub_concrete_slice cs1 cs2 :=
  if (0 <=? cs2.(cs_ofs)) && (cs2.(cs_ofs) + cs2.(cs_len) <=? cs1.(cs_len)) then
    ok {| cs_ofs := cs1.(cs_ofs) + cs2.(cs_ofs); cs_len := cs2.(cs_len) |}
  else Error ErrOob.

(* We interpret a symbolic_zone also as a concrete_slice *)
Fixpoint sem_zone_aux se cs z :=
  match z with
  | [::] => ok cs
  | s1 :: z =>
    Let cs1 := sem_slice se s1 in
    Let cs2 := sub_concrete_slice cs cs1 in
    sem_zone_aux se cs2 z
  end.

Definition sem_zone se z :=
  match z with
  | [::] => type_error
  | s :: z =>
    Let cs := sem_slice se s in
    sem_zone_aux se cs z
  end.

(* Well-formedness of a [concrete_slice]. *)
Record wf_concrete_slice (cs : concrete_slice) (ty : stype) (sl : slot) := {
  wfcs_len : size_of ty <= cs.(cs_len);
    (* the zone is big enough to store a value of type [ty] *)
  wfcs_ofs : 0 <= cs.(cs_ofs) /\ cs.(cs_ofs) + cs.(cs_len) <= size_slot sl
    (* the zone is a small enough to be in slot [sl] *)
}.

Definition wf_zone se z ty sl :=
  exists2 cs,
    sem_zone se z = ok cs &
    wf_concrete_slice cs ty sl.

(* Well-formedness of a [sub_region]. *)
Record wf_sub_region se (sr : sub_region) ty := {
  wfsr_region :> wf_region sr.(sr_region);
  wfsr_zone   :> wf_zone se sr.(sr_zone) ty sr.(sr_region).(r_slot)
}.

Definition wfr_WF (rmap : region_map) se :=
  forall x sr,
    Mvar.get rmap.(var_region) x = Some sr ->
    wf_sub_region se sr x.(vtype).

Definition concrete_slice_ble (cs1 cs2 : concrete_slice) :=
  (cs1.(cs_ofs) + cs1.(cs_len) <=? cs2.(cs_ofs))%Z.

(* A well-formed interval can be associated to a concrete interval. *)
Definition wf_interval se i :=
  exists ci, [/\
    mapM (sem_slice se) i = ok ci,
    (* the [all] part is needed, so that concrete_slice_ble is transitive.
       We could also ask for wf_concrete_slice, but it does not work as good
       with ssreflect. *)
    all (fun cs => 0 <? cs.(cs_len)) ci &
    path.sorted concrete_slice_ble ci].

Definition wf_status se status :=
  match status with
  | Borrowed i => wf_interval se i
  | _ => True
  end.

Definition wfr_STATUS (rmap : region_map) se :=
  forall r status_map x status,
    Mr.get rmap.(region_var) r = Some status_map ->
    Mvar.get status_map x = Some status ->
    wf_status se status.

(* This allows to read uniformly in words and arrays. *)
Definition get_val_byte v off :=
  match v with
  | Vword ws w =>
    if ((0 <=? off) && (off <? wsize_size ws)) then ok (LE.wread8 w off)
    else Error ErrOob
  | Varr _ a => read a Aligned off U8
  |_ => type_error
  end.

Definition sub_region_addr se sr :=
  Let cs := sem_zone se sr.(sr_zone) in
  ok (Addr sr.(sr_region).(r_slot) + wrepr _ cs.(cs_ofs))%R.

Definition offset_in_concrete_slice cs off :=
  ((cs.(cs_ofs) <=? off) && (off <? cs.(cs_ofs) + cs.(cs_len)))%Z.

(* "concrete interval" is just [seq concrete_slice] *)
Definition offset_in_concrete_interval ci off :=
  has (fun cs => offset_in_concrete_slice cs off) ci.

Definition valid_offset_interval se i off :=
  forall ci,
    mapM (sem_slice se) i = ok ci ->
    ~ offset_in_concrete_interval ci off.

Definition valid_offset se status off : Prop :=
  match status with
  | Valid => true
  | Unknown => false
  | Borrowed i => valid_offset_interval se i off
  end.

Definition eq_sub_region_val_read se (m2:mem) sr status v :=
  forall off ofs w,
     sub_region_addr se sr = ok ofs ->
     valid_offset se status off ->
     get_val_byte v off = ok w ->
     read m2 Aligned (ofs + wrepr _ off)%R U8 = ok w.

Definition eq_sub_region_val ty se m2 sr status v :=
  eq_sub_region_val_read se m2 sr status v /\
  (* According to the psem semantics, a variable of type [sword ws] can store
     a value of type [sword ws'] of shorter size (ws' <= ws).
     But actually, this is used only for register variables.
     For stack variables, we check in [alloc_lval] in stack_alloc.v that the
     value has the same size as the variable, and we remember that fact here.
  *)
  (* Actually, it is handful to know that [ty] and [type_of_val v] are the same
     even in the non-word cases.
  *)
  type_of_val v = ty.

Variable (P: uprog) (ev: @extra_val_t progUnit).
Notation gd := (p_globs P).

(* TODO: could we have this in stack_alloc.v ?
   -> could be used in check_valid/set_arr_word...
   This could mean useless checks for globals, but maybe worth it
   cf. check_vpk_word ?
   Not clear : one advantage of using vpk is to avoid two calls to
   pmap.(globals) and pmap.(locals)
   Could pmap.(globlals) and pmap.(locals) directly return sub_regions ?
*)
Definition check_gvalid rmap x : option (sub_region * status) :=
  if is_glob x then 
    omap (fun '(_, ws) =>
      let sr := sub_region_glob x.(gv) ws in
      let status := Valid in
      (sr, status)) (Mvar.get pmap.(globals) (gv x))
  else
    let sr := Mvar.get rmap.(var_region) x.(gv) in
    match sr with
    | Some sr =>
      let status := get_var_status rmap.(region_var) sr.(sr_region) x.(gv) in
      Some (sr, status)
    | _ => None
    end.
(* tentative de réécrire avec ce qu'on a déjà
Definition f rmap x :=
  Let vpk := get_var_kind pmap x in cexec pp_error_loc
  Let vpk := o2r ErrOob vpk in
  get_gsub_region_status rmap x.(gv) vpk.
*)

Definition wfr_VAL (rmap:region_map) se (s1:estate) (s2:estate) :=
  forall x sr status v,
    check_gvalid rmap x = Some (sr, status) ->
    get_gvar true gd s1.(evm) x = ok v ->
    eq_sub_region_val x.(gv).(vtype) se s2.(emem) sr status v.

Definition valid_pk rmap se (s2:estate) sr pk : Prop :=
  match pk with
  | Pdirect s ofs ws cs sc =>
    sub_region_beq sr (sub_region_direct s ws cs sc)
  | Pstkptr s ofs ws cs f =>
    check_stack_ptr rmap s ws cs f ->
    forall pofs ofs,
    sub_region_addr se (sub_region_stkptr s ws cs) = ok pofs ->
    sub_region_addr se sr = ok ofs ->
    read s2.(emem) Aligned pofs Uptr = ok ofs
  | Pregptr p =>
    forall ofs, sub_region_addr se sr = ok ofs ->
    s2.(evm).[p] = Vword ofs
  end.

Definition wfr_PTR (rmap:region_map) se (s2:estate) :=
  forall x sr, Mvar.get (var_region rmap) x = Some sr ->
    exists pk, get_local pmap x = Some pk /\ valid_pk rmap se s2 sr pk.

Class wf_rmap (rmap:region_map) se (s1:estate) (s2:estate) := {
  wfr_wf  : wfr_WF rmap se;
    (* sub-regions in [rmap] are well-formed *)
  wfr_status : wfr_STATUS rmap se;
    (* statuses in [rmap] are well-formed *)
  wfr_val : wfr_VAL rmap se s1 s2;
    (* [rmap] remembers for each relevant program variable which part of the target
       memory contains the value that this variable has in the source. These pieces
       of memory can be safely read without breaking semantics preservation.
    *)
  wfr_ptr : wfr_PTR rmap se s2;
    (* a variable in [rmap] is also in [pmap] and there is a link between
       the values associated to this variable in both maps *)
}.

Definition eq_mem_source (m1 m2:mem) :=
  forall w, validw m1 Aligned w U8 -> read m1 Aligned w U8 = read m2 Aligned w U8.

Hypothesis wf_pmap0 : wf_pmap.

(* FIXME: could we put [m0] as section variable? it should not be modified? *)
(* [m0]: initial target memory (just before the call to the current function)
   [s1]: current source estate
   [s2]: current target estate
*)
Class valid_state table (rmap : region_map) se (m0 : mem) (s1 s2 : estate) := {
  vs_scs         : s1.(escs) = s2.(escs);
  vs_slot_valid  : slot_valid s2.(emem);
    (* slots are valid in the target *)
  vs_disjoint    : disjoint_source s1.(emem);
    (* slots are disjoint from the source memory *)
  vs_valid_incl  : valid_incl s1.(emem) s2.(emem);
    (* every valid memory cell in the source is valid in the target *)
  vs_valid_incl2 : valid_incl m0 s2.(emem);
    (* every valid memory cell before the call is valid during the call *)
  vs_unchanged   : mem_unchanged s1.(emem) m0 s2.(emem);
    (* stack memory (i.e. valid in the target before the call but not in the source)
       disjoint from writable slots is unchanged between [m0] and [s2] *)
  vs_rip         : (evm s2).[pmap.(vrip)] = Vword rip;
    (* [vrip] stores address [rip] *)
  vs_rsp         : (evm s2).[pmap.(vrsp)] = Vword rsp;
    (* [vrsp] stores address [rsp] *)
  vs_eq_vm       : eq_vm s1.(evm) s2.(evm);
    (* registers already present in the source program store the same values
       in the source and in the target *)
  vs_wf_table    : wf_table table se s1.(evm);
  vs_wf_region   : wf_rmap rmap se s1 s2;
    (* cf. [wf_rmap] definition *)
  vs_eq_mem      : eq_mem_source s1.(emem) s2.(emem);
    (* the memory that is already valid in the source is the same in the target *)
  vs_glob_valid  : forall p, between rip glob_size p U8 -> validw m0 Aligned p U8;
    (* globals are valid in the target before the call *)
  vs_top_stack   : rsp = top_stack (emem s2);
    (* [rsp] is the stack pointer, it points to the top of the stack *)
}.

Existing Instance vs_wf_region.

(* We extend some predicates with the global case. *)
(* -------------------------------------------------------------------------- *)

Lemma sub_region_glob_wf se x ofs ws :
  wf_global x ofs ws ->
  wf_sub_region se (sub_region_glob x ws) x.(vtype).
Proof.
  move=> [*]; split.
  + by split=> //; apply /idP.
  eexists; first by reflexivity.
  by split=> /=; lia.
Qed.

Lemma check_gvalid_wf rmap se x sr_status :
  wfr_WF rmap se ->
  check_gvalid rmap x = Some sr_status ->
  wf_sub_region se sr_status.1 x.(gv).(vtype).
Proof.
  move=> hwfr.
  rewrite /check_gvalid; case: (@idP (is_glob x)) => hg.
  + by case heq: Mvar.get => [[??]|//] [<-] /=; apply (sub_region_glob_wf se (wf_globals heq)).
  by case heq: Mvar.get => // -[<-]; apply hwfr.
Qed.

Lemma get_var_status_wf_status rmap se r x :
  wfr_STATUS rmap se ->
  wf_status se (get_var_status rmap r x).
Proof.
  move=> hwfs.
  rewrite /get_var_status /get_status /get_status_map.
  case hsm: Mr.get => [status_map|//] /=.
  case hstatus: Mvar.get => [status'|//] /=.
  exact: hwfs hsm hstatus.
Qed.

Lemma check_gvalid_wf_status rmap se x sr_status :
  wfr_STATUS rmap se ->
  check_gvalid rmap x = Some sr_status ->
  wf_status se sr_status.2.
Proof.
  move=> hwfs.
  rewrite /check_gvalid; case: (@idP (is_glob x)) => hg.
  + by case heq: Mvar.get => [[??]|//] [<-] /=.
  by case heq: Mvar.get => // -[<-]; apply: get_var_status_wf_status hwfs.
Qed.

Definition valid_vpk rv se s2 x sr vpk :=
  match vpk with
  | VKglob (_, ws) => sr = sub_region_glob x ws
  | VKptr pk => valid_pk rv se s2 sr pk
  end.

Lemma get_globalP x z : get_global pmap x = ok z <-> Mvar.get pmap.(globals) x = Some z.
Proof.
  rewrite /get_global; case: Mvar.get; last by split.
  by move=> ?;split => -[->].
Qed.

(* A variant of [wfr_PTR] for [gvar]. *)
Lemma wfr_gptr rmap se s1 s2 x sr status :
  wf_rmap rmap se s1 s2 ->
  check_gvalid rmap x = Some (sr, status) ->
  exists vpk, get_var_kind pmap x = ok (Some vpk)
  /\ valid_vpk rmap se s2 x.(gv) sr vpk.
Proof.
  move=> hrmap.
  rewrite /check_gvalid /get_var_kind.
  case: is_glob.
  + case heq: Mvar.get => [[ofs ws]|//] /= [<- _].
    have /get_globalP -> := heq.
    by eexists.
  case heq: Mvar.get => // [sr'] [<- _].
  have /wfr_ptr [pk [-> hpk]] := heq.
  by eexists.
Qed.

(* [wf_global] and [wf_direct] in a single predicate. *)
Definition wf_vpk x vpk :=
  match vpk with
  | VKglob zws => wf_global x zws.1 zws.2
  | VKptr pk => wf_local x pk
  end.

Lemma get_var_kind_wf x vpk :
  get_var_kind pmap x = ok (Some vpk) ->
  wf_vpk x.(gv) vpk.
Proof.
  rewrite /get_var_kind.
  case: is_glob.
  + by t_xrbindP=> -[ofs ws] /get_globalP /wf_globals ? <-.
  case heq: get_local => [pk|//] [<-].
  by apply wf_locals.
Qed.

(* Predicates about concrete slices: zbetween, disjoint *)
(* -------------------------------------------------------------------------- *)

Definition zbetween_concrete_slice cs1 cs2 :=
  (cs1.(cs_ofs) <=? cs2.(cs_ofs)) &&
  (cs2.(cs_ofs) + cs2.(cs_len) <=? cs1.(cs_ofs) + cs1.(cs_len)).

Lemma zbetween_concrete_sliceP cs1 cs2 off :
  zbetween_concrete_slice cs1 cs2 ->
  offset_in_concrete_slice cs2 off ->
  offset_in_concrete_slice cs1 off.
Proof.
  rewrite /zbetween_concrete_slice /offset_in_concrete_slice !zify.
  by lia.
Qed.

Lemma zbetween_concrete_slice_refl cs : zbetween_concrete_slice cs cs.
Proof. by rewrite /zbetween_concrete_slice !zify; lia. Qed.

Lemma zbetween_concrete_slice_trans z1 z2 z3 :
  zbetween_concrete_slice z1 z2 ->
  zbetween_concrete_slice z2 z3 ->
  zbetween_concrete_slice z1 z3.
Proof. by rewrite /zbetween_concrete_slice !zify; lia. Qed.

Lemma sub_concrete_slice_incl cs1 cs2 cs :
  sub_concrete_slice cs1 cs2 = ok cs ->
  zbetween_concrete_slice cs1 cs.
Proof.
  rewrite /sub_concrete_slice /zbetween_concrete_slice.
  case: ifP => // + [<-] /=.
  rewrite !zify.
  by lia.
Qed.

Definition disjoint_concrete_slice cs1 cs2 :=
  (cs1.(cs_ofs) + cs1.(cs_len) <=? cs2.(cs_ofs)) ||
  (cs2.(cs_ofs) + cs2.(cs_len) <=? cs1.(cs_ofs)).

Lemma disjoint_concrete_sliceP cs1 cs2 off :
  disjoint_concrete_slice cs1 cs2 ->
  offset_in_concrete_slice cs1 off ->
  offset_in_concrete_slice cs2 off ->
  False.
Proof.
  rewrite /disjoint_concrete_slice /offset_in_concrete_slice !zify.
  by lia.
Qed.

Lemma disjoint_concrete_slice_sym cs1 cs2 :
  disjoint_concrete_slice cs1 cs2 = disjoint_concrete_slice cs2 cs1.
Proof. by rewrite /disjoint_concrete_slice orbC. Qed.

Lemma disjoint_concrete_slice_incl cs1 cs1' cs2 cs2' :
  zbetween_concrete_slice cs1 cs1' ->
  zbetween_concrete_slice cs2 cs2' ->
  disjoint_concrete_slice cs1 cs2 ->
  disjoint_concrete_slice cs1' cs2'.
Proof.
  by rewrite /zbetween_concrete_slice /disjoint_concrete_slice !zify; lia.
Qed.

Lemma disjoint_concrete_slice_incl_l cs1 cs1' cs2 :
  zbetween_concrete_slice cs1 cs1' ->
  disjoint_concrete_slice cs1 cs2 ->
  disjoint_concrete_slice cs1' cs2.
Proof.
  move=> ?; apply disjoint_concrete_slice_incl => //.
  by apply zbetween_concrete_slice_refl.
Qed.

Lemma disjoint_concrete_slice_r cs1 cs2 cs2' :
  zbetween_concrete_slice cs2 cs2' ->
  disjoint_concrete_slice cs1 cs2 ->
  disjoint_concrete_slice cs1 cs2'.
Proof.
  move=> ?; apply disjoint_concrete_slice_incl => //.
  by apply zbetween_concrete_slice_refl.
Qed.

Lemma sub_concrete_slice_disjoint cs cs1 cs1' cs2 cs2' :
  sub_concrete_slice cs cs1 = ok cs1' ->
  sub_concrete_slice cs cs2 = ok cs2' ->
  disjoint_concrete_slice cs1 cs2 ->
  disjoint_concrete_slice cs1' cs2'.
Proof.
  rewrite /sub_concrete_slice /disjoint_concrete_slice.
  case: ifP => // _ [<-] /=.
  case: ifP => // _ [<-] /=.
  rewrite !zify.
  by lia.
Qed.


(*
(* On the model of [between_byte]. *)
Lemma zbetween_zone_byte z1 z2 i :
  zbetween_zone z1 z2 ->
  0 <= i /\ i < z2.(z_len) ->
  zbetween_zone z1 (sub_zone_at_ofs z2 (Some i) (wsize_size U8)).
Proof. by rewrite /zbetween_zone wsize8 !zify /=; lia. Qed.

Lemma subset_interval_of_zone z1 z2 :
  I.subset (interval_of_zone z1) (interval_of_zone z2) = zbetween_zone z2 z1.
Proof.
  rewrite /I.subset /interval_of_zone /zbetween_zone /=.
  by apply /idP/idP; rewrite !zify; lia.
Qed.

Lemma memi_mem_U8 bytes z off :
  ByteSet.memi bytes (z.(z_ofs) + off) =
  ByteSet.mem bytes (interval_of_zone (sub_zone_at_ofs z (Some off) (wsize_size U8))).
Proof.
  apply /idP/idP.
  + move=> hmem; apply /ByteSet.memP; move=> i.
    rewrite /interval_of_zone /I.memi /= wsize8 !zify => hbound.
    by have -> : i = z_ofs z + off by lia.
  move=> /ByteSet.memP; apply.
  by rewrite /interval_of_zone /I.memi /= wsize8 !zify; lia.
Qed.
*)

(*
Lemma disjoint_zones_incl z1 z1' z2 z2' :
  zbetween_zone z1 z1' ->
  zbetween_zone z2 z2' ->
  disjoint_zones z1 z2 ->
  disjoint_zones z1' z2'.
Proof. by rewrite /zbetween_zone /disjoint_zones !zify; lia. Qed.

Lemma disjoint_zones_incl_l z1 z1' z2 :
  zbetween_zone z1 z1' ->
  disjoint_zones z1 z2 ->
  disjoint_zones z1' z2.
Proof. by move=> ?; apply disjoint_zones_incl => //; apply zbetween_zone_refl. Qed.

Lemma disjoint_zones_incl_r z1 z2 z2' :
  zbetween_zone z2 z2' ->
  disjoint_zones z1 z2 ->
  disjoint_zones z1 z2'.
Proof. by move=> ?; apply disjoint_zones_incl => //; apply zbetween_zone_refl. Qed.

Lemma disjoint_interval_of_zone z1 z2 :
  I.disjoint (interval_of_zone z1) (interval_of_zone z2) =
  disjoint_zones z1 z2.
Proof. by rewrite /I.disjoint /disjoint_zones /= !zify. Qed.

Lemma interval_of_zone_wf :
  forall z, 0 < z.(z_len) -> I.wf (interval_of_zone z).
Proof. by move=> z hlen; rewrite /I.wf /I.is_empty /= !zify; lia. Qed.

Lemma mem_remove_interval_of_zone z1 z2 bytes :
  0 < z1.(z_len) -> 0 < z2.(z_len) ->
  ByteSet.mem (ByteSet.remove bytes (interval_of_zone z1)) (interval_of_zone z2) ->
  ByteSet.mem bytes (interval_of_zone z2) /\ disjoint_zones z1 z2.
Proof.
  move=> hlt1 hlt2.
  have hwf1 := interval_of_zone_wf hlt1.
  have hwf2 := interval_of_zone_wf hlt2.
  move=> /(mem_remove hwf1 hwf2).
  by rewrite disjoint_interval_of_zone.
Qed.

Lemma disj_sub_regions_sym sr1 sr2 : disj_sub_regions sr1 sr2 = disj_sub_regions sr2 sr1.
Proof. by rewrite /disj_sub_regions /region_same eq_sym disjoint_zones_sym. Qed.
*)

(* Lemmas about sem_zone *)
(* -------------------------------------------------------------------------- *)

Lemma sem_zone_aux_app se cs z1 cs1 z2 :
  sem_zone_aux se cs z1 = ok cs1 ->
  sem_zone_aux se cs (z1 ++ z2) = sem_zone_aux se cs1 z2.
Proof.
  elim: z1 cs => [|s1 z1 ih1] cs /=.
  + by move=> [<-].
  by t_xrbindP=> cs1' -> /= cs1'' -> /= /ih1.
Qed.

Lemma sem_zone_app se z1 z2 cs1 :
  sem_zone se z1 = ok cs1 ->
  sem_zone se (z1 ++ z2) = sem_zone_aux se cs1 z2.
Proof.
  case: z1 => [//|s1 z1] /=.
  t_xrbindP=> cs -> /=.
  by apply sem_zone_aux_app.
Qed.

Lemma sub_concrete_slice_assoc cs1 cs2 cs3 cs4 cs5 :
  sub_concrete_slice cs1 cs2 = ok cs3 ->
  sub_concrete_slice cs3 cs4 = ok cs5 ->
  exists2 cs,
    sub_concrete_slice cs2 cs4 = ok cs &
    sub_concrete_slice cs1 cs = ok cs5.
Proof.
  rewrite /sub_concrete_slice.
  case: ifP => // hle1 [<-] /=.
  case: ifP => // hle2 [<-] /=.
  eexists; first by reflexivity.
  move=> /=; case: ifPn; last first.
  + move: hle1 hle2; rewrite !zify.
    by lia.
  by move=> _; rewrite Z.add_assoc.
Qed.

Lemma sem_zone_aux_sub_concrete_slice se z cs1 cs1' cs cs2 :
  sem_zone_aux se cs1 z = ok cs1' ->
  sub_concrete_slice cs cs2 = ok cs1 ->
  exists2 cs2',
    sem_zone_aux se cs2 z = ok cs2' &
    sub_concrete_slice cs cs2' = ok cs1'.
Proof.
  elim: z cs1 cs2 => [|s z ih] cs1 cs2 /=.
  + move=> [<-] ok_cs1.
    by eexists; first by reflexivity.
  t_xrbindP=> ? -> /= cs1'' ok_cs1'' ok_cs1' ok_cs1.
  have [? -> /= hsub] := sub_concrete_slice_assoc ok_cs1 ok_cs1''.
  by apply: ih hsub.
Qed.

Lemma sem_zone_aux_sem_zone se z cs1 cs2 :
  z <> [::] ->
  sem_zone_aux se cs1 z = ok cs2 ->
  exists2 cs,
    sem_zone se z = ok cs &
    sub_concrete_slice cs1 cs = ok cs2.
Proof.
  case: z => [//|s z] _ /=.
  t_xrbindP=> ? -> /= cs1' ok_cs1' ok_cs2.
  by apply (sem_zone_aux_sub_concrete_slice ok_cs2 ok_cs1').
Qed.

Lemma sem_zone_aux_incl se z cs1 cs2 :
  sem_zone_aux se cs1 z = ok cs2 ->
  zbetween_concrete_slice cs1 cs2.
Proof.
  elim: z cs1 => [|s z ih] cs1 /=.
  + by move=> [<-]; apply zbetween_concrete_slice_refl.
  t_xrbindP=> cs ok_cs cs1' ok_cs1' ok_cs2.
  apply (zbetween_concrete_slice_trans (sub_concrete_slice_incl ok_cs1')).
  by apply (ih _ ok_cs2).
Qed.

Lemma sem_zone_cons_incl se s z cs :
  sem_zone se (s::z) = ok cs ->
  exists2 cs',
    sem_slice se s = ok cs' & zbetween_concrete_slice cs' cs.
Proof.
  move=> /=.
  t_xrbindP=> ? -> /= ok_cs.
  eexists; first by reflexivity.
  by apply (sem_zone_aux_incl ok_cs).
Qed.

Lemma sem_zone_aux_app_inv se cs z1 z2 cs2 :
  sem_zone_aux se cs (z1 ++ z2) = ok cs2 ->
  exists2 cs1,
    sem_zone_aux se cs z1 = ok cs1 &
    sem_zone_aux se cs1 z2 = ok cs2.
Proof.
  elim: z1 cs => [|s1 z1 ih1] cs /=.
  + by move=> ?; eexists; first by reflexivity.
  t_xrbindP=> ? -> /= ? -> /= ok_cs2.
  by apply ih1.
Qed.

Lemma sem_zone_app_inv se z1 z2 cs :
  z1 <> [::] -> z2 <> [::] ->
  sem_zone se (z1 ++ z2) = ok cs ->
  exists cs1 cs2, [/\
    sem_zone se z1 = ok cs1,
    sem_zone se z2 = ok cs2 &
    sub_concrete_slice cs1 cs2 = ok cs].
Proof.
  case: z1 => [//|s1 z1] _ /=.
  move=> z2_nnil.
  t_xrbindP=> cs1 -> /= ok_cs.
  have [{}cs1 -> /= {}ok_cs] := sem_zone_aux_app_inv ok_cs.
  have [cs2 ok_cs2 {}ok_cs] := sem_zone_aux_sem_zone z2_nnil ok_cs.
  by exists cs1, cs2.
Qed.

(* TODO: clean *)
Lemma sem_zone_app_inv2 se z1 z2 cs ty s :
  sem_zone se (z1 ++ z2) = ok cs ->
  wf_concrete_slice cs ty s ->
  exists cs1 cs2, [/\
    z1 <> [::] -> sem_zone se z1 = ok cs1,
    z2 <> [::] -> sem_zone se z2 = ok cs2 &
    sub_concrete_slice cs1 cs2 = ok cs].
Proof.
  move=> ok_cs [wf_len wf_ofs].
  case: z1 ok_cs => [|s1 z1] /= ok_cs.
  + exists {| cs_ofs := 0; cs_len := cs.(cs_ofs) + cs.(cs_len) |}, cs.
    split=> //.
    rewrite /sub_concrete_slice /=.
    case: ifPn.
    + by case: (cs).
    rewrite !zify. lia.
  move: ok_cs. t_xrbindP=> ? -> /= h.
  have {h} [cs_ h1 h2] := sem_zone_aux_app_inv h.
  have: z2 = [::] \/ z2 <> [::].
  + by case: (z2); [left|right].
  case.
  + move=> ?; subst z2.
    move: h2 => /= [?]; subst cs_.
    exists cs, {| cs_ofs := 0; cs_len := cs.(cs_len) |}.
    split=> //=.
    rewrite /sub_concrete_slice /= Z.leb_refl Z.add_0_r. by case: (cs).
  move=> z2_nnil.
  have [cs2 h11 h12] := sem_zone_aux_sem_zone z2_nnil h2.
  exists cs_, cs2.
  split=> //.
Qed.

(* Lemmas about wf_zone *)
(* -------------------------------------------------------------------------- *)
(*
Lemma sub_zone_at_ofs_compose z ofs1 ofs2 len1 len2 :
  sub_zone_at_ofs (sub_zone_at_ofs z  len1) (Some ofs2) len2 =
  sub_zone_at_ofs z (Some (ofs1 + ofs2)) len2.
Proof. by rewrite /= Z.add_assoc. Qed.
*)
Lemma wf_concrete_slice_len_gt0 cs ty sl :
  wf_concrete_slice cs ty sl -> 0 < cs.(cs_len).
Proof. by move=> [? _]; have := size_of_gt0 ty; lia. Qed.
(*
Lemma zbetween_zone_sub_zone_at_ofs z ty sl ofs len :
  wf_zone z ty sl ->
  (forall zofs, ofs = Some zofs -> 0 <= zofs /\ zofs + len <= size_of ty) ->
  zbetween_zone z (sub_zone_at_ofs z ofs len).
Proof.
  move=> hwf.
  case: ofs => [ofs|]; last by (move=> _; apply zbetween_zone_refl).
  move=> /(_ _ refl_equal).
  rewrite /zbetween_zone !zify /=.
  by have := hwf.(wfz_len); lia.
Qed.

(* We use [sub_zone_at_ofs z (Some 0)] to manipulate sub-zones of [z].
   Not sure if this a clean way to proceed.
   This lemma is a special case of [zbetween_zone_sub_zone_at_ofs].
*)
Lemma zbetween_zone_sub_zone_at_ofs_0 z ty sl :
  wf_zone z ty sl ->
  zbetween_zone z (sub_zone_at_ofs z (Some 0) (size_of ty)).
Proof.
  move=> hwf.
  apply: (zbetween_zone_sub_zone_at_ofs hwf).
  by move=> _ [<-]; lia.
Qed.

Lemma zbetween_zone_sub_zone_at_ofs_option z i ofs len ty sl :
  wf_zone z ty sl ->
  0 <= i /\ i + len <= size_of ty ->
  (ofs <> None -> ofs = Some i) ->
  zbetween_zone (sub_zone_at_ofs z ofs len) (sub_zone_at_ofs z (Some i) len).
Proof.
  move=> hwf hi.
  case: ofs => [ofs|].
  + by move=> /(_ ltac:(discriminate)) [->]; apply zbetween_zone_refl.
  move=> _.
  apply (zbetween_zone_sub_zone_at_ofs hwf).
  by move=> _ [<-].
Qed.
*)
(* Lemmas about wf_sub_region *)
(* -------------------------------------------------------------------------- *)

(* TODO: move this closer to alloc_array_moveP? Before, this was used everywhere
   but not anymore. *)

Lemma wf_sub_region_size_of se sr ty1 ty2 :
  size_of ty2 <= size_of ty1 ->
  wf_sub_region se sr ty1 ->
  wf_sub_region se sr ty2.
Proof.
  move=> hle [hwf1 hwf2]; split=> //.
  case: hwf2 => cs ok_cs [wf_cs1 wf_cs2].
  exists cs => //; split=> //.
  by lia.
Qed.

Lemma wf_sub_region_subtype se sr ty1 ty2 :
  subtype ty2 ty1 ->
  wf_sub_region se sr ty1 ->
  wf_sub_region se sr ty2.
Proof.
  move=> hsub hwf.
  by apply (wf_sub_region_size_of (size_of_le hsub) hwf).
Qed.

Lemma split_lastP z z' s :
  z <> [::] ->
  split_last z = (z', s) ->
  z = z' ++ [:: s].
Proof.
  elim: z z' => [//|s1 z1 ih1] z' _ /=.
  case: z1 ih1 => [|s1' z1] ih1.
  + by move=> [<- <-].
  case hsplit: split_last => [z last].
  move=> [??]; subst z' s.
  by rewrite (ih1 _ ltac:(discriminate) hsplit).
Qed.

(* TODO: clean & move *)
Lemma sub_concrete_slice_wf cs ty sl ofs ty2 :
  wf_concrete_slice cs ty sl ->
  0 <= ofs /\ ofs + size_of ty2 <= size_of ty ->
  exists2 cs',
    sub_concrete_slice cs {| cs_ofs := ofs; cs_len := size_of ty2 |} = ok cs' &
    wf_concrete_slice cs' ty2 sl.
Proof.
  move=> [wf_len wf_ofs] hofs.
  rewrite /sub_concrete_slice /=.
  case: ifPn.
  + move=> _. eexists; split; first by reflexivity.
    split=> /=. lia. lia.
  rewrite !zify. lia.
Qed.

(* not used, to be removed *)
Lemma sub_region_rcons_wf se z ty sl ofs ofsi ty2 :
  wf_zone se z ty sl ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  wf_zone se (z ++ [:: {| ss_ofs := ofs; ss_len := size_of ty2 |}]) ty2 sl.
Proof.
  move=> hwf ok_ofsi hofsi.
  have [cs ok_cs wf_cs] := hwf.
  have [cs' ok_cs' wf_cs'] := sub_concrete_slice_wf wf_cs hofsi.
  exists cs' => //.
  rewrite (sem_zone_app _ ok_cs).
  by rewrite /= /sem_slice /= ok_ofsi /= ok_cs'.
Qed.


Lemma sub_zone_at_ofsP se z cs ty sl ofs ofsi ty2 :
  sem_zone se z = ok cs ->
  wf_concrete_slice cs ty sl ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  exists cs', [/\
    sem_zone se (sub_zone_at_ofs z ofs (size_of ty2)) = ok cs',
    wf_concrete_slice cs' ty2 sl &
    sub_concrete_slice cs {| cs_ofs := ofsi; cs_len := size_of ty2 |} = ok cs'].
Proof.
  move=> ok_cs wf_cs ok_ofsi hofsi.
  have [cs' ok_cs' wf_cs'] := sub_concrete_slice_wf wf_cs hofsi.
  exists cs'; split=> //.
  rewrite /sub_zone_at_ofs.
  case hsplit: split_last => [z' s].
  have hz: z <> [::].
  + by move=> hnil; rewrite hnil in ok_cs.
  have {}hsplit := split_lastP hz hsplit.
  have hsem:
    sem_zone se
      (z ++ [:: {| ss_ofs := ofs; ss_len := size_of ty2 |}]) = ok cs'.
  + rewrite (sem_zone_app _ ok_cs).
    by rewrite /= /sem_slice /= ok_ofsi /= ok_cs'.
  move: (erefl (sem_slice se s)); rewrite {2}/sem_slice.
  case: is_constP => [sofs|//].
  case: is_constP => [slen|//] /= hs.
  case: is_constP ok_ofsi hsem => [_|//] /= [->] _.
  rewrite {}hsplit in ok_cs.
  have: z' = [::] \/ z' <> [::].
  + by case: (z'); [left|right].
  case=> [?|z'_nnil].
  + subst z'.
    move: hs ok_cs ok_cs' => /= -> /= [<-].
    rewrite /sub_concrete_slice /=.
    by case: ifP.
  have := sem_zone_app_inv (z2:=[::s]) z'_nnil ltac:(discriminate) ok_cs.
  rewrite /= hs /= => -[cs1 [_ [hz' [<-] hsub]]].
  rewrite (sem_zone_app _ hz') /=.
  have [] := sub_concrete_slice_assoc hsub ok_cs'.
  by rewrite {1}/sub_concrete_slice /=; case: ifP => // _ _ [<-] ->.
Qed.

Lemma sub_region_at_ofs_wf se sr ty ofs ofsi ty2 :
  wf_sub_region se sr ty ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  wf_sub_region se (sub_region_at_ofs sr ofs (size_of ty2)) ty2.
Proof.
  move=> [hwfr hwfz] ok_ofsi hofsi; split=> //=.
  have [cs ok_cs wf_cs] := hwfz.
  have [cs' [ok_cs' wf_cs' hsub]] := sub_zone_at_ofsP ok_cs wf_cs ok_ofsi hofsi.
  by exists cs'.
Qed.

Lemma sub_region_addr_offset se sr ty ofs ofsi ty2 addr :
  wf_sub_region se sr ty ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  sub_region_addr se sr = ok addr ->
  sub_region_addr se (sub_region_at_ofs sr ofs (size_of ty2)) = ok (addr + wrepr _ ofsi)%R.
Proof.
  move=> hwf ok_ofsi hofsi.
  have [cs ok_cs wf_cs] := hwf.(wfsr_zone).
  have [cs' [ok_cs' wf_cs' hsub]] := sub_zone_at_ofsP ok_cs wf_cs ok_ofsi hofsi.
  rewrite /sub_region_addr ok_cs /= => -[<-].
  rewrite ok_cs' /=.
  move: hsub; rewrite /sub_concrete_slice /=.
  case: ifP => // _ [<-] /=.
  by rewrite wrepr_add GRing.addrA.
Qed.

(*
Lemma sub_region_at_ofs_0_wf sr ty :
  wf_sub_region sr ty ->
  wf_sub_region (sub_region_at_ofs sr (Some 0) (size_of ty)) ty.
Proof.
  move=> hwf.
  apply: (sub_region_at_ofs_wf hwf).
  by move=> _ [<-]; lia.
Qed.

Lemma sub_region_at_ofs_wf_byte sr ty ofs :
  wf_sub_region sr ty ->
  0 <= ofs < size_of ty ->
  wf_sub_region (sub_region_at_ofs sr (Some ofs) (wsize_size U8)) sword8.
Proof.
  move=> hwf hofs.
  change (wsize_size U8) with (size_of sword8).
  apply (sub_region_at_ofs_wf hwf (ofs:=Some ofs)).
  by move=> _ [<-] /=; rewrite wsize8; lia.
Qed.
*)

Lemma wunsigned_sub_region_addr se sr ty cs :
  wf_sub_region se sr ty ->
  sem_zone se sr.(sr_zone) = ok cs ->
  exists2 w,
    sub_region_addr se sr = ok w &
    wunsigned w = wunsigned (Addr sr.(sr_region).(r_slot)) + cs.(cs_ofs).
Proof.
  move=> [hwf [cs2 ok_cs wf_cs]]; rewrite ok_cs => -[?]; subst cs2.
  rewrite /sub_region_addr; rewrite ok_cs /=.
  eexists; first by reflexivity.
  apply wunsigned_add.
  have hlen := wf_concrete_slice_len_gt0 wf_cs.
  have hofs := wfcs_ofs wf_cs.
  have /ZleP hno := addr_no_overflow (wfr_slot hwf).
  have ? := wunsigned_range (Addr (sr.(sr_region).(r_slot))).
  by lia.
Qed.

Lemma zbetween_sub_region_addr se sr ty ofs :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  zbetween (Addr sr.(sr_region).(r_slot)) (size_slot sr.(sr_region).(r_slot))
    ofs (size_of ty).
Proof.
  move=> hwf haddr.
  have [cs ok_cs wf_cs] := hwf.(wfsr_zone).
  have := wunsigned_sub_region_addr hwf ok_cs.
  rewrite haddr => -[_ [<-] heq].
  rewrite /zbetween !zify heq.
  have hofs := wf_cs.(wfcs_ofs).
  have hlen := wf_cs.(wfcs_len).
  by lia.
Qed.
(*
Lemma sub_region_at_ofs_None sr len :
  sub_region_at_ofs sr None len = sr.
Proof. by case: sr. Qed.
*)

  

Lemma no_overflow_sub_region_addr se sr ty ofs :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  no_overflow ofs (size_of ty).
Proof.
  move=> hwf haddr.
  apply (no_overflow_incl (zbetween_sub_region_addr hwf haddr)).
  by apply (addr_no_overflow hwf.(wfr_slot)).
Qed.

(*
Lemma zbetween_sub_region_at_ofs sr ty ofs ws :
  wf_sub_region sr ty ->
  (∀ zofs : Z, ofs = Some zofs → 0 <= zofs ∧ zofs + wsize_size ws <= size_of ty) ->
  zbetween (sub_region_addr sr) (size_of ty)
           (sub_region_addr (sub_region_at_ofs sr ofs (wsize_size ws))) (size_of (stype_at_ofs ofs (sword ws) ty)).
Proof.
  move=> hwf hofs.
  change (wsize_size ws) with (size_of (sword ws)) in hofs.
  have hwf' := sub_region_at_ofs_wf hwf hofs.
  rewrite /zbetween !zify.
  rewrite (wunsigned_sub_region_addr hwf).
  rewrite (wunsigned_sub_region_addr hwf').
  case: ofs hofs {hwf'} => [ofs|] /=.
  + by move=> /(_ _ refl_equal); lia.
  by lia.
Qed.

Lemma zbetween_sub_region_at_ofs_option sr ofs ws i ty :
  wf_sub_region sr ty ->
  0 <= i /\ i + wsize_size ws <= size_of ty ->
  (ofs <> None -> ofs = Some i) ->
  zbetween (sub_region_addr (sub_region_at_ofs sr ofs (wsize_size ws))) (size_of (stype_at_ofs ofs (sword ws) ty))
           (sub_region_addr sr + wrepr _ i) (wsize_size ws).
Proof.
  move=> hwf hi.
  rewrite (sub_region_addr_offset (wsize_size ws)).
  case: ofs => [ofs|] /=.
  + by move=> /(_ ltac:(discriminate)) [->]; apply zbetween_refl.
  move=> _; rewrite sub_region_at_ofs_None.
  apply: (zbetween_sub_region_at_ofs hwf).
  by move=> _ [<-].
Qed.
*)

(* [valid_state]'s clauses deal about U8 only. We show extended versions valid
   for any [ws].
*)
(* -------------------------------------------------------------------------- *)

Lemma valid_incl_word table rmap se m0 s1 s2 al p ws :
  valid_state table rmap se m0 s1 s2 ->
  validw s1.(emem) al p ws ->
  validw s2.(emem) al p ws.
Proof.
  move=> hvs /validwP [hal hvalid].
  apply /validwP; split=> //.
  move=> k hk; rewrite (validw8_alignment Aligned); apply: vs_valid_incl.
  rewrite (validw8_alignment al).
  exact: hvalid.
Qed.

Lemma eq_mem_source_word table rmap se m0 s1 s2 al p ws :
  valid_state table rmap se m0 s1 s2 ->
  validw s1.(emem) al p ws ->
  read s1.(emem) al p ws = read s2.(emem) al p ws.
Proof.
  move=> hvs /validwP [hal hvalid].
  apply: eq_read => al' k hk.
  rewrite !(read8_alignment Aligned).
  apply: vs_eq_mem.
  rewrite (validw8_alignment al).
  exact: hvalid.
Qed.

(* [eq_sub_region_val_read] deals with 1-byte words. This lemma extends it to
   words of arbitrary sizes, when status is Valid. *)
Lemma eq_sub_region_val_read_word se sr ty s2 (v : value) ofs ws off w al :
  wf_sub_region se sr ty ->
  eq_sub_region_val_read se (emem s2) sr Valid v ->
  sub_region_addr se sr = ok ofs ->
  (forall k, 0 <= k < wsize_size ws -> get_val_byte v (off + k) = ok (LE.wread8 w k)) ->
  read (emem s2) al (ofs + wrepr _ off)%R ws =
    if is_aligned_if al (ofs + wrepr _ off)%R ws then ok w else Error ErrAddrInvalid.
Proof.
  move=> hwf hread ok_ofs hget.
  apply read8_read.
  move=> al' k hk.
  rewrite addE -GRing.addrA -wrepr_add (read8_alignment Aligned).
  apply hread => //.
  by apply hget.
Qed.

Lemma get_val_byte_word ws (w : word ws) off :
  0 <= off < wsize_size ws ->
  get_val_byte (Vword w) off = ok (LE.wread8 w off).
Proof. by rewrite /= -!zify => ->. Qed.

Lemma get_val_byte_bound v off w :
  get_val_byte v off = ok w -> 0 <= off /\ off < size_val v.
Proof.
  case: v => //.
  + move=> len a /=.
    by rewrite -get_read8 => /WArray.get_valid8 /WArray.in_boundP.
  move=> ws w' /=.
  by case: ifP => //; rewrite !zify.
Qed.

(* -------------------------------------------------------------------------- *)

Lemma check_gvalid_lvar rmap (x : var_i) sr :
  Mvar.get rmap.(var_region) x = Some sr ->
  check_gvalid rmap (mk_lvar x) = Some (sr, get_var_status rmap sr.(sr_region) x).
Proof. by rewrite /check_gvalid /= => ->. Qed.

Lemma check_gvalid_writable rmap x sr status :
  sr.(sr_region).(r_writable) ->
  check_gvalid rmap x = Some (sr, status) ->
  status = get_var_status rmap sr.(sr_region) x.(gv).
Proof.
  move=> hw.
  rewrite /check_gvalid.
  case: (@idP (is_glob x)) => hg.
  + by case: Mvar.get => [[ws ofs]|//] /= [? _]; subst sr.
  by case: Mvar.get => [_|//] [-> ?].
Qed.

Lemma cast_ptrP wdb gd s e i :
  sem_pexpr wdb gd s e >>= to_int = ok i ->
  exists2 v, sem_pexpr wdb gd s (cast_ptr e) = ok v & value_uincl (Vword (wrepr Uptr i)) v.
Proof.
  t_xrbindP => v he hi.
  apply: cast_wP.
  by rewrite /= he /sem_sop1 /= hi.
Qed.

Lemma mk_ofsP wdb aa sz gd s2 ofs e i :
  sem_pexpr wdb gd s2 e >>= to_int = ok i ->
  sem_pexpr wdb gd s2 (mk_ofs aa sz e ofs) = ok (Vword (wrepr Uptr (i * mk_scale aa sz + ofs)%Z)).
Proof.
  rewrite /mk_ofs; case is_constP => /= [? [->] //| {e} e he] /=.
  rewrite /sem_sop2 /=.
  have [_ -> /value_uinclE [ws [w [-> huincl]]]] /= := cast_ptrP he.
  rewrite !truncate_word_u /=.
  rewrite (word_uincl_truncate huincl (truncate_word_u _)) /=.
  by rewrite truncate_word_u /= wrepr_add wrepr_mul GRing.mulrC.
Qed.

Lemma mk_ofs_intP wdb gd s e i aa sz :
  Let x := sem_pexpr wdb gd s e in to_int x = ok i ->
  sem_pexpr wdb gd s (mk_ofs_int aa sz e) = ok (Vint (i * mk_scale aa sz)).
Proof.
  rewrite /mk_ofs_int; case is_constP => /= [? [->] //| {e} e he] /=.
  move: he; t_xrbindP => v ok_v ok_i.
  by rewrite ok_v /= /sem_sop2 /= ok_i /= Z.mul_comm.
Qed.

Section EXPR.
  Variables (table : table) (rmap:region_map).
  Variables (se : estate) (m0:mem) (s:estate) (s':estate).
  Hypothesis (hvalid: valid_state table rmap se m0 s s').

  (* If [x] is a register, it is not impacted by the presence of global
     variables per hypothesis [vs_eq_vm].
  *)
  Lemma get_var_kindP wdb x v:
    get_var_kind pmap x = ok None ->
    ~ Sv.In x.(gv) pmap.(vnew) ->
    get_gvar wdb gd (evm s) x = ok v ->
    get_gvar wdb [::] (evm s') x = ok v.
  Proof.
    rewrite /get_var_kind; case: ifPn => hglob; first by t_xrbindP.
    case hgl : get_local => // _ /(vs_eq_vm hgl) heq.
    by rewrite !get_gvar_nglob // /get_var heq.
  Qed.

  Lemma base_ptrP sc : (evm s').[base_ptr pmap sc] = Vword (wbase_ptr sc).
  Proof. by case: sc => /=; rewrite (vs_rsp, vs_rip). Qed.

  Lemma Zland_mod z ws : Z.land z (wsize_size ws - 1) = z mod wsize_size ws.
  Proof.
    rewrite wsize_size_is_pow2 -Z.land_ones; last by case: ws.
    by rewrite Z.ones_equiv.
  Qed.

  Lemma divideP ws e wdb gd i :
    divide e ws ->
    sem_pexpr wdb gd se e >>= to_int = ok i ->
    i mod wsize_size ws = 0.
  Proof.
    case: e => //=.
    + move=> z.
      by rewrite /divide_z Zland_mod => /eqP hdiv -[<-].
    case=> // o e1 e2.
    move=> /orP [].
    + case: is_constP => //= z1.
      rewrite /divide_z Zland_mod => /eqP hdiv.
      t_xrbindP=> v v2 ok_v2.
      case: o => //=.
      rewrite /sem_sop2 /=.
      t_xrbindP=> z2 ok_z2 <- /= [<-].
      by rewrite Zmult_mod hdiv /= Zmod_0_l.
    case: is_constP => //= z2.
    rewrite /divide_z Zland_mod => /eqP hdiv.
    t_xrbindP=> v v1 ok_v1.
    case: o; last by rewrite /sem_sop2 /=; t_xrbindP.
    rewrite /sem_sop2 /=.
    t_xrbindP=> z1 ok_z1 <- /= [<-].
    by rewrite Zmult_mod hdiv Z.mul_0_r Zmod_0_l.
  Qed.

  Lemma divideP_slice sli ws cs :
    divide (ss_ofs sli) ws ->
    sem_slice se sli = ok cs ->
    cs.(cs_ofs) mod wsize_size ws = 0.
  Proof.
    move=> hdiv.
    rewrite /sem_slice.
    apply: rbindP => ofs ok_ofs.
    apply: rbindP => len _ [<-] /=.
    by apply (divideP hdiv ok_ofs).
  Qed.

  (* FIXME: clean *)
  Lemma divide_zoneP z ws cs :
    divide_zone z ws ->
    sem_zone se z = ok cs ->
    cs.(cs_ofs) mod wsize_size ws = 0.
  Proof.
    case: z => [//|sli1 z] /= /andP [hdiv1 hdiv2].
    t_xrbindP=> cs1 /(divideP_slice hdiv1).
    elim: z cs1 hdiv2 => [|sli2 z ih] cs1.
    + by move=> _ ? [<-].
    simpl.
    move=> /andP [hdiv2 hdiv3] h.
    t_xrbindP=> cs2 ok_cs2 cs3 ok_cs3 ok_cs.
    have := ih _ hdiv3 _ ok_cs.
    apply.
    move: ok_cs3; rewrite /sub_concrete_slice; case: ifP => // _ [<-] /=.
    rewrite Zplus_mod.
    rewrite h.
    have -> := divideP_slice hdiv2 ok_cs2.
    done.
  Qed.

  Lemma check_alignP x sr ty w al ws tt :
    wf_sub_region se sr ty ->
    sub_region_addr se sr = ok w ->
    check_align al x sr ws = ok tt ->
    is_aligned_if al w ws.
  Proof.
    move=> hwf ok_w; rewrite /check_align; t_xrbindP.
    case: al => //= halign halign2.
    have: is_align (Addr sr.(sr_region).(r_slot)) ws.
    + apply (is_align_m halign).
      rewrite -hwf.(wfr_align).
      by apply (slot_align hwf.(wfr_slot)).
    rewrite /is_align !p_to_zE.
    have [cs ok_cs _] := hwf.(wfsr_zone).
    have := wunsigned_sub_region_addr hwf ok_cs.
    rewrite ok_w => -[_ [<-] ->].
    rewrite Z.add_mod //.
    move=> /eqP -> /=.
    by rewrite (divide_zoneP halign2 ok_cs).
  Qed.

  Lemma get_sub_regionP x sr :
    get_sub_region rmap x = ok sr <-> Mvar.get rmap.(var_region) x = Some sr.
  Proof.
    rewrite /get_sub_region; case: Mvar.get; last by split.
    by move=> ?; split => -[->].
  Qed.

  Lemma get_sub_region_statusP (x : var_i) sr status :
    get_sub_region_status rmap x = ok (sr, status) ->
    Mvar.get rmap.(var_region) x = Some sr
    /\ status = get_var_status rmap sr.(sr_region) x.
  Proof.
    rewrite /get_sub_region_status.
    by t_xrbindP=> ? /get_sub_regionP -> -> ->.
  Qed.

  Lemma is_validP status :
    is_valid status -> status = Valid.
  Proof. by case: status. Qed.

  Lemma check_validP (x : var_i) status tt :
    check_valid x status = ok tt ->
    status = Valid.
  Proof. by rewrite /check_valid; t_xrbindP=> /is_validP. Qed.

  Lemma sub_region_addr_glob x ofs ws :
    wf_global x ofs ws ->
    sub_region_addr se (sub_region_glob x ws) = ok (rip + wrepr _ ofs)%R.
  Proof.
    by move=> hwf; rewrite /sub_region_addr /= hwf.(wfg_offset) wrepr0 GRing.addr0.
  Qed.

  Lemma sub_region_addr_direct x sl ofs ws cs sc :
    wf_direct x sl ofs ws cs sc ->
    sub_region_addr se (sub_region_direct sl ws cs sc) =
      ok (wbase_ptr sc + wrepr _ (ofs + cs.(cs_ofs)))%R.
  Proof.
    by move=> hwf; rewrite /sub_region_addr hwf.(wfd_offset) wrepr_add GRing.addrA.
  Qed.

  Lemma sub_region_addr_stkptr x sl ofs ws cs f :
    wf_stkptr x sl ofs ws cs f ->
    sub_region_addr se (sub_region_stkptr sl ws cs) =
      ok (rsp + wrepr _ (ofs + cs.(cs_ofs)))%R.
  Proof.
    by move=> hwf; rewrite /sub_region_addr /= hwf.(wfs_offset) wrepr_add GRing.addrA.
  Qed.

  Lemma sub_region_stkptr_wf y sl ofs ws cs f :
    wf_stkptr y sl ofs ws cs f ->
    wf_sub_region se (sub_region_stkptr sl ws cs) spointer.
  Proof.
    case=> *; split=> //.
    by eexists; first by reflexivity.
  Qed.

  Lemma get_gsub_region_statusP x vpk sr status :
    get_var_kind pmap x = ok (Some vpk) ->
    get_gsub_region_status rmap x.(gv) vpk = ok (sr, status) ->
    check_gvalid rmap x = Some (sr, status).
  Proof.
    rewrite /get_var_kind /check_gvalid.
    case : (@idP (is_glob x)) => hg.
    + by t_xrbindP=> -[_ ws'] /get_globalP -> <- /= [<- <-].
    case hlocal: get_local => [pk|//] [<-].
    by move=> /get_sub_region_statusP [-> ->].
  Qed.
(*
  Lemma check_vpk_wordP al x vpk ofs ws t :
    (forall zofs, ofs = Some zofs -> 0 <= zofs /\ zofs + wsize_size ws <= size_slot x.(gv)) ->
    get_var_kind pmap x = ok (Some vpk) ->
    check_vpk_word rmap al x.(gv) vpk ofs ws = ok t ->
    exists sr bytes, [/\
      check_gvalid rmap x = Some (sr, bytes),
      let isub_ofs := interval_of_zone (sub_zone_at_ofs sr.(sr_zone) ofs (wsize_size ws)) in
      ByteSet.mem bytes isub_ofs &
      is_aligned_if al (sub_region_addr sr) ws].
  Proof.
    move=> hofs hget.
    rewrite /check_vpk_word.
    t_xrbindP=> -[[sr sr'] bytes] /(check_vpkP hofs hget) [bytesx [hgvalid -> ->]].
    assert (hwf := check_gvalid_wf wfr_wf hgvalid).
    t_xrbindP=> /check_validP hmem /(check_alignP hwf) hal.
    exists sr, bytesx; split=> //.
    apply: mem_incl_l hmem.
    by apply subset_inter_l.
  Qed.
*)

  Lemma symbolic_slice_beqP s1 s2 :
    symbolic_slice_beq s1 s2 ->
    sem_slice se s1 = sem_slice se s2.
  Proof.
    move=> /andP [eq1 eq2].
    by rewrite /sem_slice (eq_exprP _ _ _ eq1) (eq_exprP _ _ _ eq2).
  Qed.

  Lemma symbolic_zone_beq_sem_zone_aux cs z1 z2 :
    symbolic_zone_beq z1 z2 ->
    sem_zone_aux se cs z1 = sem_zone_aux se cs z2.
  Proof.
    elim: z1 z2 cs => [|s1 z1 ih] [|s2 z2] //= cs.
    rewrite /symbolic_zone_beq /= => /andP [/symbolic_slice_beqP -> /ih{}ih].
    case: sem_slice => //= cs1.
    by case: sub_concrete_slice.
  Qed.

  Lemma symbolic_zone_beq_sem_zone z1 z2 :
    symbolic_zone_beq z1 z2 ->
    sem_zone se z1 = sem_zone se z2.
  Proof.
    case: z1 z2 => [|s1 z1] [|s2 z2] //=.
    rewrite /symbolic_zone_beq /= => /andP [/symbolic_slice_beqP -> heq].
    case: sem_slice => //= cs.
    by apply symbolic_zone_beq_sem_zone_aux.
  Qed.

  Lemma sub_region_beq_addr sr1 sr2 :
    sub_region_beq sr1 sr2 ->
    sub_region_addr se sr1 = sub_region_addr se sr2.
  Proof.
    move=> /andP [/eqP heqr heqz].
    rewrite /sub_region_addr.
    by rewrite (symbolic_zone_beq_sem_zone heqz) heqr.
  Qed.

  Lemma addr_from_pkP wdb (x:var_i) pk sr ty xi ofs :
    wf_local x pk ->
    valid_pk rmap se s' sr pk ->
    wf_sub_region se sr ty ->
    addr_from_pk pmap x pk = ok (xi, ofs) ->
    exists2 w,
      get_var wdb (evm s') xi >>= to_pointer = ok w &
      sub_region_addr se sr = ok (w + wrepr _ ofs)%R.
  Proof.
    case: pk => //.
    + move=> sl ofs' ws cs sc hwfpk /= heqsub _ [<- <-].
      rewrite /= /get_var base_ptrP /= orbT /= truncate_word_u.
      eexists; first by reflexivity.
      rewrite (sub_region_beq_addr heqsub).
      by apply (sub_region_addr_direct hwfpk).
    move=> p hwfpk /= hpk hwf [<- <-].
    have [cs ok_cs _] := hwf.(wfsr_zone).
    have [w ok_w _] := wunsigned_sub_region_addr hwf ok_cs.
    rewrite /= /get_var (hpk _ ok_w) /= orbT /= truncate_word_u.
    eexists; first by reflexivity.
    by rewrite wrepr0 GRing.addr0.
  Qed.
(*
  (* If [x] is a local variable *)
  Lemma check_mk_addr_ptr (x:var_i) aa ws xi ei e1 i1 pk sr :
    sem_pexpr true [::] s' e1 >>= to_int = ok i1 ->
    wf_local x pk ->
    valid_pk rmap s' sr pk ->
    mk_addr_ptr pmap x aa ws pk e1 = ok (xi, ei) ->
    ∃ (wx wi: pointer),
      [/\ Let x := get_var true (evm s') xi in to_pointer x = ok wx,
          Let x := sem_pexpr true [::] s' ei in to_pointer x = ok wi
        & (sub_region_addr sr + wrepr Uptr (i1 * mk_scale aa ws))%R = (wx + wi)%R].
  Proof.
    move=> he1 hwfpk hpk.
    rewrite /mk_addr_ptr.
    t_xrbindP=> -[xi' ofs] haddr <- <-.
    move: haddr => /(addr_from_pkP true hwfpk hpk) [wx [-> ->]].
    rewrite (mk_ofsP _ _ _ he1) /= truncate_word_u.
    eexists _, _; split=> //.
    by rewrite Z.add_comm wrepr_add GRing.addrA.
  Qed.
*)
  Lemma addr_from_vpkP wdb (x:var_i) vpk sr ty xi ofs :
    wf_vpk x vpk ->
    valid_vpk rmap se s' x sr vpk ->
    wf_sub_region se sr ty ->
    addr_from_vpk pmap x vpk = ok (xi, ofs) ->
    exists2 w,
      get_var wdb (evm s') xi >>= to_pointer = ok w &
      sub_region_addr se sr = ok (w + wrepr _ ofs)%R.
  Proof.
    case: vpk => [[ofs' ws]|pk].
    + move=> hwfpk /= -> hwf [<- <-].
      rewrite /= /get_var vs_rip /= orbT /= truncate_word_u.
      eexists; first by reflexivity.
      by rewrite (sub_region_addr_glob hwfpk).
    by apply addr_from_pkP.
  Qed.
(*
  Lemma check_mk_addr (x:var_i) aa ws xi ei e1 i1 vpk sr :
    sem_pexpr true [::] s' e1 >>= to_int = ok i1 ->
    wf_vpk x vpk ->
    valid_vpk rmap s' x sr vpk ->
    mk_addr pmap x aa ws vpk e1 = ok (xi, ei) ->
    ∃ (wx wi : pointer),
      [/\ Let x := get_var true (evm s') xi in to_pointer x = ok wx,
          Let x := sem_pexpr true [::] s' ei in to_pointer x = ok wi
        & (sub_region_addr sr + wrepr Uptr (i1 * mk_scale aa ws))%R = (wx + wi)%R].
  Proof.
    move=> he1 hwfpk hpk.
    rewrite /mk_addr.
    t_xrbindP=> -[xi' ofs] haddr <- <-.
    move: haddr => /(addr_from_vpkP true hwfpk hpk) [wx [-> ->]].
    rewrite (mk_ofsP _ _ _ he1) /= truncate_word_u.
    eexists _, _; split=> //.
    by rewrite Z.add_comm wrepr_add GRing.addrA.
  Qed.
*)

  Let X e : Prop :=
    ∀ ty e' v v2,
      alloc_e pmap rmap e ty = ok e' →
      sem_pexpr true gd s e = ok v →
      truncate_val ty v = ok v2 ->
      exists v', sem_pexpr true [::] s' e' = ok v' /\ truncate_val ty v' = ok v2.

  Let Y es : Prop :=
    ∀ err tys es' vs vs2,
      alloc_es pmap rmap es tys = ok es' →
      sem_pexprs true gd s es = ok vs →
      mapM2 err truncate_val tys vs = ok vs2 ->
      exists vs', sem_pexprs true [::] s' es' = ok vs' /\ mapM2 err truncate_val tys vs' = ok vs2.

  Lemma check_varP (x:var_i) t: 
    check_var pmap x = ok t -> 
    get_var_kind pmap (mk_lvar x) = ok None.
  Proof. by rewrite /check_var /get_var_kind /=; case: get_local. Qed.

  Lemma get_gvar_word x ws gd vm v :
    x.(gv).(vtype) = sword ws ->
    get_gvar true gd vm x = ok v ->
    exists (ws' : wsize) (w : word ws'), (ws' <= ws)%CMP /\ v = Vword w.
  Proof.
    move=> hty hget.
    have := type_of_get_gvar hget; rewrite hty => /compat_type_subtype /subtypeE [ws' [hty' hsub]].
    case/type_of_valI: hty' => [? | [w ?]]; subst.
    + by have := get_gvar_undef hget erefl.
    by exists ws', w.
  Qed.

  Lemma check_diffP x t : check_diff pmap x = ok t -> ~Sv.In x (vnew pmap).
  Proof. by rewrite /check_diff; case:ifPn => /Sv_memP. Qed.

  (* Maybe a bit too specialized. *)
  Lemma ofs_bound_option z len size ofs :
    0 <= z /\ z + len <= size ->
    (ofs <> None -> ofs = Some z) ->
    forall zofs, ofs = Some zofs -> 0 <= zofs /\ zofs + len <= size.
  Proof.
    move=> hbound.
    case: ofs => //.
    by move=> _ /(_ ltac:(discriminate)) [->] _ [<-].
  Qed.

  (* Not sure at all if this is the right way to do the proof. *)
  Lemma wbit_subword (ws ws' : wsize) i (w : word ws) k :
    wbit_n (word.subword i ws' w) k = (k < ws')%nat && wbit_n w (k + i).
  Proof.
    clear.
    rewrite /wbit_n.
    case: ltP.
    + move=> /ltP hlt.
      by rewrite word.subwordE word.wbit_t2wE (nth_map ord0) ?size_enum_ord // nth_enum_ord.
    rewrite /nat_of_wsize => hle.
    rewrite word.wbit_word_ovf //.
    by apply /ltP; lia.
  Qed.

  (* TODO: is this result generic enough to be elsewhere ? *)
  Lemma zero_extend_wread8 (ws ws' : wsize) (w : word ws) :
    (ws' <= ws)%CMP ->
    forall off,
      0 <= off < wsize_size ws' ->
      LE.wread8 (zero_extend ws' w) off = LE.wread8 w off.
  Proof.
    clear.
    move=> /wsize_size_le /(Z.divide_pos_le _ _ (wsize_size_pos _)) hle off hoff.
    rewrite /LE.wread8 /LE.encode /split_vec.
    have hmod: forall (ws:wsize), ws %% U8 = 0%nat.
    + by move=> [].
    have hdiv: forall (ws:wsize), ws %/ U8 = Z.to_nat (wsize_size ws).
    + by move=> [].
    have hlt: (Z.to_nat off < Z.to_nat (wsize_size ws))%nat.
    + by apply /ltP /Z2Nat.inj_lt; lia.
    have hlt': (Z.to_nat off < Z.to_nat (wsize_size ws'))%nat.
    + by apply /ltP /Z2Nat.inj_lt; lia.
    rewrite !hmod !addn0.
    rewrite !(nth_map 0%nat) ?size_iota ?hdiv // !nth_iota // !add0n.
    apply /eqP/eq_from_wbit_n => i.
    rewrite !wbit_subword; f_equal.
    rewrite wbit_zero_extend.
    have -> //: (i + Z.to_nat off * U8 <= wsize_size_minus_1 ws')%nat.
    rewrite -ltnS -/(nat_of_wsize ws').
    apply /ltP.
    have := ltn_ord i; rewrite -/(nat_of_wsize _) => /ltP hi.
    have /ltP ? := hlt'.
    have <-: (Z.to_nat (wsize_size ws') * U8 = ws')%nat.
    + by case: (ws').
    by rewrite -!multE -!plusE; nia.
  Qed.

  Lemma check_e_esP : (∀ e, X e) * (∀ es, Y es).
  Proof.
    apply: pexprs_ind_pair; subst X Y; split => //=.
    + move=> err [|//] _ _ _ /= [<-] [<-] [<-].
      by exists [::].
    + move=> e he es hes err [//|ty tys].
      t_xrbindP=> _ _ vs2 e' ok_e' es' ok_es' <- v ok_v vs ok_vs <- /=.
      t_xrbindP=> v2 ok_v2 {}vs2 ok_vs2 <-.
      have [v' [ok_v' htr]] := he _ _ _ _ ok_e' ok_v ok_v2.
      have [vs' [ok_vs' htrs]] := hes _ _ _ _ _ ok_es' ok_vs ok_vs2.
      rewrite ok_v' ok_vs' /=.
      eexists; split; first by reflexivity.
      by rewrite /= htr htrs.
    + move=> z ???? [<-] [<-] /= /truncate_valE [-> ->].
      by eexists; split; first by reflexivity.
    + move=> b ???? [<-] [<-] /= /truncate_valE [-> ->].
      by eexists; split; first by reflexivity.
    + move=> n ???? [<-] [<-] /= /truncate_valE [-> ->].
      eexists; split; first by reflexivity.
      by rewrite /truncate_val /= WArray.castK /=.
    + move=> x ty e' v v2; t_xrbindP => -[ vpk | ] hgvk; last first.
      + t_xrbindP=> /check_diffP hnnew <- /= ok_v htr.
        exists v; split=> //.
        by apply: get_var_kindP.
      case hty: is_word_type => [ws | //]; move /is_word_typeP in hty; subst.
      case: ifP => //; rewrite -/(subtype (sword _) _) => hsub.
      t_xrbindP=> -[sr status] hgsub.
      t_xrbindP=> hcvalid halign [xi ofsi] haddr [<-] hget /= htr.
      have hgvalid := get_gsub_region_statusP hgvk hgsub.
      have hwf := [elaborate check_gvalid_wf wfr_wf hgvalid].
      have hvpk: valid_vpk rmap se s' x.(gv) sr vpk.
      + have /wfr_gptr := hgvalid.
        by rewrite hgvk => -[_ [[]] <-].
      have [wi ok_wi eq_addr] :=
        addr_from_vpkP true (get_var_kind_wf hgvk) hvpk hwf haddr.
      rewrite ok_wi /= truncate_word_u /=.
      have [ws' [htyx hcmp]] := subtypeEl hsub.
      assert (heq := wfr_val hgvalid hget); rewrite htyx in heq.
      case: heq => hread hty'.
      have [ws'' [w [_ ?]]] := get_gvar_word htyx hget; subst v.
      case: hty' => ?; subst ws''.
      have ? := check_validP hcvalid; subst status.
      rewrite -(GRing.addr0 (_+_)%R) -wrepr0.
      rewrite (eq_sub_region_val_read_word _ hwf hread eq_addr (w:=zero_extend ws w)).
      + rewrite wrepr0 GRing.addr0.
        rewrite (check_alignP hwf eq_addr halign) /=.
        eexists; split; first by reflexivity.
        move: htr; rewrite /truncate_val /=.
        t_xrbindP=> ? /truncate_wordP [_ ->] <-.
        by rewrite truncate_word_u.
      move=> k hk.
      rewrite zero_extend_wread8 //.
      apply (get_val_byte_word w).
      by have /= := size_of_le hsub; rewrite htyx /=; lia.
    + move=> al aa sz x e1 he1 ty e' v v2 he'; apply: on_arr_gvarP => n t htyx /= hget.
      t_xrbindP => i vi /he1{he1}he1 hvi w hw <- htr.
      exists (Vword w); split=> //.
      move: he'; t_xrbindP => e1' /he1{he1}.
      rewrite /truncate_val /= hvi /= => /(_ _ erefl) [] v' [] he1'.
      t_xrbindP=> i' hv' ?; subst i'.
      have h0 : sem_pexpr true [::] s' e1' >>= to_int = ok i.
      + by rewrite he1' /= hv'.
      move=> [vpk | ]; last first.
      + t_xrbindP => h /check_diffP h1 <- /=.
        by rewrite (get_var_kindP h h1 hget) /= h0 /= hw.
      t_xrbindP=> hgvk [sr status] hgsub.
      t_xrbindP=> hcvalid halign [xi ofsi] haddr [<-] /=.
      have hgvalid := get_gsub_region_statusP hgvk hgsub.
      have hwf := [elaborate check_gvalid_wf wfr_wf hgvalid].
      have hvpk: valid_vpk rmap se s' x.(gv) sr vpk.
      + have /wfr_gptr := hgvalid.
        by rewrite hgvk => -[_ [[]] <-].
      have [wi ok_wi eq_addr] :=
        addr_from_vpkP true (get_var_kind_wf hgvk) hvpk hwf haddr.
      rewrite ok_wi /= (mk_ofsP aa sz ofsi h0) /= truncate_word_u /=.
      assert (heq := wfr_val hgvalid hget).
      case: heq => hread _.
      have ? := check_validP hcvalid; subst status.
      rewrite wrepr_add (GRing.addrC (wrepr _ _)) GRing.addrA.
      rewrite (eq_sub_region_val_read_word _ hwf hread eq_addr (w:=w)).
      + case: al hw halign => //= hw halign.
        have {}halign := check_alignP hwf eq_addr halign.
        rewrite (is_align_addE halign) WArray.arr_is_align.
        by have [_ _ /= ->] := WArray.get_bound hw.
      have [_ hread8] := (read_read8 hw).
      by move => k hk; rewrite /= (read8_alignment al) -hread8.
    + move=> al1 sz1 v1 e1 IH ty e2 v v2.
      t_xrbindP => /check_varP hc /check_diffP hnnew e1' /IH hrec <- wv1 vv1 /= hget hto' we1 ve1.
      move=> he1 hto wr hr ? htr; subst v.
      exists (Vword wr); split=> //.
      have := hrec _ _ he1.
      rewrite /truncate_val /= hto /= => /(_ _ erefl) [] v' [] he1'.
      t_xrbindP=> w hv' ?; subst w.
      have := get_var_kindP hc hnnew hget; rewrite /get_gvar /= => -> /=.
      rewrite hto' /= he1' /= hv' /=.
      by rewrite -(eq_mem_source_word hvalid (readV hr)) hr.
    + move=> o1 e1 IH ty e2 v v2.
      t_xrbindP => e1' /IH hrec <- ve1 /hrec{}hrec hve1 htr.
      exists v; split=> //=.
      have [ve1' [htr' hve1']] := sem_sop1_truncate_val hve1.
      have [v' [he1' /truncate_value_uincl huincl]] := hrec _ htr'.
      rewrite he1' /=.
      by apply (vuincl_sem_sop1 huincl).
    + move=> o2 e1 H1 e2 H2 ty e' v v2.
      t_xrbindP => e1' /H1 hrec1 e2' /H2 hrec2 <- ve1 /hrec1{}hrec1 ve2 /hrec2{}hrec2 ho2 htr.
      exists v; split=> //=.
      have [ve1' [ve2' [htr1 htr2 ho2']]] := sem_sop2_truncate_val ho2.
      have [v1' [-> /truncate_value_uincl huincl1]] := hrec1 _ htr1.
      have [v2' [-> /truncate_value_uincl huincl2]] := hrec2 _ htr2.
      by rewrite /= (vuincl_sem_sop2 huincl1 huincl2 ho2').
    + move => o es1 H1 ty e2 v v2.
      t_xrbindP => es1' /H1{H1}H1 <- ves /H1{H1}H1 /= hves htr.
      exists v; split=> //.
      rewrite -/(sem_pexprs _ _ _ _).
      have [ves' [htr' hves']] := sem_opN_truncate_val hves.
      have [vs' [-> /mapM2_truncate_value_uincl huincl]] := H1 _ _ htr'.
      by rewrite /= (vuincl_sem_opN huincl hves').
    move=> t e He e1 H1 e2 H2 ty e' v v2.
    t_xrbindP=> e_ /He he e1_ /H1 hrec1 e2_ /H2 hrec2 <-.
    move=> b vb /he{}he hvb ve1 ve1' /hrec1{}hrec1 htr1 ve2 ve2' /hrec2{}hrec2 htr2 <- htr.
    move: he; rewrite {1 2}/truncate_val /= hvb /= => /(_ _ erefl) [] vb' [] -> /=.
    t_xrbindP=> b' -> ? /=; subst b'.
    have hsub: subtype ty t.
    + have := truncate_val_subtype htr.
      rewrite fun_if.
      rewrite (truncate_val_has_type htr1) (truncate_val_has_type htr2).
      by rewrite if_same.
    have [ve1'' htr1''] := subtype_truncate_val hsub htr1.
    have := subtype_truncate_val_idem hsub htr1 htr1''.
    move=> /hrec1 [ve1_ [-> /= ->]] /=.
    have [ve2'' htr2''] := subtype_truncate_val hsub htr2.
    have := subtype_truncate_val_idem hsub htr2 htr2''.
    move=> /hrec2 [ve2_ [-> /= ->]] /=.
    eexists; split; first by reflexivity.
    move: htr.
    rewrite !(fun_if (truncate_val ty)).
    rewrite htr1'' htr2''.
    by rewrite (truncate_val_idem htr1'') (truncate_val_idem htr2'').
  Qed.

  Definition alloc_eP := check_e_esP.1.
  Definition alloc_esP := check_e_esP.2.

End EXPR.

Lemma get_localn_checkg_diff rmap sr_status se s2 x y :
  get_local pmap x = None ->
  wfr_PTR rmap se s2 ->
  check_gvalid rmap y = Some sr_status ->
  (~is_glob y -> x <> (gv y)).
Proof.
  rewrite /check_gvalid; case:is_glob => // hl hwf.
  case heq: Mvar.get => [sr' | // ] _ _.
  by have /hwf [pk [hy _]] := heq; congruence.
Qed.

Section CLONE.

Variable (clone : (var_i → PrimInt63.int → var_i)).
Context (clone_ty : forall x n, (clone x n).(vtype) = x.(vtype)).

Notation symbolic_of_pexpr := (symbolic_of_pexpr clone).
Notation get_symbolic_of_pexpr := (get_symbolic_of_pexpr clone).

Section SYMBOLIC_OF_PEXPR_VARS.

Let X e := forall table table' e',
  symbolic_of_pexpr table e = Some (table', e') ->
  wft_VARS table -> [/\
    wft_VARS table',
    Sv.Subset table.(vars) table'.(vars) &
    Sv.Subset (read_e e') table'.(vars)].

Let Y es := forall table table' es',
  fmapo symbolic_of_pexpr table es = Some (table', es') ->
  wft_VARS table -> [/\
    wft_VARS table',
    Sv.Subset table.(vars) table'.(vars) &
    Sv.Subset (read_es es') table'.(vars)].

Lemma symbolic_of_pexpr_vars_e_es :
  (forall e, X e) /\ (forall es, Y es).
Proof.
  apply: pexprs_ind_pair; split; subst X Y => //=.
  + move=> table _ _ [<- <-] hvars.
    split=> //.
    rewrite /read_es /=.
    by clear; SvD.fsetdec.
  + move=> e he es hes table table' es'.
    apply: obindP => -[table1 e'] /he{}he.
    apply: obindP => -[table2 {}es'] /= /hes{}hes [<- <-] hvars.
    have [hvars1 hsub1 hsubr1] := he hvars.
    have [hvars2 hsub2 hsubr2] := hes hvars1.
    split=> //.
    + by clear -hsub1 hsub2; SvD.fsetdec.
    rewrite read_es_cons.
    by clear -hsubr1 hsub2 hsubr2; SvD.fsetdec.
  + move=> z table _ _ [<- <-] hvars.
    split=> //.
    rewrite /read_e /=.
    by clear; SvD.fsetdec.
  + move=> b table _ _ [<- <-] hvars.
    split=> //.
    rewrite /read_e /=.
    by clear; SvD.fsetdec.
  + move=> x table table' e'.
    case: is_lvar => //.
    rewrite /table_get_var.
    case hget: Mvar.get => [e|].
    + move=> [<- <-] hvars.
      split=> //.
      by apply: hvars hget.
    rewrite /table_fresh_var /=.
    case: Sv_memP => // hnin.
    case: Mvar.get => //.
    rewrite /table_set_var /=.
    case: Sv.mem => //.
    move=> [<- <-] hvars /=.
    split.
    + move=> y ey /=.
      rewrite Mvar.setP.
      case: eq_op.
      + move=> [<-] /=.
        rewrite read_e_var /read_gvar /=.
        by clear; SvD.fsetdec.
      move=> /hvars.
      by clear; SvD.fsetdec.
    + by clear; SvD.fsetdec.
    rewrite read_e_var /read_gvar /=.
    by clear; SvD.fsetdec.
  + move=> op e he table table' e'.
    apply: obindP => -[{}table' {}e'] /he{}he [<- <-] hvars.
    have [hvars' hsub hsubr] := he hvars.
    by split.
  + move=> op e1 he1 e2 he2 table table' e'.
    apply: obindP => -[table1 e1'] /he1{}he1.
    apply: obindP => -[table2 e2'] /he2{}he2.
    move=> [<- <-] hvars.
    have [hvars1 hsub1 hsubr1] := he1 hvars.
    have [hvars2 hsub2 hsubr2] := he2 hvars1.
    split=> //.
    + by clear -hsub1 hsub2; SvD.fsetdec.
    rewrite read_e_Papp2.
    by clear -hsubr1 hsub2 hsubr2; SvD.fsetdec.
  + move=> op es hes table table' e'.
    apply: obindP => -[table1 es'] /hes{}hes.
    move=> [<- <-] hvars.
    have [hvars1 hsub1 hsubr1] := hes hvars.
    by split.
  move=> ty b hb e1 he1 e2 he2 table table' e'.
  apply: obindP => -[table1 b'] /hb{}hb.
  apply: obindP => -[table2 e1'] /he1{}he1.
  apply: obindP => -[table3 e2'] /he2{}he2.
  move=> [<- <-] hvars.
  have [hvars1 hsub1 hsubr1] := hb hvars.
  have [hvars2 hsub2 hsubr2] := he1 hvars1.
  have [hvars3 hsub3 hsubr3] := he2 hvars2.
  split=> //.
  + by clear -hsub1 hsub2 hsub3; SvD.fsetdec.
  rewrite read_e_Pif.
  by clear -hsubr1 hsub2 hsubr2 hsub3 hsubr3; SvD.fsetdec.
Qed.

(* in practice, subsumed by wf_table_symbolic_of_pexpr *)
Lemma wft_VARS_symbolic_of_pexpr table table' e e' :
  symbolic_of_pexpr table e = Some (table', e') ->
  wft_VARS table ->
  wft_VARS table'.
Proof.
  move=> he hvars.
  by have [hvars' _ _] := symbolic_of_pexpr_vars_e_es.1 _ _ _ _ he hvars.
Qed.

(* Actually, the hypothesis wft_VARS is not needed, but is was simpler to prove
   the 3 propositions in one go. *)
Lemma symbolic_of_pexpr_subset_vars table table' e e' :
  symbolic_of_pexpr table e = Some (table', e') ->
  wft_VARS table ->
  Sv.Subset table.(vars) table'.(vars).
Proof.
  move=> he hvars.
  by have [_ hsub _] := symbolic_of_pexpr_vars_e_es.1 _ _ _ _ he hvars.
Qed.

Lemma symbolic_of_pexpr_subset_read table table' e e' :
  symbolic_of_pexpr table e = Some (table', e') ->
  wft_VARS table ->
  Sv.Subset (read_e e') table'.(vars).
Proof.
  move=> he hvars.
  by have [_ _ hsubr] := symbolic_of_pexpr_vars_e_es.1 _ _ _ _ he hvars.
Qed.

End SYMBOLIC_OF_PEXPR_VARS.

Section WF_TABLE_SYMBOLIC_OF_PEXPR.

Context (s : estate).

(* FIXME: the formulation of wft_SEM should allow to insert in the table the variables
   that do not yet have a semantics, to avoid problems with if that define
   variables only in one branch. This would also allow to avoid alloc_array_move
   from updating table *)
Let X e :=
  forall table table' e' se,
    symbolic_of_pexpr table e = Some (table', e') ->
    wf_table table se s.(evm) ->
    exists vme, [/\
      wf_table table' (with_vm se vme) s.(evm),
      se.(evm) <=1 vme &
      forall gd v1,
        sem_pexpr true gd s e = ok v1 ->
        exists2 v2,
          sem_pexpr true [::] (with_vm se vme) e' = ok v2 &
          value_uincl v1 v2].

Let Y es :=
  forall table table' es' se,
    fmapo symbolic_of_pexpr table es = Some (table', es') ->
    wf_table table se s.(evm) ->
    exists vme, [/\
      wf_table table' (with_vm se vme) s.(evm),
      se.(evm) <=1 vme &
      forall gd vs1,
        sem_pexprs true gd s es = ok vs1 ->
        exists2 vs2,
          sem_pexprs true [::] (with_vm se vme) es' = ok vs2 &
          List.Forall2 value_uincl vs1 vs2].

Lemma wf_table_symbolic_of_pexpr_e_es : (forall e, X e) /\ (forall es, Y es).
Proof.
  apply: pexprs_ind_pair; split; subst X Y => //=.
  - move=> table _ _ se [<- <-] hwft.
    exists se.(evm); split=> //=.
    + by rewrite with_vm_same.
    move=> _ _ [<-].
    by eexists; first by reflexivity.
  - move=> e he es hes table table' es' se.
    apply: obindP => -[table1 e'] hsyme.
    apply: obindP => -[table2 {}es'] /= hsymes [<- <-] hwft.
    have [vme1 [hwft1 hincl1 hseme1]] := he _ _ _ _ hsyme hwft.
    have [vme2 [hwft2 hincl2 hseme2]] := hes _ _ _ _ hsymes hwft1.
    exists vme2; split=> //=.
    + exact: vm_uinclT hincl1 hincl2.
    t_xrbindP=> gd vs1 v1 /hseme1 [v2 ok_v2 hincl]
      {}vs /hseme2 [vs2 ok_vs2 hincls] <-.
    have [v2' ok_v2' hincl'] := sem_pexpr_uincl hincl2 ok_v2.
    rewrite ok_v2' ok_vs2 /=.
    eexists; first by reflexivity.
    constructor=> //.
    exact: value_uincl_trans hincl hincl'.
  - move=> z table _ _ se [<- <-] hwft.
    exists se.(evm); split=> //=.
    + by rewrite with_vm_same.
    move=> _ _ [<-].
    by eexists; first by reflexivity.
  - move=> b table _ _ se [<- <-] hwft.
    exists se.(evm); split=> //=.
    + by rewrite with_vm_same.
    move=> _ _ [<-].
    by eexists; first by reflexivity.
  - move=> x table table' e' se.
    case: ifP => // hlvar.
    rewrite /table_get_var.
    case hget: Mvar.get => [e|].
    + move=> [<- <-] hwft.
      exists se.(evm); split=> //.
      + by rewrite with_vm_same.
      move=> gd v1.
      rewrite /get_gvar hlvar with_vm_same.
      by apply: hwft.(wft_sem) hget.
    rewrite /table_fresh_var.
    set x' := clone x.(gv) _.
    case: Sv_memP => // hnin.
    case: Mvar.get => //.
    rewrite /table_set_var /=.
    case: Sv.mem => //.
    move=> [<- <-] hwft.
    exists se.(evm).[x' <- s.(evm).[x.(gv)]].
    split=> /=.
    + case: hwft => hvars hundef hsem.
      split.
      + move=> y ey /=.
        rewrite Mvar.setP.
        case: eq_op.
        + move=> [<-] /=.
          rewrite read_e_var /read_gvar /=.
          by clear; SvD.fsetdec.
        move=> /hvars.
        by clear; SvD.fsetdec.
      + move=> y /= ynin.
        rewrite Vm.setP_neq; last first.
        + apply /eqP.
          by clear -ynin; SvD.fsetdec.
        apply hundef.
        by clear -ynin; SvD.fsetdec.
      move=> y ey vy /=.
      rewrite Mvar.setP.
      case: eqP.
      + move=> <- [<-] /=.
        rewrite /get_gvar /= /get_var Vm.setP_eq.
        rewrite compat_val_vm_truncate_val; last first.
        + by rewrite clone_ty; apply Vm.getP.
        by move=> ?; exists vy.
      move=> _ hey ok_vy.
      have [v2 ok_v2 hincl] := hsem _ _ _ hey ok_vy.
      exists v2 => //.
      rewrite -ok_v2.
      apply eq_on_sem_pexpr => //=.
      move=> y' hin.
      rewrite Vm.setP_neq //.
      apply /eqP => /=.
      have := hvars _ _ hey.
      by clear -hin hnin; SvD.fsetdec.
    + apply: vm_uincl_set_r (vm_uincl_refl _).
      rewrite (hwft.(wft_undef) hnin).
      by apply/compat_value_uincl_undef/vm_truncate_val_compat.
    move=> gd v1.
    rewrite /get_gvar hlvar /= /get_var Vm.setP_eq.
    rewrite compat_val_vm_truncate_val; last first.
    + by rewrite clone_ty; apply Vm.getP.
    by move=> ?; exists v1.
  - move=> op e he table table' e' se.
    apply: obindP => -[{}table' {}e'] hsyme [<- <-] hwft.
    have [vme1 [hwft1 hincl1 hseme1]] := he _ _ _ _ hsyme hwft.
    exists vme1; split=> //=.
    t_xrbindP=> gd v1 ve /hseme1 [v2 -> hincl] ok_v1 /=.
    exists v1 => //.
    exact: (vuincl_sem_sop1 hincl ok_v1).
  - move=> op e1 he1 e2 he2 table table' e' se.
    apply: obindP => -[table1 e1'] hsyme1.
    apply: obindP => -[table2 e2'] hsyme2.
    move=> [<- <-] hwft.
    have [vme1 [hwft1 hincl1 hseme1]] := he1 _ _ _ _ hsyme1 hwft.
    have [vme2 [hwft2 hincl2 hseme2]] := he2 _ _ _ _ hsyme2 hwft1.
    exists vme2; split=> //=.
    + exact: vm_uinclT hincl1 hincl2.
    t_xrbindP=> gd v ve1 /hseme1 [v1 ok_v1 incl_v1] ve2
      /hseme2 [v2 ok_v2 incl_v2] ok_v.
    have [v1' ok_v1' incl_v1'] := sem_pexpr_uincl hincl2 ok_v1.
    rewrite ok_v1' ok_v2 /=.
    exists v => //.
    exact: (vuincl_sem_sop2 (value_uincl_trans incl_v1 incl_v1') incl_v2 ok_v).
  + move=> op es hes table table' e' se.
    apply: obindP => -[table1 es'] hsymes.
    move=> [<- <-] hwft.
    have [vme1 [hwft1 hincl1 hseme1]] := hes _ _ _ _ hsymes hwft.
    exists vme1; split=> //=.
    t_xrbindP=> gd v1 vs1 /hseme1 [vs2 ok_vs2 hincls] ok_v1.
    rewrite -/(sem_pexprs _ _ _ _) ok_vs2 /=.
    exists v1 => //.
    exact: (vuincl_sem_opN hincls ok_v1).
  move=> ty b hb e1 he1 e2 he2 table table' e' se.
  apply: obindP => -[table1 b'] hsymb.
  apply: obindP => -[table2 e1'] hsyme1.
  apply: obindP => -[table3 e2'] hsyme2.
  move=> [<- <-] hwft.
  have [vmeb [hwftb hinclb hsemb]] := hb _ _ _ _ hsymb hwft.
  have [vme1 [hwft1 hincl1 hseme1]] := he1 _ _ _ _ hsyme1 hwftb.
  have [vme2 [hwft2 hincl2 hseme2]] := he2 _ _ _ _ hsyme2 hwft1.
  exists vme2; split=> //=.
  + apply: vm_uinclT hincl2.
    exact: vm_uinclT hinclb hincl1.
  t_xrbindP=> gd v bb vb /hsemb [vb' ok_vb' incl_vb'] ok_bb
    ve1' ve1 /hseme1 [v1 ok_v1 incl_v1] ok_ve1'
    ve2' ve2 /hseme2 [v2 ok_v2 incl_v2] ok_ve2' eq_v.
  have [vb'' ok_vb'' incl_vb''] := sem_pexpr_uincl hincl1 ok_vb'.
  have [vb''' ok_vb''' incl_vb'''] := sem_pexpr_uincl hincl2 ok_vb''.
  have [v1' ok_v1' incl_v1'] := sem_pexpr_uincl hincl2 ok_v1.
  rewrite ok_vb''' ok_v1' ok_v2 /=.
  have incl_vb: value_uincl vb vb'''.
  + apply: value_uincl_trans incl_vb'''.
    exact: value_uincl_trans incl_vb' incl_vb''.
  have /= -> := of_value_uincl_te (ty:=sbool) incl_vb ok_bb.
  have [v1'' -> incl_v1''] := value_uincl_truncate (value_uincl_trans incl_v1 incl_v1') ok_ve1'.
  have [v2'' -> incl_v2''] /= := value_uincl_truncate incl_v2 ok_ve2'.
  eexists; first by reflexivity.
  rewrite -eq_v.
  by case: (bb).
Qed.

Definition wf_table_symbolic_of_pexpr := wf_table_symbolic_of_pexpr_e_es.1.

End WF_TABLE_SYMBOLIC_OF_PEXPR.

End CLONE.

(*
(* warm-up, to remove at some point *)
Lemma wf_table_update_table table se s1 e v ty v' r s1' table' :
  wf_table table se (evm s1) ->
  sem_pexpr true gd s1 e = ok v ->
  truncate_val ty v = ok v' ->
  write_lval true gd r v' s1 = ok s1' ->
  update_table table r ty e = ok table' ->
  exists2 vme,
    wf_table table' (with_vm se vme) s1'.(evm) &
    se.(evm) <=1 vme.
Proof.
  move=> hwft hsem htrunc hw.
  rewrite /update_table.
  case: r hw => /=.
  + move=> _ _ /write_noneP [-> _ _] [<-].
    exists se.(evm) => //.
    by rewrite with_vm_same.
  + move=> x hw.
    case hsym: symbolic_of_pexpr => [[table1 e1]|]; last first.
    + move=> [<-].
      exists se.(evm) => //.
      split=> /=.
      + move=> y ey /=.
        rewrite Mvar.removeP; case: eq_op => //.
        by apply: hwft.(wft_vars).
      + exact: hwft.(wft_undef).
      move=> y ey vy /=.
      rewrite Mvar.removeP.
      have [_ _ ->] := write_get_varP hw.
      case: eq_op => //.
      rewrite with_vm_same.
      by apply hwft.(wft_sem).
    t_xrbindP=> _ /o2rP.
    rewrite /table_set_var.
    case: Sv_memP => // hnin [<-].
    have [vme1 [hwft1 hincl1 hseme1]] := wf_table_symbolic_of_pexpr hsym hwft.
    exists vme1 => //.
    split.
    + move=> y ey /=.
      rewrite Mvar.setP.
      case: eq_op.
      + move=> [<-].
        exact: (symbolic_of_pexpr_subset_read hsym hwft.(wft_vars)).
      exact: hwft1.(wft_vars).
    + exact: hwft1.(wft_undef).
    move=> y ey vy /=.
    rewrite Mvar.setP.
    have [hdb htr ->] := write_get_varP hw.
    case: eq_op.
    + move=> [<-].
      t_xrbindP=> _ <-.
      have [v2 ok_v2 hincl] := hseme1 _ _ hsem.
      exists v2 => //.
      apply: value_uincl_trans hincl.
      apply: value_uincl_trans (truncate_value_uincl htrunc).
      exact: vm_truncate_value_uincl htr.
    exact: hwft1.(wft_sem).
  + t_xrbindP=> ???????????????? <- <- /=.
    exists se.(evm) => //.
    by rewrite with_vm_same.
  + t_xrbindP=> ?????.
    apply: on_arr_varP.
    t_xrbindP=> ???????????? hw <-.
    exists se.(evm) => //.
    split=> /=.
    + move=> y ey /=.
      rewrite Mvar.removeP; case: eq_op => //.
      by apply: hwft.(wft_vars).
    + exact: hwft.(wft_undef).
    move=> y ey vy /=.
    rewrite Mvar.removeP.
    have [_ _ ->] := write_get_varP hw.
    case: eq_op => //.
    rewrite with_vm_same.
    by apply hwft.(wft_sem).
  t_xrbindP=> ?????.
  apply: on_arr_varP.
  t_xrbindP=> ???????????? hw <-.
  exists se.(evm) => //.
  split=> /=.
  + move=> y ey /=.
    rewrite Mvar.removeP; case: eq_op => //.
    by apply: hwft.(wft_vars).
  + exact: hwft.(wft_undef).
  move=> y ey vy /=.
  rewrite Mvar.removeP.
  have [_ _ ->] := write_get_varP hw.
  case: eq_op => //.
  rewrite with_vm_same.
  by apply hwft.(wft_sem).
Qed. *)

Lemma sem_slice_vm_uincl se vm s cs :
  vm_uincl se.(evm) vm ->
  sem_slice se s = ok cs ->
  sem_slice (with_vm se vm) s = ok cs.
Proof.
  move=> hincl.
  rewrite /sem_slice.
  t_xrbindP=> z1 v1 ok_v1 ok_z1 z2 v2 ok_v2 ok_z2 <-.
  have [v1' -> hincl1] := sem_pexpr_uincl hincl ok_v1.
  have /= -> := of_value_uincl_te (ty:=sint) hincl1 ok_z1.
  have [v2' -> hincl2] := sem_pexpr_uincl hincl ok_v2.
  have /= -> := of_value_uincl_te (ty:=sint) hincl2 ok_z2.
  done.
Qed.

Lemma sem_zone_aux_vm_uincl se vm z cs1 cs2 :
  vm_uincl se.(evm) vm ->
  sem_zone_aux se cs1 z = ok cs2 ->
  sem_zone_aux (with_vm se vm) cs1 z = ok cs2.
Proof.
  move=> hincl.
  elim: z cs1 => [//|s z ih] cs1 /=.
  t_xrbindP=> _ /(sem_slice_vm_uincl hincl) -> {}cs1 /= -> /=.
  by apply ih.
Qed.

Lemma sem_zone_vm_uincl se vm z cs :
  vm_uincl se.(evm) vm ->
  sem_zone se z = ok cs ->
  sem_zone (with_vm se vm) z = ok cs.
Proof.
  move=> hincl.
  case: z => [//|s z] /=.
  by t_xrbindP=>
    _ /(sem_slice_vm_uincl hincl) -> /= /(sem_zone_aux_vm_uincl hincl) ->.
Qed.

Lemma sub_region_addr_vm_uincl se vme sr addr :
  vm_uincl se.(evm) vme ->
  sub_region_addr se sr = ok addr ->
  sub_region_addr (with_vm se vme) sr = ok addr.
Proof.
  move=> hincl.
  rewrite /sub_region_addr; t_xrbindP=> cs ok_cs <-.
  by rewrite (sem_zone_vm_uincl hincl ok_cs) /=.
Qed.

(* TODO: better name & move *)
Lemma mapM_ext_alt {eT aT bT} (f1 f2 : aT -> result eT bT) m m' :
  (forall a b, List.In a m -> f1 a = ok b -> f2 a = ok b) ->
  mapM f1 m = ok m' ->
  mapM f2 m = ok m'.
Proof.
  elim: m m' => [//|a m ih] /= m' hext.
  t_xrbindP=> b ok_b {}m' ok_m' <-.
  rewrite (hext _ _ _ ok_b) /=; last by left.
  rewrite (ih _ _  ok_m') //.
  by move=> ???; apply hext; right.
Qed.

Lemma valid_offset_interval_vm_uincl se vme i off :
  vm_uincl se.(evm) vme ->
  wf_interval se i ->
  valid_offset_interval se i off
    <-> valid_offset_interval (with_vm se vme) i off.
Proof.
  move=> huincl [ci [ok_ci _ _]].
  have ok_ci_alt: mapM (sem_slice (with_vm se vme)) i = ok ci.
  + apply: mapM_ext_alt ok_ci.
    move=> s cs _ ok_cs.
    exact: sem_slice_vm_uincl huincl ok_cs.
  rewrite /valid_offset_interval ok_ci ok_ci_alt.
  by split; move=> hvalid _ [<-]; apply hvalid.
Qed.

Lemma valid_offset_vm_uincl se vme status off :
  vm_uincl se.(evm) vme ->
  wf_status se status ->
  valid_offset se status off <-> valid_offset (with_vm se vme) status off.
Proof.
  move=> huincl.
  case: status => //= i.
  exact: valid_offset_interval_vm_uincl huincl.
Qed.

Lemma wf_sub_region_vm_uincl se vme sr vm :
  se.(evm) <=1 vme ->
  wf_sub_region se sr vm ->
  wf_sub_region (with_vm se vme) sr vm.
Proof.
  move=> huincl.
  case=> hwfr [cs ok_cs wf_cs].
  split=> //.
  exists cs => //.
  by apply (sem_zone_vm_uincl huincl ok_cs).
Qed.

Lemma wf_status_vm_uincl se vme status :
  se.(evm) <=1 vme ->
  wf_status se status ->
  wf_status (with_vm se vme) status.
Proof.
  move=> huincl.
  case: status => //= i [ci [ok_ci all_ci sorted_ci]].
  exists ci; split=> //.
  apply: mapM_ext_alt ok_ci.
  by move=> s cs _; apply: sem_slice_vm_uincl huincl.
Qed.

Lemma eq_sub_region_val_vm_uincl se vme ty m sr status v :
  se.(evm) <=1 vme ->
  wf_sub_region se sr ty ->
  wf_status se status ->
  eq_sub_region_val ty se m sr status v ->
  eq_sub_region_val ty (with_vm se vme) m sr status v.
Proof.
  move=> huincl hwf hwfs [hread hty].
  split=> // off addr w haddr off_valid ok_w.
  apply: hread ok_w.
  + have [cs ok_cs _] := hwf.(wfsr_zone).
    have [ofs' haddr' _] := wunsigned_sub_region_addr hwf ok_cs.
    have := sub_region_addr_vm_uincl huincl haddr'.
    by rewrite haddr => -[?]; subst ofs'.
  by rewrite (valid_offset_vm_uincl _ huincl hwfs).
Qed.

Lemma wf_rmap_vm_uincl rmap se s1 s2 vme :
  se.(evm) <=1 vme ->
  wf_rmap rmap se s1 s2 ->
  wf_rmap rmap (with_vm se vme) s1 s2.
Proof.
  move=> huincl.
  case=> hwfsr hwfst hval hptr.
  split=> //.
  + move=> x sr /hwfsr hwf.
    by apply (wf_sub_region_vm_uincl huincl hwf).
  + move=> r sm x status hsm hstatus.
    have {hsm hstatus} := hwfst _ _ _ _ hsm hstatus.
    by apply (wf_status_vm_uincl huincl).
  + move=> x sr status v hgvalid hgget.
    have {hgget} heqval := hval _ _ _ _ hgvalid hgget.
    have /= hwf := check_gvalid_wf hwfsr hgvalid.
    have /= hwfs := check_gvalid_wf_status hwfst hgvalid.
    by apply eq_sub_region_val_vm_uincl.
  move=> x sr /[dup] hsr /hptr [pk [hget hpk]].
  exists pk; split=> //.
  case: pk hpk {hget} => //=.
  + move=> xp hxp ofs haddr; apply hxp.
    have hwf := hwfsr _ _ hsr.
    have [cs ok_cs _] := hwf.(wfsr_zone).
    have [ofs' haddr' _] := wunsigned_sub_region_addr hwf ok_cs.
    have := sub_region_addr_vm_uincl huincl haddr'.
    by rewrite haddr => -[?]; subst ofs'.
  move=> s ofs ws cs f hpk hcheck pofs ofs' ok_pofs ok_ofs'.
  apply hpk => //.
  have hwf := hwfsr _ _ hsr.
  have [cs' ok_cs' _] := hwf.(wfsr_zone).
  have [ofs'' haddr'' _] := wunsigned_sub_region_addr hwf ok_cs'.
  have := sub_region_addr_vm_uincl huincl haddr''.
  by rewrite ok_ofs' => -[?]; subst ofs''.
Qed.

Lemma valid_state_vm_uincl se vme table' table rmap m0 s1 s2 :
  se.(evm) <=1 vme ->
  wf_table table' (with_vm se vme) s1.(evm) ->
  valid_state table rmap se m0 s1 s2 ->
  valid_state table' rmap (with_vm se vme) m0 s1 s2.
Proof.
  move=> huincl hwft'.
  case=>
    /= hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem
    hglobv htop.
  split=> //.
  by apply wf_rmap_vm_uincl.
Qed.

Lemma wf_table_set_var table se vm x v :
  wf_table table se vm ->
  wf_table (remove_binding table x) se vm.[x <- v].
Proof.
  case=> hvars hundef hsem.
  constructor=> //.
  + move=> y ey /=.
    rewrite Mvar.removeP.
    case: eq_op => //.
    by apply hvars.
  move=> y ey vy /=.
  rewrite Mvar.removeP.
  case: eqP => // hneq.
  rewrite get_var_neq //.
  by apply hsem.
Qed.

Lemma valid_state_set_var table rmap se m0 s1 s2 x v :
  valid_state table rmap se m0 s1 s2 ->
  get_local pmap x = None ->
  ¬ Sv.In x (vnew pmap) ->
  valid_state (remove_binding table x) rmap se m0
    (with_vm s1 (evm s1).[x <- v]) (with_vm s2 (evm s2).[x <- v]).
Proof.
  case: s1 s2 => scs1 mem1 vm1 [scs2 mem2 vm2].
  case=>
    /= hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem
    hglobv htop hget hnin.
  constructor => //=.
  + by rewrite Vm.setP_neq //; assert (h:=rip_in_new); apply/eqP => ?; subst x; apply hnin.
  + by rewrite Vm.setP_neq //; assert (h:=rsp_in_new); apply/eqP => ?; subst x; apply hnin.
  + by move=> y hy hnnew; rewrite !Vm.setP heqvm.
  + by apply: wf_table_set_var hwft.
  rewrite /with_vm /=; case: hwfr => hwfsr hwfst hval hptr.
  constructor => //.
  + move=> y sr bytes vy hy; have ? := get_localn_checkg_diff hget hptr hy.
    by rewrite get_gvar_neq //; apply hval.
  move=> y mp hy; have [pk [hgety hpk]]:= hptr y mp hy; exists pk; split => //.
  case: pk hgety hpk => //= yp hyp.
  assert (h := wfr_new (wf_locals hyp)).
  by rewrite Vm.setP_neq //;apply /eqP => /=; clear -h hnin; SvD.fsetdec.
Qed.

Lemma eq_sub_region_val_disjoint_zrange_ovf p sz mem1 mem2 se sr w ty status v :
  (forall al p1 ws1,
      disjoint_zrange_ovf p sz p1 (wsize_size ws1) ->
      read mem2 al p1 ws1 = read mem1 al p1 ws1) ->
  sub_region_addr se sr = ok w ->
  disjoint_zrange_ovf p sz w (size_of ty) ->
  eq_sub_region_val ty se mem1 sr status v ->
  eq_sub_region_val ty se mem2 sr status v.
Proof.
  move=> hreadeq ok_w hd [hread hty]; split=> // off ofs w' ok_ofs hoff hget.
  move: ok_w; rewrite ok_ofs => -[?]; subst w.
  rewrite -(hread _ _ _ ok_ofs hoff hget).
  apply hreadeq => i i' hi.
  rewrite /wsize_size /= => hi'.
  have {} hi' : i' = 0 by lia.
  subst.
  rewrite add_0 -addE.
  apply: hd => //.
  exact: get_val_byte_bound hget.
Qed.

Lemma disjoint_source_word table rmap se m0 s1 s2 :
  valid_state table rmap se m0 s1 s2 ->
  forall s al p ws,
    Sv.In s Slots -> validw s1.(emem) al p ws ->
    disjoint_zrange_ovf p (wsize_size ws) (Addr s) (size_slot s).
Proof.
  move=> hvs s al p ws hin /validwP [] hal hd i i' /hd.
  rewrite (validw8_alignment Aligned) !addE => hi hi'.
  case: (vs_disjoint hin hi).
  rewrite /wsize_size /= => /ZleP hs _ D K.
  move: D.
  have -> : wunsigned (p + wrepr _ i) = wunsigned (Addr s + wrepr _ i') by rewrite K.
  have ? := wunsigned_range (Addr s).
  rewrite wunsigned_add; lia.
Qed.

Lemma eq_sub_region_val_disjoint_zrange p sz mem1 mem2 se sr w ty status v :
  (forall al p1 ws1,
    disjoint_zrange p sz p1 (wsize_size ws1) ->
    read mem2 al p1 ws1 = read mem1 al p1 ws1) ->
  sub_region_addr se sr = ok w ->
  disjoint_zrange p sz w (size_of ty) ->
  eq_sub_region_val ty se mem1 sr status v ->
  eq_sub_region_val ty se mem2 sr status v.
Proof.
  move=> hreadeq ok_w hd [hread hty]; split=> // off ofs w' ok_ofs hoff hget.
  move: ok_w; rewrite ok_ofs => -[?]; subst w.
  rewrite -(hread _ _ _ ok_ofs hoff hget).
  apply hreadeq.
  apply (disjoint_zrange_byte hd).
  rewrite -hty.
  by apply (get_val_byte_bound hget).
Qed.

Lemma wf_region_slot_inj r1 r2 :
  wf_region r1 -> wf_region r2 ->
  r1.(r_slot) = r2.(r_slot) ->
  r1 = r2.
Proof.
  move=> hwf1 hwf2.
  have := hwf1.(wfr_align).
  have := hwf2.(wfr_align).
  have := hwf1.(wfr_writable).
  have := hwf2.(wfr_writable).
  by case: (r1); case: (r2) => /=; congruence.
Qed.

Lemma distinct_regions_disjoint_zrange se sr1 sr2 ty1 ty2 ofs1 ofs2 :
  wf_sub_region se sr1 ty1 ->
  sub_region_addr se sr1 = ok ofs1 ->
  wf_sub_region se sr2 ty2 ->
  sub_region_addr se sr2 = ok ofs2 ->
  sr1.(sr_region) <> sr2.(sr_region) ->
  sr1.(sr_region).(r_writable) ->
  disjoint_zrange ofs1 (size_of ty1) ofs2 (size_of ty2).
Proof.
  move=> hwf1 haddr1 hwf2 haddr2 hneq hw.
  have hb1 := zbetween_sub_region_addr hwf1 haddr1.
  have hb2 := zbetween_sub_region_addr hwf2 haddr2.
  apply (disjoint_zrange_incl hb1 hb2).
  apply (disjoint_writable hwf1.(wfr_slot) hwf2.(wfr_slot));
    last by rewrite hwf1.(wfr_writable).
  by move=> /(wf_region_slot_inj hwf1 hwf2).
Qed.

Lemma eq_sub_region_val_distinct_regions se sr ty ofs sry ty' s2 mem2 status v :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  wf_sub_region se sry ty' ->
  sr.(sr_region) <> sry.(sr_region) ->
  sr.(sr_region).(r_writable) ->
  (forall al p ws,
    disjoint_zrange ofs (size_of ty) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  eq_sub_region_val ty' se (emem s2) sry status v ->
  eq_sub_region_val ty' se mem2 sry status v.
Proof.
  move=> hwf haddr hwfy hneq hw hreadeq.
  have [csy ok_csy wf_csy] := hwfy.(wfsr_zone).
  have [ofsy haddry _] := wunsigned_sub_region_addr hwfy ok_csy.
  apply (eq_sub_region_val_disjoint_zrange hreadeq haddry).
  by apply (distinct_regions_disjoint_zrange hwf haddr hwfy haddry).
Qed.
(*
Lemma disjoint_zones_disjoint_zrange sr1 ty1 sr2 ty2 :
  wf_sub_region se sr1 ty1 ->
  wf_sub_region se sr2 ty2 ->
  sr1.(sr_region) = sr2.(sr_region) ->
  disjoint_zones (sub_zone_at_ofs sr1.(sr_zone) (Some 0) (size_of ty1))
                 (sub_zone_at_ofs sr2.(sr_zone) (Some 0) (size_of ty2)) ->
  disjoint_zrange (sub_region_addr sr1) (size_of ty1) (sub_region_addr sr2) (size_of ty2).
Proof.
  move=> hwf1 hwf2 heq.
  have := addr_no_overflow (wfr_slot hwf1).
  have := addr_no_overflow (wfr_slot hwf2).
  rewrite /disjoint_zones /disjoint_range /disjoint_zrange /no_overflow !zify /=.
  rewrite (wunsigned_sub_region_addr hwf1) (wunsigned_sub_region_addr hwf2).
  have /= := wfz_len hwf1.
  have /= := wfz_len hwf2.
  have := wfz_ofs hwf1.
  have := wfz_ofs hwf2.
  rewrite heq.
  by split; rewrite ?zify; lia.
Qed.
*)

Lemma symbolic_slice_beq_sym s1 s2 :
  symbolic_slice_beq s1 s2 = symbolic_slice_beq s2 s1.
Proof.
  rewrite /symbolic_slice_beq.
  by apply/idP/idP => /andP [h1 h2]; apply /andP; split; apply eq_expr_symm.
Qed.

Lemma disjoint_zones_sym z1 z2 : disjoint_zones z1 z2 = disjoint_zones z2 z1.
Proof.
  elim: z1 z2 => [|s1 z1 ih] [|s2 z2] //=.
  rewrite symbolic_slice_beq_sym ih.
  case: symbolic_slice_beq => //.
  case: symbolic_slice_ble => // b1.
  case: symbolic_slice_ble => // b2.
  by case: b1 b2 => [] [].
Qed.

Instance symbolic_slice_beq_sym' :
  Symmetric symbolic_slice_beq.
Proof.
  move=> ??. rewrite symbolic_slice_beq_sym. done.
Qed.

Lemma symbolic_slice_bleP se s1 cs1 s2 cs2 :
  odflt false (symbolic_slice_ble s1 s2) ->
  sem_slice se s1 = ok cs1 ->
  sem_slice se s2 = ok cs2 ->
  concrete_slice_ble cs1 cs2.
Proof.
  rewrite /symbolic_slice_ble /sem_slice.
  case: is_constP => [ofs1|//].
  case: is_constP => [len1|//].
  case: is_constP => [ofs2|//] /=.
  by t_xrbindP=> ? <- len2 _ _ _ <-.
Qed.

Lemma concrete_slice_ble_trans :
  {in fun cs => 0 <? cs.(cs_len) & &, ssrbool.transitive concrete_slice_ble}.
Proof.
  move=> cs2 cs1 cs3.
  rewrite !zify.
  by lia.
Qed.

(* we could merge all lemmas about add_sub_interval, like what is done
   for get_suffix_Some *)
Lemma wf_interval_add_sub_interval i1 s i2 se cs :
  add_sub_interval i1 s = Some i2 ->
  wf_interval se i1 ->
  sem_slice se s = ok cs ->
  0 < cs.(cs_len) ->
  wf_interval se i2.
Proof.
  rewrite /wf_interval.
  move=> hadd [ci1 [ok_ci1 all_ci1 sorted_ci1]] ok_cs /ZltP len_cs.
  suff: exists ci2, [/\
    mapM (sem_slice se) i2 = ok ci2,
    all (fun cs => 0 <? cs.(cs_len)) ci2,
    path.sorted concrete_slice_ble ci2 &
    (forall cs', concrete_slice_ble cs' cs && all (concrete_slice_ble cs') ci1 -> all (concrete_slice_ble cs') ci2)].
  + move=> [ci2 [ok_ci2 all_ci2 sorted_ci2 _]].
    by exists ci2.
  elim: i1 i2 hadd ci1 ok_ci1 all_ci1 sorted_ci1 => [|s1 i1 ih1] i2 /=.
  + move=> [<-] _ [<-] _ _ /=.
    rewrite ok_cs /=.
    eexists; (split; first by reflexivity) => //=.
    by rewrite len_cs.
  case: symbolic_slice_beq.
  + move=> [<-] /= ci1 -> all_ci1 sorted_ci1.
    eexists; (split; first by reflexivity) => //.
    by move=> cs' /andP[].
  case hle1: (odflt _ _).
  + t_xrbindP=> -[<-] _ cs1 ok_cs1 ci1 ok_ci1 <- all_ci1 sorted_ci1 /=.
    rewrite ok_cs1 ok_ci1 ok_cs /=.
    eexists; (split; first by reflexivity) => //=.
    + by rewrite len_cs.
    apply /andP; split=> //.
    by apply (symbolic_slice_bleP hle1 ok_cs ok_cs1).
  case hle2: (odflt _ _) => //.
  apply: obindP=> {}i2 hadd [<-] /=.
  t_xrbindP=> _ cs1 ok_cs1 ci1 ok_ci1 <- /=/andP [len_cs1 all_ci1] sorted_ci1.
  have [ci2 [ok_ci2 all_ci2 sorted_ci2 hincl]] :=
    ih1 _ hadd _ ok_ci1 all_ci1 (path.path_sorted sorted_ci1).
  rewrite ok_cs1 ok_ci2 /=.
  eexists; (split; first by reflexivity) => /=.
  + by apply /andP; split.
  + rewrite (path.path_pairwise_in concrete_slice_ble_trans) /=.
    + apply /andP; split.
      + apply hincl.
        apply /andP; split.
        + by apply (symbolic_slice_bleP hle2 ok_cs1 ok_cs).
        move: sorted_ci1.
        rewrite (path.path_pairwise_in concrete_slice_ble_trans) /=;
          last by apply /andP.
        by move=> /andP[].
      by rewrite -(path.sorted_pairwise_in concrete_slice_ble_trans).
    by apply /andP; split.
  move=> cs' /and3P [le1_cs1 le2_cs' le3_cs'].
  apply /andP; split=> //.
  apply hincl.
  by apply /andP.
Qed.

Lemma add_sub_interval_1 i1 s i2 se ci2 cs off :
  add_sub_interval i1 s = Some i2 ->
  sem_slice se s = ok cs ->
  mapM (sem_slice se) i2 = ok ci2 ->
  offset_in_concrete_slice cs off ->
  offset_in_concrete_interval ci2 off.
Proof.
  elim: i1 i2 ci2 => [|s1 i1 ih1] i2 ci2 /=.
  + move=> [<-] /= -> /= [<-].
    by rewrite /= orbF.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + move=> [<-] /=.
    rewrite (symbolic_slice_beqP _ heq) => -> /=.
    t_xrbindP=> ci1 _ <- /= hin.
    by apply /orP; left.
  case hle1: (odflt _ _).
  + move=> [<-] /= -> /=.
    t_xrbindP=> _ cs1 _ ci1 _ <- <- hin /=.
    by apply /orP; left.
  case hle2: (odflt _ _) => //.
  apply: obindP => i2' hadd [<-] ok_cs /=.
  t_xrbindP=> cs1 ok_cs1 ci2' ok_ci2' <- hin /=.
  have {}hin := ih1 _ _ hadd ok_cs ok_ci2' hin.
  by apply /orP; right.
Qed.

Lemma add_sub_interval_2 i1 s i2 se ci1 ci2 off :
  add_sub_interval i1 s = Some i2 ->
  mapM (sem_slice se) i1 = ok ci1 ->
  mapM (sem_slice se) i2 = ok ci2 ->
  offset_in_concrete_interval ci1 off ->
  offset_in_concrete_interval ci2 off.
Proof.
  elim: i1 i2 ci1 ci2 => [|s1 i1 ih1] i2 ci1 ci2 /=.
  + by move=> [<-] [<-] /=.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + by move=> [<-] /= -> [<-].
  case hle1: (odflt _ _).
  + move=> [<-] /=.
    t_xrbindP=> cs1 -> {}ci1 -> <- cs ok_cs ? _ [<-] _ [<-] <- <- hin /=.
    by apply /orP; right.
  case hle2: (odflt _ _) => //.
  apply: obindP => i2' hadd [<-] /=.
  t_xrbindP=> cs1 -> {}ci1 ok_ci1 <- _ [<-] ci2' ok_ci2' <- /= /orP hin.
  apply /orP.
  case: hin => hin.
  + by left.
  right.
  by apply (ih1 _ _ _ hadd ok_ci1 ok_ci2' hin).
Qed.

Lemma wf_status_clear_status se status z cs :
  wf_status se status ->
  sem_zone se z = ok cs ->
  0 < cs.(cs_len) ->
  wf_status se (odflt Unknown (clear_status status z)).
Proof.
  move=> hwfs ok_cs len_cs.
  case: z ok_cs => [//|s z] ok_cs /=.
  have [cs' ok_cs' hb] := sem_zone_cons_incl ok_cs.
  have len_cs': 0 < cs'.(cs_len).
  + move: hb; rewrite !zify.
    by lia.
  case: status hwfs => //=.
  + move=> _.
    rewrite /wf_interval /= ok_cs' /=.
    eexists; (split; first by reflexivity) => //=.
    by rewrite !zify.
  move=> i i_wf.
  case hadd: add_sub_interval => [i2|//] /=.
  by apply (wf_interval_add_sub_interval hadd i_wf ok_cs' len_cs').
Qed.

Lemma valid_offset_clear_status se status z cs off :
  wf_status se status ->
  sem_zone se z = ok cs ->
  0 < cs.(cs_len) ->
  valid_offset se (odflt Unknown (clear_status status z)) off ->
  valid_offset se status off /\ ~ offset_in_concrete_slice cs off.
Proof.
  case: z => [//|s z] /=.
  case: status => //=.
  + move=> _ ok_cs len_cs hvalid.
    split=> // off_valid.
    move: hvalid; rewrite /valid_offset_interval /=.
    have [cs' -> hincl] := sem_zone_cons_incl ok_cs.
    move=> /(_ _ erefl) /=; apply.
    rewrite orbF.
    by apply (zbetween_concrete_sliceP hincl).
  move=> i i_wf ok_cs wf_cs.
  case hadd: add_sub_interval => [i'|//] /= off_valid.
  have [cs' ok_cs' hb] := sem_zone_cons_incl ok_cs.
  have len_cs': 0 < cs'.(cs_len).
  + move: hb; rewrite !zify.
    by lia.
  have [ci' [ok_ci' _ _]] := wf_interval_add_sub_interval hadd i_wf ok_cs' len_cs'.
  split.
  + have [ci [ok_ci _ _]] := i_wf.
    rewrite /valid_offset_interval ok_ci => _ [<-].
    move=> /(add_sub_interval_2 hadd ok_ci ok_ci').
    by apply off_valid.
  move=> hin.
  have :=
    add_sub_interval_1 hadd ok_cs' ok_ci' (zbetween_concrete_sliceP hb hin).
  by apply off_valid.
Qed.

Definition disjoint_symbolic_slice se s1 s2 :=
  forall cs1 cs2,
  sem_slice se s1 = ok cs1 ->
  sem_slice se s2 = ok cs2 ->
  disjoint_concrete_slice cs1 cs2.

Definition disjoint_symbolic_zone se z1 z2 :=
  forall cs1 cs2,
  sem_zone se z1 = ok cs1 ->
  sem_zone se z2 = ok cs2 ->
  disjoint_concrete_slice cs1 cs2.

Lemma disjoint_symbolic_slice_sym se s1 s2 :
  disjoint_symbolic_slice se s1 s2 ->
  disjoint_symbolic_slice se s2 s1.
Proof.
  move=> hdisj cs1 cs2 ok_cs1 ok_cs2.
  rewrite disjoint_concrete_slice_sym.
  by apply hdisj.
Qed.

(* FIXME: clean *)
Lemma disjoint_symbolic_zone_cons se s z1 z2 :
  z1 <> [::] -> z2 <> [::] ->
  disjoint_symbolic_zone se z1 z2 ->
  disjoint_symbolic_zone se (s::z1) (s::z2).
Proof.
  case: z1 => // s1 z1 _.
  case: z2 => // s2 z2 _.
  move=> hdisj cs1 cs2 /=.
  t_xrbindP=> cs -> /= cs1' ok_cs1' cs1'' ok_cs1'' ok_cs1 _ [<-] cs2' ok_cs2' cs2'' ok_cs2'' ok_cs2.
  
  move: hdisj; rewrite /disjoint_symbolic_zone.
  simpl. rewrite ok_cs1' ok_cs2' /=.
  have [cs5 h51 h52] := sem_zone_aux_sub_concrete_slice ok_cs1 ok_cs1''.
  have [cs6 h61 h62] := sem_zone_aux_sub_concrete_slice ok_cs2 ok_cs2''.
  move=> /(_ _ _ h51 h61).
  apply (sub_concrete_slice_disjoint h52 h62).
  (*
  apply disjoint_concrete_slice_incl.
  have :=  (sub_concrete_slice_incl h52). cs5
  have := sem_zone'_auxP_simpl2 ok_cs1 ok_cs1''.
  move=> [cs5 ok_cs51 ok_cs52].
  have := sem_zone'_auxP_simpl2 ok_cs2 ok_cs2''.
  move=> [cs6 ok_cs61 ok_cs62].
  move=> /(_ _ _ ok_cs51 ok_cs61).
  move: ok_cs52 ok_cs62. *)
Qed.

(* under-specification *)
(* TODO: remove disjoint_symbolic_slice and reason on concrete_slice only *)
Lemma symbolic_slice_ble_disjoint se s1 s2 :
  odflt false (symbolic_slice_ble s1 s2) ->
  disjoint_symbolic_slice se s1 s2.
Proof.
  move=> + cs1 cs2.
  rewrite /symbolic_slice_ble /sem_slice.
  case: is_constP => //= ofs1.
  case: is_constP => //= len1.
  case: is_constP => //= ofs2.
  move=> hle [<-].
  t_xrbindP=> len2 vlen2 ok_vlen2 ok_len2 <-.
  by rewrite /disjoint_concrete_slice /= hle.
Qed.

(* FIXME: clean *)
Lemma disjoint_symbolic_slice_zone se s1 s2 z1 z2 :
  disjoint_symbolic_slice se s1 s2 ->
  disjoint_symbolic_zone se (s1 :: z1) (s2 :: z2).
Proof.
  move=> hdisj cs1 cs2.
  move=> /sem_zone_cons_incl [cs1' h11 h12].
  move=> /sem_zone_cons_incl [cs2' h21 h22].
  have := hdisj _ _ h11 h21.
  apply disjoint_concrete_slice_incl.
  done. done. (*
  
  
   /=.
  case: z1 => [|s1' z1].
  + case: z2 => [|s2' z2].
    + rewrite /= !LetK => ok_cs1 ok_cs2.
      by apply hdisj.
    rewrite /= LetK /sub_concrete_slice.
    t_xrbindP=> ok_cs1 cs2' ok_cs2' cs2'' ok_cs2'' cs2''' ok_cs2''' ok_cs2.
    case: ifP ok_cs2''' ok_cs2 => // + [<-].
    have := hdisj _ _ ok_cs1 ok_cs2'.
    rewrite /disjoint_concrete_slice /= !zify.
    by lia.
  case: z2 => [|s2' z2].
  + rewrite /= /sub_concrete_slice.
    t_xrbindP=> cs1' ok_cs1' cs1'' ok_cs1'' ok_cs1 ok_cs2.
    case: ifP ok_cs1 => // + [<-].
    have := hdisj _ _ ok_cs1' ok_cs2.
    rewrite /disjoint_concrete_slice /= !zify.
    by lia.
  rewrite /= /sub_concrete_slice.
  t_xrbindP=> cs1' ok_cs1' cs1'' ok_cs1'' ok_cs1 cs2' ok_cs2' cs2'' ok_cs2'' ok_cs2.
  case: ifP ok_cs1 => // + [<-].
  case: ifP ok_cs2 => // + [<-].
  have := hdisj _ _ ok_cs1' ok_cs2'.
  rewrite /disjoint_concrete_slice /= !zify.
  by lia. *)
Qed.

(* La fonction [disjoint_zones] n'a pas de cas particulier pour les constantes ?
   pourrait-on réécrire en fonction de get_suffix ? *)
Lemma get_suffix_Some_None se z1 z2 :
  get_suffix z1 z2 = Some None ->
  disjoint_symbolic_zone se z1 z2.
Proof.
  elim: z1 z2 => [//|s1 z1 ih1] [//|s2 z2] /=.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + move=> hsuffix.
    suff: disjoint_symbolic_zone se (s1 :: z1) (s1 :: z2).
    + move=> hdisj cs1 cs2.
      rewrite /sem_zone -(symbolic_slice_beqP _ heq) -!/(sem_zone _ (_::_)).
      by move: cs1 cs2.
    apply disjoint_symbolic_zone_cons.
    + by case: (z1) hsuffix.
    + by case: (z1) (z2) hsuffix => [//|??] [].
    by apply ih1.
  move=> hsuffix; apply disjoint_symbolic_slice_zone; move: hsuffix.
  case hle1: (odflt _ _).
  + move=> _.
    by apply symbolic_slice_ble_disjoint.
  case hle2: (odflt _ _).
  + move=> _.
    apply disjoint_symbolic_slice_sym.
    by apply symbolic_slice_ble_disjoint.
  case: z1 {ih1} => //.
  case: is_const => // ?.
  case: is_const => // ?.
  case: is_const => // ?.
  case: is_const => // ?.
  by case: ifP.
Qed.

Lemma sub_concrete_slice_offset cs1 cs2 cs :
  sub_concrete_slice cs1 cs2 = ok cs ->
  forall off,
    offset_in_concrete_slice cs off =
    offset_in_concrete_slice cs2 (off - cs1.(cs_ofs)).
Proof.
  rewrite /sub_concrete_slice.
  case: ifP => // _ [<-].
  move=> off.
  rewrite /offset_in_concrete_slice /=.
  by apply /idP/idP; rewrite !zify; lia.
Qed.

(*
(0,3) :: (a, 3) :: (0,2) :: (i,1) :: (j,1)
(0,3) :: (a, 3) :: (1,2)
->
(0,3) :: (a, 3) :: (1, 1)
*)

(* FIXME: clean *)
Lemma get_suffix_Some_Some se z1 z2 z cs1 cs2 :
  z <> [::] ->
  get_suffix z1 z2 = Some (Some z) ->
  sem_zone se z1 = ok cs1 ->
  sem_zone se z2 = ok cs2 ->
  exists2 cs,
    sem_zone se z = ok cs &
      forall off,
        offset_in_concrete_slice cs1 off ->
        offset_in_concrete_slice cs2 off ->
        offset_in_concrete_slice cs (off - cs1.(cs_ofs)).
Proof.
  move=> z_nnil.
  elim: z1 z2 cs1 cs2 => [//|s1 z1 ih1] [//|s2 z2] cs1 cs2 //=.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + rewrite (symbolic_slice_beqP _ heq).
    t_xrbindP=> hsuffix cs1' -> /= ok_cs1 _ [<-] ok_cs2.
    have: z1 = [::] \/ z1 <> [::].
    + (* TODO : prove aux lemma *)
      by case: (z1); [left|right].
    case=> [?|z1_nnil].
    + subst z1.
      move: hsuffix ok_cs1 => /= [?] [?]; subst z2 cs1'.
      have [cs ok_cs {}ok_cs2] := sem_zone_aux_sem_zone z_nnil ok_cs2.
      exists cs => //.
      move=> off hoff1 hoff2.
      rewrite -(sub_concrete_slice_offset ok_cs2). done.
    have: z2 = [::] \/ z2 <> [::].
    + by case: (z2); [left|right].
    case=> [?|z2_nnil].
    + subst z2.
      by case: (z1) z1_nnil hsuffix.
    have [cs1'' ok_cs1'' {}ok_cs1] := sem_zone_aux_sem_zone z1_nnil ok_cs1.
    have [cs2'' ok_cs2'' {}ok_cs2] := sem_zone_aux_sem_zone z2_nnil ok_cs2.
    have := ih1 _ _ _ hsuffix ok_cs1'' ok_cs2''.
    move=> [cs ok_cs hoff].
    exists cs => //.
    move=> off.
    rewrite (sub_concrete_slice_offset ok_cs1) (sub_concrete_slice_offset ok_cs2).
    move=> /hoff /[apply].
    move: ok_cs1; rewrite /sub_concrete_slice /=.
    case: ifP => // _ [<-] /=.
    rewrite Z.sub_add_distr. done.
(*
    + subst z2=> //.
    
      simpl in hsuffix.
    
    
  have := sem_zone_aux_sem_zone ok_cs1.
  have := ih1 _ _ _ hsuffix.
  
  + case: z1 ih1 => [|s1' z1] ih1 /=.
    + move=> [?]; subst z.
      rewrite (symbolic_slice_beqP _ heq). => -> /=.
      t_xrbindP=> cs2' ok_cs2' ok_cs2.
      exists cs2' => //.
      by move=> off; rewrite (sub_concrete_slice_offset off ok_cs2).
    rewrite -/(get_suffix (s1'::z1) z2).
    case: z2 => [//|s2' z2] hsuffix /=.
    t_xrbindP=>
      cs1' ok_cs1' cs1'' ok_cs1'' ok_cs1 cs2' ok_cs2' cs2'' ok_cs2'' ok_cs2.
    have [cs ok_cs hinter] := ih1 _ _ _ hsuffix ok_cs1'' ok_cs2''.
    exists cs => //.
    move: ok_cs1';
      rewrite (symbolic_slice_beqP _ heq) ok_cs2' => -[?]; subst cs2'.
    move=> off.
    rewrite (sub_concrete_slice_offset _ ok_cs1).
    rewrite (sub_concrete_slice_offset _ ok_cs2).
    move=> /hinter{}hinter /hinter{}hinter.
    move: ok_cs1.
    rewrite /sub_concrete_slice; case: ifP => // _ [<-] /=.
    by rewrite Z.sub_add_distr.
    *)
  case hle1: (odflt _ _) => //.
  case hle2: (odflt _ _) => //.
  case: z1 {ih1} => //.
  move=> hsuffix ok_cs1 ok_cs2.
  have [cs2' ok_cs2' hincl2] := sem_zone_cons_incl ok_cs2.
  move: hsuffix ok_cs1 ok_cs2'.
  rewrite /= /sem_slice.
  case: is_constP => //= ofs1.
  case: is_constP => //= len1.
  case: is_constP => //= ofs2.
  case: is_constP => //= len2.
  case: ifP => hif.
  + by move=> [?]; subst z.
  move=> [<-] [?] [?]; subst.
  eexists; first by reflexivity.
  move=> off + /(zbetween_concrete_sliceP hincl2).
  rewrite /offset_in_concrete_slice /= !zify.
  by lia.
Qed.

Lemma get_suffix_Some_Some_wf se z1 z2 z cs1 cs2 cs :
  get_suffix z1 z2 = Some (Some z) ->
  sem_zone se z1 = ok cs1 ->
  sem_zone se z2 = ok cs2 ->
  sem_zone se z = ok cs ->
  0 < cs1.(cs_len) ->
  0 < cs2.(cs_len) ->
  0 < cs.(cs_len).
Proof.
  elim: z1 z2 cs1 cs2 => [//|s1 z1 ih1] [//|s2 z2] cs1 cs2 //=.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + rewrite (symbolic_slice_beqP _ heq).
    t_xrbindP=> hsuffix cs1' -> /= ok_cs1 _ [<-] ok_cs2 ok_cs len_cs1 len_cs2.
    have z_nnil: z <> [::].
    + by case: (z) ok_cs.
    have: z1 = [::] \/ z1 <> [::].
    + (* TODO : prove aux lemma *)
      by case: (z1); [left|right].
    case=> [?|z1_nnil].
    + subst z1.
      move: hsuffix ok_cs1 => /= [?] [?]; subst z2 cs1'.
      have := sem_zone_aux_sem_zone z_nnil ok_cs2.
      rewrite ok_cs => -[] _ [<-].
      rewrite /sub_concrete_slice.
      by case: ifP => // _ [?]; subst cs2.
    have: z2 = [::] \/ z2 <> [::].
    + by case: (z2); [left|right].
    case=> [?|z2_nnil].
    + subst z2.
      by case: (z1) z1_nnil hsuffix.
    have [cs1'' ok_cs1'' {}ok_cs1] := sem_zone_aux_sem_zone z1_nnil ok_cs1.
    have [cs2'' ok_cs2'' {}ok_cs2] := sem_zone_aux_sem_zone z2_nnil ok_cs2.
    apply: (ih1 _ _ _ hsuffix ok_cs1'' ok_cs2'' ok_cs).
    + move: ok_cs1.
      by rewrite /sub_concrete_slice; case: ifP => // _ [?]; subst.
    move: ok_cs2.
    by rewrite /sub_concrete_slice; case: ifP => // _ [?]; subst.
  case hle1: (odflt _ _) => //.
  case hle2: (odflt _ _) => //.
  case: z1 {ih1} => //=.
  move=> hsuffix ok_cs1 ok_cs2.
  have [cs2' ok_cs2' hincl2] := sem_zone_cons_incl ok_cs2.
  move: hsuffix ok_cs1 ok_cs2' hle1 hle2.
  rewrite /sem_slice /symbolic_slice_ble. (* symbolic_slice_ble is complete on constants *)
  case: is_constP => //= ofs1.
  case: is_constP => //= len1.
  case: is_constP => //= ofs2.
  case: is_constP => //= len2.
  case: ifP => hif.
  + by move=> [?]; subst z.
  move=> [<-] [?] [?]; subst.
  move=> /ZleP hle1 /ZleP hle2 /= [<-] /=.
  move: hincl2; rewrite /zbetween_concrete_slice /= !zify.
  by lia.
Qed.

Lemma wf_status_clear_status_map_aux se status z ty sl rmap x :
  wfr_WF rmap se ->
  wf_status se status ->
  wf_zone se z ty sl ->
  wf_status se (odflt Unknown (clear_status_map_aux rmap z x status)).
Proof.
  move=> hwfsr hwfs hwfz.
  rewrite /clear_status_map_aux.
  case heq: (let%opt _ := _ in get_suffix _ _) => [oz|//].
  case: oz heq => [z1|//].
  apply: obindP=> sr hsr hsuffix.
  have hwf := hwfsr _ _ hsr.
  have [cs ok_cs wf_cs] := hwf.(wfsr_zone).
  have [cs' ok_cs' wf_cs'] := hwfz.
  have: z1 = [::] \/ z1 <> [::].
  + by case: (z1); [left|right].
  case.
  + by move=> ->.
  move=> z1_nnil.
  have [cs1 ok_cs1 _] := get_suffix_Some_Some z1_nnil hsuffix ok_cs ok_cs'.
  have len_cs := wf_concrete_slice_len_gt0 wf_cs.
  have len_cs' := wf_concrete_slice_len_gt0 wf_cs'.
  have len_cs1 :=
    get_suffix_Some_Some_wf hsuffix ok_cs ok_cs' ok_cs1 len_cs len_cs'.
  by apply (wf_status_clear_status hwfs ok_cs1 len_cs1).
Qed.

Lemma valid_offset_clear_status_map_aux se status rmap x sr z cs cs' off :
  wf_status se status ->
  Mvar.get rmap.(var_region) x = Some sr ->
  sem_zone se sr.(sr_zone) = ok cs ->
  sem_zone se z = ok cs' ->
  0 < cs'.(cs_len) ->
  0 <= off < cs.(cs_len) ->
  valid_offset se (odflt Unknown (clear_status_map_aux rmap z x status)) off ->
  valid_offset se status off /\
  ~ offset_in_concrete_slice cs' (cs.(cs_ofs) + off).
Proof.
  move=> hwfs hget ok_cs ok_cs' len_cs' hoff.
  rewrite /clear_status_map_aux hget.
  case hsuffix: get_suffix => [z1|//].
  case: z1 hsuffix => [z1|] hsuffix /= hvalid; last first.
  + (* sr.(sr_zone) and z disjoint *)
    split=> //.
    have off_in: offset_in_concrete_slice cs (cs.(cs_ofs) + off).
    + by rewrite /offset_in_concrete_slice !zify; lia.
    move=> off_in'.
    have hdisj := get_suffix_Some_None hsuffix ok_cs ok_cs'.
    by apply (disjoint_concrete_sliceP hdisj off_in off_in').
  (* sr.(sr_zone) and z intersect *)
  have: z1 = [::] \/ z1 <> [::].
  + by case: (z1); [left|right].
  case.
  + by move=> ?; subst z1.
  move=> z1_nnil.
  have [cs1 ok_cs1 off_inter] :=
    get_suffix_Some_Some z1_nnil hsuffix ok_cs ok_cs'.
  have len_cs: 0 < cs.(cs_len) by lia.
  have len_cs1 :=
    get_suffix_Some_Some_wf hsuffix ok_cs ok_cs' ok_cs1 len_cs len_cs'.
  have [{}hvalid off_nin] :=
    valid_offset_clear_status hwfs ok_cs1 len_cs1 hvalid.
  split=> //.
  have off_in: offset_in_concrete_slice cs (cs.(cs_ofs) + off).
  + by rewrite /offset_in_concrete_slice !zify; lia.
  move=> off_in'.
  have := off_inter _ off_in off_in'.
  by rewrite Z.add_simpl_l.
Qed.

Lemma eq_sub_region_val_same_region se sr ty ofs sry ty' s2 mem2 rmap y statusy v :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  Mvar.get rmap.(var_region) y = Some sry ->
  wf_sub_region se sry ty' ->
  sr.(sr_region) = sry.(sr_region) ->
  (forall al p ws,
    disjoint_zrange ofs (size_of ty) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  wf_status se statusy ->
  eq_sub_region_val ty' se (emem s2) sry statusy v ->
  eq_sub_region_val ty' se mem2 sry (odflt Unknown (clear_status_map_aux rmap sr.(sr_zone) y statusy)) v.
Proof.
  move=> hwf haddr hsry hwfy hr hreadeq hwfsy [hread hty'].
  split=> // off ofsy w haddry hvalid /[dup] /get_val_byte_bound; rewrite hty' => hoff hget.
  have [cs ok_cs wf_cs] := hwf.(wfsr_zone).
  have := wunsigned_sub_region_addr hwf ok_cs.
  rewrite haddr => -[_ [<-] ok_ofs].
  have [csy ok_csy wf_csy] := hwfy.(wfsr_zone).
  have := wunsigned_sub_region_addr hwfy ok_csy.
  rewrite haddry => -[_ [<-] ok_ofsy].
  have hoff': 0 <= off < csy.(cs_len).
  + have := wf_csy.(wfcs_len).
    by lia.
  have len_cs := wf_concrete_slice_len_gt0 wf_cs.
  have [{}hvalid off_nin] :=
    valid_offset_clear_status_map_aux hwfsy hsry ok_csy ok_cs len_cs hoff' hvalid.
  rewrite -(hread _ _ _ haddry hvalid hget).
  apply hreadeq.
  apply not_between_U8_disjoint_zrange.
  + by apply (no_overflow_sub_region_addr hwf haddr).
  rewrite /between /zbetween wsize8 !zify.
  rewrite wunsigned_add; last first.
  + have := no_overflow_sub_region_addr hwfy haddry.
    rewrite /no_overflow zify.
    have := wunsigned_range ofsy.
    by lia.
  rewrite ok_ofs ok_ofsy -hr => hb.
  apply off_nin.
  rewrite /offset_in_concrete_slice !zify.
  have := wf_cs.(wfcs_len).
  by lia.
Qed.

Lemma symbolic_slice_beq_refl : Reflexive symbolic_slice_beq.
Proof.
  move=> s.
  by rewrite /symbolic_slice_beq !eq_expr_refl.
Qed.

Lemma symbolic_zone_beq_refl : Reflexive symbolic_zone_beq.
Proof.
  move=> z.
  elim: z => [//|s z ih].
  rewrite /symbolic_zone_beq /=.
  apply /andP; split=> //.
  by apply symbolic_slice_beq_refl.
Qed.

Lemma sub_region_beq_refl : Reflexive sub_region_beq.
Proof.
  move=> sr.
  rewrite /sub_region_beq.
  apply /andP; split=> //.
  by apply symbolic_zone_beq_refl.
Qed.

Lemma symbolic_zone_beq_sym : Symmetric symbolic_zone_beq.
Proof.
  move=> z1 z2.
  elim: z1 z2 => [|s1 z1 ih] [|s2 z2] //=.
  rewrite /symbolic_zone_beq /= => /andP [/symbolic_slice_beq_sym' ? /ih ?].
  by apply /andP; split.
Qed.

Lemma sub_region_beq_sym : Symmetric sub_region_beq.
Proof.
  move=> sr1 sr2.
  rewrite /sub_region_beq.
  move=> /andP [/eqP -> /symbolic_zone_beq_sym ?].
  by apply /andP; split.
Qed.

Lemma symbolic_slice_beq_trans : Transitive symbolic_slice_beq.
Proof.
  move=> s1 s2 s3.
  rewrite /symbolic_slice_beq => /andP [eq12 eq12'] /andP [eq23 eq23'].
  apply /andP; split.
  + by apply (eq_expr_trans eq12 eq23).
  by apply (eq_expr_trans eq12' eq23').
Qed.

Lemma symbolic_zone_beq_trans : Transitive symbolic_zone_beq.
Proof.
  move=> z1 z2 z3.
  elim: z1 z2 z3 => [|s1 z1 ih] [|s2 z2] [|s3 z3] //=.
  rewrite /symbolic_zone_beq /=.
  move=> /andP [eq12 eq12'] /andP [eq23 eq23'].
  apply /andP; split.
  + by apply (symbolic_slice_beq_trans eq12 eq23).
  by apply (ih _ _ eq12' eq23').
Qed.

Lemma sub_region_beq_trans : Transitive sub_region_beq.
Proof.
  move=> sr1 sr2 sr3.
  rewrite /sub_region_beq.
  move=> /andP [/eqP -> eq12] /andP [/eqP -> eq23].
  apply /andP; split=> //.
  by apply (symbolic_zone_beq_trans eq12 eq23).
Qed.

#[local]
Instance sub_region_beq_equiv : Equivalence sub_region_beq.
Proof.
  split.
  + exact: sub_region_beq_refl.
  + exact: sub_region_beq_sym.
  exact: sub_region_beq_trans.
Qed.

(* TODO: sub_region_pk not used anymore, remove *)
Lemma sub_region_pk_valid se rmap x s sr pk :
  sub_region_pk x pk = ok sr -> valid_pk se rmap s sr pk.
Proof.
  case: pk => // v ofs ws z [|//] [<-] /=.
  by apply sub_region_beq_refl.
Qed.

(* TODO: idem *)
Lemma sub_region_pk_wf se (x:var_i) pk sr :
  sub_region_pk x pk = ok sr ->
  wf_local x pk ->
  wf_sub_region se sr x.(vtype).
Proof.
  case: pk => // v ofs ws cs [|//] [<-] /= [*].
  split=> //=.
  by eexists; first by reflexivity.
Qed.

Lemma is_align_sub_region_stkptr se x s ofs ws cs f w :
  wf_stkptr x s ofs ws cs f ->
  sub_region_addr se (sub_region_stkptr s ws cs) = ok w ->
  is_align w Uptr.
Proof.
  move=> hlocal.
  rewrite /sub_region_addr /= => -[<-].
  (* TODO: could wfs_offset_align be is_align z.(z_ofs) Uptr ?
     does it make sense ?
  *)
  apply: is_align_add hlocal.(wfs_offset_align).
  apply (is_align_m hlocal.(wfs_align_ptr)).
  rewrite -hlocal.(wfs_align).
  by apply (slot_align (sub_region_stkptr_wf se hlocal).(wfr_slot)).
Qed.

(*
Lemma set_bytesP rmap x sr ofs len rv :
  set_bytes rmap x sr ofs len = ok rv ->
  sr.(sr_region).(r_writable) /\ rv = set_pure_bytes rmap x sr ofs len.
Proof. by rewrite /set_bytes /writable; t_xrbindP. Qed.

Lemma set_sub_regionP rmap x sr ofs len rmap2 :
  set_sub_region rmap x sr ofs len = ok rmap2 ->
  sr.(sr_region).(r_writable) /\
  rmap2 = {| var_region := Mvar.set (var_region rmap) x sr;
             region_var := set_pure_bytes rmap x sr ofs len |}.
Proof. by rewrite /set_sub_region; t_xrbindP=> _ /set_bytesP [? ->] <-. Qed.
*)

Lemma check_writableP x r tt :
  check_writable x r = ok tt ->
  r.(r_writable).
Proof. by rewrite /check_writable; t_xrbindP. Qed.

Lemma set_wordP se sr (x:var_i) ofs rmap al status ws rmap2 :
  wf_sub_region se sr x.(vtype) ->
  sub_region_addr se sr = ok ofs ->
  set_word rmap al sr x status ws = ok rmap2 ->
  [/\ sr.(sr_region).(r_writable),
      is_aligned_if al ofs ws &
      rmap2 = set_word_pure rmap sr x status].
Proof.
  move=> hwf ok_ofs; rewrite /set_word.
  by t_xrbindP=> /check_writableP hw /(check_alignP hwf ok_ofs) hal <-.
Qed.

Lemma get_status_map_setP rv r r' sm :
  get_status_map (Mr.set rv r' sm) r = if r' == r then sm else get_status_map rv r.
Proof. by rewrite /get_status_map Mr.setP; case: eqP. Qed.

Lemma is_unknownP status : is_unknown status -> status = Unknown.
Proof. by case: status. Qed.

Lemma get_status_setP sm x x' status :
  get_status (set_status sm x' status) x = if x' == x then status else get_status sm x.
Proof.
  rewrite /get_status /set_status.
  case h: is_unknown.
  + have -> := is_unknownP h.
    by rewrite Mvar.removeP; case: eq_op.
  by rewrite Mvar.setP; case: eq_op.
Qed.

Lemma clear_status_map_aux_unknown rmap z x :
  odflt Unknown (clear_status_map_aux rmap z x Unknown) = Unknown.
Proof.
  rewrite /clear_status_map_aux.
  by case: (let%opt _ := _ in get_suffix _ _) => // -[] // [] //.
Qed.

Lemma clear_status_map_aux_not_unknown rmap z x status :
  odflt Unknown (clear_status_map_aux rmap z x status) <> Unknown ->
  exists sr, Mvar.get rmap.(var_region) x = Some sr.
Proof.
  rewrite /clear_status_map_aux.
  case: Mvar.get => [sr|//] _.
  by exists sr.
Qed.

Lemma get_status_clear x rmap z sm :
  get_status (clear_status_map rmap z sm) x =
  odflt Unknown (clear_status_map_aux rmap z x (get_status sm x)).
Proof.
  rewrite /clear_status_map /get_status.
  rewrite Mvar.filter_mapP.
  by case: Mvar.get => //; rewrite clear_status_map_aux_unknown.
Qed.

Lemma get_var_status_set_word_status rmap sr x status r y :
  get_var_status (set_word_status rmap sr x status) r y =
    let statusy := get_var_status rmap r y in
    if sr.(sr_region) != r then
      statusy
    else
      if x == y then status
      else
        odflt Unknown (clear_status_map_aux rmap sr.(sr_zone) y statusy).
Proof.
  rewrite /set_word_status /get_var_status.
  rewrite get_status_map_setP.
  case: eqP => [->|//] /=.
  rewrite get_status_setP.
  by case: eq_op => //; rewrite get_status_clear.
Qed.

Lemma check_gvalid_set_word se sr (x:var_i) rmap al status ws rmap2 y sry statusy :
  Mvar.get rmap.(var_region) x = Some sr ->
  wf_sub_region se sr x.(vtype) ->
  set_word rmap al sr x status ws = ok rmap2 ->
  check_gvalid rmap2 y = Some (sry, statusy) ->
    [/\ ~ is_glob y, x = gv y :> var, sry = sr & statusy = status]
  \/
    [/\ ~ is_glob y, x <> gv y :> var, sr.(sr_region) = sry.(sr_region),
        Mvar.get rmap.(var_region) y.(gv) = Some sry &
        let statusy' := get_var_status rmap sry.(sr_region) y.(gv) in
        statusy = odflt Unknown (clear_status_map_aux rmap sr.(sr_zone) y.(gv) statusy')]
  \/
    [/\ ~ is_glob y -> x <> gv y :> var, sr.(sr_region) <> sry.(sr_region) &
        check_gvalid rmap y = Some (sry, statusy)].
Proof.
  move=> hsr hwf hset.
  have [cs ok_cs _] := hwf.(wfsr_zone).
  have [ofs haddr _] := wunsigned_sub_region_addr hwf ok_cs.
  have [hw _ ->] := set_wordP hwf haddr hset.
  rewrite /check_gvalid /=.
  case: (@idP (is_glob y)) => hg.
  + case heq: Mvar.get => [[ofs' ws']|//] [<- <-] /=.
    right; right; split => //.
    move=> heqr.
    by move: hw; rewrite heqr.
  case hsry: Mvar.get => [sr'|//] [? <-]; subst sr'.
  rewrite get_var_status_set_word_status.
  case: (x =P gv y :> var).
  + move=> eq_xy.
    move: hsry; rewrite -eq_xy hsr => -[<-].
    rewrite eqxx.
    by left; split.
  move=> neq_xy.
  case: eqP => heqr.
  + by right; left; split.
  by right; right; split.
Qed.

(* This lemma is used for [set_sub_region] and [set_stack_ptr]. *)
Lemma mem_unchanged_write_slot se m0 s1 s2 sr ty ofs mem2 :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  sr.(sr_region).(r_writable) ->
  (forall al p ws,
    disjoint_zrange ofs (size_of ty) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  mem_unchanged (emem s1) m0 (emem s2) ->
  mem_unchanged (emem s1) m0 mem2.
Proof.
  move=> hwf haddr hwritable hreadeq hunch p hvalid1 hvalid2 hdisj.
  rewrite (hunch _ hvalid1 hvalid2 hdisj).
  symmetry; apply hreadeq.
  apply (disjoint_zrange_incl_l (zbetween_sub_region_addr hwf haddr)).
  apply (hdisj _ hwf.(wfr_slot)).
  by rewrite hwf.(wfr_writable).
Qed.

(* TODO: should we use this def instead? *)
Definition wfr_STATUS' (rmap : region_map) se :=
  forall r x,
    wf_status se (get_var_status rmap r x).

Lemma wfr_STATUS_alt rmap se :
  wfr_STATUS rmap se <-> wfr_STATUS' rmap se.
Proof.
  split.
  + move=> hwfst r x.
    by apply get_var_status_wf_status.
  move=> hwfst r sm x status hsm hstatus.
  move: (hwfst r x).
  rewrite /get_var_status /get_status_map hsm /=.
  by rewrite /get_status hstatus /=.
Qed.

(* This lemma is used both for [set_word] and [set_stack_ptr]. *)
Lemma wfr_STATUS_set_word_pure rmap se sr x status ty :
  wfr_WF rmap se ->
  wf_sub_region se sr ty ->
  wf_status se status ->
  wfr_STATUS rmap se ->
  wfr_STATUS (set_word_pure rmap sr x status) se.
Proof.
  move=> hwfsr hwf hwfs hwfst.
  move /wfr_STATUS_alt in hwfst; apply wfr_STATUS_alt.
  move=> r y /=.
  rewrite get_var_status_set_word_status.
  case: eq_op => //=.
  case: eq_op => //.
  by apply: wf_status_clear_status_map_aux hwf.(wfsr_zone).
Qed.

(* TODO: move? *)
Lemma mk_lvar_nglob x : ~ is_glob x -> mk_lvar x.(gv) = x.
Proof. by case: x => [? []]. Qed.

(* This lemma is used only for [set_word]. *)
Lemma wfr_VAL_set_word rmap se s1 s2 sr (x:var_i) ofs mem2 al status ws (rmap2 : region_map) v :
  wf_rmap rmap se s1 s2 ->
  Mvar.get rmap.(var_region) x = Some sr ->
  sub_region_addr se sr = ok ofs ->
  (forall al p ws,
    disjoint_zrange ofs (size_slot x) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  set_word rmap al sr x status ws = ok rmap2 ->
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se mem2 sr status (vm_truncate_val (vtype x) v) ->
  wfr_VAL rmap2 se (with_vm s1 (evm s1).[x <- v]) (with_mem s2 mem2).
Proof.
  move=> hwfr hsr haddr hreadeq hset htr hval y sry statusy vy.
  have /wfr_wf hwf := hsr.
  move=> /(check_gvalid_set_word hsr hwf hset) [|[|]].
  + case: x htr hval {hsr hwf hreadeq hset} => x xii /= htr hval.
    move=> [? ? -> ->]; subst x.
    have [_ hty] := hval.
    rewrite get_gvar_eq //.
    by t_xrbindP => hd <-.
  + move=> [hnglob hneq heqr hsry /= ->].
    have := check_gvalid_lvar hsry; rewrite mk_lvar_nglob // => hgvalid.
    rewrite get_gvar_neq //; move=> /(wfr_val hgvalid).
    assert (hwfy := check_gvalid_wf wfr_wf hgvalid).
    assert (hwfsy := check_gvalid_wf_status wfr_status hgvalid).
    by apply (eq_sub_region_val_same_region hwf haddr hsry hwfy heqr hreadeq hwfsy).
  move=> [? hneqr hgvalid].
  rewrite get_gvar_neq //; move=> /(wfr_val hgvalid).
  assert (hwfy := check_gvalid_wf wfr_wf hgvalid).
  apply: (eq_sub_region_val_distinct_regions hwf haddr hwfy hneqr _ hreadeq).
  by case: (set_wordP hwf haddr hset).
Qed.

(* TODO: clean *)
Lemma is_valid_clear_status_map_aux rmap z x status :
  is_valid (odflt Unknown (clear_status_map_aux rmap z x status)) ->
  is_valid status.
Proof.
  case: status => //=.
  + by rewrite clear_status_map_aux_unknown.
  move=> i /=. rewrite /clear_status_map_aux.
  case: Mvar.get => [sr|//].
  case: get_suffix => [z1|//].
  case: z1 => [z1|//].
  case: z1 => /=. done.
  move=> ??.
  case: add_sub_interval => /=. done. done.
Qed.

(* TODO: is this needed? *)
Lemma is_valid_valid_offset se status off :
  is_valid status ->
  valid_offset se status off.
Proof. by case: status. Qed.

Lemma var_region_not_new rmap se s2 x sr :
  wfr_PTR rmap se s2 ->
  Mvar.get rmap.(var_region) x = Some sr ->
  ~ Sv.In x pmap.(vnew).
Proof. by move=> /[apply] -[_ [/wf_vnew ? _]]. Qed.

Lemma valid_pk_set_word_status rmap se s1 s2 x sr ofs mem2 status y pk sry :
  wf_rmap rmap se s1 s2 ->
  Mvar.get rmap.(var_region) x = Some sr ->
  sub_region_addr se sr = ok ofs ->
  ~ Sv.In x pmap.(vnew) ->
  (forall al p ws,
    disjoint_zrange ofs (size_slot x) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  wf_local y pk ->
  valid_pk rmap se s2 sry pk ->
  valid_pk (set_word_status rmap sr x status) se (with_mem s2 mem2) sry pk.
Proof.
  move=> hwfr hsr haddr hnin hreadeq hlocal hpk.
  case: pk hlocal hpk => //= s ofs' ws' z f hlocal hpk.
  rewrite /check_stack_ptr get_var_status_set_word_status.
  case: eqP => heqr /=.
  + case: eqP => heq2.
    + by have := hlocal.(wfs_new); congruence.
    set status' := odflt Unknown _.
    move=> /is_validP hvalid.
    have hnunknown: status' <> Unknown by congruence.
    have [srf hsrf] := clear_status_map_aux_not_unknown hnunknown.
    by case (var_region_not_new wfr_ptr hsrf hlocal.(wfs_new)).
  move=> hvalid pofs ofsy haddrp haddry.
  rewrite -(hpk hvalid _ _ haddrp haddry).
  apply hreadeq.
  apply disjoint_zrange_sym.
  have /wfr_wf hwf := hsr.
  have hwfp := sub_region_stkptr_wf se hlocal.
  apply: (distinct_regions_disjoint_zrange hwfp haddrp hwf haddr _ erefl).
  by apply not_eq_sym.
Qed.

Lemma wfr_PTR_set_sub_region rmap se s1 s2 (x:var_i) sr ofs mem2 al status ws rmap2 :
  wf_rmap rmap se s1 s2 ->
  Mvar.get rmap.(var_region) x = Some sr ->
  sub_region_addr se sr = ok ofs ->
  (forall al p ws,
    disjoint_zrange ofs (size_slot x) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  set_word rmap al sr x status ws = ok rmap2 ->
  wfr_PTR rmap2 se (with_mem s2 mem2).
Proof.
  move=> hwfr hsr haddr hreadeq hset y sry.
  have /wfr_wf hwf := hsr.
  have [_ _ ->] /= := set_wordP hwf haddr hset.
  move=> /wfr_ptr [pky [hly hpky]].
  exists pky; split=> //.
  have /wfr_ptr [_ [/wf_vnew hnnew _]] := hsr.
  by apply (valid_pk_set_word_status _ hwfr hsr haddr hnnew hreadeq (wf_locals hly) hpky).
Qed.

(* This lemma is used for [set_sub_region] and [set_stack_ptr]. *)
Lemma eq_mem_source_write_slot table rmap se m0 s1 s2 sr ty ofs mem2:
  valid_state table rmap se m0 s1 s2 ->
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok ofs ->
  (forall al p ws,
    disjoint_zrange ofs (size_of ty) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  eq_mem_source (emem s1) mem2.
Proof.
  move=> hvs hwf haddr hreadeq p hvp.
  rewrite (vs_eq_mem hvp).
  symmetry; apply hreadeq.
  apply (disjoint_zrange_incl_l (zbetween_sub_region_addr hwf haddr)).
  by apply (vs_disjoint hwf.(wfr_slot) hvp).
Qed.

(* We show that, under the right hypotheses, [set_word] preserves
   the [valid_state] invariant.
   This lemma is used both for words and arrays. *)
Lemma valid_state_set_word table rmap se m0 s1 s2 sr (x:var_i) ofs mem2 al
    status ws (rmap2 : region_map) v :
  valid_state table rmap se m0 s1 s2 ->
  Mvar.get rmap.(var_region) x = Some sr ->
  sub_region_addr se sr = ok ofs ->
  stack_stable (emem s2) mem2 ->
  (validw mem2 =3 validw (emem s2)) ->
  (forall al p ws,
    disjoint_zrange ofs (size_slot x) p (wsize_size ws) ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  wf_status se status ->
  set_word rmap al sr x status ws = ok rmap2 ->
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se mem2 sr status (vm_truncate_val (vtype x) v) ->
  valid_state (remove_binding table x) rmap2 se m0 (with_vm s1 (evm s1).[x <- v]) (with_mem s2 mem2).
Proof.
  move=> hvs hsr haddr hss hvalideq hreadeq hwfs hset htr heqval.
  have /wfr_wf hwf := hsr.
  have /wfr_ptr [pk [hlx hpk]] := hsr.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
  constructor => //=.
  + by move=> ??; rewrite hvalideq; apply hvalid.
  + by move=> ??; rewrite hvalideq; apply hincl.
  + by move=> ??; rewrite hvalideq; apply hincl2.
  + have [hwritable _ _] := set_wordP hwf haddr hset.
    by apply (mem_unchanged_write_slot hwf haddr hwritable hreadeq hunch).
  + move=> y hget; rewrite Vm.setP_neq /=; first by apply heqvm.
    by apply /eqP; rewrite /get_local in hlx; congruence.
  + by apply: wf_table_set_var hwft.
  + case: (hwfr) => hwfsr hwfst hval hptr; split.
    + have [_ _ ->] := set_wordP hwf haddr hset.
      by move=> ?? /=; apply hwfsr.
    + have [cs ok_cs _] := hwf.(wfsr_zone).
      have [addr ok_addr _] := wunsigned_sub_region_addr hwf ok_cs.
      have [_ _ ->] := set_wordP hwf ok_addr hset.
      by apply (wfr_STATUS_set_word_pure hwfsr hwf hwfs hwfst).
    + by apply (wfr_VAL_set_word hwfr hsr haddr hreadeq hset htr heqval).
    by apply (wfr_PTR_set_sub_region hwfr hsr haddr hreadeq hset).
  + by apply (eq_mem_source_write_slot hvs hwf haddr hreadeq).
  by rewrite -(ss_top_stack hss).
Qed.

(*
Lemma set_arr_wordP rmap m0 s1 s2 al x ofs ws rmap2 :
  valid_state rmap m0 s1 s2 ->
  set_arr_word rmap al x ofs ws = ok rmap2 ->
  exists sr, [/\
    Mvar.get rmap.(var_region) x = Some sr,
    is_aligned_if al (sub_region_addr sr) ws &
    set_sub_region rmap x sr ofs (wsize_size ws) = ok rmap2].
Proof.
  move=> hvs.
  rewrite /set_arr_word; t_xrbindP=> sr /get_sub_regionP hget.
  have /wfr_wf hwf := hget.
  move=> /(check_alignP hwf) halign.
  by exists sr; split.
Qed.
*)

(* A version of [write_read8] easier to use. *)
Lemma write_read8_no_overflow mem1 mem2 al p ofs ws (w: word ws) :
  0 <= ofs /\ ofs + wsize_size ws <= wbase Uptr ->
  write mem1 al (p + wrepr _ ofs)%R w = ok mem2 ->
  forall k, 0 <= k < wbase Uptr ->
    read mem2 al (p + wrepr _ k)%R U8 =
      let i := k - ofs in
      if (0 <=? i) && (i <? wsize_size ws) then ok (LE.wread8 w i)
      else read mem1 al (p + wrepr _ k)%R U8.
Proof.
  move=> hofs hmem2 k hk.
  rewrite (write_read8 hmem2).
  rewrite subE {1}(GRing.addrC p) GRing.addrKA /=.
  rewrite wunsigned_sub_if.
  have hws := wsize_size_pos ws.
  rewrite !wunsigned_repr_small //; last by lia.
  case: (ZleP ofs k) => [//|hlt].
  case: (ZleP 0 (k - ofs)) => [|_]; first by lia.
  case: ZltP => [|_]; first by lia.
  by rewrite andFb andbF.
Qed.

(* Hypotheses are a bit restrictive but are those available in the proofs. *)
Lemma write_read8_sub_region se sr ty addr ofs ws mem1 al (w:word ws) mem2 :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok addr ->
  0 <= ofs /\ ofs + wsize_size ws <= size_of ty ->
  write mem1 al (addr + wrepr _ ofs)%R w = ok mem2 ->
  forall k, 0 <= k < size_of ty ->
    read mem2 al (addr + wrepr _ k)%R U8 =
      let i := k - ofs in
      if (0 <=? i) && (i <? wsize_size ws) then ok (LE.wread8 w i)
      else read mem1 al (addr + wrepr _ k)%R U8.
Proof.
  move=> hwf haddr hofs hmem2 k hk.
  have := no_overflow_sub_region_addr hwf haddr;
    rewrite /no_overflow !zify => hover.
  have ? := wunsigned_range addr.
  by apply: (write_read8_no_overflow _ hmem2); lia.
Qed.

Lemma zbetween_sub_region_addr_ofs se sr ty addr ofs ws :
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok addr ->
  0 <= ofs /\ ofs + wsize_size ws <= size_of ty ->
  zbetween addr (size_of ty) (addr + wrepr _ ofs) (wsize_size ws).
Proof.
  move=> hwf haddr hofs.
  rewrite /zbetween !zify.
  rewrite wunsigned_add; first by lia.
  have := no_overflow_sub_region_addr hwf haddr.
  rewrite /no_overflow zify.
  have := wunsigned_range addr.
  have := wsize_size_pos ws.
  by lia.
Qed.

Lemma validw_sub_region_addr_ofs table rmap se m0 s1 s2 sr ty addr ofs al ws :
  valid_state table rmap se m0 s1 s2 ->
  wf_sub_region se sr ty ->
  sub_region_addr se sr = ok addr ->
  0 <= ofs /\ ofs + wsize_size ws <= size_of ty ->
  is_aligned_if al (addr + wrepr _ ofs)%R ws ->
  validw s2.(emem) al (addr + wrepr _ ofs)%R ws.
Proof.
  move=> hvs hwf haddr hbound hal.
  have /vs_slot_valid hptr := hwf.(wfr_slot).
  apply /validwP; split=> //.
  move=> k hk; rewrite (validw8_alignment Aligned); apply hptr; move: hk.
  apply: between_byte.
  + apply: no_overflow_incl (no_overflow_sub_region_addr hwf haddr).
    by apply (zbetween_sub_region_addr_ofs hwf haddr hbound).
  apply (zbetween_trans (zbetween_sub_region_addr hwf haddr)).
  by apply (zbetween_sub_region_addr_ofs hwf haddr hbound).
Qed.

Lemma alloc_lvalP table rmap se r1 r2 v ty m0 (s1 s2: estate) :
  alloc_lval pmap rmap r1 ty = ok r2 -> 
  valid_state table rmap se m0 s1 s2 -> 
  type_of_val v = ty ->
  forall s1',
    write_lval true gd r1 v s1 = ok s1' ->
    exists2 s2',
      write_lval true [::] r2.2 v s2 = ok s2' &
      valid_state (remove_binding_lval table r1) r2.1 se m0 s1' s2'.
Proof.
  move=> ha hvs ?; subst ty.
  case: r1 ha => //; rewrite /alloc_lval.
  (* Lnone *)
  + move=> vi ty1 [<-] /= s1' /write_noneP.
    by rewrite /write_none => - [-> -> ->]; exists s2 => //.

  (* Lvar *)
  + move=> x.
    case hlx: get_local => [pk | ]; last first.
    + t_xrbindP=> /check_diffP hnnew <- s1' /= /write_varP [-> hdb htr].
      eexists; first by apply: (write_var_truncate hdb htr).
      by apply: valid_state_set_var.
    case heq: is_word_type => [ws | //]; move /is_word_typeP : heq => hty.
    case htyv: subtype => //.
    t_xrbindP=> sr /get_sub_regionP hsr rmap2 hsetw [xi ofsi] ha [<-] /= s1'
      /write_varP [-> hdb htr] /=.
    have /wfr_wf hwf := hsr.
    have /wf_locals hlocal := hlx.
    have /wfr_ptr := hsr; rewrite hlx => -[_ [[<-] hpk]].
    have [wi ok_wi haddr] := addr_from_pkP hvs true hlocal hpk hwf ha.
    rewrite ok_wi /= truncate_word_u /=.
    have := htr; rewrite {1}hty =>
      /(vm_truncate_val_subtype_word hdb htyv) [w htrw -> /=].
    have hofs: 0 <= 0 /\ wsize_size ws <= size_slot x by rewrite hty /=; lia.
    have hvp: validw (emem s2) Aligned (wi + wrepr _ ofsi)%R ws.
    + have [_ halign _] := set_wordP hwf haddr hsetw.
      have := validw_sub_region_addr_ofs hvs hwf haddr hofs.
      rewrite wrepr0 GRing.addr0.
      by apply.
    have /writeV -/(_ w) [mem2 hmem2] := hvp.
    rewrite hmem2 /=; eexists; first by reflexivity.
    (* valid_state update word *)
    have [_ _ hset] := set_wordP hwf haddr hsetw.
    apply: (valid_state_set_word hvs hsr haddr _ _ _ _ hsetw) => //.
    + by apply (Memory.write_mem_stable hmem2).
    + by move=> ??; apply (write_validw_eq hmem2).
    + move=> al p ws''.
      rewrite hty => /disjoint_range_alt.
      exact: (writeP_neq _ hmem2).
    rewrite {2}hty htrw; split => //.
    rewrite /eq_sub_region_val_read haddr.
    move=> off _ ? [<-] _ hget.
    have /= hoff := get_val_byte_bound hget.
    rewrite -(GRing.addr0 (_+_))%R in hmem2.
    rewrite (write_read8_sub_region hwf haddr hofs hmem2) /= ?hty // Z.sub_0_r /=.
    move: (hoff); rewrite -!zify => ->.
    by rewrite -(get_val_byte_word _ hoff).

  (* Lmem *)
  + move=> al ws x e1 /=; t_xrbindP => /check_varP hx /check_diffP hnnew e1' /(alloc_eP hvs) he1 <-.
    move=> s1' xp ? hgx hxp w1 v1 /he1 he1' hv1 w hvw mem1 hmem1 <- /=.
    have := get_var_kindP hvs hx hnnew; rewrite /get_gvar /= => /(_ _ _ hgx) -> /=.
    have {}he1': sem_pexpr true [::] s2 e1' >>= to_pointer = ok w1.
    + have [ws1 [wv1 [? hwv1]]] := to_wordI hv1; subst.
      move: he1'; rewrite /truncate_val /= hwv1 /= => /(_ _ erefl) [] ve1' [] -> /=.
      by t_xrbindP=> w1' -> ? /=; subst w1'.
    rewrite he1' hxp /= hvw /=.
    have hvp1 := write_validw hmem1.
    have /valid_incl_word hvp2 := hvp1.
    have /writeV -/(_ w) [mem2 hmem2] := hvp2.
    rewrite hmem2 /=; eexists; first by reflexivity.
    (* valid_state update mem *)
    case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
    constructor => //=.
    + move=> ??; rewrite (write_validw_eq hmem2); apply hvalid.
    + by move=> ???; rewrite (write_validw_eq hmem1); apply hdisj.
    + move=> ?; rewrite (write_validw_eq hmem1) (write_validw_eq hmem2); apply hincl.
    + move=> ?; rewrite (write_validw_eq hmem2); apply hincl2.
    + move=> p hvalid2; rewrite (write_validw_eq hmem1) => hvalid3 hdisj2.
      rewrite (hunch p hvalid2 hvalid3 hdisj2).
      symmetry; apply (writeP_neq _ hmem2).
      by apply (disjoint_range_valid_not_valid_U8 hvp1 hvalid3).
    + case: (hwfr) => hwfsr hwfst hval hptr; split=> //.
      + move=> y sry statusy vy hgvalid hgy.
        assert (hwfy := check_gvalid_wf hwfsr hgvalid).
        have hreadeq := writeP_neq _ hmem2.
        have [csy ok_csy _] := hwfy.(wfsr_zone).
        have [ofsy haddry _] := wunsigned_sub_region_addr hwfy ok_csy.
        apply: (eq_sub_region_val_disjoint_zrange_ovf hreadeq haddry _ (hval _ _ _ _ hgvalid hgy)).
        have := disjoint_source_word hvs hwfy.(wfr_slot) hvp1.
        have := zbetween_sub_region_addr hwfy haddry.
        exact: zbetween_disjoint_zrange_ovf.
      move=> y sry hgy.
      have [pk [hgpk hvpk]] := hptr _ _ hgy; exists pk; split => //.
      case: pk hgpk hvpk => //= s ofs ws' z f hgpk hread hcheck pofs ofsy haddrp haddry.
      rewrite -(hread hcheck _ _ haddrp haddry).
      apply: (writeP_neq _ hmem2).
      assert (hwf' := sub_region_stkptr_wf se (wf_locals hgpk)).
      have := disjoint_source_word hvs hwf'.(wfr_slot) hvp1.
      have := zbetween_sub_region_addr hwf' haddrp.
      exact: zbetween_disjoint_zrange_ovf.
    + move=> p; rewrite (write_validw_eq hmem1) => hv.
      apply: read_write_any_mem hmem1 hmem2.
      by apply heqmem.
    by rewrite -(ss_top_stack (Memory.write_mem_stable hmem2)).

  (* Laset *)
  move=> al aa ws x e1 /=; t_xrbindP => e1' /(alloc_eP hvs) he1.
  move=> hr2 s1'; apply: on_arr_varP => n t hty hxt.
  t_xrbindP => i1 v1 /he1 he1' hi1 w hvw t' htt' /write_varP [? hdb htr]; subst s1'.
  have {he1} he1 : sem_pexpr true [::] s2 e1' >>= to_int = ok i1.
  + have ? := to_intI hi1; subst.
    move: he1'; rewrite /truncate_val /= => /(_ _ erefl) [] ve1' [] -> /=.
    by t_xrbindP=> i1' -> ? /=; subst i1'.
  case hlx: get_local hr2 => [pk | ]; last first.
  + t_xrbindP=> /check_diffP hnnew <-.
    have /get_var_kindP -/(_ _ _ hnnew hxt) : get_var_kind pmap (mk_lvar x) = ok None.
    + by rewrite /get_var_kind /= hlx.
    rewrite /get_gvar /= => hxt2.
    rewrite he1 hxt2 /= hvw /= htt' /= (write_var_truncate hdb htr) //.
    by eexists; first reflexivity; apply: valid_state_set_var.
  t_xrbindP=> -[sr status] /get_sub_region_statusP [hsr ->].
  t_xrbindP=> rmap2 hset [xi ofsi] ha [<-] /=.
  have /wfr_wf hwf := hsr.
  have /wfr_ptr := hsr; rewrite hlx /= => -[_ [[<-] /= hpk]].
  have [wx -> /= haddr] := addr_from_pkP hvs true (wf_locals hlx) hpk hwf ha.
  rewrite (mk_ofsP aa ws ofsi he1) /= truncate_word_u /= hvw /=.
  have [hge0 hlen haa] := WArray.set_bound htt'.
  have hvp: validw (emem s2) al (wx + wrepr Uptr ofsi + wrepr _ (i1 * mk_scale aa ws))%R ws.
  + apply (validw_sub_region_addr_ofs hvs hwf haddr); first by rewrite hty.
    have [_ hal _] := set_wordP hwf haddr hset.
    case: al haa hal {htt' hset} => //= haa hal.
    apply: is_align_add; first by [].
    by rewrite WArray.arr_is_align.
  have /writeV -/(_ w) [mem2 hmem2] := hvp.
  rewrite Z.add_comm wrepr_add GRing.addrA hmem2 /=; eexists; first by reflexivity.
  (* valid_state update array *)
  have hofs: 0 <= i1 * mk_scale aa ws /\ i1 * mk_scale aa ws + size_of (sword ws) <= size_slot x.
  + by rewrite hty.
  have hvalideq := write_validw_eq hmem2.
  apply: (valid_state_set_word hvs hsr haddr  _ hvalideq _ _ hset htr) => //.
  + by apply (Memory.write_mem_stable hmem2).
  + move=> al' p ws' hdisj.
    apply (writeP_neq _ hmem2).
    apply: disjoint_range_alt.
    apply: disjoint_zrange_incl_l hdisj.
    by apply (zbetween_sub_region_addr_ofs hwf haddr).
  + by apply: get_var_status_wf_status wfr_status.
  have /vm_truncate_valE [_ ->]:= htr.
  split=> //.
  rewrite /eq_sub_region_val_read haddr.
  move=> off _ ? [<-] hvalid hget.
  have /= hoff := get_val_byte_bound hget.
  rewrite (read8_alignment al) (write_read8_sub_region hwf haddr hofs hmem2) /= ?hty //.
  move: hget; rewrite /= (write_read8 htt') WArray.subE /=.
  case: ifP => // hle.
  have hgvalid := check_gvalid_lvar hsr.
  assert (hval := wfr_val hgvalid hxt).
  case: hval => hread _.
  rewrite (read8_alignment Aligned).
  by apply hread.
Qed.

Lemma alloc_lvalsP table rmap se r1 r2 vs ty m0 (s1 s2: estate) :
  alloc_lvals pmap rmap r1 ty = ok r2 ->
  valid_state table rmap se m0 s1 s2 ->
  seq.map type_of_val vs = ty ->
  forall s1',
    write_lvals true gd s1 r1 vs = ok s1' ->
    exists2 s2',
      write_lvals true [::] s2 r2.2 vs = ok s2' &
      valid_state (foldl remove_binding_lval table r1) r2.1 se m0 s1' s2'.
Proof.
  elim: r1 r2 rmap ty vs se s1 s2 table=> //= [|a l IH] r2 rmap [ | ty tys] // [ | v vs] //.
  + by move=> se s1 s2 ? [<-] Hvalid _ s1' [<-]; exists s2.
  move=> se s1 s2 table; t_xrbindP => -[a' r3] ha [l' r4] /IH hrec <-.
  move=> Hvalid [] hty htys s1' s1'' ha1 hl1.
  have [s2' hs2' vs2']:= alloc_lvalP ha Hvalid hty ha1.
  have [s2'' hs2'' vs2'']:= hrec _ _ _ _ _ vs2' htys _ hl1.
  by exists s2'' => //=; rewrite hs2'.
Qed.

Lemma update_table_test table r ty e table2 se vm :
  update_table table r ty e = ok table2 ->
  Sv.Subset (oapp read_e Sv.empty e) table.(vars) ->
  wf_table table se vm ->
  wf_table table2 se vm.
Proof.
  rewrite /update_table.
  case: r => //; try by congruence.
  move=> x.
  case: e => [e|]; last by congruence.
  t_xrbindP=> _ /o2rP.
  rewrite /table_set_var.
  case: Sv_memP => // ? [<-].
  move=> hsub.
  case=> hvars hundef hsem.
  split=> //=.
  + move=> y ey /=. rewrite Mvar.setP. case: eqP. move=> _ [<-]. done.
  eauto.
  move=> y ey vy /=. rewrite Mvar.setP. case: eqP. move=> <- [<-].
  eauto.
Abort.

Variable (P' : sprog).
Hypothesis P'_globs : P'.(p_globs) = [::].

Local Opaque arr_size.

Lemma get_var_status_set_move_status rv x r status ry y :
  get_var_status (set_move_status rv x r status) ry y =
    let statusy := get_var_status rv ry y in
    if r != ry then
      statusy
    else
      if x == y then status
      else statusy.
Proof.
  rewrite /set_move_status /get_var_status get_status_map_setP.
  case: eqP => //= <-.
  by rewrite get_status_setP.
Qed.

Lemma check_gvalid_set_move rmap x sr status y sry statusy :
  check_gvalid (set_move rmap x sr status) y = Some (sry, statusy) ->
    [/\ ~ is_glob y, x = gv y, sr = sry &
        statusy = status]
  \/
    [/\ ~ is_glob y -> x <> gv y &
        check_gvalid rmap y = Some (sry, statusy)].
Proof.
  rewrite /check_gvalid.
  case: (@idP (is_glob y)) => hg.
  + case heq: Mvar.get => [[ofs ws]|//] [<- <-].
    by right; split.
  rewrite Mvar.setP; case: eqP.
  + move=> -> [<- <-]; left; split=> //.
    by rewrite get_var_status_set_move_status !eq_refl.
  move=> hneq.
  case heq': Mvar.get => [sr'|//] [? <-]; subst sr'.
  right; split => //.
  rewrite get_var_status_set_move_status.
  case: eqP => [_|//].
  by move: hneq=> /eqP /negPf ->.
Qed.
(*
Lemma set_arr_subP rmap x ofs len sr_from bytesy rmap2 :
  set_arr_sub rmap x ofs len sr_from bytesy = ok rmap2 ->
  exists sr, [/\
    Mvar.get rmap.(var_region) x = Some sr,
    sub_region_at_ofs sr (Some ofs) len = sr_from &
    set_move_sub rmap x (sub_region_at_ofs sr (Some ofs) len) bytesy = rmap2].
Proof.
  rewrite /set_arr_sub.
  t_xrbindP=> sr /get_sub_regionP -> /eqP heqsub hmove.
  by exists sr.
Qed.

*)
Lemma type_of_get_gvar_array wdb gd vm x n (a : WArray.array n) :
  get_gvar wdb gd vm x = ok (Varr a) ->
  x.(gv).(vtype) = sarr n.
Proof. by move=> /get_gvar_compat; rewrite /compat_val /= orbF => -[_] /compat_typeEl. Qed.

(*
Lemma get_Pvar_sub_bound wdb s1 v e y suby ofs len :
  sem_pexpr wdb gd s1 e = ok v ->
  get_Pvar_sub e = ok (y, suby) ->
  match suby with
  | Some p => p
  | None => (0, size_slot y.(gv))
  end = (ofs, len) ->
  0 < len /\
  0 <= ofs /\ ofs + len <= size_slot y.(gv).
Proof.
  case: e => //=.
  + move=> _ _ [_ <-] [<- <-].
    split; first by apply size_of_gt0.
    by lia.
  move=> aa ws len' x e'.
  apply: on_arr_gvarP.
  t_xrbindP=> n _ hty _ i v' he' hv' _ /WArray.get_sub_bound hbound _ ofs' hofs' <- <- [<- <-].
  split=> //.
  rewrite hty.
  have {he' hv'} he' : sem_pexpr wdb gd s1 e' >>= to_int = ok i by rewrite he'.
  by move: hofs' => /(get_ofs_subP he') ->.
Qed.

Lemma get_Pvar_subP wdb s1 n (a : WArray.array n) e y ofsy ofs len :
  sem_pexpr wdb gd s1 e = ok (Varr a) ->
  get_Pvar_sub e = ok (y, ofsy) ->
  match ofsy with
  | None => (0%Z, size_slot y.(gv))
  | Some p => p
  end = (ofs, len) ->
  n = Z.to_pos len /\
  exists (t : WArray.array (Z.to_pos (size_slot y.(gv)))),
    get_gvar wdb gd (evm s1) y = ok (Varr t) /\
    (forall i w, read a Aligned i U8 = ok w -> read t Aligned (ofs + i) U8 = ok w).
Proof.
  case: e => //=.
  + move=> y' hget [? <-] [<- ?]; subst y' len.
    have -> := type_of_get_gvar_array hget.
    split=> //.
    by exists a; split.
  move=> aa ws len' x e.
  apply: on_arr_gvarP.
  move=> n1 a1 hty hget.
  (* We manually apply [rbindP], because [t_xrbindP] is a bit too aggressive. *)
  apply: rbindP => i he.
  apply: rbindP => a2 hgsub heq.
  have := Varr_inj (ok_inj heq) => {heq} -[?]; subst n => /= ?; subst a2.
  t_xrbindP=> _ /(get_ofs_subP he) -> <- <- [<- <-].
  split=> //.
  rewrite hty.
  exists a1; split=> //.
  move=> k w.
  move=> /[dup]; rewrite -{1}get_read8 => /WArray.get_valid8 /WArray.in_boundP => hbound.
  rewrite (WArray.get_sub_get8 hgsub) /=.
  by move: hbound; rewrite -!zify => ->.
Qed.
*)

Lemma is_stack_ptrP vpk s ofs ws z f :
  is_stack_ptr vpk = Some (s, ofs, ws, z, f) ->
  vpk = VKptr (Pstkptr s ofs ws z f).
Proof.
  case: vpk => [|[]] => //=.
  by move=> _ _ _ _ _ [-> -> -> -> ->].
Qed.

Lemma addr_from_vpk_pexprP table rmap se m0 s1 s2 (x : var_i) vpk sr ty e1 ofs wdb :
  valid_state table rmap se m0 s1 s2 ->
  wf_vpk x vpk ->
  valid_vpk rmap se s2 x sr vpk ->
  wf_sub_region se sr ty ->
  addr_from_vpk_pexpr pmap rmap x vpk = ok (e1, ofs) ->
  exists2 w,
    sem_pexpr wdb [::] s2 e1 >>= to_pointer = ok w &
    sub_region_addr se sr = ok (w + wrepr _ ofs)%R.
Proof.
  move=> hvs hwfpk hpk hwf.
  rewrite /addr_from_vpk_pexpr.
  case heq: is_stack_ptr => [[[[[s ws] ofs'] z] f]|]; last first.
  + by t_xrbindP=> -[x' ofs'] /(addr_from_vpkP hvs wdb hwfpk hpk hwf) haddr <- <-.
  move /is_stack_ptrP in heq; subst vpk.
  rewrite /= in hpk hwfpk.
  t_xrbindP=> /hpk hread <- <- /=.
  have [cs ok_cs _] := hwf.(wfsr_zone).
  have [addr haddr _] := wunsigned_sub_region_addr hwf ok_cs.
  have haddrp := sub_region_addr_stkptr se hwfpk.
  rewrite
    truncate_word_u /=
    /get_var vs_rsp /= orbT /=
    truncate_word_u /=
    (hread _ _ haddrp haddr) /=
    truncate_word_u.
  eexists; first by reflexivity.
  by rewrite wrepr0 GRing.addr0.
Qed.

(* Alternative form of cast_get8, easier to use in our case *)
Lemma cast_get8 len1 len2 (m : WArray.array len2) (m' : WArray.array len1) :
  WArray.cast len1 m = ok m' ->
  forall k w,
    read m' Aligned k U8 = ok w ->
    read m Aligned k U8 = ok w.
Proof.
  move=> hcast k w.
  move=> /[dup]; rewrite -{1}get_read8 => /WArray.get_valid8 /WArray.in_boundP => hbound.
  rewrite (WArray.cast_get8 hcast).
  by case: hbound => _ /ZltP ->.
Qed.

Lemma wfr_WF_set se sr x rmap rmap2 :
  wf_sub_region se sr x.(vtype) ->
  rmap2.(var_region) = Mvar.set rmap.(var_region) x sr ->
  wfr_WF rmap se ->
  wfr_WF rmap2 se.
Proof.
  move=> hwf hrmap2 hwfr y sry.
  rewrite hrmap2 Mvar.setP.
  by case: eqP; [congruence|auto].
Qed.

Lemma wfr_STATUS_set_move se status rmap x sr :
  wf_status se status ->
  wfr_STATUS rmap se ->
  wfr_STATUS (set_move rmap x sr status) se.
Proof.
  move=> hwfs hwfst.
  move /wfr_STATUS_alt in hwfst; apply wfr_STATUS_alt.
  move=> r y /=.
  rewrite get_var_status_set_move_status.
  case: eq_op => //=.
  by case: eq_op.
Qed.

Lemma wfr_VAL_set_move rmap se s1 s2 x sr status v :
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se (emem s2) sr status
    (vm_truncate_val (vtype x) v) ->
  wfr_VAL rmap se s1 s2 ->
  wfr_VAL (set_move rmap x sr status) se (with_vm s1 (evm s1).[x <- v]) s2.
Proof.
  move=> htr heqval hval y sry bytesy vy /check_gvalid_set_move [].
  + by move=> [? ? <- ->]; subst x; rewrite get_gvar_eq //; t_xrbindP => hd <-.
  by move=> [? hgvalid]; rewrite get_gvar_neq => //; apply hval.
Qed.

Lemma valid_pk_set_move (rmap:region_map) se x sr status s2 y pky sry :
  ~ Sv.In x pmap.(vnew) ->
  wf_local y pky ->
  valid_pk rmap se s2 sry pky ->
  valid_pk (set_move rmap x sr status) se s2 sry pky.
Proof.
  move=> hnnew hlocal.
  case: pky hlocal => //=.
  move=> s ofs ws z f hlocal.
  rewrite /check_stack_ptr get_var_status_set_move_status.
  case: eqP => [_|//].
  case: eqP => //.
  by have := hlocal.(wfs_new); congruence.
Qed.

Lemma wfr_PTR_set_move (rmap : region_map) se s2 x pk sr status :
  get_local pmap x = Some pk ->
  valid_pk rmap se s2 sr pk ->
  wfr_PTR rmap se s2 ->
  wfr_PTR (set_move rmap x sr status) se s2.
Proof.
  move=> hlx hpk hptr y sry.
  have /wf_vnew hnnew := hlx.
  rewrite Mvar.setP; case: eqP.
  + move=> <- [<-].
    exists pk; split=> //.
    by apply (valid_pk_set_move _ _ hnnew (wf_locals hlx) hpk).
  move=> _ /hptr {pk hlx hpk} [pk [hly hpk]].
  exists pk; split=> //.
  by apply (valid_pk_set_move _ _ hnnew (wf_locals hly) hpk).
Qed.

(* There are several lemmas about [set_move] and [valid_state], and all are useful. *)
Lemma valid_state_set_move table rmap se m0 s1 s2 x sr status pk v :
  valid_state table rmap se m0 s1 s2 ->
  wf_sub_region se sr x.(vtype) ->
  wf_status se status ->
  get_local pmap x = Some pk ->
  valid_pk rmap.(region_var) se s2 sr pk ->
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se (emem s2) sr status (vm_truncate_val (vtype x) v) ->
  valid_state (remove_binding table x) (set_move rmap x sr status) se m0 (with_vm s1 (evm s1).[x <- v]) s2.
Proof.
  move=> hvs hwf hwfs hlx hpk htr heqval.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
  constructor=> //=.
  + move=> y hget; rewrite Vm.setP_neq; first by apply heqvm.
    by apply /eqP; rewrite /get_local in hlx; congruence.
  + by apply wf_table_set_var.
  case: (hwfr) => hwfsr hwfst hval hptr; split.
  + by apply: (wfr_WF_set hwf _ hwfsr).
  + by apply (wfr_STATUS_set_move hwfs hwfst).
  + by apply (wfr_VAL_set_move htr heqval hval).
  by apply (wfr_PTR_set_move hlx hpk hptr).
Qed.

(*
Lemma ptr_prop x p (w:word Uptr):
  get_local pmap x = Some (Pregptr p) ->
  type_of_val (Vword w) = vtype p.
Proof. by move=> /wf_locals /= /wfr_rtype ->. Qed.
*)

Lemma valid_state_set_move_regptr table rmap se m0 s1 s2 x sr status v p addr :
  valid_state table rmap se m0 s1 s2 ->
  wf_sub_region se sr x.(vtype) ->
  sub_region_addr se sr = ok addr ->
  wf_status se status ->
  get_local pmap x = Some (Pregptr p) ->
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se (emem s2) sr status (vm_truncate_val (vtype x) v) ->
  valid_state (remove_binding table x) (set_move rmap x sr status) se m0
       (with_vm s1 (evm s1).[x <- v])
       (with_vm s2 (evm s2).[p <- Vword addr]).
Proof.
  move=> hvs hwf haddr hwfs hlx htr heqval.
  have /wf_locals /= hlocal := hlx.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
  constructor=> //=.
  + rewrite Vm.setP_neq //; apply /eqP.
    by apply hlocal.(wfr_not_vrip).
  + rewrite Vm.setP_neq //; apply /eqP.
    by apply hlocal.(wfr_not_vrsp).
  + move=> y hget hnnew.
    rewrite Vm.setP_neq; last by apply/eqP; rewrite /get_local in hlx; congruence.
    rewrite Vm.setP_neq; last by apply/eqP; have := hlocal.(wfr_new); congruence.
    by apply heqvm.
  + by apply wf_table_set_var.
  case: (hwfr) => hwfsr hwfst hval hptr; split.
  + by apply: (wfr_WF_set hwf _ hwfsr).
  + by apply (wfr_STATUS_set_move hwfs hwfst).
  + by apply (wfr_VAL_set_move htr heqval hval).
  move=> y sry.
  have htrp : truncatable true (vtype p) (Vword addr).
  + rewrite hlocal.(wfr_rtype).
    by apply (truncatable_type_of true (Vword addr)).
  rewrite Mvar.setP; case: eqP.
  + move=> <- [<-].
    exists (Pregptr p); split=> //=.
    rewrite haddr => _ [<-].
    by rewrite Vm.setP_eq // vm_truncate_val_eq // hlocal.(wfr_rtype).
  move=> hneq /hptr [pk [hly hpk]].
  exists pk; split=> //.
  case: pk hly hpk => //=.
  + move=> p2 hly.
    rewrite Vm.setP_neq //.
    by apply/eqP/(hlocal.(wfr_distinct) hly hneq).
  move=> s ofs ws z f hly.
  rewrite /check_stack_ptr get_var_status_set_move_status.
  case: eqP => [_|//].
  case: eqP => //.
  have /is_sarrP [n hty] := hlocal.(wfr_type).
  have /wf_locals /wfs_new := hly.
  by have /wf_vnew := hlx; congruence.
Qed.

(* For stack ptr, we call set_stack_ptr (set_move ...) ..., so set_stack_ptr is
   called on a rmap which does not satisfy valid_state, nor even wfr_PTR.
   But it satisfies
     (forall x sr, Mvar.get rmap.(var_region) x = Some sr -> ~ Sv.In x pmap.(vnew))
   and this is sufficient. *)

(* close to check_gvalid_set_word, but different hypotheses *)
Lemma check_gvalid_set_stack_ptr rmap s ws cs f y sry statusy :
  (forall x sr, Mvar.get rmap.(var_region) x = Some sr -> ~ Sv.In x pmap.(vnew)) ->
  Sv.In f pmap.(vnew) ->
  check_gvalid (set_stack_ptr rmap s ws cs f) y = Some (sry, statusy) ->
  [/\ ~ is_glob y, f <> gv y, (sub_region_stkptr s ws cs).(sr_region) = sry.(sr_region),
        Mvar.get rmap.(var_region) y.(gv) = Some sry &
        let statusy' := get_var_status rmap sry.(sr_region) y.(gv) in
        statusy = odflt Unknown (clear_status_map_aux rmap (sub_region_stkptr s ws cs).(sr_zone) y.(gv) statusy')]
  \/
    [/\ ~ is_glob y -> f <> gv y, (sub_region_stkptr s ws cs).(sr_region) <> sry.(sr_region) &
        check_gvalid rmap y = Some (sry, statusy)].
Proof.
  move=> hnnew hnew.
  rewrite /check_gvalid /=.
  case: (@idP (is_glob y)) => hg.
  + case heq: Mvar.get => [[ofs' ws']|//] [<- <-].
    by right; split.
  case hsry: Mvar.get => [sr|//] [? <-]; subst sr.
  have hneq: f <> y.(gv).
  + by move /hnnew : hsry; congruence.
  rewrite get_var_status_set_word_status.
  have /eqP /negPf -> /= := hneq.
  case: eqP => heqr /=.
  + by left; split.
  by right; split.
Qed.

Lemma valid_pk_set_stack_ptr (rmap : region_map) se s2 x s ofs ws cs f paddr mem2 y pky sry :
  (forall x sr, Mvar.get rmap.(var_region) x = Some sr -> ~ Sv.In x pmap.(vnew)) ->
  wf_stkptr x s ofs ws cs f ->
  sub_region_addr se (sub_region_stkptr s ws cs) = ok paddr ->
  (forall al p ws,
    disjoint_range paddr Uptr p ws ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  x <> y ->
  get_local pmap y = Some pky ->
  valid_pk rmap se s2 sry pky ->
  valid_pk (set_stack_ptr rmap s ws cs f) se (with_mem s2 mem2) sry pky.
Proof.
  move=> hnnew hlocal hpaddr hreadeq hneq.
  case: pky => //= sy ofsy wsy csy fy hly hpky.
  have hwf := sub_region_stkptr_wf se hlocal.
  assert (hwfy := sub_region_stkptr_wf se (wf_locals hly)).
  rewrite /check_stack_ptr get_var_status_set_word_status.
  case: eqP => heqr /=.
  + have hneqf := hlocal.(wfs_distinct) hly hneq.
    have /eqP /negPf -> := hneqf.
    rewrite /clear_status_map_aux.
    case heq: Mvar.get => [srfy|//].
    (* pseudo-variables are not in var_region! We are imprecise, but the proof
       is easy. Cf. comment on clear_status_map_aux *)
    by case: (hnnew _ _ heq (wf_locals hly).(wfs_new)).
  move=> hcheck paddry addry hpaddry haddry.
  rewrite -(hpky hcheck _ _ hpaddry haddry).
  apply hreadeq.
  by apply (distinct_regions_disjoint_zrange hwf hpaddr hwfy hpaddry heqr erefl).
Qed.

(* For stack ptr, we call both set_move and set_stack_ptr. *)
Lemma valid_state_set_stack_ptr table rmap se m0 s1 s2 x s ofs ws cs f paddr mem2 sr addr status v :
  valid_state table rmap se m0 s1 s2 ->
  wf_sub_region se sr x.(vtype) ->
  sub_region_addr se sr = ok addr ->
  wf_status se status ->
  get_local pmap x = Some (Pstkptr s ofs ws cs f) ->
  sub_region_addr se (sub_region_stkptr s ws cs) = ok paddr ->
  stack_stable (emem s2) mem2 ->
  validw mem2 =3 validw (emem s2) ->
  (forall al p ws,
    disjoint_range paddr Uptr p ws ->
    read mem2 al p ws = read (emem s2) al p ws) ->
  read mem2 Aligned paddr Uptr = ok addr ->
  truncatable true (vtype x) v ->
  eq_sub_region_val x.(vtype) se (emem s2) sr status (vm_truncate_val (vtype x) v) ->
  valid_state
    (remove_binding table x)
    (set_stack_ptr (set_move rmap x sr status) s ws cs f)
    se m0 (with_vm s1 (evm s1).[x <- v]) (with_mem s2 mem2).
Proof.
  move=> hvs hwf haddr hwfs hlx hpaddr hss hvalideq hreadeq hreadptr htr heqval.
  have /wf_locals hlocal := hlx.
  have hwf' := sub_region_stkptr_wf se hlocal.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
  constructor=> //=.
  + by move=> ??; rewrite hvalideq; apply hvalid.
  + by move=> ??; rewrite hvalideq; apply hincl.
  + by move=> ??; rewrite hvalideq; apply hincl2.
  + by apply (mem_unchanged_write_slot hwf' hpaddr refl_equal hreadeq hunch).
  + move=> y hget; rewrite Vm.setP_neq; first by apply heqvm.
    by apply/eqP; rewrite /get_local in hlx; congruence.
  + by apply wf_table_set_var.
  case: (hwfr) => hwfsr hwfst hval hptr.
  have hwfsr': wfr_WF (set_move rmap x sr status) se.
  + by apply: (wfr_WF_set hwf _ hwfsr).
  have hwfst': wfr_STATUS (set_move rmap x sr status) se.
  + by apply (wfr_STATUS_set_move hwfs hwfst).
  have hval': wfr_VAL (set_move rmap x sr status) se (with_vm s1 (evm s1).[x <- v]) s2.
  + by apply (wfr_VAL_set_move htr heqval hval).
  have hnnew: forall y' sry',
    Mvar.get (var_region (set_move rmap x sr status)) y' = Some sry' ->
    ~ Sv.In y' (vnew pmap).
  + move=> y' sry' /=.
    rewrite Mvar.setP.
    case: eqP.
    + by move=> <- _; apply (wf_vnew hlx).
    by move=> _; apply (var_region_not_new hptr).
  split=> //.
  + by apply: (wfr_STATUS_set_word_pure hwfsr' hwf' _ hwfst').
  + move=> y sry statusy vy /=.
    move=> /(check_gvalid_set_stack_ptr hnnew hlocal.(wfs_new)) [].
    + move=> [hnglob hneq heqr hsry /= ->] hgety.
      have := check_gvalid_lvar hsry; rewrite mk_lvar_nglob // => hgvalidy.
      have /= hwfy := check_gvalid_wf hwfsr' hgvalidy.
      assert (heqvaly := hval' _ _ _ _ hgvalidy hgety).
      apply: (eq_sub_region_val_same_region hwf' hpaddr hsry hwfy heqr hreadeq _ heqvaly).
      by move /wfr_STATUS_alt in hwfst'.
    move=> [? hneqr hgvalidy] hgety.
    have /= hwfy := check_gvalid_wf hwfsr' hgvalidy.
    assert (heqvaly := hval' _ _ _ _ hgvalidy hgety).
    by apply (eq_sub_region_val_distinct_regions hwf' hpaddr hwfy hneqr erefl hreadeq heqvaly).
  + move=> y sry.
    rewrite [Mvar.get _ _]/= Mvar.setP.
    case: eqP.
    + move=> <- [<-].
      exists (Pstkptr s ofs ws cs f); split=> //=.
      by rewrite haddr hpaddr => _ _ _ [<-] [<-].
    move=> hneq /wfr_ptr [pky [hly hpky]].
    exists pky; split=> //.
    apply (valid_pk_set_stack_ptr hnnew hlocal hpaddr hreadeq hneq hly).
    by apply (valid_pk_set_move sr status (wf_vnew hlx) (wf_locals hly) hpky).
  + by apply (eq_mem_source_write_slot hvs hwf' hpaddr hreadeq).
  by rewrite -(ss_top_stack hss).
Qed.

(* Just like set_word, set_move_sub does not update the var_region part of the
   rmap. It takes a region and a variable as arguments. It makes sense only
   if the region is the one associated to the variable in var_region. We add
   this as an hypothesis. *)
Lemma check_gvalid_set_move_sub rmap sr x statusx ofs len substatus y sry statusy :
  Mvar.get rmap.(var_region) x = Some sr ->
  check_gvalid (set_move_sub rmap sr.(sr_region) x statusx ofs len substatus) y = Some (sry, statusy) ->
    [/\ ~ is_glob y, x = gv y, sry = sr & statusy = insert_status x statusx ofs len substatus]
  \/
    [/\ ~ is_glob y -> x <> gv y &
        check_gvalid rmap y = Some (sry, statusy)].
Proof.
  move=> hsr.
  rewrite /check_gvalid /=.
  case: (@idP (is_glob y)) => hg.
  + case heq: Mvar.get => [[ofs' ws]|//] [<- <-] /=.
    by right; split.
  case hsry: Mvar.get => [sr'|//] [? <-]; subst sr'.
  rewrite get_var_status_set_move_status.
  case: (x =P y.(gv)).
  + move=> eq_xy.
    move: hsry; rewrite -eq_xy hsr => -[<-].
    rewrite eqxx.
    by left; split.
  move=> neq_xy.
  right; split=> //=.
  by rewrite if_same.
Qed.

(* The proof would be straightforward using subseq, but it is available only for
   eqType. And intervals are not eqType. *)
Lemma wf_interval_remove_sub_interval se i s cs :
  wf_interval se i ->
  sem_slice se s = ok cs ->
  wf_interval se (remove_sub_interval i s).
Proof.
  rewrite /wf_interval.
  move=> [ci [ok_ci all_ci sorted_ci]] ok_cs.
  suff: exists ci2, [/\
    mapM (sem_slice se) (remove_sub_interval i s) = ok ci2,
    all (fun cs => 0 <? cs.(cs_len)) ci2,
    path.sorted concrete_slice_ble ci2 &
    forall cs', all (concrete_slice_ble cs') ci -> all (concrete_slice_ble cs') ci2].
  + move=> [ci2 [ok_ci2 all_ci2 sorted_ci2 _]].
    by exists ci2.
  elim: i ci ok_ci all_ci sorted_ci => [|s' i ih] /=.
  + move=> _ [<-] _ _.
    by eexists; split; first by reflexivity.
  t_xrbindP=> _ cs' ok_cs' ci ok_ci <- all_ci sorted_ci.
  have := all_ci => /= /andP [len_cs' all_ci'].
  have := sorted_ci.
  rewrite /= (path.path_pairwise_in concrete_slice_ble_trans) /=;
    last by apply /andP; split.
  rewrite -(path.sorted_pairwise_in concrete_slice_ble_trans) //.
  move=> /andP [cs'_le_ci sorted_ci'].
  have [ci2 [ok_ci2 all_ci2 sorted_ci2 hincl]] := ih _ ok_ci all_ci' sorted_ci'.
  case: symbolic_slice_beq.
  + rewrite ok_ci.
    eexists; (split; first by reflexivity) => //.
    by move=> cs'' /= /andP[].
  case hle: (odflt _ _).
  + rewrite /= ok_cs' ok_ci /=.
    by eexists; split; first by reflexivity.
  have h: exists ci2, [/\
    mapM (sem_slice se) (s' :: remove_sub_interval i s) = ok ci2,
    all (fun cs => 0 <? cs.(cs_len)) ci2,
    path.sorted concrete_slice_ble ci2 &
    forall cs'', all (concrete_slice_ble cs'') (cs' :: ci) -> all (concrete_slice_ble cs'') ci2].
  + rewrite /= ok_cs' ok_ci2 /=.
    eexists; split; first by reflexivity.
    + by move=> /=; apply /andP; split.
    + rewrite /= (path.path_pairwise_in concrete_slice_ble_trans) /=;
        last by apply /andP; split.
      apply /andP; split.
      + by apply hincl.
      by rewrite -(path.sorted_pairwise_in concrete_slice_ble_trans).
    move=> cs'' /andP [cs''_le_cs' cs''_le_ci] /=.
    apply /andP; split=> //.
    by apply hincl.
  case: is_constP => // ofs.
  case: is_constP => // len.
  case: is_constP => // ofs'.
  case: is_constP => // len'.
  case: ifP => // _.
  rewrite ok_ci2.
  eexists; (split; first by reflexivity) => //.
  move=> cs'' /andP [_ cs''_le_ci].
  by apply hincl.
Qed.

(* the only useful lemma, we just need correctness *)
Lemma remove_sub_interval_1 se s cs i ci ci2 off :
  sem_slice se s = ok cs ->
  mapM (sem_slice se) i = ok ci ->
  mapM (sem_slice se) (remove_sub_interval i s) = ok ci2 ->
  offset_in_concrete_interval ci off ->
  ~ offset_in_concrete_slice cs off ->
  offset_in_concrete_interval ci2 off.
Proof.
  move=> ok_cs.
  elim: i ci ci2 => [|s' i ih] ci ci2 /=.
  + by move=> [<-] [<-].
  t_xrbindP=> cs' ok_cs' {}ci ok_ci <- /=.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + move: ok_cs'; rewrite -(symbolic_slice_beqP se heq) ok_cs => -[<-].
    rewrite ok_ci => -[<-].
    by case/orP.
  case: (@idP (odflt _ _)) => [hle|_].
  + by rewrite /= ok_cs' ok_ci /= => -[<-] /=.
  have h:
    mapM (sem_slice se) (s' :: remove_sub_interval i s) = ok ci2 ->
    offset_in_concrete_slice cs' off || offset_in_concrete_interval ci off ->
    ~ offset_in_concrete_slice cs off → offset_in_concrete_interval ci2 off.
  + rewrite /= ok_cs' /=.
    t_xrbindP=> {}ci2 ok_ci2 <-.
    case/orP.
    + by move=> hoff _ /=; apply /orP; left.
    move=> hoff hnoff /=; apply /orP; right.
    by apply (ih _ _ ok_ci ok_ci2 hoff hnoff).
  move: ok_cs ok_cs'; rewrite {1 2}/sem_slice.
  case: is_constP => // ofs.
  case: is_constP => // len.
  case: is_constP => // ofs'.
  case: is_constP => // len'.
  case: ifP => //.
  move=> /= hb ok_cs ok_cs' ok_ci2.
  case/orP.
  + move: ok_cs ok_cs' => [<-] [<-] /= hoff [].
    by apply
      (zbetween_concrete_sliceP
        (cs1 := {| cs_ofs := _ |}) (cs2 := {| cs_ofs := _ |}) hb hoff).
  by apply: ih ok_ci ok_ci2.
Qed.

Lemma wf_status_fill_status se status s cs :
  wf_status se status ->
  sem_slice se s = ok cs ->
  wf_status se (fill_status status s).
Proof.
  move=> hwfs ok_cs.
  rewrite /fill_status.
  case: status hwfs => //= i i_wf.
  case: {1}remove_sub_interval => //= _ _.
  by apply (wf_interval_remove_sub_interval i_wf ok_cs).
Qed.

Lemma wf_status_insert_status se status substatus ofs ofsi len leni x :
  wf_status se status ->
  wf_status se substatus ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  sem_pexpr true [::] se len >>= to_int = ok leni ->
  0 < leni ->
  wf_status se (insert_status x status ofs len substatus).
Proof.
  move=> hwfs hwfs' ok_ofsi ok_leni gt0_leni.
  rewrite /insert_status.
  case: ifP => // _.
  have [cs ok_cs len_cs]:
    exists2 cs,
      sem_slice se {| ss_ofs := ofs; ss_len := len |} = ok cs &
      0 < cs.(cs_len).
  + rewrite /sem_slice ok_ofsi ok_leni /=.
    by eexists; first by reflexivity.
  have ok_cs': sem_zone se [:: {| ss_ofs := ofs; ss_len := len |}] = ok cs.
  + by rewrite /= ok_cs.
  case: ifP => _.
  + by apply (wf_status_fill_status hwfs ok_cs).
  by apply (wf_status_clear_status hwfs ok_cs' len_cs).
Qed.

Require Import seq_extra.

Lemma get_sub_statusP se status s cs off :
  get_sub_status status s ->
  wf_status se status ->
  sem_slice se s = ok cs ->
  offset_in_concrete_slice cs off ->
  valid_offset se status off.
Proof.
  move=> + + ok_cs off_in_cs.
  rewrite /get_sub_status.
  case: status => //= i.
  rewrite /valid_offset_interval.
  elim: i => [|s' i ih] /=.
  + by move=> _ _ _ [<-] /=.
  case: symbolic_slice_beq => //.
  case hle1: (odflt _ _).
  + t_xrbindP=> _ hwf _ cs' ok_cs' ci ok_ci <- /= /orP [off_in_cs'|off_in_ci].
    + have hdisj := symbolic_slice_ble_disjoint hle1 ok_cs ok_cs'.
      by apply (disjoint_concrete_sliceP hdisj off_in_cs off_in_cs').
    move: hwf; rewrite /wf_interval /= ok_cs' ok_ci /=.
    move=> [_ [[<-] hall hsorted]].
    move: hsorted; rewrite (path.sorted_pairwise_in concrete_slice_ble_trans) //=.
    move=> /andP [le_ci _].
    move: hall => /= /andP [/ZltP len_cs' _].
    move: off_in_cs.
    have [cs1 _ /andP[]] := all_has le_ci off_in_ci.
    have := symbolic_slice_bleP hle1 ok_cs ok_cs'.
    rewrite /concrete_slice_ble /offset_in_concrete_slice !zify.
    by lia.
  case hle2: (odflt _ _) => //.
  move=> hget hwf.
  t_xrbindP=> _ cs' ok_cs' ci ok_ci <-.
  have {}hwf: wf_interval se i.
  + move: hwf; rewrite /wf_interval /= ok_cs' ok_ci /=.
    move=> [_ [[<-] hall hsorted]].
    exists ci; split=> //.
    + by move: hall => /= /andP[].
    move: hsorted; rewrite (path.sorted_pairwise_in concrete_slice_ble_trans) //=.
    move=> /andP[] _.
    rewrite -(path.sorted_pairwise_in concrete_slice_ble_trans) //.
    by move: hall => /= /andP[].
  have h := ih hget hwf _ ok_ci.
  move=> /= /orP[] // off_in_cs'.
  have hdisj := symbolic_slice_ble_disjoint hle2 ok_cs' ok_cs.
  by apply (disjoint_concrete_sliceP hdisj off_in_cs' off_in_cs).
Qed.

Lemma valid_offset_insert_status_between se status substatus ofs ofsi len leni x off :
  wf_status se status ->
  wf_status se substatus ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  sem_pexpr true [::] se len >>= to_int = ok leni ->
  ofsi <= off < ofsi + leni ->
  valid_offset se (insert_status x status ofs len substatus) off ->
  valid_offset se substatus (off - ofsi).
Proof.
  move=> hwfs hwfs' ok_ofsi ok_leni hoff.
  rewrite /insert_status.
  case: andP => [|_].
  + move=> [ofs_0 _].
    move: ok_ofsi; rewrite (eq_exprP _ _ _ ofs_0) /= => -[<-].
    by rewrite Z.sub_0_r.
  case: ifP => [|_].
  + (* substatus is valid between 0 and len thanks to get_sub_status.
       We don't need the hyp about fill_status, we drop it. *)
    move=> hstatus _.
    have hslice:
      sem_slice se {| ss_ofs := 0%Z; ss_len := len |} = ok {| cs_ofs := 0%Z; cs_len := leni |}.
    + by rewrite /sem_slice /= ok_leni /=.
    apply (get_sub_statusP hstatus hwfs' hslice).
    rewrite /offset_in_concrete_slice /= !zify.
    by lia.
  (* We clear the status between 0 and len. So the valid_offset hyp is
     contradictory with hoff. *)
  move=> off_valid.
  have hzone:
    sem_zone se [:: {| ss_ofs := ofs; ss_len := len |}] = ok {| cs_ofs := ofsi; cs_len := leni |}.
  + by rewrite /= /sem_slice /= ok_ofsi ok_leni /=.
  have gt0_leni: 0 < leni.
  + by lia.
  have [_ []] := valid_offset_clear_status hwfs hzone gt0_leni off_valid.
  by rewrite /offset_in_concrete_slice /= !zify.
Qed.

Lemma valid_offset_fill_status se s cs status off :
  wf_status se status ->
  sem_slice se s = ok cs ->
  valid_offset se (fill_status status s) off ->
  ~ offset_in_concrete_slice cs off ->
  valid_offset se status off.
Proof.
  case: status => //= i i_wf ok_cs.
  have [ci [ok_ci _ _]] := i_wf.
  have [ci2 [ok_ci2 _ _]] := wf_interval_remove_sub_interval i_wf ok_cs.
  case heq: {1}(remove_sub_interval i s) => /=.
  + move=> _.
    rewrite /valid_offset_interval ok_ci => off_nin_cs _ [<-] off_in_ci.
    have := remove_sub_interval_1 ok_cs ok_ci ok_ci2 off_in_ci off_nin_cs.
    by move: ok_ci2; rewrite heq /= => -[<-] /=.
  rewrite /valid_offset_interval ok_ci ok_ci2
    => /(_ _ erefl) off_nin_ci2 off_nin_cs _ [<-] off_in_ci.
  apply off_nin_ci2.
  by apply (remove_sub_interval_1 ok_cs ok_ci ok_ci2 off_in_ci off_nin_cs).
Qed.

Lemma valid_offset_insert_status_disjoint se status substatus ofs ofsi len leni x off :
  wf_status se status ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  sem_pexpr true [::] se len >>= to_int = ok leni ->
  0 < leni ->
  0 <= off /\ off < size_slot x ->
  ~ ofsi <= off < ofsi + leni ->
  valid_offset se (insert_status x status ofs len substatus) off ->
  valid_offset se status off.
Proof.
  move=> hwfs ok_ofsi ok_leni gt0_leni hoff hnoff.
  rewrite /insert_status.
  case: andP => [|_].
  + move=> [eq_ofs eq_len].
    move: ok_ofsi ok_leni.
    rewrite (eq_exprP _ _ _ eq_ofs) (eq_exprP _ _ _ eq_len) /= => -[?] [?].
    lia.
  have hslice:
    sem_slice se {| ss_ofs := ofs; ss_len := len |} = ok {| cs_ofs := ofsi; cs_len := leni |}.
  + by rewrite /sem_slice /= ok_ofsi ok_leni /=.
  case: ifP => _.
  + move=> off_valid.
    apply (valid_offset_fill_status hwfs hslice off_valid).
    by rewrite /offset_in_concrete_slice /= !zify.
  move=> off_valid.
  have hzone:
    sem_zone se [:: {| ss_ofs := ofs; ss_len := len |}] = ok {| cs_ofs := ofsi; cs_len := leni |}.
  + by rewrite /= hslice.
  by case: (valid_offset_clear_status hwfs hzone gt0_leni off_valid).
Qed.

Lemma sub_region_status_at_ofs_addr se sr ty ofs ofsi ty2 x status :
  wf_sub_region se sr ty ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  sub_region_addr se (sub_region_status_at_ofs x sr status ofs (size_of ty2)).1 =
    sub_region_addr se (sub_region_at_ofs sr ofs (size_of ty2)).
Proof.
  move=> hwf ok_ofsi hofsi.
  rewrite /sub_region_status_at_ofs.
  case: andP => [|//] /=.
  move=> [ofs_0 _].
  have [cs ok_cs _] := hwf.(wfsr_zone).
  have [addr haddr _] := wunsigned_sub_region_addr hwf ok_cs.
  rewrite (sub_region_addr_offset hwf ok_ofsi hofsi haddr).
  move: ok_ofsi; rewrite (eq_exprP _ _ _ ofs_0) /= => -[<-].
  by rewrite wrepr0 GRing.addr0.
Qed.

(* Note that we assume [eq_sub_region_val_read] only on the (sub-)sub-region
   [(sub_region_status_at_ofs x srx statusx ofs len').1].
   We do not need it for the full sub-region [srx], since we can derive it for
   the rest of [srx] from the [valid_state] hypothesis. *)
Lemma valid_state_set_move_sub table rmap se m0 s1 s2 (x:var_i) srx pk substatus e' e aa ws len v s1' :
  valid_state table rmap se m0 s1 s2 ->
  Mvar.get rmap.(var_region) x = Some srx ->
  get_local pmap x = Some pk ->
  wf_status se substatus ->
  (forall z, sem_pexpr true gd s1 e >>= to_int = ok z -> sem_pexpr true [::] se e' >>= to_int = ok z) ->
  write_lval true gd (Lasub aa ws len x e) v s1 = ok s1' ->
  let ofs := mk_ofs_int aa ws e' in
  let len' := Pconst (arr_size ws len) in
  let statusx := get_var_status rmap srx.(sr_region) x in
  eq_sub_region_val_read se s2.(emem) (sub_region_status_at_ofs x srx statusx ofs len').1 substatus v ->
  valid_state (remove_binding table x)
    (set_move_sub rmap srx.(sr_region) x statusx ofs len' substatus)
    se m0 s1' s2.
Proof.
  move=> hvs hsrx hlx hwfs' heq_int hwrite ofs len' statusx hread.
  have /wfr_wf hwfx := hsrx.
  have hwfsx: wf_status se statusx.
  + by apply (get_var_status_wf_status _ _ wfr_status).
  move: hwrite => /=.
  apply: on_arr_varP;
    t_xrbindP=> nx ax htyx hgetx i vi ok_vi ok_i av /to_arrI ? ax' ok_ax'
      /write_varP [-> hdb htr]; subst v.
  move: heq_int; rewrite ok_vi /= ok_i => /(_ _ erefl) ok_i'.
  have ok_ofsi: sem_pexpr true [::] se ofs >>= to_int = ok (i * mk_scale aa ws).
  + by rewrite (mk_ofs_intP aa ws ok_i').
  have ok_leni: sem_pexpr true [::] se len' >>= to_int = ok (arr_size ws len).
  + by [].
  have gt0_leni := gt0_arr_size ws len.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft hwfr heqmem hglobv htop.
  constructor => //=.
  + move=> y hgety; rewrite Vm.setP_neq; first by apply heqvm.
    by apply/eqP; rewrite /get_local in hlx; congruence.
  + by apply wf_table_set_var.
  case: (hwfr) => hwfsr hwfst hval hptr; split=> //.
  + move /wfr_STATUS_alt in hwfst; apply wfr_STATUS_alt.
    move=> ry y /=.
    rewrite get_var_status_set_move_status.
    case: eqP => //= _.
    case: eqP => //= _.
    by apply (wf_status_insert_status x hwfsx hwfs' ok_ofsi ok_leni gt0_leni).
  + move=> y sry statusy vy /=.
    move=> /(check_gvalid_set_move_sub hsrx) [].
    + move=> [hnglob heq -> ->].
      rewrite heq get_gvar_eq // -heq //= htyx eq_refl => -[<-].
      split=> // off addr w haddr off_valid /[dup] /get_val_byte_bound /= hb.
      rewrite (WArray.set_sub_get8 ok_ax') /=.
      case: ifPn; rewrite !zify => hoff.
      + have ->:
          (addr + wrepr Uptr off =
            addr + wrepr _ (i * mk_scale aa ws) + wrepr _ (off - i * mk_scale aa ws))%R.
        + by rewrite wrepr_sub -GRing.addrA (GRing.addrC (wrepr _ _)) GRing.subrK.
        apply hread.
        + have ->: len' = size_of (sarr (Z.to_pos (arr_size ws len))).
          + by rewrite /= Z2Pos.id //.
          have hbound: 
            0 <= i * mk_scale aa ws /\ i * mk_scale aa ws + size_of (sarr (Z.to_pos (arr_size ws len))) <= size_slot x.
          + rewrite htyx /= Z2Pos.id //.
            by apply (WArray.set_sub_bound ok_ax').
          rewrite (sub_region_status_at_ofs_addr _ _ hwfx ok_ofsi hbound).
          by apply (sub_region_addr_offset hwfx ok_ofsi hbound haddr).
        apply: (valid_offset_insert_status_between hwfsx hwfs' ok_ofsi ok_leni _ off_valid).
        by lia.
      have hgvalidx := check_gvalid_lvar hsrx.
      have /wfr_val -/(_ _ hgetx) [{}hread _] := hgvalidx.
      apply hread => //.
      apply: (valid_offset_insert_status_disjoint hwfsx ok_ofsi ok_leni gt0_leni _ _ off_valid).
      + by rewrite htyx /=.
      by lia.
    by move=> [? hgvalid]; rewrite get_gvar_neq => //; apply hval.
  move=> y sry /=.
  move=> /hptr [pky [hly hpky]].
  exists pky; split=> //.
  case: pky hly hpky => //=.
  move=> s ofs' ws' cs f hly heq.
  rewrite /check_stack_ptr get_var_status_set_move_status.
  case: eqP => // _; case: eqP => //=.
  have /wf_vnew := hlx.
  by have /wf_locals /wfs_new := hly; congruence.
Qed.

(* ------------------------------------------------------------------ *)

(* FIXME: move *)
Require Import stack_alloc_params.

(* FIXME: should sap_mov_ofs takes an offset as argument. It is a pexpr.
   Should it be of type int or of type word Uptr? For now, it is a word Uptr. *)
Record h_stack_alloc_params (saparams : stack_alloc_params) :=
  {
    (* [mov_ofs] must behave as described in stack_alloc.v. *)
    mov_ofsP :
      forall (P' : sprog) ev s1 e i ofs pofs x tag vpk ins s2,
        p_globs P' = [::]
        -> sem_pexpr true [::] s1 e >>= to_pointer = ok i
        -> sem_pexpr true [::] s1 ofs >>= to_pointer = ok pofs
        -> sap_mov_ofs saparams x tag vpk e ofs = Some ins
        -> write_lval true [::] x (Vword (i + pofs)) s1 = ok s2
        -> exists2 vm2, sem_i P' ev s1 ins (with_vm s2 vm2) & evm s2 =1 vm2;
    (* specification of sap_immediate *)
    sap_immediateP :
      forall (P' : sprog) w s (x: var_i) z,
        vtype x = sword Uptr ->
        sem_i P' w s (sap_immediate saparams x z)
          (with_vm s (evm s).[x <- Vword (wrepr Uptr z)]);
    sap_swapP : 
      forall (P' : sprog) rip s tag (x y z w : var_i) (pz pw: pointer), 
        vtype x = spointer -> vtype y = spointer -> 
        vtype z = spointer -> vtype w = spointer -> 
        (evm s).[z] = Vword pz ->
        (evm s).[w] = Vword pw -> 
        sem_i P' rip s (sap_swap saparams tag x y z w)
             (with_vm s ((evm s).[x <- Vword pw]).[y <- Vword pz])
  }.

Context
  (shparams : slh_lowering.sh_params)
  (hshparams : slh_lowering_proof.h_sh_params shparams)
  (saparams : stack_alloc_params)
  (hsaparams : h_stack_alloc_params saparams).

(* ------------------------------------------------------------------ *)

Lemma valid_state_vm_eq s2 vm2 table rmap se mem s1 :
  (evm s2 =1 vm2)%vm ->
  valid_state table rmap se mem s1 s2 ->
  valid_state table rmap se mem s1 (with_vm s2 vm2).
Proof.
  move=> heq [hscs hsl hdisj hincl hincl' hunch hrip hrsp heqvm hwft hwfr heqsource hbetw htop].
  constructor => //=.
  1,2: by rewrite -heq.
  + by move=> ???; rewrite -heq; apply heqvm.
  case: hwfr => hwfsr hwfst hV hP; constructor => //.
  move=> x sr /hP [pk [hgl hv]]; exists pk; split => //.
  by case: (pk) hv => //= >; rewrite heq.
Qed.

(* TODO: move? *)
Context
  (fresh_var_ident : v_kind -> PrimInt63.int -> string -> stype -> Ident.ident)
  (string_of_sr : sub_region -> string).

Local Lemma clone_ty : forall x n, vtype (clone fresh_var_ident x n) = vtype x.
Proof. by []. Qed.

Lemma sub_region_beq_eq_sub_region_val sr1 sr2 ty se m2 status v :
  sub_region_beq sr1 sr2 ->
  eq_sub_region_val ty se m2 sr1 status v ->
  eq_sub_region_val ty se m2 sr2 status v.
Proof.
  move=> heqsub [hread hty]; split=> // off addr w.
  rewrite -(sub_region_beq_addr se heqsub).
  by apply hread.
Qed.

Lemma sub_region_status_at_ofs_wf se sr ty ofs ofsi ty2 x status sr' status' :
  wf_sub_region se sr ty ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  0 <= ofsi /\ ofsi + size_of ty2 <= size_of ty ->
  sub_region_status_at_ofs x sr status ofs (size_of ty2) = (sr', status') ->
  wf_sub_region se sr' ty2.
Proof.
  move=> hwf ok_ofsi hofsi.
  rewrite /sub_region_status_at_ofs.
  case: andP => [|_] /=.
  + move=> [_ /eqP heq] [<- _].
    apply: wf_sub_region_size_of hwf.
    by lia.
  move=> [<- _].
  by apply (sub_region_at_ofs_wf hwf ok_ofsi hofsi).
Qed.

Lemma sub_region_status_at_ofs_wf_status se status x sr ofs len sr' status' :
  wf_status se status ->
  sub_region_status_at_ofs x sr status ofs len = (sr', status') ->
  wf_status se status'.
Proof.
  move=> hwfs.
  rewrite /sub_region_status_at_ofs.
  case: andP => _.
  + by move=> [_ <-].
  move=> [_ <-].
  by case: ifP => _.
Qed.

Lemma valid_offset_sub_region_status_at_ofs se ofs ofsi len leni x sr status sr' status' off :
  wf_status se status ->
  sem_pexpr true [::] se ofs >>= to_int = ok ofsi ->
  sem_pexpr true [::] se len >>= to_int = ok leni ->
  0 <= off < leni ->
  sub_region_status_at_ofs x sr status ofs len = (sr', status') ->
  valid_offset se status' off ->
  valid_offset se status (ofsi + off).
Proof.
  move=> hwfs ok_ofsi ok_leni hoff.
  rewrite /sub_region_status_at_ofs.
  case: andP => [|_].
  + move=> [ofs_0 _] [_ <-].
    by move: ok_ofsi; rewrite (eq_exprP _ _ _ ofs_0) /= => -[<-].
  move=> [_ <-].
  case: ifP => // hget _.
  have ok_cs:
    sem_slice se {| ss_ofs := ofs; ss_len := len |} = ok {| cs_ofs := ofsi; cs_len := leni |}.
  + by rewrite /sem_slice ok_ofsi ok_leni /=.
  apply (get_sub_statusP hget hwfs ok_cs).
  rewrite /offset_in_concrete_slice /= !zify.
  by lia.
Qed.

Lemma alloc_array_moveP se m0 s1 s2 s1' table1 rmap1 table2 rmap2 r tag e v v' n i2 :
  valid_state table1 rmap1 se m0 s1 s2 ->
  sem_pexpr true gd s1 e = ok v ->
  truncate_val (sarr n) v = ok v' ->
  write_lval true gd r v' s1 = ok s1' ->
  alloc_array_move saparams fresh_var_ident string_of_sr pmap table1 rmap1 r tag e = ok (table2, rmap2, i2) →
  ∃ (s2' : estate) (vme : Vm.t), [/\
    sem_i P' rip s2 i2 s2',
    valid_state (remove_binding_lval table2 r) rmap2 (with_vm se vme) m0 s1' s2' &
    se.(evm) <=1 vme].
Proof.
  move=> hvs he /truncate_val_typeE[] a ?? hw; subst v v'.
  rewrite /alloc_array_move.
  t_xrbindP=> -[[[[[table1' sry] statusy] mk] ey] ofsy] He.

  have: exists vme wey wofsy, [/\
    se.(evm) <=1 vme,
    wf_table table1' (with_vm se vme) s1.(evm),
    wf_sub_region (with_vm se vme) sry (sarr n),
    wf_status (with_vm se vme) statusy,
    sem_pexpr true [::] s2 ey >>= to_pointer = ok wey,
    sem_pexpr true [::] s2 ofsy >>= to_pointer = ok wofsy,
    sub_region_addr (with_vm se vme) sry = ok (wey + wofsy)%R &
    eq_sub_region_val (sarr n) (with_vm se vme) (emem s2) sry statusy (Varr a)].
  + case: e he He => //=.
    + t_xrbindP=> y hgety vpky hkindy.
      case: vpky hkindy => [vpky|//] hkindy.
      t_xrbindP=> -[sry' statusy'] /(get_gsub_region_statusP hkindy) hgvalidy.
      assert (hwfy := check_gvalid_wf wfr_wf hgvalidy).
      have hwfpky := get_var_kind_wf hkindy.
      have /wfr_gptr := hgvalidy.
      rewrite hkindy => -[_ [[<-] hpky]].
      t_xrbindP=> -[ey' ofsy'] haddr <- <- <- _ <- <-.
      have [wey ok_wey haddry] :=
        addr_from_vpk_pexprP true hvs hwfpky hpky hwfy haddr.
      exists se.(evm), wey, (wrepr Uptr ofsy'); split=> //.
      + rewrite with_vm_same.
        by apply hvs.(vs_wf_table).
      + rewrite with_vm_same.
        by rewrite -(type_of_get_gvar_array hgety).
      + rewrite with_vm_same.
        by apply (check_gvalid_wf_status wfr_status hgvalidy).
      + by rewrite /= truncate_word_u.
      + by rewrite with_vm_same.
      rewrite with_vm_same.
      assert (hval := wfr_val hgvalidy hgety).
      by rewrite -(type_of_get_gvar_array hgety).
    move=> aa ws len y e.
    apply: on_arr_gvarP => ny ay hyty hgety.
    apply: rbindP=> i ok_i.
    apply: rbindP=> a' ok_a /ok_inj /Varr_inj [?]; subst n => /= ?; subst a.
    t_xrbindP=> vpky hkindy.
    case: vpky hkindy => [vpky|//] hkindy.
    t_xrbindP=> -[sry' statusy'] /(get_gsub_region_statusP hkindy) hgvalidy.
    t_xrbindP=> -[table1'' e1] /o2rP hsym.
    case hsub: sub_region_status_at_ofs => [sry'' statusy''].
    t_xrbindP=> -[ey' ofsy'] haddr e' halloc <- <- <- _ <- <- /=.
    have [vme [hwft huincl hsem]] :=
      wf_table_symbolic_of_pexpr clone_ty hsym hvs.(vs_wf_table).
    have {}hvs := valid_state_vm_uincl huincl hwft hvs.
    have /= hwfy := [elaborate check_gvalid_wf wfr_wf hgvalidy].
    have /= hwfsy := [elaborate check_gvalid_wf_status wfr_status hgvalidy].
    have hwfpky := get_var_kind_wf hkindy.
    have /wfr_gptr := hgvalidy.
    rewrite hkindy => -[_ [[<-] hpky]].
    have [wey ok_wey haddry] :=
      addr_from_vpk_pexprP true hvs hwfpky hpky hwfy haddr.
    move: ok_i; t_xrbindP=> vi ok_vi ok_i.
    have ok_i': sem_pexpr true [::] s2 e' >>= to_int = ok i.
    + have htr: truncate_val sint vi = ok (Vint i).
      + by rewrite /truncate_val /= ok_i /=.
      have [vi' [-> +]] := alloc_eP hvs halloc ok_vi htr.
      by rewrite /truncate_val /=; t_xrbindP=> i' -> <-.
    have ok_i'': sem_pexpr true [::] (with_vm se vme) e1 >>= to_int = ok i.
    + have [vi1 ok_vi1 incl_vi1] := hsem _ _ ok_vi.
      have /= ok_i'' := of_value_uincl_te (ty:=sint) incl_vi1 ok_i.
      by rewrite ok_vi1 /= ok_i''.
    have hint:
      sem_pexpr true [::] (with_vm se vme) (mk_ofs_int aa ws e1) >>= to_int = ok (i * mk_scale aa ws).
    + by rewrite (mk_ofs_intP aa ws ok_i'').
    have gt0_leni := gt0_arr_size ws len.
    have hbound:
      0 <= i * mk_scale aa ws /\ i * mk_scale aa ws + size_of (sarr (Z.to_pos (arr_size ws len))) <= size_slot y.(gv).
    + rewrite hyty /= Z2Pos.id //.
      by apply (WArray.get_sub_bound ok_a).
    have haddry': sub_region_addr (with_vm se vme) sry'' = ok (wey + wrepr Uptr (i * mk_scale aa ws + ofsy'))%R.
    + have := sub_region_addr_offset hwfy hint hbound haddry.
      rewrite -(sub_region_status_at_ofs_addr y.(gv) statusy' hwfy hint hbound) /= Z2Pos.id // hsub.
      by rewrite -GRing.addrA -wrepr_add Z.add_comm.
    exists vme, wey, (wrepr Uptr (i * mk_scale aa ws + ofsy')); split=> //.
    + move: hsub; rewrite -{1}(Z2Pos.id (arr_size ws len)) // => hsub.
      by apply (sub_region_status_at_ofs_wf hwfy hint hbound hsub).
    + by apply (sub_region_status_at_ofs_wf_status hwfsy hsub).
    + by rewrite (mk_ofsP aa ws ofsy' ok_i') /= truncate_word_u.
    split=> // off addr w.
    rewrite haddry' => -[<-] off_valid ok_w.
    rewrite Z.add_comm wrepr_add GRing.addrA -(GRing.addrA (_ + _)%R _) -wrepr_add.
    have /wfr_val -/(_ _ hgety) [hread _] := hgvalidy.
    apply (hread _ _ _ haddry).
    + apply: (valid_offset_sub_region_status_at_ofs (leni:=arr_size ws len)
        hwfsy hint _ _ hsub off_valid) => //.
      have /get_val_byte_bound := ok_w.
      by rewrite /= Z2Pos.id.
    move: ok_w; rewrite /= (WArray.get_sub_get8 ok_a) /=.
    by case: ifP.

  move=> [vme [wey [wofsy [huincl hwft hwfy hwfsy ok_wey ok_wofsy haddry heqvaly]]]].

  have {}hvs: valid_state table1' rmap1 (with_vm se vme) m0 s1 s2.
  + case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwft' hwfr heqmem hglobv htop.
    split=> //.
    by apply wf_rmap_vm_uincl.

  case: r hw => //.
  + move=> x /write_varP [ -> hdb h].
    have /vm_truncate_valE [hty htreq]:= h.
    case hlx: (get_local pmap x) => [pk|//].
    have /wf_locals hlocal := hlx.
    rewrite -hty in hwfy.
    rewrite -hty -htreq in heqvaly.

    case: pk hlx hlocal.
    + t_xrbindP=> s ofs' ws z sc hlx hlocal heqsub <- <- <-.
      exists s2, vme; split=> //; first by constructor.
      (* valid_state update *)
      by apply: (valid_state_set_move hvs hwfy hwfsy hlx heqsub h heqvaly).

    + move=> p hlx hlocal.
      rewrite /get_addr.
      case Hmov_ofs: (sap_mov_ofs saparams) => [ins| //].
      move=> /= [<- <- <-].
      have /(_ (with_vm s2 (evm s2).[p <- Vword (wey + wofsy)])) []:=
        mov_ofsP hsaparams rip P'_globs ok_wey ok_wofsy Hmov_ofs.
      + by rewrite /= write_var_eq_type //= hlocal.(wfr_rtype).
      move=> /= vm2 hsem heq1.
      exists (with_vm s2 vm2), vme; split => //.
      (* valid_state update *)
      apply (@valid_state_vm_eq (with_vm s2 (evm s2).[p <- Vword (wey + wofsy)]) vm2) => //.
      by apply (valid_state_set_move_regptr hvs hwfy haddry hwfsy hlx h heqvaly).

    move=> s ofs' ws z f hlx hlocal hi2 /=.
    case: ifP hi2.
    + rewrite /is_nop.
      case heq: Mvar.get => [srx|//] /andP [heqsub hcheck] [<- <- <-].
      (* interestingly, hcheck is not needed for the proof *)
      exists s2, vme; split=> //; first by constructor.
      apply: (valid_state_set_move hvs hwfy hwfsy hlx _ h heqvaly).
      move=> /= hcheck' paddr addry hpaddr haddry'.
      have /wfr_ptr := heq; rewrite hlx => -[_ [[<-] hpk]]; apply hpk => //.
      by rewrite (sub_region_beq_addr _ heqsub).
    move=> _.
    rewrite /get_addr.
    case Hmov_ofs: (sap_mov_ofs saparams) => [ins| //].
    move=> /= [<- <- <-].
    have hwf := sub_region_stkptr_wf (with_vm se vme) hlocal.
    have [cs ok_cs _] := hwf.(wfsr_zone).
    have [paddr hpaddr _] := wunsigned_sub_region_addr hwf ok_cs.
    have hvp: validw (emem s2) Aligned paddr Uptr.
    + have hofs: 0 <= 0 /\ wsize_size Uptr <= size_of (sword Uptr) by move=> /=; lia.
      have := validw_sub_region_addr_ofs hvs hwf hpaddr hofs.
      rewrite wrepr0 GRing.addr0; apply.
      by apply (is_align_sub_region_stkptr hlocal hpaddr).
    have /writeV -/(_ (wey + wofsy)%R) [mem2 hmem2] := hvp.
    have /(_ (with_mem s2 mem2)) []:=
      mov_ofsP hsaparams rip P'_globs ok_wey ok_wofsy Hmov_ofs.
    + rewrite /= /get_var vs_rsp /= !truncate_word_u /=.
      move: hpaddr; rewrite (sub_region_addr_stkptr _ hlocal) => -[->].
      by rewrite hmem2.
    move=> vm2 hsem heq1.
    exists (with_vm (with_mem s2 mem2) vm2), vme; split => //.
    apply valid_state_vm_eq => //.
    apply: (valid_state_set_stack_ptr hvs hwfy haddry hwfsy hlx hpaddr _ _ _ _ h heqvaly).
    + by apply (Memory.write_mem_stable hmem2).
    + by move=> ??; apply (write_validw_eq hmem2).
    + by move=> ??? /disjoint_range_alt; apply (writeP_neq _ hmem2).
    by rewrite (writeP_eq hmem2).

  (* interestingly, we can prove that n = Z.to_pos len = Z.to_pos (arr_size ws len2)
     but it does not seem useful
  *)
  move=> aa ws len2 x e' hw.
  case hlx: (get_local pmap x) => [pk|//].
  t_xrbindP=> -[srx statusx] /get_sub_region_statusP [hsrx ->].
  t_xrbindP=> -[table1'' e1] /o2rP hsym.
  case hsub: sub_region_status_at_ofs => [srx' statusx'].
  t_xrbindP=> heqsub <- <- <-.
  have [vme' [hwft'' huincl' hsem]] :=
    wf_table_symbolic_of_pexpr clone_ty hsym hwft.
  exists s2, vme'; split=> /=; first by constructor.
  + have {}hvs := valid_state_vm_uincl huincl' hwft'' hvs.
    have heq_int:
      forall z,
        sem_pexpr true gd s1 e' >>= to_int = ok z ->
        sem_pexpr true [::] (with_vm se vme') e1 >>= to_int = ok z.
    + t_xrbindP=> z vz ok_vz ok_z.
      have := hsem _ _ ok_vz; rewrite with_vm_idem => -[vz' -> hincl] /=.
      by apply (of_value_uincl_te (ty:=sint) hincl ok_z).
    have heqvalx: eq_sub_region_val (sarr n) (with_vm se vme') (emem s2) srx' statusy (Varr a).
    + apply (sub_region_beq_eq_sub_region_val heqsub).
      by apply (eq_sub_region_val_vm_uincl huincl').
    apply: (valid_state_set_move_sub hvs hsrx hlx _ heq_int hw).
    + by apply wf_status_vm_uincl.
    rewrite hsub.
    by case: heqvalx => [hread _].
  by apply (vm_uinclT huincl huincl').
Qed.

Lemma is_protect_ptr_failP rs o es r e msf :
  is_protect_ptr_fail rs o es = Some(r, e, msf) ->
  [/\ exists sz, o = Oslh (SLHprotect_ptr_fail sz),
      rs = [:: r] &
      es = [:: e; msf]].
Proof.
  case: o rs es => //= -[] // sz [ | r' []] // [ | e' [ | msf' []]] // [-> -> ->].
  by split => //; exists sz.
Qed.

(* The proof mostly consists in copied parts of alloc_array_moveP. *)
Lemma alloc_protect_ptrP table se m0 s1 s2 s1' rmap1 rmap2 ii r tag e msf vmsf v v' n i2 :
  valid_state table rmap1 se m0 s1 s2 ->
  sem_pexpr true gd s1 e = ok v ->
  sem_pexpr true gd s1 msf = ok vmsf ->
  truncate_val ty_msf vmsf = ok (@Vword msf_size 0%R) ->
  truncate_val (sarr n) v = ok v' ->
  write_lval true gd r v' s1 = ok s1' ->
  alloc_protect_ptr shparams pmap rmap1 ii r tag e msf = ok (rmap2, i2) ->
  ∃ s2' : estate, sem_i P' rip s2 i2 s2' ∧ valid_state (remove_binding_lval table r) rmap2 se m0 s1' s2'.
Proof.
  move=> hvs he hmsf htr; rewrite /truncate_val /=.
  t_xrbindP=> a /to_arrI ? ? hw; subst v v'.
  rewrite /alloc_protect_ptr.
  t_xrbindP=> -[[sry statusy] ey] He.

  have: exists wey, [/\
    wf_sub_region se sry (sarr n),
    wf_status se statusy,
    sem_pexpr true [::] s2 ey >>= to_pointer = ok wey,
    sub_region_addr se sry = ok wey &
    eq_sub_region_val (sarr n) se (emem s2) sry statusy (Varr a)].
  + case: e he He => //=.
    t_xrbindP=> y hgety vpky hkindy.
    case: vpky hkindy => [vpky|//] hkindy.
    t_xrbindP=> hvpky -[sry' statusy'] /(get_gsub_region_statusP hkindy) hgvalidy.
    assert (hwfy := check_gvalid_wf wfr_wf hgvalidy).
    have hwfpky := get_var_kind_wf hkindy.
    have /wfr_gptr := hgvalidy.
    rewrite hkindy => -[_ [[<-] hpky]].
    t_xrbindP=> -[ey' ofsy'] haddr [<- <- <-].
    have [wey ok_wey haddry] :=
      addr_from_vpk_pexprP true hvs hwfpky hpky hwfy haddr. 
    exists wey; split=> //.
    + by rewrite -(type_of_get_gvar_array hgety).
    + by apply (check_gvalid_wf_status wfr_status hgvalidy).
    + move: haddry.
      have ->: ofsy' = 0.
      + by case: (vpky) hvpky haddr => // -[] //= ? _ [] _ <-.
      by rewrite wrepr0 GRing.addr0.
    assert (hval := wfr_val hgvalidy hgety).
    by rewrite -(type_of_get_gvar_array hgety).

  move=> [wey [hwfy hwfsy ok_wey haddry heqvaly]].

  case: r hw => //.
  move=> x /write_varP [-> hdb h].
  have /vm_truncate_valE [hty htreq]:= h.
  case hlx: (get_local pmap x) => [pk|//].
  have /wf_locals hlocal := hlx.
  rewrite -hty in hwfy.
  rewrite -hty -htreq in heqvaly.

  case: pk hlx hlocal => //.
  move=> p hlx hlocal.
  t_xrbindP=> msf' hmsf' i hi <- <-.
  exists (with_vm s2 s2.(evm).[p <- Vword wey]); split; last first.
  + by apply (valid_state_set_move_regptr hvs hwfy haddry hwfsy hlx h heqvaly).
  move: hi; rewrite /lower_protect_ptr_fail /slh_lowering.lower_slho /=.
  case heq: slh_lowering.shp_lower => [ [[xs o] es] | //] [<-].

  move: ok_wey; t_xrbindP=> vey ok_vey ok_wey.
  have [vmsf' [ok_vmsf' htr']] := alloc_eP hvs hmsf' hmsf htr.
  have hto: to_word msf_size vmsf' = ok 0%R.
  + by move: htr'; rewrite /truncate_val /=; t_xrbindP=> _ -> ->.
  constructor; rewrite /= P'_globs.
  apply
    (slh_lowering_proof.hshp_spec_lower hshparams
      (args := [:: vey; vmsf']) (res := [:: Vword wey]) heq).
  + by eexists; first by reflexivity.
  + by rewrite /= ok_vey ok_vmsf' /=.
  + by rewrite /exec_sopn /= ok_wey hto /=.
  rewrite /= write_var_truncate //.
  apply subtype_truncatable.
  rewrite /= hlocal.(wfr_rtype).
  by apply subtype_refl.
Qed.

Lemma is_swap_arrayP o : 
  reflect (exists n,  o = Opseudo_op (pseudo_operator.Oswap (sarr n))) (is_swap_array o).
Proof.
  case: o => /=; try by constructor => -[].
  case => /=; try by constructor => -[].
  move=> s; case: is_sarrP => h; constructor.
  + by case: h => n ->; eauto.
  move=> [n []] heq; apply h; eauto.
Qed.

Lemma get_regptrP x p :
  get_regptr pmap x = ok p ->
  Mvar.get pmap.(locals) x = Some (Pregptr p).
Proof. by rewrite /get_regptr; case heq: get_local => [[]|] // [<-]. Qed.

Lemma alloc_array_swapP table m0 se s1 s2 s1' rmap1 rmap2 n xs tag es va vs i2:
  valid_state table rmap1 se m0 s1 s2 ->
  sem_pexprs true gd s1 es = ok va -> 
  exec_sopn (Opseudo_op (pseudo_operator.Oswap (sarr n))) va = ok vs -> 
  write_lvals true gd s1 xs vs = ok s1' -> 
  alloc_array_swap saparams pmap rmap1 xs tag es = ok (rmap2, i2) ->
  ∃ s2' : estate, sem_i P' rip s2 i2 s2' ∧ valid_state (foldl remove_binding_lval table xs) rmap2 se m0 s1' s2'.
Proof.
  move=> hvs.
  rewrite /alloc_array_swap.
  case: xs => // -[] // x [] // [] // y [] //.
  case: es => // -[] // z [] // [] // w [] //=.
  t_xrbindP => vz hz _ vw hw <- <-.
  rewrite /exec_sopn /= /sopn_sem /= /swap_semi; t_xrbindP.
  move=> _ tz /to_arrI hvz tw /to_arrI hvw <- <- /=; t_xrbindP; subst vz vw.
  move=> _ /write_varP [-> _ /[dup] hxtr /vm_truncate_valE [hxty hxtr']].
  move=> _ /write_varP [-> _ /[dup] hytr /vm_truncate_valE [hyty hytr']].
  rewrite with_vm_idem /= => ?; subst s1'.
  move=> pz /get_regptrP hpz [srz _] /get_sub_region_statusP [hsrz ->].
  t_xrbindP.
  move=> pw /get_regptrP hpw [srw _] /get_sub_region_statusP [hsrw ->].
  t_xrbindP.
  move=> px /get_regptrP hpx py /get_regptrP hpy /andP [xloc yloc] <- <-.

  have hzty := type_of_get_gvar_array hz.
  have /wfr_wf hwfz := hsrz.
  have [csz ok_csz _] := hwfz.(wfsr_zone).
  have [addrz ok_addrz _] := wunsigned_sub_region_addr hwfz ok_csz.
  have := check_gvalid_lvar hsrz;
    (rewrite mk_lvar_nglob; last by apply /negP; rewrite -is_lvar_is_glob) => hgvalidz.
  have hwfsz := [elaborate check_gvalid_wf_status wfr_status hgvalidz].
  have /wfr_ptr := hsrz; rewrite /get_local hpz => -[_ [[<-] /= hpkz]].
  assert (heqvalz := wfr_val hgvalidz hz).
  rewrite hzty -hyty in hwfz.
  rewrite hzty -hyty -hytr' in heqvalz.

  have hwty := type_of_get_gvar_array hw.
  have /wfr_wf hwfw := hsrw.
  have [csw ok_csw _] := hwfw.(wfsr_zone).
  have [addrw ok_addrw _] := wunsigned_sub_region_addr hwfw ok_csw.
  have := check_gvalid_lvar hsrw;
    (rewrite mk_lvar_nglob; last by apply /negP; rewrite -is_lvar_is_glob) => hgvalidw.
  have hwfsw := [elaborate check_gvalid_wf_status wfr_status hgvalidw].
  have /wfr_ptr := hsrw; rewrite /get_local hpw => -[_ [[<-] /= hpkw]].
  assert (heqvalw := wfr_val hgvalidw hw).
  rewrite hwty -hxty in hwfw.
  rewrite hwty -hxty -hxtr' in heqvalw.

  set s2' := with_vm s2 (evm s2).[px <- Vword addrw].
  set s2'' := with_vm s2' (evm s2').[py <- Vword addrz].
  exists s2''; split.
  + apply: hsaparams.(sap_swapP).
    + by apply: (wf_locals hpx).(wfr_rtype).
    + by apply: (wf_locals hpy).(wfr_rtype).
    + by apply: (wf_locals hpz).(wfr_rtype).
    + by apply: (wf_locals hpw).(wfr_rtype).
    + by apply (hpkz _ ok_addrz).
    by apply (hpkw _ ok_addrw).
  have hvs' := valid_state_set_move_regptr hvs hwfw ok_addrw hwfsw hpx hxtr heqvalw.
  have := valid_state_set_move_regptr hvs' hwfz ok_addrz hwfsz hpy hytr heqvalz.
  by rewrite /= with_vm_idem.
Qed.

Lemma alloc_array_move_initP se m0 s1 s2 s1' table1 table2 rmap1 rmap2 r tag e v v' n i2 :
  valid_state table1 rmap1 se m0 s1 s2 ->
  sem_pexpr true gd s1 e = ok v ->
  truncate_val (sarr n) v = ok v' ->
  write_lval true gd r v' s1 = ok s1' ->
  alloc_array_move_init saparams fresh_var_ident string_of_sr pmap table1 rmap1 r tag e = ok (table2, rmap2, i2) →
  ∃ (s2' : estate) vme, [/\
    sem_i P' rip s2 i2 s2',
    valid_state (remove_binding_lval table2 r) rmap2 (with_vm se vme) m0 s1' s2' &
    se.(evm) <=1 vme].
Proof.
  move=> hvs.
  rewrite /alloc_array_move_init.
  case: is_array_initP; last first.
  + by move=> _; apply alloc_array_moveP.
  move=> [m ->] /= [<-].
  rewrite /truncate_val /=.
  t_xrbindP=> _ /WArray.cast_empty_ok -> {m} <-.
  case: r => //=.
  t_xrbindP=> x /write_varP [-> _ htr] srx /get_sub_regionP hsrx <- <- <-.
  exists s2, se.(evm); split=> //; first by constructor.
  (* valid_state update *)
  rewrite with_vm_same.
  have /wfr_wf hwfx := hsrx.
  have /wfr_ptr [pkx [hlx hpkx]] := hsrx.
  have hgvalidx := check_gvalid_lvar hsrx.
  have /= hwfsx := [elaborate check_gvalid_wf_status wfr_status hgvalidx].
  apply: (valid_state_set_move hvs hwfx _ hlx hpkx htr) => //.
  have /vm_truncate_valE [-> ->] := htr.
  split=> //= off addr w _ _ /=.
  by rewrite WArray.get_empty; case: ifP.
Qed.

(* Link between a reg ptr argument value [va] in the source and
   the corresponding pointer [p] in the target. [m1] is the source memory,
   [m2] is the target memory.
*)
(* TODO: We use va (arg in the source) only to know the size of the argument.
   Would it make sense to use the type instead? Is there a benefit? *)
Record wf_arg_pointer m1 m2 (wptrs:seq (option bool)) vargs vargs' (writable:bool) align va p i := {
  wap_align             : is_align p align;
    (* [p] is aligned *)
  wap_no_overflow       : no_overflow p (size_val va);
    (* [p + size_val va - 1] does not overflow *)
  wap_valid             : forall w, between p (size_val va) w U8 -> validw m2 Aligned w U8;
    (* the bytes in [p ; p + size_val va - 1] are valid *)
    wap_fresh             : forall w, validw m1 Aligned w U8 -> disjoint_zrange p (size_val va) w (wsize_size U8);
    (* the bytes in [p ; p + size_val va - 1] are disjoint from the valid bytes of [m1] *)
  wap_writable_not_glob : writable -> (0 < glob_size)%Z -> disjoint_zrange rip glob_size p (size_val va);
    (* if the reg ptr is marked as writable, the associated zone in the target
       memory is disjoint from the globals *)
  wap_writable_disjoint : writable ->
    forall j vaj pj, i <> j ->
      isSome (nth None wptrs j) ->
      nth (Vbool true) vargs j = vaj ->
      nth (Vbool true) vargs' j = @Vword Uptr pj ->
      disjoint_zrange p (size_val va) pj (size_val vaj)
    (* if the reg ptr is marked as writable, the associated zone in the target
       memory is disjoint from all the zones pointed to by other reg ptr *)
}.

(* Link between the values given as arguments in the source and the target. *)
Definition wf_arg m1 m2 (wptrs:seq (option bool)) aligns vargs vargs' i :=
  match nth None wptrs i with
  | None => True
  | Some writable =>
    exists p,
      nth (Vbool true) vargs' i = Vword p /\
      wf_arg_pointer m1 m2 wptrs vargs vargs' writable (nth U8 aligns i) (nth (Vbool true) vargs i) p i
  end.

Definition wf_args m1 m2 (wptrs:seq (option bool)) aligns vargs vargs' :=
  forall i, wf_arg m1 m2 wptrs aligns vargs vargs' i.

Definition value_in_mem m v v' :=
  exists p, v' = Vword p /\
    forall off w, get_val_byte v off = ok w -> read m Aligned (p + wrepr _ off)%R U8 = ok w.

Definition value_eq_or_in_mem {A} m (o:option A) v v' :=
  match o with
  | None => v' = v (* no reg ptr : both values are equal *)
  | Some _ => (* reg ptr : [va] is compiled to a pointer [p] that satisfies [wf_arg_pointer] *)
    value_in_mem m v v'
  end.

(* Link between a reg ptr result value [vr1] in the source and the corresponding
   value [vr2] in the target. The reg ptr is associated to
   the [i]-th elements of [vargs1] and [vargs2] (the arguments in the source and
   the target).
*)
Record wf_result_pointer vargs1 vargs2 i vr1 vr2 := {
  wrp_subtype : subtype (type_of_val vr1) (type_of_val (nth (Vbool true) vargs1 i));
    (* [vr1] is smaller than the value taken as an argument (in the source) *)
    (* actually, size_of_val vr1 <= size_of_val (nth (Vbool true) vargs1 i) is enough to do the proofs,
       but this is true and we have lemmas about [subtype] (e.g. [wf_sub_region_subtype] *)
  wrp_args    : vr2 = nth (Vbool true) vargs2 i;
    (* [vr2] is the same pointer as the corresponding argument (in the target) *)
}.

(* Link between the values returned by the function in the source and the target. *)
Definition wf_result vargs1 vargs2 (i : option nat) vr1 vr2 :=
  match i with
  | None => True
  | Some i => wf_result_pointer vargs1 vargs2 i vr1 vr2
  end.

Lemma get_PvarP e x : get_Pvar e = ok x -> e = Pvar x.
Proof. by case: e => //= _ [->]. Qed.

Lemma alloc_call_arg_aux_not_None rmap0 rmap opi e rmap2 bsr e' :
  alloc_call_arg_aux pmap rmap0 rmap opi e = ok (rmap2, (bsr, e')) ->
  forall pi, opi = Some pi -> exists sr, bsr = Some (pi.(pp_writable), sr).
Proof.
  move=> halloc pi ?; subst opi.
  move: halloc; rewrite /alloc_call_arg_aux.
  t_xrbindP=> x _ _.
  case: get_local => [pk|//].
  case: pk => // p.
  t_xrbindP=> -[[sr ?] ?] _; t_xrbindP=> _ _ _ _ _ /= <- _.
  by eexists.
Qed.

Lemma alloc_call_args_aux_not_None rmap sao_params args rmap2 l :
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  List.Forall2 (fun opi bsr => forall pi, opi = Some pi ->
    exists sr, bsr = Some (pi.(pp_writable), sr)) sao_params (map fst l).
Proof.
  rewrite /alloc_call_args_aux.
  elim: sao_params args {2}rmap rmap2 l.
  + move=> [|//] _ _ _ /= [_ <-]; constructor.
  move=> opi sao_params ih [//|arg args] rmap0 /=.
  t_xrbindP=> _ _ [rmap1 [bsr e]] halloc [rmap2 l] /= /ih{ih}ih _ <-.
  constructor=> //.
  by apply (alloc_call_arg_aux_not_None halloc).
Qed.

Lemma set_clearP rmap x sr rmap2 :
  set_clear rmap x sr = ok rmap2 ->
  sr.(sr_region).(r_writable) /\
  rmap2 = set_clear_pure rmap sr.
Proof. by rewrite /set_clear; t_xrbindP=> /check_writableP -> ->. Qed.

Lemma alloc_call_arg_aux_writable rmap0 rmap opi e rmap2 bsr e' :
  alloc_call_arg_aux pmap rmap0 rmap opi e = ok (rmap2, (bsr, e')) ->
  forall sr, bsr = Some (true, sr) ->
  sr.(sr_region).(r_writable).
Proof.
  move=> halloc sr ?; subst bsr.
  move: halloc; rewrite /alloc_call_arg_aux.
  t_xrbindP=> x _ _.
  case: opi => [pi|].
  + case: get_local => [pk|//].
    case: pk => // p.
    t_xrbindP=> -[[sr' ?] ?] /= _; t_xrbindP=> _ _ tt hclear _ hw <- _.
    by move: hclear; rewrite hw => /set_clearP [? _].
  case: get_local => //.
  by t_xrbindP.
Qed.

Lemma alloc_call_args_aux_writable rmap sao_params args rmap2 l :
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  List.Forall (fun bsr => forall sr, bsr = Some (true, sr) ->
    sr.(sr_region).(r_writable)) (map fst l).
Proof.
  rewrite /alloc_call_args_aux.
  elim: sao_params args {2}rmap rmap2 l.
  + by move=> [|//] _ _ _ [_ <-]; constructor.
  move=> opi sao_params ih [//|arg args] rmap0 /=.
  t_xrbindP=> _ _ [rmap1 [bsr e]] halloc [rmap2 l] /= /ih{ih}ih _ <-.
  constructor=> //.
  by apply (alloc_call_arg_aux_writable halloc).
Qed.

(* FIXME: we prove things about incl. Maybe we should prove sth about another
predicate Incl with semantic meaning, i.e. parametrized by some [se] and doing
  inclusions on concrete intervals. *)

Section SUBSEQ.

Context {A : Type} (eqA : rel A).

Lemma subseqA_refl : Reflexive eqA -> Reflexive (subseqA eqA).
Proof.
  move=> hrefl.
  elim=> [//|x s ih] /=.
  by rewrite hrefl.
Qed.

Lemma cons_subseqA x1 s1 s2 :
  subseqA eqA (x1 :: s1) s2 -> subseqA eqA s1 s2.
Proof.
  elim: s2 s1 x1 => [|x2 s2 ih2] [|x1' s1] x1 //=.
  case: ifP => _.
  + case: ifP => // _.
    by apply ih2.
  move=> /ih2.
  case: ifP => // _.
  by apply ih2.
Qed.

Lemma subseqA_cons_cons x1 s1 x2 s2 :
  subseqA eqA (x1 :: s1) (x2 :: s2) =
    if eqA x1 x2 then subseqA eqA s1 s2
    else subseqA eqA (x1 :: s1) s2.
Proof. by move=> /=; case: ifP. Qed.

Lemma subseqA_cons x s : Reflexive eqA -> subseqA eqA s (x :: s).
Proof.
  move=> hrefl.
  elim: s x => [//|x' s ih] x.
  rewrite subseqA_cons_cons.
  case: ifP => _.
  + by apply ih.
  by apply subseqA_refl.
Qed.

(* eqA does not return a Prop, is_true is inserted.
   Due to the coercion, setoid does not work well. We define this boring lemma
   to make it work better. *)
Instance Equivalence_eq_compat : Equivalence eqA -> Proper (eqA ==> eqA ==> eq) eqA.
Proof.
  move=> hequiv.
  move=> x1 x2 eq_x y1 y2 eq_y.
  apply /idP/idP.
  + move=> eq_xy.
    transitivity y1 => //.
    transitivity x1 => //.
    by symmetry.
  move=> eq_xy.
  transitivity x2 => //.
  transitivity y2 => //.
  by symmetry.
Qed.

(* we use rewrite ->, because ssreflect's rewrite does not like setoid *)
Lemma subseqA_trans : Equivalence eqA -> Transitive (subseqA eqA).
Proof.
  move=> hequiv.
  move=> s1 s2 s3.
  elim: s3 s1 s2 => [|x3 s3 ih3] [|x1 s1] [|x2 s2] //=.
  case: ifP => heq1.
  + move=> hsub; apply ih3.
    rewrite -> heq1.
    case: ifP => //= _.
    by rewrite heq1.
  case: ifP => heq2.
  + rewrite <- heq2.
    rewrite heq1.
    by apply ih3.
  case: ifP => _.
  + move=> /cons_subseqA + /cons_subseqA.
    by apply ih3.
  move=> + /cons_subseqA.
  by apply ih3.
Qed.

Instance subseqA_preorder : Equivalence eqA -> PreOrder (subseqA eqA).
Proof.
  move=> hequiv.
  split.
  + by apply: subseqA_refl.
  by apply: subseqA_trans.
Qed.

(* useless in the end? *)
Lemma subseqA_all (p : pred A) :
  Proper (eqA ==> eq) p ->
  forall s1 s2,
    subseqA eqA s1 s2 ->
    all p s2 ->
    all p s1.
Proof.
  move=> p_compat s1 s2.
  elim: s2 s1 => [|x2 s2 ih2] [|x1 s1] //= hsub /andP [hx2 all_s2].
  have := ih2 _ hsub all_s2.
  case: ifP => [heq|//] all_s1.
  by rewrite (p_compat _ _ heq) hx2 all_s1.
Qed.

(* useless in the end? *)
Lemma subseqA_sorted_in {p : {pred A}} {leT:rel A} :
  Equivalence eqA ->
  Proper (eqA ==> eq) p ->
  Proper (eqA ==> eqA ==> eq) leT ->
  {in p & &, ssrbool.transitive leT} ->
  forall s1 s2,
    all p s2 ->
    subseqA eqA s1 s2 ->
    path.sorted leT s2 ->
    path.sorted leT s1.
Proof.
  move=> eqA_equiv p_compat leT_compat htrans s1 s2 all_s2 hsub.
  elim: s2 s1 all_s2 hsub => [|x2 s2 ih2] [|x1 s1] //.
  move=> /[dup] all_s2 /= /andP [p_x2 all_s2'] hsub.
  rewrite (path.path_sorted_inE htrans) // => /andP [leT_x2 sorted_s2].
  have {}ih2 := ih2 _ all_s2' hsub sorted_s2.
  case: ifP hsub ih2 => [heq|_] hsub ih2 => //.
  rewrite (path.path_sorted_inE htrans) /=; last first.
  + rewrite -> heq.
    rewrite p_x2 /=.
    by apply (subseqA_all _ hsub all_s2').
  rewrite ih2 andbT.
  apply: sub_all (subseqA_all _ hsub leT_x2).
  move=> x.
  by rewrite -> heq.
Qed.

End SUBSEQ.

(* TODO: reorganize & use setoid as much as possible *)
Instance symbolic_slice_beq_equiv : Equivalence symbolic_slice_beq.
Proof.
  split.
  + exact symbolic_slice_beq_refl.
  + exact symbolic_slice_beq_sym'.
  exact symbolic_slice_beq_trans.
Qed.

Instance incl_interval_preorder : PreOrder incl_interval.
Proof.
  by apply: subseqA_preorder.
Qed.

Definition incl_interval_refl := incl_interval_preorder.(PreOrder_Reflexive).
Definition incl_interval_trans := incl_interval_preorder.(PreOrder_Transitive).

Lemma incl_interval_nil_l i : incl_interval [::] i.
Proof. by case: i => [|??]. Qed.

Lemma incl_interval_cons s i :
  incl_interval i (s :: i).
Proof. by apply: subseqA_cons. Qed.

Instance symbolic_slice_beq_compat :
  Proper (symbolic_slice_beq ==> symbolic_slice_beq ==> eq) symbolic_slice_beq.
Proof. by apply: Equivalence_eq_compat. Qed.

Lemma incl_status_refl : Reflexive incl_status.
Proof.
  move=> status.
  case: status => //= i.
  by reflexivity.
Qed.

Lemma incl_status_map_refl : Reflexive incl_status_map.
Proof.
  move=> sm.
  apply Mvar.inclP => x.
  case: Mvar.get => [status|//].
  by apply incl_status_refl.
Qed.

Lemma incl_refl : Reflexive incl.
Proof.
  move=> rmap.
  apply /andP; split.
  + apply Mvar.inclP => x.
    case: Mvar.get => [sr|//].
    by apply sub_region_beq_refl.
  apply Mr.inclP => r.
  case: Mr.get => [sm|//].
  by apply incl_status_map_refl.
Qed.

Instance all2_equiv A (r : rel A) : Equivalence r -> Equivalence (all2 r).
Proof.
  move=> [hrefl hsym htrans].
  split.
  + by apply all2_refl.
  + move=> l1 l2.
    (* is this correct elim syntax? *)
    elim/list_all2_ind: l1 l2 / => [//|x1 l1 x2 l2] /=.
    by move=> /hsym -> _ ->.
  by move=> /[swap]; apply all2_trans; move=> /[swap].
Qed.

Lemma incl_status_trans : Transitive incl_status.
Proof.
  case=> [||i1] [||i2] [||i3] //= hincl1 hincl2.
  by transitivity i2.
Qed.

Lemma incl_status_map_trans : Transitive incl_status_map.
Proof.
  move=> sm1 sm2 sm3.
  move=> /Mvar.inclP h1 /Mvar.inclP h2.
  apply Mvar.inclP => x.
  case heq1: Mvar.get => [status1|//].
  have := h1 x; rewrite heq1.
  case heq2: Mvar.get => [status2|//] hincl.
  have := h2 x; rewrite heq2.
  case heq3: Mvar.get => [status3|//].
  by apply (incl_status_trans hincl).
Qed.

Lemma incl_trans : Transitive incl.
Proof.
  move=> rmap1 rmap2 rmap3.
  move=> /andP [] /Mvar.inclP h12 /Mr.inclP h12'.
  move=> /andP [] /Mvar.inclP h23 /Mr.inclP h23'.
  apply /andP; split.
  + apply Mvar.inclP => x.
    case heq1: Mvar.get => [sr1|//].
    have := h12 x; rewrite heq1.
    case heq2: Mvar.get => [sr2|//] heqsub.
    have := h23 x; rewrite heq2.
    case heq3: Mvar.get => [status3|//].
    by apply (sub_region_beq_trans heqsub).
  apply Mr.inclP => r.
  case heq1: Mr.get => [sm1|//].
  have := h12' r; rewrite heq1.
  case heq2: Mr.get => [sm2|//] hincl.
  have := h23' r; rewrite heq2.
  case heq3: Mr.get => [sm3|//].
  by apply (incl_status_map_trans hincl).
Qed.

Lemma get_var_status_None rv r x :
  Mr.get rv r = None ->
  get_var_status rv r x = Unknown.
Proof.
  move=> hget.
  rewrite /get_var_status /get_status_map hget /=.
  by rewrite /get_status /empty_status_map Mvar.get0.
Qed.

(* This is not exactly the Prop-version of [incl]. [incl] has the disadvantage
   that a map with dummy bindings (e.g. associating empty bytes to a var) is not
   [incl] in the map without the dummy bindings, while equivalent from the point
   of view of the definitions that we care about ([get_var_bytes],
   [check_valid], [valid_state]). [Incl] avoids this pitfall.
*)
Definition Incl (rmap1 rmap2 : region_map) :=
  (forall x sr, Mvar.get rmap1.(var_region) x = Some sr ->
    exists2 sr2, Mvar.get rmap2.(var_region) x = Some sr2 & sub_region_beq sr sr2) /\
  (forall r x, incl_status (get_var_status rmap1 r x) (get_var_status rmap2 r x)).

Lemma Incl_refl : Reflexive Incl.
Proof.
  move=> rmap.
  split.
  + move=> x sr hsr; exists sr=> //.
    by apply sub_region_beq_refl.
  by move=> r x; apply incl_status_refl.
Qed.

Lemma Incl_trans : Transitive Incl.
Proof.
  move=> rmap1 rmap2 rmap3.
  move=> [hincl11 hincl12] [hincl21 hincl22]; split.
  + move=> x sr1 /hincl11 [sr2 /hincl21 [sr3 hsr3 heqsub2] heqsub1].
    exists sr3 => //.
    apply (sub_region_beq_trans heqsub1 heqsub2).
  by move=> r x; apply (incl_status_trans (hincl12 r x) (hincl22 r x)).
Qed.

(* we use sub_region_beq sr sr2 -> sr.(sr_region) = sr2.(sr_region) *)
Lemma Incl_check_gvalid rmap1 rmap2 x sr status :
  Incl rmap1 rmap2 ->
  check_gvalid rmap1 x = Some (sr, status) ->
  exists sr2 status2, [/\
    check_gvalid rmap2 x = Some (sr2, status2),
    sub_region_beq sr sr2 &
    incl_status status status2].
Proof.
  move=> [hincl1 hincl2].
  rewrite /check_gvalid.
  case: is_glob.
  + move=> ->.
    exists sr, status; split=> //.
    + by apply sub_region_beq_refl.
    by apply incl_status_refl.
  case heq1: Mvar.get=> [sr'|//] [? <-]; subst sr'.
  have [sr2 -> heqsub] := hincl1 _ _ heq1.
  eexists _, _; (split; first by reflexivity) => //.
  move: heqsub => /andP [/eqP <- _].
  by apply hincl2.
Qed.

Lemma incl_var_region rmap1 rmap2 x sr :
  incl rmap1 rmap2 ->
  Mvar.get rmap1.(var_region) x = Some sr ->
  exists2 sr2, Mvar.get rmap2.(var_region) x = Some sr2 & sub_region_beq sr sr2.
Proof.
  move=> /andP [hincl _] hget1.
  have /Mvar.inclP -/(_ x) := hincl.
  rewrite hget1.
  case: Mvar.get => [sr2|//] heqsub.
  by exists sr2.
Qed.

Lemma incl_get_var_status rmap1 rmap2 r x :
  incl rmap1 rmap2 ->
  incl_status (get_var_status rmap1 r x) (get_var_status rmap2 r x).
Proof.
  move=> /andP [] _ /Mr.inclP /(_ r).
  rewrite /get_var_status /get_status_map /get_status.
  case: Mr.get => [sm1|//].
  case: Mr.get => [sm2|//].
  move=> /Mvar.inclP /(_ x).
  case: Mvar.get => [status1|//].
  by case: Mvar.get => [status2|//].
Qed.

(* we use sub_region_beq sr sr2 -> sr.(sr_region) = sr2.(sr_region) *)
Lemma incl_check_gvalid rmap1 rmap2 x sr status :
  incl rmap1 rmap2 ->
  check_gvalid rmap1 x = Some (sr, status) ->
  exists sr2 status2, [/\
    check_gvalid rmap2 x = Some (sr2, status2),
    sub_region_beq sr sr2 &
    incl_status status status2].
Proof.
  move=> hincl.
  rewrite /check_gvalid.
  case: is_glob.
  + move=> ->.
    exists sr, status; split=> //.
    + by apply sub_region_beq_refl.
    by apply incl_status_refl.
  case heq1: Mvar.get=> [sr'|//] [? <-]; subst sr'.
  have [sr2 -> heqsub] := incl_var_region hincl heq1.
  eexists _, _; (split; first by reflexivity) => //.
  case/andP: heqsub => /eqP <- _.
  by apply: incl_get_var_status hincl.
Qed.

Lemma sub_region_beq_wf sr1 sr2 se ty :
  sub_region_beq sr1 sr2 ->
  wf_sub_region se sr2 ty ->
  wf_sub_region se sr1 ty.
Proof.
  move=> /andP [/eqP heqr heqz] [hwfr hwfz].
  split; rewrite heqr //.
  case: hwfz => cs ok_cs wf_cs.
  exists cs => //.
  by rewrite (symbolic_zone_beq_sem_zone se heqz).
Qed.

(* To use path.sorted on [seq concrete_slice], we prove that concrete_slice is
   eqType. *)
Scheme Equality for concrete_slice.
Lemma concrete_slice_eq_axiom : Equality.axiom concrete_slice_beq.
Proof.
  exact:
    (eq_axiom_of_scheme internal_concrete_slice_dec_bl internal_concrete_slice_dec_lb).
Qed.

From HB Require Import structures.
HB.instance Definition _ := hasDecEq.Build concrete_slice concrete_slice_eq_axiom.

Lemma incl_intervalP se i1 i2 ci2 :
  incl_interval i1 i2 ->
  mapM (sem_slice se) i2 = ok ci2 ->
  exists2 ci1, mapM (sem_slice se) i1 = ok ci1 & subseq ci1 ci2.
Proof.
  elim: i2 i1 ci2 => [|s2 i2 ih2] [|s1 i1] //=.
  + by move=> _ _ [<-]; exists [::].
  + by move=> ci2 _ _; exists [::] => //; apply sub0seq.
  t_xrbindP=> _ hincl cs2 ok_cs2 ci2 ok_ci2 <-.
  have [ci1 ok_ci1 hsub] := ih2 _ _ hincl ok_ci2.
  have {}hsub: subseq (cs2 :: ci1) (cs2 :: ci2).
  + by rewrite /= eq_refl.
  case: ifP ok_ci1 => [heqsub|_] ok_ci1.
  + exists (cs2::ci1) => //.
    by rewrite (symbolic_slice_beqP se heqsub) ok_cs2 ok_ci1 /=.
  exists ci1 => //.
  apply: subseq_trans hsub.
  by apply subseq_cons.
Qed.

Lemma incl_interval_wf i1 i2 se :
  incl_interval i1 i2 ->
  wf_interval se i2 ->
  wf_interval se i1.
Proof.
  rewrite /wf_interval.
  move=> hincl [ci2 [ok_ci2 all_ci2 sorted_ci2]].
  have [ci1 ok_ci1 hsub] := incl_intervalP hincl ok_ci2.
  exists ci1; split=> //.
  + by apply (subseq_all hsub).
  apply: (path.subseq_sorted_in _ hsub sorted_ci2).
  apply: sub_in3 concrete_slice_ble_trans.
  by apply /allP.
Qed.

(*
not true
Lemma incl_status_wf status1 status2 se :
  incl_status status1 status2 ->
  wf_status se status2 ->
  wf_status se status1.
Proof.
  case: status1 status2 => [||i1] [||i2] //=.
  move=> hincl.
*)

(* TODO: better use offset_in_concrete_interval for uniformity? *)
Lemma incl_interval_valid_offset se i1 i2 off :
  incl_interval i1 i2 ->
  wf_interval se i2 ->
  valid_offset_interval se i2 off ->
  valid_offset_interval se i1 off.
Proof.
  move=> hincl [ci2 [ok_ci2 all_ci2 sorted_ci2]] off_valid2 ci1 ok_ci1 off_valid1.
  apply (off_valid2 _ ok_ci2).
  have := incl_intervalP hincl ok_ci2.
  rewrite ok_ci1 => -[_ [<-] hsub].
  by apply (subseq_has hsub off_valid1).
Qed.

Lemma incl_statusP status1 status2 se off :
  incl_status status1 status2 ->
  wf_status se status1 ->
  valid_offset se status1 off ->
  valid_offset se status2 off.
Proof.
  case: status1 status2 => [||i1] [||i2] //=.
  by apply incl_interval_valid_offset.
Qed.

Lemma sub_region_beq_valid_pk sr1 sr2 rv se s2 pk :
  sub_region_beq sr1 sr2 ->
  valid_pk rv se s2 sr1 pk ->
  valid_pk rv se s2 sr2 pk.
Proof.
  move=> heqsub.
  case: pk.
  + move=> s ofs ws cs sc /=.
    by apply (sub_region_beq_trans (sub_region_beq_sym heqsub)).
  + move=> p /= hpk addr haddr; apply hpk.
    by rewrite (sub_region_beq_addr se heqsub).
  move=> s ofs ws cs f /= hpk hcheck paddr addr hpaddr haddr.
  apply (hpk hcheck paddr addr hpaddr).
  by rewrite (sub_region_beq_addr se heqsub).
Qed.

Lemma wf_rmap_incl rmap1 rmap2 se s1 s2 :
  incl rmap1 rmap2 ->
  wfr_STATUS rmap1 se ->
  wf_rmap rmap2 se s1 s2 ->
  wf_rmap rmap1 se s1 s2.
Proof.
  move=> hincl hwfst1 hwfr2.
  case: (hwfr2) => hwfsr2 hwfst2 hval2 hptr2; split=> //.
  + move=> x sr1 /(incl_var_region hincl) [sr2 hsr2 heqsub].
    apply (sub_region_beq_wf heqsub).
    by apply hwfsr2.
  + move=> x sr1 status1 v hgvalid1 hget.
    have [sr2 [status2 [hgvalid2 heqsub {}hincl]]] :=
      incl_check_gvalid hincl hgvalid1.
    apply (sub_region_beq_eq_sub_region_val (sub_region_beq_sym heqsub)).
    have [hread2 hty2] := hval2 _ _ _ _ hgvalid2 hget.
    split=> //.
    move=> off addr w haddr off_valid.
    apply hread2 => //.
    have /= hwfs1 := check_gvalid_wf_status hwfst1 hgvalid1.
    by apply (incl_statusP hincl hwfs1 off_valid).
  move=> x sr1 /(incl_var_region hincl) [sr2 /hptr2 [pk [hlx hpk2]] heqsub].
  exists pk; split=> //.
  apply (sub_region_beq_valid_pk (sub_region_beq_sym heqsub)).
  case: pk hlx hpk2 => //= sl ofs ws cs f hlx hpk hstkptr.
  apply hpk.
  have := incl_get_var_status (sub_region_stkptr sl ws cs).(sr_region) f hincl.
  move: hstkptr; rewrite /check_stack_ptr.
  move=> /is_validP ->.
  by case: get_var_status.
Qed.

Lemma valid_state_incl rmap1 rmap2 se table m0 s s' :
  incl rmap1 rmap2 ->
  wfr_STATUS rmap1 se ->
  valid_state table rmap2 se m0 s s' ->
  valid_state table rmap1 se m0 s s'.
Proof.
  move=> hincl hwfst hvs.
  case:(hvs) => hscs hvalid hdisj hincl' hincl2 hunch hrip hrsp heqvm hwft' hwfr heqmem hglobv htop.
  constructor=> //.
  by apply (wf_rmap_incl hincl hwfst hwfr).
Qed.

Lemma incl_Incl rmap1 rmap2 : incl rmap1 rmap2 -> Incl rmap1 rmap2.
Proof.
  move=> hincl; split.
  + by move=> x sr; apply (incl_var_region hincl).
  by move=> r x; apply (incl_get_var_status _ _ hincl).
Qed.

Lemma wf_rmap_Incl rmap1 rmap2 se s1 s2 :
  Incl rmap1 rmap2 ->
  wfr_STATUS rmap1 se ->
  wf_rmap rmap2 se s1 s2 ->
  wf_rmap rmap1 se s1 s2.
Proof.
  move=> /[dup] hincl [hinclr hincls] hwfst1 hwfr2.
  case: (hwfr2) => hwfsr2 hwfst2 hval2 hptr2; split=> //.
  + move=> x sr1 /hinclr [sr2 hsr2 heqsub].
    apply (sub_region_beq_wf heqsub).
    by apply hwfsr2.
  + move=> x sr1 status1 v hgvalid1 hget.
    have [sr2 [status2 [hgvalid2 heqsub {}hincl]]] :=
      Incl_check_gvalid hincl hgvalid1.
    apply (sub_region_beq_eq_sub_region_val (sub_region_beq_sym heqsub)).
    have [hread2 hty2] := hval2 _ _ _ _ hgvalid2 hget.
    split=> //.
    move=> off addr w haddr off_valid.
    apply hread2 => //.
    have /= hwfs1 := check_gvalid_wf_status hwfst1 hgvalid1.
    by apply (incl_statusP hincl hwfs1 off_valid).
  move=> x sr1 /hinclr [sr2 /hptr2 [pk [hlx hpk2]] heqsub].
  exists pk; split=> //.
  apply (sub_region_beq_valid_pk (sub_region_beq_sym heqsub)).
  case: pk hlx hpk2 => //= sl ofs ws cs f hlx hpk hstkptr.
  apply hpk.
  have := hincls (sub_region_stkptr sl ws cs).(sr_region) f.
  move: hstkptr; rewrite /check_stack_ptr.
  move=> /is_validP ->.
  by case: get_var_status.
Qed.

Lemma valid_state_Incl rmap1 rmap2 se table m0 s s' :
  Incl rmap1 rmap2 ->
  wfr_STATUS rmap1 se ->
  valid_state table rmap2 se m0 s s' ->
  valid_state table rmap1 se m0 s s'.
Proof.
  move=> hincl hwfst hvs.
  case:(hvs) => hscs hvalid hdisj hincl' hincl2 hunch hrip hrsp heqvm hwft' hwfr heqmem hglobv htop.
  constructor=> //.
  by apply (wf_rmap_Incl hincl hwfst hwfr).
Qed.

Lemma incl_merge_interval i1 i2 i2' i i' :
  incl_interval i2 i2' ->
  merge_interval i1 i2 = Some i ->
  merge_interval i1 i2' = Some i' ->
  incl_interval i i'.
Proof.
  move=> hincl.
  rewrite /merge_interval.
Admitted.

(* We could probably deduce add_sub_interval_1/_2 from this lemma *)
Lemma add_sub_interval_incl_l i1 s i2 :
  add_sub_interval i1 s = Some i2 ->
  incl_interval i1 i2.
Proof.
  elim: i1 i2 => [|s1 i1 ih1] i2 /=.
  + by move=> _; apply incl_interval_nil_l.
  case: symbolic_slice_beq.
  + move=> [<-] /=.
    rewrite symbolic_slice_beq_refl /=.
    by reflexivity.
  case: (odflt _ _).
  + move=> [<-].
    by apply incl_interval_cons.
  case: (odflt _ _) => //.
  apply: obindP => {}i2 hadd [<-].
  rewrite /= symbolic_slice_beq_refl /=.
  by apply (ih1 _ hadd).
Qed.

Lemma add_sub_interval_incl_r i1 s i2 :
  add_sub_interval i1 s = Some i2 ->
  has (symbolic_slice_beq s) i2.
Proof.
  elim: i1 i2 => [|s1 i1 ih1] i2 /=.
  + move=> [<-] /=.
    by rewrite symbolic_slice_beq_refl.
  case: (@idP (symbolic_slice_beq _ _)) => [heq|_].
  + move=> [<-] /=.
    by rewrite heq.
  case: (odflt _ _).
  + move=> [<-] /=.
    by rewrite symbolic_slice_beq_refl.
  case: (odflt _ _) => //.
  apply: obindP => {}i2 hadd [<-] /=.
  by rewrite (ih1 _ hadd) orbT.
Qed.

Lemma merge_interval_None i1 :
  foldl (fun acc s => let%opt acc := acc in add_sub_interval acc s) None i1 = None.
Proof. by elim: i1. Qed.

Lemma merge_interval_incl_r i1 i2 i :
  merge_interval i1 i2 = Some i ->
  incl_interval i2 i.
Proof.
  rewrite /merge_interval.
  elim: i1 i2 i => [|s1 i1 ih1] i2 i /=.
  + by move=> [<-]; reflexivity.
  case hadd: add_sub_interval => [i2'|]; last first.
  + by rewrite merge_interval_None.
  move=> /ih1.
  apply incl_interval_trans.
  by apply (add_sub_interval_incl_l hadd).
Qed.

Lemma test se i1 i2 ci1 ci2 :
  all (fun s1 => has (symbolic_slice_beq s1) i2) i1 ->
  mapM (sem_slice se) i1 = ok ci1 ->
  mapM (sem_slice se) i2 = ok ci2 ->
  all (fun cs => 0 <? cs.(cs_len))%Z ci1 ->
  all (fun cs => 0 <? cs.(cs_len))%Z ci2 ->
  path.sorted concrete_slice_ble ci1 ->
  path.sorted concrete_slice_ble ci2 ->
  subseqA symbolic_slice_beq i1 i2.
Proof.
  move=> hincl ok_ci1 ok_ci2 all_ci1 all_ci2 sorted_ci1 sorted_ci2.

  have: {subset ci1 <= ci2}.
  + move=> cs /= /(nthP {| cs_ofs := 0; cs_len := 0 |}) [k hk hnth1].
    have := mapM_nth {| ss_ofs := 0; ss_len := 0 |} {| cs_ofs := 0; cs_len := 0 |} ok_ci1.
    rewrite (size_mapM ok_ci1) => /(_ _ hk). rewrite hnth1 => h1.
    have /(all_nthP {| ss_ofs := 0; ss_len := 0 |}) := hincl.
    rewrite (size_mapM ok_ci1) => /(_ _ hk).
    move=> /(has_nthP {| ss_ofs := 0; ss_len := 0 |}). move=> [k' hk' heq].
    have := mapM_nth {| ss_ofs := 0; ss_len := 0 |} {| cs_ofs := 0; cs_len := 0 |} ok_ci2 hk'.
    have <- := symbolic_slice_beqP se heq. rewrite h1 => -[h2].
    apply /(nthP {| cs_ofs := 0; cs_len := 0 |}).
    exists k'.
    rewrite -(size_mapM ok_ci2). done.
    done.

  move=> hsub.
  have uniq_ci1: uniq ci1.
  + apply (path.sorted_uniq_in (leT:=concrete_slice_ble)).
    + apply: sub_in3 concrete_slice_ble_trans.
      apply /allP. done.
    + move=> cs hin.
      have /allP := all_ci1. move=> /(_ cs hin) /ZltP ?.
      apply /negP.
      rewrite /concrete_slice_ble !zify. lia.
    done.
  have hcount := leq_uniq_count uniq_ci1 hsub.
  have := proj1 (count_subseqP _ _) hcount.
  move=> [ci2' hsub2 hperm].
  have: ci1 = ci2'.
  + apply (path.sorted_eq_in (leT := concrete_slice_ble)).
    + apply: sub_in3 concrete_slice_ble_trans.
      apply /allP. done.
    + move=> cs1 cs2 hin1 hin2 /andP [].
      have /allP -/(_ _ hin1) /ZltP ? := all_ci1.
      have /allP -/(_ _ hin2) /ZltP ? := all_ci1.
      rewrite /concrete_slice !zify. lia.
    done.
    apply: path.subseq_sorted_in hsub2 sorted_ci2.
    apply: sub_in3 concrete_slice_ble_trans.
    apply /allP. done.
    done.
  move=> ?; subst ci2'. move=> {hperm}.

  have: exists2 m, size m = size i2 & i1 = mask m i2.
  + have /subseqP [m heqsize hmask] := hsub2.
    exists m.
    + rewrite (size_mapM ok_ci2). done.
    Search nth (@eq (seq _)).
    apply (eq_from_nth (x0 := {| ss_ofs := 0; ss_len := 0 |})).
    + rewrite size_mask. rewrite -(size_mask (s:=ci2)). rewrite -hmask.
      rewrite (size_mapM ok_ci1). done. done.
      rewrite (size_mapM ok_ci2). done.
    move=> k hk.
    have /(all_nthP {| ss_ofs := 0; ss_len := 0 |}) := hincl.
    move=> /(_ _ hk). move=> /(has_nthP {| ss_ofs := 0; ss_len := 0 |}).
    move=> [k' hk' heq].
    have H1 := mapM_nth {| ss_ofs := 0; ss_len := 0 |} {| cs_ofs := 0; cs_len := 0 |} ok_ci1 hk.
    have H2 := mapM_nth {| ss_ofs := 0; ss_len := 0 |} {| cs_ofs := 0; cs_len := 0 |} ok_ci2 hk'.
    have := symbolic_slice_beqP se heq.
    have hk_: (k < size (mask m i2))%nat.
    + admit.
    Require Import SetoidList. Sorted inside SetoidList
    have := mem_nth hk_.
    nth in_mem
    mask in_mem
    
     rewrite H1 H2 => -[].
    mask nth
    
    path.sorted nth
    
    path.sorted_ltn_nth_in
    
    pairwise nth
    
    
    
  
  
  uniq path.sorted
  leq_uniq_count
  sub_mem count subseq perm_eq perm_eq  path.sorted
  

Locate "=i". ssrbool.eq_mem sub_mem
Lemma test T (r:rel T) : ssrbool.irreflexive r -> ssrbool.antisymmetric r.
Proof.
  move=> hirrefl x y. ssrbool.transitive ssrbool.irreflexive
  perm_eq subseq
  path.irr_sorted_eq_in sub_mem perm_eq

(* Goal True. have := mem_subseq. *)
Lemma test {A:eqType} (eqA : rel A) (s1 s2:seq A) :
  {subset s1 <= s2} ->
  path.sorted eqA s1 ->
  path.sorted eqA s2 ->
  subseq s1 s2.

ssrbool.irreflexive ssrbool.antisymmetric
path.sorted  perm_eq pred1 count path.sorted
path.sorted subseq
(*
Lemma toto i1' i1'' i2 i2' :
  foldl (fun acc s=> let%opt acc := acc in add_sub_interval acc s) (Some i2) (i1' ++ i1'') =
  foldl (fun acc s=> let%opt acc := acc in add_sub_interval acc s) (Some i2') i1'' ->
  incl_interval i1' i2'.
Proof.
  elim: i1' i2 => /=.
  + move=> ? _. apply incl_interval_nil_l.
  move=> s1 i1' ih i2 /=.
  case hadd: add_sub_interval => [acc|].
  + move=> /[dup] /ih ? /merge_interval_incl_r.
  have := ih _ (add_sub_interval i2 s1) erefl.
*)

sub_mem perm_eq mask sub_mem

mem_subseq
perm_to_subseq
subseqP
subseq_uniqP
path.subseq_sort
path.mem2

in_mem subseq
subseq perm_eq set

Lemma merge_interval_incl_l i1 i2 i :
  merge_interval i1 i2 = Some i ->
  incl_interval i1 i.
Proof.
  rewrite /merge_interval.
  elim: i1 i2 i => [|s1 i1 ih1] i2 i /=.
  + by move=> _; apply incl_interval_nil_l.
  case hadd: add_sub_interval => [i2'|]; last first.
  + by rewrite merge_interval_None.
  
  
  case: i1 => /=. move=> _. apply incl_interval_nil_l.
  move=> s1 i1. case: i1 => [|s2 i1] /=.
  admit.
  case: i1 => [|s3 i1] /=.
  add_sub_interval "wf"
  
  
  
  
  
  rewrite /merge_interval.
  elim: i1 i2 i => [|s1 i1 ih1] i2 i /=.
  + by move=> _; apply incl_interval_nil_l.
  case hadd: add_sub_interval => [i2'|]; last first.
  + by rewrite merge_interval_None.
  move=> /[dup] /ih1 ?. /merge_interval_incl_r.
  move=> /[dup] /ih1 ->; rewrite andbT.
  have /(has_nthP {| ss_ofs := 0; ss_len := 0 |}) [k hk heqsub] :=
    add_sub_interval_incl_r hadd.
  move=> /merge_interval_r /(all_nthP {| ss_ofs := 0; ss_len := 0 |}) /(_ _ hk).
  apply sub_has => k'.
  by apply symbolic_slice_beq_trans.
Qed.

Lemma incl_status_map_merge_status_l sm1 sm2 :
  incl_status_map (Mvar.map2 merge_status sm1 sm2) sm1.
Proof.
  apply Mvar.inclP => x.
  rewrite Mvar.map2P //.
  rewrite /merge_status.
  case: Mvar.get => [status1|//].
  case: Mvar.get => [status2|//].
  case: status1 status2 => [||i1] [||i2] //=.
  + by apply incl_interval_refl.
  case hmerge: merge_interval => [i|//] /=.
  by apply (merge_interval_l hmerge).
Qed.

Lemma incl_status_map_merge_status_r sm1 sm2 :
  incl_status_map (Mvar.map2 merge_status sm1 sm2) sm2.
Proof.
  apply Mvar.inclP => x.
  rewrite Mvar.map2P //.
  rewrite /merge_status.
  case: Mvar.get => [status1|//].
  case: Mvar.get => [status2|//].
  case: status1 status2 => [||i1] [||i2] //=.
  + by apply incl_interval_refl.
  case hmerge: merge_interval => [i|//] /=.
  by apply (merge_interval_r hmerge).
Qed.

Lemma incl_merge_l rmap1 rmap2 : incl (merge rmap1 rmap2) rmap1.
Proof.
  rewrite /merge; apply /andP => /=; split.
  + apply Mvar.inclP => x.
    rewrite Mvar.map2P //.
    case: Mvar.get => [sr1|//].
    case: Mvar.get => [sr2|//].
    case: sub_region_beq => //.
    by apply sub_region_beq_refl.
  apply Mr.inclP => r.
  rewrite Mr.map2P //.
  rewrite /merge_status_map.
  case: Mr.get => [sm1|//].
  case: Mr.get => [sm2|//].
  case: Mvar.is_empty => //.
  by apply incl_status_map_merge_status_l.
Qed.

Lemma incl_merge_r rmap1 rmap2 : incl (merge rmap1 rmap2) rmap2.
Proof.
  rewrite /merge; apply /andP => /=; split.
  + apply Mvar.inclP => x.
    rewrite Mvar.map2P //.
    case: Mvar.get => [sr1|//].
    case: Mvar.get => [sr2|//].
    by case: ifP.
  apply Mr.inclP => r.
  rewrite Mr.map2P //.
  rewrite /merge_status_map.
  case: Mr.get => [sm1|//].
  case: Mr.get => [sm2|//].
  case: Mvar.is_empty => //.
  by apply incl_status_map_merge_status_r.
Qed.

(* TODO: better proof with no quadratic complexity *)
Instance is_const_compat : Proper (eq_expr ==> eq) is_const.
Proof. by move=> [^~ 1] [^~ 2] //= /eqP ->. Qed.

Instance symbolic_slice_ble_compat :
  Proper (symbolic_slice_beq ==> symbolic_slice_beq ==> eq) symbolic_slice_ble.
Proof.
  move=> s1 s1' heqsub1 s2 s2' heqsub2.
  rewrite /symbolic_slice_ble.
  move: heqsub1 heqsub2; rewrite /symbolic_slice_beq.
  by move=>
    /andP [/is_const_compat -> /is_const_compat ->]
    /andP [/is_const_compat -> _].
Qed.

Lemma symbolic_zone_beq_get_suffix z1 z1' z2 :
  symbolic_zone_beq z1 z1' ->
  match get_suffix z1 z2 with
  | None => get_suffix z1' z2 = None
  | Some None => get_suffix z1' z2 = Some None
  | Some (Some z) =>
    exists2 z', get_suffix z1' z2 = Some (Some z') & symbolic_zone_beq z z'
  end.
Proof.
  move=> heq; move: heq z2.
  (* is this correct elim syntax? *)
  elim/list_all2_ind: z1 z1' / => [|s1 z1 s1' z1' heqsub hall2 ih] z2 /=.
  + exists z2 => //.
    by apply symbolic_zone_beq_refl.
  case: z2 => [//|s2 z2].
  (* forced to do these "have", because setoid & is_true do not work well *)
  have ->: symbolic_slice_beq s1' s2 = symbolic_slice_beq s1 s2.
  + by apply /idP/idP; apply symbolic_slice_beq_trans; [|symmetry].
  have ->: symbolic_slice_ble s1' s2 = symbolic_slice_ble s1 s2.
  + (* we need standard rewrite *)
    by rewrite -> heqsub.
  have ->: symbolic_slice_ble s2 s1' = symbolic_slice_ble s2 s1.
  + by rewrite -> heqsub.
  case: (@idP (symbolic_slice_beq _ _)) => [heqsub2|_].
  + by apply ih.
  case hle1: (odflt _ _) => //.
  case hle2: (odflt _ _) => //.
  case: z1 z1' hall2 {ih} => [|??] [|??] // _.
  move /andP: heqsub => [/is_const_compat <- /is_const_compat <-].
  case: (match is_const _ with | Some _ => _ | _ => _ end) => [[|]|] => //.
  move=> ?; eexists; first by reflexivity.
  by apply symbolic_zone_beq_refl.
Qed.

Lemma add_sub_interval_compat se s i1 i2 i1' :
  wf_interval se i1 ->
  wf_interval se i2 ->
  add_sub_interval i1 s = Some i1' ->
  incl_interval i2 i1 ->
  exists2 i2',
    add_sub_interval i2 s = Some i2' &
    incl_interval i2' i1'.
Proof.
  elim: i1 i1' i2 => [|s1 i1 ih1] i1' i2 /=.
  + move=> _ _ [<-]. case: i2 => /=. move=> _. eexists; first by reflexivity. apply incl_interval_refl.
    done.
  move=> hwf1 hwf2.
  case h: symbolic_slice_beq.
  + move=> [<-].
    case: i2 hwf2. move=> /=. move=> _ _. eexists; first by reflexivity. move=> /=. rewrite h. done.
  move=> s2 i2 /= hwf2.
  move=> /andP [h1 h2].
  have ->: symbolic_slice_beq s s2 = symbolic_slice_beq s2 s1.
  + rewrite (symbolic_slice_beq_sym s2 s1). apply /idP/idP; apply symbolic_slice_beq_trans. symmetry. done. done.
  move: h1. case H: symbolic_slice_beq.
  + move=> _.
    eexists; first by reflexivity. simpl. rewrite H. done.
  move=> h1.
  move: hwf2 => []. admit.
  case hle1: (odflt _ _).
  + move=> [<-]. admit.
  case hle2: (odflt _ _) => //.
  apply: obindP. move=> {}i1' hadd [<-] hincl.
  have := ih1 _ _ _ _ hadd.
  t_xrbindP.
  + admit.
  
   rewrite /incl_interval. move=> /(all_nthP {| ss_ofs := 0; ss_len := 0 |}).
   move=> h0.
   case: i2. admit.
Admitted.

Lemma incl_status_compat status1 status2 z :
  incl_status status1 status2 ->
  incl_status
    (odflt Unknown (clear_status status1 z))
    (odflt Unknown (clear_status status2 z)).
Proof.
  move=> hincl.
  case: z => [//|s z] /=.
  case: status1 status2 hincl => [||i1] [||i2] //=.
  rewrite symbolic_slice_beq_refl. done.
  case hadd: add_sub_interval => //=.
  have := add_sub_interval_incl_r hadd. move=> ->. done.
  case hadd1: add_sub_interval => //=.
  move=> h.
  have := add_sub_interval_compat hadd1 h. move=> [i2' -> h'] /=. done.
  case hadd2: add_sub_interval => //=.
  move=> h.
  have:=add_sub_interval_compat hadd2 hadd1 h. done.
  have h1 := add_sub_interval_incl_l hadd1.
  have h2 := add_sub_interval_incl_l hadd2.
  move=> h.
  have := incl_interval_trans
  

Lemma subset_clear_bytes_compat rmap1 rmap2 status1 status2 z x :
  incl rmap1 rmap2 ->
  incl_status status1 status2 ->
  incl_status
    (odflt Unknown (clear_status_map_aux rmap1 z x status1))
    (odflt Unknown (clear_status_map_aux rmap2 z x status2)).
Proof.
  move=> hinclr hincls.
  rewrite /clear_status_map_aux.
  case hsr1: Mvar.get => [sr1|//].
  have [sr2 hsr2 heqsub] := incl_var_region hinclr hsr1.
  rewrite hsr2.
  have /andP [_ h] := heqsub.
  have := symbolic_zone_beq_get_suffix z h.
  case: (get_suffix (sr_zone sr1) z) => [[z1|]|]; [|by move->..].
  move=> [z2 -> heqsub'].
  clear_status
  + admit.
  + move=> -> /=. done.
  move=> ->. simpl.
   (get_suffix (sr_zone sr2) z) => [[z1|]|] [[z2|]|] //.
  case: z1.
  + case: z2 => //.
  move=> s1 z1.
  case: z2 => // s2 z2.
  case: status1 status2 hincls => [||i1] [||i2] //=.
  rewrite /symbolic_zone_beq /=. move=> _ /andP []. rewrite symbolic_slice_beq_sym. move=> ->. done.
  case hadd: add_sub_interval => [i|//] /=. admit.
  case h1: add_sub_interval => [?|//] /=.
  case h2: add_sub_interval => [?|//] /=. admit.
  add_sub_interval_incl_l
    [/symbolic_slice_beq_sym -> _].
  incl_status
  incl_status
  
  
  
  case: incl
  
  move=> /ByteSet.subsetP hsubset.
  apply /ByteSet.subsetP => z.
  rewrite /clear_bytes !ByteSet.removeE.
  move=> /andP [hmem hnmem].
  apply /andP; split=> //.
  by apply hsubset.
Qed.
*)
Lemma incl_status_map_clear_status_map_compat sm1 sm2 rmap1 rmap2 z :
  incl_status_map sm1 sm2 ->
  incl_status_map (clear_status_map rmap1 z sm1) (clear_status_map rmap2 z sm2).
Proof.
  move=> /Mvar.inclP hincl.
  apply /Mvar.inclP => x.
  rewrite /clear_status_map !Mvar.filter_mapP.
  case heq1: (Mvar.get sm1 x) (hincl x) => [status1|//] /=.
  case: Mvar.get => [status2|//] /=.
  by apply subset_clear_bytes_compat.
Qed.
*)
(* not sure whether this is a good name *)
Lemma incl_set_clear_pure_compat rmap1 rmap2 sr :
  incl rmap1 rmap2 ->
  incl (set_clear_pure rmap1 sr) (set_clear_pure rmap2 sr).
Proof.
  move=> /andP [] hincl1 /Mr.inclP hincl2.
  apply /andP; split=> //=.
  apply /Mr.inclP => r.
  rewrite /set_clear_status !Mr.setP.
  case: eqP => [?|//].
  rewrite /get_status_map.
  apply incl_status_map_clear_status_map_compat.
  rewrite /get_bytes_map.
  case heq1: Mr.get (hincl2 sr.(sr_region)) => [r1|] /=.
  + by case: Mr.get.
  move=> _.
  apply /Mvar.inclP => x.
  by rewrite Mvar.get0.
Qed.

Lemma subset_clear_bytes i bytes :
  ByteSet.subset (clear_bytes i bytes) bytes.
Proof.
  apply /ByteSet.subsetP => z.
  by rewrite /clear_bytes ByteSet.removeE => /andP [? _].
Qed.

Lemma incl_bytes_map_clear_bytes_map r i bm :
  incl_bytes_map r (clear_bytes_map i bm) bm.
Proof.
  apply /Mvar.inclP => x.
  rewrite /clear_bytes_map Mvar.mapP.
  case: Mvar.get => [bytes|//] /=.
  by apply subset_clear_bytes.
Qed.

(* If we used the optim "do not put empty bytesets in the map", then I think
   we could remove the condition. *)
Lemma incl_set_clear_pure (rmap:region_map) sr ofs len :
  Mr.get rmap sr.(sr_region) <> None ->
  incl (set_clear_pure rmap sr ofs len) rmap.
Proof.
  move=> hnnone.
  apply /andP; split=> /=.
  + apply Mvar.inclP => x.
    by case: Mvar.get.
  apply /Mr.inclP => r.
  rewrite /set_clear_bytes Mr.setP.
  case: eqP => [<-|_].
  + rewrite /get_bytes_map.
    case heq: Mr.get hnnone => [bm|//] _ /=.
    by apply incl_bytes_map_clear_bytes_map.
  case: Mr.get => // bm.
  by apply incl_bytes_map_refl.
Qed.

Lemma get_var_bytes_set_clear_bytes rv sr ofs len r y :
  get_var_bytes (set_clear_bytes rv sr ofs len) r y =
    let bytes := get_var_bytes rv r y in
    if sr.(sr_region) != r then bytes
    else
      let i := interval_of_zone (sub_zone_at_ofs sr.(sr_zone) ofs len) in
      ByteSet.remove bytes i.
Proof.
  rewrite /set_clear_bytes /get_var_bytes.
  rewrite get_bytes_map_setP.
  case: eqP => [->|] //=.
  by rewrite get_bytes_clear.
Qed.

Lemma alloc_call_arg_aux_incl (rmap0 rmap:region_map) opi e rmap2 bsr e2 :
  (forall r, Mr.get rmap0 r <> None -> Mr.get rmap r <> None) ->
  alloc_call_arg_aux pmap rmap0 rmap opi e = ok (rmap2, (bsr, e2)) ->
  incl rmap2 rmap /\ (forall r, Mr.get rmap0 r <> None -> Mr.get rmap2 r <> None).
Proof.
  move=> hincl.
  rewrite /alloc_call_arg_aux.
  t_xrbindP=> x _ _.
  case: opi => [pi|].
  + case: get_local => [pk|//].
    case: pk => // p.
    t_xrbindP=> -[[sr _] _] /get_sub_region_bytesP [bytes [hgvalid -> ->]].
    t_xrbindP=> /check_validP hmem _ /= {rmap2}rmap2 hclear <- _ _.
    case: pp_writable hclear; last first.
    + move=> [<-]; split=> //.
      by apply incl_refl.
    move=> /set_clearP [hw ->].
    split.
    + apply incl_set_clear_pure.
      apply hincl.
      move: hgvalid; rewrite /check_gvalid /=.
      case: Mvar.get => [_|//] [-> hget] hnone.
      move: hmem; rewrite -hget (get_var_bytes_None _ hnone) /=.
      have hempty: forall b, ByteSet.is_empty (ByteSet.inter ByteSet.empty b).
      + move=> b.
        apply: (is_empty_incl _ is_empty_empty).
        by apply subset_inter_l.
      move=> /mem_is_empty_l /(_ (hempty _)).
      apply /negP.
      apply interval_of_zone_wf.
      by apply size_of_gt0.
    move=> r /=.
    rewrite /set_clear_bytes Mr.setP.
    case: eqP => [//|_].
    by apply hincl.
  case: get_local => [//|].
  t_xrbindP=> _ <- _ _.
  split=> //.
  by apply incl_refl.
Qed.

Lemma alloc_call_args_aux_incl_aux (rmap0 rmap:region_map) err sao_params args rmap2 l :
  (forall r, Mr.get rmap0 r <> None -> Mr.get rmap r <> None) ->
  fmapM2 err (alloc_call_arg_aux pmap rmap0) rmap sao_params args = ok (rmap2, l) ->
  incl rmap2 rmap.
Proof.
  elim: sao_params args rmap rmap2 l.
  + by move=> [|//] rmap _ _ _ [<- _]; apply incl_refl.
  move=> opi sao_params ih [//|arg args] rmap /=.
  t_xrbindP=> _ _ hnnone [rmap1 [bsr e]] halloc [rmap2 l] /= /ih{ih}ih <- _.
  have [hincl hnnone2] := alloc_call_arg_aux_incl hnnone halloc.
  apply: (incl_trans _ hincl).
  by apply ih.
Qed.

Lemma alloc_call_args_aux_incl rmap sao_params args rmap2 l :
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  incl rmap2 rmap.
Proof. by apply alloc_call_args_aux_incl_aux. Qed.

Lemma alloc_call_arg_aux_uincl wdb m0 rmap0 rmap s1 s2 opi e1 rmap2 bsr e2 v1 :
  valid_state rmap0 m0 s1 s2 ->
  alloc_call_arg_aux pmap rmap0 rmap opi e1 = ok (rmap2, (bsr, e2)) ->
  sem_pexpr wdb gd s1 e1 = ok v1 ->
  exists v2,
    sem_pexpr wdb [::] s2 e2 = ok v2 /\
    value_eq_or_in_mem (emem s2) opi v1 v2.
Proof.
  move=> hvs.
  rewrite /alloc_call_arg_aux.
  t_xrbindP=> x /get_PvarP ->.
  case: x => x [] //= _.
  case: opi => [pi|]; last first.
  + case hlx: get_local => //.
    t_xrbindP=> /check_diffP hnnew _ _ <- /= hget.
    have hkind: get_var_kind pmap (mk_lvar x) = ok None.
    + by rewrite /get_var_kind /= hlx.
    rewrite (get_var_kindP hvs hkind hnnew hget).
    by eexists.
  case hlx: get_local => [pk|//].
  case: pk hlx => // p hlx.
  t_xrbindP=> -[[sr ?] ?] /get_sub_region_bytesP [bytes [hgvalid -> ->]] /=.
  t_xrbindP=> /check_validP hmem _ _ _ _ _ <- /= hget.
  have /wfr_gptr := hgvalid.
  rewrite /get_var_kind /= hlx => -[_ [[<-] /=]] hgetp.
  rewrite get_gvar_nglob // /get_var /= {}hgetp /= orbT /=.
  eexists; split; first by reflexivity.
  eexists; split; first by reflexivity.
  have hget' : get_gvar true gd (evm s1) {| gv := x; gs := Slocal |} = ok v1.
  + have /is_sarrP [len hty] := wfr_type (wf_pmap0.(wf_locals) hlx).
    move: hget; rewrite /get_gvar /= => /get_varP [].
    by rewrite /get_var hty => <- ? /compat_valEl [a] ->.
  have /(wfr_val hgvalid) [hread /= hty] := hget'.
  move=> off w /[dup] /get_val_byte_bound; rewrite hty => hoff.
  apply hread.
  have :=
    subset_inter_l bytes
      (ByteSet.full
        (interval_of_zone (sub_region_at_ofs sr (Some 0) (size_slot x)).(sr_zone))).
  move=> /mem_incl_l -/(_ _ hmem) {}hmem.
  rewrite memi_mem_U8; apply: mem_incl_r hmem; rewrite subset_interval_of_zone.
  rewrite -(Z.add_0_l off).
  rewrite -(sub_zone_at_ofs_compose _ _ _ (size_slot x)).
  apply zbetween_zone_byte => //.
  by apply zbetween_zone_refl.
Qed.

Lemma alloc_call_args_aux_uincl wdb rmap m0 s1 s2 sao_params args rmap2 l vargs1 :
  valid_state rmap m0 s1 s2 ->
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  sem_pexprs wdb gd s1 args = ok vargs1 ->
  exists vargs2,
    sem_pexprs wdb [::] s2 (map snd l) = ok vargs2 /\
    Forall3 (value_eq_or_in_mem (emem s2)) sao_params vargs1 vargs2.
Proof.
  move=> hvs.
  rewrite /alloc_call_args_aux.
  elim: sao_params args {2}rmap rmap2 l vargs1.
  + move=> [|//] /= _ _ _ l [_ <-] [<-] /=.
    eexists; split; first by reflexivity.
    by constructor.
  move=> opi sao_params ih [//|arg args] rmap0 /=.
  t_xrbindP=> _ _ _ [rmap1 [bsr e]] halloc [rmap2 l] /= /ih{}ih _ <-
    varg1 hvarg1 vargs1 hvargs1 <-.
  have [varg2 [hvarg2 heqinmem]] := alloc_call_arg_aux_uincl hvs halloc hvarg1.
  have [vargs2 [hvargs2 heqinmems]] := ih _ hvargs1.
  rewrite /= hvarg2 /= hvargs2 /=.
  eexists; split; first by reflexivity.
  by constructor.
Qed.

Lemma alloc_call_arg_aux_wf wdb m0 rmap0 rmap s1 s2 wptrs aligns vargs vargs' opi e1 rmap2 e2 i :
  valid_state rmap0 m0 s1 s2 ->
  alloc_call_arg_aux pmap rmap0 rmap opi e1 = ok (rmap2, e2) ->
  sem_pexpr wdb gd s1 e1 = ok (nth (Vbool true) vargs i) ->
  sem_pexpr wdb [::] s2 e2.2 = ok (nth (Vbool true) vargs' i) ->
  nth None wptrs i = omap pp_writable opi ->
  nth U8 aligns i = oapp pp_align U8 opi ->
  (nth None wptrs i = Some true ->
    forall j vai vaj (pi pj : word Uptr),
    i <> j ->
    isSome (nth None wptrs j) ->
    nth (Vbool true) vargs i = vai ->
    nth (Vbool true) vargs j = vaj ->
    nth (Vbool true) vargs' i = Vword pi ->
    nth (Vbool true) vargs' j = Vword pj ->
    disjoint_zrange pi (size_val vai) pj (size_val vaj)) ->
  wf_arg (emem s1) (emem s2) wptrs aligns vargs vargs' i.
Proof.
  move=> hvs.
  rewrite /alloc_call_arg_aux.
  t_xrbindP=> x /get_PvarP ->.
  case: x => x [] //= _.
  case: opi => [pi|]; last first.
  + case hlx: get_local => //.
    move=> _ _ _ hnreg _ _.
    by rewrite /wf_arg hnreg.
  case hlx: get_local => [pk|//].
  case: pk hlx => // p hlx.
  t_xrbindP=> -[[sr ?] ?] /get_sub_region_bytesP [bytes [hgvalid _ _]] /=.
  have /(check_gvalid_wf wfr_wf) /= hwf := hgvalid.
  t_xrbindP=> _ /(check_alignP hwf) halign {}rmap2 hclear _ <- hget /=.
  have /wfr_gptr := hgvalid.
  rewrite /get_var_kind /= hlx => -[_ [[<-] /=]] hgetp.
  rewrite get_gvar_nglob // /get_var /= {}hgetp /= orbT /=.
  (* We have [size_val v1 <= size_slot x] by [have /= hle := size_of_le (type_of_get_gvar hget)].
     The inequality is sufficient for most of the proof.
     But we even have the equality, so let's use it.
  *)
  have hget' : get_gvar true gd (evm s1) {| gv := x; gs := Slocal |} = ok (nth (Vbool true) vargs i).
  + have /is_sarrP [len hty] := wfr_type (wf_pmap0.(wf_locals) hlx).
    move: hget; rewrite /get_gvar /= => /get_varP [].
    by rewrite /get_var hty => <- ? /compat_valEl [a] ->.
  have /(wfr_val hgvalid) [_ /= hty] := hget'.
  move=> [/esym hsr] hreg hal hdisj.
  rewrite /wf_arg hreg hsr.
  eexists; split; first by reflexivity.
  split.
  + by rewrite hal.
  + have /= := no_overflow_sub_region_addr hwf.
    by rewrite hty.
  + move=> w hb.
    apply (vs_slot_valid hwf.(wfr_slot)).
    apply (zbetween_trans (zbetween_sub_region_addr hwf)).
    by rewrite -hty.
  + move=> w hvalid.
    apply: disjoint_zrange_incl_l (vs_disjoint hwf.(wfr_slot) hvalid).
    rewrite hty.
    by apply (zbetween_sub_region_addr hwf).
  + move=> hw hgsize.
    move: hclear; rewrite hw => /set_clearP [hwritable _].
    apply: disjoint_zrange_incl_r (writable_not_glob hwf.(wfr_slot) _ hgsize);
      last by rewrite hwf.(wfr_writable).
    rewrite hty.
    by apply (zbetween_sub_region_addr hwf).
  by move=> *; (eapply hdisj; first by congruence); try eassumption; reflexivity.
Qed.

Lemma alloc_call_args_aux_wf wdb rmap m0 s1 s2 sao_params args rmap2 l vargs1 vargs2 :
  valid_state rmap m0 s1 s2 ->
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  sem_pexprs wdb gd s1 args = ok vargs1 ->
  sem_pexprs wdb [::] s2 (map snd l) = ok vargs2 ->
  (forall i, nth None (map (omap pp_writable) sao_params) i = Some true ->
    forall j vai vaj (pi pj : word Uptr),
    i <> j ->
    isSome (nth None (map (omap pp_writable) sao_params) j) ->
    nth (Vbool true) vargs1 i = vai ->
    nth (Vbool true) vargs1 j = vaj ->
    nth (Vbool true) vargs2 i = Vword pi ->
    nth (Vbool true) vargs2 j = Vword pj ->
    disjoint_zrange pi (size_val vai) pj (size_val vaj)) ->
  wf_args (emem s1) (emem s2)
    (map (omap pp_writable) sao_params)
    (map (oapp pp_align U8) sao_params) vargs1 vargs2.
Proof.
  move=> hvs hallocs ok_vargs1 ok_vargs2 hdisj.
  move=> i.
  (* It is enough to show wf_arg for interesting i *)
  suff: forall writable,
    nth None [seq omap pp_writable i | i <- sao_params] i = Some writable ->
    wf_arg (emem s1) (emem s2)
      [seq omap pp_writable i | i <- sao_params]
      [seq oapp pp_align U8 i | i <- sao_params] vargs1 vargs2 i.
  + rewrite /wf_arg.
    case: nth => [writable|//].
    by apply; reflexivity.
  move=> writable hwritable.
  have := nth_not_default hwritable ltac:(discriminate); rewrite size_map => hi.
  have [hsize1 hsize2] := size_fmapM2 hallocs.
  have [rmap1 [rmap1' [_ [halloc _]]]] :=
    fmapM2_nth None (Pconst 0) (None, Pconst 0) hallocs hi.
  apply (alloc_call_arg_aux_wf (wdb:=wdb) hvs halloc).
  + apply (mapM_nth (Pconst 0) (Vbool true) ok_vargs1).
    by rewrite -hsize1.
  + rewrite -(nth_map _ (Pconst 0)); last by rewrite -hsize2.
    apply (mapM_nth (Pconst 0) (Vbool true) ok_vargs2).
    by rewrite size_map -hsize2.
  + by rewrite (nth_map None).
  + by rewrite (nth_map None).
  exact: hdisj.
Qed.

Lemma alloc_call_arg_aux_sub_region wdb m0 rmap0 rmap s1 s2 opi e1 rmap2 bsr e2 v1 v2 :
  valid_state rmap0 m0 s1 s2 ->
  alloc_call_arg_aux pmap rmap0 rmap opi e1 = ok (rmap2, (bsr, e2)) ->
  sem_pexpr wdb gd s1 e1 = ok v1 ->
  sem_pexpr wdb [::] s2 e2 = ok v2 -> [/\
  forall b sr, bsr = Some (b, sr) ->
    v2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val v1) &
  forall sr, bsr = Some (true, sr) ->
    incl rmap2 (set_clear_pure rmap sr (Some 0%Z) (size_val v1))].
Proof.
  move=> hvs.
  rewrite /alloc_call_arg_aux.
  t_xrbindP=> x /get_PvarP ->.
  case: x => x [] //= _.
  case: opi => [pi|]; last first.
  + case hlx: get_local => //.
    t_xrbindP=> /check_diffP hnnew _ <- _ _ _.
    by split.
  case hlx: get_local => [pk|//].
  case: pk hlx => // p hlx.
  t_xrbindP=> -[[sr _] _] /get_sub_region_bytesP [bytes [hgvalid -> ->]] /=.
  have /(check_gvalid_wf wfr_wf) /= hwf := hgvalid.
  t_xrbindP=> _ _ {rmap2}rmap2 hclear <- <- <- hget /=.
  have /wfr_gptr := hgvalid.
  rewrite /get_var_kind /= hlx => -[_ [[<-] /=]] hgetp.
  rewrite get_gvar_nglob // /get_var /= {}hgetp /= orbT /= => -[<-].
  (* We have [size_val v1 <= size_slot x] by [have /= hle := size_of_le (type_of_get_gvar hget)].
     The inequality is sufficient for most of the proof.
     But we even have the equality, so let's use it.
  *)
  have hget' : get_gvar true gd (evm s1) {| gv := x; gs := Slocal |} = ok v1.
  + have /is_sarrP [len hty] := wfr_type (wf_pmap0.(wf_locals) hlx).
    move: hget; rewrite /get_gvar /= => /get_varP [].
    by rewrite /get_var hty => <- ? /compat_valEl [a] ->.
  have /(wfr_val hgvalid) [_ /= hty] := hget'.
  split.
  + move=> _ _ [_ <-].
    split=> //.
    by rewrite hty.
  move=> _ [hw <-].
  move: hclear; rewrite hw => /set_clearP [_ ->].
  by rewrite hty; apply incl_refl.
Qed.

Lemma alloc_call_args_aux_sub_region wdb rmap m0 s1 s2 sao_params args rmap2 l vargs1 vargs2 :
  valid_state rmap m0 s1 s2 ->
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) ->
  sem_pexprs wdb gd s1 args = ok vargs1 ->
  sem_pexprs wdb [::] s2 (map snd l) = ok vargs2 -> [/\
    Forall3 (fun bsr varg1 varg2 => forall (b:bool) (sr:sub_region), bsr = Some (b, sr) ->
      varg2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val varg1)) (map fst l) vargs1 vargs2 &
    List.Forall2 (fun bsr varg1 => forall sr, bsr = Some (true, sr) ->
      incl rmap2 (set_clear_pure rmap sr (Some 0%Z) (size_val varg1))) (map fst l) vargs1].
Proof.
  move=> hvs.
  have: forall r, Mr.get rmap r <> None -> Mr.get rmap r <> None by done.
  rewrite /alloc_call_args_aux.
  elim: sao_params args {-1 3}rmap rmap2 l vargs1 vargs2.
  + move=> [|//] /= rmap0 _ _ _ _ _ [<- <-] [<-] [<-].
    by split; constructor.
  move=> opi sao_params ih [//|arg args] rmap0 /=.
  t_xrbindP=> _ _ _ + hnnone [rmap1 [bsr e]] halloc [rmap2 l] /= hallocs <- <- varg1 hvarg1 vargs1 hvargs1 <- /=.
  t_xrbindP=> _ varg2 hvarg2 vargs2 hvargs2 <-.
  have [haddr hclear] := alloc_call_arg_aux_sub_region hvs halloc hvarg1 hvarg2.
  have [hincl hnnone2] := alloc_call_arg_aux_incl hnnone halloc.
  have [haddrs hclears] := ih _ _ _ _ _ _ hnnone2 hallocs hvargs1 hvargs2.
  split; constructor=> //.
  + move=> sr /hclear.
    apply: incl_trans.
    by apply (alloc_call_args_aux_incl_aux hnnone2 hallocs).
  apply: Forall2_impl hclears.
  move=> _ v1 hincl' sr /hincl'{hincl'}hincl'.
  apply (incl_trans hincl').
  by apply: incl_set_clear_pure_compat hincl.
Qed.

(* we could benefit from [seq.allrel] but it exists only in recent versions *)
Lemma check_all_disjP notwritables writables srs :
  check_all_disj notwritables writables srs -> [/\
  forall b1 sr1 sr2, Some (b1, sr1) \in (map fst srs) -> sr2 \in writables -> disj_sub_regions sr1 sr2,
  forall sr1 sr2, Some (true, sr1) \in (map fst srs) -> sr2 \in notwritables -> disj_sub_regions sr1 sr2 &
  forall i1 sr1 i2 b2 sr2, nth None (map fst srs) i1 = Some (true, sr1) -> nth None (map fst srs) i2 = Some (b2, sr2) ->
    i1 <> i2 -> disj_sub_regions sr1 sr2].
Proof.
  elim: srs notwritables writables.
  + move=> notwritables writables _.
    split=> // i1 b1 sr1 i2 b2 sr2.
    by rewrite nth_nil.
  move=> [bsr e] srs ih notwritables writables /=.
  case: bsr => [[b sr]|]; last first.
  + move=> /ih [ih1 ih2 ih3].
    split.
    + move=> b1 sr1 sr2.
      rewrite in_cons /=.
      by apply ih1.
    + move=> sr1 sr2.
      rewrite in_cons /=.
      by apply ih2.
    move=> [//|i1] sr1 [//|i2] b2 sr2 /= hnth1 hnth2 hneq.
    by apply: ih3 hnth1 hnth2 ltac:(congruence).
  case: allP => // hdisj.
  case: b; last first.
  + move=> /ih [ih1 ih2 ih3].
    split.
    + move=> b1 sr1 sr2.
      rewrite in_cons => /orP [/eqP [_ ->]|hin1] hin2.
      + by apply hdisj.
      by apply: ih1 hin1 hin2.
    + move=> sr1 sr2.
      rewrite in_cons /= => hin1 hin2.
      apply ih2 => //.
      rewrite in_cons.
      by apply /orP; right.
    move=> [//|i1] sr1 [|i2] b2 sr2 /=.
    + move=> hnth1 [_ <-] _.
      apply ih2; last by apply mem_head.
      rewrite -hnth1.
      apply mem_nth.
      by apply (nth_not_default hnth1 ltac:(discriminate)).
    move=> hnth1 hnth2 hneq.
    by apply: ih3 hnth1 hnth2 ltac:(congruence).
  case: allP => // hdisj2.
  move=> /ih [ih1 ih2 ih3].
  split.
  + move=> b1 sr1 sr2.
    rewrite in_cons => /orP [/eqP [_ ->]|hin1] hin2.
    + by apply hdisj.
    apply (ih1 _ _ _ hin1).
    rewrite in_cons.
    by apply /orP; right.
  + move=> sr1 sr2.
    rewrite in_cons => /orP [/eqP [->]|hin1] hin2.
    + by apply hdisj2.
    by apply ih2.
  move=> i1 sr1 i2 b2 sr2.
  case: i1 => [|i1].
  + case: i2 => [//|i2].
    move=> /= [<-] hnth2 _.
    rewrite disj_sub_regions_sym.
    apply (ih1 b2); last by apply mem_head.
    rewrite -hnth2.
    apply mem_nth.
    by apply (nth_not_default hnth2 ltac:(discriminate)).
  move=> /= hnth1.
  case: i2 => [|i2].
  + move=> [_ <-] _.
    apply (ih1 true); last by apply mem_head.
    rewrite -hnth1.
    apply mem_nth.
    by apply (nth_not_default hnth1 ltac:(discriminate)).
  move=> /= hnth2 hneq.
  apply: ih3 hnth1 hnth2 ltac:(congruence).
Qed.

Lemma disj_sub_regions_disjoint_zrange sr1 sr2 ty1 ty2 :
  wf_sub_region sr1 ty1 ->
  wf_sub_region sr2 ty2 ->
  disj_sub_regions sr1 sr2 ->
  sr1.(sr_region).(r_writable) ->
  disjoint_zrange (sub_region_addr sr1) (size_of ty1) (sub_region_addr sr2) (size_of ty2).
Proof.
  move=> hwf1 hwf2 hdisj hw.
  move: hdisj; rewrite /disj_sub_regions /region_same.
  case: eqP => heqr /=.
  + move=> hdisj.
    apply (disjoint_zones_disjoint_zrange hwf1 hwf2).
    + by apply (wf_region_slot_inj hwf1 hwf2).
    apply: disjoint_zones_incl hdisj.
    + by apply (zbetween_zone_sub_zone_at_ofs_0 hwf1).
    by apply (zbetween_zone_sub_zone_at_ofs_0 hwf2).
  move=> _.
  by apply (distinct_regions_disjoint_zrange hwf1 hwf2 ltac:(congruence) hw).
Qed.

Lemma disj_sub_regions_disjoint_values (srs:seq (option (bool * sub_region))) sao_params vargs1 vargs2 :
  (forall i1 sr1 i2 b2 sr2, nth None srs i1 = Some (true, sr1) -> nth None srs i2 = Some (b2, sr2) ->
    i1 <> i2 -> disj_sub_regions sr1 sr2) ->
  List.Forall2 (fun opi bsr => forall pi, opi = Some pi -> exists sr, bsr = Some (pi.(pp_writable), sr)) sao_params srs ->
  List.Forall (fun bsr => forall sr, bsr = Some (true, sr) -> sr.(sr_region).(r_writable)) srs ->
  Forall3 (fun bsr varg1 varg2 => forall (b:bool) (sr:sub_region), bsr = Some (b, sr) ->
    varg2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val varg1)) srs vargs1 vargs2 ->
  forall i, nth None (map (omap pp_writable) sao_params) i = Some true ->
    forall j vai vaj (pi pj : word Uptr),
    i <> j ->
    isSome (nth None (map (omap pp_writable) sao_params) j) ->
    nth (Vbool true) vargs1 i = vai ->
    nth (Vbool true) vargs1 j = vaj ->
    nth (Vbool true) vargs2 i = Vword pi ->
    nth (Vbool true) vargs2 j = Vword pj ->
    disjoint_zrange pi (size_val vai) pj (size_val vaj).
Proof.
  move=> hdisj hnnone hwritable haddr.
  move=> i hwi j vai vaj pi pj neq_ij /isSomeP [wj hwj] hvai hvaj hpi hpj.
  have := nth_not_default hwi ltac:(discriminate); rewrite size_map => hi.
  have := nth_not_default hwj ltac:(discriminate); rewrite size_map => hj.
  move: hwi; rewrite (nth_map None) // => /oseq.obindI [pii [hpii [hwi]]].
  move: hwj; rewrite (nth_map None) // => /oseq.obindI [pij [hpij _]].
  have := Forall2_nth hnnone None None.
  move=> /[dup].
  move=> /(_ _ hi _ hpii); rewrite hwi => -[sri hsri].
  move=> /(_ _ hj _ hpij) [srj hsrj].
  have /InP hini := mem_nth None (nth_not_default hsri ltac:(discriminate)).
  have /List.Forall_forall -/(_ _ hini _ hsri) hwi' := hwritable.
  have := Forall3_nth haddr None (Vbool true) (Vbool true).
  move=> /[dup].
  move=> /(_ _ (nth_not_default hsri ltac:(discriminate)) _ _ hsri).
  rewrite hpi hvai => -[[?] hwfi]; subst pi.
  move=> /(_ _ (nth_not_default hsrj ltac:(discriminate)) _ _ hsrj).
  rewrite hpj hvaj => -[[?] hwfj]; subst pj.
  apply (disj_sub_regions_disjoint_zrange hwfi hwfj) => //.
  by apply: hdisj hsri hsrj neq_ij.
Qed.

(* TODO: is it a good name? *)
Lemma alloc_call_argsE rmap sao_params args rmap2 l :
  alloc_call_args pmap rmap sao_params args = ok (rmap2, l) ->
  alloc_call_args_aux pmap rmap sao_params args = ok (rmap2, l) /\
  check_all_disj [::] [::] l.
Proof.
  rewrite /alloc_call_args.
  by t_xrbindP=> -[{rmap2}rmap2 {l}l] halloc hdisj [<- <-].
Qed.

(* Full spec *)
Lemma alloc_call_argsP wdb rmap m0 s1 s2 sao_params args rmap2 l vargs1 :
  valid_state rmap m0 s1 s2 ->
  alloc_call_args pmap rmap sao_params args = ok (rmap2, l) ->
  sem_pexprs wdb gd s1 args = ok vargs1 ->
  exists vargs2, [/\
    sem_pexprs wdb [::] s2 (map snd l) = ok vargs2,
    wf_args (emem s1) (emem s2)
      (map (omap pp_writable) sao_params)
      (map (oapp pp_align U8) sao_params) vargs1 vargs2,
    Forall3 (value_eq_or_in_mem (emem s2)) sao_params vargs1 vargs2,
    Forall3 (fun bsr varg1 varg2 => forall (b:bool) (sr:sub_region), bsr = Some (b, sr) ->
      varg2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val varg1)) (map fst l) vargs1 vargs2 &
    List.Forall2 (fun bsr varg1 => forall sr, bsr = Some (true, sr) ->
      incl rmap2 (set_clear_pure rmap sr (Some 0%Z) (size_val varg1))) (map fst l) vargs1].
Proof.
  move=> hvs /alloc_call_argsE [halloc hdisj] hvargs1.
  have [vargs2 [hvargs2 heqinmems]] := alloc_call_args_aux_uincl hvs halloc hvargs1.
  have [haddr hclear] := alloc_call_args_aux_sub_region hvs halloc hvargs1 hvargs2.
  have [_ _ {}hdisj] := check_all_disjP hdisj.
  have {}hdisj :=
    disj_sub_regions_disjoint_values hdisj
      (alloc_call_args_aux_not_None halloc)
      (alloc_call_args_aux_writable halloc) haddr.
  have hwf := alloc_call_args_aux_wf hvs halloc hvargs1 hvargs2 hdisj.
  by exists vargs2; split.
Qed.

Lemma mem_unchanged_holed_rmap m0 s1 s2 mem1 mem2 l :
  valid_incl m0 (emem s2) ->
  validw (emem s1) =3 validw mem1 ->
  List.Forall (fun '(sr, ty) => wf_sub_region sr ty /\ sr.(sr_region).(r_writable)) l ->
  (forall p,
    validw (emem s2) Aligned p U8 -> ~ validw (emem s1) Aligned p U8 ->
    List.Forall (fun '(sr, ty) => disjoint_zrange (sub_region_addr sr) (size_of ty) p (wsize_size U8)) l ->
    read mem2 Aligned p U8 = read (emem s2) Aligned p U8) ->
  mem_unchanged (emem s1) m0 (emem s2) ->
  mem_unchanged mem1 m0 mem2.
Proof.
  move=> hincl hvalideq1 hlwf hlunch hunch p hvalid1 hvalid2 hdisj.
  rewrite -hvalideq1 in hvalid2.
  rewrite (hunch _ hvalid1 hvalid2 hdisj).
  symmetry; apply hlunch => //.
  + by apply hincl.
  apply List.Forall_forall => -[sr ty] hin.
  have /List.Forall_forall -/(_ _ hin) [hwf hw] := hlwf.
  apply (disjoint_zrange_incl_l (zbetween_sub_region_addr hwf)).
  apply (hdisj _ hwf.(wfr_slot)).
  by rewrite hwf.(wfr_writable).
Qed.

(* "holed" because [rmap.(region_var)] does not contain any information about the sub-regions in [l]. *)
Lemma eq_read_holed_rmap rmap m0 s1 s2 mem2 l sr ty off :
  valid_state rmap m0 s1 s2 ->
  List.Forall (fun '(sr, ty) => wf_sub_region sr ty /\ sr.(sr_region).(r_writable)) l ->
  (forall p,
    validw (emem s2) Aligned p U8 -> ~ validw (emem s1) Aligned p U8 ->
    List.Forall (fun '(sr, ty) => disjoint_zrange (sub_region_addr sr) (size_of ty) p (wsize_size U8)) l ->
    read mem2 Aligned p U8 = read (emem s2) Aligned p U8) ->
  List.Forall (fun '(sr, ty) => forall x,
    ByteSet.disjoint (get_var_bytes rmap sr.(sr_region) x) (ByteSet.full (interval_of_zone (sr.(sr_zone))))) l ->
  wf_sub_region sr ty ->
  0 <= off /\ off < size_of ty ->
  (sr.(sr_region).(r_writable) -> exists x, ByteSet.memi (get_var_bytes rmap sr.(sr_region) x) (z_ofs (sr_zone sr) + off)) ->
  read mem2 Aligned (sub_region_addr sr + wrepr _ off)%R U8 = read (emem s2) Aligned (sub_region_addr sr + wrepr _ off)%R U8.
Proof.
  move=> hvs hlwf hlunch hldisj hwf hoff hmem.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwfr heqmem hglobv htop.
  apply hlunch.
  + apply (hvalid _ _ hwf.(wfr_slot)).
    apply: between_byte hoff.
    + by apply (no_overflow_sub_region_addr hwf).
    by apply (zbetween_sub_region_addr hwf).
  + move=> hval.
    have := hdisj _ _ hwf.(wfr_slot) hval.
    apply zbetween_not_disjoint_zrange => //.
    apply: between_byte hoff.
    + by apply (no_overflow_sub_region_addr hwf).
    by apply (zbetween_sub_region_addr hwf).
  apply List.Forall_forall => -[sr2 ty2] hin2.
  have /List.Forall_forall -/(_ _ hin2) hdisj2 := hldisj.
  have /List.Forall_forall -/(_ _ hin2) [hwf2 hw2] := hlwf.
  rewrite (sub_region_addr_offset (size_of sword8)).
  change (wsize_size U8) with (size_of sword8).
  have hwf' := sub_region_at_ofs_wf_byte hwf hoff.
  case: (sr2.(sr_region) =P sr.(sr_region)) => heqr.
  + apply (disjoint_zones_disjoint_zrange hwf2 hwf') => //.
    move: hmem; rewrite -heqr => /(_ hw2) [x hmem].
    move: (hdisj2 x) => /ByteSet.disjointP /(_ _ hmem).
    rewrite ByteSet.fullE /I.memi /disjoint_zones /= !zify wsize8.
    by have := hwf2.(wfz_len); lia.
  by apply (distinct_regions_disjoint_zrange hwf2 hwf').
Qed.

Lemma wfr_VAL_holed_rmap rmap m0 s1 s2 mem1 mem2 l :
  valid_state rmap m0 s1 s2 ->
  List.Forall (fun '(sr, ty) => wf_sub_region sr ty /\ sr.(sr_region).(r_writable)) l ->
  (forall p,
    validw (emem s2) Aligned p U8 -> ~ validw (emem s1) Aligned p U8 ->
    List.Forall (fun '(sr, ty) => disjoint_zrange (sub_region_addr sr) (size_of ty) p (wsize_size U8)) l ->
    read mem2 Aligned p U8 = read (emem s2) Aligned p U8) ->
  List.Forall (fun '(sr, ty) => forall x,
    ByteSet.disjoint (get_var_bytes rmap sr.(sr_region) x) (ByteSet.full (interval_of_zone (sr.(sr_zone))))) l ->
  wfr_VAL rmap (with_mem s1 mem1) (with_mem s2 mem2).
Proof.
  move=> hvs hlwf hlunch hldisj.
  move=> x sr bytes v /= hgvalid /(wfr_val hgvalid) [hread hty].
  have /(check_gvalid_wf wfr_wf) /= hwf := hgvalid.
  split=> // off hmem w /[dup] /get_val_byte_bound; rewrite hty => hoff hget.
  rewrite -(hread _ hmem _ hget).
  apply (eq_read_holed_rmap hvs hlwf hlunch hldisj hwf hoff).
  move=> hw.
  by exists x.(gv); move: hmem; have -> := check_gvalid_writable hw hgvalid.
Qed.

Lemma wfr_PTR_holed_rmap rmap m0 s1 s2 mem2 l :
  valid_state rmap m0 s1 s2 ->
  List.Forall (fun '(sr, ty) => wf_sub_region sr ty /\ sr.(sr_region).(r_writable)) l ->
  (forall p,
    validw (emem s2) Aligned p U8 -> ~ validw (emem s1) Aligned p U8 ->
    List.Forall (fun '(sr, ty) => disjoint_zrange (sub_region_addr sr) (size_of ty) p (wsize_size U8)) l ->
    read mem2 Aligned p U8 = read (emem s2) Aligned p U8) ->
  List.Forall (fun '(sr, ty) => forall x,
    ByteSet.disjoint (get_var_bytes rmap sr.(sr_region) x) (ByteSet.full (interval_of_zone (sr.(sr_zone))))) l ->
  wfr_PTR rmap (with_mem s2 mem2).
Proof.
  move=> hvs hlwf hlunch hldisj.
  move=> x sr /wfr_ptr [pk [hlx hpk]].
  exists pk; split=> //.
  case: pk hlx hpk => // s ofs ws z f hlx /= hpk hcheck.
  rewrite -(hpk hcheck).
  apply eq_read => al i hi; rewrite addE.
  have /wf_locals /= hlocal := hlx.
  have hwfs := sub_region_stkptr_wf hlocal.
  rewrite !(read8_alignment Aligned).
  apply (eq_read_holed_rmap hvs hlwf hlunch hldisj hwfs hi).
  move=> _; exists f.
  rewrite memi_mem_U8; apply: mem_incl_r hcheck; rewrite subset_interval_of_zone.
  rewrite -(Z.add_0_l i).
  rewrite -(sub_zone_at_ofs_compose _ _ _ (size_of spointer)).
  apply zbetween_zone_byte => //.
  by apply zbetween_zone_refl.
Qed.

Lemma valid_state_holed_rmap rmap m0 s1 s2 mem1 mem2 l :
  valid_state rmap m0 s1 s2 ->
  validw (emem s1) =3 validw mem1 ->
  stack_stable (emem s2) mem2 ->
  validw (emem s2) =3 validw mem2 ->
  eq_mem_source mem1 mem2 ->
  List.Forall (fun '(sr, ty) => wf_sub_region sr ty /\ sr.(sr_region).(r_writable)) l ->
  (forall p,
    validw (emem s2) Aligned p U8 -> ~ validw (emem s1) Aligned p U8 ->
    List.Forall (fun '(sr, ty) => disjoint_zrange (sub_region_addr sr) (size_of ty) p (wsize_size U8)) l ->
    read mem2 Aligned p U8 = read (emem s2) Aligned p U8) ->
  List.Forall (fun '(sr, ty) => forall x,
    ByteSet.disjoint (get_var_bytes rmap sr.(sr_region) x) (ByteSet.full (interval_of_zone (sr.(sr_zone))))) l ->
  valid_state rmap m0 (with_mem s1 mem1) (with_mem s2 mem2).
Proof.
  move=> hvs hvalideq1 hss2 hvalideq2 heqmem_ hlwf hlunch hldisj.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwfr heqmem hglobv htop.
  constructor=> //=.
  + by move=> ??; rewrite -hvalideq2; apply hvalid.
  + by move=> ??; rewrite -hvalideq1; apply hdisj.
  + by move=> ?; rewrite -hvalideq1 -hvalideq2; apply hincl.
  + by move=> ?; rewrite -hvalideq2; apply hincl2.
  + by apply (mem_unchanged_holed_rmap hincl2 hvalideq1 hlwf hlunch hunch).
  + case: (hwfr) => hwfsr hval hptr; split=> //.
    + by apply (wfr_VAL_holed_rmap hvs hlwf hlunch hldisj).
    by apply (wfr_PTR_holed_rmap hvs hlwf hlunch hldisj).
  by rewrite -(ss_top_stack hss2).
Qed.

Lemma check_lval_reg_callP r tt :
  check_lval_reg_call pmap r = ok tt ->
    (exists ii ty, r = Lnone ii ty) \/
    exists x,
      [/\ r = Lvar x, Mvar.get pmap.(locals) x = None & ~ Sv.In x pmap.(vnew)].
Proof.
  rewrite /check_lval_reg_call.
  case: r => //.
  + move=> ii ty _.
    by left; exists ii, ty.
  move=> x.
  case heq: get_local => [//|].
  t_xrbindP=> /check_diffP ? _.
  by right; exists x.
Qed.

(* Another lemma on [set_sub_region].
   See [valid_state_set_move_regptr].
*)
Lemma valid_state_set_sub_region_regptr wdb rmap m0 s1 s2 sr ty (x:var_i) ofs ty2 p rmap2 v :
  type_of_val (Vword (sub_region_addr sr)) = vtype p ->
  valid_state rmap m0 s1 s2 ->
  wf_sub_region sr ty ->
  subtype x.(vtype) ty ->
  (forall zofs, ofs = Some zofs -> 0 <= zofs /\ zofs + size_of ty2 <= size_of ty) ->
  get_local pmap x = Some (Pregptr p) ->
  set_sub_region rmap x sr ofs (size_of ty2) = ok rmap2 ->
  truncatable wdb (vtype x) v ->
  eq_sub_region_val x.(vtype) (emem s2) sr (get_var_bytes rmap2 sr.(sr_region) x) (vm_truncate_val (vtype x) v) ->
  valid_state rmap2 m0 (with_vm s1 (evm s1).[x <- v])
                       (with_vm s2 (evm s2).[p <- Vword (sub_region_addr sr)]).
Proof.
  move=> h hvs hwf hsub hofs hlx hset htrx heqval.
  have hwf' := sub_region_at_ofs_wf hwf hofs.
  have hwf'' := wf_sub_region_subtype hsub hwf.
  have /wf_locals /= hlocal := hlx.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwfr heqmem hglobv htop.
  constructor=> //=.
  + rewrite Vm.setP_neq //.
    by apply/eqP/hlocal.(wfr_not_vrip).
  + rewrite Vm.setP_neq //.
    by apply/eqP/hlocal.(wfr_not_vrsp).
  + move=> y hget hnnew.
    rewrite Vm.setP_neq; last by apply/eqP; rewrite /get_local in hlx; congruence.
    rewrite Vm.setP_neq; last by apply/eqP; have := hlocal.(wfr_new); congruence.
    by apply heqvm.
  case: (hwfr) => hwfsr hval hptr; split.
  + apply (wfr_WF_set hwfsr hwf'').
    by have [_ ->] := set_sub_regionP hset.
  + move=> y sry bytesy vy.
    move=> /(check_gvalid_set_sub_region hwf'' hset) [].
    + move=> [/negP h1 h2 <- ->].
      rewrite /get_gvar is_lvar_is_glob h1 -h2 get_var_eq //; first by t_xrbindP => hd <-.
      have /is_sarrP [len hty] := wfr_type (wf_pmap0.(wf_locals) hlx).
      by move: htrx; rewrite hty => /vm_truncate_valEl_wdb /= [? ->].
    move=> [? [bytes [hgvalid ->]]].
    rewrite get_gvar_neq => // /(wfr_val hgvalid).
    assert (hwfy := check_gvalid_wf wfr_wf hgvalid).
    case: eqP => heqr /=.
    + by apply (eq_sub_region_val_same_region hwf' hwfy heqr).
    apply: (eq_sub_region_val_distinct_regions hwf' hwfy heqr) => //.
    by case /set_sub_regionP : hset.
  move=> y sry.
  have /set_sub_regionP [_ ->] /= := hset.
  rewrite Mvar.setP; case: eqP.
  + move=> <- [<-].
    exists (Pregptr p); split=> //=; rewrite Vm.setP_eq; first by rewrite vm_truncate_val_eq.
  move=> hneq /hptr [pk [hly hpk]].
  exists pk; split=> //.
  case: pk hly hpk => //=.
  + move=> py hly.
    have ? := hlocal.(wfr_distinct) hly hneq.
    by rewrite Vm.setP_neq //; apply /eqP.
  move=> s osf ws z f hly hpk.
  rewrite /check_stack_ptr get_var_bytes_set_pure_bytes.
  case: eqP => [_|//].
  case: eqP => [heq|_].
  + have /wf_locals /wfs_new := hly.
    by have /wf_vnew := hlx; congruence.
  by move=> /(mem_remove_interval_of_zone (wf_zone_len_gt0 hwf')) -/(_ ltac:(done)) [/hpk ? _].
Qed.

Lemma alloc_lval_callP wdb rmap m0 s1 s2 srs r oi rmap2 r2 vargs1 vargs2 vres1 vres2 s1' :
  valid_state rmap m0 s1 s2 ->
  alloc_lval_call pmap srs rmap r oi = ok (rmap2, r2) ->
  Forall3 (fun bsr varg1 varg2 => forall (b:bool) (sr:sub_region), bsr = Some (b, sr) ->
    varg2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val varg1)) (map fst srs) vargs1 vargs2 ->
  wf_result vargs1 vargs2 oi vres1 vres2 ->
  value_eq_or_in_mem (emem s2) oi vres1 vres2 ->
  write_lval wdb gd r vres1 s1 = ok s1' ->
  exists s2', [/\
    write_lval wdb [::] r2 vres2 s2 = ok s2' &
    valid_state rmap2 m0 s1' s2'].
Proof.
  move=> hvs halloc haddr hresult heqinmem hs1'.
  move: halloc; rewrite /alloc_lval_call.
  case: oi hresult heqinmem => [i|]; last first.
  + move=> _ ->.
    t_xrbindP=> /check_lval_reg_callP hcheck <- <-.
    case: hcheck.
    + move=> [ii [ty ?]]; subst r.
      by move /write_noneP : hs1';rewrite /= /write_none => -[-> -> ->]; exists s2.
    move=> [x [? hlx hnnew]]; subst r.
    move /write_varP: hs1' => [-> hdb h] /=.
    rewrite (write_var_truncate hdb h) //.
    by eexists;(split;first by reflexivity) => //; apply valid_state_set_var.
  move=> /= hresp [w [? hread]]; subst vres2.
  case hnth: nth => [[[b sr]|//] ?].
  have {hnth}hnth: nth None (map fst srs) i = Some (b, sr).
  + rewrite (nth_map (None, Pconst 0)) ?hnth //.
    by apply (nth_not_default hnth ltac:(discriminate)).
  case: r hs1' => //.
  + move=> ii ty /= /write_noneP [-> ? hdb][<- <-] /=; rewrite /write_none /=.
    by rewrite cmp_le_refl /= /DB !orbT /=; eexists.
  t_xrbindP=> x hs1' p /get_regptrP hlx {rmap2}rmap2 hset <- <-.
  have /wf_locals hlocal := hlx.
  move/write_varP: hs1' => [-> hdb h].
  have /is_sarrP [nx hty] := hlocal.(wfr_type).
  have :=
    Forall3_nth haddr None (Vbool true) (Vbool true) (nth_not_default hnth ltac:(discriminate)) _ _ hnth.
  rewrite -hresp.(wrp_args) => -[[?] hwf]; subst w.
  set vp := Vword (sub_region_addr sr).
  exists (with_vm s2 (evm s2).[p <- vp]).
  have : type_of_val vp = vtype p by rewrite hlocal.(wfr_rtype).
  split; first by apply write_var_eq_type => //; rewrite /DB /= orbT.
  have : type_of_val vres1 = sarr nx.
  + by move/vm_truncate_valEl_wdb: h; rewrite hty /= => -[a ->].
  move=> /type_of_valI -[a' ?]; subst vres1.
  have /vm_truncate_valE_wdb [? heq]:= h.
  apply: (valid_state_set_sub_region_regptr (wdb:= false) _ hvs _ (subtype_refl _) _ hlx hset) => //.
  + apply: wf_sub_region_subtype hwf.
    apply: subtype_trans hresp.(wrp_subtype).
    by rewrite hty.
  + by move=> _ [<-] /=; lia.
  by rewrite heq; split => //= off hmem w; apply hread.
Qed.

Lemma alloc_lval_call_lv_write_mem srs rmap r oi rmap2 r2 :
  alloc_lval_call pmap srs rmap r oi = ok (rmap2, r2) ->
  ~~ lv_write_mem r2.
Proof.
  rewrite /alloc_lval_call.
  case: oi => [i|].
  + case: nth => [[[b sr]|//] e].
    case: r => //.
    + by move=> ii ty [_ <-].
    by t_xrbindP=> _ p _ _ _ _ <-.
  t_xrbindP=> /check_lval_reg_callP hcheck _ <-.
  case: hcheck.
  + by move=> [_ [_ ->]] /=.
  by move=> [x [-> _ _]].
Qed.

Lemma alloc_call_resP wdb rmap m0 s1 s2 srs ret_pos rs rmap2 rs2 vargs1 vargs2 vres1 vres2 s1' :
  valid_state rmap m0 s1 s2 ->
  alloc_call_res pmap rmap srs ret_pos rs = ok (rmap2, rs2) ->
  Forall3 (fun bsr varg1 varg2 => forall (b:bool) (sr:sub_region), bsr = Some (b, sr) ->
    varg2 = Vword (sub_region_addr sr) /\ wf_sub_region sr (type_of_val varg1)) (map fst srs) vargs1 vargs2 ->
  Forall3 (wf_result vargs1 vargs2) ret_pos vres1 vres2 ->
  Forall3 (value_eq_or_in_mem (emem s2)) ret_pos vres1 vres2 ->
  write_lvals wdb gd s1 rs vres1 = ok s1' ->
  exists s2',
    write_lvals wdb [::] s2 rs2 vres2 = ok s2' /\
    valid_state rmap2 m0 s1' s2'.
Proof.
  move=> hvs halloc haddr hresults.
  move hmem: (emem s2) => m2 heqinmems.
  elim: {ret_pos vres1 vres2} hresults heqinmems rmap s1 s2 hvs hmem rs rmap2 rs2 halloc s1'.
  + move=> _ rmap s1 s2 hvs _ [|//] _ _ /= [<- <-] _ [<-].
    by eexists; split; first by reflexivity.
  move=> oi vr1 vr2 ret_pos vres1 vres2 hresult _ ih /= /List_Forall3_inv [heqinmem heqinmems]
    rmap0 s1 s2 hvs ? [//|r rs] /=; subst m2.
  t_xrbindP=> _ _ [rmap1 r2] hlval [rmap2 rs2] /= halloc <- <- s1'' s1' hs1' hs1''.
  have [s2' [hs2' hvs']] := alloc_lval_callP hvs hlval haddr hresult heqinmem hs1'.
  have heqmem := esym (lv_write_memP (alloc_lval_call_lv_write_mem hlval) hs2').
  have [s2'' [hs2'' hvs'']] := ih heqinmems _ _ _ hvs' heqmem _ _ _ halloc _ hs1''.
  rewrite /= hs2' /= hs2'' /=.
  by eexists; split; first by reflexivity.
Qed.

Lemma check_resultP wdb rmap m0 s1 s2 srs params (sao_return:option nat) res1 res2 vres1 vargs1 vargs2 :
  valid_state rmap m0 s1 s2 ->
  Forall3 (fun osr (x : var_i) v => osr <> None -> subtype x.(vtype) (type_of_val v)) srs params vargs1 ->
  List.Forall2 (fun osr varg2 => forall sr, osr = Some sr -> varg2 = Vword (sub_region_addr sr)) srs vargs2 ->
  check_result pmap rmap srs params sao_return res1 = ok res2 ->
  get_var wdb (evm s1) res1 = ok vres1 ->
  exists vres2, [/\
    get_var wdb (evm s2) res2 = ok vres2,
    wf_result vargs1 vargs2 sao_return vres1 vres2 &
    value_eq_or_in_mem (emem s2) sao_return vres1 vres2].
Proof.
  move=> hvs hsize haddr hresult hget.
  move: hresult; rewrite /check_result.
  case: sao_return => [i|].
  + case heq: nth => [sr|//].
    t_xrbindP=> /eqP heqty -[[sr' _] _] /get_sub_region_bytesP [bytes [hgvalid -> ->]].
    t_xrbindP=> /check_validP hmem /eqP ? p /get_regptrP hlres1 <-; subst sr'.
    have /wfr_gptr := hgvalid.
    rewrite /get_var_kind /= /get_var /get_local hlres1 => -[? [[<-] /= ->]] /=; rewrite orbT /=.
    eexists; split; first by reflexivity.
    + split; last first.
      + by symmetry;
          apply (Forall2_nth haddr None (Vbool true) (nth_not_default heq ltac:(discriminate))).
      apply (subtype_trans (type_of_get_var hget)).
      rewrite heqty.
      apply (Forall3_nth hsize None res1 (Vbool true) (nth_not_default heq ltac:(discriminate))).
      by rewrite heq.
    eexists; split; first by reflexivity.
    have hget' : get_var true (evm s1) res1 = ok vres1.
    + have /is_sarrP [len hty] := wfr_type (wf_pmap0.(wf_locals) hlres1).
      move: hget; rewrite /get_gvar /= => /get_varP [].
      by rewrite /get_var hty => <- ? /compat_valEl [a] ->.
    assert (hval := wfr_val hgvalid hget').
    case: hval => hread hty.
    move=> off w /[dup] /get_val_byte_bound; rewrite hty => hoff.
    apply hread.
    have :=
    subset_inter_l bytes
      (ByteSet.full
        (interval_of_zone (sub_region_at_ofs sr (Some 0) (size_slot res1)).(sr_zone))).
    move=> /mem_incl_l -/(_ _ hmem) {}hmem.
    rewrite memi_mem_U8; apply: mem_incl_r hmem; rewrite subset_interval_of_zone.
    rewrite -(Z.add_0_l off).
    rewrite -(sub_zone_at_ofs_compose _ _ _ (size_slot res1)).
    apply zbetween_zone_byte => //.
    by apply zbetween_zone_refl.
  t_xrbindP=> /check_varP hlres1 /check_diffP hnnew <-.
  exists vres1; split=> //.
  by have := get_var_kindP hvs hlres1 hnnew hget.
Qed.

Lemma check_resultsP wdb rmap m0 s1 s2 srs params sao_returns res1 res2 vargs1 vargs2 :
  valid_state rmap m0 s1 s2 ->
  Forall3 (fun osr (x : var_i) v => osr <> None -> subtype x.(vtype) (type_of_val v)) srs params vargs1 ->
  List.Forall2 (fun osr varg2 => forall sr, osr = Some sr -> varg2 = Vword (sub_region_addr sr)) srs vargs2 ->
  check_results pmap rmap srs params sao_returns res1 = ok res2 ->
  forall vres1,
  get_var_is wdb (evm s1) res1 = ok vres1 ->
  exists vres2, [/\
    get_var_is wdb (evm s2) res2 = ok vres2,
    Forall3 (wf_result vargs1 vargs2) sao_returns vres1 vres2 &
    Forall3 (value_eq_or_in_mem (emem s2)) sao_returns vres1 vres2].
Proof.
  move=> hvs hsize haddr.
  rewrite /check_results.
  t_xrbindP=> _.
  elim: sao_returns res1 res2.
  + move=> [|//] _ [<-] _ [<-] /=.
    by eexists; (split; first by reflexivity); constructor.
  move=> sao_return sao_returns ih [//|x1 res1] /=.
  t_xrbindP=> _ x2 hcheck res2 /ih{ih}ih <-.
  move=> _ v1 hget1 vres1 hgets1 <-.
  have [v2 [hget2 hresult heqinmem]] := check_resultP hvs hsize haddr hcheck hget1.
  have [vres2 [hgets2 hresults heqinmems]] := ih _ hgets1.
  rewrite /= hget2 /= hgets2 /=.
  by eexists; (split; first by reflexivity); constructor.
Qed.

Lemma check_results_alloc_params_not_None rmap srs params sao_returns res1 res2 :
  check_results pmap rmap srs params sao_returns res1 = ok res2 ->
  List.Forall (fun oi => forall i, oi = Some i -> nth None srs i <> None) sao_returns.
Proof.
  rewrite /check_results.
  t_xrbindP=> _.
  elim: sao_returns res1 res2 => //.
  move=> oi sao_returns ih [//|x1 res1] /=.
  t_xrbindP => _ x2 hresult res2 /ih{ih}ih _.
  constructor=> //.
  move=> i ?; subst oi.
  move: hresult => /=.
  by case: nth.
Qed.

(* If we write (in the target) in a reg that is distinct from everything else,
  then we preserve [valid_state]. This is applied only to [vxlen] for now, so it
  seems a bit overkill to have a dedicated lemma.
*)
Lemma valid_state_distinct_reg rmap m0 s1 s2 x v :
  valid_state rmap m0 s1 s2 ->
  x <> pmap.(vrip) ->
  x <> pmap.(vrsp) ->
  Sv.In x pmap.(vnew) ->
  (forall y p, get_local pmap y = Some (Pregptr p) -> x <> p) ->
  valid_state rmap m0 s1 (with_vm s2 (evm s2).[x <- v]).
Proof.
  move=> hvs hnrip hnrsp hnew hneq.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwfr heqmem hglobv htop.
  constructor=> //=.
  + by rewrite Vm.setP_neq //; apply /eqP.
  + by rewrite Vm.setP_neq //; apply /eqP.
  + by move=> y ??; rewrite Vm.setP_neq; [auto|apply/eqP;congruence].
  case: (hwfr) => hwfsr hval hptr; split=> //.
  move=> y sry /hptr [pky [hly hpk]].
  rewrite hly.
  eexists; split; first by reflexivity.
  case: pky hly hpk => //= p hly hgetp.
  rewrite Vm.setP_neq //; apply/eqP.
  by apply: hneq hly.
Qed.

Lemma fill_fill_mem rmap m0 s1 s2 sr len l a :
  valid_state rmap m0 s1 s2 ->
  wf_sub_region sr (sarr len) ->
  WArray.fill len l = ok a ->
  exists m2, fill_mem (emem s2) (sub_region_addr sr) l = ok m2.
Proof.
  move=> hvs hwf.
  rewrite /WArray.fill /fill_mem.
  t_xrbindP=> /eqP hsize [i {a}a] /= hfold _.

  have hvp: forall k, 0 <= k < len -> validw (emem s2) Aligned (sub_region_addr sr + wrepr _ k)%R U8.
  + move=> k hk.
    apply (validw_sub_region_at_ofs hvs hwf).
    + by rewrite wsize8 /=; lia.
    by apply is_align8.

  elim: l (emem s2) hvp 0 (WArray.empty len) {hsize} hfold => [|w l ih] m2 hvp z a0 /=.
  + by move=> _; eexists.
  t_xrbindP=> _ a' hset <- /ih{ih}ih.
  move: hset => /WArray.set_bound; rewrite WArray.mk_scale_U8 Z.mul_1_r wsize8 => -[h1 h2 _].
  have hvp2: validw m2 Aligned (sub_region_addr sr + wrepr _ z)%R U8.
  + by apply hvp; lia.
  have /writeV -/(_ w) [m2' hm2'] := hvp2.
  rewrite addE hm2' /=.
  apply ih.
  by move=> k hk; rewrite (write_validw_eq hm2'); apply hvp.
Qed.

(* For calls, we call [set_clear] on the arguments, and then [set_sub_region] on
   the results. Since the results point to the same region as the arguments,
   this is rather redundant (actually, they may have different sizes, that's why
   we perform both operations). For syscall [RandomBytes], we are in a somewhat
   restricted case, so I decided to call only [set_sub_region]. But in the
   proofs, it is actually convenient to manipulate the [region_map] where the
   arguments are cleared with [set_clear]. This lemma shows that this is
   equivalent to clear and not to clear. In the future, it will probably be more
   convenient to mimic the proof of the call, so this lemma should not be needed
   anymore.
*)
Lemma set_sub_region_clear rmap x sr ofs len rmap2 :
  set_sub_region rmap x sr (Some ofs) len = ok rmap2 ->
  exists rmap1 rmap2', [/\
    set_clear rmap x sr (Some ofs) len = ok rmap1,
    set_sub_region rmap1 x sr (Some ofs) len = ok rmap2' &
    Incl rmap2 rmap2'].
Proof.
  rewrite /set_sub_region /set_bytes /set_clear.
  case: writable => //= _ [<-].
  eexists _, _; split; [reflexivity..|].
  split=> //=.
  move=> r y.
  rewrite !get_var_bytes_set_pure_bytes get_var_bytes_set_clear_bytes.
  case: eq_op => /=; last by apply subset_refl.
  case: eq_op => /=.
  + apply /ByteSet.subsetP => i.
    rewrite !ByteSet.addE ByteSet.removeE.
    by rewrite orb_andr orbN andbT.
  apply /ByteSet.subsetP => i.
  rewrite !ByteSet.removeE.
  by rewrite -andbA andbb.
Qed.

Lemma disjoint_set_clear rmap sr ofs len x :
  ByteSet.disjoint (get_var_bytes (set_clear_pure rmap sr ofs len) sr.(sr_region) x)
                   (ByteSet.full (interval_of_zone (sub_zone_at_ofs sr.(sr_zone) ofs len))).
Proof.
  rewrite get_var_bytes_set_clear_bytes eq_refl /=.
  apply /ByteSet.disjointP => n.
  by rewrite ByteSet.fullE ByteSet.removeE => /andP [_ /negP ?].
Qed.

(* If we update the [scs] component identically in the source and the target,
   then [valid_state] is preserved. *)
Lemma valid_state_scs rmap m0 s1 s2 scs :
  valid_state rmap m0 s1 s2 ->
  valid_state rmap m0 (with_scs s1 scs) (with_scs s2 scs).
Proof.
  move=> hvs.
  case:(hvs) => hscs hvalid hdisj hincl hincl2 hunch hrip hrsp heqvm hwfr heqmem hglobv htop.
  constructor=> //=.
  case: (hwfr) => hwfsr hval hptr.
  by split.
Qed.

Lemma Incl_set_clear_pure rmap sr ofs len :
  Incl (set_clear_pure rmap sr ofs len) rmap.
Proof.
  split => //=.
  move=> r x.
  rewrite get_var_bytes_set_clear_bytes.
  case: eq_op => /=.
  + by apply subset_remove.
  by apply subset_refl.
Qed.

(* TODO: in the long term, try to merge with what is proved about calls *)
Lemma alloc_syscallP ii rmap rs o es rmap2 c m0 s1 s2 ves scs m vs s1' :
  alloc_syscall saparams pmap ii rmap rs o es = ok (rmap2, c) ->
  valid_state rmap m0 s1 s2 ->
  sem_pexprs true gd s1 es = ok ves ->
  exec_syscall_u (escs s1) (emem s1) o ves = ok (scs, m, vs) ->
  write_lvals true gd (with_scs (with_mem s1 m) scs) rs vs = ok s1' ->
  exists s2', sem P' rip s2 c s2' /\ valid_state rmap2 m0 s1' s2'.
Proof.
  move=> halloc hvs.
  move: halloc; rewrite /alloc_syscall; move=> /add_iinfoP.
  case: o => [len].
  t_xrbindP=> /ZltP hlen.
  case: rs => // -[] // x [] //.
  case: es => // -[] // g [] //.
  t_xrbindP=> pg /get_regptrP hlg px /get_regptrP hlx srg /get_sub_regionP hgetg {rmap2}rmap2 hrmap2 <- <-{c}.
  rewrite /= /exec_getrandom_u /=.
  t_xrbindP=> vg hgvarg <-{ves} [_ _] ag' /to_arrI ?
    a2 hfill [<- <-] <-{scs} <-{m} <-{vs} /=; subst vg.
  t_xrbindP=> {s1'}s1' /write_varP + <- => -[-> hdb h].
  have /wf_locals /= hlocal := hlx.
  have /vm_truncate_valE [hty htreq]:= h.
  set i1 := (X in [:: X; _]).
  set i2 := (X in [:: _; X]).

  (* write [len] in register [vxlen] *)
  have := @sap_immediateP _ hsaparams P' rip s2 (with_var (gv g) (vxlen pmap)) len (@wt_len wf_pmap0).
  set s2' := with_vm s2 _ => hsem1.
  have hvs': valid_state rmap m0 s1 s2'.
    apply (valid_state_distinct_reg _ hvs).
    + by apply len_neq_rip.
    + by apply len_neq_rsp.
    + by apply len_in_new.
    by move=> y p; apply len_neq_ptr.

  have hwfg: wf_sub_region srg g.(gv).(vtype).
  + have hgvalidg := check_gvalid_lvar hgetg.
    by apply (check_gvalid_wf wfr_wf hgvalidg).
  have hofs: forall zofs, Some 0 = Some zofs -> 0 <= zofs /\ zofs + size_of (sarr len) <= size_slot g.(gv).
  + move=> _ [<-].
    have -> /= := type_of_get_gvar_array hgvarg; lia.
  have /= hwfg' := sub_region_at_ofs_wf hwfg hofs.
  have hsub: subtype x.(vtype) g.(gv).(vtype).
  + by have -> /= := type_of_get_gvar_array hgvarg; rewrite hty.

  (* clear the argument *)
  have [rmap1 [rmap2' [hrmap1 hrmap2' hincl2]]] := set_sub_region_clear hrmap2.
  have hincl1: Incl rmap1 rmap.
  + move /set_clearP : hrmap1 => [_ ->].
    by apply Incl_set_clear_pure.
  have hvs1 := valid_state_Incl hincl1 hvs'.

  (* write the randombytes in memory (in the target) *)
  have [m2 hfillm] := fill_fill_mem hvs hwfg' hfill.
  have hvs1': valid_state rmap1 m0 s1 (with_mem s2' m2).
  + rewrite -(with_mem_same s1).
    apply (valid_state_holed_rmap
            (l:=[::(sub_region_at_ofs srg (Some 0) len,sarr len)])
            hvs1 (λ _ _ _, erefl) (fill_mem_stack_stable hfillm)
            (fill_mem_validw_eq hfillm)).
    + move=> p hvalid.
      rewrite (fill_mem_disjoint hfillm); first by apply vs_eq_mem.
      rewrite -(WArray.fill_size hfill) positive_nat_Z.
      apply (disjoint_zrange_incl_l (zbetween_sub_region_addr hwfg')).
      apply vs_disjoint => //.
      by apply hwfg.(wfr_slot).
    + constructor; last by constructor.
      split=> //.
      by move: hrmap2 => /set_sub_regionP [? _].
    + move=> p hvalid1 hvalid2 /List_Forall_inv [hdisj _].
      rewrite (fill_mem_disjoint hfillm) //.
      by rewrite -(WArray.fill_size hfill) positive_nat_Z.
    constructor; last by constructor.
    move=> y.
    have /set_clearP [_ ->] /= := hrmap1.
    by apply disjoint_set_clear.

  (* update the [scs] component *)
  set s1'' := with_scs s1 (get_random (escs s1) len).1.
  set s2'' := with_scs (with_mem s2' m2) (get_random (escs s1) len).1.
  have hvs1'': valid_state rmap1 m0 s1'' s2''.
  + by apply valid_state_scs.

  move: hfillm; rewrite -sub_region_addr_offset wrepr0 GRing.addr0 => hfillm.

  (* write the result *)
  set s1''' := with_vm s1'' (evm s1'').[x <- Varr a2].
  set s2''' := with_vm s2'' (evm s2'').[px <- Vword (sub_region_addr srg)].
  have hvs2: valid_state rmap2' m0 s1''' s2'''.
  + rewrite /s1''' /s2'''.
    apply: (valid_state_set_sub_region_regptr _ hvs1'' hwfg hsub hofs hlx hrmap2' h).
    + by rewrite hlocal.(wfr_rtype).
    rewrite htreq; split=> // off hmem w /[dup] /get_val_byte_bound /= hoff.
    rewrite (WArray.fill_get8 hfill) (fill_mem_read8_no_overflow _ hfillm)
            -?(WArray.fill_size hfill) ?positive_nat_Z /=;
      try lia.
    by case: andb.

  (* wrap up *)
  exists s2'''; split; last by apply (valid_state_Incl hincl2).
  apply (Eseq (s2 := s2')) => //.
  apply sem_seq1; constructor.
  apply: Esyscall.
  + rewrite /= /get_gvar /= /get_var.
    have /wfr_ptr := hgetg; rewrite /get_local hlg => -[_ [[<-] /= ->]] /=.
    by rewrite Vm.setP_eq wt_len vm_truncate_val_eq //; eauto.
  + rewrite /= /exec_syscall_s /= !truncate_word_u /=.
    rewrite /exec_getrandom_s_core wunsigned_repr_small; last by lia.
    by rewrite -vs_scs hfillm.
  by rewrite /= LetK; apply write_var_eq_type; rewrite // hlocal.(wfr_rtype).
Qed.

End WITH_PARAMS.
