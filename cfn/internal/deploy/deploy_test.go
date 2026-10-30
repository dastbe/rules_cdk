package deploy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	cfn "github.com/aws/aws-sdk-go-v2/service/cloudformation"
	cfntypes "github.com/aws/aws-sdk-go-v2/service/cloudformation/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"

	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
)

// fakeCFN is a tiny in-memory CloudFormation: one stack, change sets that
// compare whole templates, and synchronous execution.
type fakeCFN struct {
	stack      *cfntypes.Stack
	template   string
	changeSets map[string]*cfn.CreateChangeSetInput
	events     []cfntypes.StackEvent
	executed   int
	deleted    bool
	clock      time.Time
}

func newFake() *fakeCFN {
	return &fakeCFN{changeSets: map[string]*cfn.CreateChangeSetInput{}, clock: time.Unix(1700000000, 0)}
}

func notFound(name string) error {
	return &smithy.GenericAPIError{Code: "ValidationError", Message: fmt.Sprintf("Stack with id %s does not exist", name)}
}

func (f *fakeCFN) live(name string) bool {
	return f.stack != nil && (aws.ToString(f.stack.StackId) == name || (aws.ToString(f.stack.StackName) == name && f.stack.StackStatus != cfntypes.StackStatusDeleteComplete))
}

func (f *fakeCFN) event(status cfntypes.ResourceStatus) {
	f.clock = f.clock.Add(time.Second)
	f.events = append([]cfntypes.StackEvent{{
		EventId:           aws.String(fmt.Sprint(len(f.events))),
		Timestamp:         aws.Time(f.clock),
		ResourceStatus:    status,
		LogicalResourceId: f.stack.StackName,
		ResourceType:      aws.String("AWS::CloudFormation::Stack"),
	}}, f.events...)
}

func (f *fakeCFN) DescribeStacks(_ context.Context, in *cfn.DescribeStacksInput, _ ...func(*cfn.Options)) (*cfn.DescribeStacksOutput, error) {
	if !f.live(aws.ToString(in.StackName)) {
		return nil, notFound(aws.ToString(in.StackName))
	}
	return &cfn.DescribeStacksOutput{Stacks: []cfntypes.Stack{*f.stack}}, nil
}

func (f *fakeCFN) GetTemplate(_ context.Context, in *cfn.GetTemplateInput, _ ...func(*cfn.Options)) (*cfn.GetTemplateOutput, error) {
	return &cfn.GetTemplateOutput{TemplateBody: aws.String(f.template)}, nil
}

func (f *fakeCFN) CreateChangeSet(_ context.Context, in *cfn.CreateChangeSetInput, _ ...func(*cfn.Options)) (*cfn.CreateChangeSetOutput, error) {
	if in.ChangeSetType == cfntypes.ChangeSetTypeCreate && !f.live(aws.ToString(in.StackName)) {
		f.stack = &cfntypes.Stack{
			StackName:   in.StackName,
			StackId:     aws.String("arn:stack/" + aws.ToString(in.StackName) + "/1"),
			StackStatus: cfntypes.StackStatusReviewInProgress,
		}
	}
	f.changeSets[aws.ToString(in.ChangeSetName)] = in
	return &cfn.CreateChangeSetOutput{}, nil
}

func (f *fakeCFN) DescribeChangeSet(_ context.Context, in *cfn.DescribeChangeSetInput, _ ...func(*cfn.Options)) (*cfn.DescribeChangeSetOutput, error) {
	cs := f.changeSets[aws.ToString(in.ChangeSetName)]
	if aws.ToString(cs.TemplateBody) == f.template {
		return &cfn.DescribeChangeSetOutput{Status: cfntypes.ChangeSetStatusFailed, StatusReason: aws.String("The submitted information didn't contain changes.")}, nil
	}
	action := cfntypes.ChangeActionModify
	if cs.ChangeSetType == cfntypes.ChangeSetTypeCreate {
		action = cfntypes.ChangeActionAdd
	}
	return &cfn.DescribeChangeSetOutput{
		Status: cfntypes.ChangeSetStatusCreateComplete,
		Changes: []cfntypes.Change{{ResourceChange: &cfntypes.ResourceChange{
			Action: action, LogicalResourceId: aws.String("Bucket"), ResourceType: aws.String("AWS::S3::Bucket"),
		}}},
	}, nil
}

func (f *fakeCFN) DeleteChangeSet(_ context.Context, in *cfn.DeleteChangeSetInput, _ ...func(*cfn.Options)) (*cfn.DeleteChangeSetOutput, error) {
	delete(f.changeSets, aws.ToString(in.ChangeSetName))
	return &cfn.DeleteChangeSetOutput{}, nil
}

func (f *fakeCFN) ExecuteChangeSet(_ context.Context, in *cfn.ExecuteChangeSetInput, _ ...func(*cfn.Options)) (*cfn.ExecuteChangeSetOutput, error) {
	cs := f.changeSets[aws.ToString(in.ChangeSetName)]
	f.executed++
	f.template = aws.ToString(cs.TemplateBody)
	if cs.ChangeSetType == cfntypes.ChangeSetTypeCreate {
		f.stack.StackStatus = cfntypes.StackStatusCreateComplete
	} else {
		f.stack.StackStatus = cfntypes.StackStatusUpdateComplete
	}
	f.stack.Outputs = []cfntypes.Output{{OutputKey: aws.String("Url"), OutputValue: aws.String("https://example")}}
	f.event(cfntypes.ResourceStatus(f.stack.StackStatus))
	delete(f.changeSets, aws.ToString(in.ChangeSetName))
	return &cfn.ExecuteChangeSetOutput{}, nil
}

func (f *fakeCFN) DescribeStackEvents(_ context.Context, in *cfn.DescribeStackEventsInput, _ ...func(*cfn.Options)) (*cfn.DescribeStackEventsOutput, error) {
	return &cfn.DescribeStackEventsOutput{StackEvents: f.events}, nil
}

func (f *fakeCFN) DeleteStack(_ context.Context, in *cfn.DeleteStackInput, _ ...func(*cfn.Options)) (*cfn.DeleteStackOutput, error) {
	f.deleted = true
	f.stack.StackStatus = cfntypes.StackStatusDeleteComplete
	f.template = ""
	f.event(cfntypes.ResourceStatusDeleteComplete)
	return &cfn.DeleteStackOutput{}, nil
}

func (f *fakeCFN) UpdateTerminationProtection(_ context.Context, in *cfn.UpdateTerminationProtectionInput, _ ...func(*cfn.Options)) (*cfn.UpdateTerminationProtectionOutput, error) {
	f.stack.EnableTerminationProtection = in.EnableTerminationProtection
	return &cfn.UpdateTerminationProtectionOutput{}, nil
}

type fakeS3 struct{ objects map[string][]byte }

func (f *fakeS3) HeadObject(_ context.Context, in *s3.HeadObjectInput, _ ...func(*s3.Options)) (*s3.HeadObjectOutput, error) {
	if _, ok := f.objects[aws.ToString(in.Bucket)+"/"+aws.ToString(in.Key)]; ok {
		return &s3.HeadObjectOutput{}, nil
	}
	return nil, &smithy.GenericAPIError{Code: "NotFound"}
}

func (f *fakeS3) PutObject(_ context.Context, in *s3.PutObjectInput, _ ...func(*s3.Options)) (*s3.PutObjectOutput, error) {
	b, _ := io.ReadAll(in.Body)
	f.objects[aws.ToString(in.Bucket)+"/"+aws.ToString(in.Key)] = b
	return &s3.PutObjectOutput{}, nil
}

type fakeSTS struct{ account string }

func (f fakeSTS) GetCallerIdentity(context.Context, *sts.GetCallerIdentityInput, ...func(*sts.Options)) (*sts.GetCallerIdentityOutput, error) {
	return &sts.GetCallerIdentityOutput{Account: aws.String(f.account), Arn: aws.String("arn:aws:iam::" + f.account + ":user/me")}, nil
}

type env struct {
	d   *Deployer
	cfn *fakeCFN
	s3  *fakeS3
	out *bytes.Buffer
	dir string
}

func setup(t *testing.T, template string) *env {
	t.Helper()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "s.template.json"), []byte(template), 0o644)
	os.MkdirAll(filepath.Join(dir, "s.assets"), 0o755)
	os.WriteFile(filepath.Join(dir, "s.assets", "abc.zip"), []byte("zip"), 0o644)
	m := &manifest.Manifest{
		Config:         manifest.Config{StackName: "s", Account: "111111111111", Region: "us-east-1"},
		Template:       "s.template.json",
		TemplateSHA256: "0123456789abcdef",
		Assets:         []manifest.Asset{{Label: "//fn:code", Key: "assets/abc.zip", File: "s.assets/abc.zip"}},
	}
	e := &env{cfn: newFake(), s3: &fakeS3{objects: map[string][]byte{}}, out: &bytes.Buffer{}, dir: dir}
	e.d = &Deployer{
		CFN: e.cfn, S3: e.s3, STS: fakeSTS{"111111111111"}, Region: "us-east-1",
		Manifest: m, Dir: dir, Yes: true, Out: e.out,
		Sleep: func(time.Duration) {}, Now: func() time.Time { return e.cfn.clock },
	}
	if err := e.d.CheckIdentity(context.Background()); err != nil {
		t.Fatal(err)
	}
	return e
}

func (e *env) setTemplate(t string) {
	os.WriteFile(filepath.Join(e.dir, "s.template.json"), []byte(t), 0o644)
}

const t1 = `{"Resources": {"Bucket": {"Type": "AWS::S3::Bucket"}}}`
const t2 = `{"Resources": {"Bucket": {"Type": "AWS::S3::Bucket", "Properties": {"BucketName": "b"}}}}`

func TestPlanNewStackLeavesNothingBehind(t *testing.T) {
	e := setup(t, t1)
	changed, err := e.d.Plan(context.Background(), false)
	if err != nil || !changed {
		t.Fatalf("Plan = %v, %v", changed, err)
	}
	if len(e.cfn.changeSets) != 0 || !e.cfn.deleted || e.cfn.executed != 0 {
		t.Errorf("plan left state behind: changeSets=%d deleted=%v executed=%d", len(e.cfn.changeSets), e.cfn.deleted, e.cfn.executed)
	}
	if len(e.s3.objects) != 0 {
		t.Errorf("plan uploaded assets: %v", e.s3.objects)
	}
	if !strings.Contains(e.out.String(), "will create stack s") {
		t.Errorf("output:\n%s", e.out)
	}
}

func TestDeployLifecycle(t *testing.T) {
	ctx := context.Background()
	e := setup(t, t1)
	if err := e.d.Deploy(ctx); err != nil {
		t.Fatal(err)
	}
	if e.cfn.stack.StackStatus != cfntypes.StackStatusCreateComplete || e.cfn.executed != 1 {
		t.Fatalf("stack = %s, executed = %d", e.cfn.stack.StackStatus, e.cfn.executed)
	}
	if _, ok := e.s3.objects["rules-cfn-assets-111111111111-us-east-1/assets/abc.zip"]; !ok {
		t.Errorf("asset not uploaded: %v", e.s3.objects)
	}
	if !strings.Contains(e.out.String(), "Url = https://example") {
		t.Errorf("outputs not printed:\n%s", e.out)
	}

	// Redeploying the same template is a no-op.
	e.out.Reset()
	if err := e.d.Deploy(ctx); err != nil {
		t.Fatal(err)
	}
	if e.cfn.executed != 1 || !strings.Contains(e.out.String(), "No changes") {
		t.Errorf("redeploy executed=%d output:\n%s", e.cfn.executed, e.out)
	}

	// Diff shows the property change.
	e.setTemplate(t2)
	e.out.Reset()
	changed, err := e.d.Diff(ctx)
	if err != nil || !changed {
		t.Fatalf("Diff = %v, %v", changed, err)
	}
	if !strings.Contains(e.out.String(), "[~] Bucket (AWS::S3::Bucket)") || !strings.Contains(e.out.String(), `Properties: (absent) -> {"BucketName":"b"}`) {
		t.Errorf("diff output:\n%s", e.out)
	}

	if err := e.d.Deploy(ctx); err != nil {
		t.Fatal(err)
	}
	if e.cfn.stack.StackStatus != cfntypes.StackStatusUpdateComplete {
		t.Errorf("stack = %s", e.cfn.stack.StackStatus)
	}

	// Termination protection blocks destroy unless forced.
	e.cfn.stack.EnableTerminationProtection = aws.Bool(true)
	if err := e.d.Destroy(ctx, false); err == nil || !strings.Contains(err.Error(), "termination protection") {
		t.Fatalf("Destroy without force = %v", err)
	}
	if err := e.d.Destroy(ctx, true); err != nil {
		t.Fatal(err)
	}
	if e.cfn.stack.StackStatus != cfntypes.StackStatusDeleteComplete {
		t.Errorf("stack = %s", e.cfn.stack.StackStatus)
	}
}

func TestDeployNeedsConfirmation(t *testing.T) {
	e := setup(t, t1)
	e.d.Yes = false
	err := e.d.Deploy(context.Background())
	if err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Fatalf("Deploy = %v", err)
	}
	if e.cfn.executed != 0 || len(e.cfn.changeSets) != 0 {
		t.Errorf("executed=%d changeSets=%d", e.cfn.executed, len(e.cfn.changeSets))
	}

	e.d.In = strings.NewReader("n\n")
	if err := e.d.Deploy(context.Background()); err != nil || e.cfn.executed != 0 {
		t.Fatalf("Deploy declined = %v, executed=%d", err, e.cfn.executed)
	}
	e.d.In = strings.NewReader("y\n")
	if err := e.d.Deploy(context.Background()); err != nil || e.cfn.executed != 1 {
		t.Fatalf("Deploy accepted = %v, executed=%d", err, e.cfn.executed)
	}
}

func TestAccountGuard(t *testing.T) {
	e := setup(t, t1)
	e.d.STS = fakeSTS{"222222222222"}
	err := e.d.CheckIdentity(context.Background())
	if err == nil || !strings.Contains(err.Error(), "pinned to account 111111111111") {
		t.Fatalf("CheckIdentity = %v", err)
	}
}

func TestLargeTemplateGoesThroughS3(t *testing.T) {
	e := setup(t, "")
	big := map[string]any{"Resources": map[string]any{"Bucket": map[string]any{"Type": "AWS::S3::Bucket", "Metadata": map[string]any{"Pad": strings.Repeat("x", MaxInlineTemplate)}}}}
	b, _ := json.Marshal(big)
	e.setTemplate(string(b))
	body, url, err := e.d.templateArgs(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if body != nil || !strings.HasPrefix(aws.ToString(url), "https://rules-cfn-assets-111111111111-us-east-1.s3.us-east-1.amazonaws.com/templates/") {
		t.Fatalf("body=%v url=%v", body != nil, aws.ToString(url))
	}
}
