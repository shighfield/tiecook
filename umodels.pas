unit umodels;

{$mode objfpc}{$H+}

interface

type
  TKeyword = record
    Id: Integer;
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
    Keywords: TKeywordArray;
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

  { Parameters for a recipe search. Empty SortOrder / zero RatingGte / zero
    KeywordId each mean "no filter". SortOrder is one of the Tandoor
    sort_order values (e.g. 'name', '-rating'); RatingGte maps to rating_gte;
    KeywordId maps to a single keywords=<id>. }
  TSearchParams = record
    Query: string;
    Page: Integer;
    SortOrder: string;
    RatingGte: Integer;
    KeywordId: Integer;
  end;

implementation

end.
