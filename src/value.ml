module A = Absyn

type value =
  | Unit
  | Literal of A.literal
  | Ctor of value A.ctor
  | Type of string
  | Function of A.function_
  | InterfaceFunction of string
  | Record of (string * value) list

let rec expr_of_value = function
  | Unit -> A.Unit
  | Literal l -> A.Literal l
  | Ctor c ->
    let args = match c.A.ctor_arguments with
      | None -> None
      | Some args -> Some (List.map expr_of_value args)
    in A.Ctor { c with A.ctor_arguments = args }
  | Function f -> A.Function f
  | InterfaceFunction i -> A.Var i
  | Record r -> A.Record (List.map (fun (n,v) -> (n, expr_of_value v)) r)
  | Type _ -> assert false (* can't be converted *)
