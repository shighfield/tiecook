unit uimp_tandoor;

{ Import recipes from a Tandoor instance into the library.

  Pages through GET /api/recipe/, fetches each recipe's detail, maps it to a
  TRecipe, downloads its photo, and writes it via TLibrary.AddOrUpdate (so a
  re-import updates in place). Cross-source dedup (a Tandoor recipe that also
  exists from Meal-Master) is not done here; that is a separate step. }

{$mode objfpc}{$H+}

interface

uses
  urecipe, ulibrary, uapi, umodels;

type
  { Progress callback: called once per recipe with its title and whether it
    updated an existing file. Nil is allowed. }
  TImportProgress = procedure(const Title: string; WasUpdate: Boolean);

{ Map a fetched Tandoor recipe detail to a library recipe (pure; no I/O).
  Photo is handled by ImportTandoor, not here. }
function DetailToRecipe(const D: TRecipeDetail; const BaseUrl: string): TRecipe;

{ Import recipes. Returns the number imported; sets Updated to how many
  overwrote an existing file and Failed to how many recipes were skipped after
  an error (a failed list-page fetch still aborts). DownloadImages copies each
  recipe's photo into the library as tandoor-<id>.<ext>. Limit > 0 stops after
  that many successful recipes. }
function ImportTandoor(Client: TTandoorClient; Lib: TLibrary;
  DownloadImages: Boolean; out Updated: Integer; out Failed: Integer;
  Progress: TImportProgress = nil; Limit: Integer = 0): Integer;

implementation

uses
  SysUtils;

{ --- helpers --- }

function NearestFraction(frac: Double): string;
type
  TFrac = record v: Double; s: string; end;
const
  Fracs: array[0..8] of TFrac = (
    (v: 0.125; s: '1/8'), (v: 0.25; s: '1/4'), (v: 0.3333; s: '1/3'),
    (v: 0.375; s: '3/8'), (v: 0.5; s: '1/2'), (v: 0.625; s: '5/8'),
    (v: 0.6667; s: '2/3'), (v: 0.75; s: '3/4'), (v: 0.875; s: '7/8'));
var
  i: Integer;
begin
  Result := '';
  for i := Low(Fracs) to High(Fracs) do
    if Abs(frac - Fracs[i].v) <= 0.03 then Exit(Fracs[i].s);
end;

{ Render a numeric amount as a readable quantity ("0.5" -> "1/2", "2" -> "2").
  Zero yields ''. Odd decimals keep two significant places. }
function FmtAmount(a: Double): string;
var
  whole: Integer;
  frac: Double;
  fracStr: string;
begin
  Result := '';
  if a <= 0 then Exit;
  whole := Trunc(a + 1E-6);
  frac := a - whole;
  fracStr := NearestFraction(frac);
  if (fracStr = '') and (frac > 0.03) then
    Exit(Trim(Format('%.2f', [a])));
  if (whole = 0) and (fracStr <> '') then Result := fracStr
  else if fracStr <> '' then Result := IntToStr(whole) + ' ' + fracStr
  else Result := IntToStr(whole);
end;

{ Compose one ingredient line, preferring Tandoor's original typed text. }
function IngredientLine(const Ing: umodels.TIngredient): string;
var
  amt: string;
begin
  if Trim(Ing.OriginalText) <> '' then
    Exit(Trim(Ing.OriginalText));
  amt := FmtAmount(Ing.Amount);
  Result := Trim(amt + ' ' + Trim(Ing.UnitName) + ' ' + Trim(Ing.FoodName));
  if Trim(Ing.Note) <> '' then
    Result := Trim(Result + ', ' + Trim(Ing.Note));
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
end;

function BuildTime(WorkingTime, WaitingTime: Integer): string;
begin
  Result := '';
  if WorkingTime > 0 then Result := 'prep ' + IntToStr(WorkingTime) + ' min';
  if WaitingTime > 0 then
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + 'wait ' + IntToStr(WaitingTime) + ' min';
  end;
end;

function BuildServings(Servings: Integer; const ServingsText: string): string;
begin
  { Tandoor's unset default is servings=1 with no unit text; treat that as
    unknown and use a sensible household default of 3. }
  if (Servings <= 1) and (Trim(ServingsText) = '') then
    Exit('3');
  if Trim(ServingsText) <> '' then
  begin
    if Servings > 0 then Result := IntToStr(Servings) + ' ' + Trim(ServingsText)
    else Result := Trim(ServingsText);
  end
  else if Servings > 0 then
    Result := IntToStr(Servings)
  else
    Result := '';
end;

{ Tandoor creates an "Import > ..." keyword hierarchy during bulk imports;
  those tags are noise on nearly every recipe, so drop them. }
function IsImportKeyword(const K: umodels.TKeyword): Boolean;
var
  fn: string;
begin
  fn := Trim(K.FullName);
  Result := (CompareText(fn, 'Import') = 0)
            or (CompareText(Copy(fn, 1, 8), 'Import >') = 0)
            or (CompareText(Copy(fn, 1, 7), 'Import>') = 0)
            or (CompareText(Trim(K.Name), 'Import') = 0);
end;

function DetailToRecipe(const D: TRecipeDetail; const BaseUrl: string): TRecipe;
var
  i, j: Integer;
  st: umodels.TStep;
  ing: umodels.TIngredient;
  instr, headText: string;
begin
  InitRecipe(Result);
  Result.Title := D.Name;
  Result.Source := 'tandoor';
  Result.SourceId := IntToStr(D.Id);
  { only keep a real external source; the Tandoor page URL is not stored,
    since that instance is being retired (see project notes) }
  Result.SourceUrl := Trim(D.SourceUrl);
  Result.Servings := BuildServings(D.Servings, D.ServingsText);
  Result.Time := BuildTime(D.WorkingTime, D.WaitingTime);
  if D.Rating > 0 then Result.Rating := IntToStr(Round(D.Rating));
  Result.Description := Trim(D.Description);

  for i := 0 to High(D.Keywords) do
    if not IsImportKeyword(D.Keywords[i]) then
      AddKeyword(Result, D.Keywords[i].Name);

  { Tandoor groups ingredients under steps; flatten them (in step/order) into
    the ingredients section, and each step's instruction into the steps. }
  for i := 0 to High(D.Steps) do
  begin
    st := D.Steps[i];
    for j := 0 to High(st.Ingredients) do
    begin
      ing := st.Ingredients[j];
      if ing.IsHeader then
      begin
        headText := Trim(ing.Note);
        if headText = '' then headText := Trim(ing.FoodName);
        if headText <> '' then AddIngredient(Result, headText, True);
      end
      else
        AddIngredient(Result, IngredientLine(ing), False);
    end;
  end;

  for i := 0 to High(D.Steps) do
  begin
    instr := Trim(D.Steps[i].Instruction);
    if instr <> '' then AddStep(Result, instr);
  end;
end;

{ --- import loop --- }

function ImgExtFromUrl(const Url: string): string;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(Url));
  { strip any query string that ExtractFileExt might have swept in }
  if Pos('?', ext) > 0 then ext := Copy(ext, 1, Pos('?', ext) - 1);
  if (ext = '.jpg') or (ext = '.jpeg') or (ext = '.png') or (ext = '.webp')
     or (ext = '.gif') then
    Result := ext
  else
    Result := '.jpg';
end;

function ImportTandoor(Client: TTandoorClient; Lib: TLibrary;
  DownloadImages: Boolean; out Updated: Integer; out Failed: Integer;
  Progress: TImportProgress; Limit: Integer): Integer;
var
  P: TSearchParams;
  Res: TSearchResult;
  Ov: TRecipeOverview;
  Detail: TRecipeDetail;
  Rec: TRecipe;
  wasUpdate: Boolean;
  i, page: Integer;
  imgName, imgPath: string;
begin
  Result := 0;
  Updated := 0;
  Failed := 0;
  page := 1;
  repeat
    P.Query := '';
    P.Page := page;
    P.SortOrder := 'name';
    P.RatingGte := 0;
    P.KeywordId := 0;
    Res := Client.SearchRecipes(P);   { a page fetch failure aborts the import }

    for i := 0 to High(Res.Recipes) do
    begin
      Ov := Res.Recipes[i];
      { isolate each recipe: one bad record must not end a 353-recipe run }
      try
        Detail := Client.GetRecipeDetail(Ov.Id);
        Rec := DetailToRecipe(Detail, Client.BaseUrl);

        if DownloadImages and (Trim(Ov.ImageUrl) <> '') then
        begin
          imgName := 'tandoor-' + IntToStr(Ov.Id) + ImgExtFromUrl(Ov.ImageUrl);
          imgPath := IncludeTrailingPathDelimiter(Lib.Dir) + imgName;
          if Client.DownloadImage(Ov.ImageUrl, imgPath) then
            Rec.Image := imgName;
        end;

        Rec.Imported := FormatDateTime('yyyy-mm-dd', Now);
        Lib.AddOrUpdate(Rec, wasUpdate);
        if wasUpdate then Inc(Updated);
        Inc(Result);
        if Assigned(Progress) then Progress(Rec.Title, wasUpdate);
        if (Limit > 0) and (Result >= Limit) then Exit;
      except
        on E: Exception do
        begin
          Inc(Failed);
          WriteLn(StdErr, 'tiecook2: skip recipe id ', Ov.Id, ': ', E.Message);
        end;
      end;
    end;

    Inc(page);
  until not Res.HasNext;
end;

end.
