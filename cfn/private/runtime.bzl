"""Runtime support for generated CloudFormation bindings.

Every value built by a generated constructor or by //cfn:core.bzl is a struct
carrying a `_cfn` kind tag plus its already-rendered JSON form (`_json`), the
logical-ID references it contains (`_refs`) and any assets it embeds
(`_assets`). Rendering is done bottom-up at construction time, so nothing here
needs recursion (which Bazel's Starlark forbids). Arbitrary user dicts/lists
(e.g. JSON-typed properties) are rendered with an explicit work stack.

This file sticks to plain Starlark (struct, json, fail) so the same bindings
could be evaluated by a standalone interpreter later.

Shape encoding used by generated schema tables:
  "s" string   "i" integer   "n" number   "b" boolean   "j" any JSON
  ("l", shape)              list of shape
  ("m", shape)              map of string -> shape
  ("r", "AWS::X::Y.Def", is_tag, "display")
                            typed value produced by that constructor; tag-shaped
                            types (is_tag) also accept cfn.tag()
  ("e", [values...])        one of the listed primitive values
  ("u", [shapes...])        any of the listed shapes
"""

_MAX_ITER = 1 << 24

# Reference markers carried in `_refs`.
REF = "r:"  # Ref to a resource or parameter
GETATT = "g:"  # Fn::GetAtt on a resource
COND = "c:"  # reference to a named condition
MAP = "m:"  # Fn::FindInMap on a mapping

def is_cfn(x, kind = None):
    if type(x) != "struct" or not hasattr(x, "_cfn"):
        return False
    return kind == None or x._cfn == kind

def _kind_name(x):
    if is_cfn(x):
        if x._cfn == "value":
            return "typed value " + x._type
        return x._cfn
    return type(x)

def merge_unique(lists):
    """Concatenates lists keeping the first occurrence of each element."""
    seen = {}
    out = []
    for l in lists:
        for x in l:
            if x not in seen:
                seen[x] = True
                out.append(x)
    return out

def render(x):
    """Renders a value into JSON-compatible data.

    Args:
      x: any mix of primitives, lists, dicts and cfn structs.

    Returns:
      (json_data, refs, assets)
    """
    if is_cfn(x):
        if x._cfn == "resource":
            fail("a resource ({} {}) cannot be used as a value; use .ref or .attr.<name>".format(x.type, x.logical_id))
        if x._cfn == "template":
            fail("a template cannot be embedded in another value")
        return x._json, x._refs, x._assets
    t = type(x)
    if t not in ("dict", "list", "tuple"):
        if t not in ("string", "int", "float", "bool", "NoneType"):
            fail("cannot render value of type {} into CloudFormation JSON".format(t))
        return x, [], []

    refs = []
    assets = []
    root = [None]
    stack = [(x, root, 0)]
    for _ in range(_MAX_ITER):
        if not stack:
            break
        v, parent, key = stack.pop()
        tv = type(v)
        if tv == "dict":
            d = {}
            for k in v:
                if type(k) != "string":
                    fail("CloudFormation JSON object keys must be strings, got {}: {}".format(type(k), k))
                d[k] = None
            parent[key] = d
            for k, vv in v.items():
                stack.append((vv, d, k))
        elif tv == "list" or tv == "tuple":
            l = [None] * len(v)
            parent[key] = l
            for i, vv in enumerate(v):
                stack.append((vv, l, i))
        elif is_cfn(v):
            if v._cfn in ("resource", "template") or not hasattr(v, "_json"):
                fail("a {} cannot be used as a value here; for resources use .ref or .attr.<name>".format(v._cfn))
            parent[key] = v._json
            refs.append(v._refs)
            assets.append(v._assets)
        elif tv in ("string", "int", "float", "bool", "NoneType"):
            parent[key] = v
        else:
            fail("cannot render value of type {} into CloudFormation JSON".format(tv))
    return root[0], merge_unique(refs), merge_unique(assets)

def intrinsic(j, refs = [], assets = []):
    """Wraps an already-rendered intrinsic function (or placeholder)."""
    return struct(_cfn = "intrinsic", _json = j, _refs = refs, _assets = assets)

def _fmt(v):
    if type(v) == "string":
        return json.encode(v)
    return str(v)

def _shallow_leaf(v, shape):
    """Returns True if v is acceptable at the top level of a non-union shape."""
    if type(shape) == "string":
        tv = type(v)
        if shape == "s":
            return tv == "string"
        if shape == "i":
            return tv == "int"
        if shape == "n":
            return tv == "int" or tv == "float"
        if shape == "b":
            return tv == "bool"
        return True  # "j"
    k = shape[0]
    if k == "l":
        return type(v) in ("list", "tuple")
    if k == "m":
        return type(v) == "dict"
    if k == "r":
        return is_cfn(v, "value") and (v._type == shape[1] or (shape[2] and v._type == "cfn::Tag"))
    if k == "e":
        return v in shape[1]
    fail("unknown shape {}".format(shape))

def _shallow_ok(v, shape):
    """Returns True if v is acceptable at the top level of shape (no descent).

    Codegen flattens unions, so a union's members are never unions themselves.
    """
    if is_cfn(v, "intrinsic"):
        return True
    if type(shape) == "tuple" and shape[0] == "u":
        for s in shape[1]:
            if _shallow_leaf(v, s):
                return True
        return False
    return _shallow_leaf(v, shape)

def _describe(shape):
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

def check(where, value, shape):
    """Validates value against shape, failing with a path-aware message."""
    stack = [(value, shape, "")]
    for _ in range(_MAX_ITER):
        if not stack:
            return
        v, s, path = stack.pop()
        if v == None:
            continue
        if is_cfn(v, "intrinsic"):
            continue
        if is_cfn(v, "resource"):
            fail("{}{}: got resource {} ({}); use .ref or .attr.<name>".format(where, path, v.logical_id, v.type))
        if not _shallow_ok(v, s):
            got = _fmt(v) if type(v) in ("string", "int", "float", "bool") else _kind_name(v)
            fail("{}{}: expected {}, got {}".format(where, path, _describe(s), got))
        if type(s) == "string":
            continue
        k = s[0]
        if k == "l":
            for i, e in enumerate(v):
                stack.append((e, s[1], "{}[{}]".format(path, i)))
        elif k == "m":
            for mk, mv in v.items():
                if type(mk) != "string":
                    fail("{}{}: map keys must be strings".format(where, path))
                stack.append((mv, s[1], "{}[{}]".format(path, _fmt(mk))))
        elif k == "u":
            # Descend into the first branch that accepts the value shallowly.
            for b in s[1]:
                if _shallow_ok(v, b):
                    if type(b) != "string" and b[0] in ("l", "m", "u"):
                        stack.append((v, b, path))
                    break

def type_(name, display, props, required = [], attrs = {}, spec = None, is_resource = False):
    """Declares a resource or property type for generated constructors.

    Args:
      name: CloudFormation type name, e.g. "AWS::S3::Bucket" or "AWS::S3::Bucket.Rule".
      display: the Starlark path users call, for error messages.
      props: dict of CloudFormation property name -> (param_name, shape).
      required: CloudFormation names of required properties.
      attrs: for resources, dict of attribute snake name -> GetAtt attribute name.
      spec: Label of the spec repo's schema filegroup.
      is_resource: whether this is a resource type.
    """
    return struct(
        name = name,
        display = display,
        props = props,
        required = required,
        attrs = attrs,
        spec = spec,
        is_resource = is_resource,
    )

def _render_props(t, where, kwargs):
    body = {}
    refs = []
    assets = []
    for cfn_name, v in kwargs.items():
        if v == None:
            continue
        p = t.props.get(cfn_name)
        if p == None:
            fail("{}: unknown property {}".format(where, cfn_name))
        param, shape = p
        check("{}: {}".format(where, param), v, shape)
        j, r, a = render(v)
        body[cfn_name] = j
        refs.append(r)
        assets.append(a)
    for req in t.required:
        if kwargs.get(req) == None:
            fail("{}: missing required property {}".format(where, t.props[req][0]))
    return body, merge_unique(refs), merge_unique(assets)

def value(t, kwargs):
    """Builds a typed property value."""
    body, refs, assets = _render_props(t, t.display, kwargs)
    return struct(_cfn = "value", _type = t.name, _json = body, _refs = refs, _assets = assets)

_LOGICAL_ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

def check_logical_id(what, logical_id):
    if type(logical_id) != "string" or not logical_id:
        fail("{}: logical ID must be a non-empty string, got {}".format(what, logical_id))
    if len(logical_id) > 255:
        fail("{}: logical ID {} is longer than 255 characters".format(what, logical_id))
    for c in logical_id.elems():
        if c not in _LOGICAL_ID_CHARS:
            fail("{}: logical ID {} must be alphanumeric".format(what, _fmt(logical_id)))

_POLICIES = ["Delete", "Retain", "RetainExceptOnCreate", "Snapshot"]

def _id_of(x, what):
    if type(x) == "string":
        return x
    if is_cfn(x, "resource"):
        return x.logical_id
    fail("{}: expected a resource or logical ID string, got {}".format(what, _kind_name(x)))

def resource(
        t,
        logical_id,
        kwargs,
        depends_on = None,
        condition = None,
        deletion_policy = None,
        update_replace_policy = None,
        creation_policy = None,
        update_policy = None,
        metadata = None):
    """Builds a resource."""
    where = "{} {}".format(t.name, _fmt(logical_id))
    check_logical_id(t.name, logical_id)
    props, refs, assets = _render_props(t, where, kwargs)

    out = {"Type": t.name}
    if props:
        out["Properties"] = props
    extra_refs = []
    if depends_on != None:
        if type(depends_on) not in ("list", "tuple"):
            depends_on = [depends_on]
        ids = [_id_of(d, where + ": depends_on") for d in depends_on]
        out["DependsOn"] = ids
        extra_refs.append([REF + i for i in ids])
    if condition != None:
        cid = condition.name if is_cfn(condition, "condition") else condition
        if type(cid) != "string":
            fail("{}: condition must be a cfn.condition() or its name".format(where))
        out["Condition"] = cid
        extra_refs.append([COND + cid])
    for key, v in [("DeletionPolicy", deletion_policy), ("UpdateReplacePolicy", update_replace_policy)]:
        if v != None:
            if v not in _POLICIES:
                fail("{}: {} must be one of {}, got {}".format(where, key, _POLICIES, _fmt(v)))
            out[key] = v
    for key, v in [("CreationPolicy", creation_policy), ("UpdatePolicy", update_policy), ("Metadata", metadata)]:
        if v != None:
            j, r, a = render(v)
            out[key] = j
            extra_refs.append(r)
            assets = merge_unique([assets, a])

    attr_fields = {
        snake_name: intrinsic({"Fn::GetAtt": [logical_id, cfn_attr]}, [GETATT + logical_id])
        for snake_name, cfn_attr in t.attrs.items()
    }
    return struct(
        _cfn = "resource",
        logical_id = logical_id,
        type = t.name,
        ref = intrinsic({"Ref": logical_id}, [REF + logical_id]),
        attr = struct(**attr_fields),
        _json = out,
        _refs = merge_unique([refs] + extra_refs),
        _assets = assets,
        _spec = t.spec,
    )
