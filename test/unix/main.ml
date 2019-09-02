let reporter ?(prefix = "") () =
  let report src level ~over k msgf =
    let k _ =
      over ();
      k ()
    in
    let ppf = match level with Logs.App -> Fmt.stdout | _ -> Fmt.stderr in
    let with_stamp h _tags k fmt =
      let dt = Unix.gettimeofday () in
      Fmt.kpf k ppf
        ("%s%+04.0fus %a %a @[" ^^ fmt ^^ "@]@.")
        prefix dt
        Fmt.(styled `Magenta string)
        (Logs.Src.name src) Logs_fmt.pp_header (level, h)
    in
    msgf @@ fun ?header ?tags fmt -> with_stamp header tags k fmt
  in
  { Logs.report }

let string_size = 20

let index_size = 103

let () = Random.self_init ()

let random_char () = char_of_int (33 + Random.int 94)

let random_string () = String.init string_size (fun _i -> random_char ())

module Key = struct
  type t = string

  let v = random_string

  let hash = Hashtbl.hash

  let hash_size = 30

  let encode s = s

  let decode s off = String.sub s off string_size

  let encoded_size = string_size

  let equal = String.equal

  let pp s = Fmt.fmt "%s" s
end

module Value = struct
  type t = string

  let v = random_string

  let encode s = s

  let decode s off = String.sub s off string_size

  let encoded_size = string_size

  let pp s = Fmt.fmt "%s" s
end

module Index = Index_unix.Make (Key) (Value)

let index_name = Filename.concat "_tests" "index-unix"

let log_size = 4

let page_size = 2

let pool_size = 2

let t = Index.v ~fresh:true ~log_size index_name

(* [tbl] is the in-memory representation of the [t], i.e. tbl should always
contain the same elements as [t] *)
let tbl =
  let tbl = Hashtbl.create 0 in
  let rec loop i =
    if i = 0 then (
      Index.flush t;
      tbl )
    else
      let k = Key.v () in
      let v = Value.v () in
      Index.replace t k v;
      Hashtbl.replace tbl k v;
      loop (i - 1)
  in
  loop index_size

let rec random_new_key () =
  let r = Key.v () in
  if Hashtbl.mem tbl r then random_new_key () else r

let test_find_present t =
  Hashtbl.iter
    (fun k v ->
      match Index.find t k with
      | exception Not_found ->
          Alcotest.fail
            (Printf.sprintf "Wrong insertion: %s key is missing." k)
      | v' ->
          if not (v = v') then
            Alcotest.fail
              (Printf.sprintf "Wrong insertion: %s value is missing." v))
    tbl

let test_find_absent t =
  let rec loop i =
    if i = 0 then ()
    else
      let k = random_new_key () in
      Alcotest.check_raises (Printf.sprintf "Absent value was found: %s." k)
        Not_found (fun () -> ignore (Index.find t k));
      loop (i - 1)
  in
  loop index_size

let test_replace t =
  let k = Key.v () in
  let v = Value.v () in
  let v' = Value.v () in
  Index.replace t k v;
  Hashtbl.replace tbl k v;
  Index.replace t k v';
  Hashtbl.replace tbl k v';
  match Index.find t k with
  | res ->
      if not (res = v') then
        Alcotest.fail (Printf.sprintf "Replacing existing value failed.")
  | exception Not_found ->
      Alcotest.fail
        (Printf.sprintf "Inserted value is not present anymore: %s." k)

let different_size_for_key () =
  let k = String.init 2 (fun _i -> random_char ()) in
  let v = Value.v () in
  let exn = Index.Invalid_key_size k in
  Alcotest.check_raises
    "Cannot add a key of a different size than string_size." exn (fun () ->
      Index.replace t k v)

let different_size_for_value () =
  let k = Key.v () in
  let v = String.init 200 (fun _i -> random_char ()) in
  let exn = Index.Invalid_value_size v in
  Alcotest.check_raises
    "Cannot add a value of a different size than string_size." exn (fun () ->
      Index.replace t k v)

let find_present_live () = test_find_present t

let find_absent_live () = test_find_absent t

let find_present_restart () =
  test_find_present (Index.v ~fresh:false ~log_size index_name)

let find_absent_restart () =
  test_find_absent (Index.v ~fresh:false ~log_size index_name)

let replace_live () = test_replace t

let replace_restart () =
  test_replace (Index.v ~fresh:false ~log_size index_name)

let readonly () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size index_name in
  let r = Index.v ~fresh:false ~readonly:true ~log_size index_name in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  Index.flush w;
  Hashtbl.iter
    (fun k v ->
      match Index.find r k with
      | res ->
          if not (res = v) then
            Alcotest.fail
              (Printf.sprintf "Wrong insertion: %s value is missing." v)
      | exception Not_found ->
          Alcotest.fail
            (Printf.sprintf "Wrong insertion: %s key is missing." k))
    tbl

let close_reopen_rw () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test1" in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  Index.close w;
  let w = Index.v ~fresh:false ~readonly:false ~log_size "test1" in
  test_find_present w;
  Index.close w

let open_readonly_close_rw () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test2" in
  let r = Index.v ~fresh:false ~readonly:true ~log_size "test2" in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  Index.close w;
  test_find_present r;
  Index.close r

let close_reopen_readonly () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test3" in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  Index.close w;
  let r = Index.v ~fresh:false ~readonly:true ~log_size "test3" in
  test_find_present r;
  Index.close r

let test_read_after_close t k =
  test_find_present t;
  Index.close t;
  match Index.find t k with
  | exception Not_found -> ()
  | _ -> Alcotest.fail "Read after close returns a value."

let test_read_after_close_readonly t k =
  test_find_present t;
  Index.close t;
  let exn = Unix.Unix_error (Unix.EBADF, "read", "") in
  Alcotest.check_raises "Cannot read in readonly index after close." exn
    (fun () -> ignore (Index.find t k))

let fail_read_after_close () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test4" in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  let k = Key.v () in
  let v = Value.v () in
  Index.replace w k v;
  test_read_after_close w k

let fail_write_after_close () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test5" in
  Index.close w;
  let k, v = (Key.v (), Value.v ()) in
  (* a single add does not fail*)
  Index.replace w k v;
  let exn = Unix.Unix_error (Unix.EBADF, "read", "") in
  Alcotest.check_raises "Cannot write in index after close." exn (fun () ->
      Hashtbl.iter (fun k v -> Index.replace w k v) tbl)

let open_twice () =
  let w1 = Index.v ~fresh:true ~readonly:false ~log_size "test6" in
  let w2 = Index.v ~fresh:true ~readonly:false ~log_size "test6" in
  Hashtbl.iter (fun k v -> Index.replace w1 k v) tbl;
  let k = Key.v () in
  let v = Value.v () in
  Index.replace w1 k v;
  Index.close w1;

  (* while another instance is still open, read does not fail*)
  test_find_present w1;
  test_read_after_close w2 k

let open_twice_readonly () =
  let w = Index.v ~fresh:true ~readonly:false ~log_size "test7" in
  Hashtbl.iter (fun k v -> Index.replace w k v) tbl;
  let k = Key.v () in
  let v = Value.v () in
  Index.replace w k v;
  Index.close w;
  let r1 = Index.v ~fresh:false ~readonly:true ~log_size "test7" in
  let r2 = Index.v ~fresh:false ~readonly:true ~log_size "test7" in
  test_find_present r1;
  Index.close r1;
  test_read_after_close_readonly r2 k

let live_tests =
  [
    ("find (present)", `Quick, find_present_live);
    ("find (absent)", `Quick, find_absent_live);
    ("replace", `Quick, replace_live);
    ("fail add (key)", `Quick, different_size_for_key);
    ("fail add (value)", `Quick, different_size_for_value);
  ]

let restart_tests =
  [
    ("find (present)", `Quick, find_present_restart);
    ("find (absent)", `Quick, find_absent_restart);
    ("replace", `Quick, replace_restart);
  ]

let readonly_tests = [ ("add", `Quick, readonly) ]

let close_tests =
  [
    ("close and reopen", `Quick, close_reopen_rw);
    ("open two instances, close one", `Quick, open_readonly_close_rw);
    ("close and reopen on readonly", `Quick, close_reopen_readonly);
    ("fail to read after close", `Quick, fail_read_after_close);
    ("fail to write after close", `Quick, fail_write_after_close);
    ("open twice same instance", `Quick, open_twice);
    ("open twice same instance readonly", `Quick, open_twice_readonly);
  ]

let () =
  Logs.set_level (Some Logs.Debug);
  Logs.set_reporter (reporter ());
  Alcotest.run "index"
    [
      ("live", live_tests);
      ("on restart", restart_tests);
      ("readonly", readonly_tests);
      ("close", close_tests);
    ]
