//! Semantic diff between two CloudFormation templates, keyed by section and
//! logical ID rather than by line.

use std::collections::BTreeSet;
use std::fmt::Write;

use serde_json::{Map, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Added,
    Removed,
    Modified,
}

impl Kind {
    fn sign(self) -> char {
        match self {
            Kind::Added => '+',
            Kind::Removed => '-',
            Kind::Modified => '~',
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PathChange {
    pub path: String,
    pub old: Option<Value>,
    pub new: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    /// "Resources", "Outputs", ... or "" for other top-level keys.
    pub section: String,
    pub id: String,
    pub kind: Kind,
    pub resource_type: String,
    pub paths: Vec<PathChange>,
}

const SECTIONS: &[&str] = &["Parameters", "Mappings", "Conditions", "Resources", "Outputs"];

fn keys<'a>(a: Option<&'a Map<String, Value>>, b: Option<&'a Map<String, Value>>) -> BTreeSet<&'a String> {
    a.into_iter().chain(b).flat_map(|m| m.keys()).collect()
}

/// Numbers from different producers (1 vs 1.0) compare equal.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same(a, b)),
        (Value::Object(x), Value::Object(y)) => x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w))),
        _ => a == b,
    }
}

fn is_intrinsic(m: &Map<String, Value>) -> bool {
    m.len() == 1 && m.keys().all(|k| k == "Ref" || k.starts_with("Fn::"))
}

fn leaf_diff(path: &str, old: Option<&Value>, new: Option<&Value>, out: &mut Vec<PathChange>) {
    match (old, new) {
        (Some(Value::Object(o)), Some(Value::Object(n))) if !is_intrinsic(o) && !is_intrinsic(n) => {
            for k in keys(Some(o), Some(n)) {
                leaf_diff(&format!("{path}.{k}"), o.get(k), n.get(k), out);
            }
        }
        (Some(Value::Array(o)), Some(Value::Array(n))) if o.len() == n.len() => {
            for (i, (a, b)) in o.iter().zip(n).enumerate() {
                leaf_diff(&format!("{path}[{i}]"), Some(a), Some(b), out);
            }
        }
        (a, b) => {
            let equal = match (a, b) {
                (Some(a), Some(b)) => same(a, b),
                (None, None) => true,
                _ => false,
            };
            if !equal {
                out.push(PathChange { path: path.trim_start_matches('.').to_owned(), old: a.cloned(), new: b.cloned() });
            }
        }
    }
}

/// Compares the deployed (`old`) and local (`new`) templates.
pub fn diff(old: &Value, new: &Value) -> Vec<Change> {
    let mut out = Vec::new();
    for s in SECTIONS {
        let o = old.get(*s).and_then(Value::as_object);
        let n = new.get(*s).and_then(Value::as_object);
        for id in keys(o, n) {
            let ov = o.and_then(|m| m.get(id));
            let nv = n.and_then(|m| m.get(id));
            let resource_type = nv.or(ov).and_then(|v| v.get("Type")).and_then(Value::as_str).unwrap_or_default().to_owned();
            let (kind, paths) = match (ov, nv) {
                (None, Some(_)) => (Kind::Added, vec![]),
                (Some(_), None) => (Kind::Removed, vec![]),
                (Some(a), Some(b)) if !same(a, b) => {
                    let mut p = Vec::new();
                    leaf_diff("", Some(a), Some(b), &mut p);
                    (Kind::Modified, p)
                }
                _ => continue,
            };
            out.push(Change { section: s.to_string(), id: id.clone(), kind, resource_type, paths });
        }
    }
    let (o, n) = (old.as_object(), new.as_object());
    for k in keys(o, n) {
        if SECTIONS.contains(&k.as_str()) {
            continue;
        }
        let (a, b) = (o.and_then(|m| m.get(k)), n.and_then(|m| m.get(k)));
        let kind = match (a, b) {
            (None, Some(_)) => Kind::Added,
            (Some(_), None) => Kind::Removed,
            (Some(x), Some(y)) if !same(x, y) => Kind::Modified,
            _ => continue,
        };
        out.push(Change { section: String::new(), id: k.clone(), kind, resource_type: String::new(), paths: vec![PathChange { path: String::new(), old: a.cloned(), new: b.cloned() }] });
    }
    out
}

fn compact(v: &Option<Value>) -> String {
    match v {
        None => "(absent)".into(),
        Some(v) => {
            let s = v.to_string();
            if s.chars().count() > 160 {
                s.chars().take(157).collect::<String>() + "..."
            } else {
                s
            }
        }
    }
}

/// Human-readable rendering.
pub fn render(changes: &[Change]) -> String {
    if changes.is_empty() {
        return "No template differences.\n".into();
    }
    let mut out = String::new();
    let mut section: Option<&str> = None;
    for c in changes {
        if section != Some(c.section.as_str()) {
            section = Some(&c.section);
            writeln!(out, "{}", if c.section.is_empty() { "Template" } else { &c.section }).unwrap();
        }
        let label = if c.resource_type.is_empty() { c.id.clone() } else { format!("{} ({})", c.id, c.resource_type) };
        writeln!(out, "  [{}] {label}", c.kind.sign()).unwrap();
        for p in c.paths.iter().filter(|p| !p.path.is_empty()) {
            writeln!(out, "      {}: {} -> {}", p.path, compact(&p.old), compact(&p.new)).unwrap();
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn diffs_resources() {
        let old = json!({"Resources": {"A": {"Type": "T"}, "B": {"Type": "T", "Properties": {"X": 1, "Y": [1, 2]}}}});
        let new = json!({"Resources": {"B": {"Type": "T", "Properties": {"X": 1.0, "Y": [1, 3]}}, "C": {"Type": "U"}}, "Description": "d"});
        let r = render(&diff(&old, &new));
        assert!(r.contains("[-] A (T)"), "{r}");
        assert!(r.contains("[~] B (T)\n      Properties.Y[1]: 2 -> 3"), "{r}");
        assert!(r.contains("[+] C (U)"), "{r}");
        assert!(r.contains("Template\n  [+] Description"), "{r}");
        assert!(diff(&new, &new).is_empty());
    }
}
