program tiecook;

{$mode objfpc}{$H+}

uses
  SysUtils, uconfig, uapi, ufv;

var
  Cfg: TTiecookConfig;
  ErrMsg: string;
  Client: TTandoorClient;
begin
  if not LoadConfig(Cfg, ErrMsg) then
  begin
    WriteLn(StdErr, ErrMsg);
    Halt(1);
  end;

  Client := TTandoorClient.Create(Cfg.BaseUrl, Cfg.Token);
  try
    try
      RunTUI(Client);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'Fatal error: ', E.Message);
        Halt(1);
      end;
    end;
  finally
    Client.Free;
  end;
end.
