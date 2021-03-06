(*
 *  Haxe Compiler
 *  Copyright (c)2005-2008 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *)
open Ast
open Type
open Common
open Typecore

(* ---------------------------------------------------------------------- *)
(* TOOLS *)

type switch_mode =
	| CMatch of (tenum_field * (string * t) option list option * pos)
	| CExpr of texpr

type access_mode =
	| MGet
	| MSet
	| MCall

exception DisplayTypes of t list
exception DisplayFields of (string * t * documentation) list

type access_kind =
	| AKNo of string
	| AKExpr of texpr
	| AKField of texpr * tclass_field
	| AKSet of texpr * string * t * string
	| AKInline of texpr * tclass_field * t
	| AKMacro of texpr * tclass_field
	| AKUsing of texpr * tclass_field * texpr

let mk_infos ctx p params =
	let file = if ctx.in_macro then p.pfile else Filename.basename p.pfile in
	(EObjectDecl (
		("fileName" , (EConst (String file) , p)) ::
		("lineNumber" , (EConst (Int (string_of_int (Lexer.get_error_line p))),p)) ::
		("className" , (EConst (String (s_type_path ctx.curclass.cl_path)),p)) ::
		if ctx.curmethod = "" then
			params
		else
			("methodName", (EConst (String ctx.curmethod),p)) :: params
	) ,p)

let check_assign ctx e =
	match e.eexpr with
	| TLocal _ | TArray _ | TField _ ->
		()
	| TConst TThis | TTypeExpr _ when ctx.untyped ->
		()
	| _ ->
		error "Invalid assign" e.epos

let rec get_overloads ctx p = function
	| (":overload",[(EFunction (_,fu),p)],_) :: l ->
		let topt = function None -> t_dynamic | Some t -> (try Typeload.load_complex_type ctx p t with _ -> t_dynamic) in
		let args = List.map (fun (a,opt,t,_) ->  a,opt,topt t) fu.f_args in
		TFun (args,topt fu.f_type) :: get_overloads ctx p l
	| _ :: l ->
		get_overloads ctx p l
	| [] ->
		[]

let rec mark_used_class ctx c =
	if ctx.com.dead_code_elimination && not (has_meta ":?used" c.cl_meta) then begin
		c.cl_meta <- (":?used",[],c.cl_pos) :: c.cl_meta;
		match c.cl_super with
		| Some (csup,_) -> mark_used_class ctx csup
		| _ -> ()
	end

let mark_used_field ctx f =
	if ctx.com.dead_code_elimination && not (has_meta ":?used" f.cf_meta) then f.cf_meta <- (":?used",[],f.cf_pos) :: f.cf_meta

type type_class =
	| KInt
	| KFloat
	| KString
	| KUnk
	| KDyn
	| KOther
	| KParam of t

let classify t =
	match follow t with
	| TInst ({ cl_path = ([],"Int") },[]) -> KInt
	| TInst ({ cl_path = ([],"Float") },[]) -> KFloat
	| TInst ({ cl_path = ([],"String") },[]) -> KString
	| TInst ({ cl_kind = KTypeParameter; cl_implements = [{ cl_path = ([],"Float")},[]] },[]) -> KParam t
	| TInst ({ cl_kind = KTypeParameter; cl_implements = [{ cl_path = ([],"Int")},[]] },[]) -> KParam t
	| TMono r when !r = None -> KUnk
	| TDynamic _ -> KDyn
	| _ -> KOther

let object_field f =
	let pf = Parser.quoted_ident_prefix in
	let pflen = String.length pf in		
	if String.length f >= pflen && String.sub f 0 pflen = pf then String.sub f pflen (String.length f - pflen), false else f, true

let type_field_rec = ref (fun _ _ _ _ _ -> assert false)
let type_expr_with_type_rec = ref (fun ~unify _ _ _ -> assert false)

(* ---------------------------------------------------------------------- *)
(* PASS 3 : type expression & check structure *)

let rec base_types t =
	let tl = ref [] in
	let rec loop t = (match t with
	| TInst(cl, params) ->
		List.iter (fun (ic, ip) ->
			let t = apply_params cl.cl_types params (TInst (ic,ip)) in
			loop t
		) cl.cl_implements;	
		(match cl.cl_super with None -> () | Some (csup, pl) ->
			let t = apply_params cl.cl_types params (TInst (csup,pl)) in
			loop t);
		tl := t :: !tl;
	| TType ({ t_path = ([],"Null") },[t]) -> loop t;
	| TLazy f -> loop (!f())
	| TMono r -> (match !r with None -> () | Some t -> loop t)
	| _ -> tl := t :: !tl) in
	loop t;
	tl

let unify_min_raise ctx el =
	match el with
	| [] -> mk_mono()
	| [e] -> e.etype
	| _ ->
		let rec chk_null e = is_null e.etype ||
			match e.eexpr with
			| TConst TNull -> true
			| TBlock el ->
				(match List.rev el with
				| [] -> false
				| e :: _ -> chk_null e)
			| TParenthesis e -> chk_null e
			| _ -> false
		in
		let t = ref (mk_mono()) in
		let is_null = ref false in
		let has_error = ref false in

		(* First pass: Try normal unification and find out if null is involved. *)
		List.iter (fun e -> 
			if not !is_null && chk_null e then begin
				is_null := true;
				t := ctx.t.tnull !t
			end;
			let et = follow e.etype in
			(try
				unify_raise ctx et (!t) e.epos;
			with Error (Unify _,_) -> try
				unify_raise ctx (!t) et e.epos;
				t := et;
			with Error (Unify _,_) -> has_error := true);
		) el;
		if not !has_error then !t else begin
			(* Second pass: Get all base types (interfaces, super classes and their interfaces) of most general type.
			   Then for each additional type filter all types that do not unify. *)
			let common_types = base_types !t in
			let loop e = 
				let first_error = ref None in
				let filter t = (try unify_raise ctx e.etype t e.epos; true
					with Error (Unify l, p) as err -> if !first_error = None then first_error := Some(err); false)
				in
				common_types := List.filter filter !common_types;
				(match !common_types, !first_error with
					| [], Some err -> raise err
					| _ -> ());
			in
			List.iter loop (List.tl el);
			List.hd !common_types
		end

let unify_min ctx el = 
	try unify_min_raise ctx el
	with Error (Unify l,p) ->
		if not ctx.untyped then display_error ctx (error_msg (Unify l)) p;
		(List.hd el).etype

let rec unify_call_params ctx name el args r p inline =
	let next() =
		match name with
		| None -> None
		| Some (n,meta) ->
			let rec loop = function
				| [] -> None
				| (":overload",[(EFunction (fname,f),p)],_) :: l ->
					if fname <> None then error "Function name must not be part of @:overload" p;
					(match f.f_expr with Some (EBlock [], _) -> () | _ -> error "Overload must only declare an empty method body {}" p);
					let topt = function None -> error "Explicit type required" p | Some t -> Typeload.load_complex_type ctx p t in
					let args = List.map (fun (a,opt,t,_) ->  a,opt,topt t) f.f_args in
					Some (unify_call_params ctx (Some (n,l)) el args (topt f.f_type) p inline)
				| _ :: l -> loop l
			in
			loop meta
	in
	let error acc txt =
		match next() with
		| Some l -> l
		| None ->
		let format_arg = (fun (name,opt,_) -> (if opt then "?" else "") ^ name) in
		let argstr = "Function " ^ (match name with None -> "" | Some (n,_) -> "'" ^ n ^ "' ") ^ "requires " ^ (if args = [] then "no arguments" else "arguments : " ^ String.concat ", " (List.map format_arg args)) in
		display_error ctx (txt ^ " arguments\n" ^ argstr) p;
		List.rev (List.map fst acc), (TFun(args,r))
	in
	let arg_error ul name opt p =
		match next() with
		| Some l -> l
		| None -> raise (Error (Stack (Unify ul,Custom ("For " ^ (if opt then "optional " else "") ^ "function argument '" ^ name ^ "'")), p))
	in
	let rec no_opt = function
		| [] -> []
		| ({ eexpr = TConst TNull },true) :: l -> no_opt l
		| l -> List.map fst l
	in
	let rec default_value t =
		let rec is_pos_infos = function
			| TMono r ->
				(match !r with
				| Some t -> is_pos_infos t
				| _ -> false)
			| TLazy f ->
				is_pos_infos (!f())
			| TType ({ t_path = ["haxe"] , "PosInfos" },[]) ->
				true
			| TType (t,tl) ->
				is_pos_infos (apply_params t.t_types tl t.t_type)
			| _ ->
				false
		in
		if is_pos_infos t then
			let infos = mk_infos ctx p [] in
			let e = type_expr ctx infos true in
			(e, true)
		else
			(null (ctx.t.tnull t) p, true)
	in
	let rec loop acc l l2 skip =
		match l , l2 with
		| [] , [] ->
			if not (inline && ctx.g.doinline) && (match ctx.com.platform with Flash8 | Flash | Js -> true | _ -> false) then
				List.rev (no_opt acc), (TFun(args,r))
			else
				List.rev (List.map fst acc), (TFun(args,r))
		| [] , (_,false,_) :: _ ->
			error (List.fold_left (fun acc (_,_,t) -> default_value t :: acc) acc l2) "Not enough"
		| [] , (name,true,t) :: l ->
			loop (default_value t :: acc) [] l skip
		| _ , [] ->
			(match List.rev skip with
			| [] -> error acc "Too many"
			| [name,ul] -> arg_error ul name true p
			| _ -> error acc "Invalid")
		| ee :: l, (name,opt,t) :: l2 ->
			try
				let e = (!type_expr_with_type_rec) ~unify:unify_raise ctx ee (Some t) in
				unify_raise ctx e.etype t e.epos;
				loop ((e,false) :: acc) l l2 skip
			with
				Error (Unify ul,_) ->
					if opt then
						loop (default_value t :: acc) (ee :: l) l2 ((name,ul) :: skip)
					else
						arg_error ul name false (snd ee)
	in
	loop [] el args []

let rec type_module_type ctx t tparams p =
	match t with
	| TClassDecl c ->
		let t_tmp = {
			t_path = fst c.cl_path, "#" ^ snd c.cl_path;
			t_module = c.cl_module;
			t_doc = None;
			t_pos = c.cl_pos;
			t_type = TAnon {
				a_fields = c.cl_statics;
				a_status = ref (Statics c);
			};
			t_private = true;
			t_types = [];
			t_meta = no_meta;
		} in
		if ctx.com.dead_code_elimination && not (has_meta ":?used" c.cl_meta) then c.cl_meta <- (":?used",[],p) :: c.cl_meta;
		mk (TTypeExpr (TClassDecl c)) (TType (t_tmp,[])) p
	| TEnumDecl e ->
		let types = (match tparams with None -> List.map (fun _ -> mk_mono()) e.e_types | Some l -> l) in
		let fl = PMap.fold (fun f acc ->
			PMap.add f.ef_name {
				cf_name = f.ef_name;
				cf_public = true;
				cf_type = f.ef_type;
				cf_kind = (match follow f.ef_type with
					| TFun _ -> Method MethNormal
					| _ -> Var { v_read = AccNormal; v_write = AccNo }
				);
				cf_pos = e.e_pos;
				cf_doc = None;
				cf_meta = no_meta;
				cf_expr = None;
				cf_params = [];
			} acc
		) e.e_constrs PMap.empty in
		let t_tmp = {
			t_path = fst e.e_path, "#" ^ snd e.e_path;
			t_module = e.e_module;
			t_doc = None;
			t_pos = e.e_pos;
			t_type = TAnon {
				a_fields = fl;
				a_status = ref (EnumStatics e);
			};
			t_private = true;
			t_types = e.e_types;
			t_meta = no_meta;
		} in
		if ctx.com.dead_code_elimination && not (has_meta ":?used" e.e_meta) then e.e_meta <- (":?used",[],p) :: e.e_meta;
		mk (TTypeExpr (TEnumDecl e)) (TType (t_tmp,types)) p
	| TTypeDecl s ->
		let t = apply_params s.t_types (List.map (fun _ -> mk_mono()) s.t_types) s.t_type in
		match follow t with
		| TEnum (e,params) ->
			type_module_type ctx (TEnumDecl e) (Some params) p
		| TInst (c,params) ->
			type_module_type ctx (TClassDecl c) (Some params) p
		| _ ->
			error (s_type_path s.t_path ^ " is not a value") p

let type_type ctx tpath p =
	type_module_type ctx (Typeload.load_type_def ctx p { tpackage = fst tpath; tname = snd tpath; tparams = []; tsub = None }) None p

let get_constructor c params p =
	let ct, f = (try Type.get_constructor field_type c with Not_found -> error (s_type_path c.cl_path ^ " does not have a constructor") p) in
	apply_params c.cl_types params ct, f

let make_call ctx e params t p =
	try
		let ethis, fname = (match e.eexpr with TField (ethis,fname) -> ethis, fname | _ -> raise Exit) in
		let f, cl = (match follow ethis.etype with
			| TInst (c,params) -> snd (try class_field c fname with Not_found -> raise Exit), Some c
			| TAnon a -> (try PMap.find fname a.a_fields with Not_found -> raise Exit), (match !(a.a_status) with Statics c -> Some c | _ -> None)
			| _ -> raise Exit
		) in
		if ctx.com.display || f.cf_kind <> Method MethInline then raise Exit;
		let is_extern = (match cl with
			| Some { cl_extern = true } -> true
			| _ when has_meta ":extern" f.cf_meta -> true
			| _ -> false
		) in
		if not ctx.g.doinline && not is_extern then raise Exit;
		ignore(follow f.cf_type); (* force evaluation *)
		let params = List.map (ctx.g.do_optimize ctx) params in
		(match f.cf_expr with
		| Some { eexpr = TFunction fd } ->
			(match Optimizer.type_inline ctx f fd ethis params t p is_extern with
			| None ->
				if is_extern then error "Inline could not be done" p;
				raise Exit
			| Some e -> e)
		| _ ->
			error "Recursive inline is not supported" p)
	with Exit ->
		mk (TCall (e,params)) t p

let rec acc_get ctx g p =
	match g with
	| AKNo f -> error ("Field " ^ f ^ " cannot be accessed for reading") p
	| AKExpr e | AKField (e,_) -> e
	| AKSet _ -> assert false
	| AKUsing (et,_,e) ->
		(* build a closure with first parameter applied *)
		(match follow et.etype with
		| TFun (_ :: args,ret) ->
			let tcallb = TFun (args,ret) in
			let twrap = TFun ([("_e",false,e.etype)],tcallb) in
			let args = List.map (fun (n,_,t) -> alloc_var n t) args in
			let ve = alloc_var "_e" e.etype in
			let ecall = make_call ctx et (List.map (fun v -> mk (TLocal v) v.v_type p) (ve :: args)) ret p in
			let ecallb = mk (TFunction {
				tf_args = List.map (fun v -> v,None) args;
				tf_type = ret;
				tf_expr = mk (TReturn (Some ecall)) t_dynamic p;
			}) tcallb p in
			let ewrap = mk (TFunction {
				tf_args = [ve,None];
				tf_type = tcallb;
				tf_expr = mk (TReturn (Some ecallb)) t_dynamic p;
			}) twrap p in
			make_call ctx ewrap [e] tcallb p
		| _ -> assert false)
	| AKInline (e,f,t) ->
		ignore(follow f.cf_type); (* force computing *)
		(match f.cf_expr with
		| None ->
			if ctx.com.display then
				mk (TClosure (e,f.cf_name)) t p
			else
				error "Recursive inline is not supported" p
		| Some { eexpr = TFunction _ } ->
			let chk_class c = if c.cl_extern || has_meta ":extern" f.cf_meta then display_error ctx "Can't create closure on an inline extern method" p in
			(match follow e.etype with
			| TInst (c,_) -> chk_class c
			| TAnon a -> (match !(a.a_status) with Statics c -> chk_class c | _ -> ())
			| _ -> ());
			mk (TClosure (e,f.cf_name)) t p
		| Some e ->
			let rec loop e = Type.map_expr loop { e with epos = p } in
			loop e)
	| AKMacro _ ->
		assert false

let error_require r p =
	let r = if r = "sys" then
		"a system platform (php,neko,cpp,etc.)"
	else try
		if String.sub r 0 5 <> "flash" then raise Exit;
		let _, v = ExtString.String.replace (String.sub r 5 (String.length r - 5)) "_" "." in
		"flash version " ^ v ^ " (use -swf-version " ^ v ^ ")"
	with _ ->
		"'" ^ r ^ "' to be enabled"
	in
	error ("Accessing this field require " ^ r) p

let field_access ctx mode f t e p =
	let fnormal() = AKField ((mk (TField (e,f.cf_name)) t p),f) in
	let normal() =
		match follow e.etype with
		| TAnon a -> (match !(a.a_status) with EnumStatics e -> AKField ((mk (TEnumField (e,f.cf_name)) t p),f) | _ -> fnormal())
		| _ -> fnormal()
	in
	match f.cf_kind with
	| Method m ->
		if mode = MSet && m <> MethDynamic && not ctx.untyped then error "Cannot rebind this method : please use 'dynamic' before method declaration" p;
		(match m, mode with
		| MethInline, _ -> AKInline (e,f,t)
		| MethMacro, MGet -> display_error ctx "Macro functions must be called immediatly" p; normal()
		| MethMacro, MCall -> AKMacro (e,f)
		| _ , MGet -> AKExpr (mk (TClosure (e,f.cf_name)) t p)
		| _ -> normal())
	| Var v ->
		match (match mode with MGet | MCall -> v.v_read | MSet -> v.v_write) with
		| AccNo ->
			(match follow e.etype with
			| TInst (c,_) when is_parent c ctx.curclass -> normal()
			| TAnon a ->
				(match !(a.a_status) with
				| Opened when mode = MSet ->
					f.cf_kind <- Var { v with v_write = AccNormal };
					normal()
				| Statics c2 when ctx.curclass == c2 -> normal()
				| _ -> if ctx.untyped then normal() else AKNo f.cf_name)
			| _ ->
				if ctx.untyped then normal() else AKNo f.cf_name)
		| AccNormal ->
			(*
				if we are reading from a read-only variable on an anonymous object, it might actually be a method, so make sure to create a closure
			*)
			let is_maybe_method() =
				match v.v_write, follow t, follow e.etype with
				| (AccNo | AccNever), TFun _, TAnon a ->
					(match !(a.a_status) with
					| Statics _ | EnumStatics _ -> false
					| _ -> true)
				| _ -> false
			in
			if mode = MGet && is_maybe_method() then
				AKExpr (mk (TClosure (e,f.cf_name)) t p)
			else
				normal()
		| AccCall m ->
			if m = ctx.curmethod && (match e.eexpr with TConst TThis -> true | TTypeExpr (TClassDecl c) when c == ctx.curclass -> true | _ -> false) then
				let prefix = (match ctx.com.platform with Flash when Common.defined ctx.com "as3" -> "$" | _ -> "") in
				AKExpr (mk (TField (e,prefix ^ f.cf_name)) t p)
			else if mode = MSet then
				AKSet (e,m,t,f.cf_name)
			else
				AKExpr (make_call ctx (mk (TField (e,m)) (tfun [] t) p) [] t p)
		| AccResolve ->
			let fstring = mk (TConst (TString f.cf_name)) ctx.t.tstring p in
			let tresolve = tfun [ctx.t.tstring] t in
			AKExpr (make_call ctx (mk (TField (e,"resolve")) tresolve p) [fstring] t p)
		| AccNever ->
			if ctx.untyped then normal() else AKNo f.cf_name
		| AccInline ->
			AKInline (e,f,t)
		| AccRequire r ->
			error_require r p

let using_field ctx mode e i p =
	if mode = MSet then raise Not_found;
	let rec loop = function
		| [] ->
			raise Not_found
		| TEnumDecl _ :: l | TTypeDecl _ :: l ->
			loop l
		| TClassDecl c :: l ->
			try
				let f = PMap.find i c.cl_statics in
				let t = field_type f in
				(match follow t with
				| TFun ((_,_,t0) :: args,r) ->
					let t0 = (try match t0 with
					| TType({t_path=["haxe";"macro"], ("ExprOf"|"ExprRequire")}, [t]) ->
						(try unify_raise ctx e.etype t p with Error (Unify _,_) -> raise Not_found); t;
					| _ -> raise Not_found
					with Not_found ->
						(try unify_raise ctx e.etype t0 p with Error (Unify _,_) -> raise Not_found); t0) in
					if follow e.etype == t_dynamic && follow t0 != t_dynamic then raise Not_found;
					let et = type_module_type ctx (TClassDecl c) None p in
					AKUsing (mk (TField (et,i)) t p,f,e)
				| _ -> raise Not_found)
			with Not_found ->
				loop l
	in
	loop ctx.local_using

let get_this ctx p =
	match ctx.curfun with
	| FStatic ->
		error "Cannot access this from a static function" p
	| FMemberLocal ->
		if ctx.untyped then display_error ctx "Cannot access this in 'untyped' mode : use either '__this__' or var 'me = this' (transitional)" p;
		let v = (match ctx.vthis with
			| None ->
				let v = alloc_var "me" ctx.tthis in
				ctx.vthis <- Some v;
				v
			| Some v -> v
		) in
		mk (TLocal v) ctx.tthis p
	| FConstructor | FMember ->
		mk (TConst TThis) ctx.tthis p

let type_ident ctx i is_type p mode =
	match i with
	| "true" ->
		if mode = MGet then
			AKExpr (mk (TConst (TBool true)) ctx.t.tbool p)
		else
			AKNo i
	| "false" ->
		if mode = MGet then
			AKExpr (mk (TConst (TBool false)) ctx.t.tbool p)
		else
			AKNo i
	| "this" ->
		if mode = MGet then
			AKExpr (get_this ctx p)
		else
			AKNo i
	| "super" ->
		let t = (match ctx.curclass.cl_super with
			| None -> error "Current class does not have a superclass" p
			| Some (c,params) -> TInst(c,params)
		) in
		(match ctx.curfun with
		| FMember | FConstructor -> ()
		| FStatic -> error "Cannot access super inside a static function" p;
		| FMemberLocal -> error "Cannot access super inside a local function" p);
		if mode = MSet || not ctx.in_super_call then
			if mode = MGet && ctx.com.display then
				AKExpr (mk (TConst TSuper) t p)
			else
				AKNo i
		else begin
			ctx.in_super_call <- false;
			AKExpr (mk (TConst TSuper) t p)
		end
	| "null" ->
		if mode = MGet then
			AKExpr (null (mk_mono()) p)
		else
			AKNo i
	| _ ->
	try
		let v = PMap.find i ctx.locals in
		AKExpr (mk (TLocal v) v.v_type p)
	with Not_found -> try
		(* member variable lookup *)
		if ctx.curfun = FStatic then raise Not_found;
		let t , f = class_field ctx.curclass i in
		field_access ctx mode f t (get_this ctx p) p
	with Not_found -> try
		(* lookup using on 'this' *)
		if ctx.curfun = FStatic then raise Not_found;
		(match using_field ctx mode (mk (TConst TThis) ctx.tthis p) i p with
		| AKUsing (et,f,_) -> AKUsing (et,f,get_this ctx p)
		| _ -> assert false)
	with Not_found -> try
		(* static variable lookup *)
		let f = PMap.find i ctx.curclass.cl_statics in
		let e = type_type ctx ctx.curclass.cl_path p in
		(* check_locals_masking already done in type_type *)
		field_access ctx mode f (field_type f) e p
	with Not_found ->
		(* lookup imported enums *)
		let rec loop l =
			match l with
			| [] -> raise Not_found
			| t :: l ->
				match t with
				| TClassDecl _ ->
					loop l
				| TTypeDecl t ->
					(match follow t.t_type with
					| TEnum (e,_) -> loop ((TEnumDecl e) :: l)
					| _ -> loop l)
				| TEnumDecl e ->
					try
						let ef = PMap.find i e.e_constrs in
						mk (TEnumField (e,i)) (monomorphs e.e_types ef.ef_type) p
					with
						Not_found -> loop l
		in
		let e = loop ctx.local_types in
		if mode = MSet then
			AKNo i
		else
			AKExpr e

let rec type_field ctx e i p mode =
	let no_field() =
		if not ctx.untyped then display_error ctx (s_type (print_context()) e.etype ^ " has no field " ^ i) p;
		AKExpr (mk (TField (e,i)) (mk_mono()) p)
	in
	match follow e.etype with
	| TInst (c,params) ->
		let rec loop_dyn c params =
			match c.cl_dynamic with
			| Some t ->
				let t = apply_params c.cl_types params t in
				if (mode = MGet || mode = MCall) && PMap.mem "resolve" c.cl_fields then
					AKExpr (make_call ctx (mk (TField (e,"resolve")) (tfun [ctx.t.tstring] t) p) [Codegen.type_constant ctx.com (String i) p] t p)
				else
					AKExpr (mk (TField (e,i)) t p)
			| None ->
				match c.cl_super with
				| None -> raise Not_found
				| Some (c,params) -> loop_dyn c params
		in
		(try
			let rec share_parent csup c = if is_parent csup c then true else match csup.cl_super with None -> false | Some (csup,_) -> share_parent csup c in 
			let t , f = class_field c i in
			if e.eexpr = TConst TSuper && (match f.cf_kind with Var _ -> true | _ -> false) && Common.platform ctx.com Flash then error "Cannot access superclass variable for calling : needs to be a proper method" p;
			if not f.cf_public && not (share_parent c ctx.curclass) && not ctx.untyped then display_error ctx ("Cannot access to private field " ^ i) p;
			field_access ctx mode f (apply_params c.cl_types params t) e p
		with Not_found -> try
			using_field ctx mode e i p
		with Not_found -> try
			loop_dyn c params
		with Not_found ->
			if PMap.mem i c.cl_statics then error ("Cannot access static field " ^ i ^ " from a class instance") p;
			(*
				This is a fix to deal with optimize_completion which will call iterator()
				on the expression for/in, which vectors do no have.
			*)
			if ctx.com.display && i = "iterator" && c.cl_path = (["flash"],"Vector") then begin
				let it = TAnon {
					a_fields = PMap.add "next" (mk_field "next" (TFun([],List.hd params)) p) PMap.empty;
					a_status = ref Closed;
				} in
				AKExpr (mk (TField (e,i)) (TFun([],it)) p)
			end else
			no_field())
	| TDynamic t ->
		(try
			using_field ctx mode e i p
		with Not_found ->
			AKExpr (mk (TField (e,i)) t p))
	| TAnon a ->
		(try
			let f = PMap.find i a.a_fields in
			if not f.cf_public && not ctx.untyped then begin
				match !(a.a_status) with
				| Closed -> () (* always allow anon private fields access *)
				| Statics c when is_parent c ctx.curclass -> ()
				| _ -> display_error ctx ("Cannot access to private field " ^ i) p
			end;
			field_access ctx mode f (field_type f) e p
		with Not_found ->
			if is_closed a then try
				using_field ctx mode e i p
			with Not_found ->
				no_field()
			else
			let f = {
				cf_name = i;
				cf_type = mk_mono();
				cf_doc = None;
				cf_meta = no_meta;
				cf_public = true;
				cf_pos = p;
				cf_kind = Var { v_read = AccNormal; v_write = (match mode with MSet -> AccNormal | MGet | MCall -> AccNo) };
				cf_expr = None;
				cf_params = [];
			} in
			a.a_fields <- PMap.add i f a.a_fields;
			field_access ctx mode f (field_type f) e p
		)
	| TMono r ->
		if ctx.untyped && (match ctx.com.platform with Flash8 -> Common.defined ctx.com "swf-mark" | _ -> false) then ctx.com.warning "Mark" p;
		let f = {
			cf_name = i;
			cf_type = mk_mono();
			cf_doc = None;
			cf_meta = no_meta;
			cf_public = true;
			cf_pos = p;
			cf_kind = Var { v_read = AccNormal; v_write = (match mode with MSet -> AccNormal | MGet | MCall -> AccNo) };
			cf_expr = None;
			cf_params = [];
		} in
		let x = ref Opened in
		let t = TAnon { a_fields = PMap.add i f PMap.empty; a_status = x } in
		ctx.opened <- x :: ctx.opened;
		r := Some t;
		field_access ctx mode f (field_type f) e p
	| _ ->
		try using_field ctx mode e i p with Not_found -> no_field()

let type_callback ctx e params p =
	let e = type_expr ctx e true in
	let args,ret = match follow e.etype with TFun(args, ret) -> args, ret | _ -> error "First parameter of callback is not a function" p in
	let vexpr v = mk (TLocal v) v.v_type p in
	let acount = ref 0 in
	let alloc_name n =
		if n = "" || String.length n > 2 then begin
			incr acount;
			"a" ^ string_of_int !acount;
		end else
			n
	in
	let rec loop args params given_args missing_args ordered_args = match args, params with
		| [], [] -> given_args,missing_args,ordered_args
		| [], _ -> error "Too many callback arguments" p
		| (n,o,t) :: args , [] when o ->
			let a = match ctx.com.platform with Neko | Php -> (ordered_args @ [(mk (TConst TNull) t_dynamic p)]) | _ -> ordered_args in
			loop args [] given_args missing_args a
		| (n,o,t) :: args , ([] as params)
		| (n,o,t) :: args , (EConst(Ident "_"),_) :: params ->
			let v = alloc_var (alloc_name n) t in
			loop args params given_args (missing_args @ [v,o,None]) (ordered_args @ [vexpr v])
		| (n,o,t) :: args , param :: params ->
			let e = type_expr ctx param true in
			unify ctx e.etype t p;
			let v = alloc_var (alloc_name n) t in
			loop args params (given_args @ [v,o,Some e]) missing_args (ordered_args @ [vexpr v])
	in
	let given_args,missing_args,ordered_args = loop args params [] [] [] in
	let loc = alloc_var "f" e.etype in
	let given_args = (loc,false,Some e) :: given_args in
	let fun_args l = List.map (fun (v,o,_) -> v.v_name, o, v.v_type) l in
	let t_inner = TFun(fun_args missing_args, ret) in
	let call = make_call ctx (vexpr loc) ordered_args ret p in
	let func = mk (TFunction {
		tf_args = List.map (fun (v,_,_) -> v,None) missing_args;
		tf_type = ret;
		tf_expr = mk (TReturn (Some call)) ret p;
	}) t_inner p in
	let func = mk (TFunction {
		tf_args = List.map (fun (v,_,_) -> v,None) given_args;
		tf_type = t_inner;
		tf_expr = mk (TReturn (Some func)) t_inner p;
	}) (TFun(fun_args given_args, t_inner)) p in
	make_call ctx func (List.map (fun (_,_,e) -> (match e with Some e -> e | None -> assert false)) given_args) t_inner p

(*
	We want to try unifying as an integer and apply side effects.
	However, in case the value is not a normal Monomorph but one issued
	from a Dynamic relaxation, we will instead unify with float since
	we don't want to accidentaly truncate the value
*)
let unify_int ctx e k =
	let is_dynamic t =
		match follow t with
		| TDynamic _ -> true
		| _ -> false
	in
	let is_dynamic_array t =
		match follow t with
		| TInst (_,[p]) -> is_dynamic p
		| _ -> true
	in
	let is_dynamic_field t f =
		match follow t with
		| TAnon a ->
			(try is_dynamic (PMap.find f a.a_fields).cf_type with Not_found -> false)
		| TInst (c,pl) ->
			(try is_dynamic (apply_params c.cl_types pl (fst (class_field c f))) with Not_found -> false)
		| _ ->
			true
	in
	let is_dynamic_return t =
		match follow t with
		| TFun (_,r) -> is_dynamic r
		| _ -> true
	in
	(*
		This is some quick analysis that matches the most common cases of dynamic-to-mono convertions
	*)
	let rec maybe_dynamic_mono e =
		match e.eexpr with
		| TLocal _ -> is_dynamic e.etype
		| TArray({ etype = t } as e,_) -> is_dynamic_array t || maybe_dynamic_rec e t
		| TField({ etype = t } as e,f) -> is_dynamic_field t f || maybe_dynamic_rec e t
		| TCall({ etype = t } as e,_) -> is_dynamic_return t || maybe_dynamic_rec e t
		| TParenthesis e -> maybe_dynamic_mono e
		| TIf (_,a,Some b) -> maybe_dynamic_mono a || maybe_dynamic_mono b
		| _ -> false
	and maybe_dynamic_rec e t =
		match follow t with
		| TMono _ | TDynamic _ -> maybe_dynamic_mono e
		(* we might have inferenced a tmono into a single field *)
		| TAnon a when !(a.a_status) = Opened -> maybe_dynamic_mono e
		| _ -> false
	in
	match k with
	| KUnk | KDyn when maybe_dynamic_mono e ->
		unify ctx e.etype ctx.t.tfloat e.epos;
		false
	| _ ->
		unify ctx e.etype ctx.t.tint e.epos;
		true

let rec type_binop ctx op e1 e2 p =
	match op with
	| OpAssign ->
		let e1 = type_access ctx (fst e1) (snd e1) MSet in
		let e2 = type_expr_with_type ~unify ctx e2 (match e1 with AKNo _ | AKInline _ | AKUsing _ | AKMacro _ -> None | AKExpr e | AKField (e,_) | AKSet(e,_,_,_) -> Some e.etype) in
		(match e1 with
		| AKNo s -> error ("Cannot access field or identifier " ^ s ^ " for writing") p
		| AKExpr e1 | AKField (e1,_) ->
			unify ctx e2.etype e1.etype p;
			check_assign ctx e1;
			(match e1.eexpr , e2.eexpr with
			| TLocal i1 , TLocal i2 when i1 == i2 -> error "Assigning a value to itself" p
			| TField ({ eexpr = TConst TThis },i1) , TField ({ eexpr = TConst TThis },i2) when i1 = i2 ->
				error "Assigning a value to itself" p
			| _ , _ -> ());
			mk (TBinop (op,e1,e2)) e1.etype p
		| AKSet (e,m,t,_) ->
			unify ctx e2.etype t p;
			make_call ctx (mk (TField (e,m)) (tfun [t] t) p) [e2] t p
		| AKInline _ | AKUsing _ | AKMacro _ ->
			assert false)
	| OpAssignOp op ->
		(match type_access ctx (fst e1) (snd e1) MSet with
		| AKNo s -> error ("Cannot access field or identifier " ^ s ^ " for writing") p
		| AKExpr e | AKField (e,_) ->
			let eop = type_binop ctx op e1 e2 p in
			(match eop.eexpr with
			| TBinop (_,_,e2) ->
				unify ctx eop.etype e.etype p;
				check_assign ctx e;
				mk (TBinop (OpAssignOp op,e,e2)) e.etype p;
			| _ ->
				assert false)
		| AKSet (e,m,t,f) ->
			let l = save_locals ctx in
			let v = gen_local ctx e.etype in
			let ev = mk (TLocal v) e.etype p in
			let get = type_binop ctx op (EField ((EConst (Ident v.v_name),p),f),p) e2 p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,Some e]) ctx.t.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [t] t) p) [get] t p
			]) t p
		| AKInline _ | AKUsing _ | AKMacro _ ->
			assert false)
	| _ ->
	let e1 = type_expr ctx e1 in
	let e2 = type_expr ctx e2 in
	let tint = ctx.t.tint in
	let tfloat = ctx.t.tfloat in
	let mk_op t = mk (TBinop (op,e1,e2)) t p in
	match op with
	| OpAdd ->
		mk_op (match classify e1.etype, classify e2.etype with
		| KInt , KInt ->
			tint
		| KFloat , KInt
		| KInt, KFloat
		| KFloat, KFloat ->
			tfloat
		| KUnk , KInt ->
			if unify_int ctx e1 KUnk then tint else tfloat
		| KUnk , KFloat
		| KUnk , KString  ->
			unify ctx e1.etype e2.etype e1.epos;
			e1.etype
		| KInt , KUnk ->
			if unify_int ctx e2 KUnk then tint else tfloat
		| KFloat , KUnk
		| KString , KUnk ->
			unify ctx e2.etype e1.etype e2.epos;
			e2.etype
		| _ , KString
		| _ , KDyn ->
			e2.etype
		| KString , _
		| KDyn , _ ->
			e1.etype
		| KUnk , KUnk ->
			let ok1 = unify_int ctx e1 KUnk in
			let ok2 = unify_int ctx e2 KUnk in
			if ok1 && ok2 then tint else tfloat
		| KParam t1, KParam t2 when t1 == t2 ->
			t1
		| KParam t, KInt | KInt, KParam t ->
			t
		| KParam _, KFloat | KFloat, KParam _ | KParam _, KParam _ ->
			tfloat
		| KParam _, _
		| _, KParam _
		| KOther, _
		| _ , KOther ->
			let pr = print_context() in
			error ("Cannot add " ^ s_type pr e1.etype ^ " and " ^ s_type pr e2.etype) p
		)
	| OpAnd
	| OpOr
	| OpXor
	| OpShl
	| OpShr
	| OpUShr ->
		let i = tint in
		unify ctx e1.etype i e1.epos;
		unify ctx e2.etype i e2.epos;
		mk_op i
	| OpMod
	| OpMult
	| OpDiv
	| OpSub ->
		let result = ref (if op = OpDiv then tfloat else tint) in
		(match classify e1.etype, classify e2.etype with
		| KFloat, KFloat ->
			result := tfloat
		| KParam t1, KParam t2 when t1 == t2 ->
			if op <> OpDiv then result := t1
		| KParam _, KParam _ ->
			result := tfloat
		| KParam t, KInt | KInt, KParam t ->
			if op <> OpDiv then result := t
		| KParam _, KFloat | KFloat, KParam _ ->
			result := tfloat
		| KFloat, k ->
			ignore(unify_int ctx e2 k);
			result := tfloat
		| k, KFloat ->
			ignore(unify_int ctx e1 k);
			result := tfloat
		| k1 , k2 ->
			let ok1 = unify_int ctx e1 k1 in
			let ok2 = unify_int ctx e2 k2 in
			if not ok1 || not ok2  then result := tfloat;
		);
		mk_op !result
	| OpEq
	| OpNotEq ->
		(try
			unify_raise ctx e1.etype e2.etype p
		with
			Error (Unify _,_) -> unify ctx e2.etype e1.etype p);
		mk_op ctx.t.tbool
	| OpGt
	| OpGte
	| OpLt
	| OpLte ->
		(match classify e1.etype, classify e2.etype with
		| KInt , KInt | KInt , KFloat | KFloat , KInt | KFloat , KFloat | KString , KString -> ()
		| KInt , KUnk -> ignore(unify_int ctx e2 KUnk)
		| KFloat , KUnk | KString , KUnk -> unify ctx e2.etype e1.etype e2.epos
		| KUnk , KInt -> ignore(unify_int ctx e1 KUnk)
		| KUnk , KFloat | KUnk , KString -> unify ctx e1.etype e2.etype e1.epos
		| KUnk , KUnk ->
			ignore(unify_int ctx e1 KUnk);
			ignore(unify_int ctx e2 KUnk);
		| KDyn , KInt | KDyn , KFloat | KDyn , KString -> ()
		| KInt , KDyn | KFloat , KDyn | KString , KDyn -> ()
		| KDyn , KDyn -> ()
		| KParam _ , x | x , KParam _ when x <> KString && x <> KOther -> ()
		| KDyn , KUnk
		| KUnk , KDyn
		| KString , KInt
		| KString , KFloat
		| KInt , KString
		| KFloat , KString
		| KParam _ , _
		| _ , KParam _
		| KOther , _
		| _ , KOther ->
			let pr = print_context() in
			error ("Cannot compare " ^ s_type pr e1.etype ^ " and " ^ s_type pr e2.etype) p
		);
		mk_op ctx.t.tbool
	| OpBoolAnd
	| OpBoolOr ->
		let b = ctx.t.tbool in
		unify ctx e1.etype b p;
		unify ctx e2.etype b p;
		mk_op b
	| OpInterval ->
		let t = Typeload.load_core_type ctx "IntIter" in
		unify ctx e1.etype tint e1.epos;
		unify ctx e2.etype tint e2.epos;
		mk (TNew ((match t with TInst (c,[]) -> c | _ -> assert false),[],[e1;e2])) t p
	| OpAssign
	| OpAssignOp _ ->
		assert false

and type_unop ctx op flag e p =
	let set = (op = Increment || op = Decrement) in
	let acc = type_access ctx (fst e) (snd e) (if set then MSet else MGet) in
	let access e =
		let t = (match op with
		| Not ->
			unify ctx e.etype ctx.t.tbool e.epos;
			ctx.t.tbool
		| Increment
		| Decrement
		| Neg
		| NegBits ->
			if set then check_assign ctx e;
			(match classify e.etype with
			| KFloat -> ctx.t.tfloat
			| KParam t ->
				unify ctx e.etype ctx.t.tfloat e.epos;
				t
			| k ->
				if unify_int ctx e k then ctx.t.tint else ctx.t.tfloat)
		) in
		mk (TUnop (op,flag,e)) t p
	in
	match acc with
	| AKExpr e | AKField (e,_) -> access e
	| AKInline _ | AKUsing _ when not set -> access (acc_get ctx acc p)
	| AKNo s ->
		error ("The field or identifier " ^ s ^ " is not accessible for " ^ (if set then "writing" else "reading")) p
	| AKInline _ | AKUsing _ | AKMacro _ ->
		error "This kind of operation is not supported" p
	| AKSet (e,m,t,f) ->
		let l = save_locals ctx in
		let v = gen_local ctx e.etype in
		let ev = mk (TLocal v) e.etype p in
		let op = (match op with Increment -> OpAdd | Decrement -> OpSub | _ -> assert false) in
		let one = (EConst (Int "1"),p) in
		let eget = (EField ((EConst (Ident v.v_name),p),f),p) in
		match flag with
		| Prefix ->
			let get = type_binop ctx op eget one p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,Some e]) ctx.t.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [t] t) p) [get] t p
			]) t p
		| Postfix ->
			let v2 = gen_local ctx t in
			let ev2 = mk (TLocal v2) t p in
			let get = type_expr ctx eget in
			let plusone = type_binop ctx op (EConst (Ident v2.v_name),p) one p in
			unify ctx get.etype t p;
			l();
			mk (TBlock [
				mk (TVars [v,Some e; v2,Some get]) ctx.t.tvoid p;
				make_call ctx (mk (TField (ev,m)) (tfun [plusone.etype] t) p) [plusone] t p;
				ev2
			]) t p

and type_switch ctx e cases def need_val p =
	let eval = type_expr ctx e in
	let old = ctx.local_types in
	let enum = ref None in
	let used_cases = Hashtbl.create 0 in
	let is_fake_enum e =
		e.e_path = ([],"Bool") || has_meta ":fakeEnum" e.e_meta
	in
	(match follow eval.etype with
	| TEnum (e,_) when is_fake_enum e -> ()
	| TEnum (e,params) ->
		enum := Some (Some (e,params));
		ctx.local_types <- TEnumDecl e :: ctx.local_types
	| TMono _ ->
		enum := Some None;
	| t ->
		if t == t_dynamic then enum := Some None
	);
	let case_expr c =
		enum := None;
		(* this inversion is needed *)
		unify ctx eval.etype c.etype c.epos;
		CExpr c
	in
	let type_match e en s pl =
		let p = e.epos in
		let params = (match !enum with
			| None ->
				assert false
			| Some None when is_fake_enum en ->
				raise Exit
			| Some None ->
				let params = List.map (fun _ -> mk_mono()) en.e_types in
				enum := Some (Some (en,params));
				unify ctx eval.etype (TEnum (en,params)) p;
				params
			| Some (Some (en2,params)) ->
				if en != en2 then error ("This constructor is part of enum " ^ s_type_path en.e_path ^ " but is matched with enum " ^ s_type_path en2.e_path) p;
				params
		) in
		if Hashtbl.mem used_cases s then error "This constructor has already been used" p;
		Hashtbl.add used_cases s ();
		let cst = (try PMap.find s en.e_constrs with Not_found -> assert false) in
		let pl = (match cst.ef_type with
		| TFun (l,_) ->
			let pl = (if List.length l = List.length pl then pl else
				match pl with
				| [None] -> List.map (fun _ -> None) l
				| _ -> error ("This constructor requires " ^ string_of_int (List.length l) ^ " arguments") p
			) in
			Some (List.map2 (fun p (_,_,t) -> match p with None -> None | Some p -> Some (p, apply_params en.e_types params t)) pl l)
		| TEnum _ ->
			if pl <> [] then error "This constructor does not require any argument" p;
			None
		| _ -> assert false
		) in
		CMatch (cst,pl,p)
	in
	let type_case efull e pl p =
		try
			(match !enum, e with
			| None, _ -> raise Exit
			| Some (Some (en,params)), (EConst (Ident i | Type i),p) ->
				if not (PMap.mem i en.e_constrs) then error ("This constructor is not part of the enum " ^ s_type_path en.e_path) p;
			| _ -> ());
			let pl = List.map (fun e ->
				match fst e with
				| EConst (Ident "_") -> None
				| EConst (Ident i | Type i) -> Some i
				| _ -> raise Exit
			) pl in
			let e = type_expr ctx e in
			(match e.eexpr with
			| TEnumField (en,s) | TClosure ({ eexpr = TTypeExpr (TEnumDecl en) },s) -> type_match e en s pl
			| _ -> if pl = [] then case_expr e else raise Exit)
		with Exit ->
			case_expr (type_expr ctx efull)
	in
	let cases = List.map (fun (el,e2) ->
		if el = [] then error "Case must match at least one expression" (pos e2);
		let el = List.map (fun e ->
			match e with
			| (ECall (c,pl),p) -> type_case e c pl p
			| e -> type_case e e [] (snd e)
		) el in
		el, e2
	) cases in
	ctx.local_types <- old;
	let el = ref [] in
	let type_case_code e =
		let e = (match e with
			| (EBlock [],p) when need_val -> (EConst (Ident "null"),p)
			| _ -> e
		) in
		let e = type_expr ~need_val ctx e in
		el := !el @ [e];
		e
	in
	let def = (match def with
		| None -> None
		| Some e ->
			let locals = save_locals ctx in
			let e = type_case_code e in
			locals();
			Some e
	) in
	match !enum with
	| Some (Some (enum,enparams)) ->
		let same_params p1 p2 =
			let l1 = (match p1 with None -> [] | Some l -> l) in
			let l2 = (match p2 with None -> [] | Some l -> l) in
			let rec loop = function
				| [] , [] -> true
				| None :: l , [] | [] , None :: l -> loop (l,[])
				| None :: l1, None :: l2 -> loop (l1,l2)
				| Some (n1,t1) :: l1, Some (n2,t2) :: l2 ->
					n1 = n2 && type_iseq t1 t2 && loop (l1,l2)
				| _ -> false
			in
			loop (l1,l2)
		in
		let matchs (el,e) =
			match el with
			| CMatch (c,params,p1) :: l ->
				let params = ref params in
				let cl = List.map (fun c ->
					match c with
					| CMatch (c,p,p2) ->
						if not (same_params p !params) then display_error ctx "Constructors parameters differs : should be same name, same type, and same position" p2;
						if p <> None then params := p;
						c
					| _ -> assert false
				) l in
				let locals = save_locals ctx in
				let params = (match !params with
					| None -> None
					| Some l ->
						let has = ref false in
						let l = List.map (fun v ->
							match v with
							| None -> None
							| Some (v,t) -> has := true; Some (add_local ctx v t)
						) l in
						if !has then Some l else None
				) in
				let e = type_case_code e in
				locals();
				(c :: cl) , params, e
			| _ ->
				assert false
		in
		let indexes (el,vars,e) =
			List.map (fun c -> c.ef_index) el, vars, e
		in
		let cases = List.map matchs cases in
		(match def with
		| Some _ -> ()
		| None ->
			let l = PMap.fold (fun c acc ->
				if Hashtbl.mem used_cases c.ef_name then acc else c.ef_name :: acc
			) enum.e_constrs [] in
			match l with
			| [] -> ()
			| _ -> display_error ctx ("Some constructors are not matched : " ^ String.concat "," l) p
		);
		let t = if not need_val then ctx.t.tvoid else unify_min_raise ctx !el in
		mk (TMatch (eval,(enum,enparams),List.map indexes cases,def)) t p
	| _ ->
		let consts = Hashtbl.create 0 in
		let exprs (el,e) =
			let el = List.map (fun c ->
				match c with
				| CExpr (({ eexpr = TConst c }) as e) ->
					if Hashtbl.mem consts c then error "Duplicate constant in switch" e.epos;
					Hashtbl.add consts c true;
					e
				| CExpr c -> c
				| CMatch (_,_,p) -> error "You cannot use a normal switch on an enum constructor" p
			) el in
			let locals = save_locals ctx in
			let e = type_case_code e in
			locals();
			el, e
		in
		let cases = List.map exprs cases in
		let t = if not need_val then ctx.t.tvoid else unify_min_raise ctx !el in
		mk (TSwitch (eval,cases,def)) t p

and type_ident_noerr ctx i is_type p mode =
	try
		type_ident ctx i is_type p mode
	with Not_found -> try
		(* lookup type *)
		if not is_type then raise Not_found;
		let e = (try type_type ctx ([],i) p with Error (Module_not_found ([],name),_) when name = i -> raise Not_found) in
		AKExpr e
	with Not_found ->
		if ctx.untyped then begin
			if i = "__this__" then
				AKExpr (mk (TConst TThis) ctx.tthis p)
			else
				let t = mk_mono() in
				AKExpr (mk (TLocal (alloc_var i t)) t p)
		end else begin
			if ctx.curfun = FStatic && PMap.mem i ctx.curclass.cl_fields then error ("Cannot access " ^ i ^ " in static function") p;
			let err = Unknown_ident i in
			if ctx.in_display then raise (Error (err,p));
			if ctx.com.display then begin
				display_error ctx (error_msg err) p;
				let t = mk_mono() in
				AKExpr (mk (TLocal (add_local ctx i t)) t p)
			end else begin
				if List.exists (fun (i2,_) -> i2 = i) ctx.type_params then
					display_error ctx ("Type parameter " ^ i ^ " is only available at compilation and is not a runtime value") p
				else
					display_error ctx (error_msg err) p;
				AKExpr (mk (TConst TNull) t_dynamic p)
			end
		end

and type_expr_with_type ~unify ctx e t =
	match e with
	| (EParenthesis e,p) ->
		let e = type_expr_with_type ~unify ctx e t in
		mk (TParenthesis e) e.etype p;
	| (ECall (e,el),p) ->
		type_call ctx e el t p
	| (EFunction _,_) ->
		let old = ctx.param_type in
		(try
			ctx.param_type <- t;
			let e = type_expr ctx e in
			ctx.param_type <- old;
			e
		with
			exc ->
				ctx.param_type <- old;
				raise exc)
	| (EConst (Ident s | Type s),p) ->
		(try
			acc_get ctx (type_ident ctx s (match fst e with EConst (Ident _) -> false | _ -> true) p MGet) p
		with Not_found -> try
			(match t with
			| None -> raise Not_found
			| Some t ->
				match follow t with
				| TEnum (e,pl) ->
					(try
						let ef = PMap.find s e.e_constrs in
						mk (TEnumField (e,s)) (apply_params e.e_types pl ef.ef_type) p
					with Not_found ->
						display_error ctx ("Identifier '" ^ s ^ "' is not part of enum " ^ s_type_path e.e_path) p;
						mk (TConst TNull) t p)
				| _ -> raise Not_found)
		with Not_found ->
			type_expr ctx e)
	| (EArrayDecl el,p) ->
		(match t with
		| None -> type_expr ctx e
		| Some t ->
			match follow t with
			| TInst ({ cl_path = [],"Array" },[tp]) ->
				(match follow tp with
				| TMono _ ->
					type_expr ctx e
				| _ ->
					let el = List.map (fun e ->
						let e = type_expr_with_type ~unify ctx e (Some tp) in
						unify ctx e.etype tp e.epos;
						e
					) el in
					mk (TArrayDecl el) t p)
			| _ ->
				type_expr ctx e)
	| (EObjectDecl el,p) ->
		(match t with
		| None -> type_expr ctx e
		| Some t ->
			match follow t with
			| TAnon a ->
				let fields = Hashtbl.create 0 in
				let el = List.map (fun (n, e) ->
					let n,add = object_field n in
					if Hashtbl.mem fields n then error ("Duplicate field in object declaration : " ^ n) (snd e);
					let t = try (PMap.find n a.a_fields).cf_type with Not_found -> if ctx.untyped then t_dynamic else error ("Structure has extra field : " ^ n) (snd e) in
					Hashtbl.add fields n true;
					let e = type_expr_with_type ~unify ctx e (Some t) in
					unify ctx e.etype t e.epos;
					(n,e)
				) el in
				if not ctx.untyped then	PMap.iter (fun n cf ->
						if not (has_meta ":optional" cf.cf_meta) && not (Hashtbl.mem fields n) then error ("Structure has no field " ^ n) p;
					) a.a_fields;
				a.a_status := Closed;
				mk (TObjectDecl el) t p
			| _ ->
				type_expr ctx e)
	| _ ->
		type_expr ctx e

and type_access ctx e p mode =
	match e with
	| EConst (Ident s) ->
		type_ident_noerr ctx s false p mode
	| EConst (Type s) ->
		type_ident_noerr ctx s true p mode
	| EField _
	| EType _ ->
		let fields path e =
			List.fold_left (fun e (f,_,p) ->
				let e = acc_get ctx (e MGet) p in
				type_field ctx e f p
			) e path
		in
		let type_path path =
			let rec loop acc path =
				match path with
				| [] ->
					(match List.rev acc with
					| [] -> assert false
					| (name,flag,p) :: path ->
						try
							fields path (type_access ctx (EConst (if flag then Type name else Ident name)) p)
						with
							Error (Unknown_ident _,p2) as e when p = p2 ->
								try
									let path = ref [] in
									let name , _ , _ = List.find (fun (name,flag,p) ->
										if flag then
											true
										else begin
											path := name :: !path;
											false
										end
									) (List.rev acc) in
									raise (Error (Module_not_found (List.rev !path,name),p))
								with
									Not_found ->
										if ctx.in_display then raise (Parser.TypePath (List.map (fun (n,_,_) -> n) (List.rev acc),None));
										raise e)
				| (_,false,_) as x :: path ->
					loop (x :: acc) path
				| (name,true,p) as x :: path ->
					let pack = List.rev_map (fun (x,_,_) -> x) acc in
					let def() =
						try
							let e = type_type ctx (pack,name) p in
							fields path (fun _ -> AKExpr e)
						with
							Error (Module_not_found m,_) when m = (pack,name) ->
								loop ((List.rev path) @ x :: acc) []
					in
					match path with
					| (sname,true,p) :: path ->
						let get_static t =
							fields ((sname,true,p) :: path) (fun _ -> AKExpr (type_module_type ctx t None p))
						in
						let check_module m v =
							try
								let md = Typeload.load_module ctx m p in
								(* first look for existing subtype *)
								(try
									let t = List.find (fun t -> not (t_infos t).mt_private && t_path t = (fst m,sname)) md.m_types in
									Some (fields path (fun _ -> AKExpr (type_module_type ctx t None p)))
								with Not_found -> try
								(* then look for main type statics *)
									if fst m = [] then raise Not_found; (* ensure that we use def() to resolve local types first *)
									let t = List.find (fun t -> not (t_infos t).mt_private && t_path t = m) md.m_types in
									Some (get_static t)
								with Not_found ->
									None)
							with Error (Module_not_found m2,_) when m = m2 ->
								None
						in
						let rec loop pack =
							match check_module (pack,name) sname with
							| Some r -> r
							| None ->
								match List.rev pack with
								| [] -> def()
								| _ :: l -> loop (List.rev l)
						in
						(match pack with
						| [] -> loop (fst ctx.current.m_path)
						| _ ->
							match check_module (pack,name) sname with
							| Some r -> r
							| None -> def());
					| _ -> def()
			in
			match path with
			| [] -> assert false
			| (name,_,p) :: pnext ->
				try
					fields pnext (fun _ -> type_ident ctx name false p MGet)
				with
					Not_found -> loop [] path
		in
		let rec loop acc e =
			match fst e with
			| EField (e,s) ->
				loop ((s,false,p) :: acc) e
			| EType (e,s) ->
				loop ((s,true,p) :: acc) e
			| EConst (Ident i) ->
				type_path ((i,false,p) :: acc)
			| EConst (Type i) ->
				type_path ((i,true,p) :: acc)
			| _ ->
				fields acc (type_access ctx (fst e) (snd e))
		in
		loop [] (e,p) mode
	| EArray (e1,e2) ->
		let e1 = type_expr ctx e1 in
		let e2 = type_expr ctx e2 in
		unify ctx e2.etype ctx.t.tint e2.epos;
		let rec loop et =
			match follow et with
			| TInst ({ cl_array_access = Some t; cl_types = pl },tl) ->
				apply_params pl tl t
			| TInst ({ cl_super = Some (c,stl); cl_types = pl },tl) ->
				apply_params pl tl (loop (TInst (c,stl)))
			| TInst ({ cl_path = [],"ArrayAccess" },[t]) ->
				t
			| _ ->
				let pt = mk_mono() in
				let t = ctx.t.tarray pt in
				unify ctx e1.etype t e1.epos;
				pt
		in
		let pt = loop e1.etype in
		AKExpr (mk (TArray (e1,e2)) pt p)
	| _ ->
		AKExpr (type_expr ctx (e,p))

and type_exprs_unified ctx ?(need_val=true) el =
	match el with
	| [] -> [], mk_mono()
	| [e] ->
		let te = type_expr ctx ~need_val e in
		[te], te.etype
	| _ ->
		let tl = List.map (type_expr ctx ~need_val) el in
		let t = try unify_min_raise ctx tl with _ -> t_dynamic in
		tl, t

and type_expr ctx ?(need_val=true) (e,p) =
	match e with
	| EField ((EConst (String s),p),"code") ->
		if UTF8.length s <> 1 then error "String must be a single UTF8 char" p;
		mk (TConst (TInt (Int32.of_int (UChar.code (UTF8.get s 0))))) ctx.t.tint p
	| EField _
	| EType _
	| EArray _
	| EConst (Ident _)
	| EConst (Type _) ->
		acc_get ctx (type_access ctx e p MGet) p
	| EConst (Regexp (r,opt)) ->
		let str = mk (TConst (TString r)) ctx.t.tstring p in
		let opt = mk (TConst (TString opt)) ctx.t.tstring p in
		let t = Typeload.load_core_type ctx "EReg" in
		mk (TNew ((match t with TInst (c,[]) -> c | _ -> assert false),[],[str;opt])) t p
	| EConst c ->
		Codegen.type_constant ctx.com c p
    | EBinop (op,e1,e2) ->
		type_binop ctx op e1 e2 p
	| EBlock [] when need_val ->
		type_expr ctx (EObjectDecl [],p)
	| EBlock l ->
		let locals = save_locals ctx in
		let rec loop = function
			| [] -> []
			| [e] ->
				(try
					[type_expr ctx ~need_val e]
				with
					Error (e,p) -> display_error ctx (error_msg e) p; [])
			| e :: l ->
				try
					let e = type_expr ctx ~need_val:false e in
					e :: loop l
				with
					Error (e,p) -> display_error ctx (error_msg e) p; loop l
		in
		let l = loop l in
		locals();
		let rec loop = function
			| [] -> ctx.t.tvoid
			| [e] -> e.etype
			| _ :: l -> loop l
		in
		mk (TBlock l) (loop l) p
	| EParenthesis e ->
		let e = type_expr ctx ~need_val e in
		mk (TParenthesis e) e.etype p
	| EObjectDecl fl ->
		let rec loop (l,acc) (f,e) =
			let f,add = object_field f in
			if PMap.mem f acc then error ("Duplicate field in object declaration : " ^ f) p;
			let e = type_expr ctx e in
			let cf = mk_field f e.etype e.epos in
			((f,e) :: l, if add then PMap.add f cf acc else acc)
		in
		let fields , types = List.fold_left loop ([],PMap.empty) fl in
		let x = ref Const in
		ctx.opened <- x :: ctx.opened;
		mk (TObjectDecl (List.rev fields)) (TAnon { a_fields = types; a_status = x }) p
	| EArrayDecl el ->
		let tl, t = type_exprs_unified ctx el in
		mk (TArrayDecl tl) (ctx.t.tarray t) p
	| EVars vl ->
		let vl = List.map (fun (v,t,e) ->
			try
				let t = Typeload.load_type_opt ctx p t in
				let e = (match e with
					| None -> None
					| Some e ->
						let e = type_expr_with_type ~unify ctx e (Some t) in
						unify ctx e.etype t p;
						Some e
				) in
				add_local ctx v t, e
			with
				Error (e,p) ->
					display_error ctx (error_msg e) p;
					add_local ctx v t_dynamic, None
		) vl in
		mk (TVars vl) ctx.t.tvoid p
	| EFor (it,e2) ->
		let i, e1 = (match it with
			| (EIn ((EConst (Ident i | Type i),_),e),_) -> i, e
			| _ -> error "For expression should be 'v in expr'" (snd it)
		) in
		let e1 = type_expr ctx e1 in
		let old_loop = ctx.in_loop in
		let old_locals = save_locals ctx in
		ctx.in_loop <- true;
		let e = (match Optimizer.optimize_for_loop ctx i e1 e2 p with
			| Some e -> e
			| None ->
				let t, pt = Typeload.t_iterator ctx in
				let i = add_local ctx i pt in
				let e1 = (match follow e1.etype with
				| TMono _
				| TDynamic _ ->
					display_error ctx "You can't iterate on a Dynamic value, please specify Iterator or Iterable" e1.epos;
					e1
				| TLazy _ ->
					assert false
				| _ ->
					(try
						unify_raise ctx e1.etype t e1.epos;
						e1
					with Error (Unify _,_) ->
						let acc = acc_get ctx (type_field ctx e1 "iterator" e1.epos MCall) e1.epos in
						let acc = (match acc.eexpr with TClosure (e,f) -> { acc with eexpr = TField (e,f) } | _ -> acc) in
						match follow acc.etype with
						| TFun ([],it) ->
							unify ctx it t e1.epos;
							make_call ctx acc [] t e1.epos
						| _ ->
							display_error ctx "The field iterator is not a method" e1.epos;
							mk (TConst TNull) t_dynamic p
					)
				) in
				let e2 = type_expr ~need_val:false ctx e2 in
				mk (TFor (i,e1,e2)) ctx.t.tvoid p
		) in
		ctx.in_loop <- old_loop;
		old_locals();
		e
	| EIn _ ->
		error "This expression is not allowed outside a for loop" p
	| ETernary (e1,e2,e3) ->
		type_expr ctx ~need_val (EIf (e1,e2,Some e3),p)
	| EIf (e,e1,e2) ->
		let e = type_expr ctx e in
		unify ctx e.etype ctx.t.tbool e.epos;
		let e1 = type_expr ctx ~need_val e1 in
		(match e2 with
		| None ->
			if need_val then begin
				let t = ctx.t.tnull e1.etype in
				mk (TIf (e,e1,Some (null t p))) t p
			end else
				mk (TIf (e,e1,None)) ctx.t.tvoid p
		| Some e2 ->
			let e2 = type_expr ctx ~need_val e2 in
			let t = if not need_val then ctx.t.tvoid else unify_min_raise ctx [e1; e2] in
			mk (TIf (e,e1,Some e2)) t p)
	| EWhile (cond,e,NormalWhile) ->
		let old_loop = ctx.in_loop in
		let cond = type_expr ctx cond in
		unify ctx cond.etype ctx.t.tbool cond.epos;
		ctx.in_loop <- true;
		let e = type_expr ~need_val:false ctx e in
		ctx.in_loop <- old_loop;
		mk (TWhile (cond,e,NormalWhile)) ctx.t.tvoid p
	| EWhile (cond,e,DoWhile) ->
		let old_loop = ctx.in_loop in
		ctx.in_loop <- true;
		let e = type_expr ~need_val:false ctx e in
		ctx.in_loop <- old_loop;
		let cond = type_expr ctx cond in
		unify ctx cond.etype ctx.t.tbool cond.epos;
		mk (TWhile (cond,e,DoWhile)) ctx.t.tvoid p
	| ESwitch (e,cases,def) ->
		type_switch ctx e cases def need_val p
	| EReturn e ->
		let e , t = (match e with
			| None ->
				let v = ctx.t.tvoid in
				unify ctx v ctx.ret p;
				None , v
			| Some e ->
				let e = type_expr ctx e in
				unify ctx e.etype ctx.ret e.epos;
				Some e , e.etype
		) in
		mk (TReturn e) t_dynamic p
	| EBreak ->
		if not ctx.in_loop then display_error ctx "Break outside loop" p;
		mk TBreak t_dynamic p
	| EContinue ->
		if not ctx.in_loop then display_error ctx "Continue outside loop" p;
		mk TContinue t_dynamic p
	| ETry (e1,catches) ->
		let e1 = type_expr ctx ~need_val e1 in
		let catches = List.map (fun (v,t,e) ->
			let t = Typeload.load_complex_type ctx (pos e) t in
			let name = (match follow t with
				| TInst ({ cl_path = path },params) | TEnum ({ e_path = path },params) ->
					List.iter (fun pt ->
						if pt != t_dynamic then error "Catch class parameter must be Dynamic" p;
					) params;
					(match path with
					| x :: _ , _ -> x
					| [] , name -> name)
				| TDynamic _ -> ""
				| _ -> error "Catch type must be a class" p
			) in
			let locals = save_locals ctx in
			let v = add_local ctx v t in
			let e = type_expr ctx ~need_val e in
			locals();
			if need_val then unify ctx e.etype e1.etype e.epos;
			if PMap.mem name ctx.locals then error ("Local variable " ^ name ^ " is preventing usage of this type here") e.epos;
			v , e
		) catches in
		mk (TTry (e1,catches)) (if not need_val then ctx.t.tvoid else e1.etype) p
	| EThrow e ->
		let e = type_expr ctx e in
		mk (TThrow e) (mk_mono()) p
	| ECall (e,el) ->
		type_call ctx e el None p
	| ENew (t,el) ->
		let t = Typeload.load_instance ctx t p true in
		let el, c , params = (match follow t with
		| TInst (c,params) ->
			mark_used_class ctx c;
			let name = (match c.cl_path with [], name -> name | x :: _ , _ -> x) in
			if PMap.mem name ctx.locals then error ("Local variable " ^ name ^ " is preventing usage of this class here") p;
			let ct, f = get_constructor c params p in
			if not f.cf_public && not (is_parent c ctx.curclass) && not ctx.untyped then display_error ctx "Cannot access private constructor" p;
			mark_used_field ctx f;
			(match f.cf_kind with
			| Var { v_read = AccRequire r } -> error_require r p
			| _ -> ());
			let el, _ = (match follow ct with
			| TFun (args,r) ->
				unify_call_params ctx (Some ("new",f.cf_meta)) el args r p false
			| _ ->
				error "Constructor is not a function" p
			) in
			el , c , params
		| _ ->
			error (s_type (print_context()) t ^ " cannot be constructed") p
		) in
		mk (TNew (c,params,el)) t p
	| EUnop (op,flag,e) ->
		type_unop ctx op flag e p
	| EFunction (name,f) ->
		let rt = Typeload.load_type_opt ctx p f.f_type in
		let args = List.map (fun (s,opt,t,c) ->
			let t = Typeload.load_type_opt ctx p t in
			let t, c = Typeload.type_function_param ctx t c opt p in
			s , c, t
		) f.f_args in
		(match ctx.param_type with
		| None -> ()
		| Some t ->
			ctx.param_type <- None;
			match follow t with
			| TFun (args2,_) when List.length args2 = List.length args ->
				List.iter2 (fun (_,_,t1) (_,_,t2) ->
					match follow t1 with
					| TMono _ -> unify ctx t2 t1 p
					| _ -> ()
				) args args2;
			| _ -> ());
		let ft = TFun (fun_args args,rt) in
		let vname = (match name with
			| None -> None
			| Some v -> Some (add_local ctx v ft)
		) in
		let e , fargs = Typeload.type_function ctx args rt (match ctx.curfun with FStatic -> FStatic | _ -> FMemberLocal) f p in
		let f = {
			tf_args = fargs;
			tf_type = rt;
			tf_expr = e;
		} in
		let e = mk (TFunction f) ft p in
		(match vname with
		| None -> e
		| Some v ->
			let rec loop = function
				| Codegen.Block f | Codegen.Loop f | Codegen.Function f -> f loop
				| Codegen.Use v2 when v == v2 -> raise Exit
				| Codegen.Use _ | Codegen.Declare _ -> ()
			in
			let is_rec = (try Codegen.local_usage loop e; false with Exit -> true) in
			if is_rec then begin
				let vnew = add_local ctx v.v_name ft in
				mk (TVars [vnew,Some (mk (TBlock [
					mk (TVars [v,Some (mk (TConst TNull) ft p)]) ctx.t.tvoid p;
					mk (TBinop (OpAssign,mk (TLocal v) ft p,e)) ft p;
					mk (TLocal v) ft p
				]) ft p)]) ctx.t.tvoid p
			end else
				mk (TVars [v,Some e]) ctx.t.tvoid p)
	| EUntyped e ->
		let old = ctx.untyped in
		ctx.untyped <- true;
		let e = type_expr ctx ~need_val e in
		ctx.untyped <- old;
		{
			eexpr = e.eexpr;
			etype = mk_mono();
			epos = e.epos;
		}
	| ECast (e,None) ->
		let e = type_expr ctx e in
		mk (TCast (e,None)) (mk_mono()) p
	| ECast (e, Some t) ->
		(* force compilation of class "Std" since we might need it *)
		(match ctx.com.platform with
		| Js | Flash8 | Neko | Flash | Java | Cs ->
			let std = Typeload.load_type_def ctx p { tpackage = []; tparams = []; tname = "Std"; tsub = None } in
			(* ensure typing / mark for DCE *)
			ignore(follow (try PMap.find "is" (match std with TClassDecl c -> c.cl_statics | _ -> assert false) with Not_found -> assert false).cf_type)
		| Cpp | Php | Cross ->
			());
		let t = Typeload.load_complex_type ctx (pos e) t in
		let texpr = (match follow t with
		| TInst (_,params) | TEnum (_,params) ->
			List.iter (fun pt ->
				if follow pt != t_dynamic then error "Cast type parameters must be Dynamic" p;
			) params;
			(match follow t with
			| TInst (c,_) ->
				if c.cl_kind = KTypeParameter then error "Can't cast to a type parameter" p;
				TClassDecl c
			| TEnum (e,_) -> TEnumDecl e
			| _ -> assert false);
		| _ ->
			error "Cast type must be a class or an enum" p
		) in
		mk (TCast (type_expr ctx e,Some texpr)) t p
	| EDisplay (e,iscall) ->
		let old = ctx.in_display in
		ctx.in_display <- true;
		let e = (try type_expr ctx e with Error (Unknown_ident n,_) -> raise (Parser.TypePath ([n],None))) in
		ctx.in_display <- old;
		let opt_type t =
			match t with
			| TLazy f ->
				Typeload.return_partial_type := true;
				let t = (!f)() in
				Typeload.return_partial_type := false;
				t
			| _ ->
				t
		in
		let fields = (match follow e.etype with
			| TInst (c,params) ->
				let priv = is_parent c ctx.curclass in
				let merge ?(cond=(fun _ -> true)) a b =
					PMap.foldi (fun k f m -> if cond f then PMap.add k f m else m) a b
				in
				let rec loop c params =
					let m = List.fold_left (fun m (i,params) ->
						merge m (loop i params)
					) PMap.empty c.cl_implements in
					let m = (match c.cl_super with
						| None -> m
						| Some (csup,cparams) -> merge m (loop csup cparams)
					) in
					let m = merge ~cond:(fun f -> priv || f.cf_public) c.cl_fields m in
					PMap.map (fun f -> { f with cf_type = apply_params c.cl_types params (opt_type f.cf_type); cf_public = true; }) m
				in
				loop c params
			| TAnon a ->
				(match !(a.a_status) with
				| Statics c when is_parent c ctx.curclass ->
					PMap.map (fun f -> { f with cf_public = true; cf_type = opt_type f.cf_type }) a.a_fields
				| _ ->
					a.a_fields)
			| _ ->
				PMap.empty
		) in
		(*
			add 'using' methods compatible with this type
		*)
		let rec loop acc = function
			| [] -> acc
			| x :: l ->
				let acc = ref (loop acc l) in
				(match x with
				| TClassDecl c ->
					let rec dup t = Type.map dup t in
					List.iter (fun f ->
						let f = { f with cf_type = opt_type f.cf_type } in
						match follow (field_type f) with
						| TFun((_,_,TType({t_path=["haxe";"macro"], ("ExprOf"|"ExprRequire")}, [t])) :: args, ret)
						| TFun ((_,_,t) :: args, ret) when (try unify_raise ctx (dup e.etype) t e.epos; true with _ -> false) ->
							let f = { f with cf_type = TFun (args,ret); cf_params = [] } in
							if follow e.etype == t_dynamic && follow t != t_dynamic then
								()
							else
								acc := PMap.add f.cf_name f (!acc)
						| _ -> ()
					) c.cl_ordered_statics
				| _ -> ());
				!acc
		in
		let use_methods = loop PMap.empty ctx.local_using in
		let fields = PMap.fold (fun f acc -> PMap.add f.cf_name f acc) fields use_methods in
		let fields = PMap.fold (fun f acc -> f :: acc) fields [] in
		let t = (if iscall then
			match follow e.etype with
			| TFun _ -> e.etype
			| _ -> t_dynamic
		else match fields with
			| [] -> e.etype
			| _ ->
				let get_field acc f =
					if not f.cf_public then acc else (f.cf_name,f.cf_type,f.cf_doc) :: List.map (fun t -> f.cf_name,t,f.cf_doc) (get_overloads ctx p f.cf_meta) @ acc
				in
				raise (DisplayFields (List.fold_left get_field [] fields))
		) in
		(match follow t with
		| TMono _ | TDynamic _ when ctx.in_macro -> mk (TConst TNull) t p
		| _ -> raise (DisplayTypes [t]))
	| EDisplayNew t ->
		let t = Typeload.load_instance ctx t p true in
		(match follow t with
		| TInst (c,params) ->
			let ct, f = get_constructor c params p in
			raise (DisplayTypes (ct :: get_overloads ctx p f.cf_meta))
		| _ ->
			error "Not a class" p)
	| ECheckType (e,t) ->
		let e = type_expr ctx ~need_val e in
		let t = Typeload.load_complex_type ctx p t in
		unify ctx e.etype t e.epos;
		if e.etype == t then e else mk (TCast (e,None)) t p

and type_call ctx e el t p =
	match e, el with
	| (EConst (Ident "trace"),p) , e :: el ->
		if Common.defined ctx.com "no_traces" then
			null ctx.t.tvoid p
		else
		let params = (match el with [] -> [] | _ -> ["customParams",(EArrayDecl el , p)]) in
		let infos = mk_infos ctx p params in
		type_expr ctx (ECall ((EField ((EType ((EConst (Ident "haxe"),p),"Log"),p),"trace"),p),[e;EUntyped infos,p]),p)
	| (EConst (Ident "callback"),p) , e :: params ->
		type_callback ctx e params p
	| (EConst (Ident "type"),_) , [e] ->
		let e = type_expr ctx e in
		ctx.com.warning (s_type (print_context()) e.etype) e.epos;
		e
	| (EConst (Ident "__unprotect__"),_) , [(EConst (String _),_) as e] ->
		let e = type_expr ctx e in
		if Common.defined ctx.com "flash" then
			let t = tfun [e.etype] e.etype in
			mk (TCall (mk (TLocal (alloc_var "__unprotect__" t)) t p,[e])) e.etype e.epos
		else
			e
	| (EConst (Ident "super"),sp) , el ->
		if ctx.curfun <> FConstructor then error "Cannot call superconstructor outside class constructor" p;
		let el, t = (match ctx.curclass.cl_super with
		| None -> error "Current class does not have a super" p
		| Some (c,params) ->
			let ct, f = get_constructor c params p in
			mark_used_field ctx f;
			let el, _ = (match follow ct with
			| TFun (args,r) ->
				unify_call_params ctx (Some ("new",f.cf_meta)) el args r p false
			| _ ->
				error "Constructor is not a function" p
			) in
			el , TInst (c,params)
		) in
		mk (TCall (mk (TConst TSuper) t sp,el)) ctx.t.tvoid p
	| _ ->
		(match e with
		| EField ((EConst (Ident "super"),_),_) , _ | EType ((EConst (Ident "super"),_),_) , _ -> ctx.in_super_call <- true
		| _ -> ());
		let rec loop acc el =
			match acc with
			| AKInline (ethis,f,t) ->
				let params, tfunc = (match follow t with
					| TFun (args,r) -> unify_call_params ctx (Some (f.cf_name,f.cf_meta)) el args r p true
					| _ -> error (s_type (print_context()) t ^ " cannot be called") p
				) in
				make_call ctx (mk (TField (ethis,f.cf_name)) t p) params (match tfunc with TFun(_,r) -> r | _ -> assert false) p
			| AKUsing (et,ef,eparam) ->
				(match et.eexpr with
				| TField (ec,_) ->
					let acc = (type_field ctx ec ef.cf_name p MCall) in
					(match acc with
					| AKMacro _ ->
						loop acc (Interp.make_ast eparam :: el)
					| AKExpr _ | AKField _ | AKInline _ ->
						let params, tfunc = (match follow et.etype with
							| TFun ( _ :: args,r) -> unify_call_params ctx (Some (ef.cf_name,ef.cf_meta)) el args r p (ef.cf_kind = Method MethInline)
							| _ -> assert false
						) in
						let args,r = match tfunc with TFun(args,r) -> args,r | _ -> assert false in
						let et = {et with etype = TFun(("",false,eparam.etype) :: args,r)} in
						make_call ctx et (eparam::params) r p
					| _ -> assert false)
				| _ -> assert false)
			| AKMacro (ethis,f) ->
				(match ethis.eexpr with
				| TTypeExpr (TClassDecl c) ->
					(match ctx.g.do_macro ctx MExpr c.cl_path f.cf_name el p with
					| None -> type_expr ctx (EConst (Ident "null"),p)
					| Some e -> type_expr_with_type unify ctx e t)
				| _ ->
					(* member-macro call : since we will make a static call, let's found the actual class and not its subclass *)
					(match follow ethis.etype with
					| TInst (c,_) ->
						let rec loop c =
							if PMap.mem f.cf_name c.cl_fields then
								match ctx.g.do_macro ctx MExpr c.cl_path f.cf_name (Interp.make_ast ethis :: el) p with
								| None -> type_expr ctx (EConst (Ident "null"),p)
								| Some e -> type_expr ctx e
							else
								match c.cl_super with
								| None -> assert false
								| Some (csup,_) -> loop csup
						in
						loop c
					| _ -> assert false))
			| AKNo _ | AKSet _ as acc ->
				ignore(acc_get ctx acc p);
				assert false
			| AKExpr e | AKField (e,_) as acc ->
				let el , t, e = (match follow e.etype with
				| TFun (args,r) ->
					let fopts = (match acc with AKField (_,f) -> Some (f.cf_name,f.cf_meta) | _ -> match e.eexpr with TField (e,f) -> Some (f,[]) | _ -> None) in
					let el, tfunc = unify_call_params ctx fopts el args r p false in
					el,(match tfunc with TFun(_,r) -> r | _ -> assert false), {e with etype = tfunc}
				| TMono _ ->
					let t = mk_mono() in
					let el = List.map (type_expr ctx) el in
					unify ctx (tfun (List.map (fun e -> e.etype) el) t) e.etype e.epos;
					el, t, e
				| t ->
					let el = List.map (type_expr ctx) el in
					el, (if t == t_dynamic then
						t_dynamic
					else if ctx.untyped then
						mk_mono()
					else
						error (s_type (print_context()) e.etype ^ " cannot be called") e.epos), e
				) in
				if ctx.com.dead_code_elimination then
					(match e.eexpr, el with
					| TField ({ eexpr = TTypeExpr (TClassDecl { cl_path = [],"Std"  }) },"string"), [ep] -> check_to_string ctx ep.etype
					| _ -> ());
				mk (TCall (e,el)) t p
		in
		loop (type_access ctx (fst e) (snd e) MCall) el

and check_to_string ctx t =
	match follow t with
	| TInst (c,_) ->
		(try
			let _, f = class_field c "toString" in
			ignore(follow f.cf_type);
		with Not_found ->
			())
	| _ -> ()

(* ---------------------------------------------------------------------- *)
(* DEAD CODE ELIMINATION *)

let dce_check_class ctx c =
	let keep_whole_class = c.cl_extern || c.cl_interface || has_meta ":keep" c.cl_meta || (match c.cl_path with ["php"],"Boot" | ["neko"],"Boot" | ["flash"],"Boot" | [],"Array" | [],"String" -> true | _ -> false)  in
	let keep stat f =
		keep_whole_class
		|| has_meta ":?used" f.cf_meta
		|| has_meta ":keep" f.cf_meta
		|| (stat && f.cf_name = "__init__")
		|| (not stat && f.cf_name = "resolve" && (match c.cl_dynamic with Some _ -> true | None -> false))
		|| (f.cf_name = "new" && has_meta ":?used" c.cl_meta)
		|| match String.concat "." (fst c.cl_path @ [snd c.cl_path;f.cf_name]) with
		| "EReg.new"
		| "js.Boot.__init" | "flash._Boot.RealBoot.new"
		| "js.Boot.__string_rec" (* used by $estr *)
		| "js.Boot.__instanceof" (* used by catch( e : T ) *)
			-> true
		| _ -> false
	in
	keep

(*
	make sure that all things we are supposed to keep are correctly typed
*)
let dce_finalize ctx =
	let check_class c =
		let keep = dce_check_class ctx c in
		let check stat f = if keep stat f then ignore(follow f.cf_type) in
		(match c.cl_constructor with Some f -> check false f | _ -> ());
		List.iter (check false) c.cl_ordered_fields;
		List.iter (check true) c.cl_ordered_statics;
	in
	Hashtbl.iter (fun _ m ->
		List.iter (fun t ->
			match t with
			| TClassDecl c -> check_class c
			| _ -> ()
		) m.m_types
	) ctx.g.modules

(*
	remove unused fields and mark unused classes as extern
*)
let dce_optimize ctx =
	let check_class c =
		let keep = dce_check_class ctx c in
		let keep stat f = if not (keep stat f) then begin if ctx.com.verbose then Common.log ctx.com ("Removing " ^ s_type_path c.cl_path ^ "." ^ f.cf_name); false; end else true in
		c.cl_constructor <- (match c.cl_constructor with Some f when not (keep false f) -> None | x -> x);
		c.cl_ordered_fields <- List.filter (keep false) c.cl_ordered_fields;
		c.cl_ordered_statics <- List.filter (keep true) c.cl_ordered_statics;
		c.cl_fields <- List.fold_left (fun acc f -> PMap.add f.cf_name f acc) PMap.empty c.cl_ordered_fields;
		c.cl_statics <- List.fold_left (fun acc f -> PMap.add f.cf_name f acc) PMap.empty c.cl_ordered_statics;
		if c.cl_ordered_statics = [] && c.cl_ordered_fields = [] then
			match c with
			| { cl_extern = true }
			| { cl_interface = true }
			| { cl_path = ["flash";"_Boot"],"RealBoot" }
				-> ()
			| _ when has_meta ":?used" c.cl_meta || has_meta ":keep" c.cl_meta || (match c.cl_constructor with Some f -> has_meta ":?used" f.cf_meta | _ -> false)
				-> ()
			| _ ->
				Common.log ctx.com ("Removing " ^ s_type_path c.cl_path);
				c.cl_extern <- true;
				(match c.cl_path with [],"Std" -> () | _ -> c.cl_init <- None);
				c.cl_meta <- [":native",[(EConst (String "Dynamic"),c.cl_pos)],c.cl_pos]; (* make sure the type will not be referenced *)
	in
	Common.log ctx.com "Performing dead code optimization";
	Hashtbl.iter (fun _ m ->
		List.iter (fun t ->
			match t with
			| TClassDecl c -> check_class c
			| _ -> ()
		) m.m_types
	) ctx.g.modules

(* ---------------------------------------------------------------------- *)
(* FINALIZATION *)

let get_main ctx =
	match ctx.com.main_class with
	| None -> None
	| Some cl ->
		let t = Typeload.load_type_def ctx null_pos { tpackage = fst cl; tname = snd cl; tparams = []; tsub = None } in
		let ft, r = (match t with
		| TEnumDecl _ | TTypeDecl _ ->
			error ("Invalid -main : " ^ s_type_path cl ^ " is not a class") null_pos
		| TClassDecl c ->
			try
				let f = PMap.find "main" c.cl_statics in
				let t = field_type f in
				(match follow t with
				| TFun ([],r) -> t, r
				| _ -> error ("Invalid -main : " ^ s_type_path cl ^ " has invalid main function") c.cl_pos);
			with
				Not_found -> error ("Invalid -main : " ^ s_type_path cl ^ " does not have static function main") c.cl_pos
		) in
		let emain = type_type ctx cl null_pos in
		Some (mk (TCall (mk (TField (emain,"main")) ft null_pos,[])) r null_pos)

let rec finalize ctx =
	let delays = ctx.g.delayed in
	ctx.g.delayed <- [];
	match delays with
	| [] when ctx.com.dead_code_elimination ->
		ignore(get_main ctx);
		dce_finalize ctx;
		if ctx.g.delayed = [] then dce_optimize ctx else finalize ctx
	| [] ->
		(* at last done *)
		()
	| l ->
		List.iter (fun f -> f()) l;
		finalize ctx

type state =
	| Generating
	| Done
	| NotYet

let generate ctx =
	let types = ref [] in
	let states = Hashtbl.create 0 in
	let state p = try Hashtbl.find states p with Not_found -> NotYet in
	let statics = ref PMap.empty in

	let rec loop t =
		let p = t_path t in
		match state p with
		| Done -> ()
		| Generating ->
			ctx.com.warning ("Warning : maybe loop in static generation of " ^ s_type_path p) (t_infos t).mt_pos;
		| NotYet ->
			Hashtbl.add states p Generating;
			let t = (match t with
			| TClassDecl c ->
				walk_class p c;
				t
			| TEnumDecl _ | TTypeDecl _ ->
				t
			) in
			Hashtbl.replace states p Done;
			types := t :: !types

    and loop_class p c =
		if c.cl_path <> p then loop (TClassDecl c)

	and loop_enum p e =
		if e.e_path <> p then loop (TEnumDecl e)

	and walk_static_call p c name =
		try
			let f = PMap.find name c.cl_statics in
			match f.cf_expr with
			| None -> ()
			| Some e ->
				if PMap.mem (c.cl_path,name) (!statics) then
					()
				else begin
					statics := PMap.add (c.cl_path,name) () (!statics);
					walk_expr p e;
				end
		with
			Not_found -> ()

	and walk_expr p e =
		match e.eexpr with
		| TTypeExpr t ->
			(match t with
			| TClassDecl c -> loop_class p c
			| TEnumDecl e -> loop_enum p e
			| TTypeDecl _ -> assert false)
		| TEnumField (e,_) ->
			loop_enum p e
		| TNew (c,_,_) ->
			iter (walk_expr p) e;
			loop_class p c;
			let rec loop c =
				if PMap.mem (c.cl_path,"new") (!statics) then
					()
				else begin
					statics := PMap.add (c.cl_path,"new") () !statics;
					(match c.cl_constructor with
					| Some { cf_expr = Some e } -> walk_expr p e
					| _ -> ());
					match c.cl_super with
					| None -> ()
					| Some (csup,_) -> loop csup
				end
			in
			loop c
		| TMatch (_,(enum,_),_,_) ->
			loop_enum p enum;
			iter (walk_expr p) e
		| TCall (f,_) ->
			iter (walk_expr p) e;
			(* static call for initializing a variable *)
			let rec loop f =
				match f.eexpr with
				| TField ({ eexpr = TTypeExpr t },name) ->
					(match t with
					| TEnumDecl _ -> ()
					| TTypeDecl _ -> assert false
					| TClassDecl c -> walk_static_call p c name)
				| _ -> ()
			in
			loop f
		| _ ->
			iter (walk_expr p) e

    and walk_class p c =
		(match c.cl_super with None -> () | Some (c,_) -> loop_class p c);
		List.iter (fun (c,_) -> loop_class p c) c.cl_implements;
		(match c.cl_init with
		| None -> ()
		| Some e -> walk_expr p e);
		PMap.iter (fun _ f ->
			match f.cf_expr with
			| None -> ()
			| Some e ->
				match e.eexpr with
				| TFunction _ -> ()
				| _ -> walk_expr p e
		) c.cl_statics

	in
	let sorted_modules = List.sort (fun m1 m2 -> compare m1.m_path m2.m_path) (Hashtbl.fold (fun _ m acc -> m :: acc) ctx.g.modules []) in
	List.iter (fun m -> List.iter loop m.m_types) sorted_modules;
	get_main ctx, List.rev !types, sorted_modules

(* ---------------------------------------------------------------------- *)
(* MACROS *)

let get_type_patch ctx t sub =
	let new_patch() =
		{ tp_type = None; tp_remove = false; tp_meta = [] }
	in
	let path = Ast.parse_path t in
	let h, tp = (try
		Hashtbl.find ctx.g.type_patches path
	with Not_found ->
		let h = Hashtbl.create 0 in
		let tp = new_patch() in
		Hashtbl.add ctx.g.type_patches path (h,tp);
		h, tp
	) in
	match sub with
	| None -> tp
	| Some k ->
		try
			Hashtbl.find h k
		with Not_found ->
			let tp = new_patch() in
			Hashtbl.add h k tp;
			tp

let parse_string ctx s p inlined =
	let old = Lexer.save() in
	let old_file = (try Some (Hashtbl.find Lexer.all_files p.pfile) with Not_found -> None) in
	let old_display = !Parser.resume_display in
	let restore() =
		(match old_file with
		| None -> ()
		| Some f -> Hashtbl.replace Lexer.all_files p.pfile f);
		if not inlined then Parser.resume_display := old_display;
		Lexer.restore old;
	in
	Lexer.init p.pfile;
	if not inlined then Parser.resume_display := null_pos;
	let _, decls = try
		Parser.parse ctx.com (Lexing.from_string s)
	with Parser.Error (e,pe) ->
		restore();
		error (Parser.error_msg e) (if inlined then pe else p)
	| Lexer.Error (e,pe) ->
		restore();
		error (Lexer.error_msg e) (if inlined then pe else p)
	in
	restore();
	match decls with
	| [(d,_)] -> d
	| _ -> assert false

let macro_timer ctx path =
	Common.timer (if Common.defined ctx.com "macrotimes" then "macro " ^ path else "macro execution")

let typing_timer ctx f =
	let t = Common.timer "typing" in
	let old = ctx.com.error in
	(*
		disable resumable errors... unless we are in display mode (we want to reach point of completion)
	*)
	if not ctx.com.display then ctx.com.error <- (fun e p -> raise (Error(Custom e,p)));
	try
		let r = f() in
		t();
		r
	with Error (ekind,p) ->
			ctx.com.error <- old;
			t();
			Interp.compiler_error (Typecore.error_msg ekind) p
		| e ->
			ctx.com.error <- old;
			t();
			raise e

let make_macro_api ctx p =
	let make_instance = function
		| TClassDecl c -> TInst (c,List.map snd c.cl_types)
		| TEnumDecl e -> TEnum (e,List.map snd e.e_types)
		| TTypeDecl t -> TType (t,List.map snd t.t_types)
	in
	{
		Interp.pos = p;
		Interp.get_com = (fun() -> ctx.com);
		Interp.get_type = (fun s ->
			typing_timer ctx (fun() ->
				let path = parse_path s in
				try
					Some (Typeload.load_instance ctx { tpackage = fst path; tname = snd path; tparams = []; tsub = None } p true)
				with Error (Module_not_found _,p2) when p == p2 ->
					None
			)
		);
		Interp.get_module = (fun s ->
			typing_timer ctx (fun() ->
				let path = parse_path s in
				List.map make_instance (Typeload.load_module ctx path p).m_types
			)
		);
		Interp.on_generate = (fun f ->
			Common.add_filter ctx.com (fun() ->
				let t = macro_timer ctx "onGenerate" in
				f (List.map make_instance ctx.com.types);
				t()
			)
		);
		Interp.parse_string = (fun s p inl ->
			typing_timer ctx (fun() ->
				let head = "class X{static function main() " in
				let head = (if p.pmin > String.length head then head ^ String.make (p.pmin - String.length head) ' ' else head) in
				let rec loop e = let e = Ast.map_expr loop e in (fst e,p) in
				match parse_string ctx (head ^ s ^ "}") p inl with
				| EClass { d_data = [{ cff_name = "main"; cff_kind = FFun { f_expr = Some e } }]} -> if inl then e else loop e
				| _ -> assert false
			)
		);
		Interp.typeof = (fun e ->
			typing_timer ctx (fun() -> (type_expr ctx ~need_val:true e).etype)
		);
		Interp.type_patch = (fun t f s v ->
			typing_timer ctx (fun() ->
				let v = (match v with None -> None | Some s ->
					match parse_string ctx ("typedef T = " ^ s) null_pos false with
					| ETypedef { d_data = ct } -> Some ct
					| _ -> assert false
				) in
				let tp = get_type_patch ctx t (Some (f,s)) in
				match v with
				| None -> tp.tp_remove <- true
				| Some _ -> tp.tp_type <- v
			);
		);
		Interp.meta_patch = (fun m t f s ->
			let m = (match parse_string ctx (m ^ " typedef T = T") null_pos false with
				| ETypedef t -> t.d_meta
				| _ -> assert false
			) in
			let tp = get_type_patch ctx t (match f with None -> None | Some f -> Some (f,s)) in
			tp.tp_meta <- tp.tp_meta @ m;
		);
		Interp.set_js_generator = (fun gen ->
			let js_ctx = Genjs.alloc_ctx ctx.com in
			ctx.com.js_gen <- Some (fun() ->
				let jsctx = Interp.enc_obj [
					"outputFile", Interp.enc_string ctx.com.file;
					"types", Interp.enc_array (List.map (fun t -> Interp.encode_type (make_instance t)) ctx.com.types);
					"main", (match ctx.com.main with None -> Interp.VNull | Some e -> Interp.encode_texpr e);
					"generateValue", Interp.VFunction (Interp.Fun1 (fun v ->
						match v with
						| Interp.VAbstract (Interp.ATExpr e) ->
							let str = Genjs.gen_single_expr js_ctx e false in
							Interp.enc_string str
						| _ -> failwith "Invalid expression";
					));
					"isKeyword", Interp.VFunction (Interp.Fun1 (fun v ->
						Interp.VBool (Hashtbl.mem Genjs.kwds (Interp.dec_string v))
					));
					"quoteString", Interp.VFunction (Interp.Fun1 (fun v ->
						Interp.enc_string ("\"" ^ Ast.s_escape (Interp.dec_string v) ^ "\"")
					));
					"buildMetaData", Interp.VFunction (Interp.Fun1 (fun t ->
						match Codegen.build_metadata ctx.com (Interp.decode_tdecl t) with
						| None -> Interp.VNull
						| Some e -> Interp.encode_texpr e
					));
					"generateStatement", Interp.VFunction (Interp.Fun1 (fun v ->
						match v with
						| Interp.VAbstract (Interp.ATExpr e) ->
							let str = Genjs.gen_single_expr js_ctx e true in
							Interp.enc_string str
						| _ -> failwith "Invalid expression";
					));
					"setTypeAccessor", Interp.VFunction (Interp.Fun1 (fun callb ->
						js_ctx.Genjs.type_accessor <- (fun t ->
							let v = Interp.encode_type (make_instance t) in
							let ret = Interp.call (Interp.get_ctx()) Interp.VNull callb [v] Nast.null_pos in
							Interp.dec_string ret
						);
						Interp.VNull
					));
					"setCurrentClass", Interp.VFunction (Interp.Fun1 (fun c ->
						Genjs.set_current_class js_ctx (match Interp.decode_tdecl c with TClassDecl c -> c | _ -> assert false);
						Interp.VNull
					));
				] in
				let t = macro_timer ctx "jsGenerator" in
				gen jsctx;
				t()
			);
		);
		Interp.get_local_type = (fun() ->
			match ctx.g.get_build_infos() with
			| Some (mt,_) ->
				Some (match mt with
					| TClassDecl c -> TInst (c,[])
					| TEnumDecl e -> TEnum (e,[])
					| TTypeDecl t -> TType (t,[]))
			| None ->
				if ctx.curclass == null_class then
					None
				else
					Some (TInst (ctx.curclass,[]))
		);
		Interp.get_local_method = (fun() ->
			ctx.curmethod;
		);
		Interp.get_build_fields = (fun() ->
			match ctx.g.get_build_infos() with
			| None -> Interp.VNull
			| Some (_,fields) -> Interp.enc_array (List.map Interp.encode_field fields)
		);
		Interp.define_type = (fun v ->
			let m, tdef, pos = (try Interp.decode_type_def v with Interp.Invalid_expr -> Interp.exc (Interp.VString "Invalid type definition")) in
			let mdep = Typeload.type_module ctx m ctx.current.m_extra.m_file [tdef,pos] pos in
			mdep.m_extra.m_kind <- MFake;
			add_dependency ctx.current mdep;
		);
		Interp.module_dependency = (fun mpath file ismacro ->
			let m = typing_timer ctx (fun() -> Typeload.load_module ctx (parse_path mpath) p) in
			if ismacro then
				m.m_extra.m_macro_calls <- file :: List.filter ((<>) file) m.m_extra.m_macro_calls
			else
				add_dependency m (create_fake_module ctx file);
		);
		Interp.current_module = (fun() ->
			ctx.current
		);
	}

let get_macro_context ctx p =
	let api = make_macro_api ctx p in
	match ctx.g.macros with
	| Some (select,ctx) ->
		select();
		api, ctx
	| None ->
		let com2 = Common.clone ctx.com in
		ctx.com.get_macros <- (fun() -> Some com2);
		com2.package_rules <- PMap.empty;
		com2.main_class <- None;
		com2.display <- false;
		com2.dead_code_elimination <- false;
		List.iter (fun p -> com2.defines <- PMap.remove (platform_name p) com2.defines) platforms;
		com2.defines_signature <- None;
		com2.class_path <- List.filter (fun s -> not (ExtString.String.exists s "/_std/")) com2.class_path;
		com2.class_path <- List.map (fun p -> p ^ "neko" ^ "/_std/") com2.std_path @ com2.class_path;
		com2.defines <- PMap.foldi (fun k _ acc ->
			match k with
			| "no_traces" -> acc
			| _ when List.exists (fun (_,d) -> "flash" ^ d = k) Common.flash_versions -> acc
			| _ -> PMap.add k () acc
		) com2.defines PMap.empty;
		Common.define com2 "macro";
		Common.init_platform com2 Neko;
		let ctx2 = ctx.g.do_create com2 in
		let mctx = Interp.create com2 api in
		let on_error = com2.error in
		com2.error <- (fun e p -> Interp.set_error mctx true; on_error e p);
		let macro = ((fun() -> Interp.select mctx), ctx2) in
		ctx.g.macros <- Some macro;
		ctx2.g.macros <- Some macro;
		(* ctx2.g.core_api <- ctx.g.core_api; // causes some issues because of optional args and Null type in Flash9 *)
		ignore(Typeload.load_module ctx2 (["haxe";"macro"],"Expr") p);
		ignore(Typeload.load_module ctx2 (["haxe";"macro"],"Type") p);
		finalize ctx2;
		let _, types, _ = generate ctx2 in
		Interp.add_types mctx types;
		Interp.init mctx;
		api, ctx2

let load_macro ctx cpath f p =
	(*
		The time measured here takes into account both macro typing an init, but benchmarks
		shows that - unless you re doing heavy statics vars init - the time is mostly spent in
		typing the classes needed for macro execution.
	*)
	let t = macro_timer ctx "typing (+init)" in
	let api, ctx2 = get_macro_context ctx p in
	let mctx = Interp.get_ctx() in
	let m = (try Hashtbl.find ctx.g.types_module cpath with Not_found -> cpath) in
	let mloaded = Typeload.load_module ctx2 m p in
	ctx2.local_types <- mloaded.m_types;
	add_dependency ctx.current mloaded;
	let meth = (match Typeload.load_instance ctx2 { tpackage = fst cpath; tname = snd cpath; tparams = []; tsub = None } p true with
		| TInst (c,_) -> (try PMap.find f c.cl_statics with Not_found -> error ("Method " ^ f ^ " not found on class " ^ s_type_path cpath) p)
		| _ -> error "Macro should be called on a class" p
	) in
	let meth = (match follow meth.cf_type with TFun (args,ret) -> args,ret,meth.cf_pos | _ -> error "Macro call should be a method" p) in
	let in_macro = ctx.in_macro in
	if not in_macro then begin
		finalize ctx2;
		let _, types, modules = generate ctx2 in
		ctx2.com.types <- types;
		ctx2.com.Common.modules <- modules;
		Interp.add_types mctx types;
	end;
	t();
	let call args =
		let t = macro_timer ctx (s_type_path cpath ^ "." ^ f) in
		incr stats.s_macros_called;
		let r = Interp.call_path mctx ((fst cpath) @ [snd cpath]) f args api in
		t();
		r
	in
	ctx2, meth, call

let type_macro ctx mode cpath f (el:Ast.expr list) p =
	let ctx2, (margs,mret,mpos), call_macro = load_macro ctx cpath f p in
	let ctexpr = { tpackage = ["haxe";"macro"]; tname = "Expr"; tparams = []; tsub = None } in
	let expr = Typeload.load_instance ctx2 ctexpr p false in
	(match mode with
	| MExpr ->
		unify ctx2 mret expr mpos;
	| MBuild ->
		let ctfields = { tpackage = []; tname = "Array"; tparams = [TPType (CTPath { tpackage = ["haxe";"macro"]; tname = "Expr"; tparams = []; tsub = Some "Field" })]; tsub = None } in
		let tfields = Typeload.load_instance ctx2 ctfields p false in
		unify ctx2 mret tfields mpos
	| MMacroType ->
		let cttype = { tpackage = ["haxe";"macro"]; tname = "Type"; tparams = []; tsub = None } in
		let ttype = Typeload.load_instance ctx2 cttype p false in
		unify ctx2 mret ttype mpos
	);
	(*
		if the function's last argument is of Array<Expr>, split the argument list and use [] for unify_call_params
	*)
	let el,el2 = match List.rev margs with
		| (_,_,TInst({cl_path=([], "Array")},[e])) :: rest when (try Type.type_eq EqStrict e expr; true with _ -> false) ->
			let rec loop el1 el2 margs el = match margs,el with
				| _,[] ->
					el1,el2
				| _ :: [], (EArrayDecl e,_) :: [] ->
					(el1 @ [EArrayDecl [],p]),e
				| [], e :: el ->
					loop el1 (el2 @ [e]) [] el
				| _ :: [], e :: el ->
					loop (el1 @ [EArrayDecl [],p]) el2 [] (e :: el)
				| _ :: margs, e :: el ->
					loop (el1 @ [e]) el2 margs el
			in
			loop [] [] margs el
		| _ -> el,[]
	in
	let args =
		(*
			force default parameter types to haxe.macro.Expr, and if success allow to pass any value type since it will be encoded
		*)
		let eargs = List.map (fun (n,o,t) -> try unify_raise ctx2 t expr p; (n, o, t_dynamic), true with _ -> (n,o,t), false) margs in
		(*
			this is quite tricky here : we want to use unify_call_params which will type our AST expr
			but we want to be able to get it back after it's been padded with nulls
		*)
		let index = ref (-1) in
		let constants = List.map (fun e ->
			let p = snd e in
			let e = (try
				ignore(Codegen.type_constant_value ctx.com e);
				e
			with _ ->
				(* if it's not a constant, let's make something that is typed as haxe.macro.Expr - for nice error reporting *)
				(EBlock [
					(EVars ["__tmp",Some (CTPath ctexpr),Some (EConst (Ident "null"),p)],p);
					(EConst (Ident "__tmp"),p);
				],p)
			) in
			(* let's track the index by doing [e][index] (we will keep the expression type this way) *)
			incr index;
			(EArray ((EArrayDecl [e],p),(EConst (Int (string_of_int (!index))),p)),p)
		) el in
		let elt, _ = unify_call_params ctx2 (Some (f,[])) constants (List.map fst eargs) t_dynamic p false in
		List.map2 (fun (_,ise) e ->
			let e, et = (match e.eexpr with
				(* get back our index and real expression *)
				| TArray ({ eexpr = TArrayDecl [e] }, { eexpr = TConst (TInt index) }) -> List.nth el (Int32.to_int index), e
				(* added by unify_call_params *)
				| TConst TNull -> (EConst (Ident "null"),e.epos), e
				| _ -> assert false
			) in
			if ise then
				Interp.encode_expr e
			else match Interp.eval_expr (Interp.get_ctx()) et with
				| None -> assert false
				| Some v -> v
		) eargs elt
	in
	let args = match el2 with
		| [] -> args
		| _ -> (match List.rev args with _::args -> args | [] -> []) @ [Interp.enc_array (List.map Interp.encode_expr el2)]
	in
	let call() =
		match call_macro args with
		| None -> None
		| Some v ->
			try
				Some (match mode with
				| MExpr -> Interp.decode_expr v
				| MBuild ->
					let fields = (match v with
						| Interp.VNull ->
							(match ctx.g.get_build_infos() with
							| None -> assert false
							| Some (_,fields) -> fields)
						| _ ->
							List.map Interp.decode_field (Interp.dec_array v)
					) in
					(EVars ["fields",Some (CTAnonymous fields),None],p)
				| MMacroType ->
					ctx.ret <- Interp.decode_type v;
					(EBlock [],p)
				)
			with Interp.Invalid_expr ->
				error "The macro didn't return a valid result" p
	in
	let e = (if ctx.in_macro then begin
		(*
			this is super-tricky : we can't evaluate a macro inside a macro because we might trigger some cycles.
			So instead, we generate a haxe.macro.Context.delayedCalled(i) expression that will only evaluate the
			macro if/when it is called.

			The tricky part is that the whole delayed-evaluation process has to use the same contextual informations
			as if it was evaluated now.
		*)
		let ctx = {
			ctx with locals = ctx.locals;
		} in
		let mctx = Interp.get_ctx() in
		let pos = Interp.alloc_delayed mctx (fun() ->
			match call() with
			| None -> (fun() -> raise Interp.Abort)
			| Some e -> Interp.eval mctx (Genneko.gen_expr mctx.Interp.gen (type_expr ctx e))
		) in
		ctx.current.m_extra.m_time <- -1.; (* disable caching for modules having macro-in-macro *)
		let e = (EConst (Ident "__dollar__delay_call"),p) in
		Some (EUntyped (ECall (e,[EConst (Int (string_of_int pos)),p]),p),p)
	end else
		call()
	) in
	e

let call_macro ctx path meth args p =
	let ctx2, (margs,_,_), call = load_macro ctx path meth p in
	let el, _ = unify_call_params ctx2 (Some (meth,[])) args margs t_dynamic p false in
	call (List.map (fun e -> try Interp.make_const e with Exit -> error "Parameter should be a constant" e.epos) el)

let call_init_macro ctx e =
	let p = { pfile = "--macro"; pmin = 0; pmax = 0 } in
	let api = make_macro_api ctx p in
	let e = api.Interp.parse_string e p false in
	match fst e with
	| ECall (e,args) ->
		let rec loop e =
			match fst e with
			| EField (e,f) | EType (e,f) -> f :: loop e
			| EConst (Ident i | Type i) -> [i]
			| _ -> error "Invalid macro call" p
		in
		let path, meth = (match loop e with
		| [meth] -> (["haxe";"macro"],"Compiler"), meth
		| meth :: cl :: path -> (List.rev path,cl), meth
		| _ -> error "Invalid macro call" p) in
		ignore(call_macro ctx path meth args p);
	| _ ->
		error "Invalid macro call" p

(* ---------------------------------------------------------------------- *)
(* TYPER INITIALIZATION *)

let rec create com =
	let ctx = {
		com = com;
		t = com.basic;
		g = {
			core_api = None;
			macros = None;
			modules = Hashtbl.create 0;
			types_module = Hashtbl.create 0;
			type_patches = Hashtbl.create 0;
			delayed = [];
			doinline = not (Common.defined com "no_inline" || com.display);
			hook_generate = [];
			get_build_infos = (fun() -> None);
			std = null_module;
			do_inherit = Codegen.on_inherit;
			do_create = create;
			do_macro = type_macro;
			do_load_module = Typeload.load_module;
			do_optimize = Optimizer.reduce_expression;
			do_build_instance = Codegen.build_instance;
		};
		untyped = false;
		curfun = FStatic;
		in_loop = false;
		in_super_call = false;
		in_display = false;
		in_macro = Common.defined com "macro";
		ret = mk_mono();
		locals = PMap.empty;
		local_types = [];
		local_using = [];
		type_params = [];
		curmethod = "";
		curclass = null_class;
		tthis = mk_mono();
		current = null_module;
		opened = [];
		param_type = None;
		vthis = None;
	} in
	ctx.g.std <- (try
		Typeload.load_module ctx ([],"StdTypes") null_pos
	with
		Error (Module_not_found ([],"StdTypes"),_) -> error "Standard library not found" null_pos
	);
	List.iter (fun t ->
		match t with
		| TEnumDecl e ->
			(match snd e.e_path with
			| "Void" -> ctx.t.tvoid <- TEnum (e,[])
			| "Bool" -> ctx.t.tbool <- TEnum (e,[])
			| _ -> ())
		| TClassDecl c ->
			(match snd c.cl_path with
			| "Float" -> ctx.t.tfloat <- TInst (c,[])
			| "Int" -> ctx.t.tint <- TInst (c,[])
			| _ -> ())
		| TTypeDecl td ->
			(match snd td.t_path with
			| "Null" ->
				let mk_null t =
					try
						if not (is_nullable ~no_lazy:true t) then TType (td,[t]) else t
					with Exit ->
						(* don't force lazy evaluation *)
						let r = ref (fun() -> assert false) in
						r := (fun() ->
							let t = (if not (is_nullable t) then TType (td,[t]) else t) in
							r := (fun() -> t);
							t
						);
						TLazy r
				in
				ctx.t.tnull <- if not (is_static_platform com) then (fun t -> t) else mk_null;
			| _ -> ());
	) ctx.g.std.m_types;
	let m = Typeload.load_module ctx ([],"String") null_pos in
	(match m.m_types with
	| [TClassDecl c] -> ctx.t.tstring <- TInst (c,[])
	| _ -> assert false);
	let m = Typeload.load_module ctx ([],"Array") null_pos in
	(match m.m_types with
	| [TClassDecl c] -> ctx.t.tarray <- (fun t -> TInst (c,[t]))
	| _ -> assert false);
	ctx

;;
type_field_rec := type_field;
type_expr_with_type_rec := type_expr_with_type;
