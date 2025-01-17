module Private = struct
  module Fan = Fan
  module Io_array = Io_array
  module Search = Search
end

module type Key = sig
  type t

  val equal : t -> t -> bool

  val hash : t -> int

  val hash_size : int

  val encode : t -> string

  val encoded_size : int

  val decode : string -> int -> t

  val pp : t Fmt.t
end

module type Value = sig
  type t

  val encode : t -> string

  val encoded_size : int

  val decode : string -> int -> t

  val pp : t Fmt.t
end

module type IO = Io.S

module type S = sig
  type t

  type key

  type value

  val v : ?fresh:bool -> ?readonly:bool -> log_size:int -> string -> t

  val clear : t -> unit

  val find : t -> key -> value

  val mem : t -> key -> bool

  exception Invalid_key_size of key

  exception Invalid_value_size of value

  val replace : t -> key -> value -> unit

  val iter : (key -> value -> unit) -> t -> unit

  val force_merge : t -> unit

  val flush : t -> unit

  val close : t -> unit
end

let may f = function None -> () | Some bf -> f bf

let assert_and_get = function None -> assert false | Some e -> e

exception RO_not_allowed

exception Closed

module Make (K : Key) (V : Value) (IO : IO) = struct
  type key = K.t

  type value = V.t

  type entry = { key : key; key_hash : int; value : value }

  let entry_size = K.encoded_size + V.encoded_size

  let entry_sizeL = Int64.of_int entry_size

  exception Invalid_key_size of key

  exception Invalid_value_size of value

  let append_key_value io key value =
    let encoded_key = K.encode key in
    let encoded_value = V.encode value in
    if String.length encoded_key <> K.encoded_size then
      raise (Invalid_key_size key);
    if String.length encoded_value <> V.encoded_size then
      raise (Invalid_value_size value);
    IO.append io encoded_key;
    IO.append io encoded_value

  let decode_entry bytes off =
    let string = Bytes.unsafe_to_string bytes in
    let key = K.decode string off in
    let value = V.decode string (off + K.encoded_size) in
    { key; key_hash = K.hash key; value }

  module Tbl = Hashtbl.Make (K)

  type config = { log_size : int; readonly : bool; fresh : bool }

  type index = { io : IO.t; fan_out : Fan.t }

  type log = { io : IO.t; mem : value Tbl.t }

  type instance = {
    config : config;
    root : string;
    mutable generation : int64;
    mutable index : index option;
    mutable log : log option;
    mutable open_instances : int;
    lock : IO.lock option;
  }

  type t = instance option ref

  let check_open t =
    match !t with Some instance -> instance | None -> raise Closed

  let clear t =
    let t = check_open t in
    Log.debug (fun l -> l "clear %S" t.root);
    if t.config.readonly then raise RO_not_allowed;
    t.generation <- 0L;
    let log = assert_and_get t.log in
    IO.clear log.io;
    Tbl.clear log.mem;
    may
      (fun (i : index) ->
        IO.clear i.io;
        IO.close i.io)
      t.index;
    t.index <- None

  let ( // ) = Filename.concat

  let index_dir root = root // "index"

  let log_path root = index_dir root // "log"

  let index_path root = index_dir root // "data"

  let lock_path root = index_dir root // "lock"

  let merge_path root = index_dir root // "merge"

  let page_size = Int64.mul entry_sizeL 1_000L

  let iter_io_off ?(min = 0L) ?max f io =
    let max = match max with None -> IO.offset io | Some m -> m in
    let rec aux offset =
      let remaining = Int64.sub max offset in
      if remaining <= 0L then ()
      else
        let len = Int64.to_int (Stdlib.min remaining page_size) in
        let raw = Bytes.create len in
        let n = IO.read io ~off:offset ~len raw in
        let rec read_page page off =
          if off = n then ()
          else
            let entry = decode_entry page off in
            f Int64.(add (of_int off) offset) entry;
            (read_page [@tailcall]) page (off + entry_size)
        in
        read_page raw 0;
        (aux [@tailcall]) Int64.(add offset page_size)
    in
    (aux [@tailcall]) min

  let iter_io ?min ?max f io = iter_io_off ?min ?max (fun _ e -> f e) io

  module Entry = struct
    type t = entry

    module Key = K
    module Value = V

    let encoded_size = entry_size

    let decode = decode_entry

    let to_key e = e.key

    let to_value e = e.value
  end

  module IOArray = Io_array.Make (IO) (Entry)

  module Search =
    Search.Make (Entry) (IOArray)
      (struct
        type t = int

        module Entry = Entry

        let compare : int -> int -> int = compare

        let of_entry e = e.key_hash

        let of_key = K.hash

        let linear_interpolate ~low:(low_index, low_metric)
            ~high:(high_index, high_metric) key_metric =
          let low_in = float_of_int low_metric in
          let high_in = float_of_int high_metric in
          let target_in = float_of_int key_metric in
          let low_out = Int64.to_float low_index in
          let high_out = Int64.to_float high_index in
          (* Fractional position of [target_in] along the line from [low_in] to [high_in] *)
          let proportion = (target_in -. low_in) /. (high_in -. low_in) in
          (* Convert fractional position to position in output space *)
          let position = low_out +. (proportion *. (high_out -. low_out)) in
          let rounded = ceil (position -. 0.5) +. 0.5 in
          Int64.of_float rounded
      end)

  let with_cache ~v ~clear =
    let roots = Hashtbl.create 0 in
    let f ?(fresh = false) ?(readonly = false) ~log_size root =
      try
        if not (Sys.file_exists (index_dir root)) then (
          Log.debug (fun l ->
              l "[%s] does not exist anymore, cleaning up the fd cache"
                (Filename.basename root));
          Hashtbl.remove roots (root, true);
          Hashtbl.remove roots (root, false);
          raise Not_found );
        let t = Hashtbl.find roots (root, readonly) in
        if t.open_instances <> 0 then (
          Log.debug (fun l -> l "%s found in cache" root);
          t.open_instances <- t.open_instances + 1;
          let t = ref (Some t) in
          if fresh then clear t;
          t )
        else (
          Hashtbl.remove roots (root, readonly);
          raise Not_found )
      with Not_found ->
        Log.debug (fun l ->
            l "[%s] v fresh=%b readonly=%b" (Filename.basename root) fresh
              readonly);
        let instance = v ~fresh ~readonly ~log_size root in
        Hashtbl.add roots (root, readonly) instance;
        ref (Some instance)
    in
    `Staged f

  let v_no_cache ~fresh ~readonly ~log_size root =
    let lock =
      if not readonly then Some (IO.lock (lock_path root)) else None
    in
    let config = { log_size = log_size * entry_size; readonly; fresh } in
    let log_path = log_path root in
    let log =
      if readonly && not (Sys.file_exists log_path) then None
      else
        let mem = Tbl.create 1024 in
        let io = IO.v ~fresh ~readonly ~generation:0L ~fan_size:0L log_path in
        iter_io (fun e -> Tbl.replace mem e.key e.value) io;
        Some { io; mem }
    in
    let generation =
      match log with None -> 0L | Some log -> IO.get_generation log.io
    in
    let index =
      let index_path = index_path root in
      if Sys.file_exists index_path then
        let io = IO.v ~fresh ~readonly ~generation ~fan_size:0L index_path in
        let fan_out = Fan.import ~hash_size:K.hash_size (IO.get_fanout io) in
        Some { fan_out; io }
      else None
    in
    { config; generation; log; root; index; open_instances = 1; lock }

  let (`Staged v) = with_cache ~v:v_no_cache ~clear

  let interpolation_search index key =
    let hashed_key = K.hash key in
    let low_bytes, high_bytes = Fan.search index.fan_out hashed_key in
    let low, high =
      Int64.(div low_bytes entry_sizeL, div high_bytes entry_sizeL)
    in
    Search.interpolation_search (IOArray.v index.io) key ~low ~high

  let try_load_log t =
    let log_path = log_path t.root in
    if Sys.file_exists log_path then (
      let io =
        IO.v ~fresh:t.config.fresh ~readonly:true ~generation:0L ~fan_size:0L
          log_path
      in
      let mem = Tbl.create 1024 in
      iter_io (fun e -> Tbl.replace mem e.key e.value) io;
      t.generation <- IO.get_generation io;
      t.log <- Some { io; mem } )

  let sync_log t =
    (match t.log with None -> try_load_log t | Some _ -> ());
    match t.log with
    | None -> ()
    | Some log ->
        let generation = IO.get_generation log.io in
        let log_offset = IO.offset log.io in
        let new_log_offset = IO.force_offset log.io in
        let add_log_entry e = Tbl.replace log.mem e.key e.value in
        if t.generation <> generation then (
          Tbl.clear log.mem;
          iter_io add_log_entry log.io;
          may (fun (i : index) -> IO.close i.io) t.index;
          if Int64.equal generation 0L then t.index <- None
          else
            let index_path = index_path t.root in
            let io =
              IO.v ~fresh:false ~readonly:true ~generation ~fan_size:0L
                index_path
            in
            let fan_out =
              Fan.import ~hash_size:K.hash_size (IO.get_fanout io)
            in
            t.index <- Some { fan_out; io };
            t.generation <- generation )
        else if log_offset < new_log_offset then
          iter_io add_log_entry log.io ~min:log_offset
        else if log_offset > new_log_offset then assert false

  let find t key =
    let t = check_open t in
    Log.debug (fun l -> l "find %a" K.pp key);
    if t.config.readonly then sync_log t;
    match t.log with
    | None -> raise Not_found
    | Some log -> (
        try Tbl.find log.mem key
        with Not_found -> (
          match t.index with
          | Some index -> interpolation_search index key
          | None -> raise Not_found ) )

  let mem t key =
    Log.debug (fun l -> l "mem %a" K.pp key);
    match find t key with _ -> true | exception Not_found -> false

  let append_buf_fanout fan_out hash buf_str dst_io =
    Fan.update fan_out hash (IO.offset dst_io);
    IO.append dst_io buf_str

  let append_entry_fanout fan_out entry dst_io =
    Fan.update fan_out entry.key_hash (IO.offset dst_io);
    append_key_value dst_io entry.key entry.value

  let rec merge_from_log fan_out log log_i hash_e dst_io =
    if log_i >= Array.length log then log_i
    else
      let v = log.(log_i) in
      if v.key_hash > hash_e then log_i
      else (
        append_entry_fanout fan_out v dst_io;
        (merge_from_log [@tailcall]) fan_out log (log_i + 1) hash_e dst_io )

  let append_remaining_log fan_out log log_i dst_io =
    for log_i = log_i to Array.length log - 1 do
      append_entry_fanout fan_out log.(log_i) dst_io
    done

  (* Merge [log] with [t] into [dst_io]. [log] must be sorted by key hashes. *)
  let merge_with log (index : index) dst_io =
    let entries = 10_000 in
    let len = entries * entry_size in
    let buf = Bytes.create len in
    let refill off = ignore (IO.read index.io ~off ~len buf) in
    let index_end = IO.offset index.io in
    let fan_out = index.fan_out in
    refill 0L;
    let rec go index_offset buf_offset log_i =
      if index_offset >= index_end then
        append_remaining_log fan_out log log_i dst_io
      else
        let buf_str = Bytes.sub_string buf buf_offset entry_size in
        let index_offset = Int64.add index_offset entry_sizeL in
        let key_e = K.decode buf_str 0 in
        let hash_e = K.hash key_e in
        let log_i = merge_from_log fan_out log log_i hash_e dst_io in
        if
          log_i >= Array.length log
          ||
          let key = log.(log_i).key in
          not (K.equal key key_e)
        then append_buf_fanout fan_out hash_e buf_str dst_io;
        let buf_offset =
          let n = buf_offset + entry_size in
          if n >= Bytes.length buf then (
            refill index_offset;
            0 )
          else n
        in
        (go [@tailcall]) index_offset buf_offset log_i
    in
    (go [@tailcall]) 0L 0 0

  let merge ~witness t =
    Log.debug (fun l -> l "unforced merge %S\n" t.root);
    let log = assert_and_get t.log in
    let merge_path = merge_path t.root in
    let generation = Int64.succ t.generation in
    let log_array =
      let compare_entry e e' = compare e.key_hash e'.key_hash in
      let b = Array.make (Tbl.length log.mem) witness in
      Tbl.fold
        (fun key value i ->
          b.(i) <- { key; value; key_hash = K.hash key };
          i + 1)
        log.mem 0
      |> ignore;
      Array.fast_sort compare_entry b;
      b
    in
    let fan_size =
      match t.index with
      | None -> Tbl.length log.mem
      | Some index ->
          (Int64.to_int (IO.offset index.io) / entry_size) + Tbl.length log.mem
    in
    let fan_out = Fan.v ~hash_size:K.hash_size ~entry_size fan_size in
    let merge =
      IO.v ~readonly:false ~fresh:true ~generation
        ~fan_size:(Int64.of_int (Fan.exported_size fan_out))
        merge_path
    in
    ( match t.index with
    | None ->
        let io =
          IO.v ~fresh:true ~readonly:false ~generation:0L ~fan_size:0L
            (index_path t.root)
        in
        append_remaining_log fan_out log_array 0 merge;
        t.index <- Some { io; fan_out }
    | Some index ->
        let index = { index with fan_out } in
        merge_with log_array index merge;
        t.index <- Some index );
    match t.index with
    | None -> assert false
    | Some index ->
        Fan.finalize index.fan_out;
        IO.set_fanout merge (Fan.export index.fan_out);
        IO.rename ~src:merge ~dst:index.io;
        IO.clear log.io;
        Tbl.clear log.mem;
        IO.set_generation log.io generation;
        t.generation <- generation

  let get_witness t =
    match t.log with
    | None -> None
    | Some log -> (
        let exception Found of entry in
        match
          Tbl.iter
            (fun key value ->
              raise (Found { key; value; key_hash = K.hash key }))
            log.mem
        with
        | exception Found e -> Some e
        | () -> (
            match t.index with
            | None -> None
            | Some index ->
                let buf = Bytes.create entry_size in
                let n = IO.read index.io ~off:0L ~len:entry_size buf in
                assert (n = entry_size);
                Some (decode_entry buf 0) ) )

  let force_merge t =
    let t = check_open t in
    Log.debug (fun l -> l "forced merge %S\n" t.root);
    match get_witness t with None -> () | Some witness -> merge ~witness t

  let replace t key value =
    let t = check_open t in
    Log.debug (fun l -> l "add %a %a" K.pp key V.pp value);
    if t.config.readonly then raise RO_not_allowed;
    let log = assert_and_get t.log in
    append_key_value log.io key value;
    Tbl.replace log.mem key value;
    if Int64.compare (IO.offset log.io) (Int64.of_int t.config.log_size) > 0
    then merge ~witness:{ key; key_hash = K.hash key; value } t

  let iter f t =
    let t = check_open t in
    Log.debug (fun l -> l "iter %S" t.root);
    if t.config.readonly then sync_log t;
    match t.log with
    | None -> ()
    | Some log ->
        Tbl.iter f log.mem;
        may
          (fun (i : index) -> iter_io (fun e -> f e.key e.value) i.io)
          t.index

  let flush_instance instance =
    if instance.config.readonly then raise RO_not_allowed;
    let log = assert_and_get instance.log in
    IO.sync log.io

  let flush t =
    let instance = check_open t in
    flush_instance instance

  let close it =
    match !it with
    | None -> ()
    | Some t ->
        (* XXX This piece of code is not thread safe. *)
        it := None;
        t.open_instances <- t.open_instances - 1;
        if t.open_instances = 0 then (
          Log.debug (fun l -> l "close %S" t.root);
          if not t.config.readonly then flush_instance t;
          may (fun l -> IO.close l.io) t.log;
          may (fun (i : index) -> IO.close i.io) t.index;
          may (fun lock -> IO.unlock lock) t.lock )
end
