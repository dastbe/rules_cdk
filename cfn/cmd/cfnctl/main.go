// cfnctl materializes and deploys CloudFormation stacks built by rules_cfn.
//
//	cfnctl package  build-time: raw template -> final template + manifest + assets
//	cfnctl diff     compare the built template with the deployed stack
//	cfnctl plan     dry run: create, describe and delete a change set
//	cfnctl deploy   create and execute a change set, streaming stack events
//	cfnctl destroy  delete the stack
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
	"github.com/dastbe/rules_cdk/cfn/internal/packager"
	"github.com/dastbe/rules_cdk/cfn/internal/validate"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: cfnctl <package|diff|plan|deploy|destroy> [flags]")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	var err error
	code := 0
	switch cmd {
	case "package":
		err = runPackage(args)
	case "diff", "plan", "deploy", "destroy":
		code, err = runRemote(context.Background(), cmd, args)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "cfnctl %s: %v\n", cmd, err)
		os.Exit(1)
	}
	os.Exit(code)
}

func readLines(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 1<<20)
	for s.Scan() {
		if l := s.Text(); l != "" {
			out = append(out, l)
		}
	}
	return out, s.Err()
}

func runPackage(args []string) error {
	fs := flag.NewFlagSet("package", flag.ExitOnError)
	raw := fs.String("raw", "", "raw template JSON produced by Starlark")
	config := fs.String("config", "", "stack config JSON")
	schemaList := fs.String("schema-list", "", "file listing registry schema JSON paths, one per line")
	assetList := fs.String("asset-list", "", "file listing asset inputs as label<TAB>packaging<TAB>relpath<TAB>path")
	outTemplate := fs.String("out-template", "", "")
	outManifest := fs.String("out-manifest", "", "")
	outAssets := fs.String("out-assets", "", "")
	fs.Parse(args)

	rawBytes, err := os.ReadFile(*raw)
	if err != nil {
		return err
	}
	cfg, err := manifest.ReadConfig(*config)
	if err != nil {
		return err
	}
	schemaFiles, err := readLines(*schemaList)
	if err != nil {
		return err
	}
	assetLines, err := readLines(*assetList)
	if err != nil {
		return err
	}
	var assets []packager.AssetFile
	for _, l := range assetLines {
		p := strings.Split(l, "\t")
		if len(p) != 4 {
			return fmt.Errorf("bad asset line %q", l)
		}
		assets = append(assets, packager.AssetFile{Label: p[0], Packaging: p[1], Rel: p[2], Path: p[3]})
	}
	_, err = packager.Package(packager.Options{
		RawTemplate:  rawBytes,
		Config:       *cfg,
		AssetFiles:   assets,
		Schemas:      validate.NewSchemas(schemaFiles),
		OutTemplate:  *outTemplate,
		OutManifest:  *outManifest,
		OutAssetsDir: *outAssets,
	})
	return err
}
