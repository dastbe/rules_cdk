//! Normalizes CloudFormation registry schemas (JSON Schema dialect) into an IR
//! that codegen turns into typed Starlark.

use std::collections::{BTreeMap, HashMap, VecDeque};

use serde_json::{Map, Value};

use crate::naming::{identifier, param_name, snake};

/// Validation constraints that type annotations can't express.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Constraints {
    pub enum_values: Vec<Value>,
    pub pattern: Option<String>,
    pub min_length: Option<f64>,
    pub max_length: Option<f64>,
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub min_items: Option<f64>,
    pub max_items: Option<f64>,
}

impl Constraints {
    fn from_node(n: &Map<String, Value>) -> Self {
        let f = |k: &str| n.get(k).and_then(Value::as_f64);
        Constraints {
            enum_values: n.get("enum").and_then(Value::as_array).cloned().unwrap_or_default(),
            pattern: n.get("pattern").and_then(Value::as_str).filter(|p| !p.is_empty()).map(str::to_owned),
            min_length: f("minLength"),
            max_length: f("maxLength"),
            minimum: f("minimum"),
            maximum: f("maximum"),
            min_items: f("minItems"),
            max_items: f("maxItems"),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Str,
    Int,
    Num,
    Bool,
    Json,
    List(Box<Shape>),
    Map(Box<Shape>),
    /// A named object definition of the same resource, by definition name.
    Ref(String),
    Union(Vec<Shape>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Shape {
    pub kind: Kind,
    pub c: Constraints,
}

impl Shape {
    fn new(kind: Kind) -> Self {
        Shape { kind, c: Constraints::default() }
    }
    fn json() -> Self {
        Shape::new(Kind::Json)
    }
}

#[derive(Debug, Clone)]
pub struct Prop {
    pub cfn_name: String,
    pub param: String,
    pub shape: Shape,
    pub required: bool,
    pub doc: String,
}

/// A property type (object definition) of a resource.
#[derive(Debug, Clone)]
pub struct PropType {
    /// e.g. "AWS::S3::Bucket.VersioningConfiguration"
    pub cfn_name: String,
    /// Definition name within the resource, e.g. "VersioningConfiguration".
    pub def_name: String,
    /// Constructor, e.g. "bucket_versioning_configuration".
    pub ctor: String,
    pub props: Vec<Prop>,
    pub doc: String,
    /// {Key, Value} shaped; also accepts the shared Tag.
    pub is_tag: bool,
}

#[derive(Debug, Clone)]
pub struct Resource {
    /// e.g. "AWS::S3::Bucket"
    pub type_name: String,
    /// Lower-cased namespace and service, e.g. "aws", "s3".
    pub namespace: String,
    pub service: String,
    /// Constructor and file stem, e.g. "bucket".
    pub ctor: String,
    pub file_stem: String,
    pub props: Vec<Prop>,
    /// Attribute field name -> GetAtt attribute name (e.g. "endpoint_address" -> "Endpoint.Address").
    pub attrs: BTreeMap<String, String>,
    pub doc: String,
    pub types: Vec<PropType>,
}

const PRIMS: &[(&str, fn() -> Kind)] = &[
    ("string", || Kind::Str),
    ("integer", || Kind::Int),
    ("number", || Kind::Num),
    ("boolean", || Kind::Bool),
];

fn prim(t: &str) -> Option<Kind> {
    PRIMS.iter().find(|(n, _)| *n == t).map(|(_, k)| k())
}

fn is_type_bearing(n: &Value) -> bool {
    n.as_object().is_some_and(|m| {
        ["type", "$ref", "properties", "items", "oneOf", "anyOf", "enum", "patternProperties"]
            .iter()
            .any(|k| m.contains_key(*k))
    })
}

fn is_object_with_props(n: &Map<String, Value>) -> bool {
    let has_props = n.get("properties").and_then(Value::as_object).is_some_and(|p| !p.is_empty());
    let object_typed = match n.get("type") {
        None => true,
        Some(Value::String(t)) => t == "object",
        _ => false,
    };
    has_props && object_typed
}

/// First paragraph of a description, trimmed to about `limit` characters.
pub fn first_paragraph(text: &str, limit: usize) -> String {
    let t = text.trim().split("\n\n").next().unwrap_or("").trim().replace('\n', " ");
    if t.chars().count() <= limit {
        return t;
    }
    let cut: String = t.chars().take(limit).collect();
    match cut.rfind(". ") {
        Some(i) if i > limit / 3 => cut[..=i].to_owned(),
        _ => cut.trim_end().to_owned() + "...",
    }
}

struct Ctx<'a> {
    schema: &'a Map<String, Value>,
    defs: Map<String, Value>,
    resource_snake: String,
    /// def name -> ctor
    registered: HashMap<String, String>,
    queue: VecDeque<(String, Map<String, Value>)>,
    inline: HashMap<String, Map<String, Value>>,
}

const MAX_ALIAS_DEPTH: usize = 16;

impl<'a> Ctx<'a> {
    fn register(&mut self, def_name: &str, node: &Map<String, Value>) -> Kind {
        if !self.registered.contains_key(def_name) {
            let ctor = format!("{}_{}", self.resource_snake, snake(def_name));
            self.registered.insert(def_name.to_owned(), ctor);
            self.queue.push_back((def_name.to_owned(), node.clone()));
        }
        Kind::Ref(def_name.to_owned())
    }

    fn inline_name(&mut self, hint: &str, node: &Map<String, Value>) -> String {
        for i in 0..1000 {
            let cand = if i == 0 { hint.to_owned() } else { format!("{hint}{}", i + 1) };
            match self.inline.get(&cand) {
                Some(existing) if existing == node => return cand,
                Some(_) => continue,
                None if self.defs.contains_key(&cand) => continue,
                None => {
                    self.inline.insert(cand.clone(), node.clone());
                    return cand;
                }
            }
        }
        panic!("could not name inline definition {hint}");
    }

    fn shape(&mut self, node: &Value, hint: &str, depth: usize) -> Shape {
        let Some(n) = node.as_object() else { return Shape::json() };
        if let Some(r) = n.get("$ref").and_then(Value::as_str) {
            if depth > MAX_ALIAS_DEPTH {
                return Shape::json();
            }
            if let Some(name) = r.strip_prefix("#/definitions/") {
                let Some(target) = self.defs.get(name).and_then(Value::as_object).cloned() else {
                    return Shape::json();
                };
                if is_object_with_props(&target) {
                    return Shape::new(self.register(name, &target));
                }
                return self.shape(&Value::Object(target), name, depth + 1);
            }
            if let Some(name) = r.strip_prefix("#/properties/") {
                let target = self.schema.get("properties").and_then(|p| p.get(name)).cloned();
                return match target {
                    Some(t) => self.shape(&t, hint, depth + 1),
                    None => Shape::json(),
                };
            }
            return Shape::json();
        }

        let branches: Vec<Value> = ["oneOf", "anyOf"]
            .iter()
            .filter_map(|k| n.get(*k).and_then(Value::as_array))
            .flatten()
            .filter(|b| is_type_bearing(b))
            .cloned()
            .collect();
        if !branches.is_empty() && !is_object_with_props(n) {
            let multi = branches.len() > 1;
            let mut members: Vec<Shape> = Vec::new();
            for (i, b) in branches.iter().enumerate() {
                let h = if multi { format!("{hint}{}", i + 1) } else { hint.to_owned() };
                let s = self.shape(b, &h, depth + 1);
                let flat = match s.kind {
                    Kind::Union(ms) => ms,
                    _ => vec![s],
                };
                for m in flat {
                    if !members.contains(&m) {
                        members.push(m);
                    }
                }
            }
            // Types wherever possible: an untyped branch (often a bare {"type": "object"}
            // kept for compatibility) is dropped when typed alternatives exist.
            let typed: Vec<Shape> = members.into_iter().filter(|m| m.kind != Kind::Json).collect();
            return match typed.len() {
                0 => Shape::json(),
                1 => typed.into_iter().next().unwrap(),
                _ => Shape::new(Kind::Union(typed)),
            };
        }

        let c = Constraints::from_node(n);
        let mut t = n.get("type").cloned();
        if let Some(Value::Array(ts)) = &t {
            let prims: Vec<&str> = ts.iter().filter_map(Value::as_str).filter(|x| *x != "null").collect();
            if prims.len() == 1 {
                t = Some(Value::String(prims[0].to_owned()));
            } else if prims.iter().all(|p| prim(p).is_some()) && !prims.is_empty() {
                return Shape::new(Kind::Union(prims.iter().map(|p| Shape::new(prim(p).unwrap())).collect()));
            } else {
                return Shape::json();
            }
        }
        let t = t.as_ref().and_then(Value::as_str);
        if t.is_none() && !c.enum_values.is_empty() {
            // Untyped enum: infer from the values.
            let kind = if c.enum_values.iter().all(Value::is_string) { Kind::Str } else { Kind::Json };
            return Shape { kind, c };
        }
        match t {
            Some(p) if prim(p).is_some() => Shape { kind: prim(p).unwrap(), c },
            Some("array") => {
                let item = match n.get("items") {
                    Some(items) if items.is_object() => self.shape(items, hint, depth),
                    _ => Shape::json(),
                };
                Shape { kind: Kind::List(Box::new(item)), c }
            }
            Some("object") | None => {
                if is_object_with_props(n) {
                    let name = self.inline_name(hint, n);
                    return Shape::new(self.register(&name, n));
                }
                let pp = n.get("patternProperties").and_then(Value::as_object).filter(|p| p.len() == 1);
                let ap = n.get("additionalProperties").filter(|a| is_type_bearing(a));
                let vnode = pp.and_then(|p| p.values().next().cloned()).or_else(|| ap.cloned());
                match vnode {
                    Some(v) => Shape::new(Kind::Map(Box::new(self.shape(&v, hint, depth)))),
                    None => Shape::json(),
                }
            }
            _ => Shape::json(),
        }
    }

    fn props(&mut self, node: &Map<String, Value>, owner_hint: &str, exclude: &[String]) -> Vec<Prop> {
        let empty = Map::new();
        let node_props = node.get("properties").and_then(Value::as_object).unwrap_or(&empty);
        let required: Vec<&str> = node.get("required").and_then(Value::as_array).map(|r| r.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
        let mut names: Vec<&String> = node_props.keys().collect();
        names.sort();
        let mut out: Vec<Prop> = Vec::new();
        for cfn_name in names {
            if exclude.contains(cfn_name) {
                continue;
            }
            let mut param = param_name(cfn_name);
            if out.iter().any(|p| p.param == param) {
                // Two properties differing only by case/punctuation; keep both distinct.
                let n = out.iter().filter(|p| p.param.starts_with(&param)).count() + 1;
                param = format!("{param}_{n}");
            }
            let pnode = &node_props[cfn_name];
            let shape = self.shape(pnode, &format!("{owner_hint}{cfn_name}"), 0);
            let doc = pnode.get("description").and_then(Value::as_str).map(|d| first_paragraph(d, 240)).unwrap_or_default();
            out.push(Prop { cfn_name: cfn_name.clone(), param, shape, required: required.contains(&cfn_name.as_str()), doc });
        }
        out
    }
}

/// Normalizes one registry schema; returns None for type names that aren't `A::B::C`.
pub fn normalize(schema: &Value) -> Option<Resource> {
    let schema = schema.as_object()?;
    let type_name = schema.get("typeName")?.as_str()?.to_owned();
    let parts: Vec<&str> = type_name.split("::").collect();
    if parts.len() != 3 {
        return None;
    }
    let short = parts[2];
    let mut ctx = Ctx {
        schema,
        defs: schema.get("definitions").and_then(Value::as_object).cloned().unwrap_or_default(),
        resource_snake: snake(short),
        registered: HashMap::new(),
        queue: VecDeque::new(),
        inline: HashMap::new(),
    };

    let mut read_only = Vec::new();
    let mut attrs = BTreeMap::new();
    for p in schema.get("readOnlyProperties").and_then(Value::as_array).into_iter().flatten() {
        let Some(path) = p.as_str().and_then(|p| p.strip_prefix("/properties/")) else { continue };
        let segs: Vec<&str> = path.split('/').collect();
        if segs.contains(&"*") {
            continue;
        }
        if segs.len() == 1 {
            read_only.push(segs[0].to_owned());
        }
        attrs.insert(segs.iter().map(|s| snake(s)).collect::<Vec<_>>().join("_"), segs.join("."));
    }

    let props = ctx.props(schema, "", &read_only);
    let mut types = Vec::new();
    while let Some((def_name, node)) = ctx.queue.pop_front() {
        let tprops = ctx.props(&node, &def_name, &[]);
        let mut keys: Vec<&str> = tprops.iter().map(|p| p.cfn_name.as_str()).collect();
        keys.sort();
        let is_tag = keys == ["Key", "Value"];
        types.push(PropType {
            cfn_name: format!("{type_name}.{def_name}"),
            ctor: ctx.registered[&def_name].clone(),
            def_name: def_name.clone(),
            props: tprops,
            doc: node.get("description").and_then(Value::as_str).map(|d| first_paragraph(d, 400)).unwrap_or_default(),
            is_tag,
        });
    }

    Some(Resource {
        namespace: parts[0].to_ascii_lowercase(),
        service: parts[1].to_ascii_lowercase(),
        ctor: identifier(short),
        file_stem: snake(short),
        type_name: type_name.clone(),
        props,
        attrs,
        doc: schema.get("description").and_then(Value::as_str).map(|d| first_paragraph(d, 600)).unwrap_or_default(),
        types,
    })
}
