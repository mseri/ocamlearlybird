open Debugcom
open Inspect_types
open Symbols

type t = {
  index : int;
  stack_pos : int;
  module_ : Symbols.Module.t;
  event : Instruct.debug_event;
  mutable scopes : obj list;
  env : Env.t Lazy.t;
}

let stacksize t = t.event.ev_stacksize

let defname t = t.event.ev_defname

let module_ t = t.module_

let pc t = { frag = (Module.frag t.module_); pos = t.event.ev_pos }

let loc t =
  if t.index = 0 then
    let pos = Debug_event.lexing_position t.event in
    Location.{ loc_start = pos; loc_end = pos; loc_ghost = false }
  else t.event.ev_loc
