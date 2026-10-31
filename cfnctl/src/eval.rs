//! Evaluates typed Starlark with starlark-rust.
//!
//! Files are addressed by Bazel-style labels:
//! - `@repo//pkg:file.star`  file `pkg/file.star` in repo `repo` (mapped with `--repo name=dir`)
//! - `//pkg:file.star`       in the loading file's repo
//! - `:file.star`            in the loading file's package
//!
//! Static typechecking is on for every module, so type errors are reported for
//! all code, not just the paths that run.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use anyhow::{anyhow, bail, Context, Result};
use starlark::environment::{FrozenModule, Globals, GlobalsBuilder, LibraryExtension, Module};
use starlark::eval::{Evaluator, FileLoader};
use starlark::starlark_module;
use starlark::syntax::{AstModule, Dialect, DialectTypes};
use starlark::values::none::NoneOr;

/// The dialect rules_cfn Starlark is written in.
pub fn dialect() -> Dialect {
    Dialect {
        enable_types: DialectTypes::Enable,
        enable_keyword_only_arguments: true,
        enable_f_strings: true,
        enable_load_reexport: true,
        ..Dialect::Extended
    }
}

thread_local! {
    static REGEX_CACHE: RefCell<HashMap<String, Option<regex::Regex>>> = RefCell::new(HashMap::new());
}

/// Matches like JSON Schema `pattern` (unanchored search). None when the pattern
/// uses syntax the regex crate doesn't support (e.g. lookaheads).
pub fn regex_match(pattern: &str, s: &str) -> Option<bool> {
    REGEX_CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let re = c.entry(pattern.to_owned()).or_insert_with(|| regex::Regex::new(pattern).ok());
        re.as_ref().map(|re| re.is_match(s))
    })
}

#[starlark_module]
fn host_builtins(builder: &mut GlobalsBuilder) {
    /// Whether `s` matches the JSON Schema `pattern`, or None if the pattern can't be compiled.
    fn cfn_regex_match(pattern: &str, s: &str) -> anyhow::Result<NoneOr<bool>> {
        Ok(NoneOr::from_option(regex_match(pattern, s)))
    }
}

pub fn globals() -> Globals {
    GlobalsBuilder::extended_by(&[
        LibraryExtension::RecordType,
        LibraryExtension::EnumType,
        LibraryExtension::Typing,
        LibraryExtension::StructType,
        LibraryExtension::Json,
        LibraryExtension::Print,
        LibraryExtension::Map,
        LibraryExtension::Filter,
    ])
    .with(host_builtins)
    .build()
}

/// A parsed file label.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Label {
    pub repo: String,
    pub package: String,
    pub name: String,
}

impl Label {
    /// Parses `s` relative to `from` (the loading file's label).
    pub fn parse(s: &str, from: Option<&Label>) -> Result<Label> {
        let (repo, rest) = if let Some(r) = s.strip_prefix('@') {
            let r = r.strip_prefix('@').unwrap_or(r);
            let (repo, rest) = r.split_once("//").ok_or_else(|| anyhow!("bad label {s:?}"))?;
            (repo.to_owned(), format!("//{rest}"))
        } else {
            (from.map(|f| f.repo.clone()).unwrap_or_default(), s.to_owned())
        };
        if let Some(name) = rest.strip_prefix(':') {
            let from = from.ok_or_else(|| anyhow!("relative label {s:?} needs a loading file"))?;
            return Ok(Label { repo, package: from.package.clone(), name: name.to_owned() });
        }
        let rest = rest.strip_prefix("//").ok_or_else(|| anyhow!("label {s:?} must start with //, @repo// or :"))?;
        let (package, name) = rest.split_once(':').ok_or_else(|| anyhow!("label {s:?} must name a file after ':'"))?;
        if !name.ends_with(".star") {
            bail!("label {s:?} must name a .star file");
        }
        Ok(Label { repo, package: package.to_owned(), name: name.to_owned() })
    }

    pub fn display(&self) -> String {
        format!("@{}//{}:{}", self.repo, self.package, self.name)
    }
}

/// Maps repository names to directories.
#[derive(Debug, Clone, Default)]
pub struct Repos {
    /// "" is the main repository.
    pub dirs: HashMap<String, PathBuf>,
}

impl Repos {
    pub fn path(&self, l: &Label) -> Result<PathBuf> {
        let dir = self.dirs.get(&l.repo).ok_or_else(|| {
            anyhow!("no directory for repository @{} (pass --repo {}=<dir>)", l.repo, l.repo)
        })?;
        Ok(dir.join(&l.package).join(&l.name))
    }

    /// The label of a file under one of the repository directories.
    pub fn label_for(&self, path: &Path) -> Result<Label> {
        // Compare both lexical and symlink-resolved forms: Bazel sandboxes present
        // inputs as symlinks, while editors (and bazel-bin) may hand us either.
        let forms = |p: &Path| -> Vec<PathBuf> {
            let mut v = Vec::new();
            if let Ok(a) = std::path::absolute(p) {
                v.push(a);
            }
            if let Ok(c) = std::fs::canonicalize(p) {
                v.push(c);
            }
            v
        };
        let files = forms(path);
        let mut best: Option<(&String, PathBuf)> = None;
        for (name, dir) in &self.dirs {
            for d in forms(dir) {
                for f in &files {
                    if let Ok(rel) = f.strip_prefix(&d) {
                        if best.as_ref().is_none_or(|(_, b)| rel.components().count() < b.components().count()) {
                            best = Some((name, rel.to_owned()));
                        }
                    }
                }
            }
        }
        let (repo, rel) = best.ok_or_else(|| anyhow!("{} is not under any repository directory", path.display()))?;
        let package = rel.parent().map(|p| p.to_string_lossy().replace('\\', "/")).unwrap_or_default();
        let name = rel.file_name().unwrap().to_string_lossy().into_owned();
        Ok(Label { repo: repo.clone(), package, name })
    }
}

struct Shared {
    repos: Repos,
    globals: Globals,
    // Keyed by canonical path: the same file reached through different labels
    // (//cfn:core.star vs @rules_cfn//cfn:core.star) must be one module, or its
    // record types would be distinct.
    cache: RefCell<HashMap<PathBuf, FrozenModule>>,
    loading: RefCell<Vec<PathBuf>>,
}

/// Loads modules on behalf of the file `from`.
struct Loader {
    shared: Rc<Shared>,
    from: Label,
}

fn to_starlark(e: anyhow::Error) -> starlark::Error {
    starlark::Error::new_other(e)
}

impl FileLoader for Loader {
    fn load(&self, path: &str) -> starlark::Result<FrozenModule> {
        let label = Label::parse(path, Some(&self.from)).map_err(to_starlark)?;
        load_module(&self.shared, &label).map_err(to_starlark)
    }
}

/// Typechecks and evaluates `content` as the file at `path` (for editor diagnostics).
pub fn check_source(repos: Repos, path: &Path, content: String) -> std::result::Result<(), starlark::Error> {
    let label = repos.label_for(path).map_err(to_starlark)?;
    let shared = Rc::new(Shared { repos, globals: globals(), cache: RefCell::new(HashMap::new()), loading: RefCell::new(Vec::new()) });
    let ast = AstModule::parse(&path.to_string_lossy(), content, &dialect())?;
    let loader = Loader { shared: shared.clone(), from: label };
    Module::with_temp_heap(|module| {
        let mut eval = Evaluator::new(&module);
        eval.set_loader(&loader);
        eval.enable_static_typechecking(true);
        eval.eval_module(ast, &shared.globals).map(|_| ())
    })
}

fn load_module(shared: &Rc<Shared>, label: &Label) -> Result<FrozenModule> {
    let path = shared.repos.path(label)?;
    let key = std::fs::canonicalize(&path).with_context(|| format!("loading {} ({})", label.display(), path.display()))?;
    if let Some(m) = shared.cache.borrow().get(&key) {
        return Ok(m.clone());
    }
    if shared.loading.borrow().contains(&key) {
        bail!("load cycle through {}", label.display());
    }
    shared.loading.borrow_mut().push(key.clone());
    let src = std::fs::read_to_string(&path).with_context(|| format!("reading {} ({})", label.display(), path.display()))?;
    let ast = AstModule::parse(&label.display(), src, &dialect()).map_err(|e| anyhow!("{e}"))?;
    let loader = Loader { shared: shared.clone(), from: label.clone() };
    let frozen = Module::with_temp_heap(|module| -> Result<FrozenModule> {
        {
            let mut eval = Evaluator::new(&module);
            eval.set_loader(&loader);
            eval.enable_static_typechecking(true);
            eval.eval_module(ast, &shared.globals).map_err(|e| anyhow!("{e}"))?;
        }
        module.freeze().map_err(|e| anyhow!("{e:?}"))
    })?;
    shared.loading.borrow_mut().pop();
    shared.cache.borrow_mut().insert(key, frozen.clone());
    Ok(frozen)
}

/// Evaluates `entry` and calls its `function`, returning the result converted to JSON.
///
/// The function must return a value with a `_cfn` struct whose `json` field is the
/// template (as `core.star`'s `template()` does).
pub fn eval_template(repos: Repos, entry: &Path, function: &str) -> Result<serde_json::Value> {
    let label = repos.label_for(entry)?;
    let shared = Rc::new(Shared { repos, globals: globals(), cache: RefCell::new(HashMap::new()), loading: RefCell::new(Vec::new()) });
    let module = load_module(&shared, &label)?;
    if module.get(function).is_err() {
        bail!("{} has no function {function}()", label.display());
    }
    let src = format!("load({:?}, _entry = {:?})\n_entry()\n", label.display(), function);
    let ast = AstModule::parse("<entry>", src, &dialect()).map_err(|e| anyhow!("{e}"))?;
    let loader = Loader { shared: shared.clone(), from: label.clone() };
    Module::with_temp_heap(|m| -> Result<serde_json::Value> {
        let mut eval = Evaluator::new(&m);
        eval.set_loader(&loader);
        let result = eval.eval_module(ast, &shared.globals).map_err(|e| anyhow!("{e}"))?;
        let heap = eval.heap();
        let cfn = result
            .get_attr("_cfn", heap)
            .map_err(|e| anyhow!("{e}"))?
            .ok_or_else(|| anyhow!("{function}() must return a template(), got {}", result.get_type()))?;
        let json = cfn
            .get_attr("json", heap)
            .map_err(|e| anyhow!("{e}"))?
            .ok_or_else(|| anyhow!("{function}() must return a template()"))?;
        json.to_json_value()
    })
}

fn star_files(p: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    if !p.is_dir() {
        out.push(p.to_owned());
        return Ok(());
    }
    let mut entries: Vec<PathBuf> = std::fs::read_dir(p)?.map(|e| e.map(|e| e.path())).collect::<std::io::Result<_>>()?;
    entries.sort();
    for e in entries {
        if e.is_dir() || e.extension().is_some_and(|x| x == "star") {
            star_files(&e, out)?;
        }
    }
    Ok(())
}

/// Evaluates files (or directories of .star files) for their errors only (`cfnctl check`).
pub fn check(repos: Repos, files: &[PathBuf]) -> Result<()> {
    let shared = Rc::new(Shared { repos, globals: globals(), cache: RefCell::new(HashMap::new()), loading: RefCell::new(Vec::new()) });
    let mut all = Vec::new();
    for f in files {
        star_files(f, &mut all)?;
    }
    let mut failures = Vec::new();
    for f in &all {
        let label = shared.repos.label_for(f)?;
        if let Err(e) = load_module(&shared, &label) {
            failures.push(format!("{e}"));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        bail!("{}", failures.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        let from = Label { repo: "".into(), package: "examples/x".into(), name: "a.star".into() };
        assert_eq!(Label::parse(":b.star", Some(&from)).unwrap(), Label { repo: "".into(), package: "examples/x".into(), name: "b.star".into() });
        assert_eq!(Label::parse("//lib:c.star", Some(&from)).unwrap().package, "lib");
        let l = Label::parse("@cfn//aws/s3:bucket.star", Some(&from)).unwrap();
        assert_eq!((l.repo.as_str(), l.package.as_str(), l.name.as_str()), ("cfn", "aws/s3", "bucket.star"));
        assert_eq!(Label::parse("@@rules_cfn+//cfn:core.star", None).unwrap().repo, "rules_cfn+");
        assert!(Label::parse("lib.star", Some(&from)).is_err());
    }

    #[test]
    fn regex() {
        assert_eq!(regex_match("^[^\\s]+$", "a.b"), Some(true));
        assert_eq!(regex_match("^[^\\s]+$", "a b"), Some(false));
        assert_eq!(regex_match("^(?!aws:).*$", "x"), None);
    }
}
