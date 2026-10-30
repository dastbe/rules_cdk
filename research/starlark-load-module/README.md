# Bound `load` for Starlark (starlark-go prototype)

Goal: let a load statement bind its names to a variable instead of the file
scope, so you can write

```python
lib = load("//lib:lib.star")                 # every exported name
lib = load("//lib:lib.star", "fun", g="h")   # just lib.fun and lib.g
lib.fun(1)
```

instead of binding each symbol at file scope with `load("//lib:lib.star", "fun", ...)`.

The patch here applies to [google/starlark-go](https://github.com/google/starlark-go)
at `4f4267f`:

```sh
git clone https://github.com/google/starlark-go && cd starlark-go
git checkout 4f4267f
git am /path/to/0001-starlark-add-name-load-module-.-to-bind-a-module-val.patch
go test ./...
```

## Semantics

The model: an **unbound** load binds the listed names in the **file scope**;
a **bound** load (`m = load(...)`) binds them as attributes of **a variable**.
The text inside the parentheses means the same thing in both.

* Grammar (the bound form needs `syntax.FileOptions.LoadModule`):
  `[identifier '='] 'load' '(' string {',' [identifier '='] string} [','] ')'`
* The name list may be empty only in the bound form. In that case `m` gets
  every exported (non-`_`) global. `load("x")` on its own is still an error,
  because it would be a wildcard.
* In the bound form, the listed names are **not** bound at file scope.
  `m = load("x", "a")` followed by `a` is `undefined: a`. Duplicate attribute
  names are an error (`load: duplicate name x`). `_`-prefixed source names are
  rejected exactly as in an ordinary load.
* It's still a **statement**, not an expression. The parser only recognizes it
  on the right-hand side of a plain `=` to a single identifier.
  `f(load("x"))`, `a, b = load("x")`, `m.f = load("x")`, `m += load("x")` and
  `load("x").f` are all rejected. So loads stay statically discoverable
  (`Program.Load(i)` still lists them) and stay at the top level.
* `m` itself works like any other load binding. It's file-local, can't be
  reassigned (unless `GlobalReassign` is on), and can't be nested in a
  `def`/`if`/`for`.
* The value is a new `*starlark.LoadedModule` of type `"module"`:
  * `dir()` works, misspelled attributes get "did you mean" suggestions, and
    assigning a field is an error. A listed name that the module doesn't have
    fails the load with the same error as an ordinary load.
  * It's unhashable (same as `starlarkstruct.Module`), and freezing it freezes
    its members.
* `Thread.Load` doesn't change. Embedders get the feature for free once they
  turn on the option.

## Implementation map

| Layer | Change |
|---|---|
| `syntax/options.go` | New `FileOptions.LoadModule` option |
| `syntax/syntax.go` | `LoadStmt.Alias *Ident`. `Span` starts at the alias |
| `syntax/parse.go` | `parseSmallStmt` checks for `LOAD` after `=`. `parseLoadStmt(alias)` allows an empty list only with an alias |
| `syntax/walk.go` | Visits `Alias` |
| `resolve/resolve.go` | Pulled out `bindLoad`. With an alias, binds only the alias and checks the listed names for duplicates |
| `internal/compile` | New `LOADMODULE<n>` opcode (`to1 from1 … toN fromN module LOADMODULE<n> value`; `n=0` means all exported names). Bytecode `Version` 14 → 15 |
| `starlark/interp.go` | Pulled out `Thread.load`, shared by `LOAD` and `LOADMODULE` |
| `starlark/loadedmodule.go` | The new `LoadedModule` value type |
| `doc/spec.md` | Implementation note under "Load statements" |

Tests: parse trees and parse errors (`syntax`), binding, scoping and nesting
rules (`resolve`), and an end-to-end `starlark/testdata/loadmodule.star` that
loads a real `.star` file in both the whole-module and listed-names forms.

## Open questions / next steps

1. **Grammar choice.** Settled on `m = load(...)`: it's valid Python and
   reuses the existing notation inside the parentheses. Formatters and linters
   like buildifier still need to learn that this `load` is special.
2. **Listed names in the bound form.** Settled: supported, binding the names as
   attributes of `m` (see Semantics).
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
