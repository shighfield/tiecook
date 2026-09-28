unit uimp_mealmaster;

{ Parse Meal-Master (.MMF) recipe files into TRecipe records.

  Meal-Master's fixed layout (v8.x):

      MMMMM----- Recipe via Meal-Master (tm) v8.06
      <blank>
            Title: <title>
       Categories: <cat, cat, ...>
            Yield: <yield>
      <blank>
      <amt....><u> <ingredient>          amount cols 1-7, unit 9-10, text 12+
      ...
      <blank>
      <directions, hard-wrapped, paragraphs separated by blank lines>
      MMMMM

  One file may hold several recipes. Categories become keywords; the yield
  becomes servings; each blank-separated directions paragraph becomes a step
  with its wrapped lines rejoined. Decimal amounts become plain/fraction
  ("0.50"->"1/2", "1.00"->"1") and unit codes expand ("ts"->"tsp"). }

{$mode objfpc}{$H+}

interface

uses
  Classes, urecipe, ulibrary;

type
  TMMProgress = procedure(const Title: string; WasUpdate: Boolean);

{ Parse one .mmf file's text into recipes. }
function ImportMealMasterText(const Text: string): TRecipeArray;

{ Strip trailing "Recipe by / Recipe FROM: <url> / Source:" attribution steps,
  lifting any URL into source-url. Applied automatically on import; exposed for
  cleaning already-imported recipes. }
procedure CleanAttribution(var R: TRecipe);

{ Append every *.mmf (any case) under a file or directory path to List.
  A path that does not exist is silently ignored. }
procedure CollectMMFiles(const Path: string; List: TStrings);

{ Parse the given .mmf files and write their recipes into Lib (dedup by
  source id: filename, or filename#<title-slug> for multi-recipe files).
  Returns the number imported; sets Updated to how many overwrote a file. }
function ImportMealMasterFiles(Files: TStrings; Lib: TLibrary;
  out Updated: Integer; Progress: TMMProgress = nil): Integer;

implementation

uses
  SysUtils;

const
  LF = #10;

{ --- amount and unit rendering --- }

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
    if Abs(frac - Fracs[i].v) <= 0.03 then
      Exit(Fracs[i].s);
end;

function IsDecimal(const S: string; out D: Double): Boolean;
var
  c: Char;
  seenDigit, seenDot: Boolean;
  norm: string;
begin
  Result := False;
  seenDigit := False; seenDot := False;
  norm := '';
  for c in S do
  begin
    if (c >= '0') and (c <= '9') then begin seenDigit := True; norm := norm + c; end
    else if (c = '.') or (c = ',') then
    begin
      if seenDot then Exit;   { two dots -> not a plain decimal }
      seenDot := True; norm := norm + '.';
    end
    else
      Exit;                   { any other char -> not a plain decimal }
  end;
  if not seenDigit then Exit;
  Result := TryStrToFloat(norm, D, DefaultFormatSettings);
  { force '.' handling regardless of locale }
  if not Result then
  begin
    D := StrToFloatDef(StringReplace(norm, '.', DefaultFormatSettings.DecimalSeparator, []), 0);
    Result := True;
  end;
end;

{ Render a Meal-Master amount field as a readable quantity. }
function FormatAmount(const Raw: string): string;
var
  d, frac: Double;
  whole: Integer;
  fracStr: string;
begin
  Result := Trim(Raw);
  if Result = '' then Exit;
  if not IsDecimal(Result, d) then Exit;   { ranges/fractions pass through }
  whole := Trunc(d + 1E-6);
  frac := d - whole;
  fracStr := NearestFraction(frac);
  if (fracStr = '') and (frac > 0.03) then Exit;  { odd decimal: leave as-is }
  if (whole = 0) and (fracStr <> '') then
    Result := fracStr
  else if fracStr <> '' then
    Result := IntToStr(whole) + ' ' + fracStr
  else
    Result := IntToStr(whole);
end;

function ExpandUnit(const Raw: string): string;
var
  u: string;
begin
  u := LowerCase(Trim(Raw));
  case u of
    '':   Result := '';
    'c':  Result := 'cup';
    't', 'ts': Result := 'tsp';
    'tb', 'tbl': Result := 'tbsp';
    'oz': Result := 'oz';
    'fl': Result := 'fl oz';
    'lb': Result := 'lb';
    'g':  Result := 'g';
    'kg': Result := 'kg';
    'mg': Result := 'mg';
    'ml': Result := 'ml';
    'l':  Result := 'L';
    'pt': Result := 'pint';
    'qt': Result := 'quart';
    'ga': Result := 'gallon';
    'ds': Result := 'dash';
    'pn': Result := 'pinch';
    'dr': Result := 'drop';
    'sm': Result := 'small';
    'md': Result := 'medium';
    'lg': Result := 'large';
    'sl': Result := 'slice';
    'cn': Result := 'can';
    'pk', 'pg': Result := 'package';
    'ct': Result := 'carton';
    'cl': Result := 'clove';
    'bn': Result := 'bunch';
    'ea', 'x': Result := '';       { "each" -> no unit word }
  else
    Result := Trim(Raw);           { unknown code: keep verbatim }
  end;
end;

{ --- line classification --- }

function IsStartMarker(const Line: string): Boolean;
var
  t: string;
begin
  t := TrimLeft(Line);
  Result := (Length(t) >= 6) and (Copy(t, 1, 5) = 'MMMMM') and (t[6] = '-');
end;

function IsEndMarker(const Line: string): Boolean;
var
  t: string;
  c: Char;
begin
  t := Trim(Line);
  if t = 'MMMMM' then Exit(True);
  Result := Length(t) >= 5;               { a rule of dashes closes a recipe }
  for c in t do
    if c <> '-' then Exit(False);
end;

{ An MM ingredient sub-header, e.g. "-----FROSTING-----" or "MMMMM-FROSTING".
  A bare "-..." with one or two dashes is a continuation line, not a section,
  so a plain dash form must have at least three leading dashes. }
function DashSection(const Line: string; out Name: string): Boolean;
var
  t: string;
  hadMMMMM: Boolean;
  n: Integer;
begin
  Name := '';
  t := Trim(Line);
  hadMMMMM := (Length(t) >= 6) and (Copy(t, 1, 5) = 'MMMMM') and (t[6] = '-');
  if hadMMMMM then
    t := Copy(t, 6, Length(t));   { keeps the dash: "-FROSTING" }
  n := 0;
  while (n < Length(t)) and (t[n + 1] = '-') do Inc(n);
  if hadMMMMM then
  begin
    if n < 1 then Exit(False);
  end
  else if n < 3 then
    Exit(False);
  while (t <> '') and (t[1] = '-') do Delete(t, 1, 1);
  while (t <> '') and (t[Length(t)] = '-') do Delete(t, Length(t), 1);
  Name := Trim(t);
  Result := Name <> '';
end;

{ A leading-dash ingredient continuation line, e.g. "-well trimmed". }
function IsContinuation(const Line: string): Boolean;
var
  t: string;
begin
  t := Trim(Line);
  Result := (t <> '') and (t[1] = '-');
end;

function StripLeadingDashes(const Line: string): string;
begin
  Result := Trim(Line);
  while (Result <> '') and (Result[1] = '-') do Delete(Result, 1, 1);
  Result := Trim(Result);
end;

{ Take label "Title"/"Categories"/"Yield" from a line; '' if none. }
function HeaderLabel(const Line: string; out Value: string): string;
var
  t: string;
  p: Integer;
begin
  Result := ''; Value := '';
  t := Trim(Line);
  p := Pos(':', t);
  if p = 0 then Exit;
  Result := LowerCase(Trim(Copy(t, 1, p - 1)));
  Value := Trim(Copy(t, p + 1, Length(t)));
  if (Result <> 'title') and (Result <> 'categories') and (Result <> 'yield') then
    Result := '';
end;

function ComposeIngredient(const Line: string): string;
var
  amt, unitTxt, name: string;
begin
  if Length(Line) >= 12 then
  begin
    amt := FormatAmount(Copy(Line, 1, 7));
    unitTxt := ExpandUnit(Copy(Line, 9, 2));
    name := Trim(Copy(Line, 12, Length(Line)));
  end
  else
  begin
    amt := ''; unitTxt := ''; name := Trim(Line);
  end;
  Result := Trim(amt + ' ' + unitTxt + ' ' + name);
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
end;

{ --- block parsing --- }

procedure AddCategories(var R: TRecipe; const Value: string);
var
  parts: TStringList;
  i: Integer;
  k: string;
begin
  parts := TStringList.Create;
  try
    parts.StrictDelimiter := True;
    parts.Delimiter := ',';
    parts.DelimitedText := Value;
    for i := 0 to parts.Count - 1 do
    begin
      k := Trim(parts[i]);
      if (k <> '') and (LowerCase(k) <> 'none') then
        AddKeyword(R, k);
    end;
  finally
    parts.Free;
  end;
end;

function StartsWith(const Prefix, S: string): Boolean;
begin
  Result := LowerCase(Copy(S, 1, Length(Prefix))) = LowerCase(Prefix);
end;

{ Pull a URL out of a line, repairing a Meal-Master wrap-space and stripping
  <> brackets and trailing punctuation. Only call on a line already known to be
  attribution, since it removes internal spaces from the URL portion. }
function ExtractUrlFromText(const S: string; out Url: string): Boolean;
var
  p: Integer;
  low, tok: string;
begin
  Url := '';
  Result := False;
  low := LowerCase(S);
  p := Pos('http://', low);
  if p = 0 then p := Pos('https://', low);
  if p = 0 then p := Pos('www.', low);
  if p = 0 then Exit;
  tok := Copy(S, p, Length(S));
  tok := StringReplace(tok, ' ', '', [rfReplaceAll]);
  tok := StringReplace(tok, #9, '', [rfReplaceAll]);
  while (tok <> '') and (tok[Length(tok)] in ['>', ')', '.', ',', '"', '''', ']']) do
    Delete(tok, Length(tok), 1);
  while (tok <> '') and (tok[1] in ['<', '(', '"', '''', '[']) do
    Delete(tok, 1, 1);
  if StartsWith('www.', tok) then tok := 'https://' + tok;
  Url := tok;
  Result := Url <> '';
end;

{ Is this step a trailing attribution line (source/author) rather than an
  instruction? Sets Url when it carries one. }
function IsAttributionStep(const StepText: string; out Url: string): Boolean;
var
  t: string;
begin
  t := Trim(StepText);
  Result := ExtractUrlFromText(t, Url)
    or StartsWith('recipe by', t)
    or StartsWith('recipe from', t)
    or StartsWith('source:', t)
    or StartsWith('adapted from', t)
    or StartsWith('from:', t)
    or StartsWith('by:', t);
end;

{ Strip trailing attribution steps (Meal-Master often appends "Recipe by ..."
  and "Recipe FROM: <url>"), lifting a URL into source-url. Stops at the first
  real step, so instructions in the middle are never touched. }
procedure CleanAttribution(var R: TRecipe);
var
  newLen: Integer;
  url: string;
begin
  newLen := Length(R.Steps);
  while newLen > 0 do
  begin
    if IsAttributionStep(R.Steps[newLen - 1], url) then
    begin
      if (url <> '') and (Trim(R.SourceUrl) = '') then R.SourceUrl := url;
      Dec(newLen);
    end
    else
      Break;
  end;
  SetLength(R.Steps, newLen);
end;

function ParseBlock(Block: TStringList): TRecipe;
var
  i, ingStart: Integer;
  lbl, val, secName, para: string;
begin
  InitRecipe(Result);
  Result.Source := 'mealmaster';

  { header labels; ingredients begin after the last one seen }
  ingStart := 0;
  for i := 0 to Block.Count - 1 do
  begin
    lbl := HeaderLabel(Block[i], val);
    if lbl = 'title' then Result.Title := val
    else if lbl = 'categories' then AddCategories(Result, val)
    else if lbl = 'yield' then Result.Servings := val;
    if lbl <> '' then ingStart := i + 1;
  end;

  { skip blank lines before ingredients }
  i := ingStart;
  while (i < Block.Count) and (Trim(Block[i]) = '') do Inc(i);

  { ingredients: until the next blank line }
  while (i < Block.Count) and (Trim(Block[i]) <> '') do
  begin
    if DashSection(Block[i], secName) then
      AddIngredient(Result, secName, True)
    else if IsContinuation(Block[i]) and (Length(Result.Ingredients) > 0) then
      { fold "-continuation" into the previous ingredient }
      Result.Ingredients[High(Result.Ingredients)].Text :=
        Trim(Result.Ingredients[High(Result.Ingredients)].Text + ' '
             + StripLeadingDashes(Block[i]))
    else
      AddIngredient(Result, ComposeIngredient(Block[i]), False);
    Inc(i);
  end;

  { directions: remaining lines, blank-separated paragraphs -> steps }
  para := '';
  while i < Block.Count do
  begin
    if Trim(Block[i]) = '' then
    begin
      if para <> '' then begin AddStep(Result, para); para := ''; end;
    end
    else if DashSection(Block[i], secName) then
    begin
      { a stray marker inside directions: end the current paragraph }
      if para <> '' then begin AddStep(Result, para); para := ''; end;
    end
    else
    begin
      if para = '' then para := Trim(Block[i])
      else para := para + ' ' + Trim(Block[i]);
    end;
    Inc(i);
  end;
  if para <> '' then AddStep(Result, para);

  CleanAttribution(Result);
end;

function ImportMealMasterText(const Text: string): TRecipeArray;
var
  Lines, Block: TStringList;
  i: Integer;
  inRecipe: Boolean;
begin
  Result := nil;
  Lines := TStringList.Create;
  Block := TStringList.Create;
  try
    Lines.TextLineBreakStyle := tlbsLF;
    Block.TextLineBreakStyle := tlbsLF;
    Lines.Text := StringReplace(StringReplace(Text, #13#10, LF, [rfReplaceAll]),
                                #13, LF, [rfReplaceAll]);
    inRecipe := False;
    for i := 0 to Lines.Count - 1 do
    begin
      if IsStartMarker(Lines[i]) then
      begin
        if inRecipe and (Block.Count > 0) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := ParseBlock(Block);
        end;
        Block.Clear;
        inRecipe := True;
        Continue;
      end;
      if not inRecipe then Continue;
      if IsEndMarker(Lines[i]) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := ParseBlock(Block);
        Block.Clear;
        inRecipe := False;
        Continue;
      end;
      Block.Add(Lines[i]);
    end;
    { a recipe left open at EOF (missing footer) }
    if inRecipe and (Block.Count > 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := ParseBlock(Block);
    end;
  finally
    Block.Free;
    Lines.Free;
  end;
end;

{ --- file-level import --- }

procedure CollectMMFiles(const Path: string; List: TStrings);
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
    List.Add(Path);
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

function ImportMealMasterFiles(Files: TStrings; Lib: TLibrary;
  out Updated: Integer; Progress: TMMProgress): Integer;
var
  today, txt, base: string;
  i, ri: Integer;
  recipes: TRecipeArray;
  wasUpdate: Boolean;
begin
  Result := 0;
  Updated := 0;
  today := FormatDateTime('yyyy-mm-dd', Now);
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
      Lib.AddOrUpdate(recipes[ri], wasUpdate);
      if wasUpdate then Inc(Updated);
      Inc(Result);
      if Assigned(Progress) then Progress(recipes[ri].Title, wasUpdate);
    end;
  end;
end;

end.
