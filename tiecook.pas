program tiecook;

{ Standalone recipe library.

    tiecook                                    browse the library (later)
    tiecook list [--library DIR]               list all recipes
    tiecook search [--library DIR] <words>     search titles/keywords/text
    tiecook import mealmaster [--library DIR] <file|dir>...

  The library directory defaults to the value in the config file. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, urecipe, uconfig, ulibrary, uimp_mealmaster, uexport_html,
  uapi, uimp_tandoor, uui;

procedure Usage;
begin
  WriteLn('usage:');
  WriteLn('  tiecook list [--library DIR]');
  WriteLn('  tiecook search [--library DIR] <words>');
  WriteLn('  tiecook import mealmaster [--library DIR] <file|dir>...');
  WriteLn('  tiecook import tandoor [--library DIR] [--url URL] [--token TOKEN] [--limit N]');
  WriteLn('  tiecook export html [--library DIR] <output-dir>');
end;

{ Load the config, creating a default file the first time so the user has
  something to edit (site title, personal keyword, ...). }
function LoadOrSeedConfig: TConfig;
begin
  Result := TConfig.Create;
  if FileExists(Result.Path) then
    Result.Load
  else
  begin
    Result.Save;
    WriteLn('Wrote a default config you can edit: ', Result.Path);
  end;
end;

{ Pull a --library (or --out) DIR option out of Args, returning its value or
  '' when absent. The option and its value are removed from Args. }
function PopLibrary(Args: TStrings): string;
var
  i: Integer;
begin
  Result := '';
  i := 0;
  while i < Args.Count do
    if (Args[i] = '--library') or (Args[i] = '--out') then
    begin
      if i + 1 < Args.Count then
      begin
        Result := Args[i + 1];
        Args.Delete(i + 1);
      end;
      Args.Delete(i);
    end
    else
      Inc(i);
end;

{ Pull "--name VALUE" out of Args, returning VALUE or ''. }
function PopOption(Args: TStrings; const Name: string): string;
var
  i: Integer;
begin
  Result := '';
  i := 0;
  while i < Args.Count do
    if Args[i] = Name then
    begin
      if i + 1 < Args.Count then
      begin
        Result := Args[i + 1];
        Args.Delete(i + 1);
      end;
      Args.Delete(i);
    end
    else
      Inc(i);
end;

function ResolveLibraryDir(const Override: string): string;
var
  cfg: TConfig;
begin
  if Override <> '' then
    Exit(Override);
  cfg := TConfig.Create;
  try
    cfg.Load;
    Result := cfg.LibraryDir;
  finally
    cfg.Free;
  end;
end;

function OpenLibrary(const Override: string): TLibrary;
begin
  Result := TLibrary.Create(ResolveLibraryDir(Override));
  Result.Load;
end;

function KeywordList(const R: TRecipe): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(R.Keywords) do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + R.Keywords[i];
  end;
end;

{ --- commands --- }

procedure DoList(Args: TStrings);
var
  Lib: TLibrary;
  order: TIntArray;
  i: Integer;
  R: TRecipe;
begin
  Lib := OpenLibrary(PopLibrary(Args));
  try
    order := Lib.Search('');   { all, sorted by title }
    for i := 0 to High(order) do
    begin
      R := Lib.Recipe(order[i]);
      Write(R.Title);
      if Length(R.Keywords) > 0 then Write('  [', KeywordList(R), ']');
      WriteLn('  (', R.Source, ':', R.SourceId, ')');
    end;
    WriteLn(Format('%d recipe(s) in %s', [Lib.Count, Lib.Dir]));
  finally
    Lib.Free;
  end;
end;

procedure DoSearch(Args: TStrings);
var
  Lib: TLibrary;
  query: string;
  hits: TIntArray;
  i: Integer;
  R: TRecipe;
  libOverride: string;
begin
  libOverride := PopLibrary(Args);
  query := '';
  for i := 0 to Args.Count - 1 do
  begin
    if query <> '' then query := query + ' ';
    query := query + Args[i];
  end;
  if query = '' then begin Usage; Halt(1); end;

  Lib := OpenLibrary(libOverride);
  try
    hits := Lib.Search(query);
    for i := 0 to High(hits) do
    begin
      R := Lib.Recipe(hits[i]);
      Write(R.Title);
      if Length(R.Keywords) > 0 then Write('  [', KeywordList(R), ']');
      WriteLn('  ->  ', Lib.Slug(hits[i]), '.txt');
    end;
    WriteLn(Format('%d match(es) for "%s"', [Length(hits), query]));
  finally
    Lib.Free;
  end;
end;

procedure MMProgress(const Title: string; WasUpdate: Boolean);
begin
  if WasUpdate then Write('  update  ') else Write('  new     ');
  WriteLn(Title);
end;

procedure DoImportMealMaster(Args: TStrings);
var
  Lib: TLibrary;
  Files: TStringList;
  i, total, updated: Integer;
begin
  Lib := OpenLibrary(PopLibrary(Args));
  Files := TStringList.Create;
  try
    if Args.Count = 0 then begin Usage; Halt(1); end;
    for i := 0 to Args.Count - 1 do
      CollectMMFiles(Args[i], Files);
    if Files.Count = 0 then
    begin
      WriteLn(StdErr, 'tiecook: no .mmf files found'); Halt(1);
    end;
    total := ImportMealMasterFiles(Files, Lib, updated, @MMProgress);
    WriteLn(Format('Imported %d recipe(s) (%d updated) from %d file(s) into %s',
                   [total, updated, Files.Count, Lib.Dir]));
  finally
    Files.Free;
    Lib.Free;
  end;
end;

procedure TandoorProgress(const Title: string; WasUpdate: Boolean);
begin
  if WasUpdate then Write('  update  ') else Write('  new     ');
  WriteLn(Title);
end;

procedure DoImportTandoor(Args: TStrings);
var
  Cfg: TConfig;
  Lib: TLibrary;
  Client: TTandoorClient;
  libOverride, url, token, limitStr: string;
  n, updated, failed, limit: Integer;
begin
  libOverride := PopLibrary(Args);
  url := PopOption(Args, '--url');
  token := PopOption(Args, '--token');
  limitStr := PopOption(Args, '--limit');
  limit := StrToIntDef(limitStr, 0);
  if Args.Count <> 0 then begin Usage; Halt(1); end;

  Cfg := LoadOrSeedConfig;
  try
    if libOverride <> '' then Cfg.LibraryDir := libOverride;
    if url <> '' then Cfg.TandoorUrl := url;
    if token <> '' then Cfg.TandoorToken := token;
    Cfg.ResolveTandoorFromTiecook;         { fall back to tiecook's config }
    while (Cfg.TandoorUrl <> '') and (Cfg.TandoorUrl[Length(Cfg.TandoorUrl)] = '/') do
      Delete(Cfg.TandoorUrl, Length(Cfg.TandoorUrl), 1);

    if (Trim(Cfg.TandoorUrl) = '') or (Trim(Cfg.TandoorToken) = '') then
    begin
      WriteLn(StdErr, 'tiecook: no Tandoor url/token. Set [tandoor] in ',
              Cfg.Path, ', pass --url/--token, or configure tiecook.');
      Halt(1);
    end;

    Lib := TLibrary.Create(Cfg.LibraryDir);
    try
      ForceDirectories(Cfg.LibraryDir);
      Lib.Load;
      Client := TTandoorClient.Create(Cfg.TandoorUrl, Cfg.TandoorToken);
      try
        try
          WriteLn('Importing from ', Cfg.TandoorUrl, ' ...');
          n := ImportTandoor(Client, Lib, True, updated, failed, @TandoorProgress, limit);
          WriteLn(Format('Imported %d recipe(s) (%d updated, %d failed) into %s',
                         [n, updated, failed, Cfg.LibraryDir]));
          if failed > 0 then ExitCode := 1;
        except
          on E: ETandoorError do
          begin
            WriteLn(StdErr, 'tiecook: Tandoor error: ', E.Message);
            Halt(1);
          end;
        end;
      finally
        Client.Free;
      end;
    finally
      Lib.Free;
    end;
  finally
    Cfg.Free;
  end;
end;

procedure DoExportHtml(Args: TStrings);
var
  libOverride, outDir: string;
  Cfg: TConfig;
  Lib: TLibrary;
  n: Integer;
begin
  libOverride := PopLibrary(Args);
  if Args.Count <> 1 then begin Usage; Halt(1); end;
  outDir := Args[0];

  Cfg := LoadOrSeedConfig;
  try
    if libOverride <> '' then Cfg.LibraryDir := libOverride;
    Lib := TLibrary.Create(Cfg.LibraryDir);
    try
      Lib.Load;
      if Lib.Count = 0 then
        WriteLn(StdErr, 'tiecook: warning: library is empty (', Cfg.LibraryDir, ')');
      try
        n := ExportHtml(Lib, Cfg, outDir);
        WriteLn(Format('Exported %d recipe(s) to %s', [n, outDir]));
      except
        on E: EExportUnsafe do
        begin
          WriteLn(StdErr, 'tiecook: ', E.Message);
          Halt(1);
        end;
      end;
    finally
      Lib.Free;
    end;
  finally
    Cfg.Free;
  end;
end;

procedure DoBrowse(Args: TStrings);
var
  Cfg: TConfig;
  Lib: TLibrary;
  libOverride: string;
begin
  libOverride := PopLibrary(Args);
  if Args.Count <> 0 then begin Usage; Halt(1); end;
  Cfg := LoadOrSeedConfig;
  try
    if libOverride <> '' then Cfg.LibraryDir := libOverride;
    Lib := TLibrary.Create(Cfg.LibraryDir);
    try
      Lib.Load;
      RunBrowser(Lib, Cfg);
    finally
      Lib.Free;
    end;
  finally
    Cfg.Free;
  end;
end;

{ --- entry point --- }

procedure Dispatch;
var
  Args: TStringList;
  cmd, src: string;
  i: Integer;
begin
  cmd := LowerCase(ParamStr(1));
  Args := TStringList.Create;
  try
    if ParamCount = 0 then
    begin
      DoBrowse(Args);                       { no arguments: browse }
    end
    else if (Copy(cmd, 1, 2) = '--') then
    begin
      { options with no command, e.g. `tiecook --library DIR`: browse }
      for i := 1 to ParamCount do Args.Add(ParamStr(i));
      DoBrowse(Args);
    end
    else if cmd = 'import' then
    begin
      src := LowerCase(ParamStr(2));
      for i := 3 to ParamCount do Args.Add(ParamStr(i));
      if src = 'mealmaster' then
        DoImportMealMaster(Args)
      else if src = 'tandoor' then
        DoImportTandoor(Args)
      else
      begin
        WriteLn(StdErr, 'tiecook: unknown or missing import source');
        Usage; ExitCode := 1;
      end;
    end
    else if cmd = 'export' then
    begin
      src := LowerCase(ParamStr(2));
      for i := 3 to ParamCount do Args.Add(ParamStr(i));
      if src = 'html' then
        DoExportHtml(Args)
      else
      begin
        WriteLn(StdErr, 'tiecook: unknown or missing export format');
        Usage; ExitCode := 1;
      end;
    end
    else
    begin
      for i := 2 to ParamCount do Args.Add(ParamStr(i));
      if cmd = 'list' then DoList(Args)
      else if cmd = 'search' then DoSearch(Args)
      else begin Usage; ExitCode := 1; end;
    end;
  finally
    Args.Free;
  end;
end;

begin
  Dispatch;
end.
