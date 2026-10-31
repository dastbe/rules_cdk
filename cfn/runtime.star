"""Runtime support for generated CloudFormation bindings (starlark-rust).

Generated files load `Intrinsic`, `Tag`, `Condition` and `rt` from here. Users
should load from `core.star` instead.

Every CloudFormation value is a record carrying a `_cfn` field: a struct with
the rendered JSON (`json`), the logical IDs it references (`refs`) and the
assets it embeds (`assets`). Rendering happens bottom-up at construction time.

Ref markers in `refs`: "r:<id>" Ref, "g:<id>" Fn::GetAtt, "c:<name>" condition,
"m:<name>" mapping.
"""

Intrinsic = record(_cfn = typing.Any)

Tag = record(key = typing.Any, value = typing.Any, _cfn = typing.Any)

Condition = record(name = str, _cfn = typing.Any)

def _merge(lists):
    seen = {}
    out = []
    for l in lists:
        for x in l:
            if x not in seen:
                seen[x] = True
                out.append(x)
    return out

def _cfn_of(x):
    if hasattr(x, "_cfn"):
        return x._cfn
    return None

def render(x, where = "value"):
    """Renders a value into (json, refs, assets)."""
    if x == None or type(x) in ("string", "int", "float", "bool"):
        return x, [], []
    c = _cfn_of(x)
    if c != None:
        if c.kind == "resource":
            fail("{}: got resource {} ({}); use .ref or .attr.<name>".format(where, x.logical_id, x.type))
        if c.kind in ("template", "parameter", "output", "mapping"):
            fail("{}: a {} cannot be used as a value".format(where, c.kind))
        return c.json, c.refs, c.assets
    if type(x) in ("list", "tuple"):
        js, refs, assets = [], [], []
        for i, e in enumerate(x):
            j, r, a = render(e, "{}[{}]".format(where, i))
            js.append(j)
            refs.append(r)
            assets.append(a)
        return js, _merge(refs), _merge(assets)
    if type(x) == "dict":
        js, refs, assets = {}, [], []
        for k, v in x.items():
            if type(k) != "string":
                fail("{}: CloudFormation JSON object keys must be strings, got {}".format(where, repr(k)))
            j, r, a = render(v, "{}[{}]".format(where, repr(k)))
            js[k] = j
            refs.append(r)
            assets.append(a)
        return js, _merge(refs), _merge(assets)
    fail("{}: cannot render {} into CloudFormation JSON".format(where, type(x)))

def intrinsic(j, refs = [], assets = []):
    return Intrinsic(_cfn = struct(kind = "intrinsic", json = j, refs = refs, assets = assets))

def fn(name, args):
    j, refs, assets = render(args, name)
    return intrinsic({name: j}, refs, assets)

def is_intrinsic(x):
    c = _cfn_of(x)
    return c != None and c.kind == "intrinsic"

def _fmt(v):
    return repr(v)

def check(where, v, c):
    """Checks the constraints types can't express: enum, pattern, lengths, ranges."""
    if v == None or c == None or is_intrinsic(v):
        return
    if "enum" in c and v not in c["enum"]:
        fail("{}: expected one of [{}], got {}".format(where, ", ".join([_fmt(e) for e in c["enum"]]), _fmt(v)))
    t = type(v)
    if t == "string":
        n = len(v)
        if "min_length" in c and n < c["min_length"]:
            fail("{}: {} is shorter than the minimum length {}".format(where, _fmt(v), c["min_length"]))
        if "max_length" in c and n > c["max_length"]:
            fail("{}: {} is longer than the maximum length {}".format(where, _fmt(v), c["max_length"]))
        if "pattern" in c and cfn_regex_match(c["pattern"], v) == False:
            fail("{}: {} does not match pattern {}".format(where, _fmt(v), c["pattern"]))
    elif t == "int" or t == "float":
        if "minimum" in c and v < c["minimum"]:
            fail("{}: {} is less than the minimum {}".format(where, v, c["minimum"]))
        if "maximum" in c and v > c["maximum"]:
            fail("{}: {} is greater than the maximum {}".format(where, v, c["maximum"]))
    elif t == "list":
        if "min_items" in c and len(v) < c["min_items"]:
            fail("{}: has {} items; at least {} required".format(where, len(v), c["min_items"]))
        if "max_items" in c and len(v) > c["max_items"]:
            fail("{}: has {} items; at most {} allowed".format(where, len(v), c["max_items"]))
        if "items" in c:
            for i, e in enumerate(v):
                check("{}[{}]".format(where, i), e, c["items"])
    elif t == "dict" and "values" in c:
        for k, e in v.items():
            check("{}[{}]".format(where, _fmt(k)), e, c["values"])

def type_info(cfn_name, display, props, attrs = {}):
    """Schema table for a generated constructor: props maps param -> (CFN name, constraints)."""
    return struct(cfn_name = cfn_name, display = display, props = props, attrs = attrs)

def _render_props(t, where, kwargs):
    body, refs, assets = {}, [], []
    for param, v in kwargs.items():
        if v == None:
            continue
        cfn_name, c = t.props[param]
        w = "{}: {}".format(where, param)
        check(w, v, c)
        j, r, a = render(v, w)
        body[cfn_name] = j
        refs.append(r)
        assets.append(a)
    return body, _merge(refs), _merge(assets)

def value(t, kwargs):
    """Renders a property-type value; the result goes in its record's _cfn field."""
    body, refs, assets = _render_props(t, t.display, kwargs)
    return struct(kind = "value", type = t.cfn_name, json = body, refs = refs, assets = assets)

_ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

def check_logical_id(what, logical_id):
    if type(logical_id) != "string" or not logical_id:
        fail("{}: logical ID must be a non-empty string, got {}".format(what, repr(logical_id)))
    if len(logical_id) > 255:
        fail("{}: logical ID {} is longer than 255 characters".format(what, logical_id))
    for ch in logical_id.elems():
        if ch not in _ID_CHARS:
            fail("{}: logical ID {} must be alphanumeric".format(what, repr(logical_id)))

_POLICIES = ["Delete", "Retain", "RetainExceptOnCreate", "Snapshot"]

def _id_of(x, where):
    if type(x) == "string":
        return x
    c = _cfn_of(x)
    if c != None and c.kind == "resource":
        return x.logical_id
    fail("{}: expected a resource or logical ID string, got {}".format(where, type(x)))

def resource(
        rec,
        attrs_rec,
        t,
        logical_id,
        kwargs,
        depends_on,
        condition,
        deletion_policy,
        update_replace_policy,
        creation_policy,
        update_policy,
        metadata):
    """Builds a resource record."""
    where = "{} {}".format(t.cfn_name, repr(logical_id))
    check_logical_id(t.cfn_name, logical_id)
    props, refs, assets = _render_props(t, where, kwargs)
    out = {"Type": t.cfn_name}
    if props:
        out["Properties"] = props
    extra = []
    if depends_on != None:
        ids = [_id_of(d, where + ": depends_on") for d in depends_on]
        out["DependsOn"] = ids
        extra.append(["r:" + i for i in ids])
    if condition != None:
        name = condition.name if hasattr(condition, "name") else condition
        out["Condition"] = name
        extra.append(["c:" + name])
    for key, v in [("DeletionPolicy", deletion_policy), ("UpdateReplacePolicy", update_replace_policy)]:
        if v != None:
            if v not in _POLICIES:
                fail("{}: {} must be one of {}, got {}".format(where, key, _POLICIES, repr(v)))
            out[key] = v
    for key, v in [("CreationPolicy", creation_policy), ("UpdatePolicy", update_policy), ("Metadata", metadata)]:
        if v != None:
            j, r, a = render(v, "{}: {}".format(where, key))
            out[key] = j
            extra.append(r)
            assets = _merge([assets, a])
    attr_values = {
        k: intrinsic({"Fn::GetAtt": [logical_id, v]}, ["g:" + logical_id])
        for k, v in t.attrs.items()
    }
    return rec(
        logical_id = logical_id,
        type = t.cfn_name,
        ref = intrinsic({"Ref": logical_id}, ["r:" + logical_id]),
        attr = attrs_rec(**attr_values),
        _cfn = struct(kind = "resource", json = out, refs = _merge([refs] + extra), assets = assets),
        **kwargs
    )

rt = struct(
    check = check,
    check_logical_id = check_logical_id,
    fn = fn,
    intrinsic = intrinsic,
    is_intrinsic = is_intrinsic,
    merge = _merge,
    render = render,
    resource = resource,
    type_info = type_info,
    value = value,
)
