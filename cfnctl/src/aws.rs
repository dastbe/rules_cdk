//! [`Aws`] implemented with the AWS SDK for Rust.

use std::time::Duration;

use anyhow::{anyhow, Result};
use aws_sdk_cloudformation::error::ProvideErrorMetadata;
use aws_sdk_cloudformation::types as cfn;
use aws_sdk_s3::primitives::ByteStream;

use crate::deploy::{Aws, ChangeSetPage, CreateChangeSet, ResourceChange, StackEvent, StackInfo};

pub struct Sdk {
    cfn: aws_sdk_cloudformation::Client,
    s3: aws_sdk_s3::Client,
    sts: aws_sdk_sts::Client,
}

impl Sdk {
    /// Loads credentials and region from the default chain; returns the client and its region.
    pub async fn new(region: Option<String>, profile: Option<String>) -> Result<(Sdk, String)> {
        let mut loader = aws_config::defaults(aws_config::BehaviorVersion::latest());
        if let Some(r) = region {
            loader = loader.region(aws_config::Region::new(r));
        }
        if let Some(p) = profile {
            loader = loader.profile_name(p);
        }
        let conf = loader.load().await;
        let region = conf
            .region()
            .map(|r| r.to_string())
            .ok_or_else(|| anyhow!("no AWS region: set region on the cfn_stack, pass --region, or set AWS_REGION"))?;
        let sdk = Sdk {
            cfn: aws_sdk_cloudformation::Client::new(&conf),
            s3: aws_sdk_s3::Client::new(&conf),
            sts: aws_sdk_sts::Client::new(&conf),
        };
        Ok((sdk, region))
    }
}

fn err<E: ProvideErrorMetadata + std::error::Error + Send + Sync + 'static>(e: E) -> anyhow::Error {
    match (e.code(), e.message()) {
        (Some(c), Some(m)) => anyhow!("{c}: {m}"),
        _ => anyhow!(e),
    }
}

fn s(x: Option<&str>) -> String {
    x.unwrap_or_default().to_owned()
}

impl Aws for Sdk {
    async fn identity(&self) -> Result<(String, String)> {
        let id = self.sts.get_caller_identity().send().await.map_err(err)?;
        Ok((s(id.account()), s(id.arn())))
    }

    async fn describe_stack(&self, stack: &str) -> Result<Option<StackInfo>> {
        match self.cfn.describe_stacks().stack_name(stack).send().await {
            Ok(out) => Ok(out.stacks().first().map(|st| StackInfo {
                id: s(st.stack_id()),
                status: st.stack_status().map(|x| x.as_str().to_owned()).unwrap_or_default(),
                termination_protection: st.enable_termination_protection().unwrap_or(false),
                outputs: st.outputs().iter().map(|o| (s(o.output_key()), s(o.output_value()))).collect(),
            })),
            Err(e) if e.code() == Some("ValidationError") && e.message().is_some_and(|m| m.contains("does not exist")) => Ok(None),
            Err(e) => Err(err(e)),
        }
    }

    async fn get_template(&self, stack: &str) -> Result<String> {
        let out = self.cfn.get_template().stack_name(stack).template_stage(cfn::TemplateStage::Original).send().await.map_err(err)?;
        Ok(s(out.template_body()))
    }

    async fn create_change_set(&self, req: CreateChangeSet) -> Result<()> {
        let mut b = self
            .cfn
            .create_change_set()
            .stack_name(&req.stack)
            .change_set_name(&req.name)
            .change_set_type(if req.create { cfn::ChangeSetType::Create } else { cfn::ChangeSetType::Update })
            .set_template_body(req.body)
            .set_template_url(req.url)
            .set_role_arn(req.role_arn)
            .description("Created by rules_cfn cfnctl");
        for c in req.capabilities {
            b = b.capabilities(cfn::Capability::from(c.as_str()));
        }
        for (k, v) in req.parameters {
            b = b.parameters(cfn::Parameter::builder().parameter_key(k).parameter_value(v).build());
        }
        for (k, v) in req.tags {
            b = b.tags(cfn::Tag::builder().key(k).value(v).build());
        }
        b.send().await.map_err(err)?;
        Ok(())
    }

    async fn describe_change_set(&self, stack: &str, name: &str, next: Option<String>) -> Result<ChangeSetPage> {
        let out = self.cfn.describe_change_set().stack_name(stack).change_set_name(name).set_next_token(next).send().await.map_err(err)?;
        Ok(ChangeSetPage {
            status: out.status().map(|x| x.as_str().to_owned()).unwrap_or_default(),
            reason: s(out.status_reason()),
            changes: out
                .changes()
                .iter()
                .filter_map(|c| c.resource_change())
                .map(|rc| ResourceChange {
                    action: rc.action().map(|a| a.as_str().to_owned()).unwrap_or_default(),
                    logical_id: s(rc.logical_resource_id()),
                    resource_type: s(rc.resource_type()),
                    replacement: rc.replacement().map(|r| r.as_str().to_owned()).unwrap_or_default(),
                })
                .collect(),
            next: out.next_token().map(str::to_owned),
        })
    }

    async fn delete_change_set(&self, stack: &str, name: &str) -> Result<()> {
        self.cfn.delete_change_set().stack_name(stack).change_set_name(name).send().await.map_err(err)?;
        Ok(())
    }

    async fn execute_change_set(&self, stack: &str, name: &str) -> Result<()> {
        self.cfn.execute_change_set().stack_name(stack).change_set_name(name).send().await.map_err(err)?;
        Ok(())
    }

    async fn stack_events(&self, stack: &str) -> Result<Vec<StackEvent>> {
        let out = self.cfn.describe_stack_events().stack_name(stack).send().await.map_err(err)?;
        Ok(out
            .stack_events()
            .iter()
            .map(|e| StackEvent {
                id: s(e.event_id()),
                timestamp: e.timestamp().map(|t| t.secs()).unwrap_or_default(),
                status: e.resource_status().map(|x| x.as_str().to_owned()).unwrap_or_default(),
                logical_id: s(e.logical_resource_id()),
                resource_type: s(e.resource_type()),
                reason: s(e.resource_status_reason()),
            })
            .collect())
    }

    async fn delete_stack(&self, stack: &str) -> Result<()> {
        self.cfn.delete_stack().stack_name(stack).send().await.map_err(err)?;
        Ok(())
    }

    async fn set_termination_protection(&self, stack: &str, enabled: bool) -> Result<()> {
        self.cfn.update_termination_protection().stack_name(stack).enable_termination_protection(enabled).send().await.map_err(err)?;
        Ok(())
    }

    async fn object_exists(&self, bucket: &str, key: &str) -> Result<bool> {
        // Any failure (including 403 on a missing key) means "upload it"; PutObject reports real errors.
        Ok(self.s3.head_object().bucket(bucket).key(key).send().await.is_ok())
    }

    async fn put_object(&self, bucket: &str, key: &str, data: Vec<u8>) -> Result<()> {
        self.s3.put_object().bucket(bucket).key(key).body(ByteStream::from(data)).send().await.map_err(err)?;
        Ok(())
    }

    fn now(&self) -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or_default()
    }

    async fn sleep(&self, d: Duration) {
        tokio::time::sleep(d).await
    }
}
