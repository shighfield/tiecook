unit ulibrary;

{ The recipe library: a directory of one-recipe-per-file .txt files.

  TLibrary scans the directory into memory, searches it, and owns the write
  path so imports deduplicate by source. A recipe is identified across
  imports by source + source-id: AddOrUpdate overwrites the matching file
  under its existing slug, or writes a new uniquely-slugged file. }

{$mode objfpc}{$H+}

interface

uses
  urecipe;

type
  TIntArray = array of Integer;

  TLibraryEntry = record
    Recipe: TRecipe;
    Slug: string;         { file name without the .txt extension }
  end;

  TLibrary = class
  private
    FDir: string;
    FEntries: array of TLibraryEntry;
    function UniqueSlug(const Title: string): string;
  public
    constructor Create(const Dir: string);
    procedure Load;
    function Count: Integer;
    function Recipe(Index: Integer): TRecipe;
    function Slug(Index: Integer): string;
    function FilePath(Index: Integer): string;
    { The recipe's photo as a basename that exists in the library dir, or ''.
      Honours an explicit `image:` (basename only, never a path outside the
      library) and falls back to a drop-in <slug>.jpg/.jpeg/.png/.webp. }
    function ImageBasename(Index: Integer): string;
    { First index whose source+source-id match, or -1. }
    function IndexOfSource(const Source, SourceId: string): Integer;
    { Indices whose title/keywords/ingredients/description/steps contain Query
      (case-insensitive), sorted by title. Empty query returns all. }
    function Search(const Query: string): TIntArray;
    { Write R to the library, overwriting a same-source file or creating a new
      one. Returns the slug; sets WasUpdate. Keeps the in-memory index current. }
    function AddOrUpdate(const R: TRecipe; out WasUpdate: Boolean): string;
    property Dir: string read FDir;
  end;

implementation

uses
  SysUtils, Classes;

const
  ImgExts: array[0..3] of string = ('.jpg', '.jpeg', '.png', '.webp');

function DedupKey(const Source, SourceId: string): string;
begin
  Result := LowerCase(Source) + '|' + SourceId;
end;

constructor TLibrary.Create(const Dir: string);
begin
  inherited Create;
  FDir := Dir;
  SetLength(FEntries, 0);
end;

procedure TLibrary.Load;
var
  Info: TSearchRec;
  base, full: string;
begin
  SetLength(FEntries, 0);
  if not DirectoryExists(FDir) then Exit;
  base := IncludeTrailingPathDelimiter(FDir);
  if FindFirst(base + '*.txt', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Attr and faDirectory) = 0 then
      begin
        full := base + Info.Name;
        try
          SetLength(FEntries, Length(FEntries) + 1);
          FEntries[High(FEntries)].Recipe := LoadRecipe(full);
          FEntries[High(FEntries)].Slug := ChangeFileExt(Info.Name, '');
        except
          { not a parseable recipe: drop the half-added entry }
          SetLength(FEntries, Length(FEntries) - 1);
        end;
      end;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
end;

function TLibrary.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TLibrary.Recipe(Index: Integer): TRecipe;
begin
  Result := FEntries[Index].Recipe;
end;

function TLibrary.Slug(Index: Integer): string;
begin
  Result := FEntries[Index].Slug;
end;

function TLibrary.FilePath(Index: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(FDir) + FEntries[Index].Slug + '.txt';
end;

function TLibrary.ImageBasename(Index: Integer): string;
var
  R: TRecipe;
  base, cand, libd: string;
  e: Integer;
begin
  Result := '';
  R := FEntries[Index].Recipe;
  libd := IncludeTrailingPathDelimiter(FDir);
  if R.Image <> '' then
  begin
    base := ExtractFileName(R.Image);
    if (base <> '') and FileExists(libd + base) then Exit(base);
  end;
  for e := Low(ImgExts) to High(ImgExts) do
  begin
    cand := FEntries[Index].Slug + ImgExts[e];
    if FileExists(libd + cand) then Exit(cand);
  end;
end;

function TLibrary.IndexOfSource(const Source, SourceId: string): Integer;
var
  i: Integer;
  key: string;
begin
  Result := -1;
  if SourceId = '' then Exit;
  key := DedupKey(Source, SourceId);
  for i := 0 to High(FEntries) do
    if DedupKey(FEntries[i].Recipe.Source, FEntries[i].Recipe.SourceId) = key then
      Exit(i);
end;

function TLibrary.UniqueSlug(const Title: string): string;
var
  base, cand: string;
  n, i: Integer;
  clash: Boolean;
begin
  base := Slugify(Title);
  cand := base;
  n := 1;
  repeat
    clash := FileExists(IncludeTrailingPathDelimiter(FDir) + cand + '.txt');
    if not clash then
      for i := 0 to High(FEntries) do
        if SameText(FEntries[i].Slug, cand) then begin clash := True; Break; end;
    if clash then
    begin
      Inc(n);
      cand := base + '-' + IntToStr(n);
    end;
  until not clash;
  Result := cand;
end;

function TLibrary.AddOrUpdate(const R: TRecipe; out WasUpdate: Boolean): string;
var
  idx: Integer;
begin
  idx := IndexOfSource(R.Source, R.SourceId);
  WasUpdate := idx >= 0;
  if WasUpdate then
  begin
    Result := FEntries[idx].Slug;
    FEntries[idx].Recipe := R;
  end
  else
  begin
    Result := UniqueSlug(R.Title);
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)].Recipe := R;
    FEntries[High(FEntries)].Slug := Result;
  end;
  ForceDirectories(FDir);
  SaveRecipe(R, IncludeTrailingPathDelimiter(FDir) + Result + '.txt');
end;

{ --- search --- }

{ All searchable text of a recipe, lowercased, newline-joined. }
function Haystack(const R: TRecipe): string;
var
  i: Integer;
begin
  Result := LowerCase(R.Title) + #10 + LowerCase(R.Description);
  for i := 0 to High(R.Keywords) do Result := Result + #10 + LowerCase(R.Keywords[i]);
  for i := 0 to High(R.Ingredients) do Result := Result + #10 + LowerCase(R.Ingredients[i].Text);
  for i := 0 to High(R.Steps) do Result := Result + #10 + LowerCase(R.Steps[i]);
end;

{ Split on whitespace into lowercased, non-empty terms. }
procedure SplitTerms(const Query: string; Terms: TStrings);
var
  c: Char;
  cur: string;
begin
  Terms.Clear;
  cur := '';
  for c in LowerCase(Query) do
    if (c = ' ') or (c = #9) then
    begin
      if cur <> '' then begin Terms.Add(cur); cur := ''; end;
    end
    else
      cur := cur + c;
  if cur <> '' then Terms.Add(cur);
end;

function AllTermsMatch(const Hay: string; Terms: TStrings): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to Terms.Count - 1 do
    if Pos(Terms[i], Hay) = 0 then Exit;
  Result := True;
end;

function TLibrary.Search(const Query: string): TIntArray;
var
  Terms: TStringList;
  i, j, tmp: Integer;
begin
  Result := nil;
  Terms := TStringList.Create;
  try
    SplitTerms(Query, Terms);
    for i := 0 to High(FEntries) do
      if (Terms.Count = 0) or AllTermsMatch(Haystack(FEntries[i].Recipe), Terms) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := i;
      end;
  finally
    Terms.Free;
  end;
  { sort indices by title (small n, simple insertion) }
  for i := 1 to High(Result) do
  begin
    tmp := Result[i];
    j := i - 1;
    while (j >= 0) and
          (CompareText(FEntries[Result[j]].Recipe.Title,
                       FEntries[tmp].Recipe.Title) > 0) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := tmp;
  end;
end;

end.
