program quickjs_signature_test;

{$mode ObjFPC}{$H+}

uses
  mormot.lib.quickjs;

var
  Runtime: JSRuntime;
begin
  Runtime := nil;
  // Keep the call reachable to the type checker, but never execute it. This
  // test is compiled with -Cn: it verifies the Pascal declaration without
  // requiring a QuickJS library on every host.
  if ParamCount < 0 then
    JS_SetMaxStackSize(Runtime, 256 * 1024);
end.
