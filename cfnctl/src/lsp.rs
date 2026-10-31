//! `cfnctl lsp`: a Starlark language server that understands rules_cfn labels.
//!
//! Built on starlark_lsp: completion (globals, loaded symbols, keyword
//! arguments), hover with docstrings, go-to-definition across `load()`s into the
//! generated bindings, and diagnostics from parsing, lints and a full
//! typecheck-and-evaluate of the open buffer.

use std::path::Path;

use starlark::analysis::AstModuleLint;
use starlark::docs::DocModule;
use starlark::errors::EvalMessage;
use starlark::syntax::AstModule;
use starlark_lsp::error::eval_message_to_lsp_diagnostic;
use starlark_lsp::server::{LspContext, LspEvalResult, LspUri, StringLiteralResult};

use crate::eval::{self, Label, Repos};

pub struct Context {
    pub repos: Repos,
    docs: DocModule,
}

impl Context {
    pub fn new(repos: Repos) -> Self {
        Context { repos, docs: eval::globals().documentation() }
    }
}

fn file(uri: &LspUri) -> Result<&Path, String> {
    match uri {
        LspUri::File(p) => Ok(p),
        _ => Err(format!("unsupported URI {uri}")),
    }
}

impl LspContext for Context {
    fn parse_file_with_contents(&self, uri: &LspUri, content: String) -> LspEvalResult {
        let Ok(path) = file(uri) else { return LspEvalResult::default() };
        match AstModule::parse(&path.to_string_lossy(), content.clone(), &eval::dialect()) {
            Err(e) => LspEvalResult { diagnostics: vec![eval_message_to_lsp_diagnostic(EvalMessage::from_error(path, &e))], ast: None },
            Ok(ast) => {
                let mut diagnostics: Vec<_> = ast.lint(None).into_iter().map(|l| eval_message_to_lsp_diagnostic(EvalMessage::from(l))).collect();
                if let Err(e) = eval::check_source(self.repos.clone(), path, content) {
                    diagnostics.push(eval_message_to_lsp_diagnostic(EvalMessage::from_error(path, &e)));
                }
                LspEvalResult { diagnostics, ast: Some(ast) }
            }
        }
    }

    fn resolve_load(&self, path: &str, current_file: &LspUri, _root: Option<&Path>) -> Result<LspUri, String> {
        let from = self.repos.label_for(file(current_file)?).map_err(|e| e.to_string())?;
        let label = Label::parse(path, Some(&from)).map_err(|e| e.to_string())?;
        let p = self.repos.path(&label).map_err(|e| e.to_string())?;
        let abs = std::fs::canonicalize(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        Ok(LspUri::File(abs))
    }

    fn render_as_load(&self, target: &LspUri, current_file: &LspUri, _root: Option<&Path>) -> Result<String, String> {
        let t = self.repos.label_for(file(target)?).map_err(|e| e.to_string())?;
        let c = self.repos.label_for(file(current_file)?).map_err(|e| e.to_string())?;
        Ok(if t.repo == c.repo && t.package == c.package {
            format!(":{}", t.name)
        } else if t.repo == c.repo {
            format!("//{}:{}", t.package, t.name)
        } else {
            format!("@{}//{}:{}", t.repo, t.package, t.name)
        })
    }

    fn resolve_string_literal(&self, literal: &str, current_file: &LspUri, root: Option<&Path>) -> Result<Option<StringLiteralResult>, String> {
        // Lets go-to-definition jump from a load() path string to the file.
        if literal.ends_with(".star") && (literal.starts_with('@') || literal.starts_with("//") || literal.starts_with(':')) {
            if let Ok(uri) = self.resolve_load(literal, current_file, root) {
                return Ok(Some(StringLiteralResult { uri, location_finder: None }));
            }
        }
        Ok(None)
    }

    fn get_load_contents(&self, uri: &LspUri) -> Result<Option<String>, String> {
        match std::fs::read_to_string(file(uri)?) {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn get_environment(&self, _uri: &LspUri) -> DocModule {
        self.docs.clone()
    }

    fn get_uri_for_global_symbol(&self, _current_file: &LspUri, _symbol: &str) -> Result<Option<LspUri>, String> {
        Ok(None)
    }
}

pub fn serve(repos: Repos) -> anyhow::Result<()> {
    starlark_lsp::server::stdio_server(Context::new(repos)).map_err(|e| anyhow::anyhow!("{e:?}"))
}
