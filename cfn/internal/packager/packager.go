// Package packager turns the raw template produced by Starlark into the final,
// deployable template: asset placeholders are resolved to content-addressed S3
// locations, strict schema validation runs, capabilities are inferred, and a
// manifest describing the stack is written.
package packager

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
	"github.com/dastbe/rules_cdk/cfn/internal/validate"
)

// AssetFile is one input file of an asset.
type AssetFile struct {
	Label     string
	Packaging string
	// Rel is the file's path inside a zip asset (relative to the label's package).
	Rel  string
	Path string
}

// Options configures Package.
type Options struct {
	RawTemplate []byte
	Config      manifest.Config
	AssetFiles  []AssetFile
	Schemas     *validate.Schemas
	// OutTemplate, OutManifest and OutAssetsDir are the outputs. The manifest
	// refers to the other two relative to its own directory.
	OutTemplate  string
	OutManifest  string
	OutAssetsDir string
}

// Decode parses JSON keeping numbers exact.
func Decode(b []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

// Encode renders JSON deterministically (sorted keys, two-space indent, no HTML escaping).
func Encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	e := json.NewEncoder(&buf)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// zipEpoch is the fixed modification time for zip entries (the zip format's minimum).
var zipEpoch = time.Date(1980, 1, 1, 0, 0, 0, 0, time.UTC)

// DeterministicZip zips files at their given names with fixed metadata.
func DeterministicZip(files map[string]string) ([]byte, error) {
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, n := range names {
		st, err := os.Stat(files[n])
		if err != nil {
			return nil, err
		}
		mode := os.FileMode(0o644)
		if st.Mode()&0o111 != 0 {
			mode = 0o755
		}
		h := &zip.FileHeader{Name: n, Method: zip.Deflate, Modified: zipEpoch}
		h.SetMode(mode)
		w, err := zw.CreateHeader(h)
		if err != nil {
			return nil, err
		}
		f, err := os.Open(files[n])
		if err != nil {
			return nil, err
		}
		_, err = io.Copy(w, f)
		f.Close()
		if err != nil {
			return nil, err
		}
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

type packed struct {
	asset manifest.Asset
	data  []byte
}

func packAssets(files []AssetFile) (map[string]*packed, error) {
	byLabel := map[string][]AssetFile{}
	for _, f := range files {
		byLabel[f.Label] = append(byLabel[f.Label], f)
	}
	out := map[string]*packed{}
	for label, fs := range byLabel {
		var data []byte
		ext := ".zip"
		switch fs[0].Packaging {
		case "zip":
			m := map[string]string{}
			for _, f := range fs {
				m[f.Rel] = f.Path
			}
			var err error
			if data, err = DeterministicZip(m); err != nil {
				return nil, fmt.Errorf("asset %s: %w", label, err)
			}
		case "file":
			if len(fs) != 1 {
				return nil, fmt.Errorf("asset %s: packaging \"file\" needs exactly one file, got %d", label, len(fs))
			}
			var err error
			if data, err = os.ReadFile(fs[0].Path); err != nil {
				return nil, err
			}
			ext = path.Ext(fs[0].Rel)
		default:
			return nil, fmt.Errorf("asset %s: unknown packaging %q", label, fs[0].Packaging)
		}
		sum := sha256.Sum256(data)
		h := hex.EncodeToString(sum[:])
		out[label] = &packed{
			asset: manifest.Asset{Label: label, Packaging: fs[0].Packaging, SHA256: h, Key: "assets/" + h + ext, File: ""},
			data:  data,
		}
	}
	return out, nil
}

// resolveAssets replaces {"__cfn_asset__": {"label", "part"}} placeholders in place.
func resolveAssets(v any, assets map[string]*packed, bucket string) (any, error) {
	switch x := v.(type) {
	case map[string]any:
		if ph, ok := x["__cfn_asset__"].(map[string]any); ok && len(x) == 1 {
			label, _ := ph["label"].(string)
			part, _ := ph["part"].(string)
			a, ok := assets[label]
			if !ok {
				return nil, fmt.Errorf("asset placeholder for %s has no packaged files (is it in the cfn_stack's assets?)", label)
			}
			switch part {
			case "bucket":
				return sub(bucket), nil
			case "key":
				return a.asset.Key, nil
			case "s3_uri":
				return sub("s3://" + bucket + "/" + a.asset.Key), nil
			}
			return nil, fmt.Errorf("asset placeholder for %s: unknown part %q", label, part)
		}
		for k, e := range x {
			r, err := resolveAssets(e, assets, bucket)
			if err != nil {
				return nil, err
			}
			x[k] = r
		}
	case []any:
		for i, e := range x {
			r, err := resolveAssets(e, assets, bucket)
			if err != nil {
				return nil, err
			}
			x[i] = r
		}
	}
	return v, nil
}

func sub(s string) any {
	if strings.Contains(s, "${") {
		return map[string]any{"Fn::Sub": s}
	}
	return s
}

var namedIAM = map[string][]string{
	"AWS::IAM::Role":            {"RoleName"},
	"AWS::IAM::User":            {"UserName"},
	"AWS::IAM::Group":           {"GroupName"},
	"AWS::IAM::ManagedPolicy":   {"ManagedPolicyName"},
	"AWS::IAM::InstanceProfile": {"InstanceProfileName"},
}

// InferCapabilities returns the capabilities CloudFormation will demand for tmpl.
func InferCapabilities(tmpl map[string]any) []string {
	caps := map[string]bool{}
	resources, _ := tmpl["Resources"].(map[string]any)
	for _, r := range resources {
		rm, _ := r.(map[string]any)
		tn, _ := rm["Type"].(string)
		if strings.HasPrefix(tn, "AWS::IAM::") {
			caps["CAPABILITY_IAM"] = true
			props, _ := rm["Properties"].(map[string]any)
			for _, p := range namedIAM[tn] {
				if _, ok := props[p]; ok {
					caps["CAPABILITY_NAMED_IAM"] = true
				}
			}
		}
		if tn == "AWS::CloudFormation::Stack" || tn == "AWS::Serverless::Application" {
			caps["CAPABILITY_AUTO_EXPAND"] = true
		}
	}
	if _, ok := tmpl["Transform"]; ok {
		caps["CAPABILITY_AUTO_EXPAND"] = true
	}
	out := make([]string, 0, len(caps))
	for c := range caps {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// MaxTemplateSize is CloudFormation's limit for templates uploaded via S3.
const MaxTemplateSize = 1 << 20

// Package runs the whole packaging step.
func Package(o Options) (*manifest.Manifest, error) {
	raw, err := Decode(o.RawTemplate)
	if err != nil {
		return nil, fmt.Errorf("parsing raw template: %w", err)
	}
	tmpl, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("template must be a JSON object")
	}

	assets, err := packAssets(o.AssetFiles)
	if err != nil {
		return nil, err
	}
	bucket := o.Config.AssetBucket
	if bucket == "" {
		bucket = manifest.DefaultAssetBucket
	}
	if _, err := resolveAssets(tmpl, assets, bucket); err != nil {
		return nil, err
	}

	if o.Schemas != nil {
		problems, err := o.Schemas.Template(tmpl)
		if err != nil {
			return nil, err
		}
		if len(problems) > 0 {
			return nil, fmt.Errorf("template fails schema validation:\n  %s", strings.Join(problems, "\n  "))
		}
	}

	body, err := Encode(tmpl)
	if err != nil {
		return nil, err
	}
	if len(body) > MaxTemplateSize {
		return nil, fmt.Errorf("template is %d bytes; CloudFormation allows at most %d", len(body), MaxTemplateSize)
	}
	sum := sha256.Sum256(body)

	m := &manifest.Manifest{
		Config:         o.Config,
		TemplateSHA256: hex.EncodeToString(sum[:]),
		TemplateSize:   len(body),
	}
	capSet := map[string]bool{}
	for _, c := range append(InferCapabilities(tmpl), o.Config.Capabilities...) {
		capSet[c] = true
	}
	m.Capabilities = nil
	for c := range capSet {
		m.Capabilities = append(m.Capabilities, c)
	}
	sort.Strings(m.Capabilities)
	if m.AssetBucket == "" && len(assets) > 0 {
		m.AssetBucket = manifest.DefaultAssetBucket
	}

	manifestDir := filepath.Dir(o.OutManifest)
	rel := func(p string) (string, error) { return filepath.Rel(manifestDir, p) }
	if m.Template, err = rel(o.OutTemplate); err != nil {
		return nil, err
	}
	if err := os.WriteFile(o.OutTemplate, body, 0o644); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(o.OutAssetsDir, 0o755); err != nil {
		return nil, err
	}
	labels := make([]string, 0, len(assets))
	for l := range assets {
		labels = append(labels, l)
	}
	sort.Strings(labels)
	for _, l := range labels {
		a := assets[l]
		out := filepath.Join(o.OutAssetsDir, path.Base(a.asset.Key))
		if err := os.WriteFile(out, a.data, 0o644); err != nil {
			return nil, err
		}
		if a.asset.File, err = rel(out); err != nil {
			return nil, err
		}
		m.Assets = append(m.Assets, a.asset)
	}
	mb, err := Encode(m)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(o.OutManifest, mb, 0o644); err != nil {
		return nil, err
	}
	return m, nil
}
