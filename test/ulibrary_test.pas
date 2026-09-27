program ulibrary_test;

{ Tests for the library layer: scan/index, search, and dedup on AddOrUpdate. }

{$mode objfpc}{$H+}

uses
  SysUtils, urecipe, uconfig, ulibrary;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

function MakeRecipe(const Title, Source, SourceId: string): TRecipe;
begin
  InitRecipe(Result);
  Result.Title := Title;
  Result.Source := Source;
  Result.SourceId := SourceId;
end;

{ Delete every file in a flat directory, then the directory itself, so the
  test starts and ends from a clean slate regardless of prior runs. }
procedure WipeDir(const d: string);
var
  Info: TSearchRec;
begin
  if not DirectoryExists(d) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(d) + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Attr and faDirectory) = 0 then
        DeleteFile(IncludeTrailingPathDelimiter(d) + Info.Name);
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  RemoveDir(d);
end;

var
  dir, cfgpath: string;
  Lib: TLibrary;
  R: TRecipe;
  hits: TIntArray;
  wasUpdate: Boolean;
  slug1, slug2: string;
  cfg: TConfig;

begin
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'tc2lib_test';
  WipeDir(dir);                 { clear anything a previous run left behind }
  ForceDirectories(dir);

  Lib := TLibrary.Create(dir);
  try
    Lib.Load;
    Check(Lib.Count = 0, 'empty library');

    { add two recipes }
    R := MakeRecipe('Egg Drop Soup', 'mealmaster', 'egg.mmf');
    AddKeyword(R, 'Soup'); AddKeyword(R, 'Shawn');
    AddIngredient(R, '4 cup chicken stock');
    slug1 := Lib.AddOrUpdate(R, wasUpdate);
    Check(not wasUpdate, 'first add is not an update');
    Check(slug1 = 'egg-drop-soup', 'slug from title');

    R := MakeRecipe('Squash Soup', 'mealmaster', 'squash.mmf');
    AddKeyword(R, 'Soup');
    AddIngredient(R, '1 Acorn squash');
    Lib.AddOrUpdate(R, wasUpdate);
    Check(Lib.Count = 2, 'two recipes after two adds');
    Check(FileExists(IncludeTrailingPathDelimiter(dir) + 'egg-drop-soup.txt'),
          'file written to disk');

    { re-add the first with a changed body: must overwrite, not duplicate }
    R := MakeRecipe('Egg Drop Soup', 'mealmaster', 'egg.mmf');
    AddKeyword(R, 'Soup');
    AddIngredient(R, '5 cup chicken stock (more)');
    slug2 := Lib.AddOrUpdate(R, wasUpdate);
    Check(wasUpdate, 're-add of same source is an update');
    Check(slug2 = slug1, 'update keeps the same slug');
    Check(Lib.Count = 2, 'update does not grow the library');

    { different recipe, same title -> unique slug, not an update }
    R := MakeRecipe('Egg Drop Soup', 'mealmaster', 'other.mmf');
    slug2 := Lib.AddOrUpdate(R, wasUpdate);
    Check(not wasUpdate, 'same title but different source is a new recipe');
    Check(slug2 = 'egg-drop-soup-2', 'title clash gets a -2 slug');
    Check(Lib.Count = 3, 'three recipes now');
  finally
    Lib.Free;
  end;

  { reload from disk and search }
  Lib := TLibrary.Create(dir);
  try
    Lib.Load;
    Check(Lib.Count = 3, 'reload sees all three files');

    hits := Lib.Search('squash');
    Check(Length(hits) = 1, 'search title: squash');

    hits := Lib.Search('Soup');            { title + keyword hits }
    Check(Length(hits) = 3, 'search matches title or keyword across all three');

    hits := Lib.Search('acorn');           { ingredient hit }
    Check(Length(hits) = 1, 'search matches ingredient text');

    hits := Lib.Search('nonesuch');
    Check(Length(hits) = 0, 'search miss');

    { multi-word: all terms must match, across different fields
      ("soup" is a keyword, "chicken" is in the ingredient) }
    hits := Lib.Search('soup chicken');
    Check(Length(hits) = 1, 'multi-word AND across fields');
    hits := Lib.Search('soup nonesuch');
    Check(Length(hits) = 0, 'multi-word AND fails when one term misses');

    hits := Lib.Search('');
    Check(Length(hits) = 3, 'empty query returns all');
    { sorted by title: the two "Egg Drop Soup" then "Squash Soup" }
    Check((Length(hits) = 3) and (Lib.Recipe(hits[2]).Title = 'Squash Soup'),
          'results sorted by title');

    Check(Lib.IndexOfSource('mealmaster', 'squash.mmf') >= 0, 'IndexOfSource hit');
    Check(Lib.IndexOfSource('mealmaster', 'missing') = -1, 'IndexOfSource miss');
  finally
    Lib.Free;
  end;

  { config round-trip at an explicit path }
  cfgpath := IncludeTrailingPathDelimiter(dir) + 'config.ini';
  cfg := TConfig.Create(cfgpath);
  try
    Check(cfg.PersonalKeyword = '', 'config default personal keyword is empty (generic)');
    Check(cfg.SiteTitle = 'My Recipes', 'config default site title');
    cfg.LibraryDir := dir;
    cfg.SiteTitle := 'Shawn''s Recipes';
    cfg.Save;
  finally
    cfg.Free;
  end;
  cfg := TConfig.Create(cfgpath);
  try
    cfg.Load;
    Check(cfg.LibraryDir = dir, 'config LibraryDir round-trip');
    Check(cfg.SiteTitle = 'Shawn''s Recipes', 'config SiteTitle round-trip');
    Check(cfg.FavoriteKeyword = 'Favorite', 'config keeps a default on reload');
  finally
    cfg.Free;
  end;

  WipeDir(dir);

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
