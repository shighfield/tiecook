unit uopen;

{ Open a URL or local file in the user's default application. Fire-and-forget:
  returns immediately and never raises, so a failure to launch can't crash the
  TUI. Ported from tiecook; a file path works as the target too. }

{$mode objfpc}{$H+}

interface

procedure OpenExternal(const Target: string);

implementation

uses
  {$IFDEF WINDOWS}
  Windows, ShellApi,
  {$ELSE}
  Process,
  {$ENDIF}
  SysUtils;

procedure OpenExternal(const Target: string);
{$IFDEF WINDOWS}
begin
  ShellExecute(0, 'open', PChar(Target), nil, nil, SW_SHOWNORMAL);
end;
{$ELSE}
var
  P: TProcess;
begin
  { Run through sh so the launched app's stdout/stderr go to /dev/null instead
    of scribbling over the TUI (Chromium-based browsers are noisy). The target
    is passed as $1 - a discrete argument, never interpolated into the script -
    so it can't be read as shell metacharacters. Don't wait on the child. }
  P := TProcess.Create(nil);
  try
    try
      P.Executable := '/bin/sh';
      P.Parameters.Add('-c');
      P.Parameters.Add('xdg-open "$1" >/dev/null 2>&1');
      P.Parameters.Add('sh');
      P.Parameters.Add(Target);
      P.Execute;
    except
      on E: Exception do
        { xdg-open missing or unlaunchable: silently give up rather than
          take down the UI. }
    end;
  finally
    P.Free;
  end;
end;
{$ENDIF}

end.
