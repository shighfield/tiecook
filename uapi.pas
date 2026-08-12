unit uapi;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fphttpclient, opensslsockets, fpjson, jsonparser, umodels;

type
  ETandoorError = class(Exception)
  public
    HttpStatus: Integer; // 0 = network/TLS-level failure, no HTTP status
    constructor CreateHttp(AStatus: Integer; const AMsg: string);
  end;

  TTandoorClient = class
  private
    FBaseUrl: string;
    FToken: string;
    FHttp: TFPHTTPClient;
    function DoGet(const APath: string): TJSONData;
    function ParseOverview(Obj: TJSONObject): TRecipeOverview;
    function ParseIngredient(Obj: TJSONObject): TIngredient;
    function ParseStep(Obj: TJSONObject): TStep;
  public
    constructor Create(const ABaseUrl, AToken: string);
    destructor Destroy; override;
    function SearchRecipes(const AQuery: string; APage: Integer): TSearchResult;
    function GetRecipeDetail(AId: Integer): TRecipeDetail;
  end;

implementation

{ ETandoorError }

constructor ETandoorError.CreateHttp(AStatus: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  HttpStatus := AStatus;
end;

{ TTandoorClient }

constructor TTandoorClient.Create(const ABaseUrl, AToken: string);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  FToken := AToken;
  FHttp := TFPHTTPClient.Create(nil);
  FHttp.AddHeader('Authorization', 'Bearer ' + FToken);
  FHttp.AddHeader('Accept', 'application/json');
  FHttp.AllowRedirect := True;
  FHttp.IOTimeout := 10000;
end;

destructor TTandoorClient.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TTandoorClient.DoGet(const APath: string): TJSONData;
var
  ResponseBody: TStringStream;
  Status: Integer;
begin
  ResponseBody := TStringStream.Create('');
  try
    try
      FHttp.Get(FBaseUrl + APath, ResponseBody);
      Status := FHttp.ResponseStatusCode;
    except
      on E: EHTTPClient do
      begin
        Status := FHttp.ResponseStatusCode;
        case Status of
          401, 403:
            raise ETandoorError.CreateHttp(Status,
              'Authentication failed (check token in config) - HTTP ' + IntToStr(Status));
          404:
            raise ETandoorError.CreateHttp(Status, 'Not found (HTTP 404)');
          500..599:
            raise ETandoorError.CreateHttp(Status, 'Server error (HTTP ' + IntToStr(Status) + ')');
        else
          raise ETandoorError.CreateHttp(Status, 'Unexpected HTTP status ' + IntToStr(Status));
        end;
      end;
      on E: Exception do
        raise ETandoorError.CreateHttp(0, 'Network/TLS error: ' + E.Message);
    end;

    try
      Result := GetJSON(ResponseBody.DataString);
    except
      on E: Exception do
        raise ETandoorError.CreateHttp(Status, 'Invalid JSON response: ' + E.Message);
    end;
  finally
    ResponseBody.Free;
  end;
end;

function TTandoorClient.ParseOverview(Obj: TJSONObject): TRecipeOverview;
var
  KwArr: TJSONArray;
  I: Integer;
  KwObj: TJSONObject;
begin
  Result.Id := Obj.Get('id', 0);
  Result.Name := Obj.Get('name', '');
  Result.Description := Obj.Get('description', '');
  Result.ImageUrl := Obj.Get('image', '');
  Result.WorkingTime := Obj.Get('working_time', 0);
  Result.WaitingTime := Obj.Get('waiting_time', 0);
  Result.Servings := Obj.Get('servings', 0);
  Result.ServingsText := Obj.Get('servings_text', '');
  Result.Rating := Obj.Get('rating', Double(0));

  SetLength(Result.Keywords, 0);
  KwArr := Obj.Get('keywords', TJSONArray(nil));
  if Assigned(KwArr) then
  begin
    SetLength(Result.Keywords, KwArr.Count);
    for I := 0 to KwArr.Count - 1 do
    begin
      KwObj := TJSONObject(KwArr.Items[I]);
      Result.Keywords[I].Name := KwObj.Get('name', '');
    end;
  end;
end;

function TTandoorClient.ParseIngredient(Obj: TJSONObject): TIngredient;
var
  FoodObj, UnitObj: TJSONObject;
begin
  FoodObj := Obj.Get('food', TJSONObject(nil));
  if Assigned(FoodObj) then
    Result.FoodName := FoodObj.Get('name', '')
  else
    Result.FoodName := '';

  UnitObj := Obj.Get('unit', TJSONObject(nil));
  if Assigned(UnitObj) then
    Result.UnitName := UnitObj.Get('name', '')
  else
    Result.UnitName := '';

  Result.Amount := Obj.Get('amount', Double(0));
  Result.Note := Obj.Get('note', '');
  Result.OriginalText := Obj.Get('original_text', '');
  Result.IsHeader := Obj.Get('is_header', False);
end;

function TTandoorClient.ParseStep(Obj: TJSONObject): TStep;
var
  IngArr: TJSONArray;
  I: Integer;
begin
  Result.Name := Obj.Get('name', '');
  Result.Instruction := Obj.Get('instruction', '');
  Result.TimeMinutes := Obj.Get('time', 0);
  Result.Order := Obj.Get('order', 0);

  SetLength(Result.Ingredients, 0);
  IngArr := Obj.Get('ingredients', TJSONArray(nil));
  if Assigned(IngArr) then
  begin
    SetLength(Result.Ingredients, IngArr.Count);
    for I := 0 to IngArr.Count - 1 do
      Result.Ingredients[I] := ParseIngredient(TJSONObject(IngArr.Items[I]));
  end;
end;

function TTandoorClient.SearchRecipes(const AQuery: string; APage: Integer): TSearchResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  ResultsArr: TJSONArray;
  I: Integer;
begin
  Data := DoGet('/api/recipe/?query=' + EncodeURLElement(AQuery) + '&page=' + IntToStr(APage));
  try
    Obj := TJSONObject(Data);
    Result.Count := Obj.Get('count', 0);
    Result.HasNext := Obj.Get('next', '') <> '';
    Result.HasPrevious := Obj.Get('previous', '') <> '';

    SetLength(Result.Recipes, 0);
    ResultsArr := Obj.Get('results', TJSONArray(nil));
    if Assigned(ResultsArr) then
    begin
      SetLength(Result.Recipes, ResultsArr.Count);
      for I := 0 to ResultsArr.Count - 1 do
        Result.Recipes[I] := ParseOverview(TJSONObject(ResultsArr.Items[I]));
    end;
  finally
    Data.Free;
  end;
end;

function TTandoorClient.GetRecipeDetail(AId: Integer): TRecipeDetail;
var
  Data: TJSONData;
  Obj: TJSONObject;
  StepsArr: TJSONArray;
  I: Integer;
begin
  Data := DoGet('/api/recipe/' + IntToStr(AId) + '/');
  try
    Obj := TJSONObject(Data);
    Result.Id := Obj.Get('id', 0);
    Result.Name := Obj.Get('name', '');
    Result.Description := Obj.Get('description', '');
    Result.WorkingTime := Obj.Get('working_time', 0);
    Result.WaitingTime := Obj.Get('waiting_time', 0);
    Result.Servings := Obj.Get('servings', 0);
    Result.ServingsText := Obj.Get('servings_text', '');
    Result.SourceUrl := Obj.Get('source_url', '');
    Result.Rating := Obj.Get('rating', Double(0));

    SetLength(Result.Steps, 0);
    StepsArr := Obj.Get('steps', TJSONArray(nil));
    if Assigned(StepsArr) then
    begin
      SetLength(Result.Steps, StepsArr.Count);
      for I := 0 to StepsArr.Count - 1 do
        Result.Steps[I] := ParseStep(TJSONObject(StepsArr.Items[I]));
    end;
  finally
    Data.Free;
  end;
end;

end.
