// Package deploy implements cfnctl's run-time commands on top of
// CloudFormation change sets: diff, plan (dry run), deploy and destroy.
package deploy

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	cfn "github.com/aws/aws-sdk-go-v2/service/cloudformation"
	cfntypes "github.com/aws/aws-sdk-go-v2/service/cloudformation/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"

	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
	"github.com/dastbe/rules_cdk/cfn/internal/tmpldiff"
)

// CloudFormation is the subset of the CloudFormation API cfnctl uses.
type CloudFormation interface {
	DescribeStacks(context.Context, *cfn.DescribeStacksInput, ...func(*cfn.Options)) (*cfn.DescribeStacksOutput, error)
	GetTemplate(context.Context, *cfn.GetTemplateInput, ...func(*cfn.Options)) (*cfn.GetTemplateOutput, error)
	CreateChangeSet(context.Context, *cfn.CreateChangeSetInput, ...func(*cfn.Options)) (*cfn.CreateChangeSetOutput, error)
	DescribeChangeSet(context.Context, *cfn.DescribeChangeSetInput, ...func(*cfn.Options)) (*cfn.DescribeChangeSetOutput, error)
	DeleteChangeSet(context.Context, *cfn.DeleteChangeSetInput, ...func(*cfn.Options)) (*cfn.DeleteChangeSetOutput, error)
	ExecuteChangeSet(context.Context, *cfn.ExecuteChangeSetInput, ...func(*cfn.Options)) (*cfn.ExecuteChangeSetOutput, error)
	DescribeStackEvents(context.Context, *cfn.DescribeStackEventsInput, ...func(*cfn.Options)) (*cfn.DescribeStackEventsOutput, error)
	DeleteStack(context.Context, *cfn.DeleteStackInput, ...func(*cfn.Options)) (*cfn.DeleteStackOutput, error)
	UpdateTerminationProtection(context.Context, *cfn.UpdateTerminationProtectionInput, ...func(*cfn.Options)) (*cfn.UpdateTerminationProtectionOutput, error)
}

// S3 is the subset of the S3 API cfnctl uses.
type S3 interface {
	HeadObject(context.Context, *s3.HeadObjectInput, ...func(*s3.Options)) (*s3.HeadObjectOutput, error)
	PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

// STS is the subset of the STS API cfnctl uses.
type STS interface {
	GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error)
}

// MaxInlineTemplate is the largest template CloudFormation accepts as TemplateBody.
const MaxInlineTemplate = 51200

// Deployer runs commands for one packaged stack.
type Deployer struct {
	CFN    CloudFormation
	S3     S3
	STS    STS
	Region string

	Manifest *manifest.Manifest
	// Dir is the directory the manifest's relative paths are resolved against.
	Dir string

	// Yes skips interactive confirmation.
	Yes bool
	In  io.Reader
	Out io.Writer

	Sleep func(time.Duration)
	Now   func() time.Time
	// PollInterval between status checks.
	PollInterval time.Duration

	account string
}

func (d *Deployer) sleep() {
	if d.Sleep != nil {
		d.Sleep(d.PollInterval)
		return
	}
	time.Sleep(d.PollInterval)
}

func (d *Deployer) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

func (d *Deployer) printf(format string, args ...any) {
	fmt.Fprintf(d.Out, format, args...)
}

// CheckIdentity refuses to continue when the credentials are for another account.
func (d *Deployer) CheckIdentity(ctx context.Context) error {
	id, err := d.STS.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return fmt.Errorf("checking AWS credentials: %w", err)
	}
	d.account = aws.ToString(id.Account)
	if want := d.Manifest.Account; want != "" && want != d.account {
		return fmt.Errorf("stack %s is pinned to account %s but credentials are for account %s (%s)",
			d.Manifest.StackName, want, d.account, aws.ToString(id.Arn))
	}
	if want := d.Manifest.Region; want != "" && want != d.Region {
		return fmt.Errorf("stack %s is pinned to region %s but the session is for %s", d.Manifest.StackName, want, d.Region)
	}
	return nil
}

func (d *Deployer) bucket() string {
	b := d.Manifest.AssetBucket
	if b == "" {
		b = manifest.DefaultAssetBucket
	}
	b = strings.ReplaceAll(b, "${AWS::AccountId}", d.account)
	return strings.ReplaceAll(b, "${AWS::Region}", d.Region)
}

func (d *Deployer) templateBody() ([]byte, error) {
	return os.ReadFile(filepath.Join(d.Dir, d.Manifest.Template))
}

// stack returns the deployed stack, or nil if it does not exist.
func (d *Deployer) stack(ctx context.Context) (*cfntypes.Stack, error) {
	out, err := d.CFN.DescribeStacks(ctx, &cfn.DescribeStacksInput{StackName: aws.String(d.Manifest.StackName)})
	if err != nil {
		if isNotFound(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(out.Stacks) == 0 {
		return nil, nil
	}
	return &out.Stacks[0], nil
}

func isNotFound(err error) bool {
	var ae smithy.APIError
	return errors.As(err, &ae) && ae.ErrorCode() == "ValidationError" && strings.Contains(ae.ErrorMessage(), "does not exist")
}

// Diff prints the semantic difference between the deployed and local templates.
func (d *Deployer) Diff(ctx context.Context) (bool, error) {
	local, err := d.templateBody()
	if err != nil {
		return false, err
	}
	var newT map[string]any
	if err := decode(local, &newT); err != nil {
		return false, err
	}
	st, err := d.stack(ctx)
	if err != nil {
		return false, err
	}
	oldT := map[string]any{}
	if st == nil || st.StackStatus == cfntypes.StackStatusReviewInProgress {
		d.printf("Stack %s does not exist yet; everything will be created.\n", d.Manifest.StackName)
	} else {
		out, err := d.CFN.GetTemplate(ctx, &cfn.GetTemplateInput{
			StackName:     aws.String(d.Manifest.StackName),
			TemplateStage: cfntypes.TemplateStageOriginal,
		})
		if err != nil {
			return false, err
		}
		if err := decode([]byte(aws.ToString(out.TemplateBody)), &oldT); err != nil {
			return false, fmt.Errorf("deployed template is not JSON (was it deployed by another tool?): %w", err)
		}
	}
	changes := tmpldiff.Diff(oldT, newT)
	d.printf("Stack %s\n", d.Manifest.StackName)
	tmpldiff.Print(d.Out, changes)
	return len(changes) > 0, nil
}

func decode(b []byte, v any) error {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	return dec.Decode(v)
}

// UploadAssets uploads packaged assets that aren't already in the asset bucket.
func (d *Deployer) UploadAssets(ctx context.Context) error {
	bucket := d.bucket()
	for _, a := range d.Manifest.Assets {
		_, err := d.S3.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(bucket), Key: aws.String(a.Key)})
		if err == nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join(d.Dir, a.File))
		if err != nil {
			return err
		}
		d.printf("Uploading %s -> s3://%s/%s\n", a.Label, bucket, a.Key)
		if _, err := d.S3.PutObject(ctx, &s3.PutObjectInput{
			Bucket: aws.String(bucket),
			Key:    aws.String(a.Key),
			Body:   bytes.NewReader(data),
		}); err != nil {
			return fmt.Errorf("uploading %s to s3://%s (run the bootstrap stack first?): %w", a.Label, bucket, err)
		}
	}
	return nil
}

func (d *Deployer) templateArgs(ctx context.Context) (body, url *string, err error) {
	b, err := d.templateBody()
	if err != nil {
		return nil, nil, err
	}
	if len(b) <= MaxInlineTemplate {
		return aws.String(string(b)), nil, nil
	}
	bucket := d.bucket()
	key := "templates/" + d.Manifest.TemplateSHA256 + ".json"
	if _, err := d.S3.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(bucket), Key: aws.String(key), Body: bytes.NewReader(b)}); err != nil {
		return nil, nil, fmt.Errorf("uploading template (%d bytes) to s3://%s: %w", len(b), bucket, err)
	}
	return nil, aws.String(fmt.Sprintf("https://%s.s3.%s.amazonaws.com/%s", bucket, d.Region, key)), nil
}

// ChangeSet is a created change set.
type ChangeSet struct {
	Name    string
	Type    cfntypes.ChangeSetType
	Changes []cfntypes.Change
	// Empty is true if CloudFormation found nothing to change.
	Empty bool
}

func (d *Deployer) createChangeSet(ctx context.Context) (*ChangeSet, error) {
	st, err := d.stack(ctx)
	if err != nil {
		return nil, err
	}
	cs := &ChangeSet{Type: cfntypes.ChangeSetTypeUpdate}
	if st == nil || st.StackStatus == cfntypes.StackStatusReviewInProgress {
		cs.Type = cfntypes.ChangeSetTypeCreate
	} else if st.StackStatus == cfntypes.StackStatusRollbackComplete {
		return nil, fmt.Errorf("stack %s is in ROLLBACK_COMPLETE (its creation failed) and must be destroyed before it can be deployed again", d.Manifest.StackName)
	} else if strings.HasSuffix(string(st.StackStatus), "_IN_PROGRESS") {
		return nil, fmt.Errorf("stack %s is busy (%s)", d.Manifest.StackName, st.StackStatus)
	}

	body, url, err := d.templateArgs(ctx)
	if err != nil {
		return nil, err
	}
	sha := d.Manifest.TemplateSHA256
	if len(sha) > 12 {
		sha = sha[:12]
	}
	cs.Name = fmt.Sprintf("rules-cfn-%s-%d", sha, d.now().Unix())
	in := &cfn.CreateChangeSetInput{
		StackName:     aws.String(d.Manifest.StackName),
		ChangeSetName: aws.String(cs.Name),
		ChangeSetType: cs.Type,
		TemplateBody:  body,
		TemplateURL:   url,
		Description:   aws.String("Created by rules_cfn cfnctl"),
	}
	if d.Manifest.RoleARN != "" {
		in.RoleARN = aws.String(d.Manifest.RoleARN)
	}
	for _, c := range d.Manifest.Capabilities {
		in.Capabilities = append(in.Capabilities, cfntypes.Capability(c))
	}
	for _, k := range sortedKeys(d.Manifest.Parameters) {
		in.Parameters = append(in.Parameters, cfntypes.Parameter{ParameterKey: aws.String(k), ParameterValue: aws.String(d.Manifest.Parameters[k])})
	}
	for _, k := range sortedKeys(d.Manifest.Tags) {
		in.Tags = append(in.Tags, cfntypes.Tag{Key: aws.String(k), Value: aws.String(d.Manifest.Tags[k])})
	}
	if _, err := d.CFN.CreateChangeSet(ctx, in); err != nil {
		return nil, fmt.Errorf("creating change set: %w", err)
	}

	for {
		out, err := d.CFN.DescribeChangeSet(ctx, &cfn.DescribeChangeSetInput{
			StackName:     aws.String(d.Manifest.StackName),
			ChangeSetName: aws.String(cs.Name),
		})
		if err != nil {
			return nil, err
		}
		switch out.Status {
		case cfntypes.ChangeSetStatusCreateComplete:
			cs.Changes = append(cs.Changes, out.Changes...)
			for next := out.NextToken; next != nil; {
				page, err := d.CFN.DescribeChangeSet(ctx, &cfn.DescribeChangeSetInput{
					StackName:     aws.String(d.Manifest.StackName),
					ChangeSetName: aws.String(cs.Name),
					NextToken:     next,
				})
				if err != nil {
					return nil, err
				}
				cs.Changes = append(cs.Changes, page.Changes...)
				next = page.NextToken
			}
			return cs, nil
		case cfntypes.ChangeSetStatusFailed:
			reason := aws.ToString(out.StatusReason)
			if strings.Contains(reason, "didn't contain changes") || strings.Contains(reason, "No updates are to be performed") {
				cs.Empty = true
				return cs, nil
			}
			return nil, fmt.Errorf("change set failed: %s", reason)
		}
		d.sleep()
	}
}

func (d *Deployer) printChangeSet(cs *ChangeSet) {
	if cs.Empty {
		d.printf("No changes to stack %s.\n", d.Manifest.StackName)
		return
	}
	verb := "update"
	if cs.Type == cfntypes.ChangeSetTypeCreate {
		verb = "create"
	}
	d.printf("Change set %s will %s stack %s:\n", cs.Name, verb, d.Manifest.StackName)
	for _, c := range cs.Changes {
		rc := c.ResourceChange
		if rc == nil {
			continue
		}
		line := fmt.Sprintf("  %-8s %-40s %s", rc.Action, aws.ToString(rc.LogicalResourceId), aws.ToString(rc.ResourceType))
		if rc.Replacement == cfntypes.ReplacementTrue {
			line += "  REPLACEMENT"
		} else if rc.Replacement == cfntypes.ReplacementConditional {
			line += "  (may be replaced)"
		}
		d.printf("%s\n", line)
	}
}

func (d *Deployer) cleanupChangeSet(ctx context.Context, cs *ChangeSet) error {
	if _, err := d.CFN.DeleteChangeSet(ctx, &cfn.DeleteChangeSetInput{
		StackName:     aws.String(d.Manifest.StackName),
		ChangeSetName: aws.String(cs.Name),
	}); err != nil {
		return err
	}
	if cs.Type != cfntypes.ChangeSetTypeCreate {
		return nil
	}
	// A CREATE change set leaves an empty REVIEW_IN_PROGRESS stack behind.
	st, err := d.stack(ctx)
	if err != nil || st == nil || st.StackStatus != cfntypes.StackStatusReviewInProgress {
		return err
	}
	_, err = d.CFN.DeleteStack(ctx, &cfn.DeleteStackInput{StackName: aws.String(d.Manifest.StackName)})
	return err
}

// Plan is a dry run: it creates a change set, prints it and deletes it.
// It returns true if the stack would change.
func (d *Deployer) Plan(ctx context.Context, keep bool) (bool, error) {
	cs, err := d.createChangeSet(ctx)
	if err != nil {
		return false, err
	}
	d.printChangeSet(cs)
	if keep && !cs.Empty {
		d.printf("Keeping change set %s for review.\n", cs.Name)
		return true, nil
	}
	return !cs.Empty, d.cleanupChangeSet(ctx, cs)
}

func (d *Deployer) confirm(prompt string) (bool, error) {
	if d.Yes {
		return true, nil
	}
	if d.In == nil {
		return false, fmt.Errorf("refusing to %s without confirmation; pass --yes", prompt)
	}
	d.printf("Do you want to %s? [y/N] ", prompt)
	line, err := bufio.NewReader(d.In).ReadString('\n')
	if err != nil && err != io.EOF {
		return false, err
	}
	a := strings.ToLower(strings.TrimSpace(line))
	return a == "y" || a == "yes", nil
}

// Deploy uploads assets, creates a change set and, once confirmed, executes it.
func (d *Deployer) Deploy(ctx context.Context) error {
	if err := d.UploadAssets(ctx); err != nil {
		return err
	}
	cs, err := d.createChangeSet(ctx)
	if err != nil {
		return err
	}
	d.printChangeSet(cs)
	if cs.Empty {
		return d.cleanupChangeSet(ctx, cs)
	}
	ok, err := d.confirm("deploy these changes")
	if err != nil || !ok {
		if cerr := d.cleanupChangeSet(ctx, cs); cerr != nil && err == nil {
			err = cerr
		}
		if err == nil {
			d.printf("Not deploying.\n")
		}
		return err
	}
	start := d.now()
	if _, err := d.CFN.ExecuteChangeSet(ctx, &cfn.ExecuteChangeSetInput{
		StackName:     aws.String(d.Manifest.StackName),
		ChangeSetName: aws.String(cs.Name),
	}); err != nil {
		return fmt.Errorf("executing change set: %w", err)
	}
	st, err := d.wait(ctx, start)
	if err != nil {
		return err
	}
	switch st {
	case cfntypes.StackStatusCreateComplete, cfntypes.StackStatusUpdateComplete, cfntypes.StackStatusImportComplete:
	default:
		return fmt.Errorf("deploy of %s failed: stack is %s", d.Manifest.StackName, st)
	}
	if d.Manifest.TerminationProtection {
		if _, err := d.CFN.UpdateTerminationProtection(ctx, &cfn.UpdateTerminationProtectionInput{
			StackName:                   aws.String(d.Manifest.StackName),
			EnableTerminationProtection: aws.Bool(true),
		}); err != nil {
			return err
		}
	}
	return d.printOutputs(ctx)
}

func (d *Deployer) printOutputs(ctx context.Context) error {
	st, err := d.stack(ctx)
	if err != nil || st == nil || len(st.Outputs) == 0 {
		return err
	}
	d.printf("Outputs:\n")
	outs := append([]cfntypes.Output(nil), st.Outputs...)
	sort.Slice(outs, func(i, j int) bool { return aws.ToString(outs[i].OutputKey) < aws.ToString(outs[j].OutputKey) })
	for _, o := range outs {
		d.printf("  %s = %s\n", aws.ToString(o.OutputKey), aws.ToString(o.OutputValue))
	}
	return nil
}

// Destroy deletes the stack.
func (d *Deployer) Destroy(ctx context.Context, force bool) error {
	st, err := d.stack(ctx)
	if err != nil {
		return err
	}
	if st == nil {
		d.printf("Stack %s does not exist.\n", d.Manifest.StackName)
		return nil
	}
	if aws.ToBool(st.EnableTerminationProtection) {
		if !force {
			return fmt.Errorf("stack %s has termination protection enabled; pass --force to disable it and delete", d.Manifest.StackName)
		}
	}
	ok, err := d.confirm("delete stack " + d.Manifest.StackName)
	if err != nil || !ok {
		return err
	}
	if aws.ToBool(st.EnableTerminationProtection) {
		if _, err := d.CFN.UpdateTerminationProtection(ctx, &cfn.UpdateTerminationProtectionInput{
			StackName:                   aws.String(d.Manifest.StackName),
			EnableTerminationProtection: aws.Bool(false),
		}); err != nil {
			return err
		}
	}
	start := d.now()
	if _, err := d.CFN.DeleteStack(ctx, &cfn.DeleteStackInput{StackName: st.StackId}); err != nil {
		return err
	}
	// Track by stack ID: once deleted, the name no longer resolves.
	final, err := d.waitID(ctx, aws.ToString(st.StackId), start)
	if err != nil {
		return err
	}
	if final != cfntypes.StackStatusDeleteComplete {
		return fmt.Errorf("delete of %s failed: stack is %s", d.Manifest.StackName, final)
	}
	return nil
}

func (d *Deployer) wait(ctx context.Context, since time.Time) (cfntypes.StackStatus, error) {
	return d.waitID(ctx, d.Manifest.StackName, since)
}

// waitID polls the stack until it leaves *_IN_PROGRESS, streaming new events.
func (d *Deployer) waitID(ctx context.Context, id string, since time.Time) (cfntypes.StackStatus, error) {
	seen := map[string]bool{}
	for {
		ev, err := d.CFN.DescribeStackEvents(ctx, &cfn.DescribeStackEventsInput{StackName: aws.String(id)})
		if err != nil {
			return "", err
		}
		// Events come newest first; print oldest first.
		for i := len(ev.StackEvents) - 1; i >= 0; i-- {
			e := ev.StackEvents[i]
			eid := aws.ToString(e.EventId)
			if seen[eid] || (e.Timestamp != nil && e.Timestamp.Before(since)) {
				continue
			}
			seen[eid] = true
			line := fmt.Sprintf("  %s  %-28s %-40s %s", e.Timestamp.Format("15:04:05"), e.ResourceStatus, aws.ToString(e.LogicalResourceId), aws.ToString(e.ResourceType))
			if r := aws.ToString(e.ResourceStatusReason); r != "" && strings.HasSuffix(string(e.ResourceStatus), "FAILED") {
				line += "\n      " + r
			}
			d.printf("%s\n", line)
		}
		out, err := d.CFN.DescribeStacks(ctx, &cfn.DescribeStacksInput{StackName: aws.String(id)})
		if err != nil {
			return "", err
		}
		if len(out.Stacks) == 0 {
			return cfntypes.StackStatusDeleteComplete, nil
		}
		st := out.Stacks[0].StackStatus
		if !strings.HasSuffix(string(st), "_IN_PROGRESS") {
			return st, nil
		}
		d.sleep()
	}
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
