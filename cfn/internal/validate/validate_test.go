package validate

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const schema = `{
  "typeName": "Test::Thing::Widget",
  "definitions": {
    "Part": {"type": "object", "properties": {"Count": {"type": "integer", "minimum": 1, "maximum": 3}}}
  },
  "properties": {
    "Name": {"type": "string", "pattern": "^[a-z]+$", "maxLength": 5},
    "Parts": {"type": "array", "maxItems": 2, "items": {"$ref": "#/definitions/Part"}},
    "Either": {"oneOf": [{"type": "string", "pattern": "^x$"}, {"type": "integer"}]},
    "Lookahead": {"type": "string", "pattern": "^(?!aws:).*$"}
  }
}`

func templ(t *testing.T, props string) map[string]any {
	t.Helper()
	var v map[string]any
	d := json.NewDecoder(strings.NewReader(`{"Resources": {"W": {"Type": "Test::Thing::Widget", "Properties": ` + props + `}}}`))
	d.UseNumber()
	if err := d.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestTemplate(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "test-thing-widget.json")
	os.WriteFile(p, []byte(schema), 0o644)
	s := NewSchemas([]string{p})

	for _, tc := range []struct {
		props string
		want  []string
	}{
		{`{"Name": "abc", "Parts": [{"Count": 2}], "Either": "nope", "Lookahead": "aws:x"}`, nil},
		{`{"Name": {"Ref": "P"}, "Parts": {"Fn::If": ["C", [], []]}}`, nil},
		{`{"Name": "ABCDEF"}`, []string{`W (Test::Thing::Widget): Name: "ABCDEF" does not match pattern ^[a-z]+$`, `"ABCDEF" is longer than maxLength 5`}},
		{`{"Parts": [{"Count": 0}, {"Count": 4}, {}]}`, []string{"Parts: has 3 items; at most 2 allowed", "Parts[0].Count: 0 is less than minimum 1", "Parts[1].Count: 4 is greater than maximum 3"}},
	} {
		problems, err := s.Template(templ(t, tc.props))
		if err != nil {
			t.Fatal(err)
		}
		joined := strings.Join(problems, "\n")
		if len(tc.want) == 0 && len(problems) != 0 {
			t.Errorf("%s: unexpected problems:\n%s", tc.props, joined)
		}
		for _, w := range tc.want {
			if !strings.Contains(joined, w) {
				t.Errorf("%s: missing %q in:\n%s", tc.props, w, joined)
			}
		}
	}
}
