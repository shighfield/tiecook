unit urecipe;

{ The tiecook recipe model and its plain-text file format.

  One recipe per file. A file is a header of `key: value` lines, a blank
  line, then any of the `description:`, `ingredients:` and `steps:` body
  sections. Body content is indented two spaces; a section ends at the
  next unindented `name:` line or at end of file. Example:

      title: Kung Pao Chicken
      source: tandoor-api
      source-id: 142
      source-url: https://recipes.example/view/recipe/142
      keywords: Chinese, Chicken, Spicy
      servings: 4
      image: kung-pao-chicken.jpg
      imported: 2026-09-26

      description:
        Classic Sichuan stir-fry.

      ingredients:
        500 g chicken thigh, diced
        ## Sauce
        1 tbsp Chinkiang vinegar

      steps:
        1. Marinate the chicken.

        2. Fire the wok hot and stir-fry fast.

  Ingredient lines that begin with `## ` are sub-headings (e.g. "Sauce").
  Step numbers are cosmetic: the writer generates them and the reader
  strips a leading `N.` so steps round-trip as plain text.

  In the description and steps, wrapped lines flow together (consecutive
  non-blank lines are joined with spaces) and a BLANK line separates
  paragraphs. So the exact wrapping of hand-edited or imported text doesn't
  matter; use a blank line for a real paragraph break. }

{$mode objfpc}{$H+}

interface

type
  TIngredient = record
    Text: string;       { the line, or the heading text when IsSection }
    IsSection: Boolean; { a "## Sauce" sub-heading rather than an item }
  end;

  TRecipe = record
    Title: string;
    Source: string;     { 'tandoor-api', 'mealmaster', 'tandoor-zip', 'jsonld' }
    SourceId: string;
    SourceUrl: string;
    Keywords: array of string;
    Servings: string;
    Time: string;
    Rating: string;
    Image: string;
    Imported: string;   { ISO date, YYYY-MM-DD }
    Description: string;           { free text; paragraphs separated by blank lines }
    Ingredients: array of TIngredient;
    Steps: array of string;        { one paragraph per step, no number }
  end;

  TRecipeArray = array of TRecipe;

procedure InitRecipe(out R: TRecipe);
procedure AddKeyword(var R: TRecipe; const K: string);
procedure AddIngredient(var R: TRecipe; const Text: string; IsSection: Boolean = False);
procedure AddStep(var R: TRecipe; const Text: string);

{ --- structured-editing helpers --- }
{ Independent deep copy (so an editor working-copy doesn't alias the original). }
function CopyRecipe(const R: TRecipe): TRecipe;
{ Replace the keyword list from a comma-separated string. }
procedure SetKeywords(var R: TRecipe; const Csv: string);
procedure InsertIngredient(var R: TRecipe; Pos: Integer; const Text: string; IsSection: Boolean = False);
procedure DeleteIngredient(var R: TRecipe; Index: Integer);
procedure MoveIngredient(var R: TRecipe; Index, Delta: Integer);
procedure InsertStep(var R: TRecipe; Pos: Integer; const Text: string);
procedure DeleteStep(var R: TRecipe; Index: Integer);
procedure MoveStep(var R: TRecipe; Index, Delta: Integer);

function RecipeToText(const R: TRecipe): string;
function RecipeFromText(const S: string): TRecipe;

function LoadRecipe(const FileName: string): TRecipe;
procedure SaveRecipe(const R: TRecipe; const FileName: string);

{ A filesystem-safe slug from a title: lowercase ASCII, runs of other
  characters folded to single hyphens. Empty input yields 'recipe'. }
function Slugify(const S: string): string;

{ Remove a trailing markdown "### Source" section from a block of text (Tandoor
  appends one to a recipe's last step). Returns the text without it; if the
  section held a URL, returns it in Url. If there is no such section the text
  is returned unchanged and Url is ''. }
function StripSourceSection(const S: string; out Url: string): string;

implementation

uses
  SysUtils, Classes;

const
  Indent = '  ';
  LF = #10;

procedure InitRecipe(out R: TRecipe);
begin
  R.Title := '';
  R.Source := '';
  R.SourceId := '';
  R.SourceUrl := '';
  SetLength(R.Keywords, 0);
  R.Servings := '';
  R.Time := '';
  R.Rating := '';
  R.Image := '';
  R.Imported := '';
  R.Description := '';
  SetLength(R.Ingredients, 0);
  SetLength(R.Steps, 0);
end;

procedure AddKeyword(var R: TRecipe; const K: string);
var
  T: string;
begin
  T := Trim(K);
  if T = '' then Exit;
  SetLength(R.Keywords, Length(R.Keywords) + 1);
  R.Keywords[High(R.Keywords)] := T;
end;

procedure AddIngredient(var R: TRecipe; const Text: string; IsSection: Boolean);
begin
  SetLength(R.Ingredients, Length(R.Ingredients) + 1);
  R.Ingredients[High(R.Ingredients)].Text := Text;
  R.Ingredients[High(R.Ingredients)].IsSection := IsSection;
end;

procedure AddStep(var R: TRecipe; const Text: string);
begin
  SetLength(R.Steps, Length(R.Steps) + 1);
  R.Steps[High(R.Steps)] := Text;
end;

{ --- structured-editing helpers --- }

function CopyRecipe(const R: TRecipe): TRecipe;
begin
  Result := R;                       { copies scalars; arrays alias until... }
  Result.Keywords := Copy(R.Keywords);        { ...forced unique here }
  Result.Ingredients := Copy(R.Ingredients);
  Result.Steps := Copy(R.Steps);
end;

procedure SetKeywords(var R: TRecipe; const Csv: string);
var
  parts: TStringList;
  i: Integer;
begin
  SetLength(R.Keywords, 0);
  parts := TStringList.Create;
  try
    parts.StrictDelimiter := True;
    parts.Delimiter := ',';
    parts.DelimitedText := Csv;
    for i := 0 to parts.Count - 1 do
      AddKeyword(R, parts[i]);
  finally
    parts.Free;
  end;
end;

procedure InsertIngredient(var R: TRecipe; Pos: Integer; const Text: string; IsSection: Boolean);
var
  i: Integer;
begin
  if Pos < 0 then Pos := 0;
  if Pos > Length(R.Ingredients) then Pos := Length(R.Ingredients);
  SetLength(R.Ingredients, Length(R.Ingredients) + 1);
  for i := High(R.Ingredients) downto Pos + 1 do
    R.Ingredients[i] := R.Ingredients[i - 1];
  R.Ingredients[Pos].Text := Text;
  R.Ingredients[Pos].IsSection := IsSection;
end;

procedure DeleteIngredient(var R: TRecipe; Index: Integer);
var
  i: Integer;
begin
  if (Index < 0) or (Index > High(R.Ingredients)) then Exit;
  for i := Index to High(R.Ingredients) - 1 do
    R.Ingredients[i] := R.Ingredients[i + 1];
  SetLength(R.Ingredients, Length(R.Ingredients) - 1);
end;

procedure MoveIngredient(var R: TRecipe; Index, Delta: Integer);
var
  j: Integer;
  tmp: TIngredient;
begin
  j := Index + Delta;
  if (Index < 0) or (Index > High(R.Ingredients)) or
     (j < 0) or (j > High(R.Ingredients)) then Exit;
  tmp := R.Ingredients[Index];
  R.Ingredients[Index] := R.Ingredients[j];
  R.Ingredients[j] := tmp;
end;

procedure InsertStep(var R: TRecipe; Pos: Integer; const Text: string);
var
  i: Integer;
begin
  if Pos < 0 then Pos := 0;
  if Pos > Length(R.Steps) then Pos := Length(R.Steps);
  SetLength(R.Steps, Length(R.Steps) + 1);
  for i := High(R.Steps) downto Pos + 1 do
    R.Steps[i] := R.Steps[i - 1];
  R.Steps[Pos] := Text;
end;

procedure DeleteStep(var R: TRecipe; Index: Integer);
var
  i: Integer;
begin
  if (Index < 0) or (Index > High(R.Steps)) then Exit;
  for i := Index to High(R.Steps) - 1 do
    R.Steps[i] := R.Steps[i + 1];
  SetLength(R.Steps, Length(R.Steps) - 1);
end;

procedure MoveStep(var R: TRecipe; Index, Delta: Integer);
var
  j: Integer;
  tmp: string;
begin
  j := Index + Delta;
  if (Index < 0) or (Index > High(R.Steps)) or
     (j < 0) or (j > High(R.Steps)) then Exit;
  tmp := R.Steps[Index];
  R.Steps[Index] := R.Steps[j];
  R.Steps[j] := tmp;
end;

{ --- writing --- }

{ Fold any CR/LF in a value into single spaces. Header values, keywords and
  ingredient lines are single-line by nature; this keeps an accidental newline
  from breaking the file structure. }
function CollapseWS(const S: string): string;
begin
  Result := StringReplace(S, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
end;

procedure AppendHeader(SB: TStringList; const Key, Value: string);
begin
  if Value <> '' then
    SB.Add(Key + ': ' + CollapseWS(Value));
end;

function JoinKeywords(const R: TRecipe): string;
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

{ Split a multi-line string into physical lines, each emitted indented. }
procedure AppendIndentedBlock(SB: TStringList; const Block: string);
var
  Lines: TStringList;
  i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.TextLineBreakStyle := tlbsLF;
    Lines.Text := Block;
    { TStringList.Text drops a single trailing newline; that is what we want. }
    for i := 0 to Lines.Count - 1 do
      if Lines[i] = '' then
        SB.Add('')
      else
        SB.Add(Indent + Lines[i]);
  finally
    Lines.Free;
  end;
end;

{ Emit one step. The first physical line is "  N. text"; further lines of a
  multi-line step are indented under it, and blank lines within the step are
  kept as paragraph breaks. This matches how ReadSteps parses them back. }
procedure AppendStep(SB: TStringList; Num: Integer; const Text: string);
const
  ContIndent = '     ';   { deeper than the two-space base -> a continuation }
var
  Lines: TStringList;
  i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.TextLineBreakStyle := tlbsLF;
    Lines.Text := Text;
    if Lines.Count = 0 then
    begin
      SB.Add(Indent + IntToStr(Num) + '. ');
      Exit;
    end;
    SB.Add(Indent + IntToStr(Num) + '. ' + Lines[0]);
    for i := 1 to Lines.Count - 1 do
      if Lines[i] = '' then
        SB.Add('')
      else
        SB.Add(ContIndent + Lines[i]);
  finally
    Lines.Free;
  end;
end;

function RecipeToText(const R: TRecipe): string;
var
  SB: TStringList;
  i: Integer;
begin
  SB := TStringList.Create;
  try
    SB.TextLineBreakStyle := tlbsLF;

    AppendHeader(SB, 'title', R.Title);
    AppendHeader(SB, 'source', R.Source);
    AppendHeader(SB, 'source-id', R.SourceId);
    AppendHeader(SB, 'source-url', R.SourceUrl);
    AppendHeader(SB, 'keywords', JoinKeywords(R));
    AppendHeader(SB, 'servings', R.Servings);
    AppendHeader(SB, 'time', R.Time);
    AppendHeader(SB, 'rating', R.Rating);
    AppendHeader(SB, 'image', R.Image);
    AppendHeader(SB, 'imported', R.Imported);

    if R.Description <> '' then
    begin
      SB.Add('');
      SB.Add('description:');
      AppendIndentedBlock(SB, R.Description);
    end;

    if Length(R.Ingredients) > 0 then
    begin
      SB.Add('');
      SB.Add('ingredients:');
      for i := 0 to High(R.Ingredients) do
        if R.Ingredients[i].IsSection then
          SB.Add(Indent + '## ' + CollapseWS(R.Ingredients[i].Text))
        else
          SB.Add(Indent + CollapseWS(R.Ingredients[i].Text));
    end;

    if Length(R.Steps) > 0 then
    begin
      SB.Add('');
      SB.Add('steps:');
      for i := 0 to High(R.Steps) do
      begin
        if i > 0 then SB.Add('');
        AppendStep(SB, i + 1, R.Steps[i]);
      end;
    end;

    Result := SB.Text;
  finally
    SB.Free;
  end;
end;

{ --- reading --- }

{ Recognise an unindented "name:" line with nothing after the colon.
  Returns the lowercased name, or '' if the line is not a section header. }
function SectionHeader(const Line: string): string;
var
  p: Integer;
  name, rest: string;
  c: Char;
begin
  Result := '';
  if (Line = '') or (Line[1] = ' ') or (Line[1] = #9) then Exit;
  p := Pos(':', Line);
  if p = 0 then Exit;
  name := Copy(Line, 1, p - 1);
  rest := Trim(Copy(Line, p + 1, Length(Line)));
  if rest <> '' then Exit;              { has a value -> not a body section }
  for c in name do
    if not (((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'))
            or ((c >= '0') and (c <= '9')) or (c = '-')) then
      Exit;
  Result := LowerCase(name);
end;

{ Strip an indent of up to two leading spaces. }
function Unindent(const Line: string): string;
begin
  Result := Line;
  if (Length(Result) >= 1) and (Result[1] = ' ') then Delete(Result, 1, 1);
  if (Length(Result) >= 1) and (Result[1] = ' ') then Delete(Result, 1, 1);
end;

{ Count leading spaces. }
function LeadSpaces(const S: string): Integer;
begin
  Result := 0;
  while (Result < Length(S)) and (S[Result + 1] = ' ') do Inc(Result);
end;

{ A step marker is a base-indented (<= 2 spaces) "N." or "N)" line. Deeper
  indentation marks a continuation of the current step, not a new one.
  Returns True and the text after the number when Line opens a step. }
function StepMarker(const Line: string; out Rest: string): Boolean;
var
  i, n: Integer;
begin
  Result := False;
  Rest := '';
  if LeadSpaces(Line) > 2 then Exit;
  i := 1;
  while (i <= Length(Line)) and (Line[i] = ' ') do Inc(i);
  n := i;
  while (i <= Length(Line)) and (Line[i] >= '0') and (Line[i] <= '9') do Inc(i);
  if i = n then Exit;                              { no digits }
  if (i > Length(Line)) or not ((Line[i] = '.') or (Line[i] = ')')) then Exit;
  Inc(i);
  while (i <= Length(Line)) and (Line[i] = ' ') do Inc(i);
  Rest := Copy(Line, i, Length(Line));
  Result := True;
end;

procedure SetHeaderField(var R: TRecipe; const Key, Value: string);
var
  k: string;
  parts: TStringList;
  i: Integer;
begin
  k := LowerCase(Trim(Key));
  case k of
    'title':      R.Title := Value;
    'source':     R.Source := Value;
    'source-id':  R.SourceId := Value;
    'source-url': R.SourceUrl := Value;
    'servings':   R.Servings := Value;
    'time':       R.Time := Value;
    'rating':     R.Rating := Value;
    'image':      R.Image := Value;
    'imported':   R.Imported := Value;
    'keywords':
      begin
        parts := TStringList.Create;
        try
          parts.StrictDelimiter := True;
          parts.Delimiter := ',';
          parts.DelimitedText := Value;
          for i := 0 to parts.Count - 1 do
            AddKeyword(R, parts[i]);
        finally
          parts.Free;
        end;
      end;
  end;
end;

{ Reflow a buffer of physical lines into paragraphs: consecutive non-blank
  lines are joined with single spaces (so hard-wrapped or hand-edited text
  flows), and a blank line separates paragraphs (kept as a blank line). This
  makes the format forgiving of how prose is wrapped; a real break needs a
  blank line. }
function ReflowBlock(Buf: TStringList): string;
var
  i: Integer;
  para: string;
  paras: TStringList;
begin
  paras := TStringList.Create;
  try
    para := '';
    for i := 0 to Buf.Count - 1 do
      if Trim(Buf[i]) = '' then
      begin
        if para <> '' then begin paras.Add(para); para := ''; end;
      end
      else if para = '' then
        para := Trim(Buf[i])
      else
        para := para + ' ' + Trim(Buf[i]);
    if para <> '' then paras.Add(para);

    Result := '';
    for i := 0 to paras.Count - 1 do
    begin
      if i > 0 then Result := Result + LF + LF;
      Result := Result + paras[i];
    end;
  finally
    paras.Free;
  end;
end;

function RecipeFromText(const S: string): TRecipe;
var
  Lines: TStringList;
  descBuf, stepBuf: TStringList;
  i, p: Integer;
  inHeader, stepOpen: Boolean;
  section, hdr, item, rest: string;
  R: TRecipe;

  procedure CloseStep;
  begin
    if stepOpen then
    begin
      AddStep(R, ReflowBlock(stepBuf));
      stepBuf.Clear;
      stepOpen := False;
    end;
  end;

  procedure CloseSection;
  begin
    if section = 'description' then
      R.Description := ReflowBlock(descBuf)
    else if section = 'steps' then
      CloseStep;
  end;

begin
  InitRecipe(R);
  Lines := TStringList.Create;
  descBuf := TStringList.Create;
  stepBuf := TStringList.Create;
  try
    Lines.TextLineBreakStyle := tlbsLF;
    descBuf.TextLineBreakStyle := tlbsLF;
    stepBuf.TextLineBreakStyle := tlbsLF;
    { normalise CRLF / CR to LF so Meal-Master-derived text parses too }
    Lines.Text := StringReplace(StringReplace(S, #13#10, LF, [rfReplaceAll]),
                                #13, LF, [rfReplaceAll]);

    inHeader := True;
    section := '';
    stepOpen := False;
    i := 0;
    while i < Lines.Count do
    begin
      if inHeader then
      begin
        { the header ends at a blank line, or at the first body section even
          when a hand-edited file forgot the blank line }
        if (Trim(Lines[i]) = '') or (SectionHeader(Lines[i]) <> '') then
          inHeader := False
        else
        begin
          p := Pos(':', Lines[i]);
          if p > 0 then
            SetHeaderField(R, Copy(Lines[i], 1, p - 1),
                           Trim(Copy(Lines[i], p + 1, Length(Lines[i]))));
          Inc(i);
          Continue;
        end;
        { fall through without advancing when a section header ended the header }
        if Trim(Lines[i]) = '' then
        begin
          Inc(i);
          Continue;
        end;
      end;

      hdr := SectionHeader(Lines[i]);
      if hdr <> '' then
      begin
        CloseSection;
        descBuf.Clear;
        section := hdr;
        Inc(i);
        Continue;
      end;

      case section of
        'description':
          descBuf.Add(Unindent(Lines[i]));
        'ingredients':
          if Trim(Lines[i]) <> '' then
          begin
            item := Unindent(Lines[i]);
            if Copy(item, 1, 3) = '## ' then
              AddIngredient(R, Trim(Copy(item, 4, Length(item))), True)
            else
              AddIngredient(R, item, False);
          end;
        'steps':
          if StepMarker(Lines[i], rest) then
          begin
            CloseStep;
            stepBuf.Add(rest);
            stepOpen := True;
          end
          else if Trim(Lines[i]) = '' then
          begin
            if stepOpen then stepBuf.Add('');   { paragraph break within a step }
          end
          else if stepOpen then
            stepBuf.Add(Trim(Lines[i]))          { continuation line }
          else
          begin
            { steps section that opens without a number: treat as step one }
            stepBuf.Add(Trim(Lines[i]));
            stepOpen := True;
          end;
      end;
      Inc(i);
    end;

    CloseSection;
    Result := R;
  finally
    stepBuf.Free;
    descBuf.Free;
    Lines.Free;
  end;
end;

function LoadRecipe(const FileName: string): TRecipe;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);
    Result := RecipeFromText(SL.Text);
  finally
    SL.Free;
  end;
end;

procedure SaveRecipe(const R: TRecipe; const FileName: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.TextLineBreakStyle := tlbsLF;
    SL.Text := RecipeToText(R);
    SL.SaveToFile(FileName);
  finally
    SL.Free;
  end;
end;

function Slugify(const S: string): string;
var
  c: Char;
  prevDash: Boolean;
begin
  Result := '';
  prevDash := False;
  for c in S do
  begin
    if ((c >= 'a') and (c <= 'z')) or ((c >= '0') and (c <= '9')) then
    begin
      Result := Result + c; prevDash := False;
    end
    else if (c >= 'A') and (c <= 'Z') then
    begin
      Result := Result + Chr(Ord(c) + 32); prevDash := False;
    end
    else if not prevDash then
    begin
      Result := Result + '-'; prevDash := True;
    end;
  end;
  while (Result <> '') and (Result[1] = '-') do Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] = '-') do
    Delete(Result, Length(Result), 1);
  if Result = '' then Result := 'recipe';
end;

function StripSourceSection(const S: string; out Url: string): string;
var
  Lines: TStringList;
  i, markerAt, p: Integer;
  t, u: string;
begin
  Url := '';
  Result := S;
  Lines := TStringList.Create;
  try
    Lines.TextLineBreakStyle := tlbsLF;
    Lines.Text := StringReplace(StringReplace(S, #13#10, LF, [rfReplaceAll]),
                                #13, LF, [rfReplaceAll]);
    { find a line that is only '#'s followed by 'source' }
    markerAt := -1;
    for i := 0 to Lines.Count - 1 do
    begin
      t := Trim(Lines[i]);
      if (t <> '') and (t[1] = '#') then
      begin
        while (t <> '') and (t[1] = '#') do Delete(t, 1, 1);
        if LowerCase(Trim(t)) = 'source' then begin markerAt := i; Break; end;
      end;
    end;
    if markerAt < 0 then Exit;

    { pull the first URL out of the section }
    for i := markerAt + 1 to Lines.Count - 1 do
    begin
      p := Pos('http://', LowerCase(Lines[i]));
      if p = 0 then p := Pos('https://', LowerCase(Lines[i]));
      if p > 0 then
      begin
        u := Copy(Lines[i], p, Length(Lines[i]));
        p := Pos(' ', u);
        if p > 0 then u := Copy(u, 1, p - 1);
        Url := Trim(u);
        Break;
      end;
    end;

    { drop the section and any blank lines that preceded it }
    while (markerAt > 0) and (Trim(Lines[markerAt - 1]) = '') do Dec(markerAt);
    Result := '';
    for i := 0 to markerAt - 1 do
    begin
      if i > 0 then Result := Result + LF;
      Result := Result + Lines[i];
    end;
  finally
    Lines.Free;
  end;
end;

end.
