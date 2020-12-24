type conn = { io_in : Lwt_io.input_channel; io_out : Lwt_io.output_channel }

let iter_seq_s f seq =
  Seq.fold_left (fun prev_promise elt ->
    let%lwt () = prev_promise in
    f elt
  ) (Lwt.return ()) seq

let chdir_lock = Lwt_mutex.create ()

let with_chdir ~cwd fn =
  Lwt_mutex.with_lock chdir_lock (fun () ->
      let%lwt cwd' = Lwt_unix.getcwd () in
      Lwt_unix.chdir cwd;%lwt
      (fn ()) [%finally Lwt_unix.chdir cwd'])

let loop_read in_chan f =
  let action da =
    let open Lwt_io in
    let break = ref false in
    while%lwt not !break do
      if da.da_ptr < da.da_max then (
        let content =
          Lwt_bytes.proxy da.da_buffer da.da_ptr (da.da_max - da.da_ptr)
        in
        da.da_ptr <- da.da_max;
        let content = Lwt_bytes.to_string content in
        f content )
      else
        let%lwt size = da.da_perform () in
        if size = 0 then break := true;
        Lwt.return_unit
    done
  in
  Lwt_io.direct_access in_chan action

let getstringsockname sock =
  let addr = Lwt_unix.getsockname sock in
  match addr with
  | Unix.ADDR_UNIX addr -> addr
  | Unix.ADDR_INET (addr, port) ->
      Unix.string_of_inet_addr addr ^ ":" ^ string_of_int port

let read_nativeint_be in_ =
  if Sys.word_size = 64 then
    let%lwt word = Lwt_io.BE.read_int64 in_ in
    Lwt.return (Int64.to_nativeint word)
  else
    let%lwt word = Lwt_io.BE.read_int32 in_ in
    Lwt.return (Nativeint.of_int32 word)

let write_nativeint_be out n =
  if Sys.word_size = 64 then
    let word = Int64.of_nativeint n in
    Lwt_io.BE.write_int64 out word
  else
    let word = Nativeint.to_int32 n in
    Lwt_io.BE.write_int32 out word

let read_to_string_exactly ic count =
  let buf = Bytes.create count in
  Lwt_io.read_into_exactly ic buf 0 count;%lwt
  Lwt.return (Bytes.to_string buf)

let resolve_in_dirs fname dirs =
  let rec rec_resolve fname dirs =
    match dirs with
    | dir :: dirs ->
        let path = dir ^ "/" ^ fname in
        if%lwt Lwt_unix.file_exists path then Lwt.return (Some path)
        else rec_resolve fname dirs
    | [] -> Lwt.return None
  in
  rec_resolve fname dirs

let memo (type k v) ?(hashed = (Hashtbl.hash, ( = ))) ?(weight = fun _ -> 1)
    ~cap f =
  let module Hashed = struct
    type t = k

    let hash = fst hashed

    let equal = snd hashed
  end in
  let module Weighted = struct
    type t = v

    let weight = weight
  end in
  let module PC = Hashtbl.Make (Hashed) in
  let module C = Lru.M.Make (Hashed) (Weighted) in
  let pc = PC.create 0 in
  let c = C.create cap in
  let rec g k =
    match C.find k c with
    | Some v ->
        C.promote k c;
        Lwt.return v
    | None -> (
        match PC.find_opt pc k with
        | Some p -> p
        | None ->
            let p = f g k in
            PC.replace pc k p;
            let%lwt v = p in
            C.add k v c;
            PC.remove pc k;
            Lwt.return v )
  in
  g

let file_content_and_bols =
  let weight (content, _bols) = String.length content in
  memo ~weight
    ~cap:(32 * 1024 * 1024)
    (fun _rec source ->
      let%lwt ic = Lwt_io.open_file ~mode:Lwt_io.input source in
      let%lwt code = Lwt_io.read ic in
      let bols = ref [ 0 ] in
      for i = 0 to String.length code - 1 do
        if code.[i] = '\n' then bols := (i + 1) :: !bols
      done;
      let bols = !bols |> List.rev |> Array.of_list in
      Lwt.return (code, bols))

let digest_file =
  memo ~weight:String.length ~cap:(64 * 1024) (fun _rec path ->
      Lwt_preemptive.detach (fun path -> Digest.file path) path)

(* This function is needed while Lwt_mvar.take_available may results mvar is still full *)
let take_mvar_nonblocking var =
  if not (Lwt_mvar.is_empty var) then
    Lwt_mvar.take var
  else
    Lwt.return ()
