
func _compile_regex() -> void:
	_re_take_over = RegEx.new()
	_re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
	_re_extends = RegEx.new()
	_re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
	_re_extends_classname = RegEx.new()
	_re_extends_classname.compile('(?m)^extends\\s+([A-Z]\\w+)\\s*$')
	_re_class_name = RegEx.new()
	_re_class_name.compile('(?m)^class_name\\s+(\\w+)')
	_re_func = RegEx.new()
	_re_func.compile('(?m)^(?:static\\s+)?func\\s+(\\w+)\\s*\\(')
	_re_preload = RegEx.new()
	_re_preload.compile('preload\\s*\\(\\s*"(res://[^"]+)"\\s*\\)')
	_re_filename_priority = RegEx.new()
	_re_filename_priority.compile('^(-?\\d+)-(.*)')
	_re_hook_call = RegEx.new()
	_re_hook_call.compile('\\.hook\\s*\\(\\s*"([A-Za-z_][\\w]*)-([A-Za-z_][\\w]*?)(?:-(?:pre|post|callback))?"')



func _rtv_compile_codegen_regex() -> void:
	if _rtv_re_extends != null:
		return
	_rtv_re_extends = RegEx.new()
	_rtv_re_extends.compile('^extends\\s+"?([\\w/.:"]+)"?')
	_rtv_re_class_name = RegEx.new()
	_rtv_re_class_name.compile('^class_name\\s+(\\w+)')
	_rtv_re_func = RegEx.new()
	_rtv_re_func.compile('^func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_static_func = RegEx.new()
	_rtv_re_static_func.compile('^static\\s+func\\s+(\\w+)\\s*\\(([^)]*)\\)(\\s*->\\s*([\\w\\[\\]]+))?\\s*:')
	_rtv_re_var = RegEx.new()
	_rtv_re_var.compile('^(?:@export\\s+)?var\\s+(\\w+)')

func _rtv_extract_param_names(params: String) -> Array:
	var names: Array = []
	if params.strip_edges().is_empty():
		return names
	for p in params.split(","):
		var trimmed := (p as String).strip_edges()
		var without_type := trimmed.split(":")[0]
		var without_default := (without_type as String).split("=")[0]
		var name := (without_default as String).strip_edges()
		if not name.is_empty():
			names.append(name)
	return names

func _rtv_script_hook_prefix(filename: String) -> String:
	var stem := filename
	if stem.ends_with(".gd"):
		stem = stem.substr(0, stem.length() - 3)
	return stem.to_lower()


func _rtv_parse_script(filename: String, source: String) -> Dictionary:
	_rtv_compile_codegen_regex()
	var script := {
		"filename": filename,
		"path": filename,
		"extends": "",
		"class_name": null,
		"functions": [],
		"var_names": [],
	}
	var lines: PackedStringArray = source.split("\n")
	var func_starts: Array = []

	for line_num in lines.size():
		var line: String = lines[line_num]
		var trimmed := line.strip_edges()

		var m_ext := _rtv_re_extends.search(trimmed)
		if m_ext != null:
			script["extends"] = m_ext.get_string(1)

		var m_cn := _rtv_re_class_name.search(trimmed)
		if m_cn != null:
			script["class_name"] = m_cn.get_string(1)

		if not line.begins_with("\t") and not line.begins_with(" "):
			var m_var := _rtv_re_var.search(trimmed)
			if m_var != null:
				(script["var_names"] as Array).append(m_var.get_string(1))

		var m_sfunc := _rtv_re_static_func.search(trimmed)
		if m_sfunc != null:
			var ret_group = m_sfunc.get_string(4) if m_sfunc.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_sfunc.get_string(1), m_sfunc.get_string(2),
				_rtv_extract_param_names(m_sfunc.get_string(2)), true,
				ret_group,
			])
			continue

		var m_func := _rtv_re_func.search(trimmed)
		if m_func != null:
			var ret_group2 = m_func.get_string(4) if m_func.get_start(4) != -1 else null
			func_starts.append([
				line_num, m_func.get_string(1), m_func.get_string(2),
				_rtv_extract_param_names(m_func.get_string(2)), false,
				ret_group2,
			])

	for idx in func_starts.size():
		var fs: Array = func_starts[idx]
		var line_num: int = fs[0]
		var name: String = fs[1]
		var params: String = fs[2]
		var param_names: Array = fs[3]
		var is_static: bool = fs[4]
		var return_type = fs[5]

		var body_start := line_num + 1
		var body_end := lines.size()
		if idx + 1 < func_starts.size():
			body_end = func_starts[idx + 1][0]

		var is_coroutine := false
		var has_return_value := false
		for i in range(body_start, body_end):
			if i >= lines.size():
				break
			var body_line := lines[i].strip_edges()
			if "await " in body_line:
				is_coroutine = true
			if body_line.begins_with("return ") and body_line.length() > 7:
				has_return_value = true

		if return_type != null and return_type != "void":
			has_return_value = true
		if return_type != null and return_type == "void":
			has_return_value = false

		(script["functions"] as Array).append({
			"name": name,
			"params": params,
			"param_names": param_names,
			"line_number": line_num + 1,
			"is_static": is_static,
			"return_type": return_type,
			"is_coroutine": is_coroutine,
			"has_return_value": has_return_value,
		})

	return script


func _rtv_rewrite_vanilla_source(source: String, parsed: Dictionary, method_mask: Dictionary = {}) -> String:
	var apply_mask: bool = not method_mask.is_empty()
	var hookable: Array = []
	for fe in parsed["functions"]:
		if fe["is_static"]:
			continue
		if apply_mask and not method_mask.has(fe["name"].to_lower()):
			continue
		hookable.append(fe)
	if hookable.is_empty():
		return source

	var hookable_names: Dictionary = {}
	for fe in hookable:
		hookable_names[fe["name"]] = true

	var src: String = source.replace("\r\n", "\n").replace("\r", "\n")

	var autofix := _rtv_autofix_legacy_syntax(src)
	src = autofix["source"]
	var af_total: int = int(autofix["bodyless"]) + int(autofix["tool"]) \
			+ int(autofix["onready"]) + int(autofix["export"]) + int(autofix.get("base", 0))
	if af_total > 0:
		_log_info("[Autofix] %s: %d bodyless, %d @tool, %d @onready, %d @export, %d base()->super -- legacy syntax normalized" \
				% [parsed.get("filename", "?"), autofix["bodyless"], autofix["tool"], autofix["onready"], autofix["export"], autofix.get("base", 0)])


	var lines: PackedStringArray = src.split("\n")
	var current_hooked_method: String = ""
	for i in lines.size():
		var line: String = lines[i]
		if not line.is_empty() and line[0] != "\t" and line[0] != " ":
			current_hooked_method = ""
			if line.begins_with("func "):
				var open_paren := line.find("(")
				if open_paren >= 0:
					var name_end := open_paren
					while name_end > 5 and line[name_end - 1] == " ":
						name_end -= 1
					var method_name := line.substr(5, name_end - 5)
					if hookable_names.has(method_name):
						lines[i] = "func _rtv_vanilla_" + method_name + line.substr(name_end)
						current_hooked_method = method_name
			continue
		if current_hooked_method.is_empty():
			continue
		if not ("super" in line):
			continue
		lines[i] = _rewrite_bare_super(line, current_hooked_method)

	lines = _rtv_apply_prelude_injections(parsed.get("filename", ""), lines, "_rtv_vanilla_")

	var indent := _detect_indent_style(src)
	var prefix := _rtv_script_hook_prefix(parsed["filename"])
	var appended := "\n\n"
	for fe in hookable:
		appended += _rtv_dispatch_inline_src(fe, prefix, indent) + "\n"

	appended += _rtv_registry_injection(parsed["filename"], indent)

	return "\n".join(lines) + appended

func _rtv_registry_injection(filename: String, indent: String) -> String:
	return ""


func _rtv_apply_prelude_injections(filename: String, lines: PackedStringArray, rename_prefix: String) -> PackedStringArray:
	return lines
func _rewrite_bare_super(line: String, method_name: String) -> String:
	var scan_end := line.length()
	var comment_idx := line.find("#")
	if comment_idx >= 0:
		scan_end = comment_idx
	var out := line
	var cursor := 0
	while cursor < scan_end:
		var idx := out.find("super", cursor)
		if idx < 0 or idx >= scan_end:
			break
		if idx > 0:
			var prev := out[idx - 1]
			if prev == "." or prev == "_" or prev.to_upper() != prev.to_lower() \
					or (prev >= "0" and prev <= "9"):
				cursor = idx + 5
				continue
		var after := idx + 5
		while after < out.length() and out[after] == " ":
			after += 1
		if after >= out.length() or out[after] != "(":
			cursor = idx + 5
			continue
		var before := out.substr(0, idx)
		var rest := out.substr(after)
		out = before + "super." + method_name + rest
		var delta := 1 + method_name.length()
		cursor = idx + 5 + delta + 1
		scan_end += delta
	return out

func _detect_indent_style(source: String) -> String:
	for line: String in source.split("\n"):
		if line.is_empty():
			continue
		var ch: String = line[0]
		if ch != "\t" and ch != " ":
			continue
		var stripped := line.strip_edges()
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if ch == "\t":
			return "\t"
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		if n > 0:
			return " ".repeat(n)
	return "\t"

func _rtv_leading_indent(line: String) -> String:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return line.substr(0, n)

func _rtv_is_block_header(trimmed: String) -> bool:
	if not trimmed.ends_with(":"):
		return false
	if trimmed == "else:":
		return true
	for kw in ["if ", "elif ", "for ", "while ", "match ", "func ", "class "]:
		if trimmed.begins_with(kw):
			return true
	if trimmed.begins_with("static func "):
		return true
	return false

func _rtv_autofix_legacy_syntax(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var indent_unit := _detect_indent_style(source)
	var fix_bodyless := 0
	var fix_tool := 0
	var fix_onready := 0
	var fix_export := 0
	var fix_base := 0

	var current_method: String = ""
	var method_line_indent: String = ""

	for i in lines.size():
		var line: String = lines[i]

		var lead := _rtv_leading_indent(line)
		if lead.is_empty() and not line.strip_edges().is_empty():
			var stripped_top := line.strip_edges()
			if stripped_top.begins_with("func "):
				var open_paren := stripped_top.find("(")
				if open_paren > 5:
					current_method = stripped_top.substr(5, open_paren - 5).strip_edges()
					method_line_indent = ""
			elif stripped_top.begins_with("static func ") or stripped_top.begins_with("@"):
				current_method = ""
			else:
				current_method = ""

		if not current_method.is_empty() and line.find("base(") >= 0:
			var rewritten := _rtv_rewrite_bare_base(line, current_method)
			if rewritten != line:
				line = rewritten
				fix_base += 1

		lead = _rtv_leading_indent(line)
		var body_text := line.substr(lead.length())
		if i == 0 and body_text.strip_edges() == "tool":
			line = lead + "@tool"
			fix_tool += 1
		elif body_text.begins_with("onready var "):
			line = lead + "@onready var " + body_text.substr(12)
			fix_onready += 1
		elif body_text.begins_with("export var "):
			line = lead + "@export var " + body_text.substr(11)
			fix_export += 1

		out.append(line)

		var trimmed := line.strip_edges()
		if not _rtv_is_block_header(trimmed):
			continue
		var header_indent := _rtv_leading_indent(line)
		var j := i + 1
		var has_body := false
		while j < lines.size():
			var next_line: String = lines[j]
			var next_trimmed := next_line.strip_edges()
			if next_trimmed.is_empty():
				j += 1
				continue
			if next_trimmed.begins_with("#"):
				j += 1
				continue
			var next_indent := _rtv_leading_indent(next_line)
			if next_indent.length() > header_indent.length() \
					and next_indent.begins_with(header_indent):
				has_body = true
			break
		if not has_body:
			out.append(header_indent + indent_unit + "pass")
			fix_bodyless += 1

	return {
		"source": "\n".join(out),
		"bodyless": fix_bodyless,
		"tool": fix_tool,
		"onready": fix_onready,
		"export": fix_export,
		"base": fix_base,
	}

func _rtv_rewrite_bare_base(line: String, method_name: String) -> String:
	var comment_start := line.find("#")
	var head: String = line if comment_start < 0 else line.substr(0, comment_start)
	var tail: String = "" if comment_start < 0 else line.substr(comment_start)
	var i := 0
	var rewritten := ""
	while i < head.length():
		if i + 4 <= head.length() and head.substr(i, 4) == "base":
			var prev_ok := true
			if i > 0:
				var pc := head[i - 1]
				if pc >= "a" and pc <= "z":
					prev_ok = false
				elif pc >= "A" and pc <= "Z":
					prev_ok = false
				elif pc >= "0" and pc <= "9":
					prev_ok = false
				elif pc == "_" or pc == ".":
					prev_ok = false
			var j := i + 4
			while j < head.length() and (head[j] == " " or head[j] == "\t"):
				j += 1
			if prev_ok and j < head.length() and head[j] == "(":
				var close_idx := _rtv_find_matching_paren(head, j)
				if close_idx == j + 1 and close_idx > 0:
					var k := close_idx + 1
					if k < head.length() and head[k] == ".":
						var name_start := k + 1
						var name_end := name_start
						while name_end < head.length() \
								and _rtv_is_ident_char(head[name_end]):
							name_end += 1
						if name_end > name_start \
								and name_end < head.length() \
								and head[name_end] == "(":
							var chained_name: String = head.substr(name_start, name_end - name_start)
							rewritten += "super." + chained_name
							i = name_end
							continue
				rewritten += "super." + method_name
				i += 4
				continue
		rewritten += head[i]
		i += 1
	return rewritten + tail

func _rtv_find_matching_paren(s: String, open_idx: int) -> int:
	if open_idx >= s.length() or s[open_idx] != "(":
		return -1
	var depth := 0
	var in_dq := false
	var in_sq := false
	var i := open_idx
	while i < s.length():
		var c := s[i]
		if in_dq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "\"":
				in_dq = false
		elif in_sq:
			if c == "\\" and i + 1 < s.length():
				i += 2
				continue
			if c == "'":
				in_sq = false
		else:
			if c == "\"":
				in_dq = true
			elif c == "'":
				in_sq = true
			elif c == "(":
				depth += 1
			elif c == ")":
				depth -= 1
				if depth == 0:
					return i
		i += 1
	return -1

func _rtv_is_ident_char(c: String) -> bool:
	if c == "_":
		return true
	if c >= "a" and c <= "z":
		return true
	if c >= "A" and c <= "Z":
		return true
	if c >= "0" and c <= "9":
		return true
	return false

func _rtv_strip_helper_reload(source: String) -> Dictionary:
	var lines: PackedStringArray = source.split("\n")
	var out: PackedStringArray = PackedStringArray()
	var stripped: int = 0
	var i: int = 0
	while i < lines.size():
		var line: String = lines[i]
		if not line.begins_with("func "):
			out.append(line)
			i += 1
			continue
		var start: int = i
		var end: int = i + 1
		while end < lines.size():
			var bl: String = lines[end]
			if bl.length() > 0 and not (bl[0] == "\t" or bl[0] == " "):
				break
			end += 1
		var has_tov: bool = false
		for k in range(start, end):
			if ".take_over_path(" in lines[k]:
				has_tov = true
				break
		if has_tov:
			for k in range(start, end):
				var bl: String = lines[k]
				var trimmed: String = bl.strip_edges()
				if trimmed.ends_with(".reload()") and not trimmed.begins_with("#"):
					var before_paren: int = trimmed.find(".reload()")
					var ident_part: String = trimmed.substr(0, before_paren)
					var is_bare_call: bool = true
					for c in ident_part:
						if not (c == "_" or c == "." or (c >= "a" and c <= "z") \
								or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
							is_bare_call = false
							break
					if is_bare_call:
						var indent_len: int = 0
						while indent_len < bl.length() and (bl[indent_len] == "\t" or bl[indent_len] == " "):
							indent_len += 1
						var indent: String = bl.substr(0, indent_len)
						stripped += 1
						continue
				out.append(bl)
		else:
			for k in range(start, end):
				out.append(lines[k])
		i = end
	return {"source": "\n".join(out), "stripped": stripped}


func _rtv_dispatch_inline_src(fe: Dictionary, prefix: String, indent: String = "\t") -> String:
	var method_name: String = fe["name"]
	var params: String = fe["params"]
	var param_names_str: String = ", ".join(fe["param_names"])
	var hook_base: String = "%s-%s" % [prefix, method_name.to_lower()]
	var vanilla_call: String = "_rtv_vanilla_%s(%s)" % [method_name, param_names_str]
	var args_array: String = "[]" if param_names_str.is_empty() else "[%s]" % param_names_str
	var is_coro: bool = bool(fe["is_coroutine"])
	var is_engine_void: bool = method_name in GAME_ENGINE_VOID_METHODS
	var is_void: bool = is_engine_void or not bool(fe["has_return_value"])
	var aw: String = "await " if is_coro else ""

	var return_annot: String = ""
	var rt = fe.get("return_type")
	if rt != null and not (rt as String).is_empty():
		return_annot = " -> " + (rt as String)
	var sig: String = "func %s()%s:" % [method_name, return_annot] if params.is_empty() \
			else "func %s(%s)%s:" % [method_name, params, return_annot]

	var I1: String = indent
	var I2: String = indent + indent
	var I3: String = indent + indent + indent

	var out := ""
	if not is_void:
		out += "%s\n" % sig
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%sreturn %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _result\n" % I1
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%svar _replret = _repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif _did_skip:\n" % I2
		out += "%s_result = _replret\n" % I3
		out += "%selse:\n" % I2
		out += "%s_result = %s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s_result = %s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_result = _lib._dispatch_post(\"%s-post\", %s, _result)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
		out += "%sreturn _result\n" % I1
	else:
		out += "%s\n" % sig
		out += "%sif not Engine.has_meta(\"RTVModLib\"):\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%svar _lib = Engine.get_meta(\"RTVModLib\")\n" % I1
		out += "%sif not _lib._any_mod_hooked:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif not _lib._hooked_bases.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%sif _lib._developer_mode:\n" % I1
		out += "%s_lib._dispatch_counts[\"%s\"] = int(_lib._dispatch_counts.get(\"%s\", 0)) + 1\n" % [I2, hook_base, hook_base]
		out += "%sif _lib._wrapper_active.has(\"%s\"):\n" % [I1, hook_base]
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%sreturn\n" % I2
		out += "%s_lib._wrapper_active[\"%s\"] = true\n" % [I1, hook_base]
		out += "%svar _rtv_prev_caller = _lib._caller\n" % I1
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-pre\", %s)\n" % [I1, hook_base, args_array]
		out += "%svar _repl = _lib._get_hooks(\"%s\")\n" % [I1, hook_base]
		out += "%sif _repl.size() > 0:\n" % I1
		out += "%svar _prev_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = false\n" % I2
		out += "%s_repl[0].callv(%s)\n" % [I2, args_array]
		out += "%svar _did_skip = _lib._skip_super\n" % I2
		out += "%s_lib._skip_super = _prev_skip\n" % I2
		out += "%sif !_did_skip:\n" % I2
		out += "%s%s%s\n" % [I3, aw, vanilla_call]
		out += "%selse:\n" % I1
		out += "%s%s%s\n" % [I2, aw, vanilla_call]
		out += "%s_lib._caller = self\n" % I1
		out += "%s_lib._dispatch(\"%s-post\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._dispatch_deferred(\"%s-callback\", %s)\n" % [I1, hook_base, args_array]
		out += "%s_lib._wrapper_active.erase(\"%s\")\n" % [I1, hook_base]
		out += "%s_lib._caller = _rtv_prev_caller\n" % I1
	return out
