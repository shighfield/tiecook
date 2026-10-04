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
  SysUtils, Classes;

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

{ --- instruction cleaning + sentence splitting --- }

function StartsCI(const Prefix, S: string): Boolean;
begin
  Result := CompareText(Copy(Trim(S), 1, Length(Prefix)), Prefix) = 0;
end;

function HasCI(const Needle, S: string): Boolean;
begin
  Result := Pos(LowerCase(Needle), LowerCase(S)) > 0;
end;

{ Pull a URL from a line, repairing wrap-spaces and stripping <> / trailing
  punctuation. Only used on lines already known to be attribution. }
function GrabUrl(const S: string; out Url: string): Boolean;
var
  p: Integer;
  low, tok: string;

  { keep the earliest match, so an archive.org wrapper (whose path embeds the
    original http:// URL) is taken whole rather than from the inner URL }
  procedure Earliest(const Needle: string);
  var
    q: Integer;
  begin
    q := Pos(Needle, low);
    if (q > 0) and ((p = 0) or (q < p)) then p := q;
  end;

begin
  Url := '';
  low := LowerCase(S);
  p := 0;
  Earliest('https://');
  Earliest('http://');
  Earliest('www.');
  if p = 0 then Exit(False);
  tok := Copy(S, p, Length(S));
  tok := StringReplace(tok, ' ', '', [rfReplaceAll]);
  tok := StringReplace(tok, #9, '', [rfReplaceAll]);
  while (tok <> '') and (tok[Length(tok)] in ['>', ')', '.', ',', '"', '''', ']']) do
    Delete(tok, Length(tok), 1);
  while (tok <> '') and (tok[1] in ['<', '(', '"', '''', '[']) do
    Delete(tok, 1, 1);
  if CompareText(Copy(tok, 1, 4), 'www.') = 0 then tok := 'https://' + tok;
  Url := tok;
  Result := Url <> '';
end;

{ A paragraph that is attribution, nutrition, or BBS/tagline noise rather than
  a real instruction. Captures a URL when present. }
function IsJunkPara(const P: string; out Url: string): Boolean;
begin
  Url := '';
  { only start-anchored markers here: a run-on Meal-Master dump puts the whole
    method and its attribution in one paragraph, so a "contains" test would drop
    the method with it; embedded attribution is cut at the sentence level }
  if StartsCI('recipe from', P) or StartsCI('recipe by', P)
     or StartsCI('recipe source', P) or StartsCI('source:', P)
     or StartsCI('posted by', P) or StartsCI('adapted from', P)
     or StartsCI('an original recipe by', P) or StartsCI('from:', P)
     or StartsCI('###', P)
     or GrabUrl(P, Url) then
  begin
    GrabUrl(P, Url);
    Exit(True);
  end;
  if HasCI('per serving', P) or HasCI('calories', P) or HasCI('g carbs', P)
     or HasCI('g protein', P) or HasCI('g fat', P) or HasCI('mg sodium', P)
     or HasCI('g fiber', P) or (StartsCI('per ', P) and HasCI(' cal', P)) then
    Exit(True);
  { Meal-Master header remnants }
  if StartsCI('total time', P) or StartsCI('prep time', P) or StartsCI('preparation time', P)
     or StartsCI('cooking time', P) or StartsCI('cook time', P) or StartsCI('yield', P) then
    Exit(True);
  if HasCI('* origin', P) or HasCI('mbse', P) or HasCI(' bbs', P) or HasCI('fidonet', P)
     or StartsCI('---', P) or StartsCI('* ', P) then
    Exit(True);
  Result := False;
end;

{ Split a paragraph of running prose into sentences (ending at . ! ? followed
  by a space and a capital, or end of text). }
procedure SplitSentences(const P: string; Steps: TStrings);
var
  i, start, j: Integer;

  procedure Emit(a, b: Integer);
  var
    t: string;
  begin
    t := Trim(Copy(P, a, b - a + 1));
    if Length(t) >= 2 then Steps.Add(t);
  end;

begin
  start := 1;
  i := 1;
  while i <= Length(P) do
  begin
    if P[i] in ['.', '!', '?'] then
    begin
      while (i < Length(P)) and (P[i + 1] in ['.', '!', '?']) do Inc(i);
      if i = Length(P) then
      begin Emit(start, i); start := i + 1; end
      else if P[i + 1] = ' ' then
      begin
        j := i + 1;
        while (j <= Length(P)) and (P[j] = ' ') do Inc(j);
        if (j <= Length(P)) and (P[j] in ['A'..'Z']) then
        begin Emit(start, i); i := j - 1; start := j; end;
      end;
    end;
    Inc(i);
  end;
  if start <= Length(P) then Emit(start, Length(P));
end;

{ True for a sentence that is source/attribution boilerplate rather than a
  cooking instruction, so it can be dropped from a run-on method. }
function IsAttributionSentence(const S: string): Boolean;
var
  t: string;
begin
  t := Trim(S);
  Result :=
    StartsCI('recipe by', t) or StartsCI('recipe from', t)
    or StartsCI('recipe source', t) or StartsCI('source:', t)
    or StartsCI('posted by', t) or StartsCI('adapted from', t)
    or StartsCI('an original recipe by', t) or StartsCI('from:', t)
    or HasCI('<gopher:', t) or HasCI('<news:', t) or HasCI('<http', t)
    or HasCI('uncle dirty dave', t)
    or HasCI('wherever you go, there you are', t);
end;

{ Sentence-split content, but stop at the first attribution sentence: the real
  method always precedes its attribution, and anything after it is boilerplate
  or a corrupted duplicate of the method, so it is dropped. }
procedure AddCleanSentences(const P: string; Steps: TStrings);
var
  tmp: TStringList;
  i: Integer;
begin
  tmp := TStringList.Create;
  try
    tmp.TextLineBreakStyle := tlbsLF;
    SplitSentences(P, tmp);
    { drop only the attribution sentences, keeping what surrounds them: real
      method can follow an embedded attribution (e.g. "From: ... " mid-recipe),
      so cutting to the end here would discard genuine steps }
    for i := 0 to tmp.Count - 1 do
      if not IsAttributionSentence(tmp[i]) then Steps.Add(tmp[i]);
  finally
    tmp.Free;
  end;
end;

{ Turn a Tandoor instruction blob into clean steps: split into blank-line
  paragraphs, rejoin a URL wrapped across paragraphs, drop junk
  (attribution/nutrition/BBS) capturing any URL, and sentence-split the rest
  (cutting each content run at its first attribution sentence). }
procedure CleanInstruction(const S: string; Steps: TStrings; var Url: string);
var
  raw, paras: TStringList;
  i: Integer;
  cur, u, contentBuf: string;

  { collapse the blob into blank-line-separated paragraphs (lines within a
    paragraph are space-joined) }
  procedure BuildParas;
  var
    j: Integer;
    acc: string;
  begin
    acc := '';
    for j := 0 to raw.Count - 1 do
      if Trim(raw[j]) = '' then
      begin
        if acc <> '' then begin paras.Add(acc); acc := ''; end;
      end
      else if acc = '' then acc := Trim(raw[j])
      else acc := acc + ' ' + Trim(raw[j]);
    if acc <> '' then paras.Add(acc);
  end;

  { true if the paragraph opens an angle-bracketed URL ("<http...", "<www...",
    etc.) that is not yet closed by ">" on the same paragraph }
  function OpensUrlBracket(const P: string): Boolean;
  var
    lp: string;
  begin
    lp := LowerCase(P);
    Result := ((Pos('<http', lp) > 0) or (Pos('<www', lp) > 0)
               or (Pos('<ftp', lp) > 0) or (Pos('<gopher', lp) > 0)
               or (Pos('<news', lp) > 0))
              and (Pos('>', P) = 0);
  end;

  { a "<...>" URL can be wrapped across blank-separated paragraphs; merge
    following paragraphs into one that opened such a URL until its closing ">".
    Gated on a real scheme so a stray "<" in corrupted text does not swallow
    following paragraphs. }
  procedure MergeWrappedUrls;
  var
    j: Integer;
  begin
    j := 0;
    while j < paras.Count do
    begin
      if OpensUrlBracket(paras[j]) then
        while (j + 1 < paras.Count) and (Pos('>', paras[j]) = 0) do
        begin
          paras[j] := paras[j] + ' ' + paras[j + 1];
          paras.Delete(j + 1);
        end;
      Inc(j);
    end;
  end;

  { sentence-split the accumulated content (stopping at attribution) and reset }
  procedure FlushContent;
  begin
    if contentBuf <> '' then
    begin
      AddCleanSentences(contentBuf, Steps);
      contentBuf := '';
    end;
  end;

begin
  raw := TStringList.Create;
  paras := TStringList.Create;
  try
    raw.TextLineBreakStyle := tlbsLF;
    raw.Text := StringReplace(StringReplace(S, #13#10, #10, [rfReplaceAll]),
                              #13, #10, [rfReplaceAll]);
    BuildParas;
    MergeWrappedUrls;
    contentBuf := '';
    for i := 0 to paras.Count - 1 do
    begin
      cur := paras[i];
      if IsJunkPara(cur, u) then
      begin
        { flush first so the junk breaks the running method }
        FlushContent;
        if (u <> '') and (Url = '') then Url := u;
      end
      else if contentBuf = '' then contentBuf := cur
      else contentBuf := contentBuf + ' ' + cur;
    end;
    FlushContent;
  finally
    paras.Free;
    raw.Free;
  end;
end;

function DetailToRecipe(const D: TRecipeDetail; const BaseUrl: string): TRecipe;
var
  i, j: Integer;
  st: umodels.TStep;
  ing: umodels.TIngredient;
  headText, srcUrl: string;
  stepList: TStringList;
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

  { split each step's instruction into clean, sentence-level steps, dropping
    attribution/nutrition/BBS junk and lifting any URL into source-url }
  srcUrl := '';
  stepList := TStringList.Create;
  try
    stepList.TextLineBreakStyle := tlbsLF;
    for i := 0 to High(D.Steps) do
      CleanInstruction(D.Steps[i].Instruction, stepList, srcUrl);
    if (srcUrl <> '') and (Result.SourceUrl = '') then Result.SourceUrl := srcUrl;
    for i := 0 to stepList.Count - 1 do
      AddStep(Result, stepList[i]);
  finally
    stepList.Free;
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
          WriteLn(StdErr, 'tiecook: skip recipe id ', Ov.Id, ': ', E.Message);
        end;
      end;
    end;

    Inc(page);
  until not Res.HasNext;
end;

end.
