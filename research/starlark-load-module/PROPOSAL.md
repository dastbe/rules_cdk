# spec: `name = load("module.star")` binds a module as a first-class value

There is currently no way to refer to a loaded module as a single value.
To use three functions from `lib.star`, a file must name each one:

```python
load("//lib:lib.star", "parse", "render", lib_check="check")
```

This has come up several times (google/starlark-go#234, google/starlark-go#302,
google/starlark-go#417, #111), and it causes a few minor problems:

1. Every new use of a function from `lib.star` requires an edit to the load
   statement, and every removal leaves an unused name behind.
2. At the point of use, `parse(x)` gives no hint where `parse` came from.
3. To avoid the first two problems, many libraries export a struct that serves
   as a module, `lib = struct(parse = _parse, render = _render, ...)`. This
   duplicates every exported name and is easy to let drift out of date.

The obvious fix, first-class modules, was proposed in #111 as
`import "lib.star" as lib`. That proposal was closed because it is not
Python syntax. Wildcard loads were rejected in google/starlark-go#302 for good
reason: they make it hard to know where a name is defined.

## Proposal

I propose that a load statement may also appear as the right-hand side of an
assignment to a single identifier, with no names listed:

```python
lib = load("//lib:lib.star")

lib.parse(x)
```

The grammar becomes:

```grammar
LoadStmt = 'load' '(' string {',' [identifier '='] string} [','] ')'
         | identifier '=' 'load' '(' string [','] ')' .
```

The statement binds `lib` to a value of type `module` whose attributes are the
exported globals of the loaded module, that is, those whose names do not
begin with `_`. In all other respects it behaves like an ordinary load:

- The binding is local to the file, and is not re-exported.
- The statement may appear only at top level.
- The module name must be a string literal, so the set of modules a file loads
  remains statically apparent.
- The module value is immutable, and selecting a nonexistent attribute is an
  error. (`lib.prase` reports "module has no .prase field or method (did you
  mean .parse?)".)

`load` does not become an expression. `f(load("x.star"))`,
`a, b = load("x.star")`, and `load("x.star").parse` remain syntax errors, as
does `m = load("x.star", "parse")`, which would mix the two forms.

## Why this syntax

- It is a strict subset of Python. `lib = load("lib.star")` parses as an
  ordinary assignment of a call, so Python-based tools and syntax highlighters
  continue to work. This was the objection to #111.
- It adds no wildcard. Every reference to a loaded name is a selection `lib.f`
  from a binding that is visible in the file, so a reader (or a checker) can
  always tell where `f` comes from. This was the objection to
  google/starlark-go#302.
- It adds no keyword and no second way to load individual symbols. `load`
  remains the only way to import.

Alternatives considered:

- `load(lib="lib.star")`. Elsewhere in a load statement, `x="y"` means "bind x
  to the symbol named y", so this form would give the same notation two
  meanings.
- `load("lib.star")`, binding a name derived from the file name. Many file
  names are not identifiers (`name.v2.star`, `my-rules.bzl`), and the binding
  would be invisible at the point of declaration.
- `load("lib.star", lib="*")`. This already works with application support (see
  google/starlark-go#234), but `"*"` reads as a wildcard and is not one, and
  each application must implement it separately.

## Migration considerations

As noted in google/starlark-go#234, the main cost of any change to the load
statement is the number of tools that must understand it.

- In each implementation (Go, Java, Rust), the change is small: an optional
  identifier on the existing load statement node. Tools that only enumerate the
  modules a file loads, such as Bazel's dependency discovery, see the module
  string in the usual place and need only a parser update.
- Tools that track the names a load binds (buildifier's unused-load warning,
  IDE jump-to-definition) must learn one new binding form. Buildifier would
  also need to accept the form, and should keep these statements at the top of
  the file with other loads.
- Implementations can ship the feature behind a flag, as with other dialect
  options, until the tools catch up. No existing file changes meaning.

## Implementation

I have a prototype for starlark-go, gated by a new `syntax.FileOptions.LoadModule`
option. It consists of parser and resolver support, a new `LOADMODULE` opcode,
and a `LoadedModule` value type. It is about 300 lines including tests.

## Open questions

1. Should `m = load("x.star", "a", "b")` bind a module restricted to `a` and
   `b`? I suggest not for now; it can be added later without breaking anything.
2. Are two module values for the same file equal? Bazel caches loaded modules,
   but other applications may not. I suggest module values be unhashable and
   compare by identity, like other application-defined values.
