open Import
open Memo.O

module Kind = struct
  type t =
    | Default
    | Opam of Opam_switch.t
    | Lock of { default : bool }

  let to_dyn : t -> Dyn.t = function
    | Default -> Dyn.string "default"
    | Lock { default } ->
      Dyn.variant "lock" [ Dyn.record [ "default", Dyn.bool default ] ]
    | Opam o -> Opam_switch.to_dyn o
  ;;

  let initial_ocamlpath = lazy (Findlib_config.ocamlpath_of_env Env.initial)

  let ocamlpath t ~env ~findlib_toolchain =
    let env_ocamlpath = Findlib_config.ocamlpath_of_env env in
    match t, findlib_toolchain with
    | Default, None -> Option.value ~default:[] env_ocamlpath
    | _, _ ->
      let initial_ocamlpath = Lazy.force initial_ocamlpath in
      (* If we are not in the default context, we can only use the OCAMLPATH
         variable if it is specific to this build context *)
      (* CR-someday diml: maybe we should actually clear OCAMLPATH in other
         build contexts *)
      (match env_ocamlpath, initial_ocamlpath with
       | None, None -> []
       | Some s, None ->
         (* [OCAMLPATH] set for the target context, unset in the
            [initial_env]. This means it's the [OCAMLPATH] specific to this
            build context. *)
         s
       | None, Some _ ->
         (* Clear [OCAMLPATH] for this build context if it's defined
            initially but not for this build context. *)
         []
       | Some env_ocamlpath, Some initial_ocamlpath ->
         (* Clear [OCAMLPATH] for this build context Unless it's different
            from the initial [OCAMLPATH] variable. *)
         (match List.compare ~compare:Path.compare env_ocamlpath initial_ocamlpath with
          | Eq -> []
          | _ -> env_ocamlpath))
  ;;
end

module Env_nodes = struct
  type t =
    { context : Dune_env.Stanza.t option
    ; workspace : Dune_env.Stanza.t option
    }

  let empty = { context = None; workspace = None }

  let extra_env { context; workspace } profile =
    let make env =
      Option.value
        ~default:Env.empty
        (let open Option.O in
         let+ (env : Dune_env.Stanza.config) =
           env >>= Dune_env.Stanza.find_opt ~profile
         in
         env.env_vars)
    in
    Env.extend_env (make context) (make workspace)
  ;;
end

type builder =
  { profile : Profile.t
  ; merlin : bool
  ; instrument_with : Lib_name.t list
  ; fdo_target_exe : Path.t option
  ; dynamically_linked_foreign_archives : bool
  ; env_nodes : Env_nodes.t
  ; name : Context_name.t
  ; env : Env.t
  ; implicit : bool
  ; findlib_toolchain : Context_name.t option
  ; for_host : t option
  ; path : Path.t list
  }

and t =
  { kind : Kind.t
  ; build_dir : Path.Build.t
  ; ocaml : Ocaml_toolchain.t
  ; findlib_paths : Path.t list
  ; default_ocamlpath : Path.t list
  ; build_context : Build_context.t
  ; builder : builder
  ; which : Filename.t -> Path.t option Memo.t
  }

module Builder = struct
  type t = builder

  let empty =
    { profile = Profile.Dev
    ; merlin = false
    ; instrument_with = []
    ; fdo_target_exe = None
    ; dynamically_linked_foreign_archives = false
    ; env_nodes = Env_nodes.empty
    ; name = Context_name.default
    ; env = Env.empty
    ; implicit = false
    ; findlib_toolchain = None
    ; for_host = None
    ; path = []
    }
  ;;

  let extend_paths t ~env =
    let t =
      let f (var, t) =
        let parse ~loc:_ s = s in
        let standard = Env_path.path env |> List.map ~f:Path.to_string in
        var, Ordered_set_lang.eval t ~parse ~standard ~eq:String.equal
      in
      List.map ~f t
    in
    let vars =
      let to_absolute_filename s = Path.of_string s |> Path.to_absolute_filename in
      let sep = String.make 1 Bin.path_sep in
      let env = Env.Map.of_list_exn t in
      let f l = String.concat ~sep (List.map ~f:to_absolute_filename l) in
      Env.Map.map ~f env
    in
    Env.extend ~vars env
  ;;

  let set_workspace_base
    t
    { Workspace.Context.Common.targets = _
    ; name
    ; host_context = _
    ; profile
    ; env = _
    ; toolchain
    ; paths
    ; loc = _
    ; fdo_target_exe
    ; dynamically_linked_foreign_archives
    ; instrument_with
    ; merlin
    }
    =
    let env =
      let env = Global.env () in
      extend_paths ~env paths
    in
    { t with
      merlin
    ; profile
    ; dynamically_linked_foreign_archives
    ; instrument_with
    ; fdo_target_exe
    ; name
    ; env
    ; findlib_toolchain = toolchain
    }
  ;;
end

let ocaml t = t.ocaml
let build_dir t = t.build_dir
let kind t = t.kind
let findlib_paths t = t.findlib_paths
let for_host t = t.builder.for_host
let default_ocamlpath t = t.default_ocamlpath
let implicit t = t.builder.implicit
let findlib_toolchain t = t.builder.findlib_toolchain
let env_nodes t = t.builder.env_nodes
let dynamically_linked_foreign_archives t = t.builder.dynamically_linked_foreign_archives
let fdo_target_exe t = t.builder.fdo_target_exe
let instrument_with t = t.builder.instrument_with
let merlin t = t.builder.merlin
let profile t = t.builder.profile
let equal x y = Context_name.equal x.builder.name y.builder.name
let hash t = Context_name.hash t.builder.name
let build_context t = t.build_context
let which t fname = t.which fname
let host t = Option.value ~default:t t.builder.for_host
let name t = t.builder.name
let path t = t.builder.path
let installed_env t = t.builder.env
let to_dyn_concise t : Dyn.t = Context_name.to_dyn t.builder.name
let compare a b = Context_name.compare a.builder.name b.builder.name

let to_dyn t : Dyn.t =
  let open Dyn in
  let path = Path.to_dyn in
  record
    [ "name", Context_name.to_dyn t.builder.name
    ; "kind", Kind.to_dyn t.kind
    ; "profile", Profile.to_dyn t.builder.profile
    ; "merlin", Bool t.builder.merlin
    ; ( "for_host"
      , option
          Context_name.to_dyn
          (Option.map t.builder.for_host ~f:(fun t -> t.builder.name)) )
    ; "fdo_target_exe", option path t.builder.fdo_target_exe
    ; "build_dir", Path.Build.to_dyn t.build_dir
    ; "ocaml_bin", path t.ocaml.bin_dir
    ; "ocaml", Action.Prog.to_dyn t.ocaml.ocaml
    ; "ocamlc", path t.ocaml.ocamlc
    ; "ocamlopt", Action.Prog.to_dyn t.ocaml.ocamlopt
    ; "ocamldep", Action.Prog.to_dyn t.ocaml.ocamldep
    ; "ocamlmklib", Action.Prog.to_dyn t.ocaml.ocamlmklib
    ; "installed_env", Env.to_dyn (Env.diff t.builder.env Env.initial)
    ; "findlib_paths", list path t.findlib_paths
    ; "ocaml_config", Ocaml_config.to_dyn t.ocaml.ocaml_config
    ; "instrument_with", (list Lib_name.to_dyn) t.builder.instrument_with
    ]
;;

(* Wrap calls to the opam binary *)
module Opam : sig
  (* Environment for this opam switch *)
  val env : env:Env.t -> Opam_switch.t -> string Env.Map.t Memo.t
end = struct
  let opam =
    Memo.Lazy.create ~name:"context-opam" (fun () ->
      Which.which ~path:(Env_path.path Env.initial) "opam"
      >>= function
      | None -> Utils.program_not_found "opam" ~loc:None
      | Some opam ->
        let+ version =
          Memo.of_reproducible_fiber
            (Process.run_capture_line
               ~display:Quiet
               Strict
               opam
               [ "--version"; "--color=never" ])
        in
        (match Scanf.sscanf version "%d.%d.%d" (fun a b c -> a, b, c) with
         | Ok ((a, b, c) as v) ->
           if v < (2, 0, 0)
           then
             User_error.raise
               [ Pp.textf
                   "The version of opam installed on your system is too old. Dune \
                    requires at least version 2.0.0, however version %d.%d.%d is \
                    installed."
                   a
                   b
                   c
               ];
           opam
         | Error () ->
           User_error.raise
             [ Pp.textf
                 "`%s config --version' returned invalid output:"
                 (Path.to_string_maybe_quoted opam)
             ; Pp.verbatim version
             ]))
  ;;

  let opam_binary_exn () = Memo.Lazy.force opam

  let env =
    let impl (env, { Opam_switch.root; switch }) =
      let* opam = opam_binary_exn () in
      let args =
        List.concat
          [ [ "config"; "env" ]
          ; (match root with
             | None -> []
             | Some root -> [ "--root"; root ])
          ; [ "--switch"; switch; "--sexp"; "--set-switch" ]
          ]
      in
      let+ s =
        Process.run_capture ~display:Quiet ~env Strict opam args
        |> Memo.of_reproducible_fiber
      in
      Dune_sexp.Parser.parse_string ~fname:"<opam output>" ~mode:Single s
      |> Dune_sexp.Decoder.(parse (enter (repeat (pair string string))) Univ_map.empty)
      |> Env.Map.of_list_multi
      |> Env.Map.mapi ~f:(fun var values ->
        match List.rev values with
        | [] -> assert false
        | [ x ] -> x
        | x :: _ ->
          User_warning.emit
            [ Pp.textf "variable %S present multiple times in the output of:" var
            ; Pp.tag
                User_message.Style.Details
                (Pp.text (String.quote_list_for_shell (Path.to_string opam :: args)))
            ];
          x)
    in
    let module Input = struct
      type t = Env.t * Opam_switch.t

      let equal (env_a, opam_a) (env_b, opam_b) =
        Env.equal env_a env_b && Opam_switch.equal opam_a opam_b
      ;;

      let hash = Tuple.T2.hash Env.hash Opam_switch.hash
      let to_dyn (env, kind) = Dyn.Tuple [ Env.to_dyn env; Opam_switch.to_dyn kind ]
    end
    in
    let memo =
      Memo.create
        "opam-env"
        impl
        ~cutoff:(Env.Map.equal ~equal:String.equal)
        ~input:(module Input)
    in
    fun ~env opam -> Memo.exec memo (env, opam)
  ;;
end

module Build_environment_kind = struct
  (* Heuristics to detect the current environment *)

  type t =
    | Cross_compilation_using_findlib_toolchain of Context_name.t
    | Hardcoded_path of string list
    | Opam2_environment of string (* opam switch prefix *)
    | Lock
    | Unknown

  let query ~kind ~findlib_toolchain ~env =
    match findlib_toolchain with
    | Some s -> Cross_compilation_using_findlib_toolchain s
    | None ->
      let opam_prefix = Env.get env Opam_switch.opam_switch_prefix_var_name in
      (match kind with
       | `Opam ->
         (match opam_prefix with
          | Some s -> Opam2_environment s
          | None ->
            (* This is unreachable because we check in [create_for_opam] that opam
               sets this variable *)
            assert false)
       | `Lock -> Lock
       | `Default ->
         (match Setup.library_path with
          | _ :: _ as l -> Hardcoded_path l
          | [] ->
            (match opam_prefix with
             | Some s -> Opam2_environment s
             | None -> Unknown)))
  ;;

  let findlib_paths t ~findlib ~ocaml_bin =
    match findlib with
    | Some findlib -> Findlib_config.ocamlpath findlib
    | None ->
      (match t with
       | Cross_compilation_using_findlib_toolchain toolchain ->
         User_error.raise
           [ Pp.textf
               "Could not find `ocamlfind' in PATH or an environment variable \
                `OCAMLFIND_CONF' while cross-compiling with toolchain `%s'"
               (Context_name.to_string toolchain)
           ]
           ~hints:
             [ Pp.enumerate
                 [ "`opam install ocamlfind' and/or:"
                 ; "Point `OCAMLFIND_CONF' to the findlib configuration that defines \
                    this toolchain"
                 ]
                 ~f:Pp.text
             ]
       | Hardcoded_path l -> List.map l ~f:Path.of_filename_relative_to_initial_cwd
       | Opam2_environment opam_prefix ->
         let p = Path.of_filename_relative_to_initial_cwd opam_prefix in
         [ Path.relative p "lib" ]
       | Lock -> []
       | Unknown -> [ Path.relative (Path.parent_exn ocaml_bin) "lib" ])
  ;;
end

let make_installed_env env name findlib env_nodes version profile =
  let env =
    (* See comment in ansi_color.ml for setup_env_for_colors. For versions
       where OCAML_COLOR is not supported, but 'color' is in OCAMLPARAM, use
       the latter. If 'color' is not supported, we just don't force colors
       with 4.02. *)
    if !Clflags.capture_outputs
       (* CR rgrinberg: what if we just set [OCAML_COLOR] and [OCAMLPARAM]
          unconditionally? These ancient versions of OCaml aren't important
          anymore and thsi would allow us to initialize the environment without
          building and running the compiler *)
       && Lazy.force Ansi_color.stderr_supports_color
       && Ocaml.Version.supports_color_in_ocamlparam version
       && not (Ocaml.Version.supports_ocaml_color version)
    then Ocaml.Env.with_color env
    else env
  in
  let vars =
    Env.Map.singleton
      Execution_env.Inside_dune.var
      (Execution_env.Inside_dune.value (In_context (Context_name.build_dir name)))
  in
  Env.extend env ~vars
  |> Env.extend_env
       (Option.value ~default:Env.empty (Option.map findlib ~f:Findlib_config.env))
  |> Env.extend_env (Env_nodes.extra_env env_nodes profile)
;;

let create (builder : Builder.t) ~(kind : Kind.t) =
  let* which, builder =
    match kind with
    | Default | Opam _ -> Memo.return (Which.which ~path:builder.path, builder)
    | Lock _ ->
      let+ env = Pkg_rules.exported_env builder.name in
      let which =
        let which = Staged.unstage @@ Pkg_rules.which builder.name in
        fun prog ->
          which prog
          >>= function
          | Some p -> Memo.return (Some p)
          | None -> Which.which ~path:builder.path prog
      in
      let env = Env_path.extend_env_concat_path builder.env env in
      which, { builder with env }
  in
  let ocamlpath =
    Kind.ocamlpath kind ~env:builder.env ~findlib_toolchain:builder.findlib_toolchain
  in
  let* findlib =
    let findlib_toolchain =
      Option.map builder.findlib_toolchain ~f:Context_name.to_string
    in
    Findlib_config.discover_from_env ~env:builder.env ~which ~ocamlpath ~findlib_toolchain
  in
  let* ocaml, build_env_kind =
    let toolchain kind =
      let+ toolchain =
        Ocaml_toolchain.of_env_with_findlib builder.name builder.env findlib ~which
      in
      toolchain, kind
    in
    match kind with
    | Default -> toolchain `Default
    | Opam _ -> toolchain `Opam
    | Lock _ ->
      Pkg_rules.ocaml_toolchain builder.name
      >>= (function
      | None -> toolchain `Lock
      | Some toolchain ->
        let+ toolchain, _ = Action_builder.run toolchain Eager in
        toolchain, `Default)
  in
  let default_ocamlpath =
    let default_ocamlpath =
      Build_environment_kind.query
        ~kind:build_env_kind
        ~findlib_toolchain:builder.findlib_toolchain
        ~env:builder.env
      |> Build_environment_kind.findlib_paths ~findlib ~ocaml_bin:ocaml.bin_dir
    in
    if Ocaml.Version.has_META_files ocaml.version
    then ocaml.lib_config.stdlib_dir :: default_ocamlpath
    else default_ocamlpath
  in
  let builder =
    let installed_env =
      make_installed_env
        builder.env
        builder.name
        findlib
        builder.env_nodes
        ocaml.version
        builder.profile
    in
    { builder with env = installed_env }
  in
  if Option.is_some builder.fdo_target_exe
  then Ocaml_toolchain.check_fdo_support ocaml builder.name;
  let builder =
    let dynamically_linked_foreign_archives =
      Ocaml_config.supports_shared_libraries ocaml.ocaml_config
      && builder.dynamically_linked_foreign_archives
    in
    { builder with dynamically_linked_foreign_archives }
  in
  Ocaml_toolchain.register_response_file_support ocaml;
  Memo.return
    { kind
    ; builder
    ; build_dir = Context_name.build_dir builder.name
    ; ocaml
    ; findlib_paths = ocamlpath @ default_ocamlpath
    ; default_ocamlpath
    ; build_context = Build_context.create ~name:builder.name
    ; which
    }
;;

module Group = struct
  type nonrec t =
    { native : t
    ; targets : t list
    }

  let create builder ~(kind : Kind.t) ~targets =
    let* native =
      let implicit =
        not
          (List.mem
             targets
             ~equal:Workspace.Context.Target.equal
             Workspace.Context.Target.Native)
      in
      let builder = { builder with implicit } in
      create builder ~kind
    in
    let+ others =
      let builder =
        { builder with implicit = false; merlin = false; for_host = Some native }
      in
      Memo.parallel_map targets ~f:(function
        | Native -> Memo.return None
        | Named findlib_toolchain ->
          let name = Context_name.target builder.name ~toolchain:findlib_toolchain in
          create { builder with name; findlib_toolchain = Some findlib_toolchain } ~kind
          >>| Option.some)
    in
    { native; targets = List.filter_opt others }
  ;;

  let default (builder : Builder.t) ~lock ~targets =
    let path = Env_path.path builder.env in
    let* (kind : Kind.t) =
      if lock
      then Memo.return @@ Kind.Lock { default = true }
      else
        let+ has_lock = Pkg_rules.has_lock builder.name in
        if has_lock then Kind.Lock { default = true } else Default
    in
    create { builder with path } ~kind ~targets
  ;;

  let create_for_opam (builder : Builder.t) ~switch ~loc ~targets =
    let* vars = Opam.env ~env:builder.env switch in
    if not (Env.Map.mem vars Opam_switch.opam_switch_prefix_var_name)
    then
      User_error.raise
        ~loc
        [ Pp.textf
            "opam doesn't set the environment variable %s. I cannot create an opam build \
             context without opam setting this variable."
            Opam_switch.opam_switch_prefix_var_name
        ];
    let path =
      match Env.Map.find vars Env_path.var with
      | None ->
        (* CR rgrinberg: Is this even possible? *)
        Env_path.path builder.env
      | Some s -> Bin.parse_path s
    in
    let builder = { builder with path; env = Env.extend builder.env ~vars } in
    create builder ~kind:(Opam switch) ~targets
  ;;

  module rec Instantiate : sig
    val instantiate : Context_name.t -> t Memo.t
  end = struct
    let instantiate_impl name : t Memo.t =
      let env = Global.env () in
      let* workspace = Workspace.workspace () in
      let context =
        List.find_exn workspace.contexts ~f:(fun ctx ->
          Context_name.equal (Workspace.Context.name ctx) name)
      in
      let* host_context =
        match Workspace.Context.host_context context with
        | None -> Memo.return None
        | Some context_name ->
          let+ { native; targets = _ } = Instantiate.instantiate context_name in
          Some native
      in
      let builder : Builder.t =
        let builder =
          let env_nodes =
            let context = Workspace.Context.env context in
            { Env_nodes.context; workspace = workspace.env }
          in
          { Builder.empty with env_nodes; for_host = host_context }
        in
        match context with
        | Opam opam -> Builder.set_workspace_base builder opam.base
        | Default default ->
          let builder = Builder.set_workspace_base builder default.base in
          let merlin = workspace.merlin_context = Some (Workspace.Context.name context) in
          { builder with merlin }
      in
      match context with
      | Opam { base; switch } ->
        create_for_opam builder ~switch ~loc:base.loc ~targets:base.targets
      | Default { lock; version_preference = _; solver_env = _; base } ->
        let builder =
          match builder.findlib_toolchain with
          | Some _ -> builder
          | None ->
            (match Env.get env "OCAMLFIND_TOOLCHAIN" with
             | None -> builder
             | Some name ->
               { builder with
                 findlib_toolchain = Some (Context_name.parse_string_exn (Loc.none, name))
               })
        in
        let lock = Option.is_some lock in
        default builder ~targets:base.targets ~lock
    ;;

    let memo =
      Memo.create "instantiate-context" ~input:(module Context_name) instantiate_impl
    ;;

    let instantiate name = Memo.exec memo name
  end

  include Instantiate
end

module DB = struct
  let all =
    let impl () =
      let* workspace = Workspace.workspace () in
      let+ contexts =
        Memo.parallel_map workspace.contexts ~f:(fun c ->
          let+ { Group.native; targets } = Group.instantiate (Workspace.Context.name c) in
          native :: targets)
      in
      let all = List.concat contexts in
      List.iter all ~f:(fun t ->
        let open Pp.O in
        Log.info
          [ Pp.box ~indent:1 (Pp.text "Dune context:" ++ Pp.cut ++ Dyn.pp (to_dyn t)) ]);
      all
    in
    let memo = Memo.lazy_ ~name:"build-contexts" impl in
    fun () -> Memo.Lazy.force memo
  ;;

  let get =
    let memo =
      Memo.create
        "context-db-get"
        ~input:(module Context_name)
        (fun name ->
          let+ contexts = all () in
          List.find_exn contexts ~f:(fun c -> Context_name.equal name c.builder.name))
    in
    Memo.exec memo
  ;;

  let create_db ~name f =
    let map =
      Memo.lazy_ ~name (fun () ->
        let+ map = all () in
        Context_name.Map.of_list_map_exn map ~f:(fun context ->
          context.builder.name, Memo.lazy_ (fun () -> f context)))
    in
    Staged.stage (fun context ->
      let* map = Memo.Lazy.force map in
      match Context_name.Map.find map context with
      | Some v -> Memo.Lazy.force v
      | None ->
        Code_error.raise "invalid context" [ "context", Context_name.to_dyn context ])
  ;;

  let by_dir dir =
    let context =
      match Install.Context.of_path dir with
      | Some name -> name
      | None ->
        Code_error.raise
          "directory does not have an associated context"
          [ "dir", Path.Build.to_dyn dir ]
    in
    get context
  ;;
end

let map_exe (context : t) =
  match context.builder.for_host with
  | None -> fun exe -> exe
  | Some (host : t) ->
    fun exe ->
      (match Path.extract_build_context_dir exe with
       | Some (dir, exe) when Path.equal dir (Path.build context.build_dir) ->
         Path.append_source (Path.build host.build_dir) exe
       | _ -> exe)
;;

let roots t =
  let module Roots = Install.Roots in
  let prefix_roots =
    match Env.get t.builder.env Opam_switch.opam_switch_prefix_var_name with
    | None -> Roots.make_all None
    | Some prefix ->
      let prefix = Path.of_filename_relative_to_initial_cwd prefix in
      Roots.opam_from_prefix prefix |> Roots.map ~f:(fun s -> Some s)
  in
  match t.kind with
  | Lock _ | Default ->
    let setup_roots = Roots.map ~f:(Option.map ~f:Path.of_string) Setup.roots in
    Roots.first_has_priority setup_roots prefix_roots
  | Opam _ -> prefix_roots
;;
