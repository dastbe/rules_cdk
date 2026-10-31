//! CloudFormation name -> Starlark identifier conversion.
//!
//! Generated bindings depend on these rules, so changes show up in the golden
//! tests and in every user's load() statements.

/// Starlark keywords and reserved words. Identifiers that collide get a trailing underscore.
const KEYWORDS: &[&str] = &[
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "load", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    "True", "False", "None",
];

/// Keyword arguments every generated resource constructor accepts.
pub const RESOURCE_KWARGS: &[&str] = &[
    "depends_on",
    "condition",
    "deletion_policy",
    "update_replace_policy",
    "creation_policy",
    "update_policy",
    "metadata",
];

/// Field names every generated resource record has, besides properties' attributes.
const RESERVED_PARAMS: &[&str] = &["logical_id"];

/// Mixed-case tokens the boundary splitter would otherwise mangle (e.g. IPv6 -> i_pv6).
const TOKEN_OVERRIDES: &[(&str, &str)] = &[
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
];

/// Converts a CloudFormation PascalCase name into snake_case.
///
/// `SSESpecification` -> `sse_specification`, `IPv6CidrBlock` -> `ipv6_cidr_block`,
/// `S3Bucket` -> `s3_bucket`, `ResourceARNs` -> `resource_arns`.
pub fn snake(name: &str) -> String {
    let mut name = name.to_owned();
    for (old, new) in TOKEN_OVERRIDES {
        name = name.replace(old, new);
    }
    let chars: Vec<char> = name.chars().collect();
    let upper = |c: char| c.is_ascii_uppercase();
    let lower = |c: char| c.is_ascii_lowercase();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if !c.is_ascii_alphanumeric() {
            out.push('_');
            continue;
        }
        if i > 0 && upper(c) {
            let prev = chars[i - 1];
            let next = chars.get(i + 1).copied();
            if lower(prev) || prev.is_ascii_digit() {
                out.push('_');
            } else if upper(prev) && next.is_some_and(lower) {
                // "ABc" splits as "A", "Bc" -- except a plural acronym like "ARNs".
                let after = chars.get(i + 2).copied();
                let plural = next == Some('s') && !after.is_some_and(lower);
                if !plural {
                    out.push('_');
                }
            }
        }
        out.push(c.to_ascii_lowercase());
    }
    let mut s = out.split('_').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("_");
    if s.starts_with(|c: char| c.is_ascii_digit()) {
        s.insert(0, 'n');
    }
    s
}

fn escape(mut s: String, reserved: &[&str]) -> String {
    if KEYWORDS.contains(&s.as_str()) || reserved.contains(&s.as_str()) {
        s.push('_');
    }
    s
}

/// snake() plus keyword escaping, for use as a Starlark identifier.
pub fn identifier(name: &str) -> String {
    escape(snake(name), &[])
}

/// Keyword argument / record field name for a CloudFormation property.
pub fn param_name(cfn_property: &str) -> String {
    let mut reserved: Vec<&str> = RESOURCE_KWARGS.to_vec();
    reserved.extend(RESERVED_PARAMS);
    // Record fields every generated record has.
    reserved.extend(["attr", "ref", "type"]);
    escape(snake(cfn_property), &reserved)
}

/// PascalCase record type name from a snake_case identifier.
pub fn pascal(snake: &str) -> String {
    snake
        .split('_')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let mut c = p.chars();
            match c.next() {
                Some(f) => f.to_ascii_uppercase().to_string() + c.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snake_cases() {
        for (input, want) in [
            ("BucketName", "bucket_name"),
            ("SSESpecification", "sse_specification"),
            ("IPv6CidrBlock", "ipv6_cidr_block"),
            ("S3Bucket", "s3_bucket"),
            ("ResourceARNs", "resource_arns"),
            ("ARNsFoo", "arns_foo"),
            ("DBSubnetGroupName", "db_subnet_group_name"),
            ("HTTPSettings", "http_settings"),
            ("EC2Instance", "ec2_instance"),
            ("Route53Resolver", "route53_resolver"),
            ("DynamoDBTarget", "dynamodb_target"),
            ("Http2Enabled", "http2_enabled"),
            ("VPCEndpoint", "vpc_endpoint"),
            ("2FA", "n2_fa"),
        ] {
            assert_eq!(snake(input), want, "{input}");
        }
    }

    #[test]
    fn escaping() {
        assert_eq!(identifier("Lambda"), "lambda_");
        assert_eq!(param_name("From"), "from_");
        assert_eq!(param_name("Condition"), "condition_");
        assert_eq!(param_name("Type"), "type_");
        assert_eq!(param_name("BucketName"), "bucket_name");
        assert_eq!(pascal("bucket_versioning_configuration"), "BucketVersioningConfiguration");
        assert_eq!(pascal("s3_bucket"), "S3Bucket");
    }
}
