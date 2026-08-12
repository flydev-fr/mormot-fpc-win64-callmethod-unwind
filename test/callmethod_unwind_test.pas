program callmethod_unwind_test;

// ABI and exception-unwind regression suite for mORMot's FPC Win64
// CallMethod trampoline. Every call goes through a genuine registered
// interface service and TRestServer.Uri() -- no HTTP, no socket.
//
// Two mutually exclusive compile modes:
//   -dMORMOT_CALLMETHOD_UNWIND_FIX      regression suite against the MASM
//                                       replacement installed by
//                                       tools/prepare.ps1 (12/12 expected)
//   -dCALLMETHOD_PRISTINE_DIFFERENTIAL  intentional run against pristine
//                                       pinned CallMethod: demonstrates the
//                                       Currency=0 defect and the process
//                                       termination on the first ordinary
//                                       exception
// Optional -dCALLMETHOD_VERBOSE prints actual status/body on mismatch.

{$mode ObjFPC}{$H+}

{$ifndef MSWINDOWS}
  {$fatal this reproducer is Windows-only}
{$endif}
{$ifndef CPUX86_64}
  {$fatal this reproducer requires the Windows x64 ABI}
{$endif}
{$ifndef MORMOT_CALLMETHOD_UNWIND_FIX}
  {$ifndef CALLMETHOD_PRISTINE_DIFFERENTIAL}
    {$fatal define MORMOT_CALLMETHOD_UNWIND_FIX (patched suite) or CALLMETHOD_PRISTINE_DIFFERENTIAL (intentional pristine comparison)}
  {$endif}
{$else}
  {$ifdef CALLMETHOD_PRISTINE_DIFFERENTIAL}
    {$fatal MORMOT_CALLMETHOD_UNWIND_FIX and CALLMETHOD_PRISTINE_DIFFERENTIAL are mutually exclusive}
  {$endif}
{$endif}

uses
  Windows,
  Classes,
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.interfaces,
  mormot.orm.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server;

const
  CASE_COUNT = 12;
  CONCURRENT_THREAD_COUNT = 4;
  CONCURRENT_ITERATIONS = 25;
  CONCURRENT_BARRIER_WAIT_MS = 5000;
  CONCURRENT_OVERLAP_DELAY_MS = 10;
  POINTER_RESULT_VALUE = PtrUInt($123456789ABCDEF0);
  INTEGER_POSITIONAL_FINGERPRINT = Int64(10987654321);
  STACK_ARGUMENTS_JSON =
    '{"A1":1,"A2":2,"A3":3,"A4":4,"A5":5,"A6":6,"A7":7,"A8":8,"A9":9,"A10":10}';
  RAISE_MESSAGE = 'callmethod-ordinary-exception';

type
  ICallMethodUnwindService = interface(IInvokable)
    ['{5D3C2A1B-7E64-4F0B-9A11-2C8E45D0B7A3}']
    function Add(A, B: Integer): Integer;
    function SignedResult: Int64;
    function UnsignedResult: Cardinal;
    function PointerResult: PtrUInt;
    function XmmArguments(A, B, C, D: Double): Double;
    function DoubleResult: Double;
    function DateTimeResult: TDateTime;
    function CurrencyResult: Currency;
    function TenIntegers(A1, A2, A3, A4, A5, A6, A7, A8, A9,
      A10: Integer): Int64;
    function MixedArguments(A: Integer; B: Double; C: Integer; D: Double;
      E: Integer; F: Double; G: Integer; H: Double): Double;
    function NoArguments: Integer;
    function CustomAnswer: TServiceCustomAnswer;
    function RaiseOrdinary(A1, A2, A3, A4, A5, A6, A7, A8, A9,
      A10: Integer): Integer;
  end;

  TCallMethodUnwindService = class(TInterfacedObject, ICallMethodUnwindService)
  public
    function Add(A, B: Integer): Integer;
    function SignedResult: Int64;
    function UnsignedResult: Cardinal;
    function PointerResult: PtrUInt;
    function XmmArguments(A, B, C, D: Double): Double;
    function DoubleResult: Double;
    function DateTimeResult: TDateTime;
    function CurrencyResult: Currency;
    function TenIntegers(A1, A2, A3, A4, A5, A6, A7, A8, A9,
      A10: Integer): Int64;
    function MixedArguments(A: Integer; B: Double; C: Integer; D: Double;
      E: Integer; F: Double; G: Integer; H: Double): Double;
    function NoArguments: Integer;
    function CustomAnswer: TServiceCustomAnswer;
    function RaiseOrdinary(A1, A2, A3, A4, A5, A6, A7, A8, A9,
      A10: Integer): Integer;
  end;

  TProbeHooks = class
  public
    procedure MethodExecute(Sender: TInterfaceMethodExecuteRaw;
      Step: TInterfaceMethodExecuteEventStep);
    function ErrorUri(Ctxt: TRestServerUriContext; E: Exception): Boolean;
    procedure AfterUri(Ctxt: TRestServerUriContext);
  end;

  TConcurrentProbe = class(TThread)
  private
    FServer: TRestServer;
    FProbeThreadId: Cardinal;
    FFailures: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TRestServer);
    property ProbeThreadId: Cardinal read FProbeThreadId;
    property Failures: Integer read FFailures;
  end;

var
  GAddCalls: LongInt;
  GRaiseCalls: LongInt;
  GRaiseFingerprintValidated: LongInt;
  GServiceFinally: LongInt;
  GSmsError: LongInt;
  GSmsErrorValidated: LongInt;
  GOnErrorUri: LongInt;
  GOnErrorValidated: LongInt;
  GAfterUri: LongInt;
  GCallerFinally: LongInt;
  GConcurrentReady: LongInt;
  GConcurrentStart: LongInt;
  GOverlapProbeEnabled: LongInt;
  GActiveServiceCalls: LongInt;
  GPeakServiceCalls: LongInt;
  GPassed: Integer;
  GCaseNumber: Integer;

threadvar
  GThreadRaiseSequence: LongInt;
  GThreadSmsHandledSequence: LongInt;

function IntegerPositionalFingerprint(A1, A2, A3, A4, A5, A6, A7,
  A8, A9, A10: Integer): Int64;
begin
  Result := Int64(A1) + Int64(A2) * 10 + Int64(A3) * 100 +
    Int64(A4) * 1000 + Int64(A5) * 10000 + Int64(A6) * 100000 +
    Int64(A7) * 1000000 + Int64(A8) * 10000000 +
    Int64(A9) * 100000000 + Int64(A10) * 1000000000;
end;

procedure RecordServiceOverlap;
var
  Active, Peak: LongInt;
begin
  Active := InterlockedIncrement(GActiveServiceCalls);
  repeat
    Peak := InterlockedCompareExchange(GPeakServiceCalls, 0, 0);
    if Peak >= Active then
      Break;
  until InterlockedCompareExchange(GPeakServiceCalls, Active, Peak) = Peak;
  try
    Windows.Sleep(CONCURRENT_OVERLAP_DELAY_MS);
  finally
    InterlockedDecrement(GActiveServiceCalls);
  end;
end;

function TCallMethodUnwindService.Add(A, B: Integer): Integer;
begin
  InterlockedIncrement(GAddCalls);
  if InterlockedCompareExchange(GOverlapProbeEnabled, 0, 0) <> 0 then
    RecordServiceOverlap;
  Result := A + B;
end;

function TCallMethodUnwindService.SignedResult: Int64;
begin
  Result := -1234567890123;
end;

function TCallMethodUnwindService.UnsignedResult: Cardinal;
begin
  Result := 4000000000;
end;

function TCallMethodUnwindService.PointerResult: PtrUInt;
begin
  Result := POINTER_RESULT_VALUE;
end;

function TCallMethodUnwindService.XmmArguments(A, B, C, D: Double): Double;
begin
  Result := A + (2 * B) + (3 * C) + (4 * D);
end;

function TCallMethodUnwindService.DoubleResult: Double;
begin
  Result := 123.5;
end;

function TCallMethodUnwindService.DateTimeResult: TDateTime;
begin
  Result := EncodeDate(2024, 2, 3) + EncodeTime(4, 5, 6, 0);
end;

function TCallMethodUnwindService.CurrencyResult: Currency;
begin
  Result := 1234.5678;
end;

function TCallMethodUnwindService.TenIntegers(A1, A2, A3, A4, A5, A6, A7, A8,
  A9, A10: Integer): Int64;
begin
  Result := IntegerPositionalFingerprint(A1, A2, A3, A4, A5, A6, A7,
    A8, A9, A10);
end;

function TCallMethodUnwindService.MixedArguments(A: Integer; B: Double;
  C: Integer; D: Double; E: Integer; F: Double; G: Integer; H: Double): Double;
begin
  Result := A + 10 * B + 100 * C + 1000 * D + 10000 * E +
    100000 * F + 1000000 * G + 10000000 * H;
end;

function TCallMethodUnwindService.NoArguments: Integer;
begin
  Result := 7;
end;

function TCallMethodUnwindService.CustomAnswer: TServiceCustomAnswer;
begin
  Result.Header := JSON_CONTENT_TYPE_HEADER;
  Result.Content := '{"domainCode":"unwind-test"}';
  Result.Status := HTTP_UNPROCESSABLE_CONTENT;
end;

function TCallMethodUnwindService.RaiseOrdinary(A1, A2, A3, A4, A5, A6, A7,
  A8, A9, A10: Integer): Integer;
begin
  InterlockedIncrement(GRaiseCalls);
  if IntegerPositionalFingerprint(A1, A2, A3, A4, A5, A6, A7, A8,
      A9, A10) = INTEGER_POSITIONAL_FINGERPRINT then
    InterlockedIncrement(GRaiseFingerprintValidated);
  Inc(GThreadRaiseSequence);
  try
    raise Exception.Create(RAISE_MESSAGE);
  finally
    InterlockedIncrement(GServiceFinally);
  end;
  Result := 0;
end;

procedure TProbeHooks.MethodExecute(Sender: TInterfaceMethodExecuteRaw;
  Step: TInterfaceMethodExecuteEventStep);
begin
  if Step <> smsError then
    Exit;
  if GThreadSmsHandledSequence = GThreadRaiseSequence then
    Exit; // pinned cached executors accumulate the same interceptor callback
  GThreadSmsHandledSequence := GThreadRaiseSequence;
  InterlockedIncrement(GSmsError);
  if (Sender.LastException <> nil) and
     (Sender.LastException.ClassType = Exception) and
     (Sender.LastException.Message = RAISE_MESSAGE) then
    InterlockedIncrement(GSmsErrorValidated);
end;

function TProbeHooks.ErrorUri(Ctxt: TRestServerUriContext;
  E: Exception): Boolean;
begin
  InterlockedIncrement(GOnErrorUri);
  if (E <> nil) and
     (E.ClassType = Exception) and
     (E.Message = RAISE_MESSAGE) then
    InterlockedIncrement(GOnErrorValidated);
  Result := True; // retain mORMot's normal 500 response for this ABI-only probe
end;

procedure TProbeHooks.AfterUri(Ctxt: TRestServerUriContext);
begin
  InterlockedIncrement(GAfterUri);
end;

procedure Invoke(AServer: TRestServer; const AMethod, ABody: RawUtf8;
  out AStatus: Cardinal; out AResponse: RawUtf8);
var
  Call: TRestUriParams;
begin
  Call.Init('root/CallMethodUnwindService.' + AMethod, 'POST',
    JSON_CONTENT_TYPE_HEADER, ABody);
  Call.RestAccessRights := @SUPERVISOR_ACCESS_RIGHTS;
  Include(Call.LowLevelConnectionFlags, llfInProcess);
  UniqueRawUtf8(Call.InBody); // Uri() parses this buffer in place
  AServer.Uri(Call);
  AStatus := Call.OutStatus;
  AResponse := Call.OutBody;
end;

function ResponseIs(AServer: TRestServer; const AMethod, ABody,
  AExpected: RawUtf8; AExpectedStatus: Cardinal = HTTP_SUCCESS): Boolean;
var
  Status: Cardinal;
  Response: RawUtf8;
begin
  Invoke(AServer, AMethod, ABody, Status, Response);
  Result := (Status = AExpectedStatus) and (Response = AExpected);
  {$ifdef CALLMETHOD_VERBOSE}
  if not Result then
  begin
    WriteLn('DEBUG ', AMethod, ' status=', Status, ' body=', Response,
      ' expectedStatus=', AExpectedStatus, ' expectedBody=', AExpected);
    Flush(Output);
  end;
  {$endif CALLMETHOD_VERBOSE}
end;

procedure ResetCounters;
begin
  GAddCalls := 0;
  GRaiseCalls := 0;
  GRaiseFingerprintValidated := 0;
  GServiceFinally := 0;
  GSmsError := 0;
  GSmsErrorValidated := 0;
  GOnErrorUri := 0;
  GOnErrorValidated := 0;
  GAfterUri := 0;
  GCallerFinally := 0;
  GConcurrentReady := 0;
  GConcurrentStart := 0;
  GOverlapProbeEnabled := 0;
  GActiveServiceCalls := 0;
  GPeakServiceCalls := 0;
end;

procedure CaseVerdict(const AName: string; APassed: Boolean);
begin
  Inc(GCaseNumber);
  if APassed then
  begin
    Inc(GPassed);
    WriteLn(Format('CASE %.2d %-28s PASS', [GCaseNumber, AName]));
  end
  else
    WriteLn(Format('CASE %.2d %-28s FAIL', [GCaseNumber, AName]));
  // keep the per-case verdicts observable even if a later pristine-mode
  // call terminates the process while stdout is a redirected pipe
  Flush(Output);
end;

constructor TConcurrentProbe.Create(AServer: TRestServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
end;

procedure TConcurrentProbe.Execute;
var
  I: Integer;
  Status: Cardinal;
  Response: RawUtf8;
begin
  FProbeThreadId := Windows.GetCurrentThreadId;
  try
    InterlockedIncrement(GConcurrentReady);
    while InterlockedCompareExchange(GConcurrentStart, 0, 0) = 0 do
      Windows.Sleep(1);
    for I := 1 to CONCURRENT_ITERATIONS do
    begin
      Invoke(FServer, 'Add', '{"A":20,"B":22}', Status, Response);
      if (Status <> HTTP_SUCCESS) or (Response <> '{"result":[42]}') then
        Inc(FFailures);
      try
        Invoke(FServer, 'RaiseOrdinary', STACK_ARGUMENTS_JSON,
          Status, Response);
      finally
        InterlockedIncrement(GCallerFinally);
      end;
      if Status <> HTTP_SERVERERROR then
        Inc(FFailures);
    end;
  except
    Inc(FFailures);
  end;
end;

function DistinctWorkerIds(const Workers: array of TConcurrentProbe): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  for I := 0 to High(Workers) do
  begin
    if (Workers[I] = nil) or (Workers[I].ProbeThreadId = 0) then
      Exit;
    for J := 0 to I - 1 do
      if Workers[I].ProbeThreadId = Workers[J].ProbeThreadId then
        Exit;
  end;
  Result := True;
end;

procedure RunCases(AServer: TRestServer);
var
  Status: Cardinal;
  Response: RawUtf8;
  I, J: Integer;
  Ok: Boolean;
  Workers: array[0..CONCURRENT_THREAD_COUNT - 1] of TConcurrentProbe;
  ExpectedConcurrentRaises: Integer;
  BarrierReady: Boolean;
begin
  ResetCounters;
  CaseVerdict('add-42', ResponseIs(AServer, 'Add',
    '{"A":20,"B":22}', '{"result":[42]}'));

  Ok := ResponseIs(AServer, 'SignedResult', 'null',
          '{"result":[-1234567890123]}') and
        ResponseIs(AServer, 'UnsignedResult', 'null',
          '{"result":[4000000000]}') and
        ResponseIs(AServer, 'PointerResult', 'null',
          '{"result":[1311768467463790320]}');
  CaseVerdict('integer-return-kinds', Ok);

  CaseVerdict('xmm-floating-arguments', ResponseIs(AServer, 'XmmArguments',
    '{"A":1.5,"B":2.5,"C":3.5,"D":4.5}', '{"result":[35]}'));

  Ok := ResponseIs(AServer, 'DoubleResult', 'null',
          '{"result":[123.5]}') and
        ResponseIs(AServer, 'DateTimeResult', 'null',
          '{"result":["2024-02-03T04:05:06"]}') and
        ResponseIs(AServer, 'CurrencyResult', 'null',
          '{"result":[1234.5678]}');
  CaseVerdict('floating-return-kinds', Ok);

  CaseVerdict('ten-integer-stack-args', ResponseIs(AServer, 'TenIntegers',
    STACK_ARGUMENTS_JSON, '{"result":[10987654321]}'));

  CaseVerdict('mixed-register-stack-args', ResponseIs(AServer,
    'MixedArguments',
    '{"A":1,"B":2.5,"C":3,"D":4.5,"E":5,"F":6.5,"G":7,"H":8.5}',
    '{"result":[92704826]}'));

  CaseVerdict('null-no-argument-call', ResponseIs(AServer, 'NoArguments',
    'null', '{"result":[7]}'));

  CaseVerdict('custom-answer-422', ResponseIs(AServer, 'CustomAnswer',
    'null', '{"domainCode":"unwind-test"}', HTTP_UNPROCESSABLE_CONTENT));

  ResetCounters;
  Status := 0;
  try
    Invoke(AServer, 'RaiseOrdinary', STACK_ARGUMENTS_JSON, Status, Response);
  finally
    InterlockedIncrement(GCallerFinally);
  end;
  Ok := (Status = HTTP_SERVERERROR) and
        (GRaiseCalls = 1) and (GServiceFinally = 1) and
        (GRaiseFingerprintValidated = 1) and
        (GSmsError = 1) and (GSmsErrorValidated = 1) and
        (GOnErrorUri = 1) and (GOnErrorValidated = 1) and
        (GAfterUri = 1) and (GCallerFinally = 1);
  CaseVerdict('exception-unwind-handlers', Ok);

  ResetCounters;
  Ok := True;
  for I := 1 to 1000 do
  begin
    Status := 0;
    try
      Invoke(AServer, 'RaiseOrdinary', STACK_ARGUMENTS_JSON,
        Status, Response);
    finally
      InterlockedIncrement(GCallerFinally);
    end;
    if Status <> HTTP_SERVERERROR then
      Ok := False;
  end;
  Ok := Ok and (GRaiseCalls = 1000) and (GServiceFinally = 1000) and
    (GRaiseFingerprintValidated = 1000) and
    (GSmsError = 1000) and (GSmsErrorValidated = 1000) and
    (GOnErrorUri = 1000) and (GOnErrorValidated = 1000) and
    (GAfterUri = 1000) and (GCallerFinally = 1000);
  {$ifdef CALLMETHOD_VERBOSE}
  if not Ok then
    WriteLn('DEBUG stress counters=', GRaiseCalls, '/',
      GRaiseFingerprintValidated, '/', GServiceFinally, '/', GSmsError, '/',
      GSmsErrorValidated, '/', GOnErrorUri, '/', GOnErrorValidated, '/',
      GAfterUri, '/', GCallerFinally);
  {$endif CALLMETHOD_VERBOSE}
  CaseVerdict('sequential-1000-unwinds', Ok);

  ResetCounters;
  for I := 0 to High(Workers) do
    Workers[I] := TConcurrentProbe.Create(AServer);
  try
    InterlockedExchange(GOverlapProbeEnabled, 1);
    for I := 0 to High(Workers) do
      Workers[I].Start;
    BarrierReady := False;
    for J := 1 to CONCURRENT_BARRIER_WAIT_MS do
    begin
      if InterlockedCompareExchange(GConcurrentReady, 0, 0) =
          CONCURRENT_THREAD_COUNT then
      begin
        BarrierReady := True;
        Break;
      end;
      Windows.Sleep(1);
    end;
    InterlockedExchange(GConcurrentStart, 1);
    for I := 0 to High(Workers) do
      Workers[I].WaitFor;
    InterlockedExchange(GOverlapProbeEnabled, 0);
    Ok := BarrierReady and DistinctWorkerIds(Workers) and
      (GPeakServiceCalls > 1) and (GActiveServiceCalls = 0);
    for I := 0 to High(Workers) do
      Ok := Ok and (Workers[I].Failures = 0);
    ExpectedConcurrentRaises := CONCURRENT_THREAD_COUNT *
      CONCURRENT_ITERATIONS;
    Ok := Ok and (GAddCalls = ExpectedConcurrentRaises) and
      (GRaiseCalls = ExpectedConcurrentRaises) and
      (GRaiseFingerprintValidated = ExpectedConcurrentRaises) and
      (GServiceFinally = ExpectedConcurrentRaises) and
      (GSmsError = ExpectedConcurrentRaises) and
      (GSmsErrorValidated = ExpectedConcurrentRaises) and
      (GOnErrorUri = ExpectedConcurrentRaises) and
      (GOnErrorValidated = ExpectedConcurrentRaises) and
      (GAfterUri = ExpectedConcurrentRaises * 2) and
      (GCallerFinally = ExpectedConcurrentRaises);
    {$ifdef CALLMETHOD_VERBOSE}
    if not Ok then
      WriteLn('DEBUG concurrent counters=', GAddCalls, '/', GRaiseCalls,
        '/', GRaiseFingerprintValidated, '/', GServiceFinally, '/',
        GSmsError, '/', GSmsErrorValidated, '/', GOnErrorUri, '/',
        GOnErrorValidated, '/', GAfterUri, '/', GCallerFinally,
        ' expected=', ExpectedConcurrentRaises, ' barrier=', BarrierReady,
        ' ready=', GConcurrentReady, ' peak=', GPeakServiceCalls,
        ' active=', GActiveServiceCalls);
    {$endif CALLMETHOD_VERBOSE}
    WriteLn('OVERLAP ready=', GConcurrentReady,
      ' peak=', GPeakServiceCalls, ' active=', GActiveServiceCalls);
    CaseVerdict('concurrent-success-unwind', Ok);
  finally
    InterlockedExchange(GConcurrentStart, 1);
    InterlockedExchange(GOverlapProbeEnabled, 0);
    for J := 0 to High(Workers) do
      Workers[J].Free;
  end;

  CaseVerdict('post-stress-process-integrity', ResponseIs(AServer, 'Add',
    '{"A":20,"B":22}', '{"result":[42]}'));
end;

var
  Server: TRestServerFullMemory;
  Factory: TServiceFactoryServerAbstract;
  Hooks: TProbeHooks;
begin
  GPassed := 0;
  GCaseNumber := 0;
  Server := nil;
  Hooks := TProbeHooks.Create;
  try
    Server := TRestServerFullMemory.CreateWithOwnModel([]);
    Factory := Server.ServiceRegister(TCallMethodUnwindService,
      [TypeInfo(ICallMethodUnwindService)], sicShared);
    if Factory = nil then
      raise Exception.Create('unable to register ICallMethodUnwindService');
    TServiceFactoryServer(Factory).AddInterceptor(@Hooks.MethodExecute);
    Server.OnErrorUri := @Hooks.ErrorUri;
    Server.OnAfterUri := @Hooks.AfterUri;
    RunCases(Server);
  finally
    Server.Free;
    Hooks.Free;
  end;

  if (GCaseNumber = CASE_COUNT) and (GPassed = CASE_COUNT) then
  begin
    WriteLn('CALLMETHOD-UNWIND: 12/12 PASS');
    Halt(0);
  end;
  WriteLn(Format('CALLMETHOD-UNWIND: %d/%d FAIL', [GPassed, CASE_COUNT]));
  Halt(1);
end.
