"""Turns CloudFormation registry schemas into typed Starlark bindings.

Pure Starlark so it can run inside a repository rule. Bazel's Starlark has no
recursion, so schema traversal uses explicit work stacks.
"""

load(":naming.bzl", "RESOURCE_KWARGS", "constant_name", "identifier", "param_name", "snake")

_MAX_ITER = 1 << 24
_MAX_ALIAS_DEPTH = 16

# ---------------------------------------------------------------------------
# Normalization: registry schema -> IR

def _is_type_bearing(n):
    if type(n) != "dict":
        return False
    for k in ("type", "$ref", "properties", "items", "oneOf", "anyOf", "enum", "patternProperties"):
        if k in n:
            return True
    return False

_PRIMS = {"string": "s", "integer": "i", "number": "n", "boolean": "b"}

def _first_paragraph(text, limit):
    if type(text) != "string":
        return ""
    t = text.strip().split("\n\n")[0].strip().replace("\n", " ")
    if len(t) > limit:
        cut = t[:limit].rfind(". ")
        t = t[:cut + 1] if cut > limit // 3 else t[:limit].rstrip() + "..."
    return t

def _type_summary(shape):
    """Human-readable description of a shape (iterative; Starlark forbids recursion)."""
    prefix = ""
    for _ in range(64):
        if type(shape) == "string":
            return prefix + _LEAF_NAMES[shape]
        k = shape[0]
        if k == "l":
            prefix += "list of "
            shape = shape[1]
        elif k == "m":
            prefix += "dict of "
            shape = shape[1]
        elif k == "r":
            return prefix + shape[3]
        elif k == "e":
            return prefix + "one of [" + ", ".join([json.encode(e) for e in shape[1]]) + "]"
        else:
            return prefix + " | ".join([_union_member_name(s) for s in shape[1]])
    return prefix + "..."

def _union_member_name(s):
    if type(s) == "string":
        return _LEAF_NAMES[s]
    return {"l": "list", "m": "dict", "r": s[3] if s[0] == "r" else "", "e": "enum", "u": "union"}[s[0]]

_LEAF_NAMES = {"s": "string", "i": "integer", "n": "number", "b": "boolean", "j": "JSON"}

def _new_ctx(schema, svc_symbol, resource_snake):
    return struct(
        schema = schema,
        defs = schema.get("definitions", {}) or {},
        svc_symbol = svc_symbol,
        resource_snake = resource_snake,
        type_name = schema["typeName"],
        registered = {},  # def name -> ctor name
        queue = [],  # (def name, node)
        inline_nodes = {},  # synthesized def name -> node
    )

def _is_object_with_props(n):
    return type(n) == "dict" and type(n.get("properties")) == "dict" and len(n["properties"]) > 0 and (
        n.get("type") in (None, "object")
    )

def _register_def(ctx, def_name, node):
    """Registers a named object definition and returns its ("r", ...) shape."""
    if def_name not in ctx.registered:
        ctor = ctx.resource_snake + "_" + snake(def_name)
        ctx.registered[def_name] = ctor
        ctx.queue.append((def_name, node))
    props = node.get("properties", {})
    is_tag = sorted(props.keys()) == ["Key", "Value"]
    return ("r", ctx.type_name + "." + def_name, is_tag, ctx.svc_symbol.rstrip("_") + "_types." + ctx.registered[def_name])

def _inline_name(ctx, hint, node):
    name = hint
    for i in range(1000):
        cand = name if i == 0 else "{}{}".format(name, i + 1)
        existing = ctx.inline_nodes.get(cand)
        if existing == None and cand not in ctx.defs:
            ctx.inline_nodes[cand] = node
            return cand
        if existing == node:
            return cand
    fail("could not name inline definition " + hint)

def shape_of(ctx, node, hint):
    """Converts a schema node into a shape (see runtime.bzl), registering object defs.

    Args:
      ctx: from _new_ctx.
      node: the JSON-schema node.
      hint: PascalCase name to use if this node is an inline object.

    Returns:
      the shape.
    """
    root = [None]

    # Ops: ("visit", node, hint, holder, index, alias_depth) and ("build", kind, children, holder, index)
    stack = [("visit", node, hint, root, 0, 0)]
    for _ in range(_MAX_ITER):
        if not stack:
            break
        op = stack.pop()
        if op[0] == "build":
            _, kind, children, holder, idx = op
            if kind == "l":
                holder[idx] = ("l", children[0])
            elif kind == "m":
                holder[idx] = ("m", children[0])
            else:
                # Union: dedupe, collapse, and absorb into "j" if any branch is untyped.
                uniq = []
                for c in children:
                    members = c[1] if type(c) == "tuple" and c[0] == "u" else [c]
                    for m in members:
                        if m not in uniq:
                            uniq.append(m)
                # Types wherever possible: an untyped branch (often a bare
                # {"type": "object"} kept for compatibility) is dropped when typed
                # alternatives exist. Intrinsics are accepted everywhere regardless.
                typed = [m for m in uniq if m != "j"]
                if not typed:
                    holder[idx] = "j"
                elif len(typed) == 1:
                    holder[idx] = typed[0]
                else:
                    holder[idx] = ("u", tuple(typed))
            continue

        _, n, h, holder, idx, depth = op
        if type(n) != "dict":
            holder[idx] = "j"
            continue

        ref = n.get("$ref")
        if type(ref) == "string":
            if depth > _MAX_ALIAS_DEPTH:
                holder[idx] = "j"
                continue
            target = None
            target_name = None
            if ref.startswith("#/definitions/"):
                target_name = ref[len("#/definitions/"):]
                target = ctx.defs.get(target_name)
            elif ref.startswith("#/properties/"):
                target = ctx.schema.get("properties", {}).get(ref[len("#/properties/"):])
            if type(target) != "dict":
                holder[idx] = "j"
            elif target_name != None and _is_object_with_props(target):
                holder[idx] = _register_def(ctx, target_name, target)
            else:
                stack.append(("visit", target, target_name or h, holder, idx, depth + 1))
            continue

        branches = []
        for key in ("oneOf", "anyOf"):
            for b in n.get(key, []) or []:
                if _is_type_bearing(b):
                    branches.append(b)
        if branches and not _is_object_with_props(n):
            children = [None] * len(branches)
            stack.append(("build", "u", children, holder, idx))
            for i, b in enumerate(branches):
                stack.append(("visit", b, "{}{}".format(h, i + 1) if len(branches) > 1 else h, children, i, depth + 1))
            continue

        if "enum" in n and type(n["enum"]) == "list" and n["enum"]:
            holder[idx] = ("e", tuple(n["enum"]))
            continue

        t = n.get("type")
        if type(t) == "list":
            prims = [x for x in t if x != "null"]
            if len(prims) == 1:
                t = prims[0]
            elif [x for x in prims if x not in _PRIMS]:
                holder[idx] = "j"
                continue
            else:
                holder[idx] = ("u", tuple([_PRIMS[x] for x in prims]))
                continue

        if t in _PRIMS:
            holder[idx] = _PRIMS[t]
        elif t == "array":
            items = n.get("items")
            if type(items) != "dict":
                holder[idx] = ("l", "j")
            else:
                children = [None]
                stack.append(("build", "l", children, holder, idx))
                stack.append(("visit", items, h, children, 0, depth))
        elif t == "object" or t == None:
            if _is_object_with_props(n):
                holder[idx] = _register_def(ctx, _inline_name(ctx, h, n), n)
                continue
            pp = n.get("patternProperties")
            ap = n.get("additionalProperties")
            vnode = None
            if type(pp) == "dict" and len(pp) == 1:
                vnode = pp.values()[0]
            elif type(ap) == "dict" and _is_type_bearing(ap):
                vnode = ap
            if vnode != None:
                children = [None]
                stack.append(("build", "m", children, holder, idx))
                stack.append(("visit", vnode, h, children, 0, depth))
            else:
                holder[idx] = "j"
        else:
            holder[idx] = "j"
    return root[0]

def _props_ir(ctx, node, owner_hint, exclude = {}):
    """Returns (props, required, docs): props is a list of (cfn_name, param, shape)."""
    props = []
    docs = {}
    seen = {}
    node_props = node.get("properties", {}) or {}
    for cfn_name in sorted(node_props):
        pnode = node_props[cfn_name]
        if cfn_name in exclude:
            continue
        param = param_name(cfn_name)
        if param in seen:
            # Two properties differing only by case/punctuation; keep both distinct.
            param = param + "_" + str(len([1 for p in props if p[1].startswith(param)]) + 1)
        seen[param] = True
        shape = shape_of(ctx, pnode, owner_hint + cfn_name)
        props.append((cfn_name, param, shape))
        docs[cfn_name] = _first_paragraph(pnode.get("description", "") if type(pnode) == "dict" else "", 240)
    names = {p[0]: True for p in props}
    required = [r for r in (node.get("required", []) or []) if type(r) == "string" and r in names]
    return props, required, docs

def normalize(schema, svc_symbol):
    """Normalizes one registry schema.

    Args:
      schema: decoded provider schema JSON.
      svc_symbol: Starlark symbol of the service struct, e.g. "s3" or "lambda_".

    Returns:
      struct(type_name, short, props, required, docs, attrs, doc, types) where types is a
      list of struct(name, ctor, props, required, docs, doc).
    """
    type_name = schema["typeName"]
    short = type_name.split("::")[2]
    resource_snake = identifier(short)
    ctx = _new_ctx(schema, svc_symbol, snake(short))

    read_only = {}
    attrs = {}
    for p in schema.get("readOnlyProperties", []) or []:
        if type(p) != "string" or not p.startswith("/properties/"):
            continue
        parts = p[len("/properties/"):].split("/")
        if "*" in parts:
            continue
        if len(parts) == 1:
            read_only[parts[0]] = True
        attrs["_".join([snake(x) for x in parts])] = ".".join(parts)

    props, required, docs = _props_ir(ctx, schema, "", read_only)

    types = []
    for _ in range(_MAX_ITER):
        if not ctx.queue:
            break
        def_name, node = ctx.queue.pop(0)
        tprops, treq, tdocs = _props_ir(ctx, node, def_name)
        types.append(struct(
            name = type_name + "." + def_name,
            ctor = ctx.registered[def_name],
            props = tprops,
            required = treq,
            docs = tdocs,
            doc = _first_paragraph(node.get("description", ""), 400),
        ))

    return struct(
        type_name = type_name,
        short = resource_snake,
        props = props,
        required = required,
        docs = docs,
        attrs = attrs,
        doc = _first_paragraph(schema.get("description", ""), 600),
        types = types,
    )

# ---------------------------------------------------------------------------
# Emission

def _lit(v):
    # Starlark and JSON string literals are compatible for the escapes json.encode emits.
    return json.encode(v)

def _shape_lit(shape):
    return repr(shape)

def _props_table(props):
    if not props:
        return "{}"
    lines = ["{"]
    for cfn_name, param, shape in props:
        lines.append("        {}: ({}, {}),".format(_lit(cfn_name), _lit(param), _shape_lit(shape)))
    lines.append("    }")
    return "\n".join(lines)

def _docstring(header, doc, props, docs, extra_args = []):
    lines = [header]
    if doc:
        lines.append("")
        lines.append(doc)
    if props or extra_args:
        lines.append("")
        lines.append("Args:")
        for name, text in extra_args:
            lines.append("  {}: {}".format(name, text))
        for cfn_name, param, shape in props:
            d = docs.get(cfn_name, "")
            lines.append("  {}: ({}) {}{}".format(param, _type_summary(shape), cfn_name, ": " + d if d else ""))
    return "\n".join(lines)

def _signature(props, required, leading):
    req = {r: True for r in required}
    params = list(leading)
    params.append("*")
    for cfn_name, param, _ in props:
        if cfn_name in req:
            params.append(param)
    for cfn_name, param, _ in props:
        if cfn_name not in req:
            params.append(param + " = None")
    return params

def _kwargs_dict(props):
    if not props:
        return "{}"
    return "{" + ", ".join(["{}: {}".format(_lit(c), p) for c, p, _ in props]) + "}"

def _enum_entries(owner, props):
    out = []
    for _, param, shape in props:
        s = shape
        if type(s) == "tuple" and s[0] == "l":
            s = s[1]
        if type(s) == "tuple" and s[0] == "e":
            consts = {}
            for v in s[1]:
                c = constant_name(v)
                if c and c not in consts:
                    consts[c] = v
            if consts:
                out.append((owner + "_" + param.rstrip("_"), consts))
    return out

def emit_service(ns, service, svc_symbol, resources):
    """Emits the .bzl source for one service namespace.

    Args:
      ns: e.g. "aws".
      service: e.g. "s3".
      svc_symbol: e.g. "s3" or "lambda_".
      resources: list of normalize() results.

    Returns:
      (source, collisions) where collisions lists exported names that were renamed.
    """
    out = []
    out.append('"""Generated CloudFormation bindings for {}::{}. DO NOT EDIT."""'.format(ns.upper() if ns == "aws" else ns, service))
    out.append("")
    out.append('load("@rules_cfn//cfn/private:runtime.bzl", _resource = "resource", _type = "type_", _value = "value")')
    out.append("")
    out.append('_SPEC = Label("//:schemas")')
    out.append("")

    res_exports = []
    type_exports = []
    enum_exports = []
    used_types = {}
    collisions = []
    kw_params = [k + " = None" for k in RESOURCE_KWARGS]
    kw_pass = ", ".join(RESOURCE_KWARGS)

    for r in sorted(resources, key = lambda x: x.type_name):
        rid = "r_" + r.short.rstrip("_")
        out.append("_t_{} = _type(".format(rid))
        out.append("    {},".format(_lit(r.type_name)))
        out.append("    {},".format(_lit(svc_symbol + "." + r.short)))
        out.append("    {},".format(_props_table(r.props)))
        out.append("    required = {},".format(repr(r.required)))
        out.append("    attrs = {},".format(repr(r.attrs)))
        out.append("    spec = _SPEC,")
        out.append("    is_resource = True,")
        out.append(")")
        out.append("")
        sig = _signature(r.props, r.required, ["logical_id"]) + kw_params
        out.append("def _{}(".format(rid))
        for p in sig:
            out.append("        {},".format(p))
        out.append("        ):")
        doc = _docstring(
            r.type_name,
            r.doc,
            r.props,
            r.docs,
            extra_args = [("logical_id", "Logical ID of the resource in the template.")],
        )
        if r.attrs:
            doc += "\n\nAttributes (via .attr):\n" + "\n".join(["  {}: {}".format(k, v) for k, v in sorted(r.attrs.items())])
        out.append("    {}".format(_lit(doc)))
        out.append("    return _resource(_t_{}, logical_id, {}, {})".format(rid, _kwargs_dict(r.props), kw_pass))
        out.append("")
        res_exports.append((r.short, "_" + rid))
        enum_exports.extend(_enum_entries(r.short.rstrip("_"), r.props))

        for t in r.types:
            name = t.ctor
            if name in used_types:
                collisions.append("{} ({} vs {})".format(name, used_types[name], t.name))
                for i in range(2, 100):
                    cand = "{}_{}".format(t.ctor, i)
                    if cand not in used_types:
                        name = cand
                        break
            used_types[name] = t.name
            tid = "v_" + name
            out.append("_t_{} = _type(".format(tid))
            out.append("    {},".format(_lit(t.name)))
            out.append("    {},".format(_lit(svc_symbol.rstrip("_") + "_types." + name)))
            out.append("    {},".format(_props_table(t.props)))
            out.append("    required = {},".format(repr(t.required)))
            out.append(")")
            out.append("")
            out.append("def _{}(".format(tid))
            for p in _signature(t.props, t.required, []):
                out.append("        {},".format(p))
            out.append("        ):")
            out.append("    {}".format(_lit(_docstring(t.name, t.doc, t.props, t.docs))))
            out.append("    return _value(_t_{}, {})".format(tid, _kwargs_dict(t.props)))
            out.append("")
            type_exports.append((name, "_" + tid))
            enum_exports.extend(_enum_entries(name, t.props))

    out.append("{} = struct(".format(svc_symbol))
    for n, f in res_exports:
        out.append("    {} = {},".format(n, f))
    out.append(")")
    out.append("")
    out.append("{}_types = struct(".format(svc_symbol.rstrip("_")))
    for n, f in type_exports:
        out.append("    {} = {},".format(n, f))
    out.append(")")
    out.append("")
    out.append("{}_enums = struct(".format(svc_symbol.rstrip("_")))
    seen = {}
    for n, consts in enum_exports:
        if n in seen:
            continue
        seen[n] = True
        out.append("    {} = struct({}),".format(n, ", ".join(["{} = {}".format(c, _lit(v)) for c, v in consts.items()])))
    out.append(")")
    out.append("")
    return "\n".join(out), collisions

def service_symbol(service):
    return identifier(service.lower())
