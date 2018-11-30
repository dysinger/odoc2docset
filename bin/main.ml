open Base
open Printf
open Bos
open Cmdliner
open Rresult
open Stdio
module Odoc = Odoc__odoc
module Model = Odoc__model
module Html = Odoc__html
module Xref = Odoc__xref

module Sqlite3 = struct
  module Rc = struct
    include Sqlite3.Rc

    let ok_exn =
      let open Sqlite3.Rc in
      function
      | OK -> ()
      | e ->
          Logs.err (fun m -> m "Sqlite error: %s" (to_string e)) ;
          Caml.exit 1

    let done_exn =
      let open Sqlite3.Rc in
      function
      | DONE -> ()
      | e ->
          Logs.err (fun m -> m "Sqlite error: %s" (to_string e)) ;
          Caml.exit 1
  end

  include (Sqlite3 : module type of Sqlite3 with module Rc := Rc)
end

let insert db name typ path =
  let query =
    sprintf
      "INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES ('%s', \
       '%s', '%s');"
      name typ path
  in
  ignore (Sqlite3.exec db query)

let ok_exn : ('a, [`Msg of string]) Caml.Pervasives.result -> 'a = function
  | Ok x -> x
  | Error (`Msg e) ->
      Logs.err (fun m -> m "%s" e) ;
      Caml.exit 1

let tar =
  (* Prefer GNU tar to BSD tar. *)
  let tar_cmds = Cmd.[v "gtar"; v "tar"] in
  List.find_exn tar_cmds ~f:(fun c -> OS.Cmd.exists c |> ok_exn)

let plist pkg_name =
  sprintf
    {|<?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
	    <key>CFBundleIdentifier</key>
	    <string>%s</string>
	    <key>CFBundleName</key>
	    <string>%s</string>
	    <key>DocSetPlatformFamily</key>
	    <string>%s</string>
	    <key>isDashDocset</key>
	    <true/>
      <key>dashIndexFilePath</key>
      <string>index.html</string>
      <key>DashDocSetFamily</key>
      <string>dashtoc</string>
      </dict>
      </plist>
    |}
    pkg_name pkg_name pkg_name

let rec id_to_string =
  let module Id = Model.Paths.Identifier in
  function
  | Id.Root (_, x) | Id.Page (_, x) | Id.CoreType x | Id.CoreException x -> x
  | Id.Module (p, x)
   |Id.ModuleType (p, x)
   |Id.Type (p, x)
   |Id.Extension (p, x)
   |Id.Exception (p, x)
   |Id.Value (p, x)
   |Id.Class (p, x)
   |Id.ClassType (p, x) ->
      id_to_string (Id.any p) ^ "." ^ x
  | Id.Method (p, x) | Id.InstanceVariable (p, x) ->
      id_to_string (Id.any p) ^ "#" ^ x
  | Id.Constructor (p, x) -> (
    match p with
    | Id.Type (p, _) -> id_to_string (Id.any p) ^ "." ^ x
    | Id.CoreType _ -> x )
  | Id.Field (p, x) -> (
    match p with
    | Id.Root (_, y) | Id.Module (_, y) | Id.ModuleType (_, y) -> y ^ "." ^ x
    | Id.Argument (_, _, _) -> id_to_string (Id.any p) ^ "." ^ x
    | Id.Type (p, _) -> id_to_string (Id.any p) ^ "." ^ x
    | Id.CoreType _ -> x
    | Id.Class (_, y) | Id.ClassType (_, y) -> y ^ "#" ^ x )
  | Id.Label _ | Id.Argument _ -> failwith "No printable path."

let path_to_string (p : Model.Paths.Path.module_) =
  let module Path = Model.Paths.Path in
  match p with
  | Path.Resolved p ->
      Path.Resolved.identifier p |> Model.Paths.Identifier.any |> id_to_string
  | _ -> "<unknown>"

(** Collect the identifiers (labeled with Dash types) in a compilation unit. *)
let ids_of_unit unit =
  let open Model.Lang in
  let output = ref [] in
  let index id type_ =
    let id = Model.Paths.Identifier.any id in
    Logs.debug (fun m -> m "Inserting %s : %s." (id_to_string id) type_) ;
    output := (id, type_) :: !output
  in
  let nop _ = () in
  let rec process_module_decl =
    let open ModuleType in
    let rec process_module_type_expr = function
      | Signature s -> process_signature s
      | Functor (_, x) -> process_module_type_expr x
      | _ -> ()
    in
    let open Module in
    function Alias _ -> () | ModuleType e -> process_module_type_expr e
  and process_module
      Module.({id; type_; expansion; hidden; display_type; canonical; _}) =
    let open Module in
    Logs.debug (fun m ->
        let canon_str =
          Option.map canonical ~f:(fun (path, _) -> path_to_string path)
          |> Option.value ~default:"none"
        in
        m "Module %s hidden=%b canonical=%s"
          (id_to_string (Model.Paths.Identifier.any id))
          hidden canon_str ) ;
    if not hidden then (
      index id "Module" ;
      let module_type = Option.value ~default:type_ display_type in
      process_module_decl module_type ;
      match expansion with
      | Some (Signature s) | Some (Functor (_, s)) -> process_signature s
      | None | Some AlreadyASig ->
          Logs.debug (fun m ->
              m "Module %s no expansion."
                (id_to_string (Model.Paths.Identifier.any id)) ) )
  and process_module_type ModuleType.({id; _}) = index id "Interface"
  and process_type_ext = nop
  and process_type TypeDecl.({id; representation; _}) =
    index id "Type" ;
    match representation with
    | Some (Variant constrs) -> List.iter constrs ~f:process_constructor
    | Some (Record fields) -> List.iter fields ~f:process_field
    | _ -> ()
  and process_constructor TypeDecl.Constructor.({id; args; _}) =
    index id "Constructor" ;
    match args with
    | Record fields -> List.iter fields ~f:process_field
    | _ -> ()
  and process_field TypeDecl.Field.({id; _}) = index id "Field"
  and process_exception Exception.({id; _}) = index id "Exception"
  and process_val id type_ =
    let open TypeExpr in
    let kind =
      match type_ with
      | Arrow _ -> "Function"
      | Object _ -> "Object"
      | _ -> "Value"
    in
    index id kind
  and process_value Value.({id; type_; _}) = process_val id type_
  and process_external External.({id; type_; _}) = process_val id type_
  and process_method Method.({id; private_; _}) =
    if not private_ then index id "Method"
  and process_instance_variable InstanceVariable.({id; _}) =
    index id "Variable"
  and process_class_signature ClassSignature.({items; _}) =
    let open ClassSignature in
    List.iter
      ~f:(function
        | Method x -> process_method x
        | InstanceVariable x -> process_instance_variable x
        | _ -> ())
      items
  and process_class Class.({id; type_; _}) =
    let open Class in
    let rec process_decl = function
      | ClassType (Signature x) -> process_class_signature x
      | ClassType (Constr _) -> ()
      | Arrow (_, _, d) -> process_decl d
    in
    process_decl type_ ; index id "Class"
  and process_class_type = nop
  and process_include Include.({expansion= {content; _}; _}) =
    process_signature content
  and process_signature_item =
    let open Signature in
    function
    | Module (_, x) -> process_module x
    | ModuleType x -> process_module_type x
    | Type (_, x) -> process_type x
    | TypExt x -> process_type_ext x
    | Exception x -> process_exception x
    | Value x -> process_value x
    | External x -> process_external x
    | Class (_, x) -> process_class x
    | ClassType (_, x) -> process_class_type x
    | Include x -> process_include x
    | Comment _ -> ()
  and process_signature sig_ = List.iter ~f:process_signature_item sig_
  and process_unit Compilation_unit.({id; content; hidden; _}) =
    let process_packed items =
      List.iter
        ~f:(fun Compilation_unit.Packed.({id; _}) -> index id "Module")
        items
    in
    Logs.debug (fun m ->
        m "Unit %s hidden=%b"
          (id_to_string (Model.Paths.Identifier.any id))
          hidden ) ;
    if not hidden then
      match content with
      | Module x -> index id "Module" ; process_signature x
      | Pack x -> process_packed x
  in
  process_unit unit ; !output

let url_to_string Html.Url.({page; anchor; _}) =
  List.rev ("index.html" :: page)
  |> String.concat ~sep:"/"
  |> fun path -> if String.(anchor = "") then path else path ^ "#" ^ anchor

let update_index db docu_dir (ids : (Model.Paths.Identifier.any * _) list) =
  let open Sqlite3 in
  let stmt =
    prepare db
      "INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?,?,?);"
  in
  exec db "BEGIN TRANSACTION;" |> Rc.ok_exn ;
  let soups = Hashtbl.Poly.create () in
  List.iter ids ~f:(fun (id, type_) ->
      let open Html in
      let url = Url.from_identifier ~stop_before:false id in
      let url =
        match url with
        | Ok x -> x
        | Error e -> failwith (Url.Error.to_string e)
      in
      let file =
        let html_path =
          List.rev ("index.html" :: url.page)
          |> String.concat ~sep:"/" |> Fpath.of_string |> ok_exn
        in
        Fpath.(docu_dir // html_path)
      in
      if OS.File.exists file |> ok_exn then (
        let url =
          if String.(url.anchor = "") then url
          else
            let soup =
              Hashtbl.find_or_add soups file ~default:(fun () ->
                  OS.File.read file |> ok_exn |> Soup.parse )
            in
            let name_ = Model.Paths.Identifier.name id in
            let new_anchor = sprintf "//apple_ref/cpp/%s/%s" type_ name_ in
            let anchor_elem =
              Soup.create_element ~attributes:[("name", new_anchor)]
                ~class_:"dashAnchor" "a"
            in
            match
              Soup.select_one (sprintf {|a[href="#%s"]|} url.anchor) soup
            with
            | Some node ->
                Soup.prepend_child node anchor_elem ;
                {url with anchor= new_anchor}
            | None ->
                Logs.warn (fun m ->
                    m "Could not find anchor node for %s in %s." url.anchor
                      (Fpath.to_string file) ) ;
                url
        in
        let open Data in
        bind stmt 1 (TEXT (id_to_string id)) |> Rc.ok_exn ;
        bind stmt 2 (TEXT type_) |> Rc.ok_exn ;
        bind stmt 3 (TEXT (url_to_string url)) |> Rc.ok_exn ;
        step stmt |> Rc.done_exn ;
        reset stmt |> Rc.ok_exn )
      else () ) ;
  exec db "END TRANSACTION;" |> Rc.ok_exn ;
  Hashtbl.iteri soups ~f:(fun ~key:file ~data:soup ->
      OS.File.write file (Soup.to_string soup) |> ok_exn )

let create_template output_path =
  let docset_dir = Fpath.of_string output_path |> ok_exn in
  let docset_name = Fpath.(rem_ext docset_dir |> basename) in
  let res_dir = Fpath.(docset_dir / "Contents" / "Resources") in
  let docu_dir = Fpath.(res_dir / "Documents") in
  let db_file = Fpath.(res_dir / "docSet.dsidx") in
  OS.Cmd.run Cmd.(v "rm" % "-rf" % p docset_dir) |> ok_exn ;
  OS.Dir.create docu_dir |> ok_exn |> ignore ;
  OS.File.write
    Fpath.(docset_dir / "Contents" / "Info.plist")
    (plist docset_name)
  |> ok_exn ;
  let etc_dir = Fpath.of_string Opam_config.etc |> ok_exn in
  OS.Cmd.(
    Cmd.(
      v "cp"
      % Fpath.(etc_dir / "icon.png" |> to_string)
      % Fpath.(docset_dir / "icon.png" |> to_string))
    |> run_status ~quiet:true)
  |> ok_exn |> ignore ;
  OS.Path.delete db_file |> ok_exn ;
  (docset_dir, docu_dir, db_file)

let create_db db_file =
  let db = Sqlite3.db_open (Fpath.to_string db_file) in
  Sqlite3.exec db
    "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, \
     path TEXT);"
  |> Sqlite3.Rc.ok_exn ;
  Sqlite3.exec db
    "CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path);"
  |> Sqlite3.Rc.ok_exn ;
  db

let depends conf pkg =
  Odig.Pkg.deps pkg |> ok_exn |> Astring.String.Set.elements
  |> List.filter_map ~f:(fun n ->
         match Odig.Pkg.lookup conf (Odig.Pkg.name_of_string n |> ok_exn) with
         | Ok p -> Some p
         | Error (`Msg e) ->
             Logs.warn (fun m -> m "Looking up package %s failed: %s" n e) ;
             None )

(** Load a compilation unit, resolve and expand it. Taken straight from
   odoc/src/html_page.ml. *)
let load_unit env path =
  let open Odoc in
  try
    let unit =
      Compilation_unit.load (Fs.File.of_string (Fpath.to_string path))
      |> Xref.Lookup.lookup
    in
    (* See comment in compile for explanation regarding the env duplication. *)
    let resolve_env = Env.build env (`Unit unit) in
    let resolved = Xref.resolve (Env.resolver resolve_env) unit in
    let expand_env = Env.build env (`Unit resolved) in
    Xref.expand (Env.expander expand_env) resolved
    |> Xref.Lookup.lookup
    |> Xref.resolve (Env.resolver expand_env)
    |> Or_error.return
  with Caml.Not_found ->
    Error
      (Error.create "Failed to resolve." (Fpath.to_string path)
         String.sexp_of_t)

let rec odoc_files_exn d =
  OS.Dir.contents d |> ok_exn
  |> List.concat_map ~f:(fun f ->
         if OS.Dir.exists f |> ok_exn then odoc_files_exn f
         else if Fpath.has_ext "odoc" f then [f]
         else [] )

let rec all_subdirs d =
  if OS.Dir.exists d |> ok_exn then
    d :: (OS.Dir.contents d |> ok_exn |> List.concat_map ~f:all_subdirs)
  else []

let populate_db include_dirs pkgs db docu_dir =
  List.iter include_dirs ~f:(fun d ->
      Logs.debug (fun m -> m "Include dir: %s" (Odoc.Fs.Directory.to_string d))
  ) ;
  let builder =
    Odoc.Env.create ~important_digests:true ~directories:include_dirs
  in
  List.iter pkgs ~f:(fun pkg ->
      let name = Odig.Pkg.name pkg in
      Logs.info (fun m -> m "Indexing %s." name) ;
      insert db name "Package" (sprintf "%s/index.html" name) ;
      let cachedir = Odig.Pkg.cachedir pkg in
      odoc_files_exn cachedir
      |> List.iter ~f:(fun f ->
             Logs.debug (fun m -> m "Loading %s." (Fpath.to_string f)) ;
             match load_unit builder f with
             | Ok unit ->
                 let ids = ids_of_unit unit in
                 update_index db docu_dir ids
             | Error err -> Logs.err (fun m -> m "%s" (Error.to_string_hum err))
         ) )

let tarix_to_sqlite tarix_fn sqlite_fn =
  (* Create new sqlite db. *)
  let db = Sqlite3.db_open (Fpath.to_string sqlite_fn) in
  Sqlite3.exec db
    "CREATE TABLE tarindex(path TEXT PRIMARY KEY COLLATE NOCASE, hash TEXT);\n\
     CREATE TABLE toextract(path TEXT PRIMARY KEY COLLATE NOCASE, hash TEXT);\n"
  |> Sqlite3.Rc.ok_exn ;
  let insert_stmt =
    Sqlite3.prepare db
      "INSERT OR IGNORE INTO tarindex(path, hash) VALUES (?,?);"
  in
  Sqlite3.(exec db "BEGIN TRANSACTION;" |> Rc.ok_exn) ;
  In_channel.with_file (Fpath.to_string tarix_fn) ~f:(fun ch ->
      In_channel.fold_lines ch ~init:0 ~f:(fun lnum line ->
          ( if lnum > 0 then
            match String.split line ~on:' ' with
            | [kind; off1; off2; len; fn] ->
                if String.(kind = "0") then (
                  Sqlite3.(
                    bind insert_stmt 1 (TEXT fn) |> Rc.ok_exn ;
                    bind insert_stmt 2
                      (TEXT (String.concat ~sep:" " [off1; off2; len]))
                    |> Rc.ok_exn ;
                    step insert_stmt |> Rc.done_exn ;
                    reset insert_stmt |> Rc.ok_exn) )
            | _ ->
                Logs.warn (fun m -> m "Unexpected line in tarix file: %s" line)
          ) ;
          lnum + 1 )
      |> ignore ) ;
  Sqlite3.(exec db "END TRANSACTION;" |> Rc.ok_exn)

let compress_docset docset_dir =
  let temp_tgz = Caml.Filename.temp_file "tarix" ".tgz" in
  let temp_idx = Caml.Filename.temp_file "tarixIndex" ".dbtxt" in
  let temp_db = Caml.Filename.temp_file "docSet" ".dsidx" in
  let db_file =
    Fpath.(docset_dir / "Contents" / "Resources" / "docSet.dsidx")
  in
  (* Copy out the docset index. *)
  OS.Cmd.run Cmd.(v "cp" % p db_file % temp_db) |> ok_exn ;
  (* Use tarix to compress the entire docset. *)
  OS.Env.set_var "TARIX" (Some (sprintf "-z -9 -f %s" temp_idx)) |> ok_exn ;
  (* Convert the tarix index to a sqlite index. *)
  let docset_base, docset_rel = Fpath.split_base docset_dir in
  OS.Cmd.run
    Cmd.(
      tar % "-c" % "-f" % temp_tgz % "--use-compress-program" % "tarix" % "-C"
      % p docset_base % p docset_rel)
  |> ok_exn ;
  (* Create a new docset template. *)
  OS.Cmd.run Cmd.(v "rm" % "-rf" % p docset_dir) |> ok_exn ;
  let _ = create_template (Fpath.to_string docset_dir) in
  (* Generate a sqlite based tar index. *)
  tarix_to_sqlite
    (Fpath.of_string temp_idx |> ok_exn)
    Fpath.(docset_dir / "Contents" / "Resources" / "tarixIndex.db") ;
  (* Copy the docset index and compressed docset back in. *)
  OS.Cmd.run
    Cmd.(
      v "rm" % "-rf"
      % p Fpath.(docset_dir / "Contents" / "Resources" / "Documents"))
  |> ok_exn ;
  OS.Cmd.run
    Cmd.(
      v "cp" % temp_tgz
      % p Fpath.(docset_dir / "Contents" / "Resources" / "tarix.tgz"))
  |> ok_exn ;
  OS.Cmd.run
    Cmd.(
      v "cp" % temp_db
      % p Fpath.(docset_dir / "Contents" / "Resources" / "docSet.dsidx"))
  |> ok_exn

let main () compress output_path pkg_names =
  (* Get Odig configuration. *)
  let conf = Odig.Conf.of_opam_switch () |> ok_exn in
  let all_pkgs = Odig.Pkg.set conf |> ok_exn |> Odig.Pkg.Set.to_list in
  (* Look up all the selected packages. *)
  let pkgs =
    match pkg_names with
    | [] -> all_pkgs
    | names ->
        List.filter_map names ~f:(fun n ->
            match Odig.Pkg.find conf n with
            | Some pkg -> Some pkg
            | None ->
                Logs.err (fun m -> m "Could not find package %s." n) ;
                None )
  in
  let include_dirs =
    List.concat_map all_pkgs ~f:(fun pkg -> all_subdirs (Odig.Pkg.cachedir pkg))
    |> List.map ~f:(fun d -> Odoc.Fs.Directory.of_string (Fpath.to_string d))
  in
  (* Create the docset template. *)
  let docset_dir, docu_dir, db_file = create_template output_path in
  (* Generate documentation using Odoc. *)
  Logs.info (fun m -> m "Running odoc.") ;
  let names = List.map pkgs ~f:Odig.Pkg.name in
  OS.Cmd.(Cmd.(v "odig" % "odoc" %% of_list names) |> run_status ~quiet:true)
  |> ok_exn |> ignore ;
  Logs.info (fun m -> m "Done running odoc.") ;
  (* Copy documentation. *)
  Logs.info (fun m -> m "Copying documentation.") ;
  List.iter pkgs ~f:(fun pkg ->
      Logs.debug (fun m -> m "Copying %s." (Odig.Pkg.name pkg)) ;
      let doc_dir = Odig.Odoc.htmldir conf (Some pkg) in
      let cmd = Cmd.(v "cp" % "-r" % p doc_dir % p docu_dir) in
      OS.Cmd.run_status ~quiet:true cmd |> ok_exn |> ignore ) ;
  (* Copy theme CSS & JS. *)
  let theme_dir = "~/.opam/default/share/odoc/odoc-theme/default/" in
  let cmd =
    Cmd.(
      v "cp"
      % (theme_dir ^ "highlight.pack.js")
      % (theme_dir ^ "odoc.css") % p docu_dir)
  in
  OS.Cmd.run_status ~quiet:true cmd |> ok_exn |> ignore ;
  Logs.info (fun m -> m "Done copying documentation.") ;
  Logs.info (fun m -> m "Creating index.") ;
  let db = create_db db_file in
  populate_db include_dirs pkgs db docu_dir ;
  Logs.info (fun m -> m "Done creating index.") ;
  if compress then (
    Logs.info (fun m -> m "Compressing docset.") ;
    compress_docset docset_dir ;
    Logs.info (fun m -> m "Done compressing docset.") )

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer () ;
  Logs.set_level level ;
  Logs.set_reporter (Logs_fmt.reporter ()) ;
  ()

let cmd =
  let setup_log =
    Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())
  in
  let compressed =
    let doc = "Generate a compressed docset." in
    Arg.(value & flag & info ["c"; "compress"] ~doc)
  in
  let docset_dir =
    let doc =
      "Destination of the docset. If the docset already exists, it will be \
       overwritten."
    in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"DOCSET" ~doc)
  in
  let pkgs =
    let doc =
      "Packages to include in the docset. If no packages are specified, then \
       all the installed packages will be used."
    in
    Arg.(value & pos_right 0 string [] & info [] ~docv:"PKG" ~doc)
  in
  ( Term.(const main $ setup_log $ compressed $ docset_dir $ pkgs)
  , Term.info "odoc2docset" )

let () = Term.(exit @@ eval cmd)

(* let () =
 *   Logs.set_reporter (Logs.format_reporter ()) ;
 *   Logs.set_level (Some Logs.Debug) ;
 *   if Array.length Sys.argv < 2 then
 *     Stdio.print_endline "Usage: odoc2docset DOCSET PKG..."
 *   else
 *     let docset_dir = Sys.argv.(1) in
 *     let pkgs =
 *       Array.sub Sys.argv ~pos:2 ~len:(Array.length Sys.argv - 2)
 *       |> Array.to_list
 *     in
 *     main docset_dir pkgs *)
