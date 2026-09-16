# The generated source modification

## Current proposal at the 2026-09-16 pin

`mormot2-2026-09-16-abi-fixes.patch` applies directly to the exact mORMot2
commit recorded in `mormot.lock`. It corrects the cross-platform
`Currency` result ABI, the QuickJS runtime parameter type, the C `size_t`
allocator bridge, and the macOS IOKit default-port constant. Apply it through
`tools/apply-upstream-fixes.ps1`, which verifies the pin, clean tree,
preflight, whitespace, and four-file patch surface. Its only relaxed match
rule is line-ending whitespace, needed because the portable LF patch targets
upstream Pascal blobs stored as CRLF. `.gitattributes` disables checkout-time
conversion of the patch so Git for Windows receives the same bytes.

The rationale and four-runner differential are documented in
[`docs/2026-09-16-upstream-fixes.md`](../docs/2026-09-16-upstream-fixes.md).

## Historical Win64 MASM patch

For the historical MASM workaround, there is no static patch file:
`tools/prepare.ps1` generates the modified
`mormot.core.interfaces.pas` deterministically from the pristine pinned git
blob, so the change can never drift from the pinned source. The script
recognizes exactly two valid states of the target file — pristine pinned or
exactly-as-generated — and refuses anything else.

The modification wraps the single audited `{$ifdef ABIX64}` `CallMethod`
block. Shape (the original body is preserved byte-for-byte):

```diff
 {$ifdef ABIX64}

+{$if defined(FPC) and defined(OSWINDOWS) and defined(MORMOT_CALLMETHOD_UNWIND_FIX)}
+{$L x64callmethod.obj}
+procedure CallMethod(var Args: TCallMethodArgs); external
+  name 'x64callmethod';
+{$else}
+
 {$ifdef NOASMBLOCK}
 ... original CallMethod implementations, unchanged ...
 {$endif NOASMBLOCK}
+{$endif MORMOT_CALLMETHOD_UNWIND_FIX}
 {$endif ABIX64}
```

Properties:

* the replacement is selected only when compiling FPC + Windows + x64 with
  `-dMORMOT_CALLMETHOD_UNWIND_FIX`; POSIX x64 and Delphi never see the COFF
  object, and a build without the define is byte-equivalent to pristine
  behavior;
* `x64callmethod.obj` (assembled from `../src/x64callmethod.asm` by
  `ml64.exe`) is installed next to `mormot.core.interfaces.pas` so the
  `{$L}` directive resolves;
* installation is transactional: candidate files are written and verified
  first, the swap uses atomic replace/move, and any failure rolls back;
* `tools/restore.ps1` restores the target from the locked git commit
  (never from a `.bak`) and deletes the generated object, transaction
  leftovers and dedicated PPU directories.

Before patching, `prepare.ps1` also asserts the pinned source still
matches the audited ABI assumptions the assembler hard-codes:
`MAX_METHOD_ARGS = 32`, the 256-byte `MAX_EXECSTACK`, the
`TInterfaceMethodValueType` ordering (`imvDouble`=8, `imvDateTime`=9,
`imvCurrency`=10) and the exact `TCallMethodArgs` record layout.
