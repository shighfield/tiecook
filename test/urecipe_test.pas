program urecipe_test;

{ Round-trip and parse tests for the urecipe file format.
  Run via ../Makefile `make test`. Exits nonzero on the first failure. }

{$mode objfpc}{$H+}

uses
  SysUtils, urecipe;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Msg);
  end;
end;

const LF = #10;

{ Field-by-field equality, so a mismatch names the field. }
function SameRecipe(const A, B: TRecipe; out Why: string): Boolean;
var
  i: Integer;
begin
  Why := '';
  Result := False;
  if A.Title <> B.Title then begin Why := 'title'; Exit; end;
  if A.Source <> B.Source then begin Why := 'source'; Exit; end;
  if A.SourceId <> B.SourceId then begin Why := 'source-id'; Exit; end;
  if A.SourceUrl <> B.SourceUrl then begin Why := 'source-url'; Exit; end;
  if A.Servings <> B.Servings then begin Why := 'servings'; Exit; end;
  if A.Time <> B.Time then begin Why := 'time'; Exit; end;
  if A.Rating <> B.Rating then begin Why := 'rating'; Exit; end;
  if A.Image <> B.Image then begin Why := 'image'; Exit; end;
  if A.Imported <> B.Imported then begin Why := 'imported'; Exit; end;
  if A.Description <> B.Description then begin Why := 'description'; Exit; end;
  if Length(A.Keywords) <> Length(B.Keywords) then begin Why := 'keyword count'; Exit; end;
  for i := 0 to High(A.Keywords) do
    if A.Keywords[i] <> B.Keywords[i] then begin Why := 'keyword ' + IntToStr(i); Exit; end;
  if Length(A.Ingredients) <> Length(B.Ingredients) then begin Why := 'ingredient count'; Exit; end;
  for i := 0 to High(A.Ingredients) do
  begin
    if A.Ingredients[i].Text <> B.Ingredients[i].Text then begin Why := 'ingredient text ' + IntToStr(i); Exit; end;
    if A.Ingredients[i].IsSection <> B.Ingredients[i].IsSection then begin Why := 'ingredient section-flag ' + IntToStr(i); Exit; end;
  end;
  if Length(A.Steps) <> Length(B.Steps) then begin Why := 'step count'; Exit; end;
  for i := 0 to High(A.Steps) do
    if A.Steps[i] <> B.Steps[i] then begin Why := 'step ' + IntToStr(i); Exit; end;
  Result := True;
end;

procedure TestRoundTrip;
var
  R, R2: TRecipe;
  T, T2, Why: string;
begin
  InitRecipe(R);
  R.Title := 'Kung Pao Chicken';
  R.Source := 'tandoor-api';
  R.SourceId := '142';
  R.SourceUrl := 'https://recipes.example/view/recipe/142';
  AddKeyword(R, 'Chinese');
  AddKeyword(R, 'Chicken');
  AddKeyword(R, 'Gluten Free');    { keyword containing a space }
  R.Servings := '4';
  R.Time := 'prep 15, cook 10';
  R.Rating := '';                  { empty optional field, must be skipped }
  R.Image := 'kung-pao-chicken.jpg';
  R.Imported := '2026-09-26';
  R.Description := 'Classic Sichuan stir-fry.' + LF + LF + 'Bold and numbing.';
  AddIngredient(R, '500 g chicken thigh, diced');
  AddIngredient(R, 'Sauce', True); { ## sub-heading }
  AddIngredient(R, '1 tbsp Chinkiang vinegar');
  AddStep(R, 'Marinate the chicken in soy and cornstarch for 20 minutes.');
  AddStep(R, 'Fire the wok hot and stir-fry the chicken until just done.');

  T := RecipeToText(R);
  R2 := RecipeFromText(T);
  Check(SameRecipe(R, R2, Why), 'record round-trip mismatch on ' + Why);

  { idempotence: re-serialising the parsed recipe yields identical text }
  T2 := RecipeToText(R2);
  Check(T = T2, 'text is not idempotent under parse+serialise');

  { the empty rating must not appear in the output }
  Check(Pos('rating:', T) = 0, 'empty rating field was written');
  Check(Pos('## Sauce', T) > 0, 'ingredient sub-heading not written as "## Sauce"');
end;

procedure TestParseAuthored;
var
  R: TRecipe;
  T: string;
begin
  { a hand-authored file, CRLF, numbered steps, blank lines between them }
  T := 'title: Squash Soup' + #13#10 +
       'source: mealmaster' + #13#10 +
       'servings: 1 Servings' + #13#10 +
       'keywords: Soup, Shawn' + #13#10 +
       #13#10 +
       'ingredients:' + #13#10 +
       '  1 Acorn squash' + #13#10 +
       '  4 c Stock (or water)' + #13#10 +
       #13#10 +
       'steps:' + #13#10 +
       '  1. Roast the squash until soft.' + #13#10 +
       #13#10 +
       '  2. Blend with stock, then finish with cream.' + #13#10;
  R := RecipeFromText(T);
  Check(R.Title = 'Squash Soup', 'authored title');
  Check(R.Source = 'mealmaster', 'authored source');
  Check(R.Servings = '1 Servings', 'authored servings');
  Check(Length(R.Keywords) = 2, 'authored keyword count');
  Check((Length(R.Keywords) = 2) and (R.Keywords[1] = 'Shawn'), 'authored second keyword');
  Check(Length(R.Ingredients) = 2, 'authored ingredient count');
  Check((Length(R.Ingredients) = 2) and (R.Ingredients[1].Text = '4 c Stock (or water)'),
        'authored second ingredient text');
  Check(Length(R.Steps) = 2, 'authored step count (blank-separated numbered steps)');
  Check((Length(R.Steps) = 2) and (R.Steps[0] = 'Roast the squash until soft.'),
        'step number was stripped');
  Check((Length(R.Steps) = 2) and (R.Steps[1] = 'Blend with stock, then finish with cream.'),
        'second step text');
end;

procedure TestFileRoundTrip;
var
  R, R2: TRecipe;
  fn, Why: string;
begin
  InitRecipe(R);
  R.Title := 'Egg Drop Soup';
  R.Source := 'mealmaster';
  AddKeyword(R, 'Soup');
  AddIngredient(R, '4 c chicken stock');
  AddStep(R, 'Simmer, then stream in beaten egg.');
  fn := GetTempFileName('', 'tc2rec');
  try
    SaveRecipe(R, fn);
    R2 := LoadRecipe(fn);
    Check(SameRecipe(R, R2, Why), 'file round-trip mismatch on ' + Why);
  finally
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

procedure TestMultilineSteps;
var
  R, R2: TRecipe;
  Why: string;
begin
  { a step whose lines include one ending in a colon, which the reader must
    NOT mistake for a body section (that used to silently drop later steps) }
  InitRecipe(R);
  R.Title := 'Deviled Eggs';
  AddStep(R, 'Whisk the eggs.' + LF + 'Tip:' + LF + 'use a fork');
  AddStep(R, 'Bake until set.');
  R2 := RecipeFromText(RecipeToText(R));
  Check(SameRecipe(R, R2, Why), 'multiline step round-trip mismatch on ' + Why);
  Check(Length(R2.Steps) = 2, 'a colon line inside step 1 dropped later steps');

  { multi-paragraph step (blank line kept as a paragraph break) }
  InitRecipe(R);
  AddStep(R, 'Make the roux.' + LF + LF + 'Then add the milk slowly.');
  R2 := RecipeFromText(RecipeToText(R));
  Check(SameRecipe(R, R2, Why), 'multi-paragraph step round-trip mismatch on ' + Why);
end;

procedure TestCrlfContinuation;
var
  R: TRecipe;
  T: string;
begin
  { authored CRLF file, a step wrapped across two physical lines }
  T := 'title: Grits' + #13#10 + #13#10 +
       'steps:' + #13#10 +
       '  1. Bring water to a boil, add salt and pepper, add grits and' + #13#10 +
       '     cook until the water is absorbed.' + #13#10 +
       '  2. Stir in butter and cheese.' + #13#10;
  R := RecipeFromText(T);
  Check(Length(R.Steps) = 2, 'CRLF continuation: step count');
  Check((Length(R.Steps) = 2) and
        (R.Steps[0] = 'Bring water to a boil, add salt and pepper, add grits and' +
                      LF + 'cook until the water is absorbed.'),
        'CRLF continuation: wrapped step joined');
end;

procedure TestNormalization;
var
  R, R2: TRecipe;
  T: string;
begin
  { newlines inside single-line values must not break the file structure }
  InitRecipe(R);
  R.Title := 'Bad' + LF + 'Title';
  AddIngredient(R, '1 cup' + LF + 'flour');
  AddStep(R, 'Mix.');
  T := RecipeToText(R);
  R2 := RecipeFromText(T);
  Check(R2.Title = 'Bad Title', 'newline in title was not collapsed to a space');
  Check(Length(R2.Ingredients) = 1, 'newline in ingredient split it into two');
  Check((Length(R2.Ingredients) = 1) and (R2.Ingredients[0].Text = '1 cup flour'),
        'ingredient newline not collapsed');
  Check(Length(R2.Steps) = 1, 'body after a broken value was lost');
end;

procedure TestUtf8;
var
  R, R2: TRecipe;
  fn, Why: string;
begin
  InitRecipe(R);
  R.Title := 'Crème Brûlée';
  AddKeyword(R, 'Dessert');
  AddIngredient(R, '½ cup sugar');
  AddStep(R, 'Bake at 180 °C until the café-au-lait custard sets.');
  fn := GetTempFileName('', 'tc2utf');
  try
    SaveRecipe(R, fn);
    R2 := LoadRecipe(fn);
    Check(SameRecipe(R, R2, Why), 'UTF-8 file round-trip mismatch on ' + Why);
  finally
    if FileExists(fn) then DeleteFile(fn);
  end;
end;

begin
  TestRoundTrip;
  TestParseAuthored;
  TestFileRoundTrip;
  TestMultilineSteps;
  TestCrlfContinuation;
  TestNormalization;
  TestUtf8;
  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then
    Halt(1);
  WriteLn('OK');
end.
