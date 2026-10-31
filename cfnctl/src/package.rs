//! Turns the raw template from `cfnctl eval` into the deployable template:
//! asset placeholders become content-addressed S3 locations, capabilities are
//! inferred, and a manifest describing the stack is written.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Bucket created by the bootstrap stack. ${AWS::AccountId}/${AWS::Region} resolve at deploy time.
pub const DEFAULT_ASSET_BUCKET: &str = "rules-cfn-assets-${AWS::AccountId}-${AWS::Region}";

/// CloudFormation's limit for templates uploaded via S3.
pub const MAX_TEMPLATE_SIZE: usize = 1 << 20;

/// Stack configuration written by the cfn_stack rule.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Config {
    pub stack_name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub region: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub account: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub parameters: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub tags: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub termination_protection: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub asset_bucket: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub role_arn: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub depends_on: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Asset {
    pub label: String,
    pub packaging: String,
    pub sha256: String,
    /// Object key in the asset bucket (content addressed).
    pub key: String,
    /// The packaged file, relative to the manifest's directory.
    pub file: String,
}

/// Everything the run-time commands need to act on a stack.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(flatten)]
    pub config: Config,
    /// Template file, relative to the manifest's directory.
    pub template: String,
    pub template_sha256: String,
    pub template_size: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assets: Vec<Asset>,
}

/// One input file of an asset.
#[derive(Debug, Clone)]
pub struct AssetFile {
    pub label: String,
    pub packaging: String,
    /// Path inside a zip asset (relative to the label's package).
    pub rel: String,
    pub path: PathBuf,
}

/// Parses an asset list line: label<TAB>packaging<TAB>relpath<TAB>path.
pub fn parse_asset_line(l: &str) -> Result<AssetFile> {
    let p: Vec<&str> = l.split('\t').collect();
    if p.len() != 4 {
        bail!("bad asset line {l:?}");
    }
    Ok(AssetFile { label: p[0].into(), packaging: p[1].into(), rel: p[2].into(), path: p[3].into() })
}

/// A canonical zip: entries sorted, stored (no compression), fixed timestamps
/// and permissions, no extra fields. Byte-for-byte reproducible from the inputs,
/// independent of any compression library.
pub fn canonical_zip(files: &BTreeMap<String, PathBuf>) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    // 1980-01-01 00:00:00 in MS-DOS format.
    let (dos_time, dos_date) = (0u16, (0 << 9) | (1 << 5) | 1u16);
    for (name, path) in files {
        let data = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
        let exec = is_executable(path);
        let crc = crc32fast::hash(&data);
        let offset = out.len() as u32;
        let n = name.as_bytes();
        // Local file header.
        out.extend_from_slice(&0x04034b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0x0800u16.to_le_bytes()); // flags: UTF-8 names
        out.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        out.extend_from_slice(&dos_time.to_le_bytes());
        out.extend_from_slice(&dos_date.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(n.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra length
        out.extend_from_slice(n);
        out.extend_from_slice(&data);
        // Central directory entry.
        let mode: u32 = if exec { 0o100755 } else { 0o100644 };
        central.extend_from_slice(&0x02014b50u32.to_le_bytes());
        central.extend_from_slice(&((3u16 << 8) | 20).to_le_bytes()); // made by: Unix, 2.0
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&0x0800u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&dos_time.to_le_bytes());
        central.extend_from_slice(&dos_date.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(data.len() as u32).to_le_bytes());
        central.extend_from_slice(&(n.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra
        central.extend_from_slice(&0u16.to_le_bytes()); // comment
        central.extend_from_slice(&0u16.to_le_bytes()); // disk
        central.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        central.extend_from_slice(&(mode << 16).to_le_bytes()); // external attrs
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(n);
    }
    let cd_offset = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x06054b50u32.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(files.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&cd_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    Ok(out)
}

#[cfg(unix)]
fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(_: &Path) -> bool {
    false
}

struct Packed {
    asset: Asset,
    data: Vec<u8>,
}

fn pack_assets(files: &[AssetFile]) -> Result<BTreeMap<String, Packed>> {
    let mut by_label: BTreeMap<&str, Vec<&AssetFile>> = BTreeMap::new();
    for f in files {
        by_label.entry(&f.label).or_default().push(f);
    }
    let mut out = BTreeMap::new();
    for (label, fs) in by_label {
        let packaging = fs[0].packaging.as_str();
        let (data, ext) = match packaging {
            "zip" => (canonical_zip(&fs.iter().map(|f| (f.rel.clone(), f.path.clone())).collect())?, ".zip".to_owned()),
            "file" => {
                if fs.len() != 1 {
                    bail!("asset {label}: packaging \"file\" needs exactly one file, got {}", fs.len());
                }
                let ext = Path::new(&fs[0].rel).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
                (std::fs::read(&fs[0].path)?, ext)
            }
            p => bail!("asset {label}: unknown packaging {p:?}"),
        };
        let sha = hex::encode(Sha256::digest(&data));
        out.insert(
            label.to_owned(),
            Packed {
                asset: Asset { label: label.to_owned(), packaging: packaging.to_owned(), key: format!("assets/{sha}{ext}"), sha256: sha, file: String::new() },
                data,
            },
        );
    }
    Ok(out)
}

fn sub(s: String) -> Value {
    if s.contains("${") {
        json!({ "Fn::Sub": s })
    } else {
        Value::String(s)
    }
}

/// Replaces {"__cfn_asset__": {"label", "part"}} placeholders in place.
fn resolve_assets(v: &mut Value, assets: &BTreeMap<String, Packed>, bucket: &str) -> Result<()> {
    if let Some(ph) = v.as_object().filter(|o| o.len() == 1).and_then(|o| o.get("__cfn_asset__")) {
        let label = ph.get("label").and_then(Value::as_str).unwrap_or_default();
        let part = ph.get("part").and_then(Value::as_str).unwrap_or_default();
        let a = assets.get(label).ok_or_else(|| anyhow!("asset {label} is used by the template but not listed in the cfn_stack's assets"))?;
        *v = match part {
            "bucket" => sub(bucket.to_owned()),
            "key" => Value::String(a.asset.key.clone()),
            "s3_uri" => sub(format!("s3://{bucket}/{}", a.asset.key)),
            p => bail!("asset placeholder for {label}: unknown part {p:?}"),
        };
        return Ok(());
    }
    match v {
        Value::Object(o) => o.values_mut().try_for_each(|e| resolve_assets(e, assets, bucket)),
        Value::Array(a) => a.iter_mut().try_for_each(|e| resolve_assets(e, assets, bucket)),
        _ => Ok(()),
    }
}

/// Capabilities CloudFormation will demand for the template.
pub fn infer_capabilities(t: &Value) -> BTreeSet<String> {
    let named: &[(&str, &str)] = &[
        ("AWS::IAM::Role", "RoleName"),
        ("AWS::IAM::User", "UserName"),
        ("AWS::IAM::Group", "GroupName"),
        ("AWS::IAM::ManagedPolicy", "ManagedPolicyName"),
        ("AWS::IAM::InstanceProfile", "InstanceProfileName"),
    ];
    let mut caps = BTreeSet::new();
    for r in t.get("Resources").and_then(Value::as_object).into_iter().flat_map(|m| m.values()) {
        let tn = r.get("Type").and_then(Value::as_str).unwrap_or_default();
        if tn.starts_with("AWS::IAM::") {
            caps.insert("CAPABILITY_IAM".to_owned());
            for (t, p) in named {
                if *t == tn && r.get("Properties").and_then(|ps| ps.get(*p)).is_some() {
                    caps.insert("CAPABILITY_NAMED_IAM".to_owned());
                }
            }
        }
        if tn == "AWS::CloudFormation::Stack" || tn == "AWS::Serverless::Application" {
            caps.insert("CAPABILITY_AUTO_EXPAND".to_owned());
        }
    }
    if t.get("Transform").is_some() {
        caps.insert("CAPABILITY_AUTO_EXPAND".to_owned());
    }
    caps
}

/// Deterministic JSON: sorted keys (serde_json's default map), two-space indent, trailing newline.
pub fn encode(v: &impl Serialize) -> Result<Vec<u8>> {
    let mut b = serde_json::to_vec_pretty(v)?;
    b.push(b'\n');
    Ok(b)
}

fn rel(from_dir: &Path, p: &Path) -> String {
    p.strip_prefix(from_dir).unwrap_or(p).to_string_lossy().replace('\\', "/")
}

pub struct Outputs<'a> {
    pub template: &'a Path,
    pub manifest: &'a Path,
    pub assets_dir: &'a Path,
}

/// Runs the packaging step.
pub fn package(raw: &[u8], config: Config, asset_files: &[AssetFile], out: Outputs) -> Result<Manifest> {
    let mut tmpl: Value = serde_json::from_slice(raw).context("parsing raw template")?;
    if !tmpl.is_object() {
        bail!("template must be a JSON object");
    }
    let assets = pack_assets(asset_files)?;
    let bucket = if config.asset_bucket.is_empty() { DEFAULT_ASSET_BUCKET.to_owned() } else { config.asset_bucket.clone() };
    resolve_assets(&mut tmpl, &assets, &bucket)?;

    let body = encode(&tmpl)?;
    if body.len() > MAX_TEMPLATE_SIZE {
        bail!("template is {} bytes; CloudFormation allows at most {MAX_TEMPLATE_SIZE}", body.len());
    }
    let mut caps = infer_capabilities(&tmpl);
    caps.extend(config.capabilities.iter().cloned());

    let manifest_dir = out.manifest.parent().unwrap_or(Path::new(""));
    std::fs::write(out.template, &body)?;
    std::fs::create_dir_all(out.assets_dir)?;
    let mut m = Manifest {
        config: Config { capabilities: caps.into_iter().collect(), ..config },
        template: rel(manifest_dir, out.template),
        template_sha256: hex::encode(Sha256::digest(&body)),
        template_size: body.len(),
        assets: Vec::new(),
    };
    if m.config.asset_bucket.is_empty() && !assets.is_empty() {
        m.config.asset_bucket = DEFAULT_ASSET_BUCKET.to_owned();
    }
    for p in assets.values() {
        let file = out.assets_dir.join(Path::new(&p.asset.key).file_name().unwrap());
        std::fs::write(&file, &p.data)?;
        m.assets.push(Asset { file: rel(manifest_dir, &file), ..p.asset.clone() });
    }
    std::fs::write(out.manifest, encode(&m)?)?;
    Ok(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cfnctl-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn zip_is_canonical_and_readable() {
        let d = tmp("zip");
        std::fs::write(d.join("a.js"), "a").unwrap();
        std::fs::write(d.join("b.js"), "bb").unwrap();
        let m: BTreeMap<String, PathBuf> = [("lib/b.js".to_owned(), d.join("b.js")), ("a.js".to_owned(), d.join("a.js"))].into();
        let z1 = canonical_zip(&m).unwrap();
        assert_eq!(z1, canonical_zip(&m).unwrap());
        // Readable by a standard unzip.
        let zp = d.join("x.zip");
        std::fs::write(&zp, &z1).unwrap();
        if let Ok(out) = std::process::Command::new("unzip").arg("-p").arg(&zp).arg("lib/b.js").output() {
            assert_eq!(out.stdout, b"bb");
        }
    }

    #[test]
    fn packages_assets_and_capabilities() {
        let d = tmp("pkg");
        std::fs::write(d.join("index.mjs"), "export const handler = async () => 1;").unwrap();
        let raw = br#"{"Resources": {
            "Role": {"Type": "AWS::IAM::Role", "Properties": {"RoleName": "r"}},
            "Fn": {"Type": "AWS::Lambda::Function", "Properties": {"Code": {
              "S3Bucket": {"__cfn_asset__": {"label": "//fn:code", "part": "bucket"}},
              "S3Key": {"__cfn_asset__": {"label": "//fn:code", "part": "key"}}}}}}}"#;
        let files = [AssetFile { label: "//fn:code".into(), packaging: "zip".into(), rel: "index.mjs".into(), path: d.join("index.mjs") }];
        let (t, mp, a) = (d.join("s.template.json"), d.join("s.manifest.json"), d.join("s.assets"));
        let m = package(raw, Config { stack_name: "s".into(), ..Default::default() }, &files, Outputs { template: &t, manifest: &mp, assets_dir: &a }).unwrap();
        assert_eq!(m.config.capabilities, ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]);
        assert_eq!(m.assets.len(), 1);
        assert!(m.assets[0].file.starts_with("s.assets/"));
        let body = std::fs::read_to_string(&t).unwrap();
        assert!(body.contains(r#""Fn::Sub": "rules-cfn-assets-${AWS::AccountId}-${AWS::Region}""#), "{body}");
        assert!(body.contains(&m.assets[0].key));
        assert!(!body.contains("__cfn_asset__"));

        let err = package(raw, Config::default(), &[], Outputs { template: &t, manifest: &mp, assets_dir: &a }).unwrap_err();
        assert!(err.to_string().contains("//fn:code"), "{err}");
    }
}
