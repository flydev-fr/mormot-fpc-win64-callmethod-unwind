# Reference results

Recorded on the tested configuration (FPC 3.2.2 Win64, mORMot2
`b1a129b09197b6b9fb67c6d4d2a13445987a3fe1`, MASM `ml64.exe`, Windows x64).

All addresses/RVAs below are **example values from one build**. They change
with every relink; the structural facts (exact coverage, gap, frame
register, saved registers) are what matters.

## Pristine pinned CallMethod (the two original issues)

Runtime, driving a real registered interface service through
`TRestServer.Uri()` in-process:

* All pure-success ABI cases up to the exception case behaved normally
  (integer/pointer returns, XMM arguments, Double/TDateTime returns, ten
  stack arguments, mixed register+stack arguments, no-argument call,
  status-422 `TServiceCustomAnswer`) — with one exception:
* **Issue B — Currency:** `CurrencyResult` (service returns `1234.5678`)
  answered status `200` with `{"result":[0]}`.
* **Issue A — unwind:** the first `RaiseOrdinary` call (ordinary
  `Exception` raised behind ten stack arguments) terminated the process;
  observed exit code in one recorded run was `-532262845`, but the exact
  code spelling is diagnostic-only and varies with environment/debugger.
  No interceptor, `OnErrorUri`, service `finally`, or URI-side handler ran.

Binary, one measured pristine build: `CallMethod` at RVA
`0x2F560..0x2F5F0`; the executable's `.pdata` contained an entry ending at
`0x2F555` and the next entry starting at `0x2F600` — no `RUNTIME_FUNCTION`
covered the `CallMethod` range, although the PE exception directory itself
existed and covered ordinary FPC-generated functions.

An intermediate unwind-only replacement (metadata added, Currency handling
left as in pristine — *not* shipped in this repository) returned the same
`{"result":[0]}` for Currency while fixing exception propagation: the two
issues are independent.

## Corrected replacement (this repository)

Runtime matrix — `CALLMETHOD-UNWIND: 12/12 PASS`:

| # | case | result |
|---|------|--------|
| 01 | add-42 | PASS (`200`, `{"result":[42]}`) |
| 02 | integer-return-kinds | PASS (Int64 `-1234567890123`, Cardinal `4000000000`, PtrUInt `1311768467463790320`) |
| 03 | xmm-floating-arguments | PASS |
| 04 | floating-return-kinds | PASS — **Currency `1234.5678`**, Double `123.5`, TDateTime `2024-02-03T04:05:06` |
| 05 | ten-integer-stack-args | PASS (positional fingerprint `10987654321`) |
| 06 | mixed-register-stack-args | PASS (noncommutative fingerprint `92704826`) |
| 07 | null-no-argument-call | PASS |
| 08 | custom-answer-422 | PASS (verbatim body, status 422) |
| 09 | exception-unwind-handlers | PASS — raise crosses the trampoline; interceptor `smsError`, `OnErrorUri`, `OnAfterUri`, service `finally`, caller `finally` each exactly 1 |
| 10 | sequential-1000-unwinds | PASS — exactly 1000/1000 on every counter (raise, fingerprint, service finally, smsError, OnErrorUri, OnAfterUri, caller finally) |
| 11 | concurrent-success-unwind | PASS — 4 threads × 25 iterations: exactly 100 successes and 100 raises, all aggregate counters exact, 0 worker failures, measured in-service overlap `ready=4 peak=4 active=0` |
| 12 | post-stress-process-integrity | PASS (Add → 42 after the stress) |

Binary gate on the final internal-linked PE (one recorded run of the final
verified configuration):

```text
OBJ : machine x64 (8664), public external symbol x64callmethod,
      non-empty .text$mn / .pdata / .xdata
map : exactly one READOBJECT provenance for the repository
      x64callmethod.obj; code contribution 0x8f bytes;
      retained .pdata (0x0c) and .xdata (0x0c) contributions
PE  : exact RUNTIME_FUNCTION 0005C090..0005C11F for the mapped
      x64callmethod range (example RVAs from that build);
      unwind-info RVA inside the OBJ's mapped .xdata;
      nonzero unwind version;
      Frame register: rbp (SET_FPREG, register=rbp, offset=0x0)
      PUSH_NONVOL, register=r12
      PUSH_NONVOL, register=rbp
```

Representative `dumpbin /unwindinfo` excerpt for the entry (values from
one build):

```text
  Begin    End      Info
  0005C090 0005C11F 000xxxxx
    Unwind version: 1
    Unwind flags: None
    Size of prologue: 0x08
    Count of codes: 4
    Frame register: rbp
    Frame offset: 0x0
    Unwind codes:
      08: SET_FPREG, register=rbp, offset=0x0
      04: PUSH_NONVOL, register=r12
      02: PUSH_NONVOL, register=rbp
```

The gate additionally rejects external-linker `LOAD` provenance for the
object, so the evidence always refers to FPC's internal-link path.
