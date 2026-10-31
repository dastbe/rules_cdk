//! Emits typed Starlark bindings: one `.star` file per resource type.
//!
//! Each file defines, for a resource like AWS::S3::Bucket:
//! - a record type per property type (`BucketVersioningConfiguration`) and a
//!   snake_case constructor for it (`bucket_versioning_configuration(...)`),
//! - the resource record (`Bucket`), its attribute record (`BucketAttrs`) and
//!   constructor (`bucket(logical_id, ...)`).
//!
//! Constructor parameters carry type annotations, so the starlark-rust
//! typechecker and LSP see the full schema. Constraints annotations can't
//! express (enums, patterns, lengths, ranges) are checked at run time by
//! `_rt.value` / `_rt.resource` from the tables emitted alongside.

use std::collections::BTreeMap;
use std::fmt::Write;

use serde_json::Value;

use crate::naming::{pascal, RESOURCE_KWARGS};
use crate::schema::{Constraints, Kind, Prop, PropType, Resource, Shape};

/// Path of the generated file for a resource, relative to the spec root.
pub fn rel_path(r: &Resource) -> String {
    format!("{}/{}/{}.star", r.namespace, r.service, r.file_stem)
}

/// Label to load a resource's bindings from, e.g. `@cfn//aws/s3:bucket.star`.
pub fn load_label(repo: &str, r: &Resource) -> String {
    format!("@{repo}//{}/{}:{}.star", r.namespace, r.service, r.file_stem)
}

fn lit(s: &str) -> String {
    // JSON string literals are valid Starlark string literals.
    serde_json::to_string(s).unwrap()
}

fn num(f: f64) -> String {
    if f.fract() == 0.0 && f.abs() < 1e15 {
        format!("{}", f as i64)
    } else {
        format!("{f}")
    }
}

fn json_lit(v: &Value) -> String {
    match v {
        Value::Null => "None".into(),
        Value::Bool(b) => if *b { "True" } else { "False" }.into(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => lit(s),
        Value::Array(a) => format!("[{}]", a.iter().map(json_lit).collect::<Vec<_>>().join(", ")),
        Value::Object(o) => format!(
            "{{{}}}",
            o.iter().map(|(k, v)| format!("{}: {}", lit(k), json_lit(v))).collect::<Vec<_>>().join(", ")
        ),
    }
}

struct Names<'a> {
    /// def name -> record type name
    records: BTreeMap<&'a str, (String, bool)>,
}

impl<'a> Names<'a> {
    fn new(r: &'a Resource) -> Self {
        let records = r.types.iter().map(|t| (t.def_name.as_str(), (pascal(&t.ctor), t.is_tag))).collect();
        Names { records }
    }
}

/// Type annotation for a shape. Intrinsics are accepted wherever a value is.
fn ann(names: &Names, s: &Shape) -> String {
    fn base(names: &Names, s: &Shape) -> String {
        match &s.kind {
            Kind::Str => "str".into(),
            Kind::Int => "int".into(),
            Kind::Num => "int | float".into(),
            Kind::Bool => "bool".into(),
            Kind::Json => "typing.Any".into(),
            Kind::List(e) => format!("list[{}]", ann(names, e)),
            Kind::Map(v) => format!("dict[str, {}]", ann(names, v)),
            Kind::Ref(def) => match names.records.get(def.as_str()) {
                Some((rec, true)) => format!("{rec} | Tag"),
                Some((rec, false)) => rec.clone(),
                None => "typing.Any".into(),
            },
            Kind::Union(ms) => ms.iter().map(|m| base(names, m)).collect::<Vec<_>>().join(" | "),
        }
    }
    let b = base(names, s);
    if b.contains("typing.Any") {
        "typing.Any".into()
    } else {
        format!("{b} | Intrinsic")
    }
}

/// Human-readable type for docstrings.
fn describe(names: &Names, s: &Shape) -> String {
    match &s.kind {
        Kind::Str => "string".into(),
        Kind::Int => "integer".into(),
        Kind::Num => "number".into(),
        Kind::Bool => "boolean".into(),
        Kind::Json => "JSON".into(),
        Kind::List(e) => format!("list of {}", describe(names, e)),
        Kind::Map(v) => format!("dict of {}", describe(names, v)),
        Kind::Ref(def) => names.records.get(def.as_str()).map(|(r, _)| r.clone()).unwrap_or_else(|| "JSON".into()),
        Kind::Union(ms) => ms.iter().map(|m| describe(names, m)).collect::<Vec<_>>().join(" or "),
    }
}

/// Runtime constraint table for a shape, or None if nothing to check.
fn constraints(s: &Shape) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();
    let c: &Constraints = &s.c;
    if !c.enum_values.is_empty() {
        parts.push(format!("\"enum\": {}", json_lit(&Value::Array(c.enum_values.clone()))));
    }
    if let Some(p) = &c.pattern {
        parts.push(format!("\"pattern\": {}", lit(p)));
    }
    for (k, v) in [
        ("min_length", c.min_length),
        ("max_length", c.max_length),
        ("minimum", c.minimum),
        ("maximum", c.maximum),
        ("min_items", c.min_items),
        ("max_items", c.max_items),
    ] {
        if let Some(v) = v {
            parts.push(format!("\"{k}\": {}", num(v)));
        }
    }
    match &s.kind {
        Kind::List(e) => {
            if let Some(ec) = constraints(e) {
                parts.push(format!("\"items\": {ec}"));
            }
        }
        Kind::Map(v) => {
            if let Some(vc) = constraints(v) {
                parts.push(format!("\"values\": {vc}"));
            }
        }
        _ => {}
    }
    if parts.is_empty() {
        None
    } else {
        Some(format!("{{{}}}", parts.join(", ")))
    }
}

fn docstring(out: &mut String, indent: &str, header: &str, doc: &str, args: &[(String, String)], extra: &str) {
    let mut text = header.to_owned();
    if !doc.is_empty() {
        text.push_str("\n\n");
        text.push_str(doc);
    }
    if !args.is_empty() {
        text.push_str("\n\nArgs:");
        for (name, d) in args {
            write!(text, "\n  {name}: {d}").unwrap();
        }
    }
    text.push_str(extra);
    let escaped = text.replace('\\', "\\\\").replace("\"\"\"", "\\\"\\\"\\\"");
    let body = escaped.lines().map(|l| if l.is_empty() { String::new() } else { format!("{indent}{l}") }).collect::<Vec<_>>().join("\n");
    writeln!(out, "{indent}\"\"\"{}\n{indent}\"\"\"", body.trim_start()).unwrap();
}

fn prop_doc(names: &Names, p: &Prop) -> String {
    let mut d = format!("{} ({}{})", p.cfn_name, describe(names, &p.shape), if p.required { ", required" } else { "" });
    let enums: Vec<String> = p.shape.c.enum_values.iter().map(|v| v.to_string()).collect();
    if !enums.is_empty() {
        write!(d, ". One of: {}", enums.join(", ")).unwrap();
    }
    if !p.doc.is_empty() {
        write!(d, ". {}", p.doc).unwrap();
    }
    d
}

fn signature(out: &mut String, leading: &[&str], names: &Names, props: &[Prop], trailing: &[String]) {
    let mut params: Vec<String> = leading.iter().map(|s| s.to_string()).collect();
    params.push("*".into());
    for p in props.iter().filter(|p| p.required) {
        params.push(format!("{}: {}", p.param, ann(names, &p.shape)));
    }
    for p in props.iter().filter(|p| !p.required) {
        let a = ann(names, &p.shape);
        let a = if a == "typing.Any" { a } else { format!("{a} | None") };
        params.push(format!("{}: {} = None", p.param, a));
    }
    params.extend(trailing.iter().cloned());
    for p in params {
        writeln!(out, "        {p},").unwrap();
    }
}

fn type_table(out: &mut String, var: &str, cfn_name: &str, display: &str, props: &[Prop], attrs: Option<&BTreeMap<String, String>>) {
    writeln!(out, "{var} = _rt.type_info(").unwrap();
    writeln!(out, "    {},", lit(cfn_name)).unwrap();
    writeln!(out, "    {},", lit(display)).unwrap();
    writeln!(out, "    {{").unwrap();
    for p in props {
        let c = constraints(&p.shape).unwrap_or_else(|| "None".into());
        writeln!(out, "        {}: ({}, {}),", lit(&p.param), lit(&p.cfn_name), c).unwrap();
    }
    writeln!(out, "    }},").unwrap();
    if let Some(attrs) = attrs {
        writeln!(out, "    attrs = {{{}}},", attrs.iter().map(|(k, v)| format!("{}: {}", lit(k), lit(v))).collect::<Vec<_>>().join(", ")).unwrap();
    }
    writeln!(out, ")").unwrap();
}

fn kwargs_dict(props: &[Prop]) -> String {
    format!("{{{}}}", props.iter().map(|p| format!("{}: {}", lit(&p.param), p.param)).collect::<Vec<_>>().join(", "))
}

fn record_fields(fields: impl IntoIterator<Item = String>) -> String {
    let fields: Vec<String> = fields.into_iter().collect();
    if fields.is_empty() {
        return "record()".into();
    }
    format!("record(\n{}\n)", fields.iter().map(|f| format!("    {f},")).collect::<Vec<_>>().join("\n"))
}

fn emit_type(out: &mut String, names: &Names, t: &PropType) {
    let rec = pascal(&t.ctor);
    let var = format!("_T_{rec}");
    type_table(out, &var, &t.cfn_name, &t.ctor, &t.props, None);
    writeln!(out).unwrap();
    writeln!(out, "def {}(", t.ctor).unwrap();
    signature(out, &[], names, &t.props, &[]);
    writeln!(out, "        ) -> {rec}:").unwrap();
    let args: Vec<(String, String)> = t.props.iter().map(|p| (p.param.clone(), prop_doc(names, p))).collect();
    docstring(out, "    ", &t.cfn_name, &t.doc, &args, "");
    writeln!(out, "    return {rec}(_cfn = _rt.value({var}, {}), {})", kwargs_dict(&t.props), t.props.iter().map(|p| format!("{0} = {0}", p.param)).collect::<Vec<_>>().join(", ")).unwrap();
    writeln!(out).unwrap();
}

/// Emits the `.star` source for one resource type.
pub fn emit(r: &Resource) -> String {
    let names = Names::new(r);
    let rec = pascal(&r.file_stem);
    let attrs_rec = format!("{rec}Attrs");
    let mut out = String::new();
    let header = format!("{}\n\n{}\n\nGenerated from the CloudFormation registry schema. DO NOT EDIT.", r.type_name, r.doc);
    docstring(&mut out, "", &header, "", &[], "");
    writeln!(out).unwrap();
    writeln!(out, "load(\"@rules_cfn//cfn:runtime.star\", \"Condition\", \"Intrinsic\", \"Tag\", _rt = \"rt\")").unwrap();
    writeln!(out).unwrap();

    // Records first: every annotation below may refer to any of them. Field types
    // are left open (the constructors' annotations do the checking), which keeps
    // recursive definitions expressible.
    for t in &r.types {
        writeln!(out, "{} = {}", pascal(&t.ctor), record_fields(t.props.iter().map(|p| format!("{} = field(typing.Any, None)", p.param)).chain(["_cfn = typing.Any".to_owned()]))).unwrap();
        writeln!(out).unwrap();
    }
    writeln!(out, "{attrs_rec} = {}", record_fields(r.attrs.keys().map(|k| format!("{k} = Intrinsic")))).unwrap();
    writeln!(out).unwrap();
    writeln!(
        out,
        "{rec} = {}",
        record_fields(
            ["logical_id = str".to_owned(), "type = str".to_owned(), "ref = Intrinsic".to_owned(), format!("attr = {attrs_rec}")]
                .into_iter()
                .chain(r.props.iter().map(|p| format!("{} = field(typing.Any, None)", p.param)))
                .chain(["_cfn = typing.Any".to_owned()])
        )
    )
    .unwrap();
    writeln!(out).unwrap();

    for t in &r.types {
        emit_type(&mut out, &names, t);
    }

    let var = format!("_T_{rec}");
    type_table(&mut out, &var, &r.type_name, &r.ctor, &r.props, Some(&r.attrs));
    writeln!(out).unwrap();
    writeln!(out, "def {}(", r.ctor).unwrap();
    let trailing: Vec<String> = vec![
        "depends_on: list[typing.Any] | None = None".into(),
        "condition: str | Condition | None = None".into(),
        "deletion_policy: str | None = None".into(),
        "update_replace_policy: str | None = None".into(),
        "creation_policy: typing.Any = None".into(),
        "update_policy: typing.Any = None".into(),
        "metadata: typing.Any = None".into(),
    ];
    signature(&mut out, &["logical_id: str"], &names, &r.props, &trailing);
    writeln!(out, "        ) -> {rec}:").unwrap();
    let mut args: Vec<(String, String)> = vec![("logical_id".into(), "Logical ID of the resource in the template.".into())];
    args.extend(r.props.iter().map(|p| (p.param.clone(), prop_doc(&names, p))));
    args.push(("depends_on".into(), "Resources this one must be created after (DependsOn).".into()));
    args.push(("condition".into(), "Only create the resource when this condition is true.".into()));
    args.push(("deletion_policy".into(), "DeletionPolicy: Delete, Retain, RetainExceptOnCreate or Snapshot.".into()));
    args.push(("update_replace_policy".into(), "UpdateReplacePolicy: Delete, Retain or Snapshot.".into()));
    args.push(("creation_policy".into(), "CreationPolicy attribute (JSON).".into()));
    args.push(("update_policy".into(), "UpdatePolicy attribute (JSON).".into()));
    args.push(("metadata".into(), "Metadata attribute (JSON).".into()));
    let extra = if r.attrs.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nAttributes (via .attr):\n{}",
            r.attrs.iter().map(|(k, v)| format!("  {k}: Fn::GetAtt {v}")).collect::<Vec<_>>().join("\n")
        )
    };
    docstring(&mut out, "    ", &r.type_name, &r.doc, &args, &extra);
    writeln!(
        out,
        "    return _rt.resource({rec}, {attrs_rec}, {var}, logical_id, {}, {})",
        kwargs_dict(&r.props),
        RESOURCE_KWARGS.join(", ")
    )
    .unwrap();
    out
}
