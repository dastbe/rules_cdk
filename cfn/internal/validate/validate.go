// Package validate applies the parts of the CloudFormation registry schemas
// that the load-time Starlark checks leave out: string patterns, lengths,
// numeric ranges and item counts. Starlark has no regex engine, so these
// checks live here and run during `bazel build`.
//
// The checks are conservative. Intrinsic functions, oneOf/anyOf branches and
// patterns RE2 can't compile are skipped rather than guessed at.
package validate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

// Schemas looks up registry schemas by type name.
type Schemas struct {
	byFile map[string]string
	cache  map[string]map[string]any
	re     map[string]*regexp.Regexp
}

// NewSchemas indexes schema files by basename (aws-s3-bucket.json). Files are
// only read when a template uses their type.
func NewSchemas(files []string) *Schemas {
	s := &Schemas{byFile: map[string]string{}, cache: map[string]map[string]any{}, re: map[string]*regexp.Regexp{}}
	for _, f := range files {
		s.byFile[filepath.Base(f)] = f
	}
	return s
}

func fileName(typeName string) string {
	return strings.ToLower(strings.ReplaceAll(typeName, "::", "-")) + ".json"
}

// Lookup returns the decoded schema for typeName, or nil if unknown.
func (s *Schemas) Lookup(typeName string) (map[string]any, error) {
	if c, ok := s.cache[typeName]; ok {
		return c, nil
	}
	path, ok := s.byFile[fileName(typeName)]
	if !ok {
		s.cache[typeName] = nil
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var d map[string]any
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if tn, _ := d["typeName"].(string); tn != typeName {
		d = nil
	}
	s.cache[typeName] = d
	return d, nil
}

// IsIntrinsic reports whether v is a CloudFormation intrinsic function call.
func IsIntrinsic(v any) bool {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 1 {
		return false
	}
	for k := range m {
		return k == "Ref" || k == "Condition" || strings.HasPrefix(k, "Fn::")
	}
	return false
}

// Template validates every resource's Properties against its schema and
// returns human-readable problems, sorted.
func (s *Schemas) Template(tmpl map[string]any) ([]string, error) {
	resources, _ := tmpl["Resources"].(map[string]any)
	var problems []string
	for id, r := range resources {
		rm, _ := r.(map[string]any)
		tn, _ := rm["Type"].(string)
		schema, err := s.Lookup(tn)
		if err != nil {
			return nil, err
		}
		if schema == nil {
			continue
		}
		props, _ := rm["Properties"].(map[string]any)
		v := &walker{s: s, schema: schema, where: fmt.Sprintf("%s (%s)", id, tn)}
		v.object(schema, props, "")
		problems = append(problems, v.problems...)
	}
	sort.Strings(problems)
	return problems, nil
}

type walker struct {
	s        *Schemas
	schema   map[string]any
	where    string
	problems []string
}

func (w *walker) errorf(path, format string, args ...any) {
	w.problems = append(w.problems, fmt.Sprintf("%s: %s: %s", w.where, strings.TrimPrefix(path, "."), fmt.Sprintf(format, args...)))
}

func (w *walker) resolve(n map[string]any, depth int) map[string]any {
	for i := 0; i < 16; i++ {
		ref, ok := n["$ref"].(string)
		if !ok {
			return n
		}
		var next any
		switch {
		case strings.HasPrefix(ref, "#/definitions/"):
			defs, _ := w.schema["definitions"].(map[string]any)
			next = defs[strings.TrimPrefix(ref, "#/definitions/")]
		case strings.HasPrefix(ref, "#/properties/"):
			props, _ := w.schema["properties"].(map[string]any)
			next = props[strings.TrimPrefix(ref, "#/properties/")]
		}
		nm, ok := next.(map[string]any)
		if !ok {
			return nil
		}
		n = nm
	}
	return nil
}

func (w *walker) object(n map[string]any, v map[string]any, path string) {
	props, _ := n["properties"].(map[string]any)
	for k, pv := range v {
		pn, ok := props[k].(map[string]any)
		if !ok {
			continue
		}
		w.value(pn, pv, path+"."+k, 0)
	}
}

func (w *walker) value(n map[string]any, v any, path string, depth int) {
	if depth > 64 || v == nil || IsIntrinsic(v) {
		return
	}
	n = w.resolve(n, depth)
	if n == nil {
		return
	}
	if _, ok := n["oneOf"]; ok {
		return
	}
	if _, ok := n["anyOf"]; ok {
		return
	}
	switch x := v.(type) {
	case string:
		w.str(n, x, path)
	case json.Number:
		w.num(n, x, path)
	case []any:
		if lo, ok := num(n["minItems"]); ok && float64(len(x)) < lo {
			w.errorf(path, "has %d items; at least %v required", len(x), lo)
		}
		if hi, ok := num(n["maxItems"]); ok && float64(len(x)) > hi {
			w.errorf(path, "has %d items; at most %v allowed", len(x), hi)
		}
		if items, ok := n["items"].(map[string]any); ok {
			for i, e := range x {
				w.value(items, e, fmt.Sprintf("%s[%d]", path, i), depth+1)
			}
		}
	case map[string]any:
		if _, ok := n["properties"]; ok {
			for k, pv := range x {
				props := n["properties"].(map[string]any)
				if pn, ok := props[k].(map[string]any); ok {
					w.value(pn, pv, path+"."+k, depth+1)
				}
			}
		}
	}
}

func num(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	}
	return 0, false
}

func (w *walker) str(n map[string]any, s, path string) {
	if t, ok := n["type"].(string); ok && t != "string" {
		return // e.g. a number passed as a string; CloudFormation coerces these
	}
	l := float64(utf8.RuneCountInString(s))
	if lo, ok := num(n["minLength"]); ok && l < lo {
		w.errorf(path, "%q is shorter than minLength %v", s, lo)
	}
	if hi, ok := num(n["maxLength"]); ok && l > hi {
		w.errorf(path, "%q is longer than maxLength %v", s, hi)
	}
	if p, ok := n["pattern"].(string); ok && p != "" {
		re, ok := w.s.re[p]
		if !ok {
			re, _ = regexp.Compile(p) // nil if RE2 can't express it (e.g. lookaheads)
			w.s.re[p] = re
		}
		if re != nil && !re.MatchString(s) {
			w.errorf(path, "%q does not match pattern %s", s, p)
		}
	}
}

func (w *walker) num(n map[string]any, x json.Number, path string) {
	f, err := x.Float64()
	if err != nil {
		return
	}
	if lo, ok := num(n["minimum"]); ok && f < lo {
		w.errorf(path, "%v is less than minimum %v", x, lo)
	}
	if hi, ok := num(n["maximum"]); ok && f > hi {
		w.errorf(path, "%v is greater than maximum %v", x, hi)
	}
}
