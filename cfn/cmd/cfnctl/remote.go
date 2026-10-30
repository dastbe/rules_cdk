package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/cloudformation"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"

	"github.com/dastbe/rules_cdk/cfn/internal/deploy"
	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
)

func runRemote(ctx context.Context, cmd string, args []string) (int, error) {
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	manifestPath := fs.String("manifest", "", "stack manifest written by `cfnctl package`")
	profile := fs.String("profile", "", "AWS shared config profile")
	region := fs.String("region", "", "AWS region (default: the manifest's region, then the SDK's default chain)")
	yes := fs.Bool("yes", false, "deploy/destroy: don't ask for confirmation")
	keep := fs.Bool("keep", false, "plan: keep the change set for review instead of deleting it")
	force := fs.Bool("force", false, "destroy: disable termination protection first")
	detailed := fs.Bool("detailed-exitcode", false, "diff/plan: exit 2 when there are changes")
	fs.Parse(args)

	m, err := manifest.Read(*manifestPath)
	if err != nil {
		return 1, err
	}
	r := m.Region
	if *region != "" {
		if r != "" && r != *region {
			return 1, fmt.Errorf("stack %s is pinned to region %s; --region=%s conflicts", m.StackName, r, *region)
		}
		r = *region
	}
	var opts []func(*config.LoadOptions) error
	if r != "" {
		opts = append(opts, config.WithRegion(r))
	}
	if *profile != "" {
		opts = append(opts, config.WithSharedConfigProfile(*profile))
	}
	cfg, err := config.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return 1, err
	}
	if cfg.Region == "" {
		return 1, fmt.Errorf("no AWS region: set region on the cfn_stack, pass --region, or set AWS_REGION")
	}

	d := &deploy.Deployer{
		CFN:          cloudformation.NewFromConfig(cfg),
		S3:           s3.NewFromConfig(cfg),
		STS:          sts.NewFromConfig(cfg),
		Region:       cfg.Region,
		Manifest:     m,
		Dir:          filepath.Dir(*manifestPath),
		Yes:          *yes,
		Out:          os.Stdout,
		PollInterval: 3e9,
	}
	if st, err := os.Stdin.Stat(); err == nil && st.Mode()&os.ModeCharDevice != 0 {
		d.In = os.Stdin // only prompt when a person is at the terminal
	}
	if err := d.CheckIdentity(ctx); err != nil {
		return 1, err
	}

	changed := false
	switch cmd {
	case "diff":
		changed, err = d.Diff(ctx)
	case "plan":
		changed, err = d.Plan(ctx, *keep)
	case "deploy":
		err = d.Deploy(ctx)
	case "destroy":
		err = d.Destroy(ctx, *force)
	}
	if err != nil {
		return 1, err
	}
	if changed && *detailed {
		return 2, nil
	}
	return 0, nil
}
