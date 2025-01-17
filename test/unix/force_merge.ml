open Common

let root = Filename.concat "_tests" "unix.force_merge"

module Context = Common.Make_context (struct
  let root = root
end)

let test_find_present t tbl =
  Hashtbl.iter
    (fun k v ->
      match Index.find t k with
      | res ->
          if not (res = v) then
            Alcotest.fail "Replacing existing value failed."
      | exception Not_found ->
          Alcotest.failf "Inserted value is not present anymore: %s." k)
    tbl

let test_one_entry r k v =
  match Index.find r k with
  | res ->
      if not (res = v) then Alcotest.fail "Replacing existing value failed."
  | exception Not_found ->
      Alcotest.failf "Inserted value is not present anymore: %s." k

let test_fd () =
  let ( >>? ) x f = match x with `Ok x -> f x | err -> err in
  (* TODO: fix these tests to take the correct directory name
           (and not break when given the wrong one) *)
  let name = "/tmp/empty" in
  (* construct an index at a known location *)
  let pid = string_of_int (Unix.getpid ()) in
  let fd_file = "tmp" in
  let lsof_command = "lsof -a -s -p " ^ pid ^ " > " ^ fd_file in
  let result =
    ( match Sys.os_type with
    | "Unix" -> `Ok ()
    | _ -> `Skip "non-UNIX operating system" )
    >>? fun () ->
    ( match Unix.system lsof_command with
    | Unix.WEXITED 0 -> `Ok ()
    | Unix.WEXITED _ ->
        `Skip "failing `lsof` command. Is `lsof` installed on your system?"
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
        Alcotest.fail "`lsof` command was interrupted" )
    >>? fun () ->
    let lines = ref [] in
    let extract_fd line =
      try
        let pos = Re.Str.search_forward (Re.Str.regexp name) line 0 in
        let fd = Re.Str.string_after line pos in
        lines := fd :: !lines
      with Not_found -> ()
    in
    let ic = open_in fd_file in
    let lines =
      ( try
          while true do
            extract_fd (input_line ic)
          done
        with End_of_file -> close_in ic );
      !lines
    in
    let contains sub s =
      try
        ignore (Re.Str.search_forward (Re.Str.regexp sub) s 0);
        true
      with Not_found -> false
    in
    let data, rs = List.partition (contains "data") lines in
    if List.length data > 2 then
      Alcotest.fail "Too many file descriptors opened for data files";
    let log, rs = List.partition (contains "log") rs in
    if List.length log > 2 then
      Alcotest.fail "Too many file descriptors opened for log files";
    let lock, rs = List.partition (contains "lock") rs in
    if List.length lock > 2 then
      Alcotest.fail "Too many file descriptors opened for lock files";
    if List.length rs > 0 then Alcotest.fail "Unknown file descriptors opened";
    `Ok ()
  in
  match result with
  | `Ok () -> ()
  | `Skip err -> Log.warn (fun m -> m "`test_fd` was skipped: %s" err)

let readonly_s () =
  let { Context.tbl; clone; _ } = Context.full_index () in
  let r1 = clone ~readonly:true in
  let r2 = clone ~readonly:true in
  let r3 = clone ~readonly:true in
  test_find_present r1 tbl;
  test_find_present r2 tbl;
  test_find_present r3 tbl;
  test_fd ()

let readonly () =
  let { Context.tbl; clone; _ } = Context.full_index () in
  let r1 = clone ~readonly:true in
  let r2 = clone ~readonly:true in
  let r3 = clone ~readonly:true in
  Hashtbl.iter
    (fun k v ->
      test_one_entry r1 k v;
      test_one_entry r2 k v;
      test_one_entry r3 k v)
    tbl;
  test_fd ()

let readonly_and_merge () =
  let { Context.rw; clone; _ } = Context.full_index () in
  let w = rw in
  let r1 = clone ~readonly:true in
  let r2 = clone ~readonly:true in
  let r3 = clone ~readonly:true in
  let interleave () =
    let k1 = Key.v () in
    let v1 = Value.v () in
    Index.replace w k1 v1;
    Index.force_merge w;
    test_one_entry r1 k1 v1;
    test_one_entry r2 k1 v1;
    test_one_entry r3 k1 v1;

    let k2 = Key.v () in
    let v2 = Value.v () in
    Index.replace w k2 v2;
    test_one_entry r1 k1 v1;
    Index.force_merge w;
    test_one_entry r2 k2 v2;
    test_one_entry r3 k1 v1;

    let k2 = Key.v () in
    let v2 = Value.v () in
    let k3 = Key.v () in
    let v3 = Value.v () in
    test_one_entry r1 k1 v1;
    Index.replace w k2 v2;
    Index.force_merge w;
    test_one_entry r1 k1 v1;
    Index.replace w k3 v3;
    Index.force_merge w;
    test_one_entry r3 k3 v3;

    let k2 = Key.v () in
    let v2 = Value.v () in
    Index.replace w k2 v2;
    test_one_entry w k2 v2;
    Index.force_merge w;
    test_one_entry w k2 v2;
    test_one_entry r2 k2 v2;
    test_one_entry r3 k1 v1;

    let k2 = Key.v () in
    let v2 = Value.v () in
    Index.replace w k2 v2;
    test_one_entry r2 k1 v1;
    Index.force_merge w;
    test_one_entry w k2 v2;
    test_one_entry r2 k2 v2;
    test_one_entry r3 k2 v2
  in
  let rec loop i =
    if i = 0 then ()
    else (
      interleave ();
      loop (i - 1) )
  in
  loop 10;
  test_fd ()

let tests =
  [
    ("readonly in sequence", `Quick, readonly_s);
    ("readonly interleaved", `Quick, readonly);
    ("interleaved merge", `Quick, readonly_and_merge);
  ]

(* Unix.sleep 10 *)
(* for `ps aux | grep force_merge` and `lsof -a -s -p pid` *)
