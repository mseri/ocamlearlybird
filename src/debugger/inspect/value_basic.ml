open Ground
open Errors
open Debug_types

class virtual value =
  object
    method virtual to_short_string : string

    method vscode_menu_context : string option = None

    method closure_code_location : source_range option = None

    method num_indexed = 0

    method num_named = 0

    method get_indexed (_idx : int) : value Lwt.t = raise Index_out_of_bound

    method list_named : (string * value) list Lwt.t = Lwt.return []
  end

let uninitialized_value =
  object
    inherit value

    method to_short_string = "«uninitialized»"
  end

let unknown_value =
  object
    inherit value

    method to_short_string = "«opaque»"
  end

class raw_string_value v =
  object
    inherit value

    method to_short_string = v
  end

class tips_value tips =
  object
    inherit value

    method to_short_string = "…"

    method! num_indexed = Array.length tips

    method! get_indexed i = new raw_string_value tips.(i) |> Lwt.return
  end

let adopters =
  ref
    ([]
      : (Scene.t ->
        Typenv.t ->
        Scene.obj ->
        Types.type_expr ->
        value option Lwt.t)
        list)

let dyn_adopter: (Scene.t -> Scene.obj -> value Lwt.t) ref =
  ref (fun _scene _obj -> Lwt.return unknown_value)

let dyn_adopt scene obj =
  (!dyn_adopter) scene obj

let adopt scene typenv obj ty =
  let rec resolve_type ty =
    match Types.get_desc ty with
    | Tlink ty | Tpoly (ty, _) -> resolve_type ty
    | Tsubst ty [@if ocaml_version < (4, 13, 0)] -> resolve_type ty
    | Tsubst (ty, _) [@if ocaml_version >= (4, 13, 0)] -> resolve_type ty
    | Tconstr (path, ty_args, _) -> (
        match Typenv.find_type path typenv with
        | exception Not_found -> ty
        | {
         type_kind = Type_abstract;
         type_manifest = Some body;
         type_params;
         _;
        } -> (
            match Typenv.type_apply typenv type_params body ty_args with
            | ty -> resolve_type ty
            | exception Ctype.Cannot_apply -> ty)
        | _ -> ty)
    | _ -> ty
  in
  let ty = resolve_type ty in
  try%lwt
    !adopters |> List.to_seq
    |> Lwt_seq.find_map_s (fun adopter -> adopter scene typenv obj ty)
  with Not_found -> dyn_adopt scene obj
