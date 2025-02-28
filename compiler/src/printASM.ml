open Utils
open Prog
open PrintCommon


let pp_asm_comment (fmt : Format.formatter) (annotations : Annotations.annotations) =
  (* TODO : Check that command is singleline or multiline *)
  List.iter(
    fun ((k, a): Annotations.annotation ) ->
      match (L.unloc k) with 
      | "comment" -> (
        match a with
          | Some ({pl_desc=Astring s;_}) -> 
            let comment_symbol = Glob_options.get_arch_comment_delimiter () in
            Format.fprintf fmt "%s %s" comment_symbol s
          | _ -> ()
        )
      | _ -> () 
  ) annotations
  
(** Assembly code lines. *)
type asm_line =
  | LLabel of string
  | LInstr of string * string list * Annotations.annotations
  | LByte of string

let iwidth = 4

let print_asm_line fmt ln =
  match ln with
  | LLabel lbl -> Format.fprintf fmt "%s:" lbl
  | LInstr (s, [],comment) -> Format.fprintf fmt "\t%s %a" s pp_asm_comment comment
  | LInstr (s, args,comment) ->
      Format.fprintf fmt "\t%-*s\t%s %a" iwidth s (String.concat ", " args) pp_asm_comment comment
  | LByte n -> Format.fprintf fmt "\t.byte\t%s" n

let print_asm_lines fmt lns =
  List.iter (Format.fprintf fmt "%a\n%!" print_asm_line) lns

(* -------------------------------------------------------------------- *)
let string_of_label name p =
  Format.asprintf "L%s$%d" (escape name) (Conv.int_of_pos p)

let string_of_glob occurrences x =
  Hash.modify_def (-1) x.v_name Stdlib.Int.succ occurrences;
  let count =  Hash.find occurrences x.v_name in
  (* Adding the number of occurrences to the label to avoid names conflict *)
  let suffix = if count > 0 then Format.asprintf "$%d" count else "" in
  Format.asprintf "G$%s%s" (escape x.v_name) suffix


(* -------------------------------------------------------------------- *)
let format_glob_data globs names =
  (* Creating a Hashtable to count occurrences of a label name*)
  let occurrences = Hash.create 42 in
  let names =
    List.map (fun ((x, _), p) -> (Conv.var_of_cvar x, Conv.z_of_cz p)) names
  in
  List.flatten
    (List.mapi
       (fun i b ->
         let b = LByte (Z.to_string (Conv.z_of_int8 b)) in
         match List.find (fun (_, p) -> Z.equal (Z.of_int i) p) names with
         | exception Not_found -> [ b ]
         | x, _ -> [ LLabel (string_of_glob occurrences x); b ])
       globs)
