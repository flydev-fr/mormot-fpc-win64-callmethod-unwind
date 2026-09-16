# Proposed mORMot2 ABI fixes at the 2026-09-16 pin

This repository pins mORMot2 commit
[`102fa3d99708d839948eef595d1d02d2e8fdbb45`](https://github.com/synopse/mORMot2/commit/102fa3d99708d839948eef595d1d02d2e8fdbb45),
the build `2.4.16897` landing point from the 2026-09-16 mORMot2 Daily
edition. The patch
[`patches/mormot2-2026-09-16-abi-fixes.patch`](../patches/mormot2-2026-09-16-abi-fixes.patch)
contains four independent corrections found while reviewing and testing that
exact tree.

The patch is intentionally applied to a clone under `deps/mormot2`; no
generated or modified dependency file is committed. `tools/apply-upstream-fixes.ps1`
checks the exact locked SHA, requires a clean clone, runs `git apply --check`,
and refuses an unexpected patch surface. The patch is stored with portable LF
line endings; application ignores only line-ending whitespace because the
locked upstream Pascal blobs use CRLF. The full commit SHA and four-file
surface check prevent that normalization from weakening the source pin.
`.gitattributes` keeps the patch itself LF on Windows runners.

## 1. `Currency` result ABI in `CallMethod`

Report:
[`mormot-imvcurrency-rax-sysv-x64.md`](https://github.com/flydev-fr/pweb/blob/main/docs/upstream/mormot-imvcurrency-rax-sysv-x64.md)

The shared x86-64 result path currently preserves RAX for `imvCurrency`.
That is correct on FPC Win64, but not on FPC SysV x86-64. The pinned FPC
3.2.3 source's
[`get_funcretloc`](https://github.com/fpc/FPCSource/blob/483299735faef392a746646bb3d5f5737a9e53a5/compiler/x86_64/cpupara.pas)
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

## 4. macOS absolute default-constant linkage

`mormot.core.os.mac.pas` declared `kIOMasterPortDefault` as an external
`cvar`. [Apple's IOKit implementation](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/IOKitLib.c#L112-L113)
defines it as a constant `MACH_PORT_NULL` value, and the
[corresponding header](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/IOKitLib.h#L129-L135)
marks it as the deprecated name of `kIOMainPortDefault`. Current macOS x86-64
linkers expose that value as an absolute symbol, so asking for its address
fails with `target '_kIOMasterPortDefault' does not have address`.

The patch maps the value to a typed Pascal constant equal to zero. This keeps
the IOKit call semantics unchanged and removes the invalid relocation. The
same unit passed `kCFAllocatorDefault` to three CoreFoundation calls. Apple's
[CoreFoundation implementation](https://github.com/apple-oss-distributions/CF/blob/dc54c6bb1c1e5e0b9486c1d26dd5bef110b20bf3/CFBase.c#L388)
defines that symbol as `NULL`, but importing its address triggers the same
Mach-O x86-64 fixup error. The patch therefore passes `nil` directly at those
call sites.

The pristine differential source-gates both address-based forms; the patched
targeted program and the complete mORMot2 suite must then link and run on both
macOS x86-64 and ARM64.

## Reproduce locally

PowerShell 7, Git, FPC 3.2.3, and the platform linker are required.

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

The test compiler is built from the official FPC `fixes_3_2` source at
commit `483299735faef392a746646bb3d5f5737a9e53a5`, which identifies itself as
FPC 3.2.3. FPC 3.2.2 is used only to bootstrap that pinned compiler; no
mORMot2 source or test is compiled with the bootstrap toolchain.

After the targeted patched checks pass, every runner also compiles and runs
the official upstream `test/mormot2tests.dpr` Core/ORM/SOA regression suite
against the patched checkout. CI defines `NO_UI` because no desktop widgetset
is installed and passes `nontp` to disable the sole public-network probe. The
suite's `process-ref.zip` input is downloaded before execution, verified as
SHA-256
`0ed513dd4dcf1a549387ae4c8cc6222456a4de149f1c928a12f6d6086c214873`,
and extracted into its normal `data` directory, so the JSON and Mustache
assertions do not depend on in-process HTTP access. On macOS the runner also
points `OPENSSL_LIBPATH` at Homebrew's `openssl@3` libraries, ensuring the HTTPS
server/client assertions execute instead of failing library discovery.

GitHub's generated macOS ARM64 hostname can be long enough to violate two
fixed 400-byte syslog-message bounds in `test.core.base`. The workflow assigns
the ephemeral runner the short hostname `mormot-ci` before the complete suite;
this changes only test-environment metadata and does not patch or skip those
assertions. All official tests must emit the upstream success marker with a
zero exit status.

The bootstrap installers and mORMot static archive are checksum-pinned; both
the FPC and mORMot source trees are fetched by full commit SHA.
