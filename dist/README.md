# dist/x64callmethod.o

Pre-assembled COFF object of `src/x64callmethod.asm`, packaged for direct
inclusion in mORMot's static distribution (the `.o` naming follows the
`static/x86_64-win64/*.o` convention; FPC's internal linker reads the file
by content, the extension is irrelevant).

The binary is **not committed** to this repository. Get it from:

* the `x64callmethod-dist` artifact of any green run of the
  `demonstrate` GitHub Actions workflow;
* the assets of a GitHub release (tag builds attach the object and its
  `.sha256` automatically);
* or build it locally: `pwsh tools/make-dist.ps1` (requires MASM
  `ml64.exe` and any `llvm-objcopy`).

## How it is produced (tools/make-dist.ps1)

```powershell
ml64.exe /nologo /c /Fo x64callmethod.obj src\x64callmethod.asm
llvm-objcopy --remove-section='.debug$S' x64callmethod.obj dist\x64callmethod.o
# + COFF header TimeDateStamp zeroed
```

* The `.debug$S` section is stripped because ml64 embeds the absolute
  build path there; FPC's linker discards the section anyway. Stripping
  renumbers symbol-table indices, so `make-dist` proves the stripped file
  equivalent to the assembly output field by field: identical raw data
  and characteristics for every retained section, and identical
  relocations by offset, type and resolved symbol *name*.
* The COFF header `TimeDateStamp` is zeroed (reproducible-build
  convention, ignored by linkers), which makes the artifact
  byte-identical across runs of the same toolset. Re-assembling with a
  different MASM version can still change the whole-file hash (the
  symbol table embeds a toolset `@comp.id`); the `.text$mn`, `.pdata`
  and `.xdata` contents depend only on the source.
* A `x64callmethod.o.sha256` checksum file is written next to the
  object.

## Contents (structure is source-determined)

```text
machine   8664 (x64)
sections  .text$mn (0x8f bytes, code)  .data (empty)
          .pdata (0xc bytes, 3 relocs) .xdata (0xc bytes)
symbol    x64callmethod (External, .text$mn+0)
function  RUNTIME_FUNCTION 0x0..0x8f (whole trampoline)
unwind    version 1, SET_FPREG rbp, PUSH_NONVOL r12, PUSH_NONVOL rbp
```

## Validation chain

`tools/make-dist.ps1` prints the deterministic section-content
fingerprint of the assembly output -- the same algorithm as
`tools/prepare.ps1` (it hashes `.text$mn`/`.pdata`/`.xdata` contents and
relocations, excluding `.debug$S` and the symbol table). In CI the
packaging step runs **after** the full demonstration and refuses the
artifact unless this fingerprint matches the one `prepare.ps1` printed
for the object that just passed:

* `tools/check-unwind.ps1`: exact `RUNTIME_FUNCTION` coverage of the
  mapped trampoline range in the **final executable**, unwind-info RVA
  inside the OBJ-contributed `.xdata`, RBP frame via `SET_FPREG`,
  `PUSH_NONVOL` for RBP and R12;
* the full runtime suite: `CALLMETHOD-UNWIND: 12/12 PASS` (ABI matrix,
  single raise, 1000 sequential unwind cycles, concurrent stress,
  post-stress call).

So a published object is always fingerprint-tied to an object that was
validated end-to-end in a linked executable in the same run.

## Integration notes

* Place the file as `static/x86_64-win64/x64callmethod.o` (or next to
  `mormot.core.interfaces.pas`) and replace the FPC + Win64 branch of
  `CallMethod` with:

  ```pascal
  {$L x64callmethod.o}
  procedure CallMethod(var Args: TCallMethodArgs); external
    name 'x64callmethod';
  ```

  (this repository's `tools/prepare.ps1` generates exactly that shape
  behind a `MORMOT_CALLMETHOD_UNWIND_FIX` define; see
  `patches/README.md`).
* The object includes **both** fixes: the Win64 unwind metadata (issue A)
  and the Currency return handling (issue B -- `imvCurrency` keeps the
  RAX value instead of copying XMM0, which is the FPC 3.2.2 Win64
  convention). A build using it will return correct `Currency` values
  where the pristine trampoline returned 0.
* The object hard-codes the audited shape of the pinned source:
  `TCallMethodArgs` layout, `MAX_EXECSTACK = 256`, and the `imv*`
  ordinals (Double = 8, DateTime = 9, Currency = 10). If any of these
  change, re-audit `src/x64callmethod.asm` and re-assemble.
* Measured on FPC 3.2.2 x86_64-win64 only. Delphi Win64 does not use
  this code path.
