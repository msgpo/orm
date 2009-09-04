(*pp camlp4orf *)

open Printf
open Lexing

open Camlp4
open PreCast
open Ast
open Syntax
open Pa_type_conv

(* Extend grammar with options for SQL tables *)
let sql_parms = Gram.Entry.mk "sql_parms"
EXTEND Gram

GLOBAL: sql_parms;

svars: [
  [ l = LIST0 [ `LIDENT(x) -> x ] SEP "," -> l ]
];

param: [
  [ "unique"; ":"; x = svars -> x ]
];

sql_parms: [
  [ l = LIST0 [ param ] SEP ";" -> l ]
];

END

(* Begin implementation *)

(* convenience function to wrap the TyDcl constructor since I cant
   find an appropriate quotation to use for this *)
let declare_type _loc name ty =
  Ast.TyDcl (_loc, name, [], ty, [])

(* defines the Ast.binding for a function of form:
let fun_name ?(opt_arg1) ?(opt_arg2) final_ident = function_body ...
*)
let function_with_label_args _loc ~fun_name ~final_ident ~function_body ~return_type opt_args =
   let opt_args = opt_args @ [ <:patt< $lid:final_ident$ >> ] in
   <:binding< $lid:fun_name$ = 
      $List.fold_right (fun b a ->
        <:expr<fun $b$ -> $a$ >>
       ) opt_args <:expr< ( $function_body$ : $return_type$ ) >>
      $ >>

(* convert a list of bindings into an expr fragment:
   let x = 1 in y = 2 in z = 3 in ()
*)
let biList_to_expr _loc bindings final =
  List.fold_right (fun b a -> 
    <:expr< let $b$ in $a$ >>
  ) bindings final

(* build something like 'f ~x1 ~x2 ~x3 ... xn' *)
let apply _loc f label_args =
  let make x = Ast.ExId (_loc, Ast.IdLid (_loc, x)) in
  let make_label x = Ast.ExLab (_loc, x, Ast.ExId (_loc, Ast.IdLid (_loc, x))) in
  let rec aux = function
  | []   -> Ast.ExApp (_loc, make f, make "()")
  | [h]  -> Ast.ExApp (_loc, make f, make_label h)
  | h::t -> Ast.ExApp (_loc, aux t , make_label h) in
  let aux0 = function
  | [] -> aux []
  | h::t -> Ast.ExApp (_loc, aux t , make h) in
  aux0 (List.rev label_args)

let access_array _loc a i =
  let make x = Ast.ExId (_loc, Ast.IdLid (_loc, x)) in
  Ast.ExAre (_loc, make a, Ast.ExInt (_loc, string_of_int i))
	
(* List.map with the integer position passed to the function *)
let mapi fn =
  let pos = ref 0 in
  List.map (fun x ->
    incr pos;
    fn !pos x
  ) 
    
open Sql_types

(* declare the types of the _persist objects used to pass SQL
   objects back and forth *)
let construct_typedefs env =
  let _loc = Loc.ghost in
  let tables = exposed_tables env in
  let object_decls = Ast.tyAnd_of_list (List.fold_right (fun t decls ->
    (* define the external type name as <name>_persist *)
    let ts_name = t.t_name ^ "_persist" in
    (* define the accessor and set_accessor functions *)
    let fields = exposed_fields env t.t_name in
    let accessor_fields = List.flatten (List.map (fun f ->
    let ctyp = <:ctyp< $f.f_ctyp$ >> in
      [ <:ctyp< $lid:f.f_name$ : $ctyp$ >> ;
       <:ctyp< $lid:"set_" ^ f.f_name$ : $f.f_ctyp$ -> unit >> ]
    ) fields) in
    let other_fields = [
      <:ctyp< save: int64 >>;
      <:ctyp< delete: unit >>;
    ] in
    let all_fields = accessor_fields  @ other_fields in
    declare_type _loc ts_name <:ctyp< < $list:all_fields$ > >> :: decls;
  ) tables []) in
  let cache_decls =
    let sum_type = List.map (fun t -> (_loc, "C_"^t.t_name, [ <:ctyp< ($lid:t.t_name^"_persist"$) >> ])) tables in
    let sum_type =
      if List.length sum_type = 1 then
        <:ctyp< $lid:(List.hd tables).t_name$ >>
      else
        <:ctyp< [ $sum_type_of_list sum_type$ ] >> in
      declare_type _loc "cache_elt" sum_type in
  stSem_of_list [ 
    <:str_item< type $object_decls$ >>;
    <:str_item< type $cache_decls$  >>;
    <:str_item< type cache = Hashtbl.t (string * int64) cache_elt >> ]
 
(* construct the functions to init the db and create objects *)
let construct_object_funs env =
  let _loc = Loc.ghost in
  let tables = exposed_tables env in
  (* output the function bindings *)
  List.flatten (List.map (fun t ->
    (* init function to initalize sqlite database *)
    let type_name = sprintf "%s_persist" t.t_name in
 
    (* the _new creation function to spawn objects of the SQL type *)
    let new_fun_name ~_lazy = sprintf "%s_new%s" t.t_name (if _lazy then "_lazy" else "") in
    let fields = exposed_fields env t.t_name in
    let fun_args = List.map (fun f ->
      if is_optional_field f then
        <:patt< ?($lid:f.f_name$ = None) >>
      else
        <:patt< ~ $lid:f.f_name$ >>
    ) fields in

    let new_set_get_functions ~_lazy = List.flatten (List.map (fun f ->
      let _lazy = is_foreign f && _lazy in
      let internal_var_name = sprintf "_%s" f.f_name in
      let get x =
        if _lazy then 
          <:expr< match $lid:x$ with [
              `Lazy f -> let x = f () in do { $lid:x$ := `Result x; x }
            | `Result x -> x ]
          >>
        else
          <:expr< $lid:x$ >> in 
      let set  x = if _lazy then <:expr< $lid:x$ := `Result v >> else <:expr< $lid:x$ := v >> in
      let init x = if _lazy then <:expr< `Lazy $lid:x$ >> else <:expr< $lid:x$ >> in
      let external_var_name = f.f_name in [
        <:class_str_item<
          value mutable $lid:internal_var_name$ = $init external_var_name$
        >>;
        <:class_str_item< 
          method $lid:external_var_name$ = $get internal_var_name$
        >>;
        <:class_str_item< 
          method $lid:"set_"^external_var_name$ v = ( $set internal_var_name$ ) 
        >>;
      ]
    ) fields) in

    (* -- implement the save function *)

    (* bindings for the ids of all the foreign-single fields *)
    let foreign_single_ids = List.map (fun f ->
        let id = f.f_name in
        <:binding< $lid:"_"^id^"_id"$ = self#$lid:id$#save >>
      ) (foreign_single_fields env t.t_name) in 

    (* the INSERT statement for this object *)
    let insert_sql = sprintf "INSERT INTO %s VALUES(%s);" t.t_name
      (String.concat "," (List.map (fun f -> 
        if is_autoid f then "NULL" else "?") (sql_fields env t.t_name))) in

    (* the UPDATE statement for this object *)
    let update_sql = sprintf "UPDATE %s SET %s WHERE id=?;" t.t_name
      (String.concat "," (List.map (fun f ->
          sprintf "%s=?" f.f_name
        ) (sql_fields_no_autoid env t.t_name))) in

    (* the Sqlite3.bind for each simple statement *)
    let sql_bind_pos = ref 0 in
    let sql_bind_expr = List.map (fun f ->
       incr sql_bind_pos;
       let v = field_to_sql_data _loc f in
       <:expr< 
        Sql_access.db_must_ok db (fun () -> 
               Sqlite3.bind stmt $`int:!sql_bind_pos$ $v$)
       >>
    ) (sql_fields_no_autoid env t.t_name) in

    (* last binding for update statement which also needs an id at the end *)
    incr sql_bind_pos;

    (* the main save function *)
    let save_main = <:binding<
       _curobj_id =
       let stmt = Sqlite3.prepare db.Sql_access.db 
         (match _id with [
            None -> $str:insert_sql$
           |Some _ -> $str:update_sql$
          ]
         ) in
       do {
         $exSem_of_list sql_bind_expr$;
         match _id with [
           None -> ()
          |Some _id -> 
            Sql_access.db_must_bind db stmt $`int:!sql_bind_pos$ (Sqlite3.Data.INT _id)
         ];
         Sql_access.db_must_step db stmt;
         match _id with [
           None -> 
            let __id = Sqlite3.last_insert_rowid db.Sql_access.db in
            do { _id := Some __id; __id }
          |Some _id ->
            _id
         ]
       }
    >> in
 
    (* generate the list functions insertion functions *)
    let foreign_many = List.map (fun f ->
      let tname = list_table_name t.t_name f.f_name in
      let ins_sql =
        sprintf "INSERT OR REPLACE INTO %s VALUES(%s)" tname 
          (String.concat "," (List.map (fun x -> "?") (sql_fields env tname)))  in 
      let del_sql =
        sprintf "DELETE FROM %s WHERE (id=?) AND (_idx > ?)" tname in
      (* XXX factor this code with the bind code above for normal values *)
      let sql_bind_pos = ref 0 in
      let sql_bind_expr = List.map (fun f ->
         incr sql_bind_pos;
         let v = field_to_sql_data _loc f in
         <:expr< 
          Sql_access.db_must_ok db (fun () -> 
                 Sqlite3.bind stmt $`int:!sql_bind_pos$ $v$)
         >>
      ) (sql_fields_no_autoid env tname) in
      (* decide which iterator to use depending on the list type *)
      let access_fn, length_fn = match f.f_ctyp with
        | <:ctyp< array $c$ >> -> <:expr< Array.iteri >> , <:expr< Array.length >>
        | <:ctyp< list $c$ >> ->  <:expr< Sql_access.list_iteri >> , <:expr< List.length >>
        | _ -> assert false in
      (* main binding for iterating through the list and updating sql *)
      let foreign_bindings = List.fold_left (fun a f ->
        match f.f_info with
        |External_foreign _ -> <:binding< $lid:"_"^f.f_name^"_id"$ = $lid:"_"^f.f_name$#save >> :: a
        |_ -> a
      ) [] (foreign_single_fields env tname) in
      let foreign_bindings = match foreign_bindings with 
      [x] -> x |_ -> <:binding< _ = () >> in
      let fid,fexpr = match f.f_info with
       |_ -> <:patt< () >>, <:expr< () >> in
      <:binding< () = 
        let stmt = Sqlite3.prepare db.Sql_access.db $str:ins_sql$ in
        let () = $access_fn$ (fun pos $lid:"_"^f.f_name$ ->
            let $foreign_bindings$ in
            let _id = _curobj_id in
            let __idx = Int64.of_int pos in
            do { 
              Sql_access.db_must_reset db stmt;
              $exSem_of_list sql_bind_expr$;
              Sql_access.db_must_step db stmt
            }
        ) $lid:"_"^f.f_name$ in
        let stmt = Sqlite3.prepare db.Sql_access.db $str:del_sql$ in
        do {
          Sql_access.db_must_bind db stmt 1 (Sqlite3.Data.INT _curobj_id);
          (* XXX check for off-by-one here *)
          Sql_access.db_must_bind db stmt 2 
             (Sqlite3.Data.INT (Int64.of_int ($length_fn$ $lid:"_"^f.f_name$)));
          Sql_access.db_must_step db stmt
        }
      >>
    ) (foreign_many_fields env t.t_name) in 

    let save_bindings = foreign_single_ids @ [ save_main ] @ foreign_many in
    let save_fun = biList_to_expr _loc save_bindings <:expr< _curobj_id >> in

    (* -- hook in the admin functions (save/delete) *)
    let new_admin_functions =
       [
         <:class_str_item< method delete = failwith "delete not implemented" >>;
         <:class_str_item< method save   = $save_fun$ >>;
       ] in
    let new_functions ~_lazy = new_set_get_functions ~_lazy @ new_admin_functions in

    let new_body ~_lazy = <:expr<
        object(self)
         $Ast.crSem_of_list (new_functions ~_lazy)$;
        end
      >> in

    let new_binding ~_lazy = function_with_label_args _loc 
      ~fun_name:(new_fun_name ~_lazy)
      ~final_ident:"db"
      ~function_body:(new_body ~_lazy)
      ~return_type:<:ctyp< $lid:type_name$ >>
      fun_args in

    (* return single binding of all the functions for this type *)
    [ new_binding ~_lazy:false; new_binding ~_lazy:true ]
  ) tables)

(* force functions *)
let construct_force_functions env =
  let _loc = Loc.ghost in
  let tables = exposed_tables env in
  let foreign_tables, not_foreign_tables  = List.partition (fun t -> List.exists is_foreign t.t_fields) tables in 
  List.map (fun t ->
    let foreign_fields = List.filter is_foreign t.t_fields in

    let force_body =
      let force_exprs =
        List.map 
          (fun f -> <:expr< ignore ($lid:get_foreign f^"_force"$ ~cache $lid:t.t_name$ # $lid:f.f_name$) >>)
          foreign_fields in
      <:expr<
        let id = match $lid:t.t_name$#id with [ None -> assert False | Some x -> x ] in
        let key = ( $str:t.t_name$, id) in
        if Hashtbl.mem cache key
        then match Hashtbl.find cache key with [ $uid:"C_"^t.t_name$ x -> x | _ -> assert False ]
        else (do {
          Hashtbl.replace cache key ($uid:"C_"^t.t_name$ $lid:t.t_name$);
          $exSem_of_list force_exprs$;
          $lid:t.t_name$ })

      >> in

    let force_binding = function_with_label_args _loc
      ~fun_name:(t.t_name^"_force")
      ~final_ident:t.t_name
      ~function_body:force_body
      ~return_type:<:ctyp< $lid:t.t_name^"_persist"$ >>
      [ <:patt< ~cache >> ]
    in

    force_binding) 
    foreign_tables 
  @ List.map (fun t ->
      <:binding< $lid:t.t_name^"_force"$ ~cache $lid:t.t_name$ : $lid:t.t_name^"_persist"$ = $lid:t.t_name$ >>)
      not_foreign_tables
  @ [ <:binding< $lid:"new_cache"$ () = Hashtbl.create 64 >> ]

(* create functions *)
let construct_create_functions env =
  let _loc = Loc.ghost in
  let tables = exposed_tables env in
  List.map (fun t ->
    let create_body =
      let fields = List.filter (fun f -> not (is_autoid f)) t.t_fields in
      let fields_str = List.map (fun f -> f.f_name) fields in
      let bindings = List.map (fun f -> 
          if is_foreign f then
            <:binding< $lid:f.f_name$ () = $lid:get_foreign f$ $lid:t.t_name$ . $lid:f.f_name$ db >>
          else
            <:binding< $lid:f.f_name$ = $lid:t.t_name$ . $lid:f.f_name$ >>
        ) fields in
      <:expr<
        let __x = 
          $biList_to_expr _loc bindings <:expr< $apply _loc (t.t_name^"_new_lazy") (fields_str @ ["db"])$ >>$ in
        $lid:t.t_name^"_force"$ ~cache:(new_cache ()) __x
      >> in

    let create_binding = function_with_label_args _loc
      ~fun_name:t.t_name
      ~final_ident:"db"
      ~function_body:create_body
      ~return_type:<:ctyp< $lid:t.t_name^"_persist"$ >>
      [ <:patt< $lid:t.t_name$ >> ] in

    <:expr< $create_binding$ >>
  ) tables


(* get functions *)
let construct_get_functions env =
  let _loc = Loc.ghost in
  let tables = exposed_tables env in
  List.map (fun t ->
    let type_name = sprintf "%s_persist" t.t_name in
    let fields = exposed_fields env t.t_name in
    let str_fields = List.map (fun f -> f.f_name) fields in
    let foreign_fields, not_foreign_fields = List.partition is_foreign fields in
    let new_lazy_object = <:expr< $apply _loc (sprintf "%s_new_lazy" t.t_name) (str_fields @ ["db"]) $ >> in

    let get_body =

      (* build-up the SQL query *)
      let sql =
        let select_clause = String.concat ", " str_fields in
        let where_0 = <:binding< __accu = [] >> in
        let where_of_field f =
          <:binding< __accu = match $lid:f.f_name$ with [
              None                -> __accu
            | Some $lid:f.f_name$ -> [ $ocaml_variant_to_sql_request _loc f$ :: __accu ] ]
          >> in
        let where_of_custom =
          <:binding< __accu = match fn with [
              None    -> List.rev __accu
            | Some fn -> List.rev [ $str:sprintf "custom_fn(%s)" select_clause$ :: __accu ] ]
          >> in
        let bindings =
          where_0 ::
            (List.map (fun f -> where_of_field f) not_foreign_fields)
          @ [ where_of_custom ] in

        biList_to_expr _loc bindings
          <:expr<
            let where_clause = String.concat " AND " __accu in
            Printf.sprintf $str:"SELECT "^select_clause^" FROM "^t.t_name^"%s"$
              (if where_clause = "" then "" else (" WHERE "^where_clause) )
          >> in

      (* TODO: build-up the bind list *)
      let binds =
        let text_fields = List.filter (fun f -> f.f_ctyp = <:ctyp< string >>) not_foreign_fields in
        let bind_funs =
          List.map (fun f ->
            <:expr<
              match $lid:f.f_name$ with [
                None -> ()
              | Some (`Eq $lid:"_"^f.f_name$) ->
                  do {
                    Sql_access.db_must_ok db (fun () -> Sqlite3.bind stmt !__count $field_to_sql_data _loc f$);
                    incr __count }
              | Some (`Contains e) ->
                  let $lid:"_"^f.f_name$ = "%."^e^"%." in
                  do {
                    Sql_access.db_must_ok db (fun () -> Sqlite3.bind stmt !__count $field_to_sql_data _loc f$);
                    incr __count } ]
            >>)
          text_fields in
        if text_fields <> [] then
          <:expr<
            let __count = ref 0 in
            $exSem_of_list bind_funs$
          >> else
          <:expr< () >> in

      (* build-up the new object from an SQL return *)
      let of_stmt = 
        let get_bindings =
          mapi (fun i f ->
              let x = <:expr<
                let $lid:"__" ^ f.f_name$ = Sqlite3.column stmt $`int:i-1$ in
                $sql_data_to_field _loc f$
              >> in
              if is_foreign f then
                <:binding< $lid:f.f_name$ () =
                  match $lid:get_foreign f^"_get"$ ~id:(`Exists (`Eq $x$)) db with [ 
                    [x] -> x
                  |  _  -> assert False ]
                >>
              else
                <:binding< $lid:f.f_name$ = $x$ >>
            ) fields in
        if foreign_fields = [] then
          <:expr< $biList_to_expr _loc get_bindings new_lazy_object$ >>
        else
          <:expr< 
            let $lid:"__"^t.t_name$ = $biList_to_expr _loc get_bindings new_lazy_object$ in
            do {
              if not _lazy then
                $lid:t.t_name^"_force"$ ~cache:(new_cache ()) $lid:"__"^t.t_name$
              else
                $lid:"__"^t.t_name$ } 
          >> in

      (* build-up the custom function *)
      let custom_fn =
        let access i f = 
          <:expr< 
            let $lid:"__"^f.f_name$ = $access_array _loc "__sql_array__" (i-1)$ in 
            $sql_data_to_field _loc f$
          >> in
        let not_foreign_bindings =
          mapi (fun i f -> <:binding< $lid:f.f_name$ = $access i f$ >>) not_foreign_fields in
        let foreign_binding =
          mapi (fun i f -> 
              <:binding< $lid:f.f_name$ () =
                match $lid:get_foreign f^"_get"$ ~_lazy:True ~id:(`Exists (`Eq $access i f$)) db with [
                  [x] -> x
                |  _  -> assert False ]
              >>
            ) foreign_fields in
        <:expr< match fn with [
             None -> ()
           | Some fn ->
               let custom_fn __sql_array__ =
                 let x = $biList_to_expr _loc (not_foreign_bindings @ foreign_binding) new_lazy_object$ in
                 if fn x then Sqlite3.Data.INT 1L else Sqlite3.Data.INT 0L in
               Sqlite3.create_funN db.Sql_access.db "custom_fn" custom_fn ]
        >> in

      <:expr<
        do {
          $custom_fn$;
          let of_stmt stmt = $of_stmt$ in
          let sql = $sql$ in
          let stmt = Sqlite3.prepare db.Sql_access.db sql in
          do {
            $binds$;
            Sql_access.step_fold db stmt of_stmt
          }
        }
      >> in

    let get_fun_name = sprintf "%s_get" t.t_name in
    let return_type = <:ctyp< list $lid:type_name$ >> in
    let get_argument =
      <:patt< ?(_lazy=False) >> :: 
        List.map (fun f -> <:patt< ? $lid:f.f_name$ >>) not_foreign_fields @
        [ <:patt< ?fn >> ] in
    let get_binding = function_with_label_args _loc
      ~fun_name:get_fun_name
      ~final_ident:"db"
      ~function_body:get_body
      ~return_type:return_type
      get_argument in
     get_binding
  ) tables

let construct_funs env =
  let _loc = Loc.ghost in
  let bs = List.fold_left (fun a f -> f env @ a) []
    [ construct_object_funs ] in
  <:str_item< 
     value rec $biAnd_of_list bs$ >>

(* --- Initialization functions to create tables and open the db handle *)

let init_db_funs env =
  let _loc = Loc.ghost in
  Ast.exSem_of_list (List.map (fun table ->
    (* open function to first access a sqlite3 db *)
    let sql_decls = List.fold_right (fun t a ->
      let fields = sql_fields env t in
      let sql_fields = List.map (fun f ->
        sprintf "%s %s" f.f_name (string_of_sql_type f)
      ) fields in
      let prim_key = match table.t_type with 
        |List -> ", PRIMARY KEY(id, _idx)"
        |_ -> "" in
      sprintf "CREATE TABLE IF NOT EXISTS %s (%s%s)" 
        t (String.concat ", " sql_fields) prim_key :: a
    ) (table.t_name :: table.t_child) [] in

    let create_table sql = <:expr<
        let sql = $str:sql$ in
        Sql_access.db_must_ok db (fun () -> Sqlite3.exec db.Sql_access.db sql)
     >> in
    let create_statements = Ast.exSem_of_list (List.map create_table sql_decls) in
    (* the final init_db binding for the SQL creation function *)
    <:expr< do { $create_statements$ } >>
  ) (sql_tables env))
 
let construct_init env =
  let _loc = Loc.ghost in
  (* XXX default name until its parsed into environment *)
  let name = "orm" in
  <:str_item<
    value $lid:name^"_init_db"$ db_name = 
      let db = Sql_access.new_state db_name in
      do {
        $init_db_funs env$; db
      };
  >>

let construct_sexp env =
  let _loc = Loc.ghost in
  let sexp_of_bindings = List.map (fun (n,t) ->
      Pa_sexp_conv.Generate_sexp_of.sexp_of_td _loc n [] t
    ) (sexp_tables env) in
  let bindings_of_sexp = List.map (fun (n,t) ->
      let internal_binding,external_binding = 
         Pa_sexp_conv.Generate_of_sexp.td_of_sexp _loc n [] t in
      <:binding< $internal_binding$ and $external_binding$ >>
    ) (sexp_tables env) in
  <:str_item< value rec $biAnd_of_list (sexp_of_bindings @ bindings_of_sexp)$ >>
 
(* Register the persist keyword with type-conv *)
let () =
  add_generator_with_arg
    "persist"
    sql_parms
    (fun tds args ->
      prerr_endline "in add_generator_with_arg: persist";
      let _loc = Loc.ghost in
      let env = process tds in
      prerr_endline (Sql_types.string_of_env env);
      match tds, args with
      |_, None ->
        Loc.raise (Ast.loc_of_ctyp tds) (Stream.Error "pa_sql_orm: arg required")
      |_, Some name ->
        let _loc = Loc.ghost in
        <:str_item<
        module Persist = struct
          $construct_sexp env$;
          $construct_typedefs env$;
          $construct_funs env$;
          $construct_init env$;
          value rec $biAnd_of_list (construct_force_functions env)$;
          value rec $biAnd_of_list (construct_create_functions env)$;
          value rec $biAnd_of_list (construct_get_functions env)$;
        end
        >>
      )
