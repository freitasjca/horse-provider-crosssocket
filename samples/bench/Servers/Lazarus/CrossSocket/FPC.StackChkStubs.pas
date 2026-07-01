unit FPC.StackChkStubs;
{$MODE OBJFPC}
interface
implementation
{$IFDEF MSWINDOWS}
{$IFNDEF NO_SMART_LINK}{$SMARTLINK OFF}{$ENDIF}

var
  StackChkGuard: PtrUInt; [public, alias: '__stack_chk_guard'];

procedure StackChkFail; [public, alias: '__stack_chk_fail'];
begin
  Halt(127);
end;

initialization
  if @StackChkFail  = nil then ;
  if @StackChkGuard = 0   then ;
{$ENDIF}
end.
