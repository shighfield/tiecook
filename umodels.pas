unit umodels;

{$mode objfpc}{$H+}

interface

type
  TKeyword = record
    Name: string;
  end;
  TKeywordArray = array of TKeyword;

  TRecipeOverview = record
    Id: Integer;
    Name: string;
    Description: string;
    ImageUrl: string;
    Keywords: TKeywordArray;
    WorkingTime: Integer;
    WaitingTime: Integer;
    Servings: Integer;
    ServingsText: string;
    Rating: Double;
  end;
  TRecipeOverviewArray = array of TRecipeOverview;

  TIngredient = record
    FoodName: string;
    UnitName: string;
    Amount: Double;
    Note: string;
    OriginalText: string;
    IsHeader: Boolean;
  end;
  TIngredientArray = array of TIngredient;

  TStep = record
    Name: string;
    Instruction: string;
    Ingredients: TIngredientArray;
    TimeMinutes: Integer;
    Order: Integer;
  end;
  TStepArray = array of TStep;

  TRecipeDetail = record
    Id: Integer;
    Name: string;
    Description: string;
    Steps: TStepArray;
    WorkingTime: Integer;
    WaitingTime: Integer;
    Servings: Integer;
    ServingsText: string;
    SourceUrl: string;
    Rating: Double;
  end;

  TSearchResult = record
    Count: Integer;
    HasNext: Boolean;
    HasPrevious: Boolean;
    Recipes: TRecipeOverviewArray;
  end;

implementation

end.
