# FPC Win64 unwind issue in mORMot CallMethod

## Summary

On FPC 3.2.2 Win64, an ordinary Pascal exception raised inside a mORMot 2
interface-based service **terminates the process** instead of reaching
mORMot's own `try/except` in `TInterfaceMethodExecuteRaw.RawExecute`,
`TRestServer.Uri()`'s error handler, or the `OnErrorUri` hook.

The root cause is that the hand-written x64 assembler trampoline
`CallMethod` in `mormot.core.interfaces.pas` has **no Windows x64 unwind
metadata** in the final FPC-linked executable: no `RUNTIME_FUNCTION` entry
covers its code range, so the Windows unwinder cannot cross that frame when
an exception propagates out of the invoked service method.

This repository contains:

* a minimal, network-free reproducer driving a real registered interface
  service through `TRestServer.Uri()` (no HTTP, no sockets);
* a tested MASM replacement for `CallMethod` with proper `.pdata`/`.xdata`
  unwind metadata (`src/x64callmethod.asm`);
* a transactional preparation/restore mechanism that installs the
  replacement into the pinned mORMot checkout behind a
  `MORMOT_CALLMETHOD_UNWIND_FIX` define, and restores the pristine pin;
* a binary verification gate that proves exact `RUNTIME_FUNCTION` coverage
  in the **final executable**, not merely in the OBJ;
* a full ABI/exception regression suite (12 cases, 1000 sequential unwind
  cycles, concurrent mixed success/raise stress);
* evidence for a second, independent FPC Win64 issue found along the way:
  `CallMethod` overwrites the valid `Currency` return value (see below).

The problem was found while integrating mORMot into another project; the
reproducer here is self-contained and has no dependency on that project.

## Tested configuration

```text
FPC       3.2.2 Win64 (x86_64-win64)
mORMot2   commit b1a129b09197b6b9fb67c6d4d2a13445987a3fe1 (pinned, fetched
          by tools/get-mormot.ps1 together with the sha256-pinned release
          statics archive)
Assembler Microsoft MASM ml64.exe (Visual Studio x64 build tools)
Checker   Microsoft dumpbin.exe (/headers, /symbols, /unwindinfo)
OS        Windows x64
```

No claim is made about other FPC versions, other targets, or Delphi; only
the configuration above was measured.

## Reproduction

```powershell
# fetch the exact pinned mORMot2 revision into deps/mormot2
pwsh tools/get-mormot.ps1

# demonstrate the ORIGINAL behavior against pristine pinned mORMot
pwsh tools/run-tests.ps1 -PristineRepro
```

The pristine run compiles the identical test suite against unmodified
pinned mORMot (`-dCALLMETHOD_PRISTINE_DIFFERENTIAL`) and shows:

* `CurrencyResult` (expected `1234.5678`) answers `200` with
  `{"result":[0]}` — the Currency defect;
* the first service method that raises an ordinary `Exception` kills the
  process before any handler runs; the remaining cases never execute and
  the suite never reaches a verdict line.

The exact process exit / exception code is environment- and
debugger-dependent and is deliberately **not** part of the contract. The
symptom that matters is: *exception propagation cannot safely traverse
`CallMethod`*.

## Root cause

`CallMethod` (`mormot.core.interfaces.pas`, `{$ifdef ABIX64}` /
`{$ifdef OSWINDOWS}` branch) is hand-written x64 assembler marked
`nostackframe`. It:

* pushes the nonvolatile registers RBP and R12;
* reserves `MAX_EXECSTACK` (256) bytes and **dynamically aligns RSP**;
* pushes a variable number of stack arguments in a loop before the call.

The final FPC-linked executable **does** contain a PE exception directory —
FPC emits `.pdata` for its own Pascal code — but no `RUNTIME_FUNCTION`
entry covers `CallMethod`'s code range. In the measured pristine build the
original `CallMethod` sat at RVA `0x2F560..0x2F5F0` while `.pdata` jumped
from a function ending at `0x2F555` straight to one starting at `0x2F600`
(addresses are build-specific; the structural gap is the point).

When the invoked service method raises, `RtlVirtualUnwind` reaches the
uncovered `CallMethod` frame, cannot restore RSP/RBP/R12 across it, and the
dispatch fails before mORMot's `try/except` in `RawExecute` is reached. The
process dies. `optIgnoreException`, execution interceptors and `OnErrorUri`
are all downstream of the unwind and cannot help.

## Why the PE exception directory alone is insufficient

"The executable has an exception directory" was true in the broken binary
too. Correctness requires an entry that **exactly covers the trampoline's
code range** with unwind codes that describe its prologue. That is what
`tools/check-unwind.ps1` gates on: exact begin/end match for the mapped
`x64callmethod` range, unwind-info RVA inside the OBJ's contributed
`.xdata`, frame register RBP established via `SET_FPREG`, and
`PUSH_NONVOL` records for RBP and R12.

## Workaround / tested fix

`src/x64callmethod.asm` is a MASM rewrite of the same trampoline using the
`PROC FRAME` unwind directives:

```asm
x64callmethod PROC FRAME
    push    rbp
    .pushreg rbp
    push    r12
    .pushreg r12
    mov     rbp, rsp
    .setframe rbp, 0
    .endprolog
    ; dynamic stack manipulation happens only AFTER the described prologue
```

With RBP declared as the frame register, the unwinder recovers the frame
regardless of the dynamic RSP movement below it. The epilogue
(`lea rsp,[rbp]` / `pop r12` / `pop rbp` / `ret`) is a canonical Win64
unwind epilog form. Argument marshalling is byte-for-byte the same behavior
as the original FPC `CallMethod` (offsets into `TCallMethodArgs`, reversed
qword stack copy, RCX/RDX/R8/R9 + XMM0..3, 32-byte shadow space).

`tools/prepare.ps1` assembles it with `ml64.exe`, validates the resulting
x64 COFF object (public `x64callmethod`, non-empty `.text$mn`, `.pdata`,
`.xdata`), installs it next to `mormot.core.interfaces.pas` and wraps the
original `ABIX64` block in a conditional:

```pascal
{$if defined(FPC) and defined(OSWINDOWS) and defined(MORMOT_CALLMETHOD_UNWIND_FIX)}
{$L x64callmethod.obj}
procedure CallMethod(var Args: TCallMethodArgs); external
  name 'x64callmethod';
{$else}
  // ... original implementation, unchanged ...
```

The change is generated (never hand-edited), recognized exactly
(pristine-or-patched, anything else is rejected), transactional with
rollback, and idempotent. `tools/restore.ps1` restores the pristine pinned
source from the locked git commit — never from a backup file — and removes
generated objects and PPUs. See `patches/README.md` for the exact shape.

A distributable copy of the object for direct upstream inclusion is
packaged by `tools/make-dist.ps1` as `dist/x64callmethod.o` (`.debug$S`
stripped, timestamp zeroed, checksum file written). The binary is not
committed: CI packages it after the demonstration passes and publishes it
as a run artifact -- and as a GitHub release asset on tag builds --
fingerprint-tied to the object that was just validated end-to-end. See
`dist/README.md` for provenance and integration notes.

## Currency ABI issue

The ABI matrix exposed a **second, independent** defect. These are two
separate issues; neither causes the other:

```text
A. missing Win64 unwind metadata for the hand-written trampoline
B. imvCurrency overwriting the valid RAX return value with XMM0
```

FPC 3.2.2 Win64 returns `Currency` as its scaled Int64 value **in RAX**.
Pristine `CallMethod` treats result kind `imvCurrency` like
`imvDouble`/`imvDateTime` and copies XMM0 over the already-stored RAX
value, so a service returning `1234.5678` answers `{"result":[0]}`:

```text
pristine pinned CallMethod:              Currency 1234.5678 -> 0
unwind-only replacement (same handling): Currency 1234.5678 -> 0
corrected replacement (RAX preserved):   Currency 1234.5678 -> 1234.5678
```

The shipped `src/x64callmethod.asm` therefore copies XMM0 only for
`imvDouble` (8) and `imvDateTime` (9) and keeps RAX for `imvCurrency` (10).
The pristine half of the differential is reproducible with
`run-tests.ps1 -PristineRepro` (the verbose case output shows the actual
`{"result":[0]}` body).

## Run the tests

```powershell
# full workflow: fetch, prepare, force rebuild, binary gate, runtime suite,
# restore in finally
pwsh tools/run-tests.ps1

# explicit tool locations if not resolvable via PATH / vswhere
pwsh tools/run-tests.ps1 -FpcPath C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe `
    -Ml64Path "C:\...\ml64.exe" -DumpbinPath "C:\...\dumpbin.exe"

# original-bug demonstration (pristine dependency, separate process)
pwsh tools/run-tests.ps1 -PristineRepro
```

Any failure exits nonzero. The dependency is restored to the pristine pin
in a `finally` block (skip with `-NoRestore` to inspect the prepared
state).

A GitHub Actions workflow (`.github/workflows/demonstrate.yml`) runs the
same two halves on a clean `windows-latest` runner — first the pristine
reproduction, then the fix — and writes a bug-vs-fix comparison to the job
summary. It fails if either half stops holding. After a green
demonstration it also packages `dist/x64callmethod.o` (fingerprint-tied
to the validated object), uploads it as the `x64callmethod-dist` run
artifact, and attaches it to the GitHub release on tag builds.

## Expected results

```text
mORMot/FPC Win64 CallMethod unwind test

ABI:
  12/12 PASS

Exception unwind:
  single raise PASS
  finally markers PASS
  sequential 1000/1000 PASS
  concurrency PASS
  post-stress call PASS

PE unwind metadata:
  RUNTIME_FUNCTION PASS
  RBP frame PASS
  RBP/R12 saves PASS

RESULT:
  PASS
```

See `docs/reference-results.md` for a full reference run, including the
recorded pristine-failure evidence.

## Files

```text
mormot.lock                     exact mORMot2 pin + sha256-pinned statics
src/x64callmethod.asm           MASM replacement trampoline (unwind + Currency)
dist/README.md                  the packaged object: provenance, integration
tools/make-dist.ps1             package dist/x64callmethod.o (not committed)

patches/README.md               exact shape of the generated source change
test/callmethod_unwind_test.pas 12-case ABI/exception suite over TRestServer.Uri()
tools/get-mormot.ps1            deterministic pinned fetch into deps/mormot2
tools/prepare.ps1               transactional install of the replacement
tools/restore.ps1               restore pristine pin, remove generated artifacts
tools/check-unwind.ps1          final-PE RUNTIME_FUNCTION/.pdata/.xdata gate
tools/run-tests.ps1             one-command workflow (+ -PristineRepro mode)
docs/reference-results.md       recorded reference results
.github/workflows/demonstrate.yml  bug-then-fix demonstration with job summary
```

## Scope and limitations

* Specific to **FPC + Win64 + mORMot `CallMethod`**. The replacement
  hard-codes the pinned `TCallMethodArgs` layout, the 256-byte
  `MAX_EXECSTACK`, and the `imv*` ordinals; `prepare.ps1` verifies these
  audited shape assumptions against the pinned source and refuses anything
  else. A pin/compiler/target change requires revalidation.
* It does **not** repair other private assembler paths in mORMot, e.g.
  `x64FakeStub`.
* The Currency convention was demonstrated for FPC 3.2.2 Win64 only.
* Delphi Win64 is not affected by construction (different compiler/back
  end); it was not measured here.

## Possible upstream directions

* Emit Win64 unwind directives for `CallMethod` in
  `mormot.core.interfaces.pas` (FPC supports SEH directives on win64), or
  link a pre-assembled object as done here.
* Alternatively restructure the call so no hand-written frame sits between
  `RawExecute`'s `try/except` and the invoked method.
* Handle `imvCurrency` per compiler: on FPC Win64 keep the RAX value
  instead of copying XMM0.
