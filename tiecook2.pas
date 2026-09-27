program tiecook2;

{ Standalone recipe library.

    tiecook2                                    browse the library (later)
    tiecook2 list [--library DIR]               list all recipes
    tiecook2 search [--library DIR] <words>     search titles/keywords/text
    tiecook2 import mealmaster [--library DIR] <file|dir>...

  The library directory defaults to the value in the config file. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, urecipe, uconfig, ulibrary, uimp_mealmaster, uexport_html;

procedure Usage;
begin
  WriteLn('usage:');
  WriteLn('  tiecook2 list [--library DIR]');
  WriteLn('  tiecook2 search [--library DIR] <words>');
  WriteLn('  tiecook2 import mealmaster [--library DIR] <file|dir>...');
  WriteLn('  tiecook2 export html [--library DIR] <output-dir>');
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

{ --- file gathering for import --- }

procedure CollectMMF(const Path: string; List: TStrings);
var
  Info: TSearchRec;
  dir: string;
begin
  if DirectoryExists(Path) then
  begin
    dir := IncludeTrailingPathDelimiter(Path);
    if FindFirst(dir + '*', faAnyFile, Info) = 0 then
    begin
      repeat
        if (Info.Attr and faDirectory) = 0 then
          if LowerCase(ExtractFileExt(Info.Name)) = '.mmf' then
            List.Add(dir + Info.Name);
      until FindNext(Info) <> 0;
      FindClose(Info);
    end;
  end
  else if FileExists(Path) then
    List.Add(Path)
  else
    WriteLn(StdErr, 'tiecook2: no such file or directory: ', Path);
end;

function ReadFileText(const FileName: string): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    Result := SL.Text;
  finally
    SL.Free;
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

procedure DoImportMealMaster(Args: TStrings);
var
  Lib: TLibrary;
  Files: TStringList;
  today, txt, slug, base: string;
  i, ri, total, updated: Integer;
  recipes: TRecipeArray;
  wasUpdate: Boolean;
begin
  Lib := OpenLibrary(PopLibrary(Args));
  Files := TStringList.Create;
  try
    if Args.Count = 0 then begin Usage; Halt(1); end;
    for i := 0 to Args.Count - 1 do
      CollectMMF(Args[i], Files);
    if Files.Count = 0 then
    begin
      WriteLn(StdErr, 'tiecook2: no .mmf files found'); Halt(1);
    end;

    today := FormatDateTime('yyyy-mm-dd', Now);
    total := 0; updated := 0;
    for i := 0 to Files.Count - 1 do
    begin
      txt := ReadFileText(Files[i]);
      recipes := ImportMealMasterText(txt);
      base := ExtractFileName(Files[i]);
      for ri := 0 to High(recipes) do
      begin
        if Trim(recipes[ri].Title) = '' then recipes[ri].Title := 'Untitled';
        if Length(recipes) > 1 then
          recipes[ri].SourceId := base + '#' + Slugify(recipes[ri].Title)
        else
          recipes[ri].SourceId := base;
        recipes[ri].Imported := today;

        slug := Lib.AddOrUpdate(recipes[ri], wasUpdate);
        if wasUpdate then Inc(updated);
        WriteLn('  ', BoolToStr(wasUpdate, 'update', 'new   '), '  ',
                recipes[ri].Title, '  ->  ', slug, '.txt');
        Inc(total);
      end;
    end;
    WriteLn(Format('Imported %d recipe(s) (%d updated) from %d file(s) into %s',
                   [total, updated, Files.Count, Lib.Dir]));
  finally
    Files.Free;
    Lib.Free;
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
        WriteLn(StdErr, 'tiecook2: warning: library is empty (', Cfg.LibraryDir, ')');
      try
        n := ExportHtml(Lib, Cfg, outDir);
        WriteLn(Format('Exported %d recipe(s) to %s', [n, outDir]));
      except
        on E: EExportUnsafe do
        begin
          WriteLn(StdErr, 'tiecook2: ', E.Message);
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

{ --- entry point --- }

procedure Dispatch;
var
  Args: TStringList;
  cmd, src: string;
  i: Integer;
begin
  if ParamCount = 0 then
  begin
    WriteLn('tiecook2: browser not implemented yet');
    Exit;
  end;

  cmd := LowerCase(ParamStr(1));
  Args := TStringList.Create;
  try
    if cmd = 'import' then
    begin
      src := LowerCase(ParamStr(2));
      for i := 3 to ParamCount do Args.Add(ParamStr(i));
      if src = 'mealmaster' then
        DoImportMealMaster(Args)
      else
      begin
        WriteLn(StdErr, 'tiecook2: unknown or missing import source');
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
        WriteLn(StdErr, 'tiecook2: unknown or missing export format');
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
