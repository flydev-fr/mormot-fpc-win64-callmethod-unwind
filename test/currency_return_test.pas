program currency_return_test;

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.interfaces,
  mormot.orm.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server;

type
  ICurrencyReturn = interface(IInvokable)
    ['{176BA876-BE60-418D-A8CE-09B18C012DE3}']
    function CurZero: Currency;
    function CurOneInt(A: Integer): Currency;
    function CurOneCur(const V: Currency): Currency;
    function CurOneDouble(V: Double): Currency;
    function CurTwoInt(A, B: Integer): Currency;
  end;

  TCurrencyReturn = class(TInterfacedObject, ICurrencyReturn)
  public
    function CurZero: Currency;
    function CurOneInt(A: Integer): Currency;
    function CurOneCur(const V: Currency): Currency;
    function CurOneDouble(V: Double): Currency;
    function CurTwoInt(A, B: Integer): Currency;
  end;

function TCurrencyReturn.CurZero: Currency;
begin
  Result := 1234.5678;
end;

function TCurrencyReturn.CurOneInt(A: Integer): Currency;
begin
  Result := A + 0.5;
end;

function TCurrencyReturn.CurOneCur(const V: Currency): Currency;
begin
  Result := V * 2;
end;

function TCurrencyReturn.CurOneDouble(V: Double): Currency;
begin
  Result := V * 2;
end;

function TCurrencyReturn.CurTwoInt(A, B: Integer): Currency;
begin
  Result := A * 100 + B + 0.25;
end;

function RunCase(Server: TRestServer; const Method, Body,
  Expected: RawUtf8): Boolean;
var
  Call: TRestUriParams;
begin
  Call.Init('root/CurrencyReturn.' + Method, 'POST',
    JSON_CONTENT_TYPE_HEADER, Body);
  Call.RestAccessRights := @SUPERVISOR_ACCESS_RIGHTS;
  Include(Call.LowLevelConnectionFlags, llfInProcess);
  UniqueRawUtf8(Call.InBody);
  Server.Uri(Call);
  Result := (Call.OutStatus = HTTP_SUCCESS) and (Call.OutBody = Expected);
  if Result then
    WriteLn('CURRENCY-CASE ', Method, ': PASS')
  else
    WriteLn('CURRENCY-CASE ', Method, ': FAIL status=', Call.OutStatus,
      ' body=', Call.OutBody, ' expected=', Expected);
end;

var
  Server: TRestServerFullMemory;
  Factory: TServiceFactoryServerAbstract;
  Passed: Integer;
begin
  Passed := 0;
  Server := TRestServerFullMemory.CreateWithOwnModel([]);
  try
    Factory := Server.ServiceRegister(TCurrencyReturn,
      [TypeInfo(ICurrencyReturn)], sicShared);
    if Factory = nil then
      raise Exception.Create('unable to register ICurrencyReturn');
    if RunCase(Server, 'CurZero', 'null', '{"result":[1234.5678]}') then
      Inc(Passed);
    if RunCase(Server, 'CurOneInt', '{"A":41}', '{"result":[41.5]}') then
      Inc(Passed);
    if RunCase(Server, 'CurOneCur', '{"V":21.25}', '{"result":[42.5]}') then
      Inc(Passed);
    if RunCase(Server, 'CurOneDouble', '{"V":21.25}', '{"result":[42.5]}') then
      Inc(Passed);
    if RunCase(Server, 'CurTwoInt', '{"A":4,"B":2}',
      '{"result":[402.25]}') then
      Inc(Passed);
  finally
    Server.Free;
  end;
  WriteLn('CURRENCY-RESULT: ', Passed, '/5');
  if Passed <> 5 then
    Halt(1);
end.
