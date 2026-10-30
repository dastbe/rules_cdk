"""CloudFormation name -> Starlark snake_case identifier conversion.

Generated bindings and the runtime both rely on these functions, so any change
here is visible in the golden tests under //cfn/tests.
"""

# Starlark keywords and reserved words. Identifiers that collide get a trailing underscore.
KEYWORDS = {k: True for k in [
    "and",
    "as",
    "assert",
    "async",
    "await",
    "break",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "load",
    "nonlocal",
    "not",
    "or",
    "pass",
    "raise",
    "return",
    "try",
    "while",
    "with",
    "yield",
    "True",
    "False",
    "None",
    # Built-in struct methods; generated struct fields cannot use these names.
    "to_json",
    "to_proto",
]}

# Resource-level keyword arguments that every generated resource constructor accepts.
# Properties whose snake name collides with one of these get a trailing underscore.
RESOURCE_KWARGS = [
    "depends_on",
    "condition",
    "deletion_policy",
    "update_replace_policy",
    "creation_policy",
    "update_policy",
    "metadata",
]

RESERVED_PARAMS = {k: True for k in ["logical_id"] + RESOURCE_KWARGS}

# Mixed-case tokens the boundary splitter would otherwise mangle (e.g. IPv6 -> i_pv6).
TOKEN_OVERRIDES = [
    ("IPv4", "Ipv4"),
    ("IPv6", "Ipv6"),
    ("IPv", "Ipv"),
    ("OAuth", "Oauth"),
    ("macOS", "Macos"),
    ("iOS", "Ios"),
    ("IoT", "Iot"),
    ("WebACL", "WebAcl"),
    ("WebSocket", "Websocket"),
    ("GraphQL", "Graphql"),
    ("NoSQL", "Nosql"),
    ("MySQL", "Mysql"),
    ("PostgreSQL", "Postgresql"),
    ("DynamoDB", "Dynamodb"),
    ("OpenSearch", "Opensearch"),
    ("OpenID", "Openid"),
    ("JavaScript", "Javascript"),
    ("TypeScript", "Typescript"),
    ("GitHub", "Github"),
    ("GitLab", "Gitlab"),
    ("BitBucket", "Bitbucket"),
]

def _is_upper(c):
    return c.isalpha() and c.isupper()

def _is_lower(c):
    return c.isalpha() and c.islower()

def snake(name):
    """Converts a CloudFormation PascalCase name into snake_case.

    Args:
      name: e.g. "SSESpecification", "IPv6CidrBlock", "S3Bucket", "ResourceARNs".

    Returns:
      e.g. "sse_specification", "ipv6_cidr_block", "s3_bucket", "resource_arns".
    """
    for old, new in TOKEN_OVERRIDES:
        name = name.replace(old, new)
    chars = name.elems()
    n = len(chars)
    out = []
    for i in range(n):
        c = chars[i]
        if not c.isalnum():
            out.append("_")
            continue
        prev = chars[i - 1] if i > 0 else ""
        nxt = chars[i + 1] if i + 1 < n else ""
        if i > 0 and _is_upper(c):
            if _is_lower(prev) or prev.isdigit():
                out.append("_")
            elif _is_upper(prev) and _is_lower(nxt):
                # "ABc" splits as "A", "Bc" -- except a plural acronym like "ARNs" / "ARNsFoo".
                after = chars[i + 2] if i + 2 < n else ""
                plural = nxt == "s" and (after == "" or not _is_lower(after))
                if not plural:
                    out.append("_")
        out.append(c.lower())
    s = "".join(out)

    # Collapse runs of underscores and trim.
    parts = [p for p in s.split("_") if p]
    s = "_".join(parts)
    if s and s[0].isdigit():
        s = "n" + s
    return s

def identifier(name):
    """snake() plus keyword escaping, for use as a Starlark identifier."""
    s = snake(name)
    if s in KEYWORDS:
        s = s + "_"
    return s

def param_name(cfn_property):
    """Keyword argument name for a CloudFormation property on a constructor."""
    s = identifier(cfn_property)
    if s in RESERVED_PARAMS:
        s = s + "_"
    return s

def constant_name(value):
    """UPPER_SNAKE constant name for an enum value, or None if it can't be one."""
    if type(value) != "string" or not value:
        return None
    s = snake(value).upper()
    if not s or not (s[0].isalpha()):
        return None
    return s
