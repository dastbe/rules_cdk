"""CloudFormation core: intrinsic functions, template sections and helpers.

    load("@rules_cfn//cfn:core.star", "template", "output", "sub", "scope")

Resource bindings live in the generated spec repo, one file per resource type:

    load("@cfn//aws/s3:bucket.star", "bucket", "bucket_versioning_configuration")
"""

# Intrinsic, Tag and Condition are re-exported so libraries can annotate with them.
load(":runtime.star", "Condition", "Intrinsic", "Tag", "rt")

# ---------------------------------------------------------------------------
# Intrinsic functions

def ref(target: typing.Any) -> Intrinsic:
    """{"Ref": ...} for a resource, parameter or logical ID. Prefer `resource.ref`."""
    if hasattr(target, "ref"):
        return target.ref
    if type(target) == "string":
        if target.startswith("AWS::"):
            return rt.intrinsic({"Ref": target})
        return rt.intrinsic({"Ref": target}, ["r:" + target])
    fail("ref: expected a resource, parameter or logical ID, got {}".format(type(target)))

def get_att(target: typing.Any, attribute: str) -> Intrinsic:
    """Fn::GetAtt. Prefer `resource.attr.<name>`, which the typechecker verifies."""
    lid = target.logical_id if hasattr(target, "logical_id") else target
    return rt.intrinsic({"Fn::GetAtt": [lid, attribute]}, ["g:" + lid])

def sub(template: str, variables: dict[str, typing.Any] | None = None) -> Intrinsic:
    """Fn::Sub. References inside ${...} are not tracked; pass resources via `variables`."""
    if variables == None:
        return rt.fn("Fn::Sub", template)
    return rt.fn("Fn::Sub", [template, variables])

def join(delimiter: str, values: typing.Any) -> Intrinsic:
    """Fn::Join."""
    return rt.fn("Fn::Join", [delimiter, values])

def select(index: int | Intrinsic, values: typing.Any) -> Intrinsic:
    """Fn::Select."""
    return rt.fn("Fn::Select", [index, values])

def split(delimiter: str, source: str | Intrinsic) -> Intrinsic:
    """Fn::Split."""
    return rt.fn("Fn::Split", [delimiter, source])

def base64(value: str | Intrinsic) -> Intrinsic:
    """Fn::Base64."""
    return rt.fn("Fn::Base64", value)

def cidr(ip_block: str | Intrinsic, count: int | Intrinsic, cidr_bits: int | Intrinsic) -> Intrinsic:
    """Fn::Cidr."""
    return rt.fn("Fn::Cidr", [ip_block, count, cidr_bits])

def get_azs(region: str | Intrinsic = "") -> Intrinsic:
    """Fn::GetAZs."""
    return rt.fn("Fn::GetAZs", region)

def import_value(name: str | Intrinsic) -> Intrinsic:
    """Fn::ImportValue."""
    return rt.fn("Fn::ImportValue", name)

def length(values: typing.Any) -> Intrinsic:
    """Fn::Length."""
    return rt.fn("Fn::Length", values)

def find_in_map(mapping: typing.Any, top_key: str | Intrinsic, second_key: str | Intrinsic) -> Intrinsic:
    """Fn::FindInMap."""
    name = mapping.name if hasattr(mapping, "name") else mapping
    i = rt.fn("Fn::FindInMap", [name, top_key, second_key])
    return rt.intrinsic(i._cfn.json, i._cfn.refs + ["m:" + name], i._cfn.assets)

def _cond_name(c):
    return c.name if hasattr(c, "name") else c

def if_(condition: str | Condition, if_true: typing.Any, if_false: typing.Any) -> Intrinsic:
    """Fn::If."""
    name = _cond_name(condition)
    i = rt.fn("Fn::If", [name, if_true, if_false])
    return rt.intrinsic(i._cfn.json, i._cfn.refs + ["c:" + name], i._cfn.assets)

def equals(a: typing.Any, b: typing.Any) -> Intrinsic:
    """Fn::Equals."""
    return rt.fn("Fn::Equals", [a, b])

def _cond_args(conditions):
    return [
        rt.intrinsic({"Condition": c.name}, ["c:" + c.name]) if hasattr(c, "name") else c
        for c in conditions
    ]

def and_(*conditions: typing.Any) -> Intrinsic:
    """Fn::And."""
    return rt.fn("Fn::And", _cond_args(conditions))

def or_(*conditions: typing.Any) -> Intrinsic:
    """Fn::Or."""
    return rt.fn("Fn::Or", _cond_args(conditions))

def not_(condition: typing.Any) -> Intrinsic:
    """Fn::Not."""
    return rt.fn("Fn::Not", _cond_args([condition]))

Pseudo = record(
    account_id = Intrinsic,
    notification_arns = Intrinsic,
    no_value = Intrinsic,
    partition = Intrinsic,
    region = Intrinsic,
    stack_id = Intrinsic,
    stack_name = Intrinsic,
    url_suffix = Intrinsic,
)

# Pseudo parameters: pseudo.region, pseudo.account_id, ...
pseudo = Pseudo(
    account_id = rt.intrinsic({"Ref": "AWS::AccountId"}),
    notification_arns = rt.intrinsic({"Ref": "AWS::NotificationARNs"}),
    no_value = rt.intrinsic({"Ref": "AWS::NoValue"}),
    partition = rt.intrinsic({"Ref": "AWS::Partition"}),
    region = rt.intrinsic({"Ref": "AWS::Region"}),
    stack_id = rt.intrinsic({"Ref": "AWS::StackId"}),
    stack_name = rt.intrinsic({"Ref": "AWS::StackName"}),
    url_suffix = rt.intrinsic({"Ref": "AWS::URLSuffix"}),
)

# ---------------------------------------------------------------------------
# Template sections

Parameter = record(logical_id = str, ref = Intrinsic, _cfn = typing.Any)
Mapping = record(name = str, _cfn = typing.Any)
Output = record(logical_id = str, _cfn = typing.Any)
Template = record(_cfn = typing.Any)

def parameter(
        logical_id: str,
        type: str = "String",
        default: typing.Any = None,
        description: str | None = None,
        allowed_values: list[typing.Any] | None = None,
        allowed_pattern: str | None = None,
        constraint_description: str | None = None,
        min_length: int | None = None,
        max_length: int | None = None,
        min_value: int | float | None = None,
        max_value: int | float | None = None,
        no_echo: bool | None = None) -> Parameter:
    """A template parameter. Use `.ref` to reference it."""
    rt.check_logical_id("parameter", logical_id)
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
    return Parameter(
        logical_id = logical_id,
        ref = rt.intrinsic({"Ref": logical_id}, ["r:" + logical_id]),
        _cfn = struct(kind = "parameter", json = body, refs = [], assets = []),
    )

def condition(name: str, expression: typing.Any) -> Condition:
    """A named condition, usable as `condition = ` on resources and in if_()."""
    rt.check_logical_id("condition", name)
    j, refs, _ = rt.render(expression, "condition " + name)
    return Condition(name = name, _cfn = struct(kind = "condition", json = j, refs = refs, assets = []))

def mapping(name: str, table: dict[str, dict[str, typing.Any]]) -> Mapping:
    """A Mappings entry, for find_in_map()."""
    rt.check_logical_id("mapping", name)
    return Mapping(name = name, _cfn = struct(kind = "mapping", json = table, refs = [], assets = []))

def output(
        logical_id: str,
        value: typing.Any,
        description: str | None = None,
        export_name: str | Intrinsic | None = None,
        condition: str | Condition | None = None) -> Output:
    """A stack output."""
    rt.check_logical_id("output", logical_id)
    j, refs, _ = rt.render(value, "output " + logical_id)
    body = {"Value": j}
    if description != None:
        body["Description"] = description
    if export_name != None:
        ej, er, _ = rt.render(export_name, "output " + logical_id)
        body["Export"] = {"Name": ej}
        refs = rt.merge([refs, er])
    if condition != None:
        name = _cond_name(condition)
        body["Condition"] = name
        refs = refs + ["c:" + name]
    return Output(logical_id = logical_id, _cfn = struct(kind = "output", json = body, refs = refs, assets = []))

def _flatten(items):
    out = []
    for x in items:
        if type(x) in ("list", "tuple"):
            out.extend(_flatten(x))
        elif x != None:
            out.append(x)
    return out

def _section(items, kind, what):
    out = _flatten(items)
    for x in out:
        if not hasattr(x, "_cfn") or x._cfn.kind != kind:
            fail("template: {} must contain only {} values, got {}".format(what, kind, repr(x)))
    return out

_LIMITS = {"Resources": 500, "Parameters": 200, "Outputs": 200, "Mappings": 200}

def template(
        resources: list[typing.Any] = [],
        parameters: list[typing.Any] = [],
        conditions: list[typing.Any] = [],
        mappings: list[typing.Any] = [],
        outputs: list[typing.Any] = [],
        description: str | None = None,
        metadata: typing.Any = None,
        transform: typing.Any = None) -> Template:
    """Assembles and validates a template. Lists may be nested (libraries return lists)."""
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
        out["Metadata"] = rt.render(metadata, "template metadata")[0]

    ids = {}
    refs = []
    assets = []
    for kind, items, key in [("parameter", parameters, "Parameters"), ("resource", resources, "Resources")]:
        section = {}
        for x in items:
            if x.logical_id in ids:
                fail("template: duplicate logical ID {} ({} and {})".format(x.logical_id, ids[x.logical_id], kind))
            ids[x.logical_id] = kind
            section[x.logical_id] = x._cfn.json
            refs.append([(r, x.logical_id) for r in x._cfn.refs])
            assets.append(x._cfn.assets)
        if section:
            out[key] = section

    for kind, items, key in [("condition", conditions, "Conditions"), ("mapping", mappings, "Mappings"), ("output", outputs, "Outputs")]:
        section = {}
        for x in items:
            name = x.logical_id if kind == "output" else x.name
            if name in section:
                fail("template: duplicate {} {}".format(kind, name))
            section[name] = x._cfn.json
            refs.append([(r, name) for r in x._cfn.refs])
        if section:
            out[key] = section

    for key, limit in _LIMITS.items():
        if len(out.get(key, {})) > limit:
            fail("template: {} has {} entries; CloudFormation allows at most {}".format(key, len(out[key]), limit))

    conds = out.get("Conditions", {})
    maps = out.get("Mappings", {})
    for r, owner in rt.merge(refs):
        target = r[2:]
        if r.startswith("r:") and target not in ids:
            fail("template: {} references {} which is not a resource or parameter in this template".format(owner, target))
        if r.startswith("g:") and ids.get(target) != "resource":
            fail("template: {} uses Fn::GetAtt on {} which is not a resource in this template".format(owner, target))
        if r.startswith("c:") and target not in conds:
            fail("template: {} references undefined condition {}".format(owner, target))
        if r.startswith("m:") and target not in maps:
            fail("template: {} references undefined mapping {}".format(owner, target))

    return Template(_cfn = struct(kind = "template", json = out, refs = [], assets = rt.merge(assets)))

# ---------------------------------------------------------------------------
# Helpers

Scope = record(prefix = str, id = typing.Any, child = typing.Any)

def scope(prefix: str = "") -> Scope:
    """Logical-ID namespacing for libraries: scope("Api").child("Items").id("Get") == "ApiItemsGet"."""

    def _id(name: str) -> str:
        lid = prefix + name
        rt.check_logical_id("scope", lid)
        return lid

    def _child(name: str) -> Scope:
        return scope(prefix + name)

    return Scope(prefix = prefix, id = _id, child = _child)

def tag(key: str | Intrinsic, value: str | Intrinsic) -> Tag:
    """A {Key, Value} tag accepted by every tag-shaped property."""
    j, refs, assets = rt.render({"Key": key, "Value": value}, "tag")
    return Tag(key = key, value = value, _cfn = struct(kind = "value", type = "cfn::Tag", json = j, refs = refs, assets = assets))

Asset = record(label = str, packaging = str, bucket = Intrinsic, key = Intrinsic, s3_uri = Intrinsic)

def asset(label: str, packaging: str = "zip") -> Asset:
    """A local file packaged and uploaded to S3 at deploy time.

    Args:
      label: absolute label of the files ("//pkg:target"). Every file of the target is
        zipped at its path relative to the target's package (packaging = "zip"), or the
        target's single file is uploaded as-is (packaging = "file"). The cfn_stack must
        list the label in `assets`.
      packaging: "zip" or "file".

    Returns:
      bucket/key/s3_uri placeholders that `cfnctl package` resolves to the
      content-addressed location in the asset bucket.
    """
    if packaging not in ("zip", "file"):
        fail("asset: packaging must be \"zip\" or \"file\"")
    if not (label.startswith("//") or label.startswith("@")):
        fail("asset: label must be absolute (\"//pkg:target\"), got {}".format(repr(label)))
    a = (label, packaging)

    def part(p):
        return rt.intrinsic({"__cfn_asset__": {"label": label, "part": p}}, [], [a])

    return Asset(label = label, packaging = packaging, bucket = part("bucket"), key = part("key"), s3_uri = part("s3_uri"))

# IAM policy documents are JSON-typed in the spec; these give them types anyway.

Statement = record(_cfn = typing.Any)
PolicyDocument = record(_cfn = typing.Any)

def statement(
        effect: str = "Allow",
        actions: typing.Any = None,
        resources: typing.Any = None,
        principal: typing.Any = None,
        not_actions: typing.Any = None,
        not_resources: typing.Any = None,
        not_principal: typing.Any = None,
        condition: dict[str, typing.Any] | None = None,
        sid: str | None = None) -> Statement:
    """One IAM policy statement."""
    if effect not in ("Allow", "Deny"):
        fail("statement: effect must be Allow or Deny, got {}".format(repr(effect)))
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
    j, refs, assets = rt.render(body, "statement")
    return Statement(_cfn = struct(kind = "value", type = "cfn::iam::Statement", json = j, refs = refs, assets = assets))

def policy_document(statements: list[Statement], version: str = "2012-10-17") -> PolicyDocument:
    """An IAM policy document."""
    j, refs, assets = rt.render({"Version": version, "Statement": statements}, "policy_document")
    return PolicyDocument(_cfn = struct(kind = "value", type = "cfn::iam::PolicyDocument", json = j, refs = refs, assets = assets))

def service_principal(service: str) -> dict[str, str]:
    """{"Service": service}, for statement(principal = ...)."""
    return {"Service": service}
