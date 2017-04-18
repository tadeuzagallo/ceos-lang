module T = Types
open Absyn

exception TypeError of string
exception UnificationError of string

type ty_env = (name * T.ty) list
type subst = (T.tvar * T.ty) list

let _type_id = ref 0
let new_var name =
  incr _type_id;
  T.TV (!_type_id, name)
let extend_env env (x, t) = (x, t)::env

let ty_int = T.Type "Int"
let ty_type = T.Type "Type"
let ty_unit = T.Type "Unit"

let default_env = [
  ("Type", ty_type);
  ("Int", ty_int);
  ("Void", ty_unit);
]

let (>>) s1 s2 =
  s1 @ s2

let rec apply s =
  let var v =
    try List.assoc v s
    with Not_found -> T.Var v
  in function
  | T.Type t -> T.Type t
  | T.Var v -> var v
  | T.Arrow (t1, t2) ->
      T.Arrow (apply s t1, apply s t2)
  | T.TypeArrow (v1, t2) ->
      T.TypeArrow (v1, apply s t2)

let rec unify = function
  | T.Type t1, T.Type t2 when t1 = t2 -> []

  | T.Var t1, t2
  | t2, T.Var t1 ->
      [(t1, t2)]

  | T.Arrow (t11, t12), T.Arrow (t21, t22) ->
      let s1 = unify (t11, t21) in
      let s2 = unify (apply s1 t12, apply s1 t22) in
      s2 >> s1

  | T.TypeArrow (v11, t12), T.Arrow (t21, t22)
  | T.Arrow (t21, t22), T.TypeArrow (v11, t12) ->
      let s1 = [(v11, t21)] in
      let s2 = unify (apply s1 t12, apply s1 (T.Arrow(t21, t22))) in
      s2 >> s1

  | T.TypeArrow (v11, t12), T.TypeArrow (v21, t22) ->
      let s1 = [(v11, T.Var v21)] in
      let s2 = unify (apply s1 t12, apply s1 t22) in
      s2 >> s1

  | t1, t2 ->
      let msg = Printf.sprintf "Failed to unify %s with %s"
        (T.to_string t1) (T.to_string t2)
      in raise (UnificationError msg)

let check_literal = function
  | Int _ -> ty_int

let rec instantiate s1 = function
  | T.TypeArrow (var, ty) ->
      let T.TV (_, name) = var in
      let var' = new_var name in
      T.TypeArrow (var', instantiate ([(var, T.Var var')] >> s1) ty)
  | T.Arrow (t1, t2) ->
      T.Arrow (instantiate s1 t1, instantiate s1 t2)
  | t -> apply s1 t

let get_type env v =
  try instantiate [] (List.assoc v env)
  with Not_found ->
    raise (TypeError "Unknown Type")

let rec check_type env : type_ -> T.ty = function
  | Con t -> get_type env t
  | Arrow (parameters, return_type) ->
      let ret = check_type env return_type in
      let fn_type = List.fold_right
        (fun p t -> T.Arrow (check_type env p, t))
        parameters ret
      in fn_type

let rec check_fn env { fn_name; fn_generics; fn_parameters; fn_return_type; fn_body } =
  let generics = match fn_generics with
  | Some g -> g
  | None -> []
  in

  let generics' = List.map (fun g -> new_var g.name) generics in
  let env' = List.fold_left
    (fun env (g, v : generic * T.tvar) -> extend_env env (g.name, T.Var v))
    env (List.combine generics generics')
  in

  let ret_type = check_type env' fn_return_type in

  let (fn_type, env'') = List.fold_right
    (fun p (t, env'') ->
      let ty = check_type env' p.param_type in
      (T.Arrow (ty , t), extend_env env'' (p.param_name, ty)))
    fn_parameters (ret_type, env)
  in
  let fn_type' = match fn_type with
  | T.Arrow _ -> fn_type
  | _ -> T.Arrow (ty_unit, fn_type)
  in
  let fn_type'' = List.fold_right (fun g t -> T.TypeArrow (g, t)) generics' fn_type' in

  let (ret, _, s1) = check_exprs env'' fn_body in
  let s2 = unify (ret, ret_type) in
  let fn_type'' = apply (s2 >> s1) fn_type'' in

  match fn_name with
  | Some n -> (fn_type'', extend_env env (n, fn_type''), s2 >> s1)
  | None -> (fn_type'', env, s2 >> s1)

and check_generic_application env (callee, generic_arguments, arguments) =
  let generic_arguments = match generic_arguments with
  | Some g -> g
  | None -> []
  and arguments = match arguments with
  | None -> []
  | Some [] -> [Unit]
  | Some args -> args
  in

  let (ty_callee, _, s1) = check_expr env callee in
  let gen_args = List.map (check_type env) generic_arguments in

  let check_type (call, s) g =
    match call with
    | T.TypeArrow (g', tail) ->
        (tail, [(g', g)] >> s)
    | _ -> raise (TypeError "Invalid type for generic application")
  and check (call, s1) argument =
    let (ty_arg, _, s2) = check_expr env argument in
    let rec check s3 ty =
      match ty with
      | T.Arrow (t1, t2) ->
          let s4 = unify (apply (s2 >> s1) t1, ty_arg) in
          (t2, s4 >> s3)
      | T.TypeArrow (v1, t2) ->
          let s4 = unify (apply s3 (T.Var v1), ty_arg) in
          check (s4 >> s3) t2
      | _ -> raise (TypeError "Invalid type for function call")
    in
    check (s2 >> s1) call
  in
  let ty, s2 = List.fold_left check_type (ty_callee, s1) gen_args in
  let ty', s3 = List.fold_left check (apply s2 ty, s2) arguments in
  (ty', env, s3)

and check_app env { callee; generic_arguments; arguments } =
  check_generic_application env (callee, generic_arguments, Some arguments)

and check_ctor env { ctor_name; ctor_generic_arguments; ctor_arguments } =
  check_generic_application env (Var ctor_name, ctor_generic_arguments, ctor_arguments)

and check_expr env : expr -> T.ty * ty_env * subst = function
  | Unit -> (ty_unit, env, [])
  | Literal l -> (check_literal l, env, [])
  | Var v -> (get_type env v, env, [])
  | Function fn -> check_fn env fn
  | Application app -> check_app env app
  | Ctor ctor -> check_ctor env ctor

and check_exprs env exprs =
  List.fold_left
    (fun (_, env, s1) node ->
      let ty, env', s2 = check_expr env node in
      (ty, env', s2 >> s1))
    (ty_unit, env, []) exprs

and check_enum_item enum_ty env { enum_item_name; enum_item_parameters } =
  match enum_item_parameters with
  | None -> extend_env env (enum_item_name, enum_ty)
  | Some ps ->
      let aux p enum_ty =
        let t = check_type env p in
        T.Arrow (t, enum_ty)
      in
      let ty = List.fold_right aux ps enum_ty in
      extend_env env (enum_item_name, ty)

and check_enum env { enum_name; enum_items } =
  let enum_ty = T.Type enum_name in
  let env' = extend_env env (enum_name, enum_ty) in
  let env'' = List.fold_left (check_enum_item enum_ty) env' enum_items in
  (ty_type, env'', [])

and check_decl env = function
  | Expr expr -> check_expr env expr
  | Enum enum -> check_enum env enum

and check_decls env decls =
  List.fold_left
    (fun (_, env, s1) node ->
      let ty, env', s2 = check_decl env node in
      (ty, env', s2 >> s1))
    (ty_unit, env, []) decls

let check program =
  let ty, _, s = check_decls default_env program.body in
  apply s ty