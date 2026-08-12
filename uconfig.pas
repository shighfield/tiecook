unit uconfig;

{$mode objfpc}{$H+}

interface

type
  TTiecookConfig = record
    BaseUrl: string;
    Token: string;
  end;

function GetConfigPath: string;
function LoadConfig(out Cfg: TTiecookConfig; out ErrMsg: string): Boolean;

implementation

uses
  SysUtils, Classes;

function GetConfigPath: string;
var
  XdgConfigHome: string;
begin
  XdgConfigHome := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if XdgConfigHome = '' then
    XdgConfigHome := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config';
  Result := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(XdgConfigHome) + 'tiecook') + 'config';
end;

const
  ExampleText =
    'Example config file:'                                                + LineEnding +
    '  # tiecook config'                                                  + LineEnding +
    '  base_url=https://recipes.example.com:8443'                        + LineEnding +
    '  token=tda_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'                + LineEnding +
    '(Generate a token in the Tandoor web UI under Settings > API.)';

function LoadConfig(out Cfg: TTiecookConfig; out ErrMsg: string): Boolean;
var
  Path: string;
  Lines: TStringList;
  I: Integer;
  Line, Key, Value: string;
  EqPos: Integer;
begin
  Result := False;
  Cfg.BaseUrl := '';
  Cfg.Token := '';
  Path := GetConfigPath;

  if not FileExists(Path) then
  begin
    ErrMsg := 'Config file not found: ' + Path + LineEnding + ExampleText;
    Exit;
  end;

  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        ErrMsg := 'Could not read config file ' + Path + ': ' + E.Message;
        Exit;
      end;
    end;

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;

      EqPos := Pos('=', Line);
      if EqPos = 0 then
        Continue;

      Key := Trim(Copy(Line, 1, EqPos - 1));
      Value := Trim(Copy(Line, EqPos + 1, Length(Line)));

      if Key = 'base_url' then
        Cfg.BaseUrl := Value
      else if Key = 'token' then
        Cfg.Token := Value;
    end;
  finally
    Lines.Free;
  end;

  while (Length(Cfg.BaseUrl) > 0) and (Cfg.BaseUrl[Length(Cfg.BaseUrl)] = '/') do
    Delete(Cfg.BaseUrl, Length(Cfg.BaseUrl), 1);

  if Cfg.BaseUrl = '' then
  begin
    ErrMsg := 'Config file ' + Path + ' is missing "base_url".' + LineEnding + ExampleText;
    Exit;
  end;

  if Cfg.Token = '' then
  begin
    ErrMsg := 'Config file ' + Path + ' is missing "token".' + LineEnding + ExampleText;
    Exit;
  end;

  Result := True;
end;

end.
