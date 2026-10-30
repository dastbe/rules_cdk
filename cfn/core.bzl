"""Hand-written CloudFormation core: intrinsics, template sections and helpers.

    load("@rules_cfn//cfn:core.bzl", "cfn")

Everything is exposed through the `cfn` struct.
"""

load(
    "//cfn/private:runtime.bzl",
    "COND",
    "GETATT",
    "MAP",
    "REF",
    "check",
    "check_logical_id",
    "intrinsic",
    "is_cfn",
    "merge_unique",
    "render",
)

# ---------------------------------------------------------------------------
# Intrinsic functions

def _fn(name, args):
    j, refs, assets = render(args)
    return intrinsic({name: j}, refs, assets)

def _ref(target):
    """{"Ref": ...} for a resource, parameter, pseudo parameter or logical ID string."""
    if is_cfn(target, "resource") or is_cfn(target, "parameter"):
        return target.ref
    if is_cfn(target, "intrinsic"):
        return target
    if type(target) == "string":
        if target.startswith("AWS::"):
            return intrinsic({"Ref": target})
        return intrinsic({"Ref": target}, [REF + target])
    fail("cfn.ref: expected a resource, parameter or logical ID, got {}".format(type(target)))

def _get_att(target, attribute):
    """Fn::GetAtt. Prefer resource.attr.<name>, which is checked against the spec."""
    lid = target.logical_id if is_cfn(target, "resource") else target
    if type(lid) != "string":
        fail("cfn.get_att: expected a resource or logical ID")
    return intrinsic({"Fn::GetAtt": [lid, attribute]}, [GETATT + lid])

def _sub(template, variables = None):
    """Fn::Sub. References to logical IDs inside ${...} are not tracked; prefer variables."""
    if variables == None:
        return _fn("Fn::Sub", template)
    return _fn("Fn::Sub", [template, variables])

def _join(delimiter, values):
    return _fn("Fn::Join", [delimiter, values])

def _select(index, values):
    return _fn("Fn::Select", [index, values])

def _split(delimiter, source):
    return _fn("Fn::Split", [delimiter, source])

def _base64(value):
    return _fn("Fn::Base64", value)

def _cidr(ip_block, count, cidr_bits):
    return _fn("Fn::Cidr", [ip_block, count, cidr_bits])

def _get_azs(region = ""):
    return _fn("Fn::GetAZs", region)

def _import_value(name):
    return _fn("Fn::ImportValue", name)

def _length(values):
    return _fn("Fn::Length", values)

def _find_in_map(mapping, top_key, second_key):
    name = mapping.name if is_cfn(mapping, "mapping") else mapping
    i = _fn("Fn::FindInMap", [name, top_key, second_key])
    return intrinsic(i._json, i._refs + [MAP + name], i._assets)

def _cond_name(c):
    if is_cfn(c, "condition"):
        return c.name
    if type(c) == "string":
        return c
    fail("expected a cfn.condition() or condition name")

def _if(condition, if_true, if_false):
    name = _cond_name(condition)
    i = _fn("Fn::If", [name, if_true, if_false])
    return intrinsic(i._json, i._refs + [COND + name], i._assets)

def _equals(a, b):
    return _fn("Fn::Equals", [a, b])

def _cond_args(conditions):
    out = []
    for c in conditions:
        if is_cfn(c, "condition"):
            out.append(intrinsic({"Condition": c.name}, [COND + c.name]))
        else:
            out.append(c)
    return out

def _and(*conditions):
    return _fn("Fn::And", _cond_args(conditions))

def _or(*conditions):
    return _fn("Fn::Or", _cond_args(conditions))

def _not(condition):
    return _fn("Fn::Not", _cond_args([condition]))

_PSEUDO = struct(
    account_id = intrinsic({"Ref": "AWS::AccountId"}),
    notification_arns = intrinsic({"Ref": "AWS::NotificationARNs"}),
    no_value = intrinsic({"Ref": "AWS::NoValue"}),
    partition = intrinsic({"Ref": "AWS::Partition"}),
    region = intrinsic({"Ref": "AWS::Region"}),
    stack_id = intrinsic({"Ref": "AWS::StackId"}),
    stack_name = intrinsic({"Ref": "AWS::StackName"}),
    url_suffix = intrinsic({"Ref": "AWS::URLSuffix"}),
)

# ---------------------------------------------------------------------------
# Template sections

def _parameter(
        logical_id,
        type = "String",
        default = None,
        description = None,
        allowed_values = None,
        allowed_pattern = None,
        constraint_description = None,
        min_length = None,
        max_length = None,
        min_value = None,
        max_value = None,
        no_echo = None):
    """A template parameter. Use `.ref` to reference it."""
    check_logical_id("cfn.parameter", logical_id)
    body = {"Type": type}
    for k, v in [
        ("Default", default),
        ("Description", description),
        ("AllowedValues", allowed_values),
        ("AllowedPattern", allowed_pattern),
        ("ConstraintDescription", constraint_description),
        ("MinLength", min_length),
        ("MaxLength", max_length),
        ("MinValue", min_value),
        ("MaxValue", max_value),
        ("NoEcho", no_echo),
    ]:
        if v != None:
            body[k] = v
    return struct(
        _cfn = "parameter",
        logical_id = logical_id,
        ref = intrinsic({"Ref": logical_id}, [REF + logical_id]),
        _json = body,
    )

def _condition(name, expression):
    """A named condition, usable as `condition = ` on resources and in cfn.if_()."""
    check_logical_id("cfn.condition", name)
    j, refs, _ = render(expression)
    return struct(_cfn = "condition", name = name, _json = j, _refs = refs)

def _mapping(name, table):
    check_logical_id("cfn.mapping", name)
    check("cfn.mapping " + name, table, ("m", ("m", "j")))
    return struct(_cfn = "mapping", name = name, _json = table)

def _output(logical_id, value, description = None, export_name = None, condition = None):
    check_logical_id("cfn.output", logical_id)
    j, refs, _ = render(value)
    body = {"Value": j}
    if description != None:
        body["Description"] = description
    if export_name != None:
        ej, er, _ = render(export_name)
        body["Export"] = {"Name": ej}
        refs = merge_unique([refs, er])
    if condition != None:
        name = _cond_name(condition)
        body["Condition"] = name
        refs = refs + [COND + name]
    return struct(_cfn = "output", logical_id = logical_id, _json = body, _refs = refs)

def _flatten(items, what):
    """Flattens arbitrarily nested lists of cfn values (libraries return lists)."""
    out = []
    stack = [items]
    for _ in range(1 << 20):
        if not stack:
            break
        x = stack.pop()
        if type(x) in ("list", "tuple"):
            for e in reversed(x):
                stack.append(e)
        elif x != None:
            out.append(x)
    return out

def _section(items, kind, what):
    out = _flatten(items, what)
    for x in out:
        if not is_cfn(x, kind):
            fail("cfn.template: {} must contain only {} values, got {}".format(what, kind, type(x)))
    return out

_LIMITS = {"Resources": 500, "Parameters": 200, "Outputs": 200, "Mappings": 200}

def _template(
        resources = [],
        parameters = [],
        conditions = [],
        mappings = [],
        outputs = [],
        description = None,
        metadata = None,
        transform = None):
    """Assembles and validates a template. Pass the result to cfn_stack(template = ...)."""
    resources = _section(resources, "resource", "resources")
    parameters = _section(parameters, "parameter", "parameters")
    conditions = _section(conditions, "condition", "conditions")
    mappings = _section(mappings, "mapping", "mappings")
    outputs = _section(outputs, "output", "outputs")

    out = {"AWSTemplateFormatVersion": "2010-09-09"}
    if description != None:
        out["Description"] = description
    if transform != None:
        out["Transform"] = transform
    if metadata != None:
        out["Metadata"] = render(metadata)[0]

    ids = {}
    refs = []
    assets = []
    specs = []
    for kind, items, key in [
        ("parameter", parameters, "Parameters"),
        ("resource", resources, "Resources"),
    ]:
        section = {}
        for x in items:
            if x.logical_id in ids:
                fail("cfn.template: duplicate logical ID {} ({} and {})".format(x.logical_id, ids[x.logical_id], kind))
            ids[x.logical_id] = kind
            section[x.logical_id] = x._json
            if kind == "resource":
                refs.append([(r, x.logical_id) for r in x._refs])
                assets.append(x._assets)
                if x._spec != None:
                    specs.append([x._spec])
        if section:
            out[key] = section

    for kind, items, key in [
        ("condition", conditions, "Conditions"),
        ("mapping", mappings, "Mappings"),
        ("output", outputs, "Outputs"),
    ]:
        section = {}
        for x in items:
            name = x.logical_id if kind == "output" else x.name
            if name in section:
                fail("cfn.template: duplicate {} {}".format(kind, name))
            section[name] = x._json
            if kind != "mapping":
                refs.append([(r, name) for r in x._refs])
        if section:
            out[key] = section

    for key, limit in _LIMITS.items():
        if len(out.get(key, {})) > limit:
            fail("cfn.template: {} has {} entries; CloudFormation allows at most {}".format(key, len(out[key]), limit))

    conds = out.get("Conditions", {})
    maps = out.get("Mappings", {})
    for r, owner in merge_unique(refs):
        target = r[2:]
        if r.startswith(REF) and target not in ids:
            fail("cfn.template: {} references {} which is not a resource or parameter in this template".format(owner, target))
        if r.startswith(GETATT) and ids.get(target) != "resource":
            fail("cfn.template: {} uses Fn::GetAtt on {} which is not a resource in this template".format(owner, target))
        if r.startswith(COND) and target not in conds:
            fail("cfn.template: {} references undefined condition {}".format(owner, target))
        if r.startswith(MAP) and target not in maps:
            fail("cfn.template: {} references undefined mapping {}".format(owner, target))

    return struct(
        _cfn = "template",
        json = out,
        assets = merge_unique(assets),
        specs = merge_unique(specs),
    )

def _template_json(template):
    """Serializes a cfn.template() to a JSON string."""
    if not is_cfn(template, "template"):
        fail("cfn.template_json: expected a cfn.template()")
    return json.encode_indent(template.json, indent = "  ")

# ---------------------------------------------------------------------------
# Helpers

def _scope(prefix = ""):
    """Logical-ID namespacing for libraries: scope("Api").child("Items").id("Get") == "ApiItemsGet"."""

    def _id(name):
        lid = prefix + name
        check_logical_id("cfn.scope", lid)
        return lid

    def _child(name):
        return _scope(prefix + name)

    return struct(prefix = prefix, id = _id, child = _child)

def _tag(key, value):
    """A {Key, Value} tag accepted by every tag-shaped property."""
    check("cfn.tag: key", key, "s")
    check("cfn.tag: value", value, "s")
    j, refs, assets = render({"Key": key, "Value": value})
    return struct(_cfn = "value", _type = "cfn::Tag", _json = j, _refs = refs, _assets = assets)

def _asset(src, packaging = "zip"):
    """A local file packaged and uploaded to S3 at deploy time.

    Args:
      src: label of the file(s). With packaging = "zip" every file of the target is
        zipped at its path relative to the target's package. With "file" the target
        must produce exactly one file, uploaded as-is.
      packaging: "zip" or "file".

    Returns:
      struct(bucket, key, s3_uri) of placeholders that `cfnctl package` resolves to
      the content-addressed location in the asset bucket.
    """
    if packaging not in ("zip", "file"):
        fail("cfn.asset: packaging must be \"zip\" or \"file\"")
    if src.startswith("@") or src.startswith("//"):
        label = Label(src)
    else:
        label = native.package_relative_label(src)
    label_str = str(label)
    if label_str.startswith("@@//"):
        label_str = label_str[2:]
    a = (label_str, packaging)

    def part(p):
        return intrinsic({"__cfn_asset__": {"label": label_str, "part": p}}, [], [a])

    return struct(
        _cfn = "asset",
        label = label_str,
        bucket = part("bucket"),
        key = part("key"),
        s3_uri = part("s3_uri"),
    )

# IAM policy documents are JSON-typed in the spec; these give them types anyway.

def _statement(
        effect = "Allow",
        actions = None,
        resources = None,
        principal = None,
        not_actions = None,
        not_resources = None,
        not_principal = None,
        condition = None,
        sid = None):
    if effect not in ("Allow", "Deny"):
        fail("cfn.iam.statement: effect must be Allow or Deny")
    body = {"Effect": effect}
    for k, v in [
        ("Sid", sid),
        ("Principal", principal),
        ("NotPrincipal", not_principal),
        ("Action", actions),
        ("NotAction", not_actions),
        ("Resource", resources),
        ("NotResource", not_resources),
        ("Condition", condition),
    ]:
        if v != None:
            body[k] = v
    j, refs, assets = render(body)
    return struct(_cfn = "value", _type = "cfn::iam::Statement", _json = j, _refs = refs, _assets = assets)

def _policy_document(statements, version = "2012-10-17"):
    check("cfn.iam.policy_document: statements", statements, ("l", ("r", "cfn::iam::Statement", False, "cfn.iam.statement")))
    j, refs, assets = render({"Version": version, "Statement": statements})
    return intrinsic(j, refs, assets)

def _service_principal(service):
    return {"Service": service}

cfn = struct(
    # intrinsics
    ref = _ref,
    get_att = _get_att,
    sub = _sub,
    join = _join,
    select = _select,
    split = _split,
    base64 = _base64,
    cidr = _cidr,
    get_azs = _get_azs,
    import_value = _import_value,
    length = _length,
    find_in_map = _find_in_map,
    if_ = _if,
    equals = _equals,
    and_ = _and,
    or_ = _or,
    not_ = _not,
    pseudo = _PSEUDO,
    # template
    parameter = _parameter,
    condition = _condition,
    mapping = _mapping,
    output = _output,
    template = _template,
    template_json = _template_json,
    # helpers
    scope = _scope,
    tag = _tag,
    asset = _asset,
    iam = struct(
        statement = _statement,
        policy_document = _policy_document,
        service_principal = _service_principal,
    ),
)
