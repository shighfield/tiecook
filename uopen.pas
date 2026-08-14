unit uopen;

{$mode objfpc}{$H+}

interface

{ Open a URL in the user's default browser. Fire-and-forget: returns
  immediately and never raises, so a failure to launch can't crash the TUI. }
procedure OpenUrl(const Url: string);

implementation

uses
  {$IFDEF WINDOWS}
  Windows, ShellApi,
  {$ELSE}
  Process,
  {$ENDIF}
  SysUtils;

procedure OpenUrl(const Url: string);
{$IFDEF WINDOWS}
begin
  ShellExecute(0, 'open', PChar(Url), nil, nil, SW_SHOWNORMAL);
end;
{$ELSE}
var
  P: TProcess;
begin
  { Pass the URL as a discrete argument (not a shell string) so it can't be
    interpreted as shell metacharacters. Don't wait on the child. }
  P := TProcess.Create(nil);
  try
    try
      P.Executable := 'xdg-open';
      P.Parameters.Add(Url);
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
