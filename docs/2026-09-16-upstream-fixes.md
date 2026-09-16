# Proposed mORMot2 ABI fixes at the 2026-09-16 pin

This repository pins mORMot2 commit
[`102fa3d99708d839948eef595d1d02d2e8fdbb45`](https://github.com/synopse/mORMot2/commit/102fa3d99708d839948eef595d1d02d2e8fdbb45),
the build `2.4.16897` landing point from the 2026-09-16 mORMot2 Daily
edition. The patch
[`patches/mormot2-2026-09-16-abi-fixes.patch`](../patches/mormot2-2026-09-16-abi-fixes.patch)
contains three independent corrections found while reviewing that exact tree.

The patch is intentionally applied to a clone under `deps/mormot2`; no
generated or modified dependency file is committed. `tools/apply-upstream-fixes.ps1`
checks the exact locked SHA, requires a clean clone, runs `git apply --check`,
and refuses an unexpected patch surface. The patch is stored with portable LF
line endings; application ignores only line-ending whitespace because the
locked upstream Pascal blobs use CRLF. The full commit SHA and three-file
surface check prevent that normalization from weakening the source pin.
`.gitattributes` keeps the patch itself LF on Windows runners.

## 1. `Currency` result ABI in `CallMethod`

Report:
[`mormot-imvcurrency-rax-sysv-x64.md`](https://github.com/flydev-fr/pweb/blob/main/docs/upstream/mormot-imvcurrency-rax-sysv-x64.md)

The shared x86-64 result path currently preserves RAX for `imvCurrency`.
That is correct on FPC Win64, but not on FPC SysV x86-64. FPC 3.2.2's
[`get_funcretloc`](https://github.com/fpc/FPCSource/blob/release_3_2_2/compiler/x86_64/cpupara.pas)
places `Currency`/`Comp` function results in the x87 result register on this
ABI. The existing 32-bit `CallMethod` implementation already handles the
same representation with `fistp`.

The correction is target-specific:

| Target | `Currency` result | Correct retrieval |
|---|---:|---|
| FPC Win64 x86-64 | RAX | Keep the already-saved RAX value |
| FPC SysV x86-64 | x87 ST0 | `fistp` the scaled 64-bit value into `res64` |
| FPC AArch64 | X0 | Keep the already-saved X0 value |
| floating `Double` / `TDateTime` | XMM0 or D0 | Preserve the existing floating-point path |

The AArch64 branch previously copied D0 for `imvCurrency`; the patch removes
that branch so the scaled Int64 already stored from X0 survives.

`test/currency_return_test.pas` sends five real interface-service calls
through `TRestServer.Uri()`: no arguments, one integer, one Currency, one
Double, and two integers. The pristine phase confirms the POSIX failures;
the patched phase requires `5/5` on all four runners.

## 2. QuickJS `JS_SetMaxStackSize` owner type

Report:
[`mormot-quickjs-js-setmaxstacksize-signature.md`](https://github.com/flydev-fr/pweb/blob/main/docs/upstream/mormot-quickjs-js-setmaxstacksize-signature.md)

The bundled
[`quickjs.h`](https://github.com/synopse/mORMot2/blob/102fa3d99708d839948eef595d1d02d2e8fdbb45/res/static/libquickjs/quickjs.h)
declares:

```c
void JS_SetMaxStackSize(JSRuntime *rt, size_t stack_size);
```

The Pascal binding used `JSContext`. The patch changes only the first
parameter to `JSRuntime`; `stack_size` was already correctly mapped to
`PtrUInt`.

`test/quickjs_signature_test.pas` passes a `JSRuntime`. Compilation is
expected to fail on the pristine declaration with the distinct
`JSRuntime`/`JSContext` pointer types, then pass after the patch. The test is
compiled with `-Cn` on Windows and Linux, so it verifies the declaration
without linking a QuickJS runtime. On Darwin, where `mormot.lib.quickjs`
intentionally exposes no public binding symbols, the runner checks the exact
declaration text instead.

## 3. C `size_t` allocator bridge

Report:
[`mormot-static-pas-malloc-size-t.md`](https://github.com/flydev-fr/pweb/blob/main/docs/upstream/mormot-static-pas-malloc-size-t.md)

The bundled C headers expose `pas_malloc`, `pas_realloc`, and
`pas_malloc_usable_size` with `size_t`. Pascal used `Cardinal` or signed
`Integer`/`PtrInt` in several corresponding declarations. On 64-bit targets,
`size_t` is an unsigned pointer-width integer, so the matching Pascal type is
`PtrUInt`.

The patch updates:

- the FPC/static bridge in `mormot.lib.static.pas`;
- the Delphi-local QuickJS allocator bridge in `mormot.lib.quickjs.pas`;
- the Delphi allocation header from four bytes to `SizeOf(PtrUInt)`;
- `calloc` multiplication and signed allocator-size boundary checks.

The test runner compares the Pascal declarations with the checked-in C
headers, checks the overflow guards, and force-compiles
`mormot.lib.static.pas`. The Delphi-only branch is source-gated in this FPC
matrix; it should additionally be compiled by upstream's Delphi CI before
merge.

## Reproduce locally

PowerShell 7, Git, FPC 3.2.2, and the platform linker are required.

```powershell
pwsh tools/get-mormot.ps1
pwsh tools/apply-upstream-fixes.ps1 -CheckOnly
pwsh tools/run-upstream-tests.ps1 -Mode Pristine
pwsh tools/apply-upstream-fixes.ps1
pwsh tools/run-upstream-tests.ps1 -Mode Patched
```

The GitHub Actions workflow runs that exact sequence on:

- `windows-latest` / x86-64;
- `ubuntu-24.04` / x86-64;
- `macos-15-intel` / x86-64;
- `macos-15` / ARM64.

The macOS compiler installer and mORMot static archive are checksum-pinned;
the mORMot source is fetched by full commit SHA.
