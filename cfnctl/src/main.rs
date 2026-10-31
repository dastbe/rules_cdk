//! cfnctl: evaluate, package and deploy CloudFormation written in typed Starlark.
//!
//!   cfnctl gen      registry schemas -> typed .star bindings (one file per resource type)
//!   cfnctl check    typecheck + evaluate .star files
//!   cfnctl eval     run a stack's entry function -> raw template JSON
//!   cfnctl package  raw template -> final template + manifest + packaged assets
//!   cfnctl build    eval + package in one step (what the cfn_stack rule runs)
//!   cfnctl lsp      language server (stdio) for editors

mod eval;
mod gen;
mod lsp;
mod naming;
mod package;
mod schema;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand};

#[derive(Parser)]
#[command(name = "cfnctl", about = "CloudFormation in typed Starlark")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Args, Clone)]
struct RepoArgs {
    /// Main repository directory (the repo `//` labels refer to).
    #[arg(long, default_value = ".")]
    root: PathBuf,
    /// Additional repositories as name=dir, e.g. --repo cfn=bazel-bin/external/cfn+/bindings.
    #[arg(long = "repo", value_parser = parse_repo)]
    repos: Vec<(String, PathBuf)>,
}

fn parse_repo(s: &str) -> Result<(String, PathBuf), String> {
    let (n, d) = s.split_once('=').ok_or("expected name=dir")?;
    Ok((n.to_owned(), PathBuf::from(d)))
}

impl RepoArgs {
    fn repos(&self) -> eval::Repos {
        let mut r = eval::Repos::default();
        r.dirs.insert(String::new(), self.root.clone());
        for (n, d) in &self.repos {
            r.dirs.insert(n.clone(), d.clone());
        }
        r
    }
}

#[derive(Subcommand)]
enum Cmd {
    /// Generate bindings from registry schema JSON files (or directories of them).
    Gen {
        /// Output directory.
        #[arg(long)]
        out: PathBuf,
        /// Repository name the bindings are loaded from (for index.json).
        #[arg(long, default_value = "cfn")]
        repo_name: String,
        /// Type-name globs to include (default: all).
        #[arg(long)]
        include: Vec<String>,
        /// Type-name globs to exclude.
        #[arg(long)]
        exclude: Vec<String>,
        /// Schema files or directories, layered in order; later layers may not redefine types.
        schemas: Vec<PathBuf>,
    },
    /// Typecheck and evaluate .star files.
    Check {
        #[command(flatten)]
        repos: RepoArgs,
        files: Vec<PathBuf>,
    },
    /// Evaluate a stack file's entry function and write the raw template.
    Eval {
        #[command(flatten)]
        repos: RepoArgs,
        /// Function that returns the template.
        #[arg(long, default_value = "main")]
        entry: String,
        /// Where to write the raw template JSON (default: stdout).
        #[arg(long)]
        out: Option<PathBuf>,
        file: PathBuf,
    },
    /// Package a raw template.
    Package {
        #[arg(long)]
        raw: PathBuf,
        #[command(flatten)]
        outs: PackageArgs,
    },
    /// Run the language server on stdio.
    Lsp {
        #[command(flatten)]
        repos: RepoArgs,
    },
    /// Evaluate and package a stack.
    Build {
        #[command(flatten)]
        repos: RepoArgs,
        #[arg(long, default_value = "main")]
        entry: String,
        #[command(flatten)]
        outs: PackageArgs,
        file: PathBuf,
    },
}

#[derive(Args)]
struct PackageArgs {
    /// Stack config JSON written by the cfn_stack rule (default: stack named after the file).
    #[arg(long)]
    config: Option<PathBuf>,
    /// File listing asset inputs as label<TAB>packaging<TAB>relpath<TAB>path, one per line.
    #[arg(long)]
    asset_list: Option<PathBuf>,
    #[arg(long)]
    out_template: PathBuf,
    #[arg(long)]
    out_manifest: PathBuf,
    #[arg(long)]
    out_assets: PathBuf,
}

impl PackageArgs {
    fn run(&self, raw: &[u8]) -> Result<()> {
        let config = match &self.config {
            Some(c) => serde_json::from_slice(&std::fs::read(c)?).with_context(|| format!("parsing {}", c.display()))?,
            None => package::Config {
                stack_name: self.out_manifest.file_name().unwrap().to_string_lossy().trim_end_matches(".manifest.json").to_owned(),
                ..Default::default()
            },
        };
        let mut files = Vec::new();
        if let Some(l) = &self.asset_list {
            for line in std::fs::read_to_string(l)?.lines().filter(|l| !l.is_empty()) {
                files.push(package::parse_asset_line(line)?);
            }
        }
        package::package(raw, config, &files, package::Outputs { template: &self.out_template, manifest: &self.out_manifest, assets_dir: &self.out_assets })?;
        Ok(())
    }
}

fn glob_match(pattern: &str, s: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == s;
    }
    let Some(mut rest) = s.strip_prefix(parts[0]) else { return false };
    for mid in &parts[1..parts.len() - 1] {
        match rest.find(mid) {
            Some(i) => rest = &rest[i + mid.len()..],
            None => return false,
        }
    }
    rest.ends_with(parts[parts.len() - 1])
}

fn json_files(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    if root.is_file() {
        out.push(root.to_owned());
        return Ok(());
    }
    let mut entries: Vec<_> = std::fs::read_dir(root).with_context(|| format!("reading {}", root.display()))?.collect::<std::io::Result<_>>()?;
    entries.sort_by_key(|e| e.path());
    for e in entries {
        let p = e.path();
        if p.is_dir() {
            json_files(&p, out)?;
        } else if p.extension().is_some_and(|x| x == "json") {
            out.push(p);
        }
    }
    Ok(())
}

fn run_gen(out: &Path, repo_name: &str, include: &[String], exclude: &[String], layers: &[PathBuf]) -> Result<()> {
    let mut by_type: BTreeMap<String, serde_json::Value> = BTreeMap::new();
    for layer in layers {
        let mut files = Vec::new();
        json_files(layer, &mut files)?;
        let mut seen_here = std::collections::HashSet::new();
        for f in files {
            let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&f)?).with_context(|| format!("parsing {}", f.display()))?;
            let Some(tn) = v.get("typeName").and_then(|t| t.as_str()).map(str::to_owned) else { continue };
            if tn.split("::").count() != 3 {
                continue;
            }
            if !include.is_empty() && !include.iter().any(|p| glob_match(p, &tn)) {
                continue;
            }
            if exclude.iter().any(|p| glob_match(p, &tn)) {
                continue;
            }
            if by_type.contains_key(&tn) && !seen_here.contains(&tn) {
                bail!("{tn} is defined by more than one schema layer ({})", layer.display());
            }
            seen_here.insert(tn.clone());
            by_type.insert(tn, v);
        }
    }
    if out.exists() {
        std::fs::remove_dir_all(out)?;
    }
    // Constructors may not shadow globals the generated code (or users) rely on,
    // e.g. AWS::Cases::Field -> field_, AWS::FraudDetector::List -> list_.
    let mut taken: std::collections::HashSet<String> = eval::globals().names().map(|n| n.as_str().to_owned()).collect();
    taken.extend(["Condition", "Intrinsic", "Tag", "_rt"].map(str::to_owned));
    let mut index = BTreeMap::new();
    for schema in by_type.values() {
        let Some(mut r) = schema::normalize(schema) else { continue };
        if taken.contains(&r.ctor) {
            r.ctor.push('_');
        }
        let path = out.join(gen::rel_path(&r));
        std::fs::create_dir_all(path.parent().unwrap())?;
        std::fs::write(&path, gen::emit(&r))?;
        index.insert(r.type_name.clone(), serde_json::json!({
            "load": gen::load_label(repo_name, &r),
            "constructor": r.ctor,
            "types": r.types.iter().map(|t| (t.cfn_name.clone(), t.ctor.clone())).collect::<BTreeMap<_, _>>(),
        }));
    }
    std::fs::write(out.join("index.json"), serde_json::to_string_pretty(&index)? + "\n")?;
    eprintln!("cfnctl gen: {} resource types -> {}", index.len(), out.display());
    Ok(())
}

fn write_json(v: &serde_json::Value, out: Option<&Path>) -> Result<()> {
    let s = serde_json::to_string_pretty(v)? + "\n";
    match out {
        Some(p) => std::fs::write(p, s)?,
        None => print!("{s}"),
    }
    Ok(())
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Gen { out, repo_name, include, exclude, schemas } => run_gen(&out, &repo_name, &include, &exclude, &schemas),
        Cmd::Check { repos, files } => eval::check(repos.repos(), &files),
        Cmd::Eval { repos, entry, out, file } => {
            let t = eval::eval_template(repos.repos(), &file, &entry)?;
            write_json(&t, out.as_deref())
        }
        Cmd::Lsp { repos } => lsp::serve(repos.repos()),
        Cmd::Package { raw, outs } => outs.run(&std::fs::read(&raw)?),
        Cmd::Build { repos, entry, outs, file } => {
            let t = eval::eval_template(repos.repos(), &file, &entry)?;
            outs.run(&serde_json::to_vec(&t)?)
        }
    }
}
