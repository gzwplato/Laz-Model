{
  ESS-Model
  Copyright (C) 2002  Eldean AB, Peter S�derman, Ville Krumlinde

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
}

unit uJavaParser;

{$MODE Delphi}

interface

uses Classes, uCodeParser, uModel, uModelEntity, uIntegrator, uCodeProvider, Types;

type
  TJavaImporter = class(TImportIntegrator)
  private
    function NeedPackageHandler(const AName: string; var AStream: TStream; OnlyLookUp: Boolean = False):String;
  public
    procedure ImportOneFile(const FileName : string); override;
    class function GetFileExtensions : TStringList; override;
  end;


  TJavaParser = class(TCodeParser)
  private
    FStream: TMemoryStream;
    FCurrPos: PChar;
    Token: string;
    FOM: TObjectModel;
    FUnit: TUnitPackage;
    Comment: string; // Accumulated comment string used for documentation of entities.
    ModAbstract : boolean;
    ModVisibility: TVisibility;
    ClassImports,FullImports : TStringList;
    NameCache : TStringList;

    FSourcePos: TPoint;
    FTokenPos: TPoint;
    FFilename: String;
    TokenPosLocked : boolean;

    function SkipToken(const what: string): Boolean;
    function SkipPair(const open, close: string): Boolean;
    function GetChar: char;

    procedure EatWhiteSpace;
    function GetNextToken: string;

    procedure ParseCompilationUnit;
    procedure ParseTypeDeclaration;
    procedure ParseModifiersOpt;
    procedure ParseClassDeclaration(IsInner : boolean = False; const ParentName : string = '');
    procedure ParseInterfaceDeclaration;

    procedure DoOperation(O: TOperation; const ParentName, TypeName: string);
    procedure DoAttribute(A: TAttribute; const TypeName: string);
    function GetTypeName : string;

    procedure SetVisibility(M: TModelEntity);
    function NeedClassifier(const CName: string; Force : boolean = True; TheClass: TModelEntityClass = nil): TClassifier;
    function NeedSource(const SourceName : string) : boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ParseStream(AStream: TStream; AModel: TAbstractPackage; AOM: TObjectModel); overload; override;
    property Filename: String read FFilename write FFilename;
  end;

implementation

uses LCLIntf, LCLType, Dialogs, SysUtils, uError;

function ExtractPackageName(const CName: string): string;
var
  I : integer;
begin
  I := LastDelimiter('.',CName);
  if I=0 then
    Result := ''
  else
    Result := Copy(CName,1,I-1);
end;

function ExtractClassName(const CName: string): string;
var
  I : integer;
begin
  I := LastDelimiter('.',CName);
  if I=0 then
    Result := CName
  else
    Result := Copy(CName,I+1,255);
end;




{ TJavaImporter }


procedure TJavaImporter.ImportOneFile(const FileName : string);
var
  Str : TStream;
  Parser: TJavaParser;
begin
  Str := CodeProvider.LoadStream(FileName);
  if Assigned(Str) then
  begin
    Parser := TJavaParser.Create;
    try
      Parser.FileName := FileName;
      Parser.NeedPackage := NeedPackageHandler;
      Parser.ParseStream(Str, Model.ModelRoot, Model);
    finally
      Parser.Free;
    end;
  end;
end;

function TJavaImporter.NeedPackageHandler(const AName: string; var AStream: TStream; OnlyLookUp: Boolean = False):String;
var
  FileName: string;
begin
  AStream := nil;
  FileName := AName + '.java';
  FileName := CodeProvider.LocateFile(FileName);
  Result := FileName;
  //Avoid reading same file twice
  if (not OnlyLookUp) and (FileName<>'') and (FilesRead.IndexOf(FileName)=-1) then
  begin
    AStream := CodeProvider.LoadStream(FileName);
    FilesRead.Add(FileName);
  end;
end;




class function TJavaImporter.GetFileExtensions: TStringList;
begin
  Result := TStringList.Create;
  Result.Values['.java'] := 'Java';
end;

{ TJavaParser }

constructor TJavaParser.Create;
begin
  inherited;
  ClassImports := TStringList.Create;
  FullImports := TStringList.Create;
  NameCache := TStringList.Create;
  NameCache.Sorted := True;
  NameCache.Duplicates := dupIgnore;
end;

destructor TJavaParser.Destroy;
begin
  inherited;
  if Assigned(FStream) then FreeAndNil(FStream);
  ClassImports.Free;
  FullImports.Free;
  NameCache.Free;
end;

function TJavaParser.SkipToken(const what: string): Boolean;
begin
  Result := False;
  GetNextToken;
  if Token = what then
  begin
    GetNextToken;
    Result := True;
  end;
end;

function TJavaParser.SkipPair(const open, close: string): Boolean;

  procedure InternalSkipPair(const open, close: string);
  begin
    while (Token <> close) and (Token<>'') do
    begin
      GetNextToken;
      while Token = open do
        InternalSkipPair(open, close);
    end;
    GetNextToken;
  end;

begin
  Result := False;
  InternalSkipPair(open, close);
  if Token <> '' then Result := True;
end;


procedure TJavaParser.EatWhiteSpace;
var
  inComment, continueLastComment, State: Boolean;

  procedure EatOne;
  begin
    if inComment then
      Comment := Comment + GetChar
    else
      GetChar;
  end;

  function EatWhite: Boolean;
  begin
    Result := False;
    while not (FCurrPos^ in [#0, #33..#255]) do
    begin
      Result := True;
      EatOne;
    end;
  end;

  function EatStarComment: Boolean;
  begin
    Result := True;
    while (not ((FCurrPos^ = '*') and ((FCurrPos + 1)^ = '/'))) or (FCurrPos^=#0) do
    begin
      Result := True;
      EatOne;
    end;
    continueLastComment := False;
    inComment := False;
    EatOne; EatOne;
  end;

  function EatSlashComment: Boolean;
  begin
    Result := True;
    while (FCurrPos^ <> #13) and (FCurrPos^ <> #10) and (FCurrPos^ <> #0) do
    begin
      Result := True;
      EatOne;
    end;
    continueLastComment := True;
    inComment := False;
    while FCurrPos^ in [#13,#10] do
      EatOne;
  end;

begin
  inComment := False;
  continueLastComment := False;
  State := True;
  while State do
  begin
    State := False;
    if (FCurrPos^ = #10) or ((FCurrPos^ = #13) and ((FCurrPos + 1)^ = #10)) then continueLastComment := False;
    if not (FCurrPos^ in [#0,#33..#255]) then State := EatWhite;
    if (FCurrPos^ = '/') and ((FCurrPos + 1)^ = '*') then
    begin
      Comment := '';
      EatOne; EatOne; // Skip slash star
      inComment := True;
      State := EatStarComment;
      inComment := False;
    end;
    if (FCurrPos^ = '/') and ((FCurrPos + 1)^ = '/') then
    begin
      if not continueLastComment then
        Comment := ''
      else
        Comment := Comment + #13#10;
      EatOne; EatOne; // Skip the double slashes
      inComment := True;
      State := EatSlashComment;
      inComment := False;
    end;
  end;
end;


function TJavaParser.GetNextToken: string;

  procedure AddOne;
  begin
    Token := Token + GetChar;
  end;

begin
  //Handle qualified identifier as a token
  //'[', ']', '.' are treated as part of a name if directly after chars
  Token := '';

  EatWhiteSpace;

  if not TokenPosLocked then
    FTokenPos := FSourcePos;

  if FCurrPos^ = '"' then // Parse String
  begin
    AddOne;
    while not (FCurrPos^ in ['"',#0]) do
    begin
      if ((FCurrPos^ = '\') and ((FCurrPos + 1)^ in ['"','\'])) then AddOne;
      AddOne;
    end;
    AddOne;
  end
  else if FCurrPos^ = '''' then // Parse char
  begin
    AddOne;
    while not (FCurrPos^ in ['''',#0]) do
    begin
      if ((FCurrPos^ = '\') and ((FCurrPos + 1)^ in ['''','\'])) then AddOne;
      AddOne;
    end;
    AddOne;
  end
  else if FCurrPos^ in ['A'..'Z', 'a'..'z', '_', '$'] then
  begin //Identifier
    AddOne;
    while True do
    begin
      while FCurrPos^ in ['A'..'Z', 'a'..'z', '0'..'9', '_'] do AddOne;
      if FCurrPos^ = '.' then
      begin
        AddOne;
        Continue;
      end;
      Break;
    end;
    while FCurrPos^ in ['[', ']'] do AddOne;
  end
  else if FCurrPos^ in [';', '{', '}', '(', ')', ',', '='] then
  begin //Single chars
    AddOne;
  end
  else if FCurrPos^ = '[' then  //Loose brackets
    while FCurrPos^ in ['[', ']'] do AddOne
  else //Everything else, forward to whitespace or interesting char
  begin
    while not (FCurrPos^ in [#0, #9, #10, #12, #13, #32, ',', '=', ';', '{', '}', '(', ')', '"', '''']) do AddOne;
  end;

  Result := Token;
end;

procedure TJavaParser.ParseStream(AStream: TStream; AModel: TAbstractPackage; AOM: TObjectModel);
var
  oldCurrentSourcefilename: PString;
  oldCurrentSourceX: PInteger;
  oldCurrentSourceY: PInteger;
begin
  if Assigned(FStream) then
    FreeAndNil(FStream);

  oldCurrentSourcefilename := uModelEntity.CurrentSourcefilename;
  oldCurrentSourceX        := uModelEntity.CurrentSourceX;
  oldCurrentSourceY        := uModelEntity.CurrentSourceY;

  uModelEntity.CurrentSourcefilename := @FFileName;
  uModelEntity.CurrentSourceX := @FTokenPos.X;
  uModelEntity.CurrentSourceY := @FTokenPos.Y;

  try
    FStream := StreamToMemory(AStream);
    FCurrPos := FStream.Memory;

    FModel := AModel;
    FOM := AOM;

    ParseCompilationUnit;
  finally
    uModelEntity.CurrentSourcefilename := oldCurrentSourcefilename;
    uModelEntity.CurrentSourceX        := oldCurrentSourceX;
    uModelEntity.CurrentSourceY        := oldCurrentSourceY;
  end;
end;

(*
QualifiedIdentifier:
    Identifier { . Identifier }
*)

procedure TJavaParser.ParseModifiersOpt;
(*
ModifiersOpt:
    { Modifier }

Modifier:
    public
    protected
    private
    static
    abstract
    final
    native
    synchronized
    transient
    volatile
    strictfp
*)
begin
  //Clear flags
  ModVisibility := viPublic;
  ModAbstract := False;
  while True do
  begin
    //Set flags based on visibility
    if Token = 'public' then
      ModVisibility := viPublic
    else if Token = 'protected' then
      ModVisibility := viProtected
    else if Token = 'private' then
      ModVisibility := viPrivate
    else if Token = 'abstract' then
      ModAbstract := True
    else if (Token = 'static') or (Token = 'final') or (Token = 'native') or
      (Token = 'synchronized') or (Token = 'transient') or (Token = 'volatile') or (Token = 'strictfp') then
    else
      Break;
    GetNextToken;
  end;
end;


procedure TJavaParser.ParseCompilationUnit;
(*
CompilationUnit:
 [package QualifiedIdentifier   ;  ]
        {ImportDeclaration}
        {TypeDeclaration}
*)
var
  UnitName: string;
  S : string;
begin
  GetNextToken;

  if Token = 'package' then
  begin
    UnitName := GetNextToken;
    SkipToken(';');
  end
  else
    UnitName := 'Default';

  FUnit := (FModel as TLogicPackage).FindUnitPackage(UnitName);
  if not Assigned(FUnit) then
    FUnit := (FModel as TLogicPackage).AddUnit(UnitName);

  while Token = 'import' do
  begin
    (*
     ImportDeclaration
        import Identifier {   .   Identifier } [   .     *   ] ;
    *)
    S := GetNextToken;
    if GetNextToken = '*' then
    begin
      FullImports.Add( ExtractPackageName(S) );
      GetNextToken;
    end
    else
    begin
      ClassImports.Values[ ExtractClassName(S) ] := ExtractPackageName(S);
//      NeedClassifier(S);
    end;
    GetNextToken;
  end;

  while Token<>'' do
    ParseTypeDeclaration;
end;


procedure TJavaParser.ParseTypeDeclaration;
(*
TypeDeclaration:
    ClassOrInterfaceDeclaration
    ;

ClassOrInterfaceDeclaration:
    ModifiersOpt (ClassDeclaration | InterfaceDeclaration)

InterfaceDeclaration:
    interface Identifier [extends TypeList] InterfaceBody
*)
begin
  ParseModifiersOpt;
  if Token = 'class' then
    ParseClassDeclaration
  else if Token = 'interface' then
    ParseInterfaceDeclaration
  else if Token = ';' then
    GetNextToken
  else
    //**error
//    raise Exception.Create('JavaParser error')
    GetNextToken
    ;
end;



procedure TJavaParser.ParseClassDeclaration(IsInner : boolean = False; const ParentName : string = '');
(*
ClassDeclaration:
    class Identifier [extends Type] [implements TypeList] ClassBody

ClassBody:
    { {ClassBodyDeclaration} }

ClassBodyDeclaration:
    ;
    [static] Block
    ModifiersOpt MemberDecl

MemberDecl:
    MethodOrFieldDecl
    void Identifier MethodDeclaratorRest
    Identifier ConstructorDeclaratorRest
    ClassOrInterfaceDeclaration

MethodOrFieldDecl:
    Type Identifier MethodOrFieldRest

MethodOrFieldRest:
    VariableDeclaratorRest
    MethodDeclaratorRest
*)
var
  C: TClass;
  Int: TInterface;
  TypeName, Ident: string;
begin
  GetNextToken;
  C := FUnit.AddClass(Token);
  SetVisibility(C);
  GetNextToken;

  if Token = 'extends' then
  begin
    C.Ancestor := NeedClassifier(GetNextToken, True, TClass) as TClass;
    GetNextToken;
  end;

  if Token = 'implements' then
  begin
    repeat
      Int := NeedClassifier(GetNextToken, True, TInterface) as TInterface;
      if Assigned(Int) then
        C.AddImplements(Int);
      GetNextToken;
    until Token <> ',';
  end;

  if Token = '{' then
  begin
    GetNextToken;
    while True do
    begin
      ParseModifiersOpt;
      if Token = '{' then
        //Static initializer
        SkipPair('{', '}')
      else if Token = ';' then
        //single semicolon
        GetNextToken
      else if Token = 'class' then
        //Inner class
        ParseClassDeclaration(True,C.Name)
      else if Token = 'interface' then
        //Inner interface
        ParseInterfaceDeclaration
      else if (Token = '}') or (Token='') then
      begin
        //End of class declaration
        GetNextToken;
        Break;
      end
      else
      begin
        //Must be typename for attr or operation
        //Or constructor
        TypeName := GetTypeName;
        if (TypeName = C.Name) and (Token = '(') then
        begin
          Ident := TypeName; //constructor
          TypeName := '';
        end
        else
        begin
          TokenPosLocked := True;
          Ident := Token;
          GetNextToken;
        end;
        if Token = '(' then
        begin
          //Operation
          DoOperation(C.AddOperation(Ident), C.Name, TypeName);
          GetNextToken; //')'
          //Skip Throws if present
          while (Token<>';') and (Token <> '{') and (Token <> '') do
            GetNextToken;
          //Either ; for abstract method or { for body
          if Token='{' then
            SkipPair('{', '}');
        end
        else
        begin
          //Attributes
          DoAttribute(C.AddAttribute(Ident), TypeName);
          while Token = ',' do
          begin
            DoAttribute(C.AddAttribute(GetNextToken), TypeName);
            GetNextToken;
          end;
          Comment := '';
        end;
      end;
    end;
  end;

  //Parent name is added last to make constructors etc to work
  //**Is this sufficent
  if IsInner then
    C.Name := ParentName + '.' + C.Name;
end;

procedure TJavaParser.ParseInterfaceDeclaration;
(*
InterfaceDeclaration:
	interface Identifier [extends TypeList] InterfaceBody

InterfaceBody:
	{ {InterfaceBodyDeclaration} }

InterfaceBodyDeclaration:
	;
	ModifiersOpt InterfaceMemberDecl

InterfaceMemberDecl:
	InterfaceMethodOrFieldDecl
	void Identifier VoidInterfaceMethodDeclaratorRest
	ClassOrInterfaceDeclaration

InterfaceMethodOrFieldDecl:
	Type Identifier InterfaceMethodOrFieldRest

InterfaceMethodOrFieldRest:
	ConstantDeclaratorsRest ;
	InterfaceMethodDeclaratorRest

InterfaceMethodDeclaratorRest:
	FormalParameters BracketsOpt [throws QualifiedIdentifierList]   ;

VoidInterfaceMethodDeclaratorRest:
	FormalParameters [throws QualifiedIdentifierList]   ;
*)
var
  Int: TInterface;
  TypeName, Ident: string;
begin
  GetNextToken;
  Int := FUnit.AddInterface(Token);
  SetVisibility(Int);
  GetNextToken;

  if Token = 'extends' then
  begin
    Int.Ancestor := NeedClassifier(GetNextToken, True, TInterface) as TInterface;
    //**limitation: an java interface can extend several interfaces, but our model only support one ancestor
    GetNextToken;
    while Token=',' do
    begin
      GetNextToken;
      GetNextToken;
    end;
  end;

  if Token = '{' then
  begin
    GetNextToken;
    while True do
    begin
      ParseModifiersOpt;
      if Token = ';' then
        //empty
        GetNextToken
      else if Token = 'class' then
        //Inner class
        ParseClassDeclaration
      else if Token = 'interface' then
        //Inner interface
        ParseInterfaceDeclaration
      else if (Token = '}')  or (Token='') then
      begin
        //End of interfacedeclaration
        GetNextToken;
        Break;
      end
      else
      begin
        //Must be type of attr or return type of operation
        TypeName := GetTypeName;
        Ident := Token;
        TokenPosLocked := True;
        if GetNextToken = '(' then
        begin
          //Operation
          DoOperation(Int.AddOperation(Ident), Int.Name, TypeName);
          GetNextToken;
          //Skip Throws if present
          while (Token<>';') and (Token <> '') do
            GetNextToken;
        end
        else
        begin
          DoAttribute(Int.AddAttribute(Ident) , TypeName);
          while Token = ',' do
          begin
            DoAttribute(Int.AddAttribute(GetNextToken), TypeName);
            GetNextToken;
          end;
          Comment := '';
        end;
      end;
    end;
  end;
end;



function TJavaParser.NeedClassifier(const CName: string; Force :  boolean = True; TheClass: TModelEntityClass = nil): TClassifier;
var
  PName,ShortName : string;
  CacheI : integer;

  function InLookInModel : TClassifier;
  var
    U : TUnitPackage;
    I : integer;
  begin
    Result := nil;
    if PName='' then
    //No packagename, check in current unit and imports
    begin
      //Classimports ( java.util.HashTable )
      for I := 0 to ClassImports.Count-1 do
        //Can not use indexofname because of casesensetivity
        if ClassImports.Names[I]=ShortName then
        begin
          Result := NeedClassifier( ClassImports.Values[ShortName] + '.' + ShortName, False, TheClass );
          if Assigned(Result) then
            Break;
        end;
      //Fullimports ( java.util.* )
      if not Assigned(Result) then
      begin
        for I := 0 to FullImports.Count-1 do
        begin
          Result := NeedClassifier( FullImports[I] + '.' + ShortName, False, TheClass );
          if Assigned(Result) then
            Break;
        end;
      end;
      //Check in current unit
      if not Assigned(Result) then
        Result := FUnit.FindClassifier(ShortName,False,TheClass,True);
    end
    else
    //Packagename, look for package
    begin
      U := FOM.ModelRoot.FindUnitPackage(PName);
      if not Assigned(U) then
        //Try to find shortname.java file in all known paths
        //Then look in model again
        //**Not sufficient, finds List.java first in awt when it is List.java in util that is needed
        //**Should iterate all .java files that have shortname
        if NeedSource(ShortName) then
          U := FOM.ModelRoot.FindUnitPackage(PName);
      if Assigned(U) then
        Result := U.FindClassifier(ShortName,False,TheClass,True);
    end;
  end;

begin
  //First of all, look in cache of names we have already looked up
  //Optimization that saves a lot of time for large projects
  CacheI := NameCache.IndexOf(CName);
  //Stringlist indexof is not casesensitive so we must double check
  if (CacheI<>-1) and (NameCache[CacheI]=CName) and ((TheClass=nil) or (NameCache.Objects[CacheI] is TheClass)) then
  begin
    Result := TClassifier(NameCache.Objects[CacheI]);
    Exit;
  end;

  PName := ExtractPackageName(CName);
  ShortName := ExtractClassName(CName);

  //Look in the model
  Result := InLookInModel;

  //Otherwise see if we can find the file we need
  if not Assigned(Result) then
    if NeedSource(ShortName) then
      Result := InLookInModel;

  if not Assigned(Result) then
  begin
    //Look in unknown
    Result := FOM.UnknownPackage.FindClassifier(CName,False,TheClass,True);
    if Force and (not Assigned(Result)) then
    begin
      //Missing, create in unknown (if Force)
      if (TheClass=nil) or (TheClass=TClass) then
        Result := FOM.UnknownPackage.AddClass(CName)
      else if TheClass=TInterface then
        Result := FOM.UnknownPackage.AddInterface(CName)
      else if TheClass=TDataType then
        Result := FOM.UnknownPackage.AddDataType(CName)
    end;
  end;

  if Assigned(Result) and (CacheI=-1) then
    NameCache.AddObject(CName,Result);

  if Force and (not Assigned(Result)) then
    raise Exception.Create(ClassName + ' failed to locate ' + Cname);
end;



//Set visibility based on flags assigned by parseOptModifier
procedure TJavaParser.SetVisibility(M: TModelEntity);
begin
  M.Visibility := ModVisibility;
  if ModAbstract and (M is TOperation) then
    (M as TOperation).IsAbstract := ModAbstract;
end;

function TJavaParser.GetChar: char;
begin
  Result := FCurrPos^;

  if Result<>#0 then
    Inc(FCurrPos);

  if FCurrPos^ = #10 then
  begin
    Inc(FSourcePos.Y);
    FSourcePos.X := 0;
  end else
    Inc(FSourcePos.X);
end;

procedure TJavaParser.DoOperation(O: TOperation; const ParentName, TypeName: string);
var
  ParType: string;
begin
  TokenPosLocked := False;
  SetVisibility(O);
  if (TypeName <> '') and (TypeName <> 'void') then
    O.ReturnValue := NeedClassifier(TypeName);
  if Assigned(O.ReturnValue) then
    O.OperationType := otFunction
  else if ParentName = O.Name then
    O.OperationType := otConstructor
  else
    O.OperationType := otProcedure;
  //Parameters
  GetNextToken;
  while (Token<>'') and (Token <> ')') do
  begin
    if Token = 'final' then
      GetNextToken;
    ParType := GetTypeName;
    O.AddParameter(Token).TypeClassifier := NeedClassifier(ParType);
    GetNextToken;
    if Token=',' then
      GetNextToken;
  end;
  O.Documentation.Description := Comment;
  Comment := '';
end;

procedure TJavaParser.DoAttribute(A: TAttribute; const TypeName: string);
begin
  TokenPosLocked := False;
  SetVisibility(A);
  if Token = '=' then
    while (Token <> ';') and (Token<>'') do
    begin
      GetNextToken;
      //Attribute initializers can hold complete inner class declarations
      if Token='{' then
        SkipPair('{','}');
    end;
  A.TypeClassifier := NeedClassifier(TypeName);
  A.Documentation.Description := Comment;
  if Token=';' then
    GetNextToken;
end;

//Handles that a typename can be followed by a separate []
function TJavaParser.GetTypeName: string;
(*
Type:
	Identifier {   .   Identifier } BracketsOpt
	BasicType

*)
begin
  Result := Token;
  GetNextToken;
  if (Length(Token)>0) and (Token[1]='[') then
  begin
    Result := Result + Token;
    GetNextToken;
  end;
end;


//Call needpackage
//Note that 'package' in javaparser is a .java-file
function TJavaParser.NeedSource(const SourceName: string): boolean;
var
  Str : TStream;
  Parser : TJavaParser;
  FileName : string;
begin
  Result := False;
  if Assigned(NeedPackage) then
  begin
    FileName := NeedPackage(SourceName,Str{%H-});
    if Assigned(Str) then
    begin
      Parser := TJavaParser.Create;
      try
        Parser.FileName := FileName;
        Parser.NeedPackage := NeedPackage;
        Parser.ParseStream(Str, FOM.ModelRoot, FOM);
      finally
        Parser.Free;
      end;
      Result := True;
    end;
  end;
end;


initialization

  Integrators.Register(TJavaImporter);

end.
