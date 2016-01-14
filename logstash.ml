open Printf
open ExtLib
open Prelude

let log = Log.from "logstash"

let state = Hashtbl.create 10

let escape k =
  if String.contains k ' ' then
    String.map (function ' ' -> '_' | c -> c) k
  else
    k

let zero = Var.(function Count _ -> Count 0 | Time _ -> Time 0. | Bytes _ -> Bytes 0)

let common_fields () =
  [
    "timestamp_ms", `Int (int_of_float @@ Time.now () *. 1000.);
    "pid", `String (Pid.show_self ());
  ]

let get () =
  let l = ref [] in
  Var.iter begin fun attr v ->
    let (previous,attr) =
      try Hashtbl.find state attr with
      | Not_found -> let x = ref (zero v), List.map (fun (k, s) -> escape k, `String s) attr in Hashtbl.add state attr x; x
    in
    let this = (common_fields () @ attr
      :  (string * [ `Floatlit of string | `Int of int | `String of string]) list
      :> (string * [>`Floatlit of string | `Int of int | `String of string]) list)
    in
    match v, !previous with
    | Count x, Count x' ->
      let delta = x - x' in
      if delta <> 0 then begin previous := v; tuck l @@ `Assoc (("count", `Int delta) :: this) end
    | Bytes x, Bytes x' ->
      let delta = x - x' in
      if delta <> 0 then begin previous := v; tuck l @@ `Assoc (("bytes", `Int delta) :: this) end
    | Time x, Time x' ->
      let delta = x -. x' in
      if delta > epsilon_float then begin previous := v; tuck l @@ `Assoc (("seconds", `Floatlit (sprintf "%g" delta)) :: this) end
    | Count _, Bytes _ | Count _, Time _
    | Bytes _, Count _ | Bytes _, Time _
    | Time _, Count _ | Time _, Bytes _ -> () (* cannot happen *)
  end;
  !l


let basename_of_file logfile =
  try Filename.chop_extension logfile with _ -> logfile

let open_logstash basename =
  let filename = sprintf "%s.%s.json" basename (Time.format_date8 @@ Unix.gmtime @@ Time.now ()) in
  try
    Files.open_out_append_text filename
  with exn -> Exn.fail ~exn "failed to open stats file %s" filename

module J = Yojson

let write_json out nr json =
  let bytes = J.to_string ~std:true json ^ "\n" in
  try
    if (String.length bytes > 4096 - !nr) then (flush out; nr := 0);
    output_string out bytes; nr := !nr + String.length bytes
  with exn -> log #warn ~exn "failed to write event %S" bytes

let line_writer out =
  let nr = ref 0 in
  write_json out nr

let setup_ ?(pause=Time.seconds 60) setup =
  match !Daemon.logfile with
  | None -> log #warn "no logfile, disabling logstash stats too"
  | Some logfile ->
    let stat_basename = basename_of_file logfile in
    log #info "will output logstash stats to %s.YYYYMMDD.json" stat_basename;
    setup pause begin fun () ->
      match open_logstash stat_basename with
      | exception exn -> log #warn ~exn "no output file, disabling"
      | ch ->
        Control.bracket ch close_out_noerr begin fun ch ->
          let write = line_writer ch in
          get () |> List.iter write; flush ch
        end
    end

let setup ?pause events = setup_ ?pause (fun pause f -> Async.setup_periodic_timer_wait events pause f)
let setup_lwt ?pause () =
  setup_ ?pause (fun pause f ->
    let rec loop () =
      match Daemon.should_exit () with
      | true -> Lwt.return_unit
      | false -> Lwt.bind (Lwt_unix.sleep pause) (fun () -> f (); loop ())
    in
    Lwt.async loop
  )


let is_same_day timestamp =
  Time.now () -. Time.days 1 < timestamp

let null = object method event _j = () end

let log' () =
  match !Daemon.logfile with
  | None ->
    log #info "no logfile, disable"; null
  | Some name ->
    try
      let basename = try Filename.chop_extension name with _ -> name in
      let out = open_logstash basename in
      log #info "will ouput log to %s" name;
      object
        val mutable timestamp = Time.now ()
        val mutable out = out
        val nr = ref 0
        method event (j : (string * [< `String of string | `Int of int]) list) =
          let () =
            (* try rotate *)
            match timestamp with
            | t when not @@ is_same_day t ->
              begin try
                  log #info "rotate log";
                  let new_fd = open_logstash basename in
                  let prev = out in
                  out <- new_fd;
                  nr := 0;
                  timestamp <- Time.now ();
                  flush prev;
                  close_out_noerr prev
                with exn -> log #warn ~exn "failed to rotate log" end
            | _ -> ()
          in
          let json = `Assoc (common_fields () @ (j :> (string * J.json) list)) in
          write_json out nr json
      end
    with exn -> log #warn ~exn "output disable"; null

let log () =
  let log = Lazy.from_fun log' in
  object
    method event j = !!log #event j
  end
