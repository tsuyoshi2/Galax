(***********************************************************************)
(*                                                                     *)
(*                                 GALAX                               *)
(*                             XQuery Engine                           *)
(*                                                                     *)
(*  Copyright 2001-2007.                                               *)
(*  Distributed only by permission.                                    *)
(*                                                                     *)
(***********************************************************************)

(* $Id: galax-project.ml,v 1.37 2007/09/19 20:01:50 mff Exp $ *)

(* Module: Top_project
   Description:
     This module implements a simple front-end for Galax XML
     projection algorithm.
 *)

open Format

open Error

open Print_top
open Xquery_ast

open Monitoring_context

open Processing_context
open Procmod_compiler
open Procmod_phases

open Compile_context

open Galax

open Top_util
open Top_config

open Xquery_core_ast

open Namespace_builtin

open Path_struct

open Top_options

(****************)
(* Command-line *)
(****************)

let usage_msg =
  sprintf "Usage: %s [options] file(s)" Sys.argv.(0)

let process_args proc_ctxt gargs =
  let args =
    make_options_argv
      proc_ctxt
      (usage_galax_project ())
      [ GalaxProject_Options;Misc_Options;Monitoring_Options;Encoding_Options;Context_Options;DataModel_Options;Serialization_Options;PrintParse_Options ]
      gargs
  in
  match args with
  | [] -> failwith "No input XML file(s) specified"
  | fnames -> fnames

let rec doc_uris_from_paths paths =
  match paths with
    | [] -> []
    | (rootid, path_fragment) :: tl ->
	let doc_uris = doc_uris_from_paths tl in
	match rootid with
	  | InputDocument uri_string ->
	      begin
		if (List.exists (fun x -> x = uri_string) doc_uris)
		then doc_uris
		else uri_string :: doc_uris
	      end
	  | InputVariable _ -> 
	      doc_uris

let typed_xml_stream_from_document_uri doc_uri =
  let proc_ctxt = Processing_context.default_processing_context () in
  let lookup_document_from_io gio =
    fun proc_ctxt ->
      let apply_load_document () =
	(* 1. Open a SAX cursor on the input document *)
	let (dtd_opt, xml_stream) = Streaming_parse.open_xml_stream_from_io gio in
	  (* 2. Resolve namespaces *)
	let resolved_xml_stream = Streaming_ops.resolve_xml_stream xml_stream in
	  (* 3. Apply type annotations *)
	let typed_xml_stream = Streaming_ops.typed_of_resolved_xml_stream resolved_xml_stream in
	  typed_xml_stream
      in
	apply_load_document ()
  in
    match Galax_url.glx_decode_url doc_uri with
      | Galax_url.File _
      | Galax_url.Http _ ->
	  lookup_document_from_io (Galax_io.Http_Input doc_uri) proc_ctxt
      | Galax_url.ExternalSource (me,host,port,local) ->
	  raise (Query (Toplevel_Error "Document projection from other back ends than files and http is not supported."))

let projected_xml_stream_from_document paths doc_uri_string =
  let doc_uri = AnyURI._actual_uri_of_string doc_uri_string in
  let project_fun = Stream_project.project_xml_stream_from_document doc_uri in
  let typed_xml_stream = typed_xml_stream_from_document_uri doc_uri_string in
  let resolved_xml_stream = Streaming_ops.erase_xml_stream typed_xml_stream in
    project_fun paths resolved_xml_stream

let print_projected_document paths doc_uri_string =
  let projected_resolved_xml_stream = projected_xml_stream_from_document paths doc_uri_string in
  let proc_ctxt = Processing_context.default_processing_context () in
    Serialization.serialize_resolved_xml_stream proc_ctxt projected_resolved_xml_stream

let output_projected_document paths doc_uri_string = 
  let projected_resolved_xml_stream = projected_xml_stream_from_document paths doc_uri_string in
  let proc_ctxt = Processing_context.default_processing_context () in
  let out_channel = open_out(doc_uri_string ^ Conf.projection_suffix) in
  let output_spec = Galax_io.Channel_Output out_channel in
  let gout = Parse_io.galax_output_from_output_spec output_spec in
  let fmt = Parse_io.formatter_of_galax_output gout in
    begin
      Serialization.fserialize_resolved_xml_stream proc_ctxt fmt projected_resolved_xml_stream;
      Parse_io.close_galax_output gout
    end

let merge_tcprolog_into_tcmainmodule tcmainmodule tcprolog =
  let merged_prologs = 
    { pcprolog_functions = tcmainmodule.pcmodule_prolog.pcprolog_functions @ tcprolog.pcprolog_functions;
      pcprolog_vars = tcmainmodule.pcmodule_prolog.pcprolog_vars @ tcprolog.pcprolog_vars;
      pcprolog_servers = tcmainmodule.pcmodule_prolog.pcprolog_servers @ tcprolog.pcprolog_servers;
      pcprolog_indices = tcmainmodule.pcmodule_prolog.pcprolog_indices @ tcprolog.pcprolog_indices }
  in
    { pcmodule_prolog = merged_prologs;
      pcmodule_statements = tcmainmodule.pcmodule_statements }


(* This hosts all the functionality currently. - Michael, 03|08|2006 *)      
let process_query_file proc_ctxt uri_string =
  let _ = set_rewriting_phase proc_ctxt true in
  let _ = set_factorization_phase proc_ctxt true in
  let _ = set_optimization_phase proc_ctxt true in
    
  let query_gio = Galax_io.File_Input uri_string in       
  let std_mod = Procmod_compiler.compile_standard_library_module proc_ctxt in
  let (_, compiled_statements) = compile_main_module false std_mod query_gio in
  let compiled_statement =
    match compiled_statements with
      | hd :: [] -> hd
      | _ -> raise (Query (Prototype "Expected exactly one statement in query."))
  in
  let paths = Alg_path_analysis.path_analysis_of_statement compiled_statement in


  (* 03|08|2006 - Michael *)
  let formatter = Format.std_formatter in
  (*let _ = Alg_path_analysis.print_full_analysis formatter paths in*)

  let get_docids paths =
    let docid_lists = List.map (fun (id, _) -> match id with | Ast_path_struct.Document_id docid -> [docid] | _ -> []) paths in
    let docids = List.concat docid_lists in
      Gmisc.remove_duplicates docids
  in

  let print_projected_document docid =
    let typed_xml_stream = typed_xml_stream_from_document_uri docid in
    let projected_xml_stream = Alg_stream_project.project_xml_stream_from_document (AnyURI._actual_uri_of_string docid) paths typed_xml_stream in
    let proc_ctxt = Processing_context.default_processing_context () in
      fprintf formatter "\n";
      fprintf formatter "PROJECTED DOCUMENT: ";
      fprintf formatter "%s" docid;
      fprintf formatter "\n";
      fprintf formatter "------------------------------------------ \n";
      Serialization.fserialize_typed_xml_stream proc_ctxt formatter projected_xml_stream;
      fprintf formatter "\n"
  in

    List.iter print_projected_document (get_docids paths)


(********)
(* Main *)
(********)
    
let main proc_ctxt query_files =
  List.iter (process_query_file proc_ctxt) query_files

let go gargs =
  let proc_ctxt = Processing_context.default_processing_context() in
  let query_files = process_args proc_ctxt gargs in
   exec main proc_ctxt query_files

