open Debug_protocol_ex
module Dap_breakpoint = Debug_protocol_ex.Breakpoint
module Dap_stack_frame = Debug_protocol_ex.Stack_frame

let run ~launch_args ~terminate ~agent rpc =
  ignore launch_args;
  ignore terminate;
  Lwt.pause ();%lwt
  Debug_rpc.set_command_handler rpc
    (module Continue_command)
    (fun _ ->
      Ocaml_debug_agent.run agent;
      Lwt.return
        Continue_command.Result.(make ~all_threads_continued:(Some true) ()));
  Debug_rpc.set_command_handler rpc
    (module Pause_command)
    (fun _ ->
      Ocaml_debug_agent.pause agent;
      Lwt.return ());
  Lwt.return ()
