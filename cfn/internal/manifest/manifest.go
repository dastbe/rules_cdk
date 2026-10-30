// Package manifest defines the stack manifest that `cfnctl package` writes at
// build time and the run-time commands (diff, plan, deploy, destroy) read.
package manifest

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config is the stack configuration written by the cfn_stack rule.
type Config struct {
	StackName             string            `json:"stack_name"`
	Region                string            `json:"region,omitempty"`
	Account               string            `json:"account,omitempty"`
	Parameters            map[string]string `json:"parameters,omitempty"`
	Tags                  map[string]string `json:"tags,omitempty"`
	Capabilities          []string          `json:"capabilities,omitempty"`
	TerminationProtection bool              `json:"termination_protection,omitempty"`
	// AssetBucket is the bucket assets are uploaded to. It may contain
	// ${AWS::AccountId} / ${AWS::Region} which are resolved at deploy time.
	AssetBucket string   `json:"asset_bucket,omitempty"`
	RoleARN     string   `json:"role_arn,omitempty"`
	DependsOn   []string `json:"depends_on,omitempty"`
}

// DefaultAssetBucket is the bucket created by `cfnctl bootstrap`.
const DefaultAssetBucket = "rules-cfn-assets-${AWS::AccountId}-${AWS::Region}"

// Asset is a packaged file uploaded to the asset bucket before deploying.
type Asset struct {
	Label     string `json:"label"`
	Packaging string `json:"packaging"`
	SHA256    string `json:"sha256"`
	// Key is the object key in the asset bucket (content addressed).
	Key string `json:"key"`
	// File is the packaged file, relative to the manifest's directory.
	File string `json:"file"`
}

// Manifest is everything the run-time commands need to act on a stack.
type Manifest struct {
	Config
	// Template is the template file, relative to the manifest's directory.
	Template       string  `json:"template"`
	TemplateSHA256 string  `json:"template_sha256"`
	TemplateSize   int     `json:"template_size"`
	Assets         []Asset `json:"assets,omitempty"`
}

// Read loads a manifest from disk.
func Read(path string) (*Manifest, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("parsing manifest %s: %w", path, err)
	}
	return &m, nil
}

// ReadConfig loads a stack config from disk.
func ReadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parsing config %s: %w", path, err)
	}
	return &c, nil
}
