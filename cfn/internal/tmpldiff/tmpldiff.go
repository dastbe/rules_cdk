// Package tmpldiff computes a semantic diff between two CloudFormation
// templates, keyed by section and logical ID rather than by line.
package tmpldiff

import (
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"sort"
	"strings"
)

// Kind of change.
type Kind string

const (
	Added    Kind = "+"
	Removed  Kind = "-"
	Modified Kind = "~"
)

// Change is one changed entry in a template section.
type Change struct {
	Section string // "Resources", "Outputs", ... or "" for top-level keys
	ID      string
	Kind    Kind
	Type    string // resource type, for Resources
	// Paths lists the changed property paths of a modified entry.
	Paths []PathChange
}

// PathChange is a changed leaf within an entry.
type PathChange struct {
	Path     string
	Old, New any
}

var sections = []string{"Parameters", "Mappings", "Conditions", "Resources", "Outputs"}

// Diff compares old (deployed) and new (local) templates.
func Diff(old, new map[string]any) []Change {
	var out []Change
	seen := map[string]bool{}
	for _, s := range sections {
		seen[s] = true
		o, _ := old[s].(map[string]any)
		n, _ := new[s].(map[string]any)
		for _, id := range keys(o, n) {
			ov, inOld := o[id]
			nv, inNew := n[id]
			c := Change{Section: s, ID: id, Type: resourceType(nv, ov)}
			switch {
			case !inOld:
				c.Kind = Added
			case !inNew:
				c.Kind = Removed
			case !reflect.DeepEqual(normalize(ov), normalize(nv)):
				c.Kind = Modified
				c.Paths = leafDiff("", normalize(ov), normalize(nv), nil)
			default:
				continue
			}
			out = append(out, c)
		}
	}
	for _, k := range keys(old, new) {
		if seen[k] {
			continue
		}
		ov, inOld := old[k]
		nv, inNew := new[k]
		switch {
		case !inOld:
			out = append(out, Change{ID: k, Kind: Added, Paths: []PathChange{{New: nv}}})
		case !inNew:
			out = append(out, Change{ID: k, Kind: Removed, Paths: []PathChange{{Old: ov}}})
		case !reflect.DeepEqual(normalize(ov), normalize(nv)):
			out = append(out, Change{ID: k, Kind: Modified, Paths: []PathChange{{Old: ov, New: nv}}})
		}
	}
	return out
}

func resourceType(vs ...any) string {
	for _, v := range vs {
		if m, ok := v.(map[string]any); ok {
			if t, ok := m["Type"].(string); ok {
				return t
			}
		}
	}
	return ""
}

func keys(ms ...map[string]any) []string {
	set := map[string]bool{}
	for _, m := range ms {
		for k := range m {
			set[k] = true
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// normalize makes values from different decoders comparable (json.Number vs float64).
func normalize(v any) any {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return x.String()
		}
		return f
	case map[string]any:
		m := make(map[string]any, len(x))
		for k, e := range x {
			m[k] = normalize(e)
		}
		return m
	case []any:
		l := make([]any, len(x))
		for i, e := range x {
			l[i] = normalize(e)
		}
		return l
	}
	return v
}

func leafDiff(path string, o, n any, out []PathChange) []PathChange {
	om, oIsMap := o.(map[string]any)
	nm, nIsMap := n.(map[string]any)
	if oIsMap && nIsMap && !isIntrinsic(om) && !isIntrinsic(nm) {
		for _, k := range keys(om, nm) {
			out = leafDiff(path+"."+k, om[k], nm[k], out)
		}
		return out
	}
	ol, oIsList := o.([]any)
	nl, nIsList := n.([]any)
	if oIsList && nIsList && len(ol) == len(nl) {
		for i := range ol {
			out = leafDiff(fmt.Sprintf("%s[%d]", path, i), ol[i], nl[i], out)
		}
		return out
	}
	if !reflect.DeepEqual(o, n) {
		out = append(out, PathChange{Path: strings.TrimPrefix(path, "."), Old: o, New: n})
	}
	return out
}

func isIntrinsic(m map[string]any) bool {
	if len(m) != 1 {
		return false
	}
	for k := range m {
		return k == "Ref" || strings.HasPrefix(k, "Fn::")
	}
	return false
}

func compact(v any) string {
	if v == nil {
		return "(absent)"
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprint(v)
	}
	s := string(b)
	if len(s) > 160 {
		s = s[:157] + "..."
	}
	return s
}

// Print writes a human-readable rendering of changes.
func Print(w io.Writer, changes []Change) {
	if len(changes) == 0 {
		fmt.Fprintln(w, "No template differences.")
		return
	}
	section := "\x00"
	for _, c := range changes {
		if c.Section != section {
			section = c.Section
			name := section
			if name == "" {
				name = "Template"
			}
			fmt.Fprintf(w, "%s\n", name)
		}
		label := c.ID
		if c.Type != "" {
			label += " (" + c.Type + ")"
		}
		fmt.Fprintf(w, "  [%s] %s\n", c.Kind, label)
		for _, p := range c.Paths {
			if p.Path == "" {
				continue
			}
			fmt.Fprintf(w, "      %s: %s -> %s\n", p.Path, compact(p.Old), compact(p.New))
		}
	}
}
