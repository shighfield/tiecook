program uexport_html_test;

{ Tests for HTML export: pages written, escaping, sections, favorites,
  personal section, image copy, and the safety refusal. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, urecipe, uconfig, ulibrary, uexport_html;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

procedure WipeDir(const d: string);
var
  Info: TSearchRec;
begin
  if not DirectoryExists(d) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Attr and faDirectory) = 0 then
        DeleteFile(IncludeTrailingPathDelimiter(d) + Info.Name)
      else if (Info.Name <> '.') and (Info.Name <> '..') then
        WipeDir(IncludeTrailingPathDelimiter(d) + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  RemoveDir(d);
end;

function ReadFile(const fn: string): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(fn);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

var
  root, libdir, outdir: string;
  Lib: TLibrary;
  Cfg: TConfig;
  R: TRecipe;
  wasUpdate: Boolean;
  n: Integer;
  html, page: string;
  ms: TMemoryStream;

begin
  root := IncludeTrailingPathDelimiter(GetTempDir) + 'tc2exp_test';
  WipeDir(root);
  libdir := IncludeTrailingPathDelimiter(root) + 'lib';
  outdir := IncludeTrailingPathDelimiter(root) + 'site';
  ForceDirectories(libdir);

  { seed a library }
  Lib := TLibrary.Create(libdir);
  try
    R := Default(TRecipe); InitRecipe(R);
    R.Title := 'Apple & Onion <Tart>';   { chars that must be escaped }
    R.Source := 'mealmaster'; R.SourceId := 'a.mmf';
    AddKeyword(R, 'Shawn'); AddKeyword(R, 'Favorite');
    R.Servings := '4';
    AddIngredient(R, 'Crust', True);
    AddIngredient(R, '1 cup flour');
    AddStep(R, 'Make it.');
    Lib.AddOrUpdate(R, wasUpdate);

    { a recipe with an explicit photo }
    R := Default(TRecipe); InitRecipe(R);
    R.Title := 'Squash Soup';
    R.Source := 'mealmaster'; R.SourceId := 's.mmf';
    R.Image := 'squash-soup.jpg';
    AddIngredient(R, '1 squash');
    AddStep(R, 'Roast, blend.');
    Lib.AddOrUpdate(R, wasUpdate);

    { a recipe with NO image field but a drop-in <slug>.jpg beside it }
    R := Default(TRecipe); InitRecipe(R);
    R.Title := 'Drop Scone';
    R.Source := 'mealmaster'; R.SourceId := 'd.mmf';
    AddStep(R, 'Griddle it.');
    Lib.AddOrUpdate(R, wasUpdate);

    { a recipe whose image field names a file that does not exist }
    R := Default(TRecipe); InitRecipe(R);
    R.Title := 'Ghost Pie';
    R.Source := 'mealmaster'; R.SourceId := 'g.mmf';
    R.Image := 'nope.jpg';
    AddStep(R, 'Vanish.');
    Lib.AddOrUpdate(R, wasUpdate);
  finally
    Lib.Free;
  end;

  { drop fake images next to the recipe files so export can copy them }
  ms := TMemoryStream.Create;
  try
    ms.WriteByte(255); ms.WriteByte(216); ms.WriteByte(255); { JPEG-ish bytes }
    ms.SaveToFile(IncludeTrailingPathDelimiter(libdir) + 'squash-soup.jpg');
    ms.SaveToFile(IncludeTrailingPathDelimiter(libdir) + 'drop-scone.jpg'); { drop-in }
  finally
    ms.Free;
  end;

  { fake header/background images the config will point at }
  ms := TMemoryStream.Create;
  try
    ms.WriteByte(137); ms.WriteByte(80); ms.WriteByte(78); ms.WriteByte(71); { PNG-ish }
    ms.SaveToFile(IncludeTrailingPathDelimiter(root) + 'header.png');
    ms.SaveToFile(IncludeTrailingPathDelimiter(root) + 'bg.jpg');
  finally
    ms.Free;
  end;

  Cfg := TConfig.Create(IncludeTrailingPathDelimiter(root) + 'config.ini');
  Cfg.SiteTitle := 'Test Recipes';
  Cfg.PersonalKeyword := 'Shawn';
  Cfg.FavoriteKeyword := 'Favorite';
  Cfg.HeaderImage := IncludeTrailingPathDelimiter(root) + 'header.png';
  Cfg.BackgroundImage := IncludeTrailingPathDelimiter(root) + 'bg.jpg';

  Lib := TLibrary.Create(libdir);
  try
    Lib.Load;
    n := ExportHtml(Lib, Cfg, outdir);
    Check(n = 4, 'exported all four recipes');

    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'index.html'), 'index.html written');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'style.css'), 'style.css written');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'apple-onion-tart.htm'),
          'recipe page written with slug name');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'images' + PathDelim + 'squash-soup.jpg'),
          'explicit recipe image copied into images/');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'images' + PathDelim + 'drop-scone.jpg'),
          'drop-in <slug>.jpg copied into images/');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'images' + PathDelim + 'header.png'),
          'header image copied into images/');
    Check(FileExists(IncludeTrailingPathDelimiter(outdir) + 'images' + PathDelim + 'bg.jpg'),
          'background image copied into images/');

    html := ReadFile(IncludeTrailingPathDelimiter(outdir) + 'index.html');
    Check(Pos('Apple &amp; Onion &lt;Tart&gt;', html) > 0, 'index escapes title');
    Check(Pos('id="personal"', html) > 0, 'personal section present');
    Check(Pos('class="favorite"', html) > 0, 'favorite recipe highlighted');
    Check(Pos('searchRecipes', html) > 0, 'live-search script present');
    Check(Pos('>MINE<', html) > 0, 'personal nav link present');
    Check(Pos('src="images/header.png"', html) > 0, 'header image referenced in index');

    Check(Pos('images/bg.jpg', ReadFile(IncludeTrailingPathDelimiter(outdir) + 'style.css')) > 0,
          'background image referenced in style.css');

    page := ReadFile(IncludeTrailingPathDelimiter(outdir) + 'apple-onion-tart.htm');
    Check(Pos('<h3>Crust</h3>', page) > 0, 'ingredient sub-heading rendered');
    Check(Pos('<li>1 cup flour</li>', page) > 0, 'ingredient list item rendered');
    Check(Pos('PRINT THIS RECIPE', page) > 0, 'print button present');
    Check(Pos('images/squash-soup.jpg', ReadFile(IncludeTrailingPathDelimiter(outdir) + 'squash-soup.htm')) > 0,
          'explicit photo referenced on its recipe page');
    Check(Pos('images/drop-scone.jpg', ReadFile(IncludeTrailingPathDelimiter(outdir) + 'drop-scone.htm')) > 0,
          'drop-in photo referenced on its recipe page');
    Check(Pos('<img', ReadFile(IncludeTrailingPathDelimiter(outdir) + 'ghost-pie.htm')) = 0,
          'missing image produces no <img> tag');
  finally
    Lib.Free;
  end;

  { safety: re-export into our own dir is allowed (marker present) }
  Lib := TLibrary.Create(libdir);
  try
    Lib.Load;
    try
      ExportHtml(Lib, Cfg, outdir);
      Check(True, 're-export into our own site dir is allowed');
    except
      on E: EExportUnsafe do Check(False, 're-export wrongly refused our own dir');
    end;

    { safety: refuse a non-empty dir we do not own }
    ms := TMemoryStream.Create;
    try
      ForceDirectories(IncludeTrailingPathDelimiter(root) + 'foreign');
      ms.WriteByte(65);
      ms.SaveToFile(IncludeTrailingPathDelimiter(root) + 'foreign' + PathDelim + 'keep.txt');
    finally
      ms.Free;
    end;
    try
      ExportHtml(Lib, Cfg, IncludeTrailingPathDelimiter(root) + 'foreign');
      Check(False, 'export should have refused a foreign non-empty dir');
    except
      on E: EExportUnsafe do Check(True, 'refused a foreign non-empty dir');
    end;
  finally
    Lib.Free;
  end;

  Cfg.Free;
  WipeDir(root);

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
