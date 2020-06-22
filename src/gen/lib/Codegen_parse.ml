(*
   Code generator for the CST.ml file.

   This produces code similar to what's found in ../../run/lib/Sample.ml
*)

open Printf
open CST_grammar
open Indent.Types

let debug_gen = false
let debug_trace = ref true

(* All rule names and other names directly defined in grammar.json
   must go through this translation. For example, it turns
   "true" into "true_" because "true" is a reserved keyword in the generated
   code.
*)
let trans = Codegen_util.translate_ident

let mli_contents grammar : string =
  let lang = grammar.name in
  let root_type = grammar.entrypoint in
  sprintf {|
(**
    Functions for parsing %s programs into a CST.

    Generated by ocaml-tree-sitter.
*)

(** Parse a %s program from a string into a typed OCaml CST. *)
val string : ?src_file:string -> string -> CST.%s option

(** Parse a %s program from a file into a typed OCaml CST. *)
val file : string -> CST.%s option

(** Whether to print debugging information. Default: %B. *)
val debug : bool ref

(** The original tree-sitter parser. *)
val ts_parser : Tree_sitter_bindings.Tree_sitter_API.ts_parser

(** Parse a program into a tree-sitter CST. *)
val parse_source_string :
   ?src_file:string -> string -> Tree_sitter_run.Tree_sitter_parsing.t

(** Parse a source file into a tree-sitter CST. *)
val parse_source_file : string -> Tree_sitter_run.Tree_sitter_parsing.t

(** Parse a tree-sitter CST into an OCaml typed CST. *)
val parse_input_tree :
  Tree_sitter_run.Tree_sitter_parsing.t ->
  CST.%s option
|}
    lang
    lang (trans root_type)
    lang (trans root_type)
    !debug_trace
    (trans root_type)

(* Emit code that wraps around a parsing function
   if runtime tracing is enabled.
*)
let trace_gen trace_fun name (reader : Indent.t) =
  if !debug_trace then
    [
      Paren (
        sprintf "fun nodes -> Combine.%s %S (" trace_fun name,
        reader
        , ") nodes");
    ]
  else
    reader

(* works with any function of type _ -> _ option *)
let trace name reader =
  trace_gen "trace" name reader

(* works only with functions of type _ reader (which return input nodes) *)
let trace_reader name reader =
  trace_gen "trace_reader" name reader

let debug_log s =
  if !debug_trace then
    Line (sprintf "print_endline %S;" s)
  else
    Inline []

let constant_header = "\
(* Generated by ocaml-tree-sitter. *)

(* Disable warnings against unused variables *)
[@@@warning \"-26-27\"]

open Tree_sitter_bindings
open Tree_sitter_run
open Tree_sitter_output_t
let get_loc x = Loc.({ start = x.start_pos; end_ = x.end_pos })
"

let declare_externals lang = sprintf "\
external create_parser :
  unit -> Tree_sitter_API.ts_parser = \"octs_create_parser_%s\"

let ts_parser = create_parser ()

let parse_source_string ?src_file contents =
  Tree_sitter_parsing.parse_source_string ?src_file ts_parser contents

let parse_source_file src_file =
  Tree_sitter_parsing.parse_source_file ts_parser src_file
"
    lang

let gen_extras grammar =
  let items = List.map (fun name ->
    Line (sprintf "%S;" name)
  ) grammar.extras
  in
  [
    Line "let extras = [";
    Block items;
    Line "]";
    Line ""
  ]

let preamble ~ast_module_name grammar =
  [
    Line constant_header;
    Line (declare_externals grammar.name);
    Line (sprintf "let debug = ref %B" !debug_trace);
    Line "";
    Inline (gen_extras grammar);
    Line (sprintf "\
let parse_input_tree input_tree : %s.%s option =
  let root_node = Tree_sitter_parsing.root input_tree in
  let src = Tree_sitter_parsing.src input_tree in
  let get_token x = Src_file.get_token src x.start_pos x.end_pos in

  if !debug then (
    Printf.printf \"input from tree-sitter:\\n\";
    Tree_sitter_dump.to_stdout [root_node];
    flush stdout;
    Printf.printf \"ocaml-tree-sitter trace:\\n\"
  );

  let get_token x =
    Src_file.get_token src x.start_pos x.end_pos in

  (* Parse a single node that has no children.
     We extract its location and source code (token). *)
  let _parse_leaf_rule type_ =
    Combine.parse_node (fun x ->
      if x.type_ = type_ then
        Some (get_loc x, get_token x)
      else
        None
    )
  in
"
            ast_module_name (trans grammar.entrypoint)
         )
  ]

let paren x = [Paren ("(", x, ")")]

let format_cases cases =
  List.map (fun (pat, e) ->
    [
      Line (sprintf "| %s ->" pat);
      Block [Block e];
    ]
  ) cases
  |> List.flatten

let match_with e cases =
  paren [
    Line "match";
    Block e;
    Line "with";
    Inline (format_cases cases);
  ]

(*
   For some functions it's shorter to produce the function's body,
   for others it's shorter to produce the whole function expression.
   Each can be wrapped to convert to the other form.
*)
type code =
  | Fun of Indent.t (* takes one argument of type 'node list' *)
  | Body of Indent.t (* assumes one argument, 'nodes' *)

let as_fun = function
  | Fun code -> code
  | Body code ->
      [
        Line "(fun nodes ->";
        Block code;
        Line ")";
      ]

let as_body = function
  | Fun code ->
      [
        Line "(";
        Block code;
        Line ") nodes";
      ]
  | Body code -> code

let gen_lazy_or cases =
  let rec gen cases =
    match cases with
    | [] -> assert false
    | [(name, _)] ->
        [ Line (sprintf "_parse_%s nodes" name) ]
    | (name, _) :: cases ->
        [
          Line (sprintf "match _parse_%s nodes with" name);
          Line "| Some _ as res -> res";
          Line "| None ->";
          Block [Block (gen cases)];
        ]
  in
  gen cases

let as_sequence body =
  match body with
  | Seq bodies -> bodies
  | body -> [body]

(*
   Produce, for head_len = len = 3:
    "(e0, (e1, e2))"

   For head_len = 2 and len = 5:
    "(e0, (e1, tail))"
*)
let gen_nested_pairs ~head_len ~len =
  assert (head_len <= len);
  assert (head_len > 0);
  let buf = Buffer.create 50 in
  let has_tail = (head_len < len) in
  let rec gen buf pos =
    if pos < head_len - 1 then
      bprintf buf "(e%i, %a)" pos gen (pos + 1)
    else if pos = head_len - 1 then
      if has_tail then
        bprintf buf "(e%i, tail)" pos
      else
        bprintf buf "e%i" pos
    else
      assert false
  in
  gen buf 0;
  Buffer.contents buf

(*
   Produce, for num_elts = num_avail = 3:
    "(e0, e1, e2)"

   For num_elts = 2 and num_avail = 5:
    "((e0, e1), tail))"
*)
let gen_flat_tuple ~head_len ~len wrap_tuple =
  assert (head_len >= 0);
  let elts =
    sprintf "(%s)"
      (Codegen_util.enum head_len
       |> List.map (fun pos -> sprintf "e%i" pos)
       |> String.concat ", ")
    |> wrap_tuple
  in
  if head_len = len then
    elts
  else
    sprintf "(%s, tail)" elts

(* A function expression that matches the rest of the sequence,
   with the depth of generated tuple and the number of elements we want to
   keep:

     (0, 0, None) : nothing needs to be matched or captured
     (1, 1, Some [Line "parse_something"]) : one element needs to be matched,
                                             captured, and returned

   It's possible to ignore the last element(s), such as a parser for checking
   the end of the sequence which returns unit. This is achieved by reducing
   the number of captured elements:

     (1, 0, Some [Line "parse_end"]) : one element needs to be matched but
                                       is ignored (giving a tuple of length 0)
     (2, 1, Some <parse an element, then match end>) :
                                       two elements are matched, captured,
                                       but the last element is discarded,
                                       giving a tuple of length 1.
*)
type next =
  | Nothing
  | Next of (int * int * code)

let show_next = function
  | Nothing -> "nothing"
  | Next (num_avail, num_keep, _) ->
      sprintf "(avail:%i, keep:%i, _)" num_avail num_keep

let flatten_next = function
  | Next x -> x
  | Nothing -> (1, 0, Fun [Line "Combine.parse_success"])

let force_next next =
  let _, _, code = flatten_next next in
  code

(* Replace the code for matching the sequence without changing the length
   of the sequence. *)
let map_next f next =
  match next with
  | Nothing ->
      Nothing
  | Next (num_captured, num_keep, code) ->
      Next (num_captured, num_keep, f code)

(* Replace the code for matching the sequence and assume it captures and
   keeps one more element. *)
let map_next_incr f next =
  match next with
  | Nothing ->
      Next (2, 1, f None)
  | Next (num_captured, num_keep, code) ->
      Next (num_captured + 1, num_keep + 1, f (Some code))

let match_end = Fun [Line "Combine.parse_end"]
let match_success = Fun [Line "Combine.parse_success"]
let match_tail = Fun [Line "_parse_tail"]

let next_match_end = Next (1, 0, match_end)
let next_success = Next (1, 0, match_success)
let next_tail = Next (1, 1, match_tail)

(* Put a matcher in front a sequence of matchers. *)
let prepend match_elt next =
  match next with
  | Nothing ->
      Next (1, 1, match_elt)
  | Next (num_captured, num_keep, tail_matcher) ->
      let seq =
        Fun [
          Line "Combine.parse_seq";
          Block (paren (as_fun match_elt));
          Block (paren (as_fun tail_matcher));
        ]
      in
      Next (num_captured + 1, num_keep + 1, seq)

(* Flatten the first n elements of a nested sequence, returning the tail
   unchanged.

   Generated code looks like this for n=2:

     match parse_sequence nodes with
     | None -> None
     | Some ((e1, (e2, tail)), nodes) -> Some (((e1, e2), tail), nodes)
                                                ^^^^^^^^^^^^^^ result pair

   If the tail is empty, leave it undefined and return a single result
   rather than a pair:

     match parse_sequence nodes with
     | None -> None
     | Some ((e1, e2), nodes) -> Some ((e1, e2), nodes)
                                       ^^^^^^^^ single result
*)
let flatten_seq_head ?wrap_tuple ?(discard = false) num_elts next =
  if debug_gen then
    printf "flatten_seq_head next:%s discard:%B\n" (show_next next) discard;
  assert (num_elts >= 0);
  match num_elts, wrap_tuple with
  | 0, _ -> next
  | _ ->
      let num_captured, num_keep, match_seq = flatten_next next in
      match num_elts, num_captured, wrap_tuple with
      | 1, 1, None -> next
      | 2, 2, None -> next
      | _ ->
          let wrap_tuple =
            match wrap_tuple with
            | None -> (fun x -> x)
            | Some f -> f
          in
          let nested_tuple_pat =
            gen_nested_pairs ~head_len:num_elts ~len:num_captured
          in
          let wrapped_result =
            let len =
              if discard then num_elts
              else num_captured
            in
            gen_flat_tuple ~head_len:num_elts ~len wrap_tuple
          in
          if debug_gen then
            printf "flatten:%i, total:%i, keep:%i  %s -> %s\n"
              num_elts num_captured num_keep
              nested_tuple_pat wrapped_result;
          let cases = [
            sprintf "Some (%s, nodes)" nested_tuple_pat, [
              Line (sprintf "Some (%s, nodes)" wrapped_result)
            ];
            "None", [Line "None"];
          ] in
          let match_seq =
            Body (
              match_with
                (as_body match_seq)
                cases
            )
          in
          (* reflect the collapse of num_elts results into one. *)
          let num_captured = num_captured - num_elts + 1 in
          let num_keep = num_keep - num_elts + 1 in
          assert (num_captured >= 0);
          assert (num_keep >= 0);
          if num_captured = 0 then
            Nothing
          else
            Next (num_captured, num_keep, match_seq)

(*
   Flatten the full sequence minus one element, and eliminate the ignored
   tail:

     (e1, (e2, (e3, ignored_tail))) -> ((e1, e2), e3)
*)
let flatten_seq_with_tail ?wrap_tuple next =
  if debug_gen then
    printf "flatten_seq_with_tail next:%s\n" (show_next next);
  let num_elts =
    match next with
    | Nothing -> 0
    | Next (_num_captured, num_keep, _code) -> num_keep - 1
  in
  let next = flatten_seq_head ?wrap_tuple num_elts next in
  force_next next

(*
   Flatten the full sequence and eliminate the ignored tail.
*)
let flatten_seq ?wrap_tuple next =
  if debug_gen then
    printf "flatten_seq next:%s\n" (show_next next);
  let num_elts =
    match next with
    | Nothing -> 0
    | Next (_num_captured, num_keep, _code) -> num_keep
  in
  let next = flatten_seq_head ?wrap_tuple ~discard:true num_elts next in
  force_next next

let wrap_matcher_result opt_wrap_result matcher_code =
  match opt_wrap_result with
  | None -> matcher_code
  | Some wrap_result ->
      Fun [
        Line "Combine.map";
        Block (paren wrap_result);
        Block (paren (as_fun matcher_code));
      ]

(* Transform the result of the first element of a pair. *)
let wrap_left_matcher_result opt_wrap_result matcher_code =
  match opt_wrap_result with
  | None -> matcher_code
  | Some wrap_result ->
      Fun [
        Line "Combine.map_fst";
        Block (paren wrap_result);
        Block (paren (as_fun matcher_code));
      ]

(*
   Create a representation of the function to match a sequence of elements.
   The return type of this function is of the form:

     (('e1, ('e2, ('e3, ...))) * node list) option

   In the CST, we these nested pairs are represented as a flat tuple.
   This flattening is done only where necessary, i.e. at the beginning
   of the sequence:
   - just under a named rule, i.e. for matching the whole sequence of children
     nodes.
   - as an alternative in a choice.
*)
let rec gen_seq body (next : next) : next =
  match body with
  | Symbol name ->
      (* (symbol, tail) *)
      prepend (Fun [
        Line (sprintf "parse_node_%s" (trans name))
      ]) next

  | Token { name; _ } ->
      (* (string, tail) *)
      prepend (Fun [
        Line (sprintf "_parse_leaf_rule %S" name)
      ]) next

  | Blank ->
      (* tail *)
      prepend (Fun [
        Line "Combine.parse_success";
      ]) next

  | Repeat body ->
      (* (list, tail) *)
      repeat `Repeat body next

  | Repeat1 body ->
      (* (list, tail) *)
      repeat `Repeat1 body next

  | Choice bodies ->
      (* (choice, tail) *)
      gen_choice bodies next

  | Optional body ->
      (* (option, tail) *)
      repeat `Optional body next

  | Seq bodies ->
      (* (e1, (e2, ...(en, tail))) *)
      gen_seqn bodies next

and gen_seqn bodies next =
  match bodies with
  | [] -> next
  | [body] -> gen_seq body next
  | body :: bodies -> gen_seq body (gen_seqn bodies next)

(* A sequence to be turned into a flat tuple, followed by something else.
   e.g. for matching the sequence AB present in (AB|C)D,
   the argument to this function would and "parse_AB" and "parse_D".

   Generated code should look like this:

     match parse_seqn nodes next with
     | None -> None
     | Some ((e1, (e2, (e3, tail))), nodes) ->
         Some (((e1, e2, e3), tail), nodes)
*)
and gen_seqn_head ?wrap_tuple bodies (next : next) : next =
  (* the length of the tuple to extract before the rest of the sequence *)
  let num_elts = List.length bodies in
  let next = gen_seqn bodies next in
  flatten_seq_head ?wrap_tuple num_elts next

(*
   Generate something like the following:

   let parse_tail = ... in
   let parse_case0 = ... parse_tail in
   let parse_case1 = ... parse_tail in
   ...
   match parse_case0 nodes with
   | Some (res, tail), nodes) -> Some (((`Case0 res), tail), nodes)
   | None ->
       match parse_case1 nodes with
       | Some ... -> ...
       | None -> ...
*)
and gen_choice cases next0 =
(
  match next0 with
  | Nothing ->
      Next (1, 1, Body [
        Inline (List.map (fun case ->
          Inline (gen_parse_case case Nothing)
        ) cases);
        Inline (gen_lazy_or cases);
      ])
  | Next _ ->
      let choice_matcher =
        let next = map_next (fun _code -> Fun [Line "_parse_tail"]) next0 in
        Body [
          Line "let _parse_tail =";
          Block (force_next next0 |> as_fun);
          Line "in";
          Inline (List.map (fun case ->
            Inline (gen_parse_case case next)
          ) cases);
          Inline (gen_lazy_or cases);
        ]
      in
      map_next_incr (fun _code -> choice_matcher) next0
) |> (fun res ->
    if debug_gen then
      printf "gen_choice returns next:%s\n" (show_next res);
    res
  )

and gen_parse_case (name, body) next =
  let bodies = as_sequence body in
  let wrap_tuple tuple = sprintf "`%s %s" name tuple in
  [
    Line (sprintf "let _parse_%s nodes =" name);
    Block (gen_seqn_head ~wrap_tuple bodies next |> force_next |> as_body);
    Line "in";
  ]

and repeat kind body next =
  let parse_repeat =
    match kind with
    | `Repeat -> "Combine.parse_repeat"
    | `Repeat1 -> "Combine.parse_repeat1"
    | `Optional -> "Combine.parse_optional"
  in
  let repeat_matcher opt_tail_matcher =
    let tail_matcher =
      match opt_tail_matcher with
      | None -> match_success
      | Some tail_matcher -> tail_matcher
    in
    Fun [
      Line parse_repeat;
      Block (paren (gen_seq body Nothing |> flatten_seq |> as_fun));
      Block (paren (tail_matcher |> as_fun));
    ]
  in
  let res = map_next_incr repeat_matcher next in
  if debug_gen then
    printf "result from repeat: %s\n" (show_next res);
  res

let create_cache prefix id type_ =
  Inline [
    Line (sprintf "let %s%s : %s Combine.Memoize.t ="
            prefix (trans id) type_);
    Block [Line "Combine.Memoize.create () in"];
  ]

let gen_rule_cache ~ast_module_name (rule : rule) =
  let primary_name = rule.name in
  let leaf = is_leaf rule.body in
  let cache_type =
    if leaf then
      "Token.t"
    else
      sprintf "%s.%s" ast_module_name (trans primary_name)
  in
  [create_cache "cache_" primary_name cache_type]

(*
   Generate a list of bindings, without 'let', 'and' etc.
   for reading some input of type TYPE from a sequence of nodes.

   We create 3 kinds of functions:

   * parse_inline_TYPE:
     - called by parse_children_TYPE, which ensures it consumes the whole input
     - called by inline rules, whose name starts with '_'
   * parse_children_TYPE:
     - calls parse_inline_TYPE
   * parse_node_TYPE:
     - cached
     - reads one node, checks its 'type' field and calls parse_children_TYPE
       on its 'children' field.

   If the rule matches a leaf node, i.e. a node with no children, we never
   need to generate parse_children_TYPE.

   In addition to its primary name, a rule may have aliases.
   - For each alias, we must generate its own parse_node_ALIAS function,
     which calls parse_children_TYPE.
   - parse_inline_TYPE is called directly for aliases whose name starts
     with '_'. There's no need for a dedicated parse_inline_ALIAS.
*)
let gen_rule_parser_bindings ~ast_module_name (rule : rule) =
  let name = rule.name in
  let body = rule.body in
  if is_leaf body then (
    (* Generate parse_inline for the primary rule name.
       Generate parse_node for each name that needs it. *)
    let parse_inline_binding =
      let fun_name = "parse_inline_" ^ trans name in
      [
        Line (sprintf "%s : unit Combine.reader =" fun_name);
        Block (trace_reader fun_name [
          Line "(fun nodes ->";
          Block [
            Line "Combine.parse_success nodes";
          ];
          Line ")";
        ])
      ]
    in
    let parse_node_binding =
      let fun_name = "parse_node_" ^ trans name in
      [
        Line (sprintf "%s : Token.t Combine.reader ="
                fun_name);
        Block (trace_reader fun_name [
          Line "(fun nodes ->";
          Block [
            Line (sprintf "Combine.Memoize.apply cache_%s" (trans name));
            Block [
              Line (sprintf "(_parse_leaf_rule %S) nodes" name);
            ]
          ];
          Line ")";
        ])
      ]
    in
    [parse_inline_binding; parse_node_binding]
  )
  else
    (* Generate parse_inline and parse_children for the primary rule name.
       Generate parse_node for each name that needs it. *)
    let parse_inline_binding =
      let fun_name = sprintf "parse_inline_%s" (trans name) in
      [
        Line (sprintf "%s _parse_tail : (%s.%s * _) Combine.reader ="
                fun_name
                ast_module_name (trans name));
        Block (trace_reader fun_name [
          Block (gen_seq body next_tail
                 |> flatten_seq_with_tail
                 |> as_fun);
        ])
      ]
    in
    let parse_children_binding =
      let fun_name = sprintf "parse_children_%s" (trans name) in
      [
        Line (sprintf "%s : %s.%s Combine.full_seq_reader ="
                fun_name
                ast_module_name (trans name));
        Block (trace fun_name [
          Line "(fun nodes ->";
          Block [
            Line (sprintf "Combine.parse_full_seq parse_inline_%s nodes"
                    (trans name));
          ];
          Line ")"
        ])
      ]
    in
    let parse_node_binding =
      let fun_name = sprintf "parse_node_%s" (trans name) in
      [
        Line (sprintf "%s : %s.%s Combine.reader ="
                fun_name
                ast_module_name (trans name));
        Block (trace_reader fun_name [
          Line "(fun nodes ->";
          Block [
            Line (sprintf "Combine.Memoize.apply cache_%s ("
                    (trans name));
            Block [
              Line (sprintf "Combine.parse_rule %S parse_children_%s"
                      name (trans name));
            ];
            Line ") nodes";
          ];
          Line ")"
        ])
      ]
    in
    [parse_inline_binding; parse_children_binding; parse_node_binding]

let gen ~ast_module_name grammar =
  let entrypoint = grammar.entrypoint in
  let rule_defs =
    List.map (fun rule_group ->
      let is_rec =
        match rule_group with
        | [x] -> x.is_rec
        | _ -> true
      in
      let rule_caches =
        List.map (fun rule ->
          Inline (gen_rule_cache ~ast_module_name rule)
        ) rule_group in
      let rule_parsers =
        let bindings =
          List.map (fun rule ->
            gen_rule_parser_bindings ~ast_module_name rule
          ) rule_group
          |> List.flatten
        in
        Codegen_util.format_bindings ~is_rec ~is_local:true bindings
      in
      [
        Inline rule_caches;
        Inline rule_parsers;
      ]
    ) grammar.rules
    |> List.flatten
  in
  [
    Inline (preamble ~ast_module_name grammar);
    Block [
      Inline rule_defs;
      Line "let result =";
      Block [
        Line (sprintf "Combine.parse_root ~extras parse_node_%s root_node;"
                (trans entrypoint));
      ];
      Line "in";
      Line "if !debug then (";
      Block [
        Line "Printf.printf \"---\n\";";
        Line "flush stdout";
      ];
      Line ");";
      Line "result"
    ];
  ]

let ml_trailer = {|
let string ?src_file contents =
  let input_tree = parse_source_string ?src_file contents in
  parse_input_tree input_tree

let file src_file =
  let input_tree = parse_source_file src_file in
  parse_input_tree input_tree
|}

let generate ~ast_module_name grammar =
  let tree = gen ~ast_module_name grammar in
  let ml_contents = Indent.to_string tree ^ ml_trailer in
  mli_contents grammar, ml_contents
