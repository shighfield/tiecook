program uimp_tandoor_test;

{ Tests the Tandoor detail -> TRecipe mapping (pure; no network). }

{$mode objfpc}{$H+}

uses
  SysUtils, urecipe, umodels, uimp_tandoor;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

function MkIng(const OrigText, Food, Unt, Note: string; Amt: Double;
  Header: Boolean): TIngredient;
begin
  Result.OriginalText := OrigText;
  Result.FoodName := Food;
  Result.UnitName := Unt;
  Result.Note := Note;
  Result.Amount := Amt;
  Result.IsHeader := Header;
end;

var
  D: TRecipeDetail;
  R: TRecipe;

begin
  { assemble a detail record like the API would yield }
  FillChar(D, SizeOf(D), 0);
  D.Id := 142;
  D.Name := 'Kung Pao Chicken';
  D.SourceUrl := '';                 { empty -> falls back to the view URL }
  D.Description := 'Spicy and numbing.';
  D.Servings := 4;
  D.ServingsText := 'servings';
  D.WorkingTime := 15;
  D.WaitingTime := 10;
  D.Rating := 4.0;

  SetLength(D.Keywords, 3);
  D.Keywords[0].Id := 1; D.Keywords[0].Name := 'Chinese';
  D.Keywords[1].Id := 2; D.Keywords[1].Name := 'Spicy';
  D.Keywords[2].Id := 3; D.Keywords[2].Name := 'Import 1';
  D.Keywords[2].FullName := 'Import > Import 1';   { should be dropped }

  SetLength(D.Steps, 2);
  D.Steps[0].Instruction := 'Marinate the chicken.';
  D.Steps[0].Order := 0;
  SetLength(D.Steps[0].Ingredients, 3);
  D.Steps[0].Ingredients[0] := MkIng('', 'Sauce', '', '', 0, True);      { header }
  D.Steps[0].Ingredients[1] := MkIng('3 tbsp soy sauce', '', '', '', 0, False);
  D.Steps[0].Ingredients[2] := MkIng('', 'peanuts', 'cup', 'roasted', 0.5, False);
  D.Steps[1].Instruction := 'Stir-fry hot and fast.';
  D.Steps[1].Order := 1;
  SetLength(D.Steps[1].Ingredients, 0);

  R := DetailToRecipe(D, 'https://recipes.example');

  Check(R.Title = 'Kung Pao Chicken', 'title');
  Check(R.Source = 'tandoor', 'source tag');
  Check(R.SourceId = '142', 'source-id from id');
  Check(R.SourceUrl = '', 'empty source_url -> no Tandoor page fallback');
  Check(R.Servings = '4 servings', 'servings + servings_text');
  Check(R.Time = 'prep 15 min, wait 10 min', 'working/waiting -> time');
  Check(R.Rating = '4', 'rating rounded');
  Check(R.Description = 'Spicy and numbing.', 'description');
  Check(Length(R.Keywords) = 2, 'keyword count (Import dropped)');
  Check((Length(R.Keywords) = 2) and (R.Keywords[0] = 'Chinese'), 'first keyword');

  Check(Length(R.Ingredients) = 3, 'ingredient count (flattened across steps)');
  Check((Length(R.Ingredients) = 3) and R.Ingredients[0].IsSection
        and (R.Ingredients[0].Text = 'Sauce'), 'header ingredient -> section');
  Check((Length(R.Ingredients) = 3) and (R.Ingredients[1].Text = '3 tbsp soy sauce'),
        'original_text used verbatim');
  Check((Length(R.Ingredients) = 3) and (R.Ingredients[2].Text = '1/2 cup peanuts, roasted'),
        'composed line: amount fraction + unit + food + note');

  Check(Length(R.Steps) = 2, 'step count (instructions only)');
  Check((Length(R.Steps) = 2) and (R.Steps[0] = 'Marinate the chicken.'), 'first step');
  Check((Length(R.Steps) = 2) and (R.Steps[1] = 'Stir-fry hot and fast.'), 'second step');

  { explicit source_url is kept }
  D.SourceUrl := 'https://origin.example/recipe';
  R := DetailToRecipe(D, 'https://recipes.example');
  Check(R.SourceUrl = 'https://origin.example/recipe', 'explicit source_url preserved');

  { Tandoor's unset servings default (1 / empty text) becomes 3 }
  D.Servings := 1; D.ServingsText := '';
  R := DetailToRecipe(D, 'https://recipes.example');
  Check(R.Servings = '3', 'unset servings (1 / empty) -> 3');

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
