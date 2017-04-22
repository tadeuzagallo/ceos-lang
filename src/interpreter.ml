open Absyn

module V = Value

exception Unbound_variable
exception Runtime_error of string

let rec combine (subst, params) : parameter list * expr list -> 'a * 'b = function
  | x::xs, y::ys ->
      combine ((x.param_name,y)::subst, params) (xs, ys)
  | x::xs, [] ->
      combine (subst, x::params) (xs, [])
  | [], [] ->
      (List.rev subst, List.rev params)
  | [], _ ->
      raise (Runtime_error "Function applied to too many arguments")

let rec subst_expr args = function
  | Unit -> Unit
  | Literal l -> Literal l
  | Var x as v -> begin
      try List.assoc x args
      with Not_found -> v
  end
  | Application ({ callee; arguments } as app) ->
      let callee = subst_expr args callee in
      let arguments = List.map (subst_expr args) arguments in
      Application { app with callee; arguments }

  | Function ({ fn_parameters; fn_body } as fn) ->
      let filter (x, _) =  not (List.exists (fun p -> p.param_name = x) fn_parameters) in
      let args' = List.filter filter args in
      let body = List.map (subst_expr args') fn_body in
      Function { fn with fn_body=body }
  | Ctor ({ ctor_arguments } as ctor) ->
      let ctor_arguments = match ctor_arguments with
        | None -> None
        | Some cargs -> Some (List.map (subst_expr args) cargs)
      in Ctor { ctor with ctor_arguments }

let subst arguments fn =
  let { fn_parameters; fn_body } as fn = match fn with
    | V.Function f -> f
    | _ -> assert false
  in
  let subst, params = combine ([], []) (fn_parameters, arguments) in
  let body' = List.rev_map (subst_expr subst) fn_body in
  match params, body' with
  | [], [] -> Unit
  | [], _ -> List.hd body'
  | _ -> Function { fn with fn_parameters = params; fn_body = body' }

let rec eval_expr env = function
  | Unit -> (V.Unit, env)
  | Ctor c -> (V.Ctor c, env)
  | Literal l -> (V.Literal l, env)
  | Application { callee; generic_arguments; arguments } ->
      let (callee', _) = eval_expr env callee in
      let arguments' = List.map (fun a -> V.expr_of_value @@ fst @@ eval_expr env a) arguments in
      let (v, _) = eval_expr env (subst arguments' callee') in
      (v, env)
  | Var v -> begin
      try (List.assoc v env, env)
      with Not_found ->
        raise Unbound_variable
  end
  | Function ({ fn_name; fn_parameters; fn_body } as fn) ->
      let fn' = V.Function fn in
      match fn_name with
      | Some n -> (fn', (n, fn')::env)
      | None -> (fn', env)

and eval_decl env = function
  | Expr expr -> eval_expr env expr
  | Enum { enum_name } -> (V.Type enum_name, env)
  | Interface { intf_name; intf_functions } ->
      let aux env { proto_name } =
        (proto_name, V.Unit)::env
      in
      let env' = List.fold_left aux env intf_functions in
      (V.Type intf_name, env')
  | Implementation { impl_name } ->
      (V.Type impl_name, env)

let eval { body } =
  List.fold_left (fun (_, env) node -> eval_decl env node) (V.Unit, []) body
  |> fst
