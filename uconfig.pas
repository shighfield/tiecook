unit uconfig;

{ tiecook2 configuration: an INI file under the user's config dir.

    [library]
    dir=<recipe library path>

    [tandoor]
    url=
    token=

    [site]
    title=My Recipes
    intro=
    footer=
    header_image=
    background_image=
    personal_keyword=
    favorite_keyword=Favorite

  [tandoor] is used by the Tandoor importer (later); [site] by HTML export.
  personal_keyword marks the personal section (empty = none); favorite_keyword
  marks highlighted recipes. Comments in the file must be on their own line
  starting with ';' - TIniFile keeps any trailing "; ..." as part of the value.

  Location: $XDG_CONFIG_HOME/tiecook2/config.ini (or ~/.config/tiecook2/...)
  on unix, %APPDATA%\tiecook2\config.ini on Windows. }

{$mode objfpc}{$H+}

interface

type
  TConfig = class
  private
    FPath: string;
  public
    LibraryDir: string;
    TandoorUrl: string;
    TandoorToken: string;
    SiteTitle: string;
    SiteIntro: string;
    SiteFooter: string;
    HeaderImage: string;
    BackgroundImage: string;
    PersonalKeyword: string;
    FavoriteKeyword: string;
    Editor: string;
    Splash: Boolean;       { show the title screen on launch }
    constructor Create(const APath: string = '');
    procedure Load;
    procedure Save;
    { The editor command for `e`/edit: config editor, else $VISUAL, else
      $EDITOR, else a per-OS default (nano / notepad). }
    function EditorCommand: string;
    { If TandoorUrl/TandoorToken are still empty, fill them from the existing
      tiecook config (~/.config/tiecook/config, keys base_url + token). }
    procedure ResolveTandoorFromTiecook;
    property Path: string read FPath;
  end;

{ The user's data/config locations, resolved per-OS. Public so the browser
  and importers can report or default them. }
function DefaultConfigFile: string;
function DefaultLibraryDir: string;

implementation

uses
  SysUtils, Classes, IniFiles;

{$ifdef windows}
function AppData(const Leaf: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA'))
            + 'tiecook2\' + Leaf;
end;

function DefaultConfigFile: string;
begin
  Result := AppData('config.ini');
end;

function DefaultLibraryDir: string;
begin
  Result := AppData('recipes');
end;

function TiecookConfigFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA'))
            + 'tiecook\config';
end;
{$else}
function ConfigBase: string;
begin
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetUserDir) + '.config';
end;

function DataBase: string;
begin
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetUserDir) + '.local/share';
end;

function DefaultConfigFile: string;
begin
  Result := IncludeTrailingPathDelimiter(ConfigBase) + 'tiecook2/config.ini';
end;

function DefaultLibraryDir: string;
begin
  Result := IncludeTrailingPathDelimiter(DataBase) + 'tiecook2/recipes';
end;

function TiecookConfigFile: string;
begin
  Result := IncludeTrailingPathDelimiter(ConfigBase) + 'tiecook/config';
end;
{$endif}

constructor TConfig.Create(const APath: string);
begin
  inherited Create;
  if APath <> '' then FPath := APath else FPath := DefaultConfigFile;
  { defaults }
  LibraryDir := DefaultLibraryDir;
  TandoorUrl := '';
  TandoorToken := '';
  SiteTitle := 'My Recipes';
  SiteIntro := '';
  SiteFooter := '';
  HeaderImage := '';
  BackgroundImage := '';
  PersonalKeyword := '';         { empty -> no personal section (generic default) }
  FavoriteKeyword := 'Favorite';
  Editor := '';
  Splash := True;
end;

function TConfig.EditorCommand: string;
begin
  Result := Trim(Editor);
  if Result <> '' then Exit;
  Result := Trim(GetEnvironmentVariable('VISUAL'));
  if Result <> '' then Exit;
  Result := Trim(GetEnvironmentVariable('EDITOR'));
  if Result <> '' then Exit;
  {$ifdef windows}Result := 'notepad';{$else}Result := 'nano';{$endif}
end;

procedure TConfig.Load;
var
  Ini: TIniFile;
begin
  if not FileExists(FPath) then Exit;   { keep defaults }
  Ini := TIniFile.Create(FPath);
  try
    LibraryDir := Ini.ReadString('library', 'dir', LibraryDir);
    if Trim(LibraryDir) = '' then LibraryDir := DefaultLibraryDir;
    TandoorUrl := Ini.ReadString('tandoor', 'url', TandoorUrl);
    TandoorToken := Ini.ReadString('tandoor', 'token', TandoorToken);
    SiteTitle := Ini.ReadString('site', 'title', SiteTitle);
    SiteIntro := Ini.ReadString('site', 'intro', SiteIntro);
    SiteFooter := Ini.ReadString('site', 'footer', SiteFooter);
    HeaderImage := Ini.ReadString('site', 'header_image', HeaderImage);
    BackgroundImage := Ini.ReadString('site', 'background_image', BackgroundImage);
    PersonalKeyword := Ini.ReadString('site', 'personal_keyword', PersonalKeyword);
    FavoriteKeyword := Ini.ReadString('site', 'favorite_keyword', FavoriteKeyword);
    Editor := Ini.ReadString('editor', 'command', Editor);
    Splash := Ini.ReadBool('ui', 'splash', Splash);
  finally
    Ini.Free;
  end;
end;

procedure TConfig.ResolveTandoorFromTiecook;
var
  SL: TStringList;
  i, p: Integer;
  key, val, fn: string;
begin
  if (Trim(TandoorUrl) <> '') and (Trim(TandoorToken) <> '') then Exit;
  fn := TiecookConfigFile;
  if not FileExists(fn) then Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(fn);
    for i := 0 to SL.Count - 1 do
    begin
      p := Pos('=', SL[i]);
      if p = 0 then Continue;
      key := LowerCase(Trim(Copy(SL[i], 1, p - 1)));
      val := Trim(Copy(SL[i], p + 1, Length(SL[i])));
      if (key = 'base_url') and (Trim(TandoorUrl) = '') then TandoorUrl := val
      else if (key = 'token') and (Trim(TandoorToken) = '') then TandoorToken := val;
    end;
  finally
    SL.Free;
  end;
end;

procedure TConfig.Save;
var
  Ini: TIniFile;
begin
  ForceDirectories(ExtractFileDir(FPath));
  Ini := TIniFile.Create(FPath);
  try
    Ini.WriteString('library', 'dir', LibraryDir);
    Ini.WriteString('tandoor', 'url', TandoorUrl);
    Ini.WriteString('tandoor', 'token', TandoorToken);
    Ini.WriteString('site', 'title', SiteTitle);
    Ini.WriteString('site', 'intro', SiteIntro);
    Ini.WriteString('site', 'footer', SiteFooter);
    Ini.WriteString('site', 'header_image', HeaderImage);
    Ini.WriteString('site', 'background_image', BackgroundImage);
    Ini.WriteString('site', 'personal_keyword', PersonalKeyword);
    Ini.WriteString('site', 'favorite_keyword', FavoriteKeyword);
    Ini.WriteString('editor', 'command', Editor);
    Ini.WriteBool('ui', 'splash', Splash);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

end.
