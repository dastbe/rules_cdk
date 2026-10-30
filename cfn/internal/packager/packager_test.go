package packager

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/dastbe/rules_cdk/cfn/internal/manifest"
)

func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestDeterministicZip(t *testing.T) {
	dir := t.TempDir()
	a := write(t, dir, "a.js", "a")
	b := write(t, dir, "b.js", "b")
	z1, err := DeterministicZip(map[string]string{"a.js": a, "lib/b.js": b})
	if err != nil {
		t.Fatal(err)
	}
	os.Chtimes(a, zipEpoch.AddDate(10, 0, 0), zipEpoch.AddDate(10, 0, 0))
	z2, err := DeterministicZip(map[string]string{"lib/b.js": b, "a.js": a})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(z1, z2) {
		t.Fatal("zip output depends on input order or mtimes")
	}
}

func TestPackage(t *testing.T) {
	dir := t.TempDir()
	code := write(t, dir, "index.mjs", "export const handler = async () => 1;")
	raw := `{
	  "Resources": {
	    "Role": {"Type": "AWS::IAM::Role", "Properties": {"RoleName": "r"}},
	    "Fn": {"Type": "AWS::Lambda::Function", "Properties": {
	      "Code": {
	        "S3Bucket": {"__cfn_asset__": {"label": "//fn:code", "part": "bucket"}},
	        "S3Key": {"__cfn_asset__": {"label": "//fn:code", "part": "key"}}
	      },
	      "MemorySize": 128
	    }}
	  }
	}`
	out := t.TempDir()
	m, err := Package(Options{
		RawTemplate:  []byte(raw),
		Config:       manifest.Config{StackName: "s"},
		AssetFiles:   []AssetFile{{Label: "//fn:code", Packaging: "zip", Rel: "index.mjs", Path: code}},
		OutTemplate:  filepath.Join(out, "s.template.json"),
		OutManifest:  filepath.Join(out, "s.manifest.json"),
		OutAssetsDir: filepath.Join(out, "s.assets"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"}; !reflect.DeepEqual(m.Capabilities, want) {
		t.Errorf("capabilities = %v, want %v", m.Capabilities, want)
	}
	if len(m.Assets) != 1 || !strings.HasPrefix(m.Assets[0].Key, "assets/") || m.Assets[0].File != "s.assets/"+filepath.Base(m.Assets[0].Key) {
		t.Fatalf("assets = %+v", m.Assets)
	}
	if _, err := os.Stat(filepath.Join(out, m.Assets[0].File)); err != nil {
		t.Errorf("packaged asset missing: %v", err)
	}
	body, _ := os.ReadFile(filepath.Join(out, "s.template.json"))
	for _, want := range []string{
		`"Fn::Sub": "rules-cfn-assets-${AWS::AccountId}-${AWS::Region}"`,
		`"S3Key": "` + m.Assets[0].Key + `"`,
		`"MemorySize": 128`,
	} {
		if !strings.Contains(string(body), want) {
			t.Errorf("template missing %s:\n%s", want, body)
		}
	}
	if strings.Contains(string(body), "__cfn_asset__") {
		t.Error("unresolved asset placeholder")
	}
}

func TestPackageMissingAsset(t *testing.T) {
	out := t.TempDir()
	_, err := Package(Options{
		RawTemplate:  []byte(`{"Resources": {"B": {"Type": "AWS::S3::Bucket", "Properties": {"X": {"__cfn_asset__": {"label": "//x", "part": "key"}}}}}}`),
		OutTemplate:  filepath.Join(out, "t"),
		OutManifest:  filepath.Join(out, "m"),
		OutAssetsDir: filepath.Join(out, "a"),
	})
	if err == nil || !strings.Contains(err.Error(), "//x") {
		t.Fatalf("err = %v", err)
	}
}
