open Jasmin
open Cmdliner
open CommonCLI

let parse_and_print arch call_conv =
  let module A = (val get_arch_module arch call_conv) in
  fun output file mjazz warn ->
    if not warn then Utils.nowarning ();
    if mjazz then Glob_options.modular_jazz := true;
    let ast =
      if mjazz
      then BatFile.with_file_in file (Parseio.parse_program ~name:file)
      else
        let env = List.fold_left Pretyping.Env.add_from Pretyping.Env.empty
                                 !Glob_options.idirs
        in let _env, _pprog, ast = Pretyping.tt_program A.arch_info env file
        in ast
    in let out, close =
      match output with
      | None -> (stdout, ignore)
      | Some latexfile -> (open_out latexfile, close_out)
    in
    let fmt = Format.formatter_of_out_channel out in
    Format.fprintf fmt "%a@." Latex_printer.pp_prog ast;
    close out

let file =
  let doc = "The Jasmin source file to pretty-print" in
  Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"JAZZ" ~doc)

let output =
  let doc =
    "The file in which the result is written (instead of the standard output)"
  in
  Arg.(value & opt (some string) None & info [ "o"; "output" ] ~docv:"TEX" ~doc)

let mjazz =
  let doc = "Parse modular features ('-mjazz' flag in 'jasminc')" in
  Arg.(value & flag & info ["m"; "M"; "modular"] ~doc)

let () =
  let doc = "Pretty-print Jasmin source programs into LATEX" in
  let man =
    [
      `S Manpage.s_environment;
      Manpage.s_environment_intro;
      `I ("OCAMLRUNPARAM", "This is an OCaml program");
      `I ("JASMINPATH", "To resolve $(i,require) directives");
    ]
  in
  let info =
    Cmd.info "jasmin2tex" ~version:Glob_options.version_string ~doc ~man
  in
  Cmd.v info Term.(const parse_and_print $ arch $ call_conv $ output $ file $ mjazz $ warn)
  |> Cmd.eval |> exit
