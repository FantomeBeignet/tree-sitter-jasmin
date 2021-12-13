From mathcomp Require Import all_ssreflect all_algebra.
Require Import ZArith.
Require Import Utf8.

Require Import expr compiler_util label x86_variables linear linear_sem.
Import ssrZ.

Set Implicit Arguments.
Unset Strict Implicit.
Unset Printing Implicit Defensive.

Local Open Scope seq_scope.

Require Import tunneling_misc unionfind tunneling unionfind_proof.
Require Import linear_sem.


Section TunnelingSemProps.

  Context (fn : funname).

  Context (p : lprog).

  Lemma find_label_tunnel_partial l uf lc : find_label l (tunnel_partial fn uf lc) = find_label l lc.
  Proof.
    rewrite /find_label /tunnel_partial seq.find_map /preim //=.
    have Hpred: [pred x | is_label l (tunnel_bore fn uf x)] =1 [pred x | is_label l x].
    + by move => [li_ii li_i] /=; case: li_i => // [] [fn' l']; case: ifP.
    rewrite (eq_find Hpred); elim: lc => [|hlc tlc] //=.
    case Hhlcl: (is_label l hlc) => //=.
    rewrite !ltnS.
    by do 2! case: ifP.
  Qed.

  Lemma lfd_body_setfb fd fb : lfd_body (setfb fd fb) = fb.
  Proof. by case: fd. Qed.

  Lemma setfb_lfd_body fd : (setfb fd (lfd_body fd)) = fd.
  Proof. by case: fd. Qed.

  Lemma lp_funcs_setfuncs lf : lp_funcs (setfuncs p lf) = lf.
  Proof. by case: p. Qed.

  Lemma lp_funcs_lprog_tunnel :
    lp_funcs (lprog_tunnel fn p) =
    match get_fundef (lp_funcs p) fn with
    | Some fd => (map
                   (fun f =>
                     (f.1,
                      if fn == f.1
                      then lfundef_tunnel_partial fn f.2 fd.(lfd_body) fd.(lfd_body)
                      else f.2))
                   (lp_funcs p))
    | None => lp_funcs p
    end.
  Proof.
    by rewrite /lprog_tunnel; case Hgfd: get_fundef => [fd|] //.
  Qed.

  Lemma get_fundef_map2 (g : funname -> lfundef -> lfundef) (fs : seq (funname * lfundef)) :
    get_fundef (map (fun f => (f.1, g f.1 f.2)) fs) fn =
    match (get_fundef fs fn) with
    | Some fd => Some (g fn fd)
    | None => None
    end.
  Proof.
    by elim: fs => [|[fn'' fd''] fs Ihfs] //=; case: ifP => // /eqP ->.
  Qed.

  Lemma get_fundef_eval_instr p' i s1 s2 :
    label_in_lprog p = label_in_lprog p' ->
    get_fundef (lp_funcs p) =1 get_fundef (lp_funcs p') ->
    eval_instr p i s1 = ok s2 -> eval_instr p' i s1 = ok s2.
  Proof.
    move => Hlabelinlprog Hgetfundef.
    rewrite /eval_instr /eval_jump; case: (li_i _) => [lv s e| |l|[fn' l]|e|lv l|e l] //.
    + by rewrite Hgetfundef.
    + by t_xrbindP => w v -> /= -> /=; rewrite Hlabelinlprog; case: (decode_label) => [[l fn']|] //; rewrite Hgetfundef.
    + by rewrite Hlabelinlprog.
    by t_xrbindP => b v -> /= -> /=; rewrite Hgetfundef.
  Qed.

  Lemma get_fundef_lsem1 p' s1 s2 :
    label_in_lprog p = label_in_lprog p' ->
    get_fundef (lp_funcs p) =1 get_fundef (lp_funcs p') ->
    lsem1 p s1 s2 -> lsem1 p' s1 s2.
  Proof.
    move => Hlabelinlprog Hgetfundef; rewrite /lsem1 /step /find_instr Hgetfundef.
    case: (get_fundef _ _) => [fd|] //; case: (oseq.onth _ _) => [i|] //.
    by apply: get_fundef_eval_instr.
  Qed.

End TunnelingSemProps.


Section TunnelingProof.

  Context (fn : funname).

  Context (p : lprog).

  Context (wf_p : well_formed_lprog p).

  Lemma tunnel_bore_empty c : tunnel_bore fn LUF.empty c = c.
  Proof.
    case: c => li_ii li_i; case: li_i => //=.
    by case; intros; case: ifP => //; rewrite LUF.find_empty.
  Qed.

  Lemma pairmap_tunnel_bore_empty fd : map (tunnel_bore fn LUF.empty) (lfd_body fd) = (lfd_body fd).
  Proof.
    by rewrite (eq_map tunnel_bore_empty) map_id.
  Qed.

  Lemma if_eq_fun (T1 : eqType) (T2 : Type) (f : T1 -> T2) a b : (if a == b then f a else f b) = f b.
  Proof. by case: ifP => // /eqP ->. Qed.

  Lemma get_fundef_map2_only_fn fn' g :
    get_fundef (map (fun f => (f.1, if fn == f.1 then g f.2 else f.2)) (lp_funcs p)) fn' =
    match get_fundef (lp_funcs p) fn' with
    | Some fd => Some (if fn == fn' then g fd else fd)
    | None => None
    end.
  Proof.
    by rewrite (get_fundef_map2 fn' (fun f1 f2 => if fn == f1 then g f2 else f2) (lp_funcs p)).
  Qed.

  Lemma get_fundef_partial fn' uf fd:
    get_fundef (map (fun f =>
                      (f.1,
                       if fn == f.1
                       then setfb f.2 (tunnel_partial fn uf (lfd_body fd))
                       else f.2))
                    (lp_funcs p)) fn' =
    match
      get_fundef (lp_funcs p) fn'
    with
    | Some fd' => Some (if fn == fn' then setfb fd' (tunnel_partial fn uf (lfd_body fd)) else fd')
    | None => None
    end.
  Proof.
    by rewrite (get_fundef_map2_only_fn fn' (fun f2 => setfb f2 (tunnel_partial fn uf (lfd_body fd)))).
  Qed.

  Lemma get_fundef_lprog_tunnel fn':
    get_fundef (lp_funcs (lprog_tunnel fn p)) fn' =
    match get_fundef (lp_funcs p) fn' with
    | Some fd => Some (if fn == fn' then lfundef_tunnel_partial fn fd fd.(lfd_body) fd.(lfd_body) else fd)
    | None => None
    end.
  Proof.
    rewrite /lprog_tunnel.
    by case Hgfd: (get_fundef _ fn) => [fd|]; first rewrite get_fundef_partial;
    case Hgfd': (get_fundef _ fn') => [fd'|] //; case Heqfn: (fn == fn') => //;
    move: Heqfn => /eqP ?; subst fn'; move: Hgfd Hgfd' => -> // [?]; subst fd'.
  Qed.

  Lemma get_fundef_union fn' uf l1 l2 fd :
    get_fundef (map (fun f =>
                      (f.1,
                       if fn == f.1
                       then setfb f.2 (tunnel_partial fn (LUF.union uf l1 l2) (lfd_body fd))
                       else f.2))
                    (lp_funcs p)) fn' =
    match
      get_fundef (lp_funcs p) fn'
    with
    | Some fd' =>
        Some (if fn == fn'
              then setfb fd' (tunnel_partial fn (LUF.union LUF.empty (LUF.find uf l1) (LUF.find uf l2)) (tunnel_partial fn uf (lfd_body fd))) 
              else fd')
    | None => None
    end.
  Proof.
    rewrite get_fundef_partial.
    case Hgfd': (get_fundef _ fn') => [fd'|] //; case Heqfn: (fn == fn') => //.
    move: Heqfn => /eqP ?; subst fn'; do 2! f_equal.
    rewrite /tunnel_partial -map_comp -eq_in_map => -[ii li] _.
    rewrite /tunnel_bore; case: li => //=.
    + move => [fn' l']; case Heqfn: (fn == fn') => //; last by rewrite Heqfn.
      move: Heqfn => /eqP ?; subst fn'; rewrite eq_refl; do 3! f_equal.
      by rewrite !LUF.find_union !LUF.find_empty.
    by intros; rewrite !LUF.find_union !LUF.find_empty.
  Qed.

  Lemma get_fundef_wf fd:
    get_fundef (lp_funcs p) fn = Some fd ->
    well_formed_body fn (lfd_body fd).
  Proof.
    move: wf_p => /andP [_]; rewrite /well_formed_lprog.
    elim: (lp_funcs p) => [|[hfn hfd] tfs IHfs] //=.
    move => /andP [Hwfhfd Hwfa].
    case: ifP; last by move => _; apply: (IHfs Hwfa).
    by move => /eqP ? [?]; subst hfn hfd.
  Qed.

  Lemma uniq_nhas fb s ii l :
    uniq (labels_of_body fb) ->
    prefix (rcons s (MkLI ii (Llabel l))) fb ->
    ~~ has (is_label l) s.
  Proof.
    move => Hwfb Hprefix; move: Hprefix Hwfb => /prefixP [sfb] ->.
    rewrite /well_formed_body /labels_of_body map_cat map_rcons filter_cat filter_rcons /=.
    rewrite cat_uniq => /andP [Huniq] /andP _; apply/negP => Hhass.
    move: Hhass => /hasP [[ii' i]]; rewrite /is_label.
    case: i => //= l' Hin /eqP ?; subst l'; move: Huniq; rewrite rcons_uniq.
    move => /andP [/negP Hnotin _]; apply: Hnotin; rewrite mem_filter.
    by apply/andP; split => //; apply/mapP; eexists; first apply: Hin.
  Qed.

  Definition li_is_label (c : linstr) :=
    if c.(li_i) is Llabel _ then true else false.

  Definition li_is_goto (c : linstr) :=
    if c.(li_i) is Lgoto _ then true else false.

  Variant tunnel_chart_spec (uf : LUF.unionfind) : linstr -> linstr -> LUF.unionfind -> Type :=
  | TC_LabelLabel ii ii' l l' :
      tunnel_chart_spec uf (MkLI ii (Llabel l)) (MkLI ii' (Llabel l')) (LUF.union uf l l')

  | TC_LabelGotoEq ii ii' l l' :
      tunnel_chart_spec uf (MkLI ii (Llabel l)) (MkLI ii' (Lgoto (fn, l'))) (LUF.union uf l l')

  | TC_LabelGotoNEq ii ii' l l' fn' of (fn != fn') :
      tunnel_chart_spec uf (MkLI ii (Llabel l)) (MkLI ii' (Lgoto (fn', l'))) uf

  | TC_NLabelGoto c c' of (~~ (li_is_label c && li_is_goto c')) :
      tunnel_chart_spec uf c c' uf.

  Variant tunnel_chart_weak_spec
    (uf : LUF.unionfind) : linstr -> linstr -> LUF.unionfind -> Type :=
  | TCW_LabelLabel ii ii' l l' :
      tunnel_chart_weak_spec
        uf (MkLI ii (Llabel l)) (MkLI ii' (Llabel l')) (LUF.union uf l l')

  | TCW_LabelGotoEq ii ii' l l' :
      tunnel_chart_weak_spec
        uf (MkLI ii (Llabel l)) (MkLI ii' (Lgoto (fn, l'))) (LUF.union uf l l')

  | TCW_Otherwise c c' :
      tunnel_chart_weak_spec uf c c' uf.

  Lemma tunnel_chartP uf c c' : tunnel_chart_spec uf c c' (tunnel_chart fn uf c c').
  Proof.
  case: c c' => [ii i] [ii' i']; case: i'; case: i; try by move=> *; apply: TC_NLabelGoto.
  + by move => l l'; apply TC_LabelLabel.
  move=> l [fn' l'] /=; case: ifPn => [/eqP<-|].
  + by apply: TC_LabelGotoEq.
  by apply: TC_LabelGotoNEq.
  Qed.

  Lemma tunnel_chartWP uf c c' : tunnel_chart_weak_spec uf c c' (tunnel_chart fn uf c c').
  Proof.
  case: c c' => [ii i] [ii' i'];
    case: i'; case: i; try by move=> *; apply: TCW_Otherwise.
  + by move => l l'; apply TCW_LabelLabel.
  move=> l [fn' l'] /=; case: ifPn => [/eqP<-|].
  + by apply: TCW_LabelGotoEq.
  by move=> _; apply: TCW_Otherwise.
  Qed.

  Lemma find_plan_partial_nhas fb s c l :
    well_formed_body fn fb ->
    prefix (rcons s c) fb ->
    ~~ has (is_label l) s ->
    LUF.find (pairfoldl (tunnel_chart fn) LUF.empty Linstr_align (rcons s c)) l = l.
  Proof.
    rewrite /well_formed_body => /andP [Huniqfb _] Hprefix.
    move => /negP; move: s l c Hprefix; apply: last_ind => [|s c1 IHs] //.
    move => l c2 Hprefix; rewrite pairfoldl_rcons has_rcons last_rcons.
    move: {1 5}c1 (erefl c1) Hprefix => c1'.
    case: tunnel_chartWP; last first.
    + move=> c c' -> Hprefix Hor; apply: IHs.
      - by apply: prefix_trans (prefix_rcons _ _) Hprefix.
      by case/negP/norP: Hor => _ /negP.
    + move=> ii ii' l1 l2 -> Hprefix.
      move=> Hor; rewrite LUF.find_union; case: ifP; last first.
      - by rewrite (IHs l _ (prefix_trans (prefix_rcons _ _) Hprefix)) //;
        move => Hhas; apply: Hor; apply/orP; right.
      rewrite (IHs l _ (prefix_trans (prefix_rcons _ _) Hprefix)) //; last first.
      - by move => Hhas; apply: Hor; apply/orP; right.
      rewrite (IHs l1 _ (prefix_trans (prefix_rcons _ _) Hprefix)) //; last first.
      - by apply: (negP (uniq_nhas Huniqfb (prefix_trans (prefix_rcons _ _) Hprefix))).
      by move => /eqP ?; subst l1; exfalso; apply: Hor; apply/orP; left; rewrite /is_label /= eq_refl.
    move=> ii ii' l1 l2 -> Hprefix.
    move=> Hor; rewrite LUF.find_union; case: ifP; last first.
    + by rewrite (IHs l _ (prefix_trans (prefix_rcons _ _) Hprefix)) //;
      move => Hhas; apply: Hor; apply/orP; right.
    rewrite (IHs l _ (prefix_trans (prefix_rcons _ _) Hprefix)) //; last first.
    + by move => Hhas; apply: Hor; apply/orP; right.
    rewrite (IHs l1 _ (prefix_trans (prefix_rcons _ _) Hprefix)) //; last first.
    + by apply: (negP (uniq_nhas Huniqfb (prefix_trans (prefix_rcons _ _) Hprefix))).
    by move => /eqP ?; subst l1; exfalso; apply: Hor; apply/orP; left; rewrite /is_label /= eq_refl.
  Qed.

  Lemma find_plan_partial fb s ii l :
    well_formed_body fn fb ->
    prefix (rcons s (MkLI ii (Llabel l))) fb ->
    LUF.find (pairfoldl (tunnel_chart fn) LUF.empty Linstr_align (rcons s (MkLI ii (Llabel l)))) l = l.
  Proof.
    move => Hwfb; move: (Hwfb).
    rewrite /well_formed_body => /andP [Huniqfb _] Hprefix.
    have Hnhas:= (uniq_nhas Huniqfb Hprefix).
    by apply (find_plan_partial_nhas Hwfb Hprefix Hnhas).
  Qed.

  Lemma find_label_inj fb l l' pc :
    well_formed_body fn fb ->
    find_label l fb = ok pc ->
    find_label l' fb = ok pc ->
    l = l'.
  Proof.
    rewrite /well_formed_body => /andP [Huniq _].
    rewrite /find_label; case: ifP => // Hfindl; case: ifP => // Hfindl'.
    move => [?] []; subst pc; move: Huniq Hfindl Hfindl'.
    elim: fb => //= c fb; rewrite /labels_of_body /=.
    case: c => li_ii li_i; case: li_i => //= [_ _ _| |l''|_|_|_ _|_ _].
    1-2,4-7:
      by move => IHfb ? ? ? /(eq_add_S _) ?; apply IHfb.
    rewrite /is_label //= => IHfb /andP [Hnotin Huniq].
    case: ifP => Heql''; case: ifP => Heql''' //=.
    + by move: Heql'' Heql''' => /eqP ? /eqP ?; subst l l'.
    by move => ? ? /(eq_add_S _) ?; apply IHfb.
  Qed.

  Lemma prefix_rcons_find_label pfb ii l fb :
    well_formed_body fn fb ->
    prefix (rcons pfb {| li_ii := ii; li_i := Llabel l |}) fb ->
    find_label l fb = ok (size pfb).
  Proof.
    rewrite /well_formed_body => /andP [Huniqfb _].
    elim: fb pfb Huniqfb => [|hfb tfb IHfb] [|hpfb tpfb] //=; case: ifP => // /eqP ?; subst hfb.
    + by move => _ _; rewrite /find_label /find /is_label /= eq_refl.
    move => Huniqfb Hprefix; have:= (IHfb tpfb); rewrite /find_label /find.
    have:= (@uniq_nhas _ (hpfb :: tpfb) ii l Huniqfb).
    rewrite rcons_cons /= eq_refl; move => Hneg; have:= (Hneg Hprefix) => /negP Hor.
    case Hisl: (is_label _ _); first by exfalso; apply: Hor; apply/orP; left.
    have Huniqtfb: (uniq (labels_of_body tfb)).
    + move: Huniqfb; rewrite /well_formed_body /labels_of_body /=.
      by case: ifP => //; rewrite cons_uniq => _ /andP [].
    move => IHdepl; have:= (IHdepl Huniqtfb Hprefix).
    case: ifP; case: ifP => //; first by move => _ _ [->].
    by rewrite ltnS => ->.
  Qed.

  Lemma prefix_find_label_goto pfb fb li_ii fn' l :
    well_formed_body fn fb ->
    prefix (rcons pfb (MkLI li_ii (Lgoto (fn', l)))) fb ->
    exists pc, find_label l fb = ok pc.
  Proof.
    rewrite /well_formed_body => /andP [_ Hall] Hprefix.
    exists (find (is_label l) fb); move: Hprefix => /prefixP [sfb] ?; subst fb; move: Hall.
    rewrite /goto_targets map_cat map_rcons filter_cat filter_rcons /=.
    rewrite all_cat all_rcons => /andP [/andP [/andP [/eqP ?]]]; subst fn'.
    rewrite /find_label => Hin _ _; rewrite -has_find; case: ifP => // Hnhas.
    exfalso; move: Hnhas; apply/Bool.eq_true_false_abs/hasP.
    move: Hin; rewrite mem_filter => /andP [_]; set fb := cat _ _.
    elim: fb => //= c fb IHfb; rewrite in_cons => /orP [/eqP Heq|Hin].
    + exists c; first by apply/mem_head.
      by rewrite /is_label -Heq /= eq_refl.
    case: (IHfb Hin) => c' Hin' His_label; exists c' => //.
    by rewrite in_cons; apply/orP; right.
  Qed.

  Lemma prefix_find_label pfb fb l pc:
    well_formed_body fn fb ->
    prefix pfb fb ->
    find_label l fb = ok pc ->
    exists pcf, find_label (LUF.find (tunnel_plan fn LUF.empty pfb) l) fb = ok pcf.
  Proof.
    move: pfb l pc; apply: last_ind => [|pfb c]; first by move => l pc; exists pc; rewrite /tunnel_plan /= LUF.find_empty.
    move => IHpfb l pc Hwfb Hprefix Hfindl; have:= (IHpfb _ _ Hwfb (prefix_trans (prefix_rcons _ _) Hprefix) Hfindl).
    move => -[pcf]; rewrite /tunnel_plan pairfoldl_rcons.
    set uf:= pairfoldl _ _ _ _; rewrite /tunnel_chart.
    case Hlastpfb: (last _ _) => [li_ii1 li_i1] //; case Hc: c => [li_ii2 li_i2] //.
    case: li_i1 Hlastpfb.
    1-2,4-7:
      by intros; eexists; eauto.
    case: li_i2 Hc.
    1-2,5-7:
      by intros; eexists; eauto.
    + move => l'' ?; subst c => l' Hlastpfb Hfindpl; rewrite LUF.find_union.
      case: ifP; last by intros; eexists; eauto.
      move => /eqP Hfindll'; move: Hfindpl; rewrite -Hfindll' => Hpcf.
      rewrite /tunnel_plan -/uf in IHpfb.
      have: exists pc'', find_label l'' fb = ok pc''; last first.
      - move => [pc''] Hfindl''.
        by apply: (IHpfb _ _ Hwfb (prefix_trans (prefix_rcons _ _) Hprefix) Hfindl'').
      
      move: (@mem_prefix _ _ _ Hprefix {| li_ii := li_ii2; li_i := Llabel l'' |}).
      rewrite -cats1 mem_cat mem_seq1 eq_refl orbT => /(_ isT) Hl''.
      elim: fb Hl'' {Hwfb Hprefix Hfindl Hpcf IHpfb} => // hfb tfb IHfb.
      rewrite in_cons; case Hhfbl'': (is_label l'' hfb) => //=.
      - by move => _; exists 0; rewrite /find_label /= Hhfbl''.
      rewrite /find_label /= Hhfbl'' ltnS.
      move => /orP [/eqP ?|]; first by subst hfb; rewrite /is_label /= eq_refl in Hhfbl''.
      move => Htfb; case: (IHfb Htfb) => pc''; rewrite /find_label => Hflbl.
      by exists pc''.+1; move: Hflbl; case: ifP => //; move => _ [<-].
    move => [fn'' l''] ?; subst c => l' Hlastpfb Hfindpl.
    case: eqP; last by intros; eexists; eauto.
    move => ?; subst fn''; rewrite LUF.find_union.
    case: ifP; last by intros; eexists; eauto.
    move => /eqP Hfindll'; move: Hfindpl; rewrite -Hfindll' => Hpcf.
    rewrite /tunnel_plan -/uf in IHpfb.
    have: exists pc'', find_label l'' fb = ok pc''; last first.
    + move => [pc''] Hfindl''.
      by apply: (IHpfb _ _ Hwfb (prefix_trans (prefix_rcons _ _) Hprefix) Hfindl'').
    move: Hwfb; rewrite /well_formed_body.
    rewrite /well_formed_body => /andP [_].
    rewrite all_filter; move: Hprefix; case/prefixP => sfb Hfb.
    rewrite {2}Hfb map_cat map_rcons all_cat all_rcons => /andP [] /andP [/= Hl'' _ _].
    rewrite eq_refl /= in Hl''.
    elim: fb Hl'' {Hfindl Hpcf IHpfb Hfb} => // hfb tfb.
    rewrite /labels_of_body /find_label !mem_filter /= in_cons.
    case Hhfbl'': (is_label l'' hfb) => //=.
    + by rewrite /is_label /= in Hhfbl'' => IHok Hor; exists 0.
    rewrite ltnS; move => IHok; rewrite /is_label in Hhfbl'' => Hor; move: Hor Hhfbl''.
    move => /orP [/eqP <-|]; first by rewrite eq_refl.
    move => Hin; case: (IHok Hin) => [pc''] Hif _; exists pc''.+1; move: Hif; case: ifP => //.
    by move => _ [->].
  Qed.

  Lemma find_is_label_eq l1 l2 lc :
    has (is_label l1) lc ->
    find (is_label l1) lc = find (is_label l2) lc ->
    l1 = l2.
  Proof.
    elim: lc => [|hlc tlc IHlc] //=.
    case: ifP; case: ifP => //=.
    + by rewrite /is_label; case: (li_i hlc) => // l /eqP <- /eqP.
    by move => _ _ Hhas [Heqfind]; apply: IHlc.
  Qed.

  Lemma mem_split {T : eqType} (s : seq T) (x : T) :
    x \in s -> exists s1 s2, s = s1 ++ x :: s2.
  Proof.
  move/rot_index; set i := seq.index x s; move/(congr1 (rotr i)).
  rewrite rotK {1}(_ : i = size (take i s)); last first.
  - by rewrite size_takel // index_size.
  by rewrite -cat_cons rotr_size_cat => ->; eauto.
  Qed.

  Lemma labels_of_body_nil : labels_of_body [::] = [::].
  Proof. by []. Qed.

  Lemma labels_of_body_cons c fb : labels_of_body (c :: fb) =
    if li_is_label c then c.(li_i) :: labels_of_body fb else labels_of_body fb.
  Proof. by []. Qed.

  Lemma labels_of_body_cat fb1 fb2 :
    labels_of_body (fb1 ++ fb2) = labels_of_body fb1 ++ labels_of_body fb2.
  Proof. by rewrite /labels_of_body map_cat filter_cat. Qed.

  Lemma is_labelP {l c} : reflect (c.(li_i) = Llabel l) (is_label l c).
  Proof.
  rewrite /is_label; case: c => ii [] /=; try by move=> *; constructor.
  by move=> l'; apply: (iffP eqP) => [->//|[->]].
  Qed.

  Lemma find_is_label_r fb (c : linstr) l :
        well_formed_body fn fb
     -> c \in fb
     -> is_label l c
     -> find (is_label l) fb = seq.index c fb.
  Proof.
  case/andP=> [uq _] /mem_split [fb1] [fb2] fbE lc.
  suff l_fb1: ~~ has (is_label l) fb1.
    have c_fb1: c \notin fb1.
      by apply/contra: l_fb1 => c_fb1; apply/hasP; exists c.
    rewrite fbE; rewrite find_cat (negbTE l_fb1) /= lc addn0.
    by rewrite index_cat (negbTE c_fb1) /= eqxx addn0.
  apply/hasPn=> /= c' c'_fb1; apply/contraL: uq => lc'.
  rewrite fbE labels_of_body_cat uniq_catC labels_of_body_cons.
  rewrite /li_is_label (is_labelP lc) /=; apply/nandP; left.
  rewrite negbK mem_cat; apply/orP; right.
  by rewrite mem_filter /= -(is_labelP lc'); apply/mapP; exists c'.
  Qed.

  Lemma find_is_label pfb fb c l :
    well_formed_body fn fb ->
    prefix (rcons pfb c) fb ->
    is_label l c ->
    find (is_label l) fb = size pfb.
  Proof.
  move=> wf /prefixP [fb' fbE] lc; rewrite (@find_is_label_r _ c) //.
  - rewrite fbE index_cat mem_rcons in_cons eqxx /=.
    rewrite -cats1 index_cat; case: ifP => //=; last first.
    - by move=> _; rewrite eqxx addn0.
    case/andP: wf => uq _; move: uq.
    rewrite fbE -cats1 !labels_of_body_cat -catA uniq_catC -catA.
    rewrite {1}/labels_of_body /= (is_labelP lc) /= andbC => /andP[_].
    rewrite mem_cat => /norP[_]; rewrite mem_filter /= => h.
    by move/(map_f li_i); rewrite (is_labelP lc) (negbTE h).
  - by rewrite fbE mem_cat mem_rcons in_cons eqxx.
  Qed.

  Lemma label_in_lprog_tunnel :
    forall fb,
      label_in_lprog
        ( match get_fundef (lp_funcs p) fn with
          | Some fd =>
              setfuncs p
                [seq (f.1,
                  if fn == f.1
                  then lfundef_tunnel_partial fn f.2 fb (lfd_body fd)
                  else f.2)
                | f <- lp_funcs p]
          | None => p
          end)
      = label_in_lprog p.
  Proof.
    move: wf_p => /andP; case: p => rip rsp globs funcs /= [Huniq _].
    rewrite /label_in_lprog /=; f_equal.
    case Hgfd: get_fundef => [fd|] // fb.
    rewrite lp_funcs_setfuncs -map_comp /=.
    have: get_fundef funcs fn = Some fd \/ get_fundef funcs fn = None by left.
    elim: funcs {rip globs Hgfd} Huniq => // -[fn' fd'] tfuncs IHfuncs /=.
    move => /andP [Hnotin Huniq]; case: ifP; last by move => _ Hgfd; f_equal; apply: IHfuncs.
    move => /eqP ?; subst fn'; case => [[?]|] //; subst fd'; f_equal; last first.
    + apply: IHfuncs => //; right; elim: tfuncs Hnotin {Huniq} => // -[fn' fd'] ttfuncs IHtfuncs /=.
      by rewrite in_cons Bool.negb_orb => /andP []; case: ifP.
    case: fd {tfuncs IHfuncs Hnotin Huniq} => /= _ _ _ _ lc _ _ _.
    set uf:= tunnel_plan _ _ _; move: uf.
    elim: lc => // -[ii []] //=; last by move => [fn'] /=; case: (fn == fn') => /=.
    by move => l lc IHlc uf; rewrite IHlc.
  Qed.

  Lemma tunneling_lsem1 s1 s2 : lsem1 (lprog_tunnel fn p) s1 s2 -> lsem p s1 s2.
  Proof.
    rewrite /lprog_tunnel; case Hgfd: (get_fundef _ _) => [fd|];
      last by apply: Relation_Operators.rt_step.
    move: s1 s2; pattern (lfd_body fd), (lfd_body fd) at 2; apply: prefixW.
    + move => s1 s2 Hlsem1; apply: Relation_Operators.rt_step.
      have:= (@get_fundef_lsem1 _ _ _ _ (label_in_lprog_tunnel _)).
      rewrite Hgfd => Hgfd'; apply: (Hgfd' _ _ _ _ Hlsem1); clear Hgfd' Hlsem1 => fn'.
      rewrite lp_funcs_setfuncs /lfundef_tunnel_partial /tunnel_plan /= /tunnel_partial pairmap_tunnel_bore_empty.
      rewrite (get_fundef_map2 fn' (fun f1 f2 => if fn == f1 then setfb f2 (lfd_body fd) else f2) (lp_funcs p)).
      case Hgfd': (get_fundef _ _) => [fd'|] //; case: ifP => // /eqP ?; subst fn'.
      by move: Hgfd'; rewrite Hgfd => -[?]; subst fd'; rewrite setfb_lfd_body.
    move => [li_ii3 li_i3] tli.
    have:= label_in_lprog_tunnel (rcons tli {| li_ii := li_ii3; li_i := li_i3 |}).
    have:= label_in_lprog_tunnel tli.
    rewrite Hgfd /lfundef_tunnel_partial /tunnel_plan pairfoldl_rcons.
    case: (lastP tli); first by case: (lfd_body fd) => //.
    move => ttli [li_ii2 li_i2]; rewrite last_rcons /=.
    case: li_i2; case: li_i3 => //.
    + move => l3 l2.
      set uf := pairfoldl _ _ _ _ => Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
      move => Hprefix Hplsem1 s1 s2; move: Hplsem1.
      rewrite /lsem1 /step /find_instr !lp_funcs_setfuncs get_fundef_union.
      case Hgfds1: (get_fundef _ _) => [fds1|] //.
      case Heqfns1: (fn == lfn s1); last first.
      - move => Hplsem1; have:= (Hplsem1 s1 s2); clear Hplsem1.
        rewrite get_fundef_partial Hgfds1 Heqfns1.
        case Honth: (oseq.onth _ _) => [[li_ii1 li_i1]|] //.
        rewrite /eval_instr /eval_jump; case: (li_i1) => //.
        * move => [fn1 l1] /=; rewrite get_fundef_partial get_fundef_union.
          case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=.
          by rewrite !find_label_tunnel_partial.
        * move => pe1 /= Htunnel; t_xrbindP => w v Hv Hw.
          rewrite Hv /= Hw /= in Htunnel; move: Htunnel.
          rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
          case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_partial get_fundef_union.
          case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=.
          by rewrite !find_label_tunnel_partial.
        * by move => lv l /=; rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
        move => pe1 l1 /= Htunnel; t_xrbindP => b v Hv Hb.
        rewrite Hv /= Hb /= in Htunnel; move: Htunnel.
        case: b {Hb} => //; rewrite get_fundef_partial get_fundef_union Heqfns1.
        by case: (get_fundef _ _) => [fd1|].
      move: s1 Heqfns1 Hgfds1 => [mem1 vm1 fn1 pc1] /= /eqP ? Hgfds1; subst fn1.
      pose s1:= Lstate mem1 vm1 fn pc1; rewrite -/s1.
      move: Hgfds1; rewrite Hgfd => -[?]; subst fds1.
      rewrite !onth_map; case Honth: (oseq.onth _ _) => [[li_ii1 li_i1]|] // Hplsem1.
      rewrite /eval_instr /eval_jump; case: li_i1 Honth => [? ? ?| |?|[fn1 l1]|pe1|lv l|pe1 l1] //=.
      1-3:
        move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
        by rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth //=.
      2:
        by move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=;
        move => Htunnel; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /= in Htunnel; move: Htunnel;
        rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union;
        case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_partial get_fundef_union;
        case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=;
        rewrite !find_label_tunnel_partial.
      2:
        by rewrite Hlabel_in_lprog_tunnel_union; move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr Hlabel_in_lprog_tunnel.
      - move => Honth.
        case Heqfn1: (fn == fn1) => //; last first.
        * have:= (Hplsem1 s1 s2); clear Hplsem1;
          rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
          rewrite Heqfn1 get_fundef_union // Heqfn1 get_fundef_partial.
          by case Hgfd1: (get_fundef _ _) => [fd1|] //; rewrite Heqfn1.
        move: Heqfn1 => /eqP ?; subst fn1.
        rewrite eq_refl /= LUF.find_union !LUF.find_empty.
        rewrite get_fundef_partial Hgfd eq_refl /=; t_xrbindP => pc3.
        case: ifP; last first.
        * have:= (Hplsem1 s1 s2); clear Hplsem1;
          rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
          rewrite eq_refl get_fundef_partial Hgfd /= eq_refl !find_label_tunnel_partial /=.
          by move => Htunnel _ Hpc13 Hs2; rewrite Hpc13 /= Hs2 /= in Htunnel; apply: Htunnel.
        rewrite find_label_tunnel_partial.
        move => Heqfind Hfindl Hsetcpc.
        pose s1':= Lstate mem1 vm1 fn (size ttli).+1.
        have:= (Hplsem1 s1' s2); have:= (Hplsem1 s1 s1'); rewrite /s1' /= -/s1'; clear Hplsem1.
        rewrite get_fundef_partial Hgfd eq_refl !onth_map Honth /= eq_refl /eval_instr /eval_jump /=.
        rewrite get_fundef_partial Hgfd eq_refl /setcpc.
        rewrite lfd_body_setfb -(eqP Heqfind) /= find_label_tunnel_partial.
        rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        rewrite (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        rewrite /= -/s1' -(prefix_onth Hprefix); last by rewrite !size_rcons.
        rewrite !onth_rcons !size_rcons eq_refl /=; subst s2; rewrite /setpc /setcpc /=.
        move => Hlsem11' Hlsem12'; apply: (@lsem_trans _ s1'); first by apply: Hlsem11'.
        apply Hlsem12'; f_equal; f_equal.
        move: (prefix_rcons_find_label (get_fundef_wf Hgfd) Hprefix).
        rewrite size_rcons; move: Hfindl; rewrite /uf.
        move: (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP [Huniqfb _].
        have:= (uniq_nhas Huniqfb Hprefix); rewrite has_rcons negb_or => /andP [_ Hnhas].
        have Hprefix':= (@prefix_rcons _ (rcons ttli {| li_ii := li_ii2; li_i := Llabel l2 |}) {| li_ii := li_ii3; li_i := Llabel l3 |}).
        rewrite (find_plan_partial_nhas (get_fundef_wf Hgfd) (prefix_trans Hprefix' Hprefix) Hnhas).
        by move => -> [->].
      move => Honth.
      t_xrbindP => b v Hv; case: b => Hb; last first.
      + have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
        by rewrite Hv /= Hb /=.
      rewrite get_fundef_partial Hgfd eq_refl /=; t_xrbindP => pc3.
      rewrite LUF.find_union !LUF.find_empty.
      case: ifP; last first.
      + have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
        rewrite Hv /= Hb /= find_label_tunnel_partial => Hpc _ Hpc3 Hs2; move: Hpc.
        rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
        by rewrite Hpc3 /= Hs2 /=; move => Hlsem; apply: Hlsem.
      rewrite find_label_tunnel_partial.
      move => Heqfind Hfindl Hsetcpc.
      pose s1':= Lstate mem1 vm1 fn (size ttli).+1.
      have:= (Hplsem1 s1' s2); have:= (Hplsem1 s1 s1'); rewrite /s1' /= -/s1'; clear Hplsem1.
      rewrite get_fundef_partial Hgfd eq_refl onth_map Honth /eval_instr /eval_jump /= Hv /= Hb /=.
      rewrite get_fundef_partial Hgfd eq_refl onth_map.
      rewrite -(eqP Heqfind) /= find_label_tunnel_partial.
      rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      rewrite (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      rewrite /= -/s1' -(prefix_onth Hprefix); last by rewrite !size_rcons.
      rewrite !onth_rcons !size_rcons eq_refl /=; subst s2; rewrite /setpc /setcpc /=.
      move => Hlsem11' Hlsem12'; apply: (@lsem_trans _ s1'); first by apply: Hlsem11'.
      apply Hlsem12'; f_equal; f_equal.
      move: (prefix_rcons_find_label (get_fundef_wf Hgfd) Hprefix).
      rewrite size_rcons; move: Hfindl; rewrite /uf.
      move: (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP [Huniqfb _].
      have:= (uniq_nhas Huniqfb Hprefix); rewrite has_rcons negb_or => /andP [_ Hnhas].
      have Hprefix':= (@prefix_rcons _ (rcons ttli {| li_ii := li_ii2; li_i := Llabel l2 |}) {| li_ii := li_ii3; li_i := Llabel l3 |}).
      rewrite (find_plan_partial_nhas (get_fundef_wf Hgfd) (prefix_trans Hprefix' Hprefix) Hnhas).
      by move => -> [->].
    move => [fn3 l3] l2; case Heqfn3: (fn == fn3) => //; move: Heqfn3 => /eqP ?; subst fn3.
    set uf := pairfoldl _ _ _ _ => Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
    move => Hprefix Hplsem1 s1 s2; move: Hplsem1.
    rewrite /lsem1 /step /find_instr !lp_funcs_setfuncs get_fundef_union.
    case Hgfds1: (get_fundef _ _) => [fds1|] //.
    case Heqfns1: (fn == lfn s1); last first.
    + move => Hplsem1; have:= (Hplsem1 s1 s2); clear Hplsem1.
      rewrite get_fundef_partial Hgfds1 Heqfns1.
      case Honth: (oseq.onth _ _) => [[li_ii1 li_i1]|] //.
      rewrite /eval_instr /eval_jump; case: (li_i1) => //.
      - move => [fn1 l1] /=; rewrite get_fundef_partial get_fundef_union.
        case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=.
        by rewrite !find_label_tunnel_partial.
      - move => pe1 /= Htunnel; t_xrbindP => w v Hv Hw.
        rewrite Hv /= Hw /= in Htunnel; move: Htunnel.
        rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
        case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_partial get_fundef_union.
        case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=.
        by rewrite !find_label_tunnel_partial.
      - by move => lv l /=; rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
      move => pe1 l1 /= Htunnel; t_xrbindP => b v Hv Hb.
      rewrite Hv /= Hb /= in Htunnel; move: Htunnel.
      case: b {Hb} => //; rewrite get_fundef_partial get_fundef_union Heqfns1.
      by case: (get_fundef _ _) => [fd1|].
    move: s1 Heqfns1 Hgfds1 => [mem1 vm1 fn1 pc1] /= /eqP ? Hgfds1; subst fn1.
    pose s1:= Lstate mem1 vm1 fn pc1; rewrite -/s1.
    move: Hgfds1; rewrite Hgfd => -[?]; subst fds1.
    rewrite !onth_map; case Honth: (oseq.onth _ _) => [[li_ii1 li_i1]|] // Hplsem1.
    rewrite /eval_instr /eval_jump; case: li_i1 Honth => [? ? ?| |?|[fn1 l1]|pe1|lv l|pe1 l1] //=.
    1-3:
      move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
      by rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth //=.
    2:
      by move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
      rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=;
      move => Htunnel; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /= in Htunnel; move: Htunnel;
      rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union;
      case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_partial get_fundef_union;
      case: (get_fundef _ _) => [fd1|] //; case Heqfn1: (fn == fn1) => //=;
      rewrite !find_label_tunnel_partial.
    2:
      by rewrite Hlabel_in_lprog_tunnel_union; move => Honth; have:= (Hplsem1 s1 s2); clear Hplsem1;
      rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr Hlabel_in_lprog_tunnel.
    + move => Honth.
      case Heqfn1: (fn == fn1) => //; last first.
      - have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
        rewrite Heqfn1 get_fundef_union // Heqfn1 get_fundef_partial.
        by case Hgfd1: (get_fundef _ _) => [fd1|] //; rewrite Heqfn1.
      move: Heqfn1 => /eqP ?; subst fn1.
      rewrite eq_refl /= LUF.find_union !LUF.find_empty.
      rewrite get_fundef_partial Hgfd eq_refl /=; t_xrbindP => pc3.
      case: ifP; last first.
      - have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
        rewrite eq_refl get_fundef_partial Hgfd /= eq_refl !find_label_tunnel_partial /=.
        by move => Htunnel _ Hpc13 Hs2; rewrite Hpc13 /= Hs2 /= in Htunnel; apply: Htunnel.
      rewrite find_label_tunnel_partial.
      move => Heqfind Hfindl Hsetcpc.
      pose s1':= Lstate mem1 vm1 fn (size ttli).+1.
      have:= (Hplsem1 s1' s2); have:= (Hplsem1 s1 s1'); rewrite /s1' /= -/s1'; clear Hplsem1.
      rewrite get_fundef_partial Hgfd eq_refl !onth_map Honth /= eq_refl /eval_instr /eval_jump /=.
      rewrite get_fundef_partial Hgfd eq_refl /setcpc.
      rewrite lfd_body_setfb -(eqP Heqfind) /= find_label_tunnel_partial.
      rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      rewrite (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      rewrite /= -/s1' -(prefix_onth Hprefix); last by rewrite !size_rcons.
      rewrite !onth_rcons !size_rcons eq_refl /= eq_refl get_fundef_partial Hgfd eq_refl.
      rewrite /= find_label_tunnel_partial Hfindl /=.
      move: Hsetcpc; rewrite /s1' /setcpc /= -/s1' => ->.
      by move => Hlsem11' Hlsem12'; apply: (@lsem_trans _ s1'); first apply: Hlsem11'; last apply Hlsem12'.
  move => Honth.
  t_xrbindP => b v Hv; case: b => Hb; last first.
  + have:= (Hplsem1 s1 s2); clear Hplsem1;
    rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
    by rewrite Hv /= Hb /=.
  rewrite get_fundef_partial Hgfd eq_refl /=; t_xrbindP => pc3.
  rewrite LUF.find_union !LUF.find_empty.
  case: ifP; last first.
  + have:= (Hplsem1 s1 s2); clear Hplsem1;
    rewrite get_fundef_partial /s1 /= -/s1 Hgfd eq_refl !onth_map Honth /eval_instr /eval_jump /=.
    rewrite Hv /= Hb /= find_label_tunnel_partial => Hpc _ Hpc3 Hs2; move: Hpc.
    rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
    by rewrite Hpc3 /= Hs2 /=; move => Hlsem; apply: Hlsem.
  rewrite find_label_tunnel_partial.
  move => Heqfind Hfindl Hsetcpc.
  pose s1':= Lstate mem1 vm1 fn (size ttli).+1.
  have:= (Hplsem1 s1' s2); have:= (Hplsem1 s1 s1'); rewrite /s1' /= -/s1'; clear Hplsem1.
  rewrite get_fundef_partial Hgfd eq_refl onth_map Honth /eval_instr /eval_jump /= Hv /= Hb /=.
  rewrite get_fundef_partial Hgfd eq_refl onth_map.
  rewrite -(eqP Heqfind) /= find_label_tunnel_partial.
  rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
  rewrite (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
  rewrite /= -/s1' -(prefix_onth Hprefix); last by rewrite !size_rcons.
  rewrite !onth_rcons !size_rcons eq_refl /= eq_refl get_fundef_partial Hgfd eq_refl.
  rewrite /= find_label_tunnel_partial Hfindl /=.
  move: Hsetcpc; rewrite /s1' /setcpc /= -/s1' => ->.
  by move => Hlsem11' Hlsem12'; apply: (@lsem_trans _ s1'); first apply: Hlsem11'; last apply Hlsem12'.
  Qed.

  Lemma tunneling_lsem s1 s2 : lsem (lprog_tunnel fn p) s1 s2 -> lsem p s1 s2.
  Proof.
    move: s1 s2; apply: lsem_ind; first by move => s; apply Relation_Operators.rt_refl.
    by move => s1 s2 s3 H1tp12 _ Hp23; apply: (lsem_trans (tunneling_lsem1 H1tp12)).
  Qed.

  Definition lsem_path_prop P p' s1 s2 :=
    exists ss,    List.Forall2 (lsem1 p') (s1 :: ss) (rcons ss s2)
           /\ List.Forall P ss.

  Lemma lsem_path_prop_lsem P p' s1 s2 :
    lsem_path_prop P p' s1 s2 ->
    lsem p' s1 s2.
  Proof.
    case => ss [Hforall2 _]; elim: ss s1 Hforall2 => [|s ss IHss] /= s1 Hforall2.
    + by inversion Hforall2; subst; apply Relation_Operators.rt_step.
    inversion Hforall2 as [|l1 l2 l3 l4 Hlsem1 Hforall2']; subst l1 l2 l3 l4.
    have:= (IHss _ Hforall2'); apply Relation_Operators.rt_trans.
    by apply Relation_Operators.rt_step.
  Qed.

  Lemma lsem_path_prop_nil P p' s1 s2 :
    lsem1 p' s1 s2 ->
    lsem_path_prop P p' s1 s2.
  Proof.
    move => Hlsem1; exists [::]; split; last by apply List.Forall_nil.
    by apply List.Forall2_cons.
  Qed.

  Lemma lsem_path_prop_cons (P : lstate -> Prop) p' s1 s2 s3 :
    lsem1 p' s1 s2 ->
    P s2 ->
    lsem_path_prop P p' s2 s3 ->
    lsem_path_prop P p' s1 s3.
  Proof.
    move => Hlsem1 HP [ss] [HForall2 HForall]; exists (s2 :: ss); split.
    + by apply List.Forall2_cons.
    by apply List.Forall_cons.
  Qed.

  Lemma Forall_rcons (A : Type) (P : A → Prop) l x :
    P x →
    List.Forall P l →
    List.Forall P (rcons l x).
  Proof.
    move => HP HForall; rewrite -cats1 List.Forall_app; split => //.
    by apply List.Forall_cons => //; apply List.Forall_nil.
  Qed.

  Lemma Forall2_rcons (A B : Type) (P : A -> B → Prop) l1 l2 x1 x2 :
    P x1 x2 →
    List.Forall2 P l1 l2 →
    List.Forall2 P (rcons l1 x1) (rcons l2 x2).
  Proof.
    move => HP HForall2; rewrite -!cats1; apply List.Forall2_app => //.
    by apply List.Forall2_cons => //; apply List.Forall2_nil.
  Qed.

  Lemma lsem_path_prop_rcons (P : lstate -> Prop) p' s1 s2 s3 :
    lsem1 p' s2 s3 ->
    P s2 ->
    lsem_path_prop P p' s1 s2 ->
    lsem_path_prop P p' s1 s3.
  Proof.
    move => Hlsem1 HP [ss] [HForall2 HForall]; exists (rcons ss s2); split.
    + by rewrite -rcons_cons; apply Forall2_rcons.
    by apply Forall_rcons.
  Qed.

  Lemma lsem_path_prop_label_impl s1 s2 fd uf uf' :
    get_fundef (lp_funcs p) fn = Some fd ->
    (exists ii l, find_instr p s1 = Some (MkLI ii (Llabel l))) ->
    lsem_path_prop
      (fun s => exists ii l, find_instr p s = Some (MkLI ii (Llabel l)))
      (setfuncs p [seq (f.1, if fn == f.1 then setfb f.2 (tunnel_partial fn uf (lfd_body fd)) else f.2) | f <- lp_funcs p])
      s1 s2 ->
    lsem_path_prop
      (fun s => exists ii l, find_instr p s = Some (MkLI ii (Llabel l)))
      (setfuncs p [seq (f.1, if fn == f.1 then setfb f.2 (tunnel_partial fn uf' (lfd_body fd)) else f.2) | f <- lp_funcs p])
      s1 s2.
  Proof.
    move => Hgfd [li_ii1] [l1] Hfindinstr1 [ss] [HForall2 HForall]; exists ss.
    move: HForall2 HForall; elim: ss s1 li_ii1 l1 Hfindinstr1 => [|s ss IHss] s1 li_ii1 l1 Hfindinstr1.
    + rewrite /= => HForall2 _; split; last by apply List.Forall_nil.
      inversion HForall2 as [|s1' s2' ss1' ss2' Hlsem1 _]; subst s1' s2' ss1' ss2'.
      apply List.Forall2_cons => {HForall2}; last by apply List.Forall2_nil.
      move: Hfindinstr1 Hlsem1; rewrite /lsem1 /step /find_instr.
      rewrite !lp_funcs_setfuncs !get_fundef_partial.
      case Hgfd1: (get_fundef (lp_funcs p) (lfn s1)) => [fd1|//].
      case: ifP => // [/eqP ?|_]; last by move => ->.
      rewrite !lfd_body_setfb {1 3}/tunnel_partial !onth_map.
      by subst fn; move: Hgfd Hgfd1 => -> [?]; subst fd => ->.
    rewrite rcons_cons => HForall2_cons HForall_cons.
    inversion HForall2_cons as [|s1' s2' ss1' ss2' Hlsem1 HForall2]; subst s1' s2' ss1' ss2'.
    inversion HForall_cons as [|s' ss' Hfindinstr HForall]; subst s' ss'.
    move: Hfindinstr => [li_ii] [l] => Hfindinstr {HForall2_cons HForall_cons}.
    move: (IHss s li_ii l Hfindinstr HForall2 HForall); clear IHss HForall2 HForall.
    move => [HForall2 HForall]; split.
    + apply List.Forall2_cons => //; move: Hfindinstr1 Hlsem1.
      rewrite /lsem1 /step /find_instr !lp_funcs_setfuncs !get_fundef_partial.
      case Hgfd1: (get_fundef (lp_funcs p) (lfn s1)) => [fd1|//].
      case: ifP => // [/eqP ?|_]; last by move => ->.
      rewrite !lfd_body_setfb {1 3}/tunnel_partial !onth_map.
      by subst fn; move: Hgfd Hgfd1 => -> [?]; subst fd => ->.
    by apply List.Forall_cons => //; exists li_ii; exists l.
  Qed.

  Lemma lsem11_tunneling s1 s2 :
    lsem1 p s1 s2 ->
    lsem1 (lprog_tunnel fn p) s1 s2 \/
    (exists s3, [ /\ lsem_path_prop (fun s => exists ii l, find_instr p s = Some (MkLI ii (Llabel l))) (lprog_tunnel fn p) s2 s3 ,
                lsem1 (lprog_tunnel fn p) s1 s3 &
                exists ii l, find_instr p s2 = Some (MkLI ii (Llabel l))]) \/
    (exists s3, [/\ lsem1 (lprog_tunnel fn p) s2 s3 ,
               lsem1 (lprog_tunnel fn p) s1 s3 &
               exists ii l, find_instr p s2 = Some (MkLI ii (Lgoto (fn, l)))]).
  Proof.
    rewrite /lprog_tunnel; case Hgfd: (get_fundef _ _) => [fd|]; last by left.
    move: s1 s2; pattern (lfd_body fd), (lfd_body fd) at 2 4 6 8 10; apply: prefixW.
    + move => s1 s2 Hlsem1; left.
      apply: (@get_fundef_lsem1 p _ s1 s2 _ _ Hlsem1); first by rewrite -(label_in_lprog_tunnel [::]) Hgfd.
      clear Hlsem1 => fn'.
      rewrite lp_funcs_setfuncs /lfundef_tunnel_partial /tunnel_plan /= /tunnel_partial pairmap_tunnel_bore_empty.
      rewrite (get_fundef_map2 fn' (fun f1 f2 => if fn == f1 then setfb f2 (lfd_body fd) else f2) (lp_funcs p)).
      case Hgfd': (get_fundef _ _) => [fd'|] //; case: ifP => // /eqP ?; subst fn'.
      by move: Hgfd'; rewrite Hgfd => -[?]; subst fd'; rewrite setfb_lfd_body.
    move => [li_ii4 li_i4] tli.
    have:= label_in_lprog_tunnel (rcons tli {| li_ii := li_ii4; li_i := li_i4 |}).
    have:= label_in_lprog_tunnel tli.
    rewrite Hgfd /lfundef_tunnel_partial /tunnel_plan pairfoldl_rcons.
    case: (lastP tli).
    + move => _ _ _ _ s1 s2 Hlsem1; left; rewrite /= /tunnel_partial.
      set p' := setfuncs _ _; have ->//: p' = p; rewrite /p'; clear p'.
      move: wf_p; rewrite /well_formed_lprog => /andP [Huniq _].
      move => {Hlsem1}; case: p Hgfd Huniq => ? ? ? funcs /= Hgfd Huniq; rewrite /setfuncs /=; f_equal.
      elim: funcs Hgfd Huniq => // f funcs /=; case: f => f1 f2 /=.
      case: ifP; last by move => _ IHfuncs Hgfd /andP [_ Huniq]; rewrite IHfuncs.
      move => /eqP ?; subst f1 => _ [?]; subst f2 => /andP [Hnotin Huniq].
      f_equal; last first.
      - elim: funcs Hnotin {Huniq} => //= [[fn' fd'] funcs].
        rewrite in_cons negb_or /= => IHfuncs /andP [Hneq Hnotin]; rewrite IHfuncs //.
        by case: ifP => // /eqP ?; subst fn; move: Hneq; rewrite eq_refl.
      f_equal; case: fd => ? ? ? ? fb ? ? ?; rewrite /setfb /=; f_equal.
      by elim: fb => // c fb /= ->; rewrite tunnel_bore_empty.
    move => ttli [li_ii3 li_i3]; rewrite last_rcons /=.
    have Hwfb:= (get_fundef_wf Hgfd).
    move => Heqlabel Heqlabel' Hprefix.
    have Hprefix'' := (prefix_rcons (rcons ttli {| li_ii := li_ii3; li_i := li_i3 |}) {| li_ii := li_ii4; li_i := li_i4 |}).
    have Hprefix' := (prefix_trans Hprefix'' Hprefix).
    move: Heqlabel Heqlabel' Hprefix Hprefix' {Hprefix''}.
    case: li_i3; case: li_i4 => //.
    + move => l4 l3; set uf := pairfoldl _ _ _ _.
      move => Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union Hprefix Hprefix' Hplsem1 s1 s2.
      move: Hplsem1; rewrite /lsem1 /step /find_instr !lp_funcs_setfuncs get_fundef_union //.
      case Hgfds1: (get_fundef _ _) => [fds1|] //.
      case Heqfns1: (fn == lfn s1); last first.
      - move => Hplsem1; have:= (Hplsem1 s1 s2); clear Hplsem1; rewrite Hgfds1.
        case Honth1: (oseq.onth _ _) => [[li_ii1 li_i1]|] //.
        rewrite get_fundef_partial Hgfds1 Heqfns1 Honth1.
        move => _ Hevalinstr; left; move: Hevalinstr.
        rewrite /eval_instr /eval_jump; case: (li_i1) => //=.
        * move => [fn1 l1] /=; rewrite get_fundef_union.
          case Heqfn1: (fn == fn1); last by case Hgfd1: (get_fundef _ _) => [fd1|].
          move: Heqfn1 => /eqP ?; subst fn1; rewrite Hgfd.
          by rewrite /= !find_label_tunnel_partial.
        * move => pe1; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /=.
          rewrite Hlabel_in_lprog_tunnel_union.
          case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_union.
          case Heqfn1: (fn == fn1); last by case Hgfd1: (get_fundef _ _) => [fd1|].
          move: Heqfn1 => /eqP ?; subst fn1; rewrite Hgfd.
          by rewrite /= !find_label_tunnel_partial.
        * by move => lv l; rewrite Hlabel_in_lprog_tunnel_union.
        move => pe1 l1; t_xrbindP => b v Hv Hb; rewrite Hv /= Hb /=.
        case: b {Hb} => //; rewrite get_fundef_union Heqfns1.
        by case: get_fundef.
      move: s1 Heqfns1 Hgfds1 => [mem1 vm1 fn1 pc1] /= /eqP ?; subst fn1.
      rewrite Hgfd => -[?]; subst fds1.
      pose s1:= Lstate mem1 vm1 fn pc1; rewrite /= -/s1.
      move: s2 => [mem2 vm2 fn2 pc2]; pose s2:= Lstate mem2 vm2 fn2 pc2; rewrite /= -/s2.
      rewrite !onth_map.
      case Honth1: (oseq.onth _ pc1) => [[li_ii1 li_i1]|] //.
      rewrite {4}/eval_instr /eval_jump; case: li_i1 Honth1 => [? ? ?| |?|[fn1 l1]|pe1|lv l|pe1 l1] //=.
      1-3:
        by move => Honth1 Hplsem1;
        have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite /s1 /= -/s1 Hgfd Honth1 /=;
        move => _ Htunnel; left.
      2:
        by rewrite /eval_instr /eval_jump => Honth1 Hplsem1;
        have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite /s1 /= -/s1 Hgfd Honth1 /=;
        move => _ Htunnel; left;
        move: Htunnel; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /=;
        rewrite Hlabel_in_lprog_tunnel_union;
        case: (decode_label _ w) => [[fn1 l1]|] //; rewrite get_fundef_union;
        case Hgfd1: (get_fundef _ _) => [fd1|] //;
        case Heqfn1: (fn == fn1) => //; move: Heqfn1 => /eqP ?; subst fn1;
        move: Hgfd1; rewrite Hgfd => -[?]; subst fd1;
        rewrite /= !find_label_tunnel_partial.
      2:
        by rewrite /eval_instr => Honth1 Hplsem1;
        have:= (Hplsem1 s1 s2); clear Hplsem1;
        rewrite /s1 /= -/s1 Hgfd Honth1 /=;
        move => _ Htunnel; left;
        rewrite Hlabel_in_lprog_tunnel_union.
      - rewrite {5 6}/eval_instr /eval_jump /=.
        rewrite !get_fundef_union eq_refl Hgfd => Honth1 Hplsem1.
        case Heqfn1: (fn == fn1) => //; last first.
        * have:= (Hplsem1 s1 s2); clear Hplsem1.
          rewrite /s1 /= -/s1 Hgfd Honth1 /=.
          move => _ Htunnel; left.
          rewrite Heqfn1 get_fundef_union Heqfn1.
          by move: Htunnel; case: (get_fundef _ _) => [fd1|].
        move: Heqfn1 => /eqP ?; subst fn1.
        rewrite Hgfd eq_refl /= LUF.find_union !LUF.find_empty get_fundef_union Hgfd eq_refl.
        t_xrbindP => pcf1 Hpcf1 ? ? ? ?; subst mem2 vm2 fn2 pc2.
        rewrite /= !find_label_tunnel_partial.
        have:= (Hplsem1 s1 s2); rewrite /eval_instr /eval_jump /=.
        rewrite /s1 /= -/s1 Hgfd Honth1 /= Hgfd /= Hpcf1 /= get_fundef_partial Hgfd eq_refl.
        rewrite lfd_body_setfb onth_map Honth1 /= eq_refl get_fundef_partial Hgfd eq_refl.
        rewrite lfd_body_setfb /= !find_label_tunnel_partial.
        move => -[//| |[[s3] | [s3]]].
        * clear Hplsem1; case: ifP => //; last by left.
          rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
          move => /eqP Hfindl; t_xrbindP => pcf1' Hpcf1' ?; subst pcf1'.
          move: Hpcf1 Hpcf1'; rewrite {1 2}/find_label -!has_find; do 2! case : ifP => //.
          move => _ Hhas [Hpcf1] [Hpcf1']; have:= (@find_is_label_eq _ (LUF.find uf l1) _ Hhas).
          rewrite Hpcf1 -{1}Hpcf1' -Hfindl => Heqfind; rewrite Heqfind // in Hpcf1.
          have Hfindislabel:= (@find_is_label _ _ _ l3 (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
          move: (Hpcf1); rewrite Hfindislabel; last by rewrite /is_label //=.
          move => Hpcf1''; move: Hpcf1 Hpcf1'; subst pcf1 => Hpcf1 Hpcf1'.
          rewrite (find_plan_partial_nhas Hwfb Hprefix' _); last first.
          + move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
            by rewrite has_rcons negb_or => /andP [].
          rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /=.
          right; left; exists (setcpc s1 fn (size ttli).+2); split => //.
          + apply lsem_path_prop_nil; rewrite /s1 /s2 /setcpc /=.
            rewrite /lsem1 /step /find_instr lp_funcs_setfuncs get_fundef_partial Hgfd eq_refl /=.
            rewrite {1}/tunnel_partial onth_map.
            rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
            by rewrite onth_rcons size_rcons eq_refl /eval_instr /= /setpc.
          + rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
            by rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons.
          rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
          by rewrite onth_rcons size_rcons eq_refl; exists li_ii4; exists l4.
        * clear Hplsem1 => -[Hlsem_path_prop]; t_xrbindP => pcf1' Hpcf1'.
          rewrite {1}/s1 /setcpc /= => ?; subst s3; set s3:= Lstate _ _ _ _ in Hlsem_path_prop.
          move => [li_ii1'] [l1'] Honth1'; case : ifP => // Heqfind; last first.
          + right; left; exists s3; split => //.
            - move: Hlsem_path_prop; apply lsem_path_prop_label_impl => //.
              by exists li_ii1'; exists l1'; rewrite /find_instr /s2 /= Hgfd.
            - rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
              by rewrite find_label_tunnel_partial Hpcf1' /= /s3.
            by rewrite Honth1'; exists li_ii1'; exists l1'.
          move: Heqfind Hpcf1' Honth1'; rewrite (find_plan_partial Hwfb Hprefix') => /eqP Hf3; rewrite -Hf3.
          rewrite (prefix_rcons_find_label Hwfb Hprefix')=> -[?]; subst pcf1' => Honth1'.
          right; left; exists (setpc s1 ((size ttli).+2)); split.
          + apply (@lsem_path_prop_rcons _ _ _ s3).
            - rewrite /s3 /lsem1 /step /find_instr lp_funcs_setfuncs get_fundef_partial /=.
              rewrite Hgfd eq_refl lfd_body_setfb {1}/tunnel_partial onth_map.
              rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
              rewrite onth_rcons size_rcons eq_refl /eval_instr /=.
              by rewrite /s1 /setpc.
            - rewrite /s3 /= Hgfd -(prefix_onth Hprefix); last by rewrite !size_rcons.
              by rewrite onth_rcons size_rcons eq_refl; exists li_ii4; exists l4.
            move: Hlsem_path_prop; apply lsem_path_prop_label_impl => //.
            by exists li_ii1'; exists l1'; rewrite /find_instr /s2 /= Hgfd.
          + rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
            rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
            - move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
              by rewrite has_rcons negb_or => /andP [].
            rewrite find_label_tunnel_partial (prefix_rcons_find_label Hwfb Hprefix).
            by rewrite size_rcons /= /s1 /s3 /setpc.
          by rewrite Honth1'; exists li_ii1'; exists l1'.
        clear Hplsem1; move => -[].
        case: ifP => //; last first.
        * move => Hfindl Hlsemsetfuncs; t_xrbindP => pcff1 Hpcff1 Hs3.
          move => [li_ii5] [l5]; rewrite Hpcff1 /= => Honth5.
          right; right; exists s3; subst s3; split => //; first last.
          + by exists li_ii5; exists l5.
          + by rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial Hpcff1.
          move: Hlsemsetfuncs; rewrite /setcpc /=; set s3 := Lstate _ _ _ _.
          rewrite {1}/tunnel_partial onth_map Honth5 /= eq_refl /=.
          rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
          t_xrbindP => pcff5 Hpcff5 ?; subst pcff5.
          rewrite {1 2}/tunnel_partial !onth_map Honth5 /= eq_refl /= eq_refl /=.
          rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
          rewrite LUF.find_union !LUF.find_empty -(find_label_inj Hwfb Hpcff1 Hpcff5).
          by rewrite Hfindl Hpcff1 /= /s1 /s3.
        move => Hfindl Hlsemsetfuncs; t_xrbindP => pcff1 Hpcff1 Hs3.
        move => [li_ii5] [l5] Honth1'; move: Hlsemsetfuncs.
        rewrite /s1 /setcpc /= in Hs3; subst s3; set s3:= Lstate _ _ _ _.
        rewrite {1}/tunnel_partial onth_map Honth1' {1}/tunnel_bore /= eq_refl /=.
        rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
        t_xrbindP => pcff5 Hpcff5 ?; subst pcff5.
        have Heqfind:= (find_label_inj Hwfb Hpcff1 Hpcff5).
        right; right; exists (setpc s1 (size ttli).+2); split.
        * rewrite {1 2}/tunnel_partial !onth_map Honth1' {1 2}/tunnel_bore !eq_refl /=.
          rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
          rewrite LUF.find_union; move: Hfindl => /eqP Hfindl.
          rewrite -Heqfind Hfindl eq_refl LUF.find_empty.
          rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
          + move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
            by rewrite has_rcons negb_or => /andP [].
          rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /=.
          by rewrite /s1 /s2 /setpc /setcpc.
        * rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
          rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
          + move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
            by rewrite has_rcons negb_or => /andP [].
          rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /=.
          by rewrite /s1 /setpc /setcpc.
        by exists li_ii5; exists l5.
      move => Honth IHmatch; rewrite {1 2}/eval_instr /= Hgfd /=; move: Honth IHmatch.
      rewrite !get_fundef_union eq_refl Hgfd => Honth1 Hplsem1.
      t_xrbindP => b v Hv Hb; rewrite Hv /= Hb /=; case: b Hb => Hb; last by left.
      t_xrbindP => pcf1 Hpcf1 ? ? ? ?; subst mem2 vm2 fn2 pc2.
      rewrite !find_label_tunnel_partial LUF.find_union !LUF.find_empty.
      have:= (Hplsem1 s1 s2); clear Hplsem1.
      rewrite /s1 /= -/s1 Hgfd Honth1 /= {1}/eval_instr /= Hgfd /=.
      rewrite Hpcf1 /= Hv /= Hb /= /setcpc /s1 /s2 /= -/s1 -/s2.
      rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb {1}/tunnel_partial onth_map Honth1 /=.
      rewrite {1}/eval_instr /= Hv /= Hb /= get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
      rewrite !find_label_tunnel_partial !onth_map.
      move => -[//| |[[s3]|[s3]]].
      - case: ifP => //; last by left.
        rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        move => /eqP Hfindl; t_xrbindP => pcf1' Hpcf1' ?; subst pcf1'.
        move: Hpcf1 Hpcf1'; rewrite {1 2}/find_label -!has_find; do 2! case : ifP => //.
        move => _ Hhas [Hpcf1] [Hpcf1']; have:= (@find_is_label_eq _ (LUF.find uf l1) _ Hhas).
        rewrite Hpcf1 -{1}Hpcf1' -Hfindl => Heqfind; rewrite Heqfind // in Hpcf1.
        have Hfindislabel:= (@find_is_label _ _ _ l3 (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        move: (Hpcf1); rewrite Hfindislabel; last by rewrite /is_label //=.
        move => Hpcf1''; move: Hpcf1 Hpcf1'; subst pcf1 => Hpcf1 Hpcf1'.
        rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
        rewrite onth_rcons !size_rcons eq_refl /eval_instr /=.
        rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
        rewrite !find_label_tunnel_partial !Hv /= !Hb /=.
        rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
        * move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
          by rewrite has_rcons negb_or => /andP [].
        rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /=.
        right; left; exists (setcpc s1 fn (size ttli).+2).
        rewrite /s1 /s2 /setcpc /=; split => //; last by exists li_ii4; exists l4.
        apply lsem_path_prop_nil; rewrite /lsem1 /step /find_instr lp_funcs_setfuncs.
        rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
        rewrite {1}/tunnel_partial onth_map -(prefix_onth Hprefix); last by rewrite !size_rcons.
        by rewrite onth_rcons !size_rcons eq_refl /eval_instr /= /setpc.
      - rewrite {1}/eval_instr /= get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
        rewrite Hv /= Hb /= find_label_tunnel_partial => -[Hlsem_path_prop].
        t_xrbindP => pcff1 Hpcff1; rewrite {1}/s1 {1}/setcpc /= => ?; subst s3.
        move: Hlsem_path_prop; set s3 := Lstate _ _ _ _ => Hlsem_path_prop.
        move => [li_ii5] [l5] Honth5; rewrite Honth5 /eval_instr /=.
        rewrite Hv /= Hb /= get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
        case: ifP => // Heqfind; last first.
        * rewrite Hpcff1 /=; right; left; exists s3; split => //; last by exists li_ii5; exists l5.
          move: Hlsem_path_prop; apply lsem_path_prop_label_impl => //.
          by rewrite /s2 /find_instr Hgfd /= Honth5; exists li_ii5; exists l5.
        rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
        * move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
          by rewrite has_rcons negb_or => /andP [].
        rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /s1 /setcpc /=.
        right; left; exists {| lmem := mem1; lvm := vm1; lfn := fn; lpc := (size ttli).+2 |}.
        split => //; last by exists li_ii5; exists l5.
        rewrite (find_plan_partial Hwfb Hprefix') in Heqfind.
        move: Heqfind Hpcff1 => /eqP Heqfind; rewrite -Heqfind => Hpcff1.
        have:= (prefix_rcons_find_label Hwfb Hprefix'); rewrite Hpcff1 => -[?]; subst pcff1.
        apply (@lsem_path_prop_rcons _ _ _ s3).
        * rewrite /s3 /lsem1 /step /find_instr lp_funcs_setfuncs get_fundef_partial /=.
          rewrite Hgfd eq_refl lfd_body_setfb {1}/tunnel_partial onth_map.
          rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
          rewrite onth_rcons size_rcons eq_refl /eval_instr /=.
          by rewrite /s1 /setpc.
        * rewrite /s3 /= Hgfd -(prefix_onth Hprefix); last by rewrite !size_rcons.
          by rewrite onth_rcons size_rcons eq_refl; exists li_ii4; exists l4.
        move: Hlsem_path_prop; apply lsem_path_prop_label_impl => //.
        by rewrite /find_instr /s2 /= Hgfd Honth5; exists li_ii5; exists l5.
      move => [Hmatch]; rewrite {1}/eval_instr /= Hv /= Hb /=.
      rewrite get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
      t_xrbindP => pcff1 Hpcff1; rewrite {1}/s1 {1}/setcpc /= => ?.
      subst s3; set s3 := Lstate _ _ _ _ in Hmatch.
      move => [li_ii5] [l5] Honth5; move: Hmatch; rewrite Honth5.
      rewrite {1}/tunnel_bore eq_refl /= get_fundef_partial Hgfd eq_refl /= find_label_tunnel_partial.
      t_xrbindP => pcff5 Hpcff5 ?; subst pcff5.
      have Heqfind:= (find_label_inj Hwfb Hpcff1 Hpcff5); clear Hpcff5.
      rewrite eq_refl /eval_instr /= !get_fundef_partial Hgfd eq_refl /= !find_label_tunnel_partial.
      rewrite Hv /= Hb /= LUF.find_union !LUF.find_empty -Heqfind.
      rewrite (find_plan_partial Hwfb Hprefix').
      case: ifP => // [/eqP Heqfind'|Hneqfind]; last first.
      - rewrite Hpcff1 /=; right; right; exists s3; rewrite /s1 /s2 /s3 /setcpc /=; split => //.
        by exists li_ii5; exists l5.
      rewrite (find_plan_partial_nhas Hwfb Hprefix'); last first.
      - move: Hwfb => /andP [Huniq _]; have:= (uniq_nhas Huniq Hprefix).
        by rewrite has_rcons negb_or => /andP [].
      rewrite (prefix_rcons_find_label Hwfb Hprefix) size_rcons /=.
      right; right; exists (setcpc s1 fn (size ttli).+2); rewrite /s1 /s2 /setcpc /=.
      by split => //; exists li_ii5; exists l5.
    move => [fn4 l4] l3; case Heqfn4: (fn == fn4) => //; move: Heqfn4 => /eqP ?; subst fn4.
    set uf := pairfoldl _ _ _ _ => Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
    move => Hprefix Hprefix' IHlsem1 [mem1 vm1 fn1 pc1] [mem2 vm2 fn2 pc2].
    set s1:= Lstate _ _ _ _; set s2:= Lstate _ _ _ _; case Heqfns1: (fn == fn1); last first.
    + move => Hlsem1; left; move: Hlsem1; clear IHlsem1.
      rewrite /lsem1 /step /find_instr lp_funcs_setfuncs.
      rewrite get_fundef_partial Heqfns1 /s1 /= -/s1.
      case Hgfd1: (get_fundef _ _) => [fd1|//].
      case Honth1: (oseq.onth _ _) => [[li_ii1 li_i1]|//].
      rewrite /eval_instr /eval_jump /=; case: li_i1 Honth1 => //=.
      - move => [fn1' l1']; rewrite get_fundef_partial.
        case Hgfd1': (get_fundef _ _) => [fd1' /=|//].
        case: ifP => //; rewrite lfd_body_setfb find_label_tunnel_partial.
        by move => /eqP ?; subst fn1'; move: Hgfd1'; rewrite Hgfd => -[?]; subst fd1'.
      - move => pe1; rewrite Hlabel_in_lprog_tunnel_union => Honth1.
        t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /=.
        case: (decode_label _ _) => [[fn1' l1']|//]; rewrite get_fundef_partial.
        case Hgfd1': (get_fundef _ _) => [fd1' /=|//].
        case: ifP => //; rewrite lfd_body_setfb find_label_tunnel_partial.
        by move => /eqP ?; subst fn1'; move: Hgfd1'; rewrite Hgfd => -[?]; subst fd1'.
      - by move => lv l; rewrite Hlabel_in_lprog_tunnel_union.
      move => pe1 l1 Honth1; t_xrbindP => b v Hv Hb; rewrite Hv /= Hb /=.
      case: b {Hb} => //; rewrite get_fundef_union Heqfns1.
      by case: get_fundef.
    move: Heqfns1 => /eqP ?; subst fn1; rewrite {1 2}/lsem1 /step /find_instr.
    rewrite lp_funcs_setfuncs get_fundef_partial /s1 /= -/s1 Hgfd eq_refl.
    rewrite lfd_body_setfb onth_map.
    case Honth1: (oseq.onth _ _) => [[li_ii1 li_i1]|] //.
    rewrite /eval_instr /eval_jump; case: li_i1 Honth1 => [? ? ?| |?|[fn1 l1]|pe1|lv l|pe1 l1] //=.
    1-3:
      move => Honth1 Hplsem1; have:= (IHlsem1 s1 s2);
      rewrite /lsem1 /step /find_instr /s1 /=;
      rewrite get_fundef_partial Hgfd eq_refl /=;
      rewrite /tunnel_partial onth_map Honth1 /eval_instr /= -/s1;
      by move => _; left.
    2:
      by move => Honth1 Hplsem1; have:= (IHlsem1 s1 s2); clear IHlsem1;
      rewrite /lsem1 /step /find_instr /s1 /=;
      rewrite get_fundef_partial Hgfd eq_refl /=;
      rewrite /tunnel_partial onth_map Honth1 /eval_instr /= -/s1;
      rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union;
      move => _; left; move: Hplsem1; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /=;
      case: (decode_label _ _) => // -[fn' ?] /=; rewrite get_fundef_partial;
      case Hgfd': (get_fundef _ _) => [fd'|//] /=; case: ifP => // /eqP ?; subst fn';
      rewrite lfd_body_setfb find_label_tunnel_partial;
      move: Hgfd'; rewrite Hgfd => -[?]; subst fd'.
    2:
      by move => Honth1 Hplsem1; have:= (IHlsem1 s1 s2); clear IHlsem1;
      rewrite /lsem1 /step /find_instr /s1 /=;
      rewrite get_fundef_partial Hgfd eq_refl /=;
      rewrite /tunnel_partial onth_map Honth1 /eval_instr /= -/s1;
      move => _; left; rewrite Hlabel_in_lprog_tunnel_union.
    + move => Honth1; case: ifP => [/eqP ?|Hneqfn1]; last first.
      - rewrite get_fundef_partial Hneqfn1 => Hmatch.
        by left; move: Hmatch; case: (get_fundef _ _).
      subst fn1; rewrite Hgfd /=; t_xrbindP => pcf1 Hpcf1 ? ? ? ?.
      subst mem2 vm2 fn2 pc2; rewrite get_fundef_partial Hgfd eq_refl.
      rewrite lfd_body_setfb /= find_label_tunnel_partial LUF.find_union.
      rewrite (find_plan_partial Hwfb Hprefix'); have:= (IHlsem1 s1 s2).
      rewrite /lsem1 /step /find_instr /s1 /= -/s1.
      rewrite !get_fundef_partial Hgfd eq_refl Honth1 !lfd_body_setfb.
      rewrite !onth_map Honth1 /= /eval_instr /= Hgfd eq_refl /= Hpcf1 /=.
      rewrite {1}/setcpc /s1 /s2 /= -/s1 -/s2.
      rewrite !get_fundef_partial Hgfd eq_refl !lfd_body_setfb /=.
      rewrite !find_label_tunnel_partial.
      case Honth5: (oseq.onth _ _) => [[li_ii5 li_i5]|]; last first.
      - move => -[//| |[[s3] [_ _ [?] [?]] //|[s3] [] //]].
        t_xrbindP => pcff1 Hpcff1 ?; subst pcff1.
        rewrite -(find_label_inj Hwfb Hpcf1 Hpcff1).
        case: ifP => [/eqP ?|Hneqlabel]; last first.
        * by rewrite Hpcf1 /= /s1 /s2 /setcpc /=; left.
        subst l1; exfalso; move: Hpcf1.
        rewrite (prefix_rcons_find_label Hwfb Hprefix') => -[?]; subst pcf1.
        move: Honth5; rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
        by rewrite onth_rcons size_rcons eq_refl.
      rewrite /tunnel_bore /= Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
      rewrite LUF.find_union (find_plan_partial Hwfb Hprefix').
      move => -[//| |[[s3]|[s3]]].
      - clear IHlsem1; t_xrbindP => pcff1 Hpcff1 ?; subst pcff1.
        rewrite -(find_label_inj Hwfb Hpcf1 Hpcff1).
        case: ifP => [/eqP ?|Hneqlabel]; last first.
        * by left; rewrite Hpcf1 /s1 /s2 /setcpc.
        subst l1; have:= (prefix_rcons_find_label Hwfb Hprefix').
        rewrite Hpcf1 => -[?]; subst pcf1; move: Honth5.
        rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
        rewrite onth_rcons size_rcons eq_refl => [[? ?]]; subst li_ii5 li_i5.
        rewrite eq_refl /= get_fundef_partial Hgfd eq_refl lfd_body_setfb /=.
        rewrite find_label_tunnel_partial LUF.find_union if_same.
        case: (prefix_find_label_goto Hwfb Hprefix) => pcf4 Hpcf4.
        case: (prefix_find_label Hwfb Hprefix' Hpcf4) => pcff4.
        rewrite {1}/tunnel_plan -/uf => Hpcff4; rewrite Hpcff4 /=.
        right; right; exists (setcpc s1 fn pcff4.+1); rewrite /s1 /s2 /setcpc /=.
        by split => //; exists li_ii4; exists l4.
      - move => [Hlsem_path_prop]; t_xrbindP => pcff1 Hpcff1.
        rewrite {1}/s1 {1}/setcpc /= => ?; subst s3.
        set s3:= Lstate _ _ _ _ in Hlsem_path_prop.
        move => [li_ii5'] [l5] [? ?]; subst li_ii5' li_i5.
        case: ifP => [/eqP Heql|Hneqlabel]; last first.
        * rewrite Hpcff1 /=; right; left; exists s3; split => //; last by exists li_ii5; exists l5.
          move: Hlsem_path_prop; apply lsem_path_prop_label_impl => //.
          by rewrite /find_instr Hgfd /s2 Honth5 /=; exists li_ii5; exists l5.
        move: (Hpcff1); rewrite -Heql (prefix_rcons_find_label Hwfb Hprefix').
        move => -[?]; subst pcff1.
        Search _ find_label.
        fail.
        case: (prefix_find_label_goto Hwfb Hprefix) => pcf4 Hpcf4.
        case: (prefix_find_label Hwfb Hprefix' Hpcf4) => pcff4.
        rewrite {1}/tunnel_plan -/uf => Hpcff4; rewrite Hpcff4 /=.
        fail.
      - clear Hplsem1; case: ifP => //; last by left.
        rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        move => /eqP Hfindl; t_xrbindP => pcf1' Hpcf1' ?; subst pcf1'.
        move: Hpcf1 Hpcf1'; rewrite {1 2}/find_label -!has_find; do 2! case : ifP => //.
        move => _ Hhas [Hpcf1] [Hpcf1']; have:= (@find_is_label_eq _ (LUF.find uf l1) _ Hhas).
        rewrite Hpcf1 -{1}Hpcf1' -Hfindl => Heqfind; rewrite Heqfind // in Hpcf1.
        have Hfindislabel:= (@find_is_label _ _ _ l3 (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
        move: (Hpcf1); rewrite Hfindislabel; last by rewrite /is_label //=.
        move => Hpcf1''; move: Hpcf1 Hpcf1'; subst pcf1 => Hpcf1 Hpcf1'.
        rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
        rewrite onth_rcons !size_rcons eq_refl {1}/tunnel_bore eq_refl /=.
        rewrite get_fundef_union Hgfd eq_refl LUF.find_union /=.
        rewrite !find_label_tunnel_partial.
        have:= (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP [_ Hall].
        move: Hall; rewrite /goto_targets all_filter all_map => Hall.
        have:= (prefix_all Hprefix Hall); rewrite all_rcons => /andP [Hl4 _]; clear Hall.
        rewrite /= mem_filter /= eq_refl /= in Hl4.
        have:= mapP Hl4 => -[[li_ii5 li_i5]] /= Hin ?.
        clear Hl4; subst li_i5; have Hhas4: has (is_label l4) (lfd_body fd).
        * by apply/hasP; eexists; first exact Hin; rewrite /is_label /= eq_refl.
        have: exists pc4, find_label l4 (lfd_body fd) = ok pc4.
        * by rewrite /find_label -has_find Hhas4; eexists.
        clear li_ii5 Hin Hhas => -[pc4] Hpc4.
        have:= (prefix_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix) Hpc4).
        rewrite /tunnel_plan -/uf => -[pcf4] Hpcf4; rewrite Hpcf4 /=.
        pose s3:= Lstate mem1 vm1 fn pcf4.+1; right; exists s3; split.
        * by case: ifP => _; rewrite Hpcf4 /= /setcpc /s2 /s3 /=.
        * by rewrite /setcpc /s1 /s3.
        by eexists; eauto.
      clear Hplsem1; move => -[]; case: ifP => //; last first.
      - move => Hfindl Hmatch Hs3; right; exists s3; split => //; move: Hmatch.
        case Honthp1: (oseq.onth _ _) => [[li_ii5 li_i5]|] //.
        case: li_i5 Honthp1 => //=.
        * move => [fn5 l5] /=; case: ifP => // Heqfn; rewrite get_fundef_union get_fundef_partial Heqfn //.
          move: Heqfn => /eqP ?; subst fn5; rewrite Hgfd LUF.find_union /= !find_label_tunnel_partial.
          case: ifP => // Hfindl' _; move: Hs3; t_xrbindP => pcff1 Hfindlabel1 ?; subst s3.
          move => ? Hfindlabel1'; rewrite /setcpc /s1 /s2 /= => -[?]; subst; exfalso.
          move: Hfindl => /eqP Hfindl; apply: Hfindl; move: Hfindl' Hfindlabel1 Hfindlabel1' => /eqP <-.
          rewrite /find_label; case: ifP; case: ifP => //; rewrite -has_find => Hhas _ [<-] [Hfind].
          by apply: (find_is_label_eq Hhas Hfind).
        * move => pe5 Honth5; t_xrbindP => w v Hv Hw; rewrite Hv /= Hw /=.
          rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
          case: (decode_label _ w) => //.
          move => [fn5 l5] /=; rewrite get_fundef_union get_fundef_partial.
          case Heqfn: (fn == fn5) => //; move: Heqfn => /eqP ?; subst fn5.
          by rewrite Hgfd /= !find_label_tunnel_partial.
        * by move => lv l; rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
        move => pe5 l5 Honth5; t_xrbindP => b v Hv Hb; rewrite Hv /= Hb /=; case: b {Hb} => //.
        rewrite !find_label_tunnel_partial LUF.find_union; case: ifP => // Hfindl'.
        move: Hs3; t_xrbindP => pcff1 Hfindlabel1 ?; subst s3.
        move => ? Hfindlabel1'; rewrite /setcpc /s1 /s2 /= => -[?]; subst; exfalso.
        move: Hfindl => /eqP Hfindl; apply: Hfindl; move: Hfindl' Hfindlabel1 Hfindlabel1' => /eqP <-.
        rewrite /find_label; case: ifP; case: ifP => //; rewrite -has_find => Hhas _ [<-] [Hfind].
        by apply: (find_is_label_eq Hhas Hfind).
      rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      move => /eqP Hfindl Hmatch; t_xrbindP => pcf1' Hpcf1'.
      move: s3 Hmatch => [mem3 vm3 fn3 pc3]; pose s3:= Lstate mem3 vm3 fn3 pc3; rewrite /= -/s3.
      move => Hmatch; rewrite /setcpc => -[? ? ? ?]; subst mem3 vm3 fn3 pc3; rewrite /s1 /= -/s1.
      move => [li_ii5] [l5] Honth5; right; move: Hpcf1' Hmatch; rewrite -Hfindl => Hpcf1'.
      have:= (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      rewrite Hpcf1' => -[?]; subst pcf1'.
      have:= (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP[_ Hall].
      move: Hall; rewrite /goto_targets all_filter all_map => Hall.
      have:= (prefix_all Hprefix Hall); rewrite all_rcons => /andP [Hl4 _]; clear Hall.
      rewrite /= mem_filter /= eq_refl /= in Hl4.
      have:= mapP Hl4 => -[[li_ii6 li_i6]] /= Hin ?.
      clear Hl4; subst li_i6; have Hhas4: has (is_label l4) (lfd_body fd).
      - by apply/hasP; eexists; first exact Hin; rewrite /is_label /= eq_refl.
      have: exists pc4, find_label l4 (lfd_body fd) = ok pc4.
      - by rewrite /find_label -has_find Hhas4; eexists.
      clear li_ii6 Hin Hhas4 => -[pc4] Hpc4.
      have:= (prefix_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix) Hpc4).
      rewrite /tunnel_plan -/uf => -[pcf4] Hpcf4; rewrite Hpcf4 /= => Hmatch.
      pose s4:= Lstate mem1 vm1 fn pcf4.+1; exists s4; split => //; last by eexists; eauto.
      move: Hmatch; rewrite Honth5 /= eq_refl get_fundef_union get_fundef_partial Hgfd eq_refl.
      rewrite /= LUF.find_union !find_label_tunnel_partial; case: ifP; first by rewrite Hpcf4 /s4.
      move => /negP Hfindl'; t_xrbindP => pcf5 Hpcf5 ?; subst pcf5; exfalso; apply: Hfindl'; apply/eqP.
      rewrite -(find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)) -/uf in Hpcf1'.
      move: Hpcf1' Hpcf5; rewrite /find_label; case: ifP; case: ifP => //.
      by rewrite -has_find => Hhas _ [<-] [Hfind]; rewrite (find_is_label_eq Hhas Hfind).
    rewrite !get_fundef_union eq_refl Hgfd => Honth1 Hplsem1.
    t_xrbindP => b v Hv Hb; rewrite Hv /= Hb /=; case: b Hb => Hb; last by left.
    t_xrbindP => pcf1 Hpcf1 ? ? ? ?; subst mem2 vm2 fn2 pc2.
    rewrite !find_label_tunnel_partial LUF.find_union !LUF.find_empty.
    have:= (Hplsem1 s1 s2); clear Hplsem1.
    rewrite /s1 /= -/s1 Hgfd Honth1 /= Hpcf1 /= Hv /= Hb /= /setcpc /s1 /s2 /= -/s1 -/s2.
    rewrite get_fundef_partial Hgfd eq_refl lfd_body_setfb onth_map Honth1 /= Hv /= Hb /=.
    rewrite !find_label_tunnel_partial !onth_map.
    move => -[//| |[s3]].
    + case: ifP => //; last by left.
      rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      move => /eqP Hfindl; t_xrbindP => pcf1' Hpcf1' ?; subst pcf1'.
      move: Hpcf1 Hpcf1'; rewrite {1 2}/find_label -!has_find; do 2! case : ifP => //.
      move => _ Hhas [Hpcf1] [Hpcf1']; have:= (@find_is_label_eq _ (LUF.find uf l1) _ Hhas).
      rewrite Hpcf1 -{1}Hpcf1' -Hfindl => Heqfind; rewrite Heqfind // in Hpcf1.
      have Hfindislabel:= (@find_is_label _ _ _ l3 (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
      move: (Hpcf1); rewrite Hfindislabel; last by rewrite /is_label //=.
      (*TODO: Can I be more directive with subst?*)
      move => Hpcf1''; move: Hpcf1 Hpcf1'; subst pcf1 => Hpcf1 Hpcf1'.
      rewrite -(prefix_onth Hprefix); last by rewrite !size_rcons.
      rewrite onth_rcons !size_rcons eq_refl {1}/tunnel_bore eq_refl /=.
      rewrite get_fundef_union Hgfd eq_refl LUF.find_union /=.
      rewrite !find_label_tunnel_partial.
      have:= (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP[_ Hall].
      move: Hall; rewrite /goto_targets all_filter all_map => Hall.
      have:= (prefix_all Hprefix Hall); rewrite all_rcons => /andP [Hl4 _]; clear Hall.
      rewrite /= mem_filter /= eq_refl /= in Hl4.
      have:= mapP Hl4 => -[[li_ii5 li_i5]] /= Hin ?.
      clear Hl4; subst li_i5; have Hhas4: has (is_label l4) (lfd_body fd).
      - by apply/hasP; eexists; first exact Hin; rewrite /is_label /= eq_refl.
      have: exists pc4, find_label l4 (lfd_body fd) = ok pc4.
      - by rewrite /find_label -has_find Hhas4; eexists.
      clear li_ii5 Hin Hhas => -[pc4] Hpc4.
      have:= (prefix_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix) Hpc4).
      rewrite /tunnel_plan -/uf => -[pcf4] Hpcf4; rewrite Hpcf4 /=.
      pose s3:= Lstate mem1 vm1 fn pcf4.+1; right; exists s3; split.
      - by case: ifP => _; rewrite Hpcf4 /= /setcpc /s2 /s3 /=.
      - by rewrite /setcpc /s1 /s3.
      by eexists; eauto.
    move => -[]; case: ifP => //; last first.
    + move => Hfindl Hmatch Hs3; right; exists s3; split => //; move: Hmatch.
      case Honthp1: (oseq.onth _ _) => [[li_ii5 li_i5]|] //.
      case: li_i5 Honthp1 => //=.
      - move => [fn5 l5] /=; case: ifP => // Heqfn; rewrite get_fundef_union get_fundef_partial Heqfn //.
        move: Heqfn => /eqP ?; subst fn5; rewrite Hgfd LUF.find_union /= !find_label_tunnel_partial.
        case: ifP => // Hfindl' _; move: Hs3; t_xrbindP => pcff1 Hfindlabel1 ?; subst s3.
        move => ? Hfindlabel1'; rewrite /setcpc /s1 /s2 /= => -[?]; subst; exfalso.
        move: Hfindl => /eqP Hfindl; apply: Hfindl; move: Hfindl' Hfindlabel1 Hfindlabel1' => /eqP <-.
        rewrite /find_label; case: ifP; case: ifP => //; rewrite -has_find => Hhas _ [<-] [Hfind].
        by apply: (find_is_label_eq Hhas Hfind).
      - move => pe5 Honth5; t_xrbindP => w5 v5 Hv5 Hw5; rewrite Hv5 /= Hw5 /=.
        rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
        case: (decode_label _ w5) => //.
        move => [fn5 l5] /=; rewrite get_fundef_union get_fundef_partial.
        case Heqfn: (fn == fn5) => //; move: Heqfn => /eqP ?; subst fn5.
        by rewrite Hgfd /= !find_label_tunnel_partial.
      - by move => lv l; rewrite Hlabel_in_lprog_tunnel Hlabel_in_lprog_tunnel_union.
      move => pe5 l5 Honth5; t_xrbindP => b5 v5 Hv5 Hb5; rewrite Hv5 /= Hb5 /=; case: b5 {Hb5} => //.
      rewrite !find_label_tunnel_partial LUF.find_union; case: ifP => // Hfindl'.
      move: Hs3; t_xrbindP => pcff1 Hfindlabel1 ?; subst s3.
      move => ? Hfindlabel1'; rewrite /setcpc /s1 /s2 /= => -[?]; subst; exfalso.
      move: Hfindl => /eqP Hfindl; apply: Hfindl; move: Hfindl' Hfindlabel1 Hfindlabel1' => /eqP <-.
      rewrite /find_label; case: ifP; case: ifP => //; rewrite -has_find => Hhas _ [<-] [Hfind].
      by apply: (find_is_label_eq Hhas Hfind).
    rewrite (find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
    move => /eqP Hfindl Hmatch; t_xrbindP => pcf1' Hpcf1'.
    move: s3 Hmatch => [mem3 vm3 fn3 pc3]; pose s3:= Lstate mem3 vm3 fn3 pc3; rewrite /= -/s3.
    move => Hmatch; rewrite /setcpc => -[? ? ? ?]; subst mem3 vm3 fn3 pc3; rewrite /s1 /= -/s1.
    move => [li_ii5] [l5] Honth5; right; move: Hpcf1' Hmatch; rewrite -Hfindl => Hpcf1'.
    have:= (prefix_rcons_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)).
    rewrite Hpcf1' => -[?]; subst pcf1'.
    have:= (get_fundef_wf Hgfd); rewrite /well_formed_body => /andP[_ Hall].
    move: Hall; rewrite /goto_targets all_filter all_map => Hall.
    have:= (prefix_all Hprefix Hall); rewrite all_rcons => /andP [Hl4 _]; clear Hall.
    rewrite /= mem_filter /= eq_refl /= in Hl4.
    have:= mapP Hl4 => -[[li_ii6 li_i6]] /= Hin ?.
    clear Hl4; subst li_i6; have Hhas4: has (is_label l4) (lfd_body fd).
    + by apply/hasP; eexists; first exact Hin; rewrite /is_label /= eq_refl.
    have: exists pc4, find_label l4 (lfd_body fd) = ok pc4.
    + by rewrite /find_label -has_find Hhas4; eexists.
    clear li_ii6 Hin Hhas4 => -[pc4] Hpc4.
    have:= (prefix_find_label (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix) Hpc4).
    rewrite /tunnel_plan -/uf => -[pcf4] Hpcf4; rewrite Hpcf4 /= => Hmatch.
    pose s4:= Lstate mem1 vm1 fn pcf4.+1; exists s4; split => //; last by eexists; eauto.
    move: Hmatch; rewrite Honth5 /= eq_refl get_fundef_union get_fundef_partial Hgfd eq_refl.
    rewrite /= LUF.find_union !find_label_tunnel_partial; case: ifP; first by rewrite Hpcf4 /s4.
    move => /negP Hfindl'; t_xrbindP => pcf5 Hpcf5 ?; subst pcf5; exfalso; apply: Hfindl'; apply/eqP.
    rewrite -(find_plan_partial (get_fundef_wf Hgfd) (prefix_trans (prefix_rcons _ _) Hprefix)) -/uf in Hpcf1'.
    move: Hpcf1' Hpcf5; rewrite /find_label; case: ifP; case: ifP => //.
    by rewrite -has_find => Hhas _ [<-] [Hfind]; rewrite (find_is_label_eq Hhas Hfind).
  Qed.

  Lemma lsem1_tunneling s1 s2 : lsem1 p s1 s2 -> exists s3, lsem (lprog_tunnel fn p) s2 s3 /\ lsem1 (lprog_tunnel fn p) s1 s3.
  Proof.
    move => H1p12; case: (lsem11_tunneling H1p12) => [H1tp12|[s3] [H1tp23 H1tp13 _]].
    + by exists s2; split => //; apply: Relation_Operators.rt_refl.
    by exists s3; split => //; apply: Relation_Operators.rt_step.
  Qed.

  Theorem lsem_tunneling s1 s2 : lsem p s1 s2 -> exists s3, lsem p s2 s3 /\ lsem (lprog_tunnel fn p) s1 s3.
  Proof.
    have Ht: (lsem p s1 s2 → ∃ s3 : lstate, lsem (lprog_tunnel fn p) s2 s3 ∧ lsem (lprog_tunnel fn p) s1 s3); last first.
    + by move => Hp12; case: (Ht Hp12) => s3 [Hp23 Htp13]; exists s3; split => //; apply: tunneling_lsem.
    move: s1 s2; apply lsem_ind_r; first by move => s; exists s; split; apply Relation_Operators.rt_refl.
    move => s1 s2 s3 Hp12 H1p23 [s4 [Htp24 Htp14]].
    case: (lsem1_tunneling H1p23) => [s4' [Hp34' H1tp24']].
    case (lsem_disj1 H1tp24' Htp24) => [Heq24|Htp44'].
    + by exists s4'; split => //; apply: (lsem_trans Htp14); rewrite -Heq24; apply: Relation_Operators.rt_step.
    by exists s4; split => //; apply: (lsem_trans Hp34' _).
  Qed.

End TunnelingProof.


Section TunnelingCompilerProof.

  Lemma all_if (T : Type) (a b c : pred T) (s : seq T) :
    all a (filter c s) ->
    all b (filter (negb \o c) s) ->
    all (fun x => if c x then a x else b x) s.
  Proof.
    elim: s => //= hs ts IHs.
    by case: ifP => [Hchs /= /andP [Hahs Hats] Hbts|Hchs /= Hats /andP [Hbhs Hbts]];
    apply/andP; split => //; apply: IHs.
  Qed.

  Lemma all_filtered (T : Type) (a b : pred T) (s : seq T) :
    all a s -> all a (filter b s).
  Proof.
    by elim: s => //= hs ts IHs; case: ifP => /= _ /andP; case => Hahs Hths; first (apply/andP; split => //); apply: IHs.
  Qed.

  Lemma all_eq_filter (T : Type) (a b c : pred T) (s : seq T) :
    (forall x, c x -> a x = b x) ->
    all a (filter c s) ->
    all b (filter c s).
  Proof.
    move => Hcab; elim: s => //= hs ts IHs; case: ifP => //= Hchs /andP [Hahs Hats].
    by apply/andP; split; first rewrite -Hcab; last apply IHs.
  Qed.

  Lemma get_fundef_all (T : Type) (funcs : seq (funname * T)) fn fd a :
    get_fundef funcs fn = Some fd ->
    all (fun f => a f.1 f.2) funcs ->
    a fn fd.
  Proof.
    elim: funcs => //= -[fn' fd'] tfuncs IHfuncs.
    case: ifP; first by move => /eqP ? [?] /= /andP [Ha _]; subst fn' fd'.
    by move => _ /= Hgfd /andP [_ Hall]; apply: IHfuncs.
  Qed.

  Lemma map_filter (T1 T2 : Type) (a : pred T2) (b : T1 -> T2) (s : seq T1) :
    filter a (map b s) = map b (filter (fun x => a (b x)) s).
  Proof.
    by elim: s => //= hs ts ->; case: ifP.
  Qed.

  Lemma labels_of_body_tunnel_partial fn uf lc :
    labels_of_body lc =
    labels_of_body (tunnel_partial fn uf lc).
  Proof.
    rewrite /labels_of_body; elim: lc => //= -[ii []] //=; first by move => ? ? ->.
    by move => [fn' l'] tlc /=; case: ifP => //; case: ifP.
  Qed.

  Lemma all_onthP (T : Type)  (a : pred T) (s : seq T) :
    reflect (forall i x , oseq.onth s i = Some x -> a x) (all a s).
  Proof.
    apply: (iffP idP).
    + move => /all_nthP Hnth i x.
      have:= Hnth x i.
      elim: s i {Hnth} => //= hs ts IHs [/= Ha [<-]|i /= Ha]; first by apply: Ha.
      by apply: IHs => Hisizets; apply: Ha.
    elim: s => //= hs ts IHs Honth.
    apply/andP; split; first by apply: (Honth 0).
    by apply: IHs => i x ?; apply: (Honth (i.+1)).
  Qed.

  Lemma assoc_onth (T : eqType) (U : Type) (s : seq (T * U)) (x : T) (y : U) :
    assoc s x = Some y ->
    exists i, oseq.onth s i = Some (x,y).
  Proof.
    elim: s => //= -[hsx hsy] ts IHs.
    case: ifP => [/eqP ? [?]|_ Hassoc]; first by subst hsx hsy; exists 0.
    by case: (IHs Hassoc) => i Honth; exists i.+1.
  Qed.

  Lemma onth_goto_targets fb i x :
    oseq.onth (goto_targets fb) i = Some x ->
    exists j ii_x r, oseq.onth fb j = Some (MkLI ii_x x) /\ Lgoto r = x.
  Proof.
    elim: fb i => // -[ii_x i_x] tfb IHfb i.
    rewrite /goto_targets /=.
    case: ifP => [|_ Hoseq].
    + case: i_x => // r _; case: i => [/= [?]|i Hoseq]; first by exists 0; exists ii_x; exists r; subst x; split.
      by case: (IHfb i Hoseq) => j Hj; exists j.+1.
    by case: (IHfb i Hoseq) => j Hj; exists j.+1.
  Qed.

  Lemma labels_of_body_tunnel_plan_partial l fn pfb fb :
    well_formed_body fn fb ->
    prefix pfb fb ->
    Llabel l \in labels_of_body fb ->
    Llabel (LUF.find (tunnel_plan fn LUF.empty pfb) l) \in labels_of_body fb.
  Proof.
    rewrite /tunnel_plan => Hwfb.
    elim/last_ind: pfb l => //=.
    move => pfb c IHfb l Hprefix Hlabelin.
    have Hprefix':= (prefix_trans (@prefix_rcons _ pfb c) Hprefix).
    have:= (IHfb _ Hprefix' Hlabelin) => {Hlabelin}.
    rewrite pairfoldl_rcons; move: IHfb.
    set uf:= pairfoldl _ _ _ _ => IHfb.
    case: last => ii []; case: c Hprefix => li_ii [] //=.
    + move => l' Hprefix l''; rewrite LUF.find_union.
      case: ifP => // _ _; apply: IHfb => //.
      apply: (@mem_prefix _ (labels_of_body (rcons pfb {| li_ii := li_ii; li_i := Llabel l' |}))).
      - by apply/prefix_filter/prefix_map.
      by rewrite /labels_of_body map_rcons filter_rcons /= mem_rcons mem_head.
    move => [fn' l'] Hprefix l''.
    case: ifP => // /eqP ?; subst fn'; rewrite LUF.find_union.
    case: ifP => // _ _; apply: IHfb.
    move: Hwfb => /andP [_ Hall].
    have:= (@prefix_all _ (goto_targets (rcons pfb {| li_ii := ii; li_i := Lgoto (fn, l') |})) _ _ _ Hall) => {Hall}.
    rewrite /goto_targets {2}map_rcons filter_rcons /= all_rcons => Hall.
    have:= andP (Hall _) => {Hall} -[] //.
    + apply: prefix_filter.
      move: (prefix_map li_i Hprefix).
      by rewrite !map_rcons.
    move: Hwfb => /andP [_] /allP /(_ (Lgoto (fn, l'))).
    rewrite eq_refl /= => Himp; apply Himp.
    have:= (@mem_prefix _ _ _ Hprefix {| li_ii := li_ii; li_i := Lgoto (fn, l') |} _).
    rewrite -cats1 mem_cat mem_seq1 eq_refl orbT => /(_ isT) => Hin.
    rewrite /goto_targets mem_filter /=.
    by apply/mapP; exists {| li_ii := li_ii; li_i := Lgoto (fn, l') |}.
  Qed.

  Lemma labels_of_body_tunnel_plan l fn fb :
    well_formed_body fn fb ->
    Llabel l \in labels_of_body fb ->
    Llabel (LUF.find (tunnel_plan fn LUF.empty fb) l) \in labels_of_body fb.
  Proof. by move => Hwfb; move: (prefix_refl fb); apply labels_of_body_tunnel_plan_partial. Qed.

  Lemma goto_targets_tunnel_partial fn fb l:
    well_formed_body fn fb ->
    Lgoto (fn, l) \in goto_targets (tunnel_partial fn (tunnel_plan fn LUF.empty fb) fb) ->
    Llabel l \in labels_of_body fb.
  Proof.
    rewrite /tunnel_plan => Hwfb.
    pattern fb, fb at 2 3.
    apply: prefixW => //=.
    + rewrite /tunnel_partial (@eq_map _ _ _ idfun); last first.
      - by move => ?; rewrite tunnel_bore_empty.
      rewrite map_id.
      move: Hwfb; rewrite /well_formed_body => /andP [_ /allP] Hall Hin.
      by move: (Hall _ Hin); rewrite eq_refl.
    move => c pfb Hprefix; rewrite pairfoldl_rcons.
    set uf:= pairfoldl _ _ _ _ => IHfb.
    case Hlast: last => [ii [ | |l'| | | | ]]; case: c Hprefix => ii' [] //=; auto.
    + move => l'' Hprefix; rewrite mem_filter => /andP [_].
      case/mapP => -[ii'' []] // [fn''' l'''] /= Hin'' [? ?]; subst fn''' l'''; move: Hin''.
      case/mapP => -[ii''' []] // [fn''' l'''] /= Hin''' [?]; subst ii'''.
      case: ifP => [/eqP ? [_]|Hneq -[?]]; last first.
      - by subst; move: Hneq; rewrite eq_refl.
      subst fn'''; rewrite LUF.find_union.
      move: IHfb Hprefix Hlast; rewrite /uf; clear uf; case: (lastP pfb) => // {pfb} pfb [iii ll].
      set uf:= pairfoldl _ _ _ _ => IHfb Hprefix; rewrite last_rcons => -[? ?]; subst iii ll.
      rewrite (find_plan_partial Hwfb (prefix_trans (prefix_rcons _ _) Hprefix)).
      case: ifP => [/eqP Heqfind|/negP Hneqfind] ?; subst l; last first.
      - apply/IHfb; rewrite mem_filter /=; apply/mapP.
        exists {| li_ii := ii''; li_i := Lgoto (fn, LUF.find uf l''') |} => //=.
        by apply/mapP; exists {| li_ii := ii''; li_i := Lgoto (fn, l''') |} => //=; rewrite eqxx.
      have Hprefix':= (prefix_rcons (rcons pfb {| li_ii := ii; li_i := Llabel l' |}) {| li_ii := ii'; li_i := Llabel l'' |}).
      have Hprefix'':= (prefix_trans Hprefix' Hprefix).
      move: (@labels_of_body_tunnel_plan_partial l'' _ _ _ Hwfb Hprefix'').
      rewrite /tunnel_plan -/uf => Himp; apply Himp; rewrite mem_filter /=.
      apply/mapP; exists {| li_ii := ii'; li_i := Llabel (l'') |} => //=.
      by apply/(mem_prefix Hprefix); rewrite -cats1 mem_cat mem_seq1 eq_refl orbT.
    move => [fn'' l''] Hprefix; case: ifP; last by auto.
    move => /eqP ?; subst fn''; rewrite mem_filter => /andP [_].
    case/mapP => -[ii'' []] // [fn''' l'''] /= Hin'' [? ?]; subst fn''' l'''; move: Hin''.
    case/mapP => -[ii''' []] // [fn''' l'''] /= Hin''' [?]; subst ii'''.
    case: ifP => [/eqP ? [_]|Hneq -[?]]; last first.
    + by subst; move: Hneq; rewrite eq_refl.
    subst fn'''; rewrite LUF.find_union.
    move: IHfb Hprefix Hlast; rewrite /uf; clear uf; case: (lastP pfb) => // {pfb} pfb [iii ll].
    set uf:= pairfoldl _ _ _ _ => IHfb Hprefix; rewrite last_rcons => -[? ?]; subst iii ll.
    rewrite (find_plan_partial Hwfb (prefix_trans (prefix_rcons _ _) Hprefix)).
    case: ifP => [/eqP Heqfind|/negP Hneqfind] ?; subst l; last first.
    + apply/IHfb; rewrite mem_filter /=; apply/mapP.
      exists {| li_ii := ii''; li_i := Lgoto (fn, LUF.find uf l''') |} => //=.
      by apply/mapP; exists {| li_ii := ii''; li_i := Lgoto (fn, l''') |} => //=; rewrite eqxx.
    apply/IHfb; rewrite mem_filter /=; apply/mapP.
    exists {| li_ii := ii'; li_i := Lgoto (fn, LUF.find uf l'') |} => //=.
    apply/mapP; exists {| li_ii := ii'; li_i := Lgoto (fn, l'') |} => //=; last by rewrite eqxx.
    move: Hprefix => /prefixP [sfb] ->; rewrite mem_cat mem_rcons in_cons.
    by apply/orP; left; apply/orP; left; apply/eqP.
  Qed.

  Lemma onthP {T : eqType} (s : seq T) (x : T) :
    reflect (exists2 i , i < size s & oseq.onth s i = Some x) (x \in s).
  Proof.
    apply: (iffP (nthP x)); case => i Hsize Hnth; exists i => //.
    + by rewrite -Hnth; apply: oseq.onth_nth_size.
    by apply/eqP; rewrite -oseq.onth_sizeP // Hnth.
  Qed.

  Lemma well_formed_lprog_tunnel fn p :
    well_formed_lprog p ->
    well_formed_lprog (lprog_tunnel fn p).
  Proof.
    rewrite /well_formed_lprog /lprog_tunnel; case: p => /= rip rsp globs funcs.
    move => /andP [Huniq Hall]; apply/andP; split.
    + move: Huniq {Hall}; case Hgfd: (get_fundef _ _) => [fd|] //=.
      by rewrite -map_comp (@eq_map _ _ _ fst).
    move: Hall; move => /all_onthP Hwfb; apply/all_onthP => i [fn' fd'] /=.
    case Hgfd: get_fundef => [fd|] /= {rip globs}; last by apply: Hwfb.
    rewrite onth_map; case Honth: oseq.onth => [[fn'' fd'']|] //= [?]; subst fn''.
    case: ifP => [/eqP ? ?|_ ?]; last by subst fd''; apply: (Hwfb _ _ Honth).
    subst fn' fd'; rewrite /lfundef_tunnel_partial /= => {i fd'' Honth}.
    case: (assoc_onth Hgfd) => i Honth; have:= (Hwfb _ _ Honth) => /= {Hwfb Hgfd Honth} Hwf.
    move: (Hwf); move => /andP [Huniql Hall]; move: (Hall) => /all_onthP Hlocalgotos.
    apply/andP; split; rewrite -labels_of_body_tunnel_partial //.
    apply/all_onthP => {i} i x /onth_goto_targets [j] [ii_x] [[fn' l']] [Honth ?]; subst x.
    move: Honth => /oseq.onthP /andP Hnth; have:= (Hnth Linstr_align) => {Hnth} -[Hsize /eqP Hnth].
    have:= (mem_nth Linstr_align Hsize); move: Hnth => -> Hin {Hsize}.
    have:= (map_f li_i Hin) => {Hin} /= Hin.
    have: Lgoto (fn', l') \in goto_targets (tunnel_partial fn (tunnel_plan fn LUF.empty (lfd_body fd)) (lfd_body fd)).
    + by rewrite /goto_targets mem_filter.
    move => {Hin} Hin; move: (Hin); rewrite /goto_targets mem_filter => /andP [_].
    case/mapP => -[ii'' []] // [fn''' l'''] /= Hin'' [? ?]; subst fn''' l'''; move: Hin''.
    case/mapP => -[ii''' []] // [fn''' l'''] /= Hin''' [?]; subst ii'''.
    case: ifP => [/eqP ? [? ?]|Hneq [? ?]].
    + subst fn''' fn'; apply/andP; split; first by apply/eqP.
      by move/(goto_targets_tunnel_partial Hwf): Hin.
    subst fn''' l'''; rewrite Hneq /=;  move: Hall => /allP /(_ (Lgoto (fn', l'))).
    rewrite /goto_targets mem_filter Hneq /= => -> //.
    by apply/mapP; exists {| li_ii := ii''; li_i := Lgoto (fn', l') |}.
  Qed.

  Lemma well_formed_partial_tunnel_program fns p :
    well_formed_lprog p ->
    well_formed_lprog (foldr lprog_tunnel p fns).
  Proof.
    by elim: fns => //= hfns tfns IHfns wfp; apply: well_formed_lprog_tunnel; apply: IHfns.
  Qed.

  Lemma partial_tunnel_program_lsem fns p s1 s2 :
    well_formed_lprog p ->
    lsem (foldr lprog_tunnel p fns) s1 s2 ->
    lsem p s1 s2.
  Proof.
    elim: fns => //= hfns tfns IHfns wfp Hpplsem12; apply: (IHfns wfp).
    apply: (tunneling_lsem (well_formed_partial_tunnel_program _ wfp)).
    by apply: Hpplsem12.
  Qed.

  Lemma tunnel_partial_size fn uf l :
    size l = size (tunnel_partial fn uf l).
  Proof. by rewrite /tunnel_partial size_map. Qed.

  Lemma lprog_tunnel_size fn p tp :
    well_formed_lprog p ->
    lprog_tunnel fn p = tp ->
    size (lp_funcs p) = size (lp_funcs tp) /\
    forall n ,
      omap (fun p => size (lfd_body p.2)) (oseq.onth (lp_funcs p) n) =
      omap (fun p => size (lfd_body p.2)) (oseq.onth (lp_funcs tp) n).
  Proof.
    rewrite /lprog_tunnel /well_formed_lprog => /andP [Huniq _].
    case Hgfd: (get_fundef _ _) => [l|] <- //.
    split => [/=|n /=]; first by rewrite size_map.
    rewrite onth_map.
    case Heqn: (oseq.onth (lp_funcs p) n) => [[fn' l']|] //=.
    f_equal; case: ifP => [/eqP ?|//]; subst fn'.
    rewrite /lfundef_tunnel_partial lfd_body_setfb -tunnel_partial_size.
    case: (assoc_onth Hgfd) => m Heqm.
    rewrite oseq.onth_nth in Heqm.
    case: (le_lt_dec (size (lp_funcs p)) m) => [/leP Hlem|/ltP Hltm].
    + by rewrite nth_default in Heqm => //; rewrite size_map.
    rewrite (@nth_map _ (fn, l) _ None (fun x => Some x) m (lp_funcs p) Hltm) in Heqm.
    rewrite oseq.onth_nth in Heqn.
    case: (le_lt_dec (size (lp_funcs p)) n) => [/leP Hlen|/ltP Hltn].
    + by rewrite nth_default in Heqn => //; rewrite size_map.
    rewrite (@nth_map _ (fn, l) _ None (fun x => Some x) n (lp_funcs p) Hltn) in Heqn.
    move: Heqm Heqn => [Heqm] [Heqn].
    have:= (@nth_map _ (fn, l) _ fn fst m (lp_funcs p) Hltm); rewrite Heqm /= => Heqm1.
    have:= (@nth_map _ (fn, l) _ fn fst n (lp_funcs p) Hltn); rewrite Heqn /= => Heqn1.
    have := (@nth_uniq _ fn _ m n _ _ Huniq); rewrite !size_map Hltm Hltn Heqm1 Heqn1 => Heq.
    have Heq': (m = n) by apply/eqP; rewrite -Heq //.
    by rewrite Heq' Heqn in Heqm; move: Heqm => [->].
  Qed.

  Lemma tunnel_program_size p tp :
    tunnel_program p = ok tp ->
    size (lp_funcs p) = size (lp_funcs tp) /\
    forall n ,
      omap (fun p => size (lfd_body p.2)) (oseq.onth (lp_funcs p) n) =
      omap (fun p => size (lfd_body p.2)) (oseq.onth (lp_funcs tp) n).
  Proof.
    rewrite /tunnel_program; case: ifP => // Hwfp [].
    elim: (funnames p) tp => [tp <- //|] fn fns Hfns tp /= Heq.
    have [<- Ho1]:= (lprog_tunnel_size (well_formed_partial_tunnel_program fns Hwfp) Heq).
    have Hrefl: foldr lprog_tunnel p fns = foldr lprog_tunnel p fns by trivial.
    have [<- Ho2]:= (Hfns (foldr lprog_tunnel p fns) Hrefl).
    by split => // n; rewrite Ho2 Ho1.
  Qed.

  Lemma lprog_tunnel_invariants fn p tp :
    lprog_tunnel fn p = tp ->
    lp_rip   p = lp_rip   tp /\
    lp_rsp   p = lp_rsp   tp /\
    lp_globs p = lp_globs tp /\
    map fst (lp_funcs p) = map fst (lp_funcs tp) /\
    map lfd_info   (map snd (lp_funcs p)) = map lfd_info   (map snd (lp_funcs tp)) /\
    map lfd_align  (map snd (lp_funcs p)) = map lfd_align  (map snd (lp_funcs tp)) /\
    map lfd_tyin   (map snd (lp_funcs p)) = map lfd_tyin   (map snd (lp_funcs tp)) /\
    map lfd_arg    (map snd (lp_funcs p)) = map lfd_arg    (map snd (lp_funcs tp)) /\
    map lfd_tyout  (map snd (lp_funcs p)) = map lfd_tyout  (map snd (lp_funcs tp)) /\
    map lfd_res    (map snd (lp_funcs p)) = map lfd_res    (map snd (lp_funcs tp)) /\
    map lfd_export (map snd (lp_funcs p)) = map lfd_export (map snd (lp_funcs tp)).
  Proof.
    rewrite /lprog_tunnel => <-; case: (get_fundef _ _) => [x|//].
    rewrite /setfuncs /=; split => //; split => //; split => //.
    rewrite -!map_comp.
    split; first by apply: eq_map => -[fn' l'].
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    split; first by apply: eq_map => -[fn' l'] /=; case: ifP.
    by apply: eq_map => -[fn' l'] /=; case: ifP.
  Qed.

  Lemma tunnel_program_invariants p tp :
    tunnel_program p = ok tp ->
    lp_rip   p = lp_rip   tp /\
    lp_rsp   p = lp_rsp   tp /\
    lp_globs p = lp_globs tp /\
    map fst (lp_funcs p) = map fst (lp_funcs tp) /\
    map lfd_info   (map snd (lp_funcs p)) = map lfd_info   (map snd (lp_funcs tp)) /\
    map lfd_align  (map snd (lp_funcs p)) = map lfd_align  (map snd (lp_funcs tp)) /\
    map lfd_tyin   (map snd (lp_funcs p)) = map lfd_tyin   (map snd (lp_funcs tp)) /\
    map lfd_arg    (map snd (lp_funcs p)) = map lfd_arg    (map snd (lp_funcs tp)) /\
    map lfd_tyout  (map snd (lp_funcs p)) = map lfd_tyout  (map snd (lp_funcs tp)) /\
    map lfd_res    (map snd (lp_funcs p)) = map lfd_res    (map snd (lp_funcs tp)) /\
    map lfd_export (map snd (lp_funcs p)) = map lfd_export (map snd (lp_funcs tp)).
  Proof.
    rewrite /tunnel_program; case: ifP => // _ [].
    elim: (funnames p) tp => [tp <-|] //= fn fns Hfns tp.
    pose fp:= (foldr lprog_tunnel p fns); rewrite -/fp.
    move => Heq; have:= (lprog_tunnel_invariants Heq).
    move => [<-] [<-] [<-] [<-] [<-] [<-] [<-] [<-] [<-] [<-] <-.
    by apply Hfns.
  Qed.

  Lemma get_fundef_foldr_lprog_tunnel p fn fns fd :
    uniq fns ->
    get_fundef (lp_funcs p) fn = Some fd →
    get_fundef (lp_funcs (foldr lprog_tunnel p fns)) fn =
    if fn \in fns
    then Some (lfundef_tunnel_partial fn fd fd.(lfd_body) fd.(lfd_body))
    else Some fd.
  Proof.
    elim: fns => //= fn' fns Hfns /andP [Hnotin Huniq] Hgfd.
    move: (Hfns Huniq Hgfd) => {Hfns} {Hgfd} Hfns.
    rewrite get_fundef_lprog_tunnel Hfns {Hfns} in_cons.
    case: ifP; case: ifP => //=.
    + by move => /eqP ?; subst fn' => Hin; rewrite Hin /= in Hnotin.
    + by rewrite eq_sym => -> .
    + by move => /eqP ?; subst fn'; rewrite eq_refl.
    by rewrite eq_sym => ->.
  Qed.

  Lemma get_fundef_tunnel_program p tp fn fd :
    tunnel_program p = ok tp →
    get_fundef (lp_funcs p) fn = Some fd →
    get_fundef (lp_funcs tp) fn = Some (lfundef_tunnel_partial fn fd fd.(lfd_body) fd.(lfd_body)).
  Proof.
    rewrite /tunnel_program; case: ifP => // Hwfp /ok_inj <-{tp} Hgfd.
    rewrite (get_fundef_foldr_lprog_tunnel _ Hgfd).
    + by rewrite ifT //; apply/in_map; exists (fn, fd) => //=; apply get_fundef_in'.
    by move: Hwfp; rewrite /well_formed_lprog /funnames => /andP [].
  Qed.

  Theorem lsem_tunnel_program p tp s1 s2 :
    tunnel_program p = ok tp ->
    lsem p s1 s2 ->
    exists s3, lsem p s2 s3 /\ lsem tp s1 s3.
  Proof.
    rewrite /tunnel_program; case: ifP => // wfp [<-].
    elim: funnames => [|hfns tfns IHfns /=]; first by exists s2; split => //; apply: Relation_Operators.rt_refl.
    move => Hlsem12; case: (IHfns Hlsem12) => s3 [Hlsem23 Hplsem13].
    case: (lsem_tunneling hfns (well_formed_partial_tunnel_program _ wfp) Hplsem13) => s4 [Hplsem34 Hpplsem14].
    exists s4; split => //; apply: (lsem_trans Hlsem23).
    by apply: (partial_tunnel_program_lsem wfp Hplsem34).
  Qed.

  Corollary lsem_run_tunnel_program p tp s1 s2 :
    tunnel_program p = ok tp →
    lsem p s1 s2 →
    lsem_final p s2 →
    lsem tp s1 s2 ∧ lsem_final tp s2.
  Proof.
    move => Htp Hlsem12 Hfinal.
    case: (lsem_tunnel_program Htp Hlsem12) => s3 [Hlsem23 Hlsem13].
    have ?:= (lsem_final_stutter Hlsem23 Hfinal); subst s3.
    split => //; case: Hfinal => fd Hgfd Heq.
    exists (lfundef_tunnel_partial (lfn s2) fd (lfd_body fd) (lfd_body fd)) => //.
    + by rewrite (get_fundef_tunnel_program Htp Hgfd).
    by rewrite /lfundef_tunnel_partial lfd_body_setfb -tunnel_partial_size.
  Qed.

End TunnelingCompilerProof.
