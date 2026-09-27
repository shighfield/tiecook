program uimp_mealmaster_test;

{ Tests for the Meal-Master parser: columns, amount/unit rendering,
  categories, directions -> steps, and multiple recipes per file. }

{$mode objfpc}{$H+}

uses
  SysUtils, urecipe, uimp_mealmaster;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

const
  CRLF = #13#10;
  { two recipes in one file, exactly Meal-Master's fixed columns }
  Blob =
    'MMMMM----- Recipe via Meal-Master (tm) v8.06' + CRLF +
    '' + CRLF +
    '      Title: Easy Chicken Teriyaki' + CRLF +
    ' Categories: Main dish, Shawn' + CRLF +
    '      Yield: 4 Servings' + CRLF +
    '' + CRLF +
    '   4.00    Boneless chicken thigh' + CRLF +
    '   0.50 c  Sliced mushrooms' + CRLF +
    '   0.33 c  Soy sauce' + CRLF +
    '   1.00 ts Olive oil' + CRLF +
    '   1.00 md Onion sliced' + CRLF +
    '' + CRLF +
    '  Cook the chicken in the oven, then rest it and cut into' + CRLF +
    '  strips or chunks.' + CRLF +
    '' + CRLF +
    '  Mix everything else in a bowl, cook the veg, then combine' + CRLF +
    '  and simmer until it thickens.' + CRLF +
    'MMMMM' + CRLF +
    'MMMMM----- Recipe via Meal-Master (tm) v8.06' + CRLF +
    '' + CRLF +
    '      Title: Squash Soup' + CRLF +
    ' Categories: Soup, Shawn' + CRLF +
    '      Yield: 1 Servings' + CRLF +
    '' + CRLF +
    '   1.00    Acorn squash' + CRLF +
    '  -peeled and cubed' + CRLF +
    '   4.00 c  Stock (or water)' + CRLF +
    '   0.25 c  Cream' + CRLF +
    '' + CRLF +
    '  Roast the squash, then blend with stock and finish with cream.' + CRLF +
    'MMMMM' + CRLF;

var
  R: TRecipeArray;

begin
  R := ImportMealMasterText(Blob);

  Check(Length(R) = 2, 'two recipes parsed from one file');
  if Length(R) = 2 then
  begin
    { recipe 1 }
    Check(R[0].Title = 'Easy Chicken Teriyaki', 'recipe 1 title');
    Check(R[0].Source = 'mealmaster', 'recipe 1 source tag');
    Check(R[0].Servings = '4 Servings', 'recipe 1 yield -> servings');
    Check(Length(R[0].Keywords) = 2, 'recipe 1 category count');
    Check((Length(R[0].Keywords) = 2) and (R[0].Keywords[1] = 'Shawn'),
          'recipe 1 keeps the Shawn category');
    Check(Length(R[0].Ingredients) = 5, 'recipe 1 ingredient count');
    { amount whole, no unit }
    Check(R[0].Ingredients[0].Text = '4 Boneless chicken thigh',
          'amount 4.00 -> 4, blank unit');
    { fraction + expanded unit }
    Check(R[0].Ingredients[1].Text = '1/2 cup Sliced mushrooms',
          '0.50 c -> 1/2 cup');
    Check(R[0].Ingredients[2].Text = '1/3 cup Soy sauce', '0.33 c -> 1/3 cup');
    Check(R[0].Ingredients[3].Text = '1 tsp Olive oil', '1.00 ts -> 1 tsp');
    Check(R[0].Ingredients[4].Text = '1 medium Onion sliced', '1.00 md -> 1 medium');
    { directions: two paragraphs -> two steps, each rewrapped to one line }
    Check(Length(R[0].Steps) = 2, 'recipe 1 step count (paragraphs)');
    Check((Length(R[0].Steps) = 2) and
          (R[0].Steps[0] = 'Cook the chicken in the oven, then rest it and cut into strips or chunks.'),
          'recipe 1 step 1 rewrapped');

    { recipe 2 }
    Check(R[1].Title = 'Squash Soup', 'recipe 2 title');
    Check(Length(R[1].Ingredients) = 3, 'recipe 2 ingredient count (continuation folded in)');
    Check(R[1].Ingredients[0].Text = '1 Acorn squash peeled and cubed',
          '"-continuation" folded into previous ingredient');
    Check(R[1].Ingredients[1].Text = '4 cup Stock (or water)', '4.00 c -> 4 cup');
    Check(R[1].Ingredients[2].Text = '1/4 cup Cream', '0.25 c -> 1/4 cup');
    Check(Length(R[1].Steps) = 1, 'recipe 2 step count');
  end;

  { slug helper }
  Check(Slugify('Easy Chicken Teriyaki') = 'easy-chicken-teriyaki', 'slugify spaces');
  Check(Slugify('GF Quiche  & Pie Crust!') = 'gf-quiche-pie-crust', 'slugify punctuation');

  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
