# Whole-module `load` for Starlark (starlark-go prototype)

Goal: let a load statement bind an entire module to a name, so you can write

```python
lib = load("//lib:lib.star")
lib.fun(1)
```

instead of listing every symbol with `load("//lib:lib.star", "fun", ...)`.

The patch here applies to [google/starlark-go](https://github.com/google/starlark-go)
at `4f4267f`:

```sh
git clone https://github.com/google/starlark-go && cd starlark-go
git checkout 4f4267f
git am /path/to/0001-starlark-add-name-load-module-to-bind-a-whole-module.patch
go test ./...
```

## Semantics

* Grammar (only when `syntax.FileOptions.LoadModule` is on):
  `identifier '=' 'load' '(' string [','] ')'`
* It's still a **statement**, not an expression. The parser only recognizes it
  on the right-hand side of a plain `=` to a single identifier.
  `f(load("x"))`, `a, b = load("x")`, `m.f = load("x")`, `m += load("x")` and
  `load("x").f` are all rejected. So loads stay statically discoverable
  (`Program.Load(i)` still lists them) and stay at the top level.
* You can't name symbols in the same statement: `m = load("x", "a")` is an error.
* The binding works like any other load binding. It's file-local, can't be
  reassigned (unless `GlobalReassign` is on), and can't be nested in a
  `def`/`if`/`for`.
* The value is a new `*starlark.LoadedModule` of type `"module"`:
  * Attributes are the `StringDict` returned by `Thread.Load`, minus names that
    start with `_`. This matches the rule that `load` can't import private names.
  * `dir()` works, misspelled attributes get "did you mean" suggestions, and
    assigning a field is an error.
  * It's unhashable (same as `starlarkstruct.Module`), and freezing it freezes
    its members.
* `Thread.Load` doesn't change. Embedders get the feature for free once they
  turn on the option.

## Implementation map

| Layer | Change |
|---|---|
| `syntax/options.go` | New `FileOptions.LoadModule` option |
| `syntax/syntax.go` | `LoadStmt.Alias *Ident`. `From`/`To` are empty in this form. `Span` starts at the alias |
| `syntax/parse.go` | `parseSmallStmt` checks for `LOAD` after `=`. `parseLoadStmt(alias)` |
| `syntax/walk.go` | Visits `Alias` |
| `resolve/resolve.go` | Pulled out `bindLoad`, used for both `Alias` and `To[i]` |
| `internal/compile` | New no-arg `LOADMODULE` opcode (`module LOADMODULE value`). Bytecode `Version` 14 → 15 |
| `starlark/interp.go` | Pulled out `Thread.load`, shared by `LOAD` and `LOADMODULE` |
| `starlark/loadedmodule.go` | The new `LoadedModule` value type |
| `doc/spec.md` | Implementation note under "Load statements" |

Tests: parse trees and parse errors (`syntax`), binding and nesting rules
(`resolve`), and an end-to-end `starlark/testdata/loadmodule.star` that loads a
real `.star` file.

## Open questions / next steps

1. **Grammar choice.** `m = load("x")` reads well, but Python treats it as an
   ordinary call. Formatters and linters like buildifier would need to learn
   that this `load` is special. A `load("x", as="m")` style would stay inside
   the existing statement grammar. It's worth deciding before writing a
   spec proposal.
2. **Subset form.** Should `m = load("x", "a", "b")` bind a module that has only
   `a` and `b`? It's rejected today, so it can be added later without breaking
   anything.
3. **Other implementations.** starlark-java (Bazel) and starlark-rust would
   need the same change before Bazel `.bzl` files could use this. The
   `bazelbuild/starlark` spec repo is the place to propose it.
4. **Module identity.** Each `LOADMODULE` makes a new `LoadedModule`
   wrapper, so two aliases of the same module are different values. Equality
   isn't defined, so this only matters if equality is added later.
5. **CLI.** `cmd/starlark` has no flag for the option yet.

## Prior discussion upstream

Checked October 2026.

* [google/starlark-go#234](https://github.com/google/starlark-go/issues/234), "load all globals in one shot?" (open, 2019). Alan Donovan: "a missing feature of the language." In Jan 2025 someone proposed the exact `foo = load("...")` form. Donovan: "That's a reasonable idea, but … almost any change to the load statement is a big hurdle just because of the number of tools that would need to be updated." Laurent Le Brun described a workaround where the host adds a `"*"` key bound to a struct, so `load("foo.star", foo="*")` works.
* [bazelbuild/starlark#111](https://github.com/bazelbuild/starlark/issues/111), "new import syntax, and first class modules" (Donovan, 2020). Proposed `import "x.star" as name`. **Closed in 2023** when the spec stated that Starlark syntax is a strict subset of Python. An Aug 2022 comment also suggested `module = load("module.star")`; no maintainer replied. Another comment suggested a `load("m.star", m="@module")` convention.
* [google/starlark-go#302](https://github.com/google/starlark-go/issues/302), "support first-class modules in load syntax" (open). Wildcard loads were rejected because they break static name resolution. Donovan floated `load("os.bzl")` / `load(alt="os.bzl")`.
* [google/starlark-go#417](https://github.com/google/starlark-go/issues/417) (closed). A load must name at least one symbol. Pointed to #111, which "has not been accepted."
* [bazelbuild/starlark#188](https://github.com/bazelbuild/starlark/issues/188) (closed). `from … import` sugar was blocked because it would break Python syntax compatibility.

What this means here: `m = load("x")` is valid Python syntax, so it avoids the objection that closed #111. It keeps names statically resolvable, so it avoids the wildcard objection too. The remaining objection is the cost of updating tools such as buildifier, gazelle and IDE plugins. A spec proposal should be filed on bazelbuild/starlark and should reference #234 and #111.
