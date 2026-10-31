//! Run-time commands on CloudFormation change sets: diff, plan (dry run),
//! deploy and destroy.
//!
//! AWS calls go through the [`Aws`] trait so the logic is testable against an
//! in-memory fake; [`crate::aws`] implements it with the AWS SDK.

use std::collections::HashSet;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};

use crate::package::{Manifest, DEFAULT_ASSET_BUCKET};
use crate::tmpldiff;

/// Largest template CloudFormation accepts inline (TemplateBody).
pub const MAX_INLINE_TEMPLATE: usize = 51200;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct StackInfo {
    pub id: String,
    pub status: String,
    pub termination_protection: bool,
    pub outputs: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ResourceChange {
    pub action: String,
    pub logical_id: String,
    pub resource_type: String,
    /// "True", "False", "Conditional" or "".
    pub replacement: String,
}

#[derive(Debug, Clone, Default)]
pub struct ChangeSetPage {
    pub status: String,
    pub reason: String,
    pub changes: Vec<ResourceChange>,
    pub next: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct StackEvent {
    pub id: String,
    /// Seconds since the epoch.
    pub timestamp: i64,
    pub status: String,
    pub logical_id: String,
    pub resource_type: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default)]
pub struct CreateChangeSet {
    pub stack: String,
    pub name: String,
    pub create: bool,
    pub body: Option<String>,
    pub url: Option<String>,
    pub role_arn: Option<String>,
    pub capabilities: Vec<String>,
    pub parameters: Vec<(String, String)>,
    pub tags: Vec<(String, String)>,
}

/// The AWS operations cfnctl needs.
#[allow(async_fn_in_trait)]
pub trait Aws {
    /// (account, caller ARN)
    async fn identity(&self) -> Result<(String, String)>;
    async fn describe_stack(&self, stack: &str) -> Result<Option<StackInfo>>;
    async fn get_template(&self, stack: &str) -> Result<String>;
    async fn create_change_set(&self, req: CreateChangeSet) -> Result<()>;
    async fn describe_change_set(&self, stack: &str, name: &str, next: Option<String>) -> Result<ChangeSetPage>;
    async fn delete_change_set(&self, stack: &str, name: &str) -> Result<()>;
    async fn execute_change_set(&self, stack: &str, name: &str) -> Result<()>;
    /// Newest first, like DescribeStackEvents.
    async fn stack_events(&self, stack: &str) -> Result<Vec<StackEvent>>;
    async fn delete_stack(&self, stack: &str) -> Result<()>;
    async fn set_termination_protection(&self, stack: &str, enabled: bool) -> Result<()>;
    async fn object_exists(&self, bucket: &str, key: &str) -> Result<bool>;
    async fn put_object(&self, bucket: &str, key: &str, data: Vec<u8>) -> Result<()>;
    /// Current time in seconds since the epoch.
    fn now(&self) -> i64;
    async fn sleep(&self, d: Duration);
}

pub struct Deployer<'a, A: Aws> {
    pub aws: &'a A,
    pub region: String,
    pub manifest: Manifest,
    /// Directory the manifest's relative paths resolve against.
    pub dir: PathBuf,
    /// Skip interactive confirmation.
    pub yes: bool,
    /// Where confirmation answers come from; None when not interactive.
    pub input: Option<Box<dyn BufRead + 'a>>,
    pub out: Box<dyn Write + 'a>,
    pub poll: Duration,
    pub account: String,
}

pub struct ChangeSet {
    pub name: String,
    pub create: bool,
    pub changes: Vec<ResourceChange>,
    /// CloudFormation found nothing to change.
    pub empty: bool,
}

const NO_CHANGES: &[&str] = &["didn't contain changes", "No updates are to be performed"];

impl<'a, A: Aws> Deployer<'a, A> {
    fn stack_name(&self) -> String {
        self.manifest.config.stack_name.clone()
    }

    /// Refuses to continue when credentials or region don't match the stack's pins.
    pub async fn check_identity(&mut self) -> Result<()> {
        let (account, arn) = self.aws.identity().await.context("checking AWS credentials")?;
        self.account = account;
        let c = &self.manifest.config;
        if !c.account.is_empty() && c.account != self.account {
            bail!("stack {} is pinned to account {} but credentials are for account {} ({arn})", c.stack_name, c.account, self.account);
        }
        if !c.region.is_empty() && c.region != self.region {
            bail!("stack {} is pinned to region {} but the session is for {}", c.stack_name, c.region, self.region);
        }
        Ok(())
    }

    fn bucket(&self) -> String {
        let b = if self.manifest.config.asset_bucket.is_empty() { DEFAULT_ASSET_BUCKET } else { &self.manifest.config.asset_bucket };
        b.replace("${AWS::AccountId}", &self.account).replace("${AWS::Region}", &self.region)
    }

    fn template_body(&self) -> Result<Vec<u8>> {
        let p = self.dir.join(&self.manifest.template);
        std::fs::read(&p).with_context(|| format!("reading {}", p.display()))
    }

    async fn stack(&self) -> Result<Option<StackInfo>> {
        self.aws.describe_stack(&self.stack_name()).await
    }

    /// Prints the semantic difference between deployed and local templates; true if any.
    pub async fn diff(&mut self) -> Result<bool> {
        let new: serde_json::Value = serde_json::from_slice(&self.template_body()?)?;
        let old = match self.stack().await? {
            Some(s) if s.status != "REVIEW_IN_PROGRESS" => {
                let body = self.aws.get_template(&self.stack_name()).await?;
                serde_json::from_str(&body).context("deployed template is not JSON (was it deployed by another tool?)")?
            }
            _ => {
                writeln!(self.out, "Stack {} does not exist yet; everything will be created.", self.stack_name())?;
                serde_json::json!({})
            }
        };
        let changes = tmpldiff::diff(&old, &new);
        writeln!(self.out, "Stack {}", self.stack_name())?;
        write!(self.out, "{}", tmpldiff::render(&changes))?;
        Ok(!changes.is_empty())
    }

    /// Uploads packaged assets that aren't already in the asset bucket.
    pub async fn upload_assets(&mut self) -> Result<()> {
        let bucket = self.bucket();
        for a in self.manifest.assets.clone() {
            if self.aws.object_exists(&bucket, &a.key).await.unwrap_or(false) {
                continue;
            }
            let data = std::fs::read(self.dir.join(&a.file))?;
            writeln!(self.out, "Uploading {} -> s3://{bucket}/{}", a.label, a.key)?;
            self.aws
                .put_object(&bucket, &a.key, data)
                .await
                .with_context(|| format!("uploading {} to s3://{bucket} (deploy the bootstrap stack first?)", a.label))?;
        }
        Ok(())
    }

    async fn template_args(&mut self) -> Result<(Option<String>, Option<String>)> {
        let body = self.template_body()?;
        if body.len() <= MAX_INLINE_TEMPLATE {
            return Ok((Some(String::from_utf8(body)?), None));
        }
        let bucket = self.bucket();
        let key = format!("templates/{}.json", self.manifest.template_sha256);
        let len = body.len();
        self.aws.put_object(&bucket, &key, body).await.with_context(|| format!("uploading template ({len} bytes) to s3://{bucket}"))?;
        Ok((None, Some(format!("https://{bucket}.s3.{}.amazonaws.com/{key}", self.region))))
    }

    async fn create_change_set(&mut self) -> Result<ChangeSet> {
        let st = self.stack().await?;
        let create = match &st {
            None => true,
            Some(s) if s.status == "REVIEW_IN_PROGRESS" => true,
            Some(s) if s.status == "ROLLBACK_COMPLETE" => {
                bail!("stack {} is in ROLLBACK_COMPLETE (its creation failed) and must be destroyed before it can be deployed again", self.stack_name())
            }
            Some(s) if s.status.ends_with("_IN_PROGRESS") => bail!("stack {} is busy ({})", self.stack_name(), s.status),
            Some(_) => false,
        };
        let (body, url) = self.template_args().await?;
        let sha: String = self.manifest.template_sha256.chars().take(12).collect();
        let name = format!("rules-cfn-{sha}-{}", self.aws.now());
        let c = &self.manifest.config;
        self.aws
            .create_change_set(CreateChangeSet {
                stack: c.stack_name.clone(),
                name: name.clone(),
                create,
                body,
                url,
                role_arn: (!c.role_arn.is_empty()).then(|| c.role_arn.clone()),
                capabilities: c.capabilities.clone(),
                parameters: c.parameters.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
                tags: c.tags.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
            })
            .await
            .context("creating change set")?;
        loop {
            let page = self.aws.describe_change_set(&self.stack_name(), &name, None).await?;
            match page.status.as_str() {
                "CREATE_COMPLETE" => {
                    let mut changes = page.changes;
                    let mut next = page.next;
                    while let Some(token) = next {
                        let p = self.aws.describe_change_set(&self.stack_name(), &name, Some(token)).await?;
                        changes.extend(p.changes);
                        next = p.next;
                    }
                    return Ok(ChangeSet { name, create, changes, empty: false });
                }
                "FAILED" => {
                    if NO_CHANGES.iter().any(|m| page.reason.contains(m)) {
                        return Ok(ChangeSet { name, create, changes: vec![], empty: true });
                    }
                    bail!("change set failed: {}", page.reason);
                }
                _ => self.aws.sleep(self.poll).await,
            }
        }
    }

    fn print_change_set(&mut self, cs: &ChangeSet) -> Result<()> {
        if cs.empty {
            writeln!(self.out, "No changes to stack {}.", self.stack_name())?;
            return Ok(());
        }
        let verb = if cs.create { "create" } else { "update" };
        writeln!(self.out, "Change set {} will {verb} stack {}:", cs.name, self.stack_name())?;
        for c in &cs.changes {
            let mut line = format!("  {:<8} {:<40} {}", c.action, c.logical_id, c.resource_type);
            match c.replacement.as_str() {
                "True" => line.push_str("  REPLACEMENT"),
                "Conditional" => line.push_str("  (may be replaced)"),
                _ => {}
            }
            writeln!(self.out, "{line}")?;
        }
        Ok(())
    }

    async fn cleanup(&mut self, cs: &ChangeSet) -> Result<()> {
        self.aws.delete_change_set(&self.stack_name(), &cs.name).await?;
        if !cs.create {
            return Ok(());
        }
        // A CREATE change set leaves an empty REVIEW_IN_PROGRESS stack behind.
        if self.stack().await?.is_some_and(|s| s.status == "REVIEW_IN_PROGRESS") {
            self.aws.delete_stack(&self.stack_name()).await?;
        }
        Ok(())
    }

    /// Dry run: create, print and delete a change set. True if the stack would change.
    pub async fn plan(&mut self, keep: bool) -> Result<bool> {
        let cs = self.create_change_set().await?;
        self.print_change_set(&cs)?;
        if keep && !cs.empty {
            writeln!(self.out, "Keeping change set {} for review.", cs.name)?;
            return Ok(true);
        }
        self.cleanup(&cs).await?;
        Ok(!cs.empty)
    }

    fn confirm(&mut self, prompt: &str) -> Result<bool> {
        if self.yes {
            return Ok(true);
        }
        let Some(input) = self.input.as_mut() else {
            bail!("refusing to {prompt} without confirmation; pass --yes");
        };
        write!(self.out, "Do you want to {prompt}? [y/N] ")?;
        self.out.flush()?;
        let mut line = String::new();
        input.read_line(&mut line)?;
        Ok(matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
    }

    /// Uploads assets, creates a change set and, once confirmed, executes it.
    pub async fn deploy(&mut self) -> Result<()> {
        self.upload_assets().await?;
        let cs = self.create_change_set().await?;
        self.print_change_set(&cs)?;
        if cs.empty {
            return self.cleanup(&cs).await;
        }
        let ok = match self.confirm("deploy these changes") {
            Ok(ok) => ok,
            Err(e) => {
                self.cleanup(&cs).await?;
                return Err(e);
            }
        };
        if !ok {
            self.cleanup(&cs).await?;
            writeln!(self.out, "Not deploying.")?;
            return Ok(());
        }
        let start = self.aws.now();
        self.aws.execute_change_set(&self.stack_name(), &cs.name).await.context("executing change set")?;
        let status = self.wait(self.stack_name(), start).await?;
        if !matches!(status.as_str(), "CREATE_COMPLETE" | "UPDATE_COMPLETE" | "IMPORT_COMPLETE") {
            bail!("deploy of {} failed: stack is {status}", self.stack_name());
        }
        if self.manifest.config.termination_protection {
            self.aws.set_termination_protection(&self.stack_name(), true).await?;
        }
        if let Some(st) = self.stack().await? {
            if !st.outputs.is_empty() {
                writeln!(self.out, "Outputs:")?;
                let mut outs = st.outputs;
                outs.sort();
                for (k, v) in outs {
                    writeln!(self.out, "  {k} = {v}")?;
                }
            }
        }
        Ok(())
    }

    /// Deletes the stack.
    pub async fn destroy(&mut self, force: bool) -> Result<()> {
        let Some(st) = self.stack().await? else {
            writeln!(self.out, "Stack {} does not exist.", self.stack_name())?;
            return Ok(());
        };
        if st.termination_protection && !force {
            bail!("stack {} has termination protection enabled; pass --force to disable it and delete", self.stack_name());
        }
        let prompt = format!("delete stack {}", self.stack_name());
        if !self.confirm(&prompt)? {
            return Ok(());
        }
        if st.termination_protection {
            self.aws.set_termination_protection(&self.stack_name(), false).await?;
        }
        let start = self.aws.now();
        self.aws.delete_stack(&st.id).await?;
        // Track by stack ID: once deleted, the name no longer resolves.
        let status = self.wait(st.id.clone(), start).await?;
        if status != "DELETE_COMPLETE" {
            bail!("delete of {} failed: stack is {status}", self.stack_name());
        }
        Ok(())
    }

    /// Polls until the stack leaves *_IN_PROGRESS, streaming new events.
    async fn wait(&mut self, stack: String, since: i64) -> Result<String> {
        let mut seen = HashSet::new();
        loop {
            let events = self.aws.stack_events(&stack).await?;
            for e in events.iter().rev() {
                if e.timestamp < since || !seen.insert(e.id.clone()) {
                    continue;
                }
                write!(self.out, "  {:<28} {:<40} {}", e.status, e.logical_id, e.resource_type)?;
                if e.status.ends_with("FAILED") && !e.reason.is_empty() {
                    write!(self.out, "\n      {}", e.reason)?;
                }
                writeln!(self.out)?;
            }
            match self.aws.describe_stack(&stack).await? {
                None => return Ok("DELETE_COMPLETE".into()),
                Some(s) if !s.status.ends_with("_IN_PROGRESS") => return Ok(s.status),
                Some(_) => self.aws.sleep(self.poll).await,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::package::{Asset, Config};
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;

    /// One stack; change sets compare whole templates; execution is synchronous.
    #[derive(Default)]
    struct Fake {
        account: String,
        stack: RefCell<Option<(StackInfo, String)>>, // info, stack name
        template: RefCell<String>,
        change_sets: RefCell<HashMap<String, CreateChangeSet>>,
        events: RefCell<Vec<StackEvent>>,
        executed: RefCell<usize>,
        deleted: RefCell<bool>,
        objects: RefCell<HashMap<String, Vec<u8>>>,
        clock: RefCell<i64>,
    }

    impl Fake {
        fn live(&self, name: &str) -> Option<StackInfo> {
            let s = self.stack.borrow();
            let (info, n) = s.as_ref()?;
            (info.id == name || (n == name && info.status != "DELETE_COMPLETE")).then(|| info.clone())
        }
        fn event(&self, status: &str) {
            *self.clock.borrow_mut() += 1;
            let mut ev = self.events.borrow_mut();
            let id = ev.len().to_string();
            ev.insert(0, StackEvent { id, timestamp: *self.clock.borrow(), status: status.into(), logical_id: "s".into(), resource_type: "AWS::CloudFormation::Stack".into(), reason: String::new() });
        }
        fn set_status(&self, status: &str) {
            if let Some((info, _)) = self.stack.borrow_mut().as_mut() {
                info.status = status.into();
            }
        }
    }

    impl Aws for Fake {
        async fn identity(&self) -> Result<(String, String)> {
            Ok((self.account.clone(), format!("arn:aws:iam::{}:user/me", self.account)))
        }
        async fn describe_stack(&self, stack: &str) -> Result<Option<StackInfo>> {
            Ok(self.live(stack))
        }
        async fn get_template(&self, _: &str) -> Result<String> {
            Ok(self.template.borrow().clone())
        }
        async fn create_change_set(&self, req: CreateChangeSet) -> Result<()> {
            if req.create && self.live(&req.stack).is_none() {
                *self.stack.borrow_mut() = Some((StackInfo { id: format!("arn:stack/{}/1", req.stack), status: "REVIEW_IN_PROGRESS".into(), ..Default::default() }, req.stack.clone()));
            }
            self.change_sets.borrow_mut().insert(req.name.clone(), req);
            Ok(())
        }
        async fn describe_change_set(&self, _: &str, name: &str, _: Option<String>) -> Result<ChangeSetPage> {
            let cs = self.change_sets.borrow();
            let cs = &cs[name];
            if cs.body.as_deref() == Some(self.template.borrow().as_str()) {
                return Ok(ChangeSetPage { status: "FAILED".into(), reason: "The submitted information didn't contain changes.".into(), ..Default::default() });
            }
            let action = if cs.create { "Add" } else { "Modify" };
            Ok(ChangeSetPage { status: "CREATE_COMPLETE".into(), changes: vec![ResourceChange { action: action.into(), logical_id: "Bucket".into(), resource_type: "AWS::S3::Bucket".into(), replacement: String::new() }], ..Default::default() })
        }
        async fn delete_change_set(&self, _: &str, name: &str) -> Result<()> {
            self.change_sets.borrow_mut().remove(name);
            Ok(())
        }
        async fn execute_change_set(&self, _: &str, name: &str) -> Result<()> {
            let cs = self.change_sets.borrow_mut().remove(name).unwrap();
            *self.executed.borrow_mut() += 1;
            *self.template.borrow_mut() = cs.body.unwrap_or_default();
            let status = if cs.create { "CREATE_COMPLETE" } else { "UPDATE_COMPLETE" };
            self.set_status(status);
            if let Some((info, _)) = self.stack.borrow_mut().as_mut() {
                info.outputs = vec![("Url".into(), "https://example".into())];
            }
            self.event(status);
            Ok(())
        }
        async fn stack_events(&self, _: &str) -> Result<Vec<StackEvent>> {
            Ok(self.events.borrow().clone())
        }
        async fn delete_stack(&self, _: &str) -> Result<()> {
            *self.deleted.borrow_mut() = true;
            self.set_status("DELETE_COMPLETE");
            self.template.borrow_mut().clear();
            self.event("DELETE_COMPLETE");
            Ok(())
        }
        async fn set_termination_protection(&self, _: &str, enabled: bool) -> Result<()> {
            if let Some((info, _)) = self.stack.borrow_mut().as_mut() {
                info.termination_protection = enabled;
            }
            Ok(())
        }
        async fn object_exists(&self, bucket: &str, key: &str) -> Result<bool> {
            Ok(self.objects.borrow().contains_key(&format!("{bucket}/{key}")))
        }
        async fn put_object(&self, bucket: &str, key: &str, data: Vec<u8>) -> Result<()> {
            self.objects.borrow_mut().insert(format!("{bucket}/{key}"), data);
            Ok(())
        }
        fn now(&self) -> i64 {
            *self.clock.borrow()
        }
        async fn sleep(&self, _: Duration) {}
    }

    #[derive(Clone, Default)]
    struct Buf(Rc<RefCell<Vec<u8>>>);
    impl Write for Buf {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.borrow_mut().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    impl Buf {
        fn take(&self) -> String {
            String::from_utf8(std::mem::take(&mut *self.0.borrow_mut())).unwrap()
        }
    }

    const T1: &str = r#"{"Resources": {"Bucket": {"Type": "AWS::S3::Bucket"}}}"#;
    const T2: &str = r#"{"Resources": {"Bucket": {"Type": "AWS::S3::Bucket", "Properties": {"BucketName": "b"}}}}"#;

    fn setup<'a>(aws: &'a Fake, dir: &std::path::Path, template: &str, out: Buf) -> Deployer<'a, Fake> {
        std::fs::create_dir_all(dir.join("s.assets")).unwrap();
        std::fs::write(dir.join("s.template.json"), template).unwrap();
        std::fs::write(dir.join("s.assets/abc.zip"), "zip").unwrap();
        let manifest = Manifest {
            config: Config { stack_name: "s".into(), account: "111111111111".into(), region: "us-east-1".into(), ..Default::default() },
            template: "s.template.json".into(),
            template_sha256: "0123456789abcdef".into(),
            template_size: template.len(),
            assets: vec![Asset { label: "//fn:code".into(), packaging: "zip".into(), sha256: "abc".into(), key: "assets/abc.zip".into(), file: "s.assets/abc.zip".into() }],
        };
        Deployer { aws, region: "us-east-1".into(), manifest, dir: dir.to_owned(), yes: true, input: None, out: Box::new(out), poll: Duration::ZERO, account: String::new() }
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("cfnctl-deploy-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn plan_new_stack_leaves_nothing_behind() {
        let aws = Fake { account: "111111111111".into(), ..Default::default() };
        let out = Buf::default();
        let mut d = setup(&aws, &tmp("plan"), T1, out.clone());
        block(async {
            d.check_identity().await.unwrap();
            assert!(d.plan(false).await.unwrap());
        });
        assert!(aws.change_sets.borrow().is_empty() && *aws.deleted.borrow() && *aws.executed.borrow() == 0);
        assert!(aws.objects.borrow().is_empty(), "plan must not upload");
        assert!(out.take().contains("will create stack s"));
    }

    #[test]
    fn deploy_lifecycle() {
        let aws = Fake { account: "111111111111".into(), ..Default::default() };
        let out = Buf::default();
        let dir = tmp("deploy");
        let mut d = setup(&aws, &dir, T1, out.clone());
        block(async {
            d.check_identity().await.unwrap();
            d.deploy().await.unwrap();
            assert_eq!(aws.live("s").unwrap().status, "CREATE_COMPLETE");
            assert!(aws.objects.borrow().contains_key("rules-cfn-assets-111111111111-us-east-1/assets/abc.zip"));
            assert!(out.take().contains("Url = https://example"));

            d.deploy().await.unwrap();
            assert_eq!(*aws.executed.borrow(), 1);
            assert!(out.take().contains("No changes"));

            std::fs::write(dir.join("s.template.json"), T2).unwrap();
            assert!(d.diff().await.unwrap());
            let o = out.take();
            assert!(o.contains("[~] Bucket (AWS::S3::Bucket)") && o.contains(r#"Properties: (absent) -> {"BucketName":"b"}"#), "{o}");

            d.deploy().await.unwrap();
            assert_eq!(aws.live("s").unwrap().status, "UPDATE_COMPLETE");

            aws.set_termination_protection("s", true).await.unwrap();
            let e = d.destroy(false).await.unwrap_err();
            assert!(e.to_string().contains("termination protection"), "{e}");
            d.destroy(true).await.unwrap();
            assert!(aws.live("s").is_none());
        });
    }

    #[test]
    fn deploy_needs_confirmation() {
        let aws = Fake { account: "111111111111".into(), ..Default::default() };
        let mut d = setup(&aws, &tmp("confirm"), T1, Buf::default());
        d.yes = false;
        block(async {
            d.check_identity().await.unwrap();
            let e = d.deploy().await.unwrap_err();
            assert!(e.to_string().contains("--yes"), "{e}");
            assert!(*aws.executed.borrow() == 0 && aws.change_sets.borrow().is_empty());
            d.input = Some(Box::new(std::io::Cursor::new(b"n\n".to_vec())));
            d.deploy().await.unwrap();
            assert_eq!(*aws.executed.borrow(), 0);
            d.input = Some(Box::new(std::io::Cursor::new(b"y\n".to_vec())));
            d.deploy().await.unwrap();
            assert_eq!(*aws.executed.borrow(), 1);
        });
    }

    #[test]
    fn account_guard() {
        let aws = Fake { account: "222222222222".into(), ..Default::default() };
        let mut d = setup(&aws, &tmp("guard"), T1, Buf::default());
        let e = block(d.check_identity()).unwrap_err();
        assert!(e.to_string().contains("pinned to account 111111111111"), "{e}");
    }

    #[test]
    fn large_template_goes_through_s3() {
        let aws = Fake { account: "111111111111".into(), ..Default::default() };
        let big = format!(r#"{{"Resources": {{"B": {{"Type": "AWS::S3::Bucket", "Metadata": {{"Pad": "{}"}}}}}}}}"#, "x".repeat(MAX_INLINE_TEMPLATE));
        let mut d = setup(&aws, &tmp("big"), &big, Buf::default());
        let (body, url) = block(async {
            d.check_identity().await.unwrap();
            d.template_args().await.unwrap()
        });
        assert!(body.is_none());
        assert!(url.unwrap().starts_with("https://rules-cfn-assets-111111111111-us-east-1.s3.us-east-1.amazonaws.com/templates/"));
    }
}
