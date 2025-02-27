module NoUnused.Modules exposing (rule)

{-| Forbid the use of modules that are never used in your project.


# Rule

@docs rule

-}

import Dict exposing (Dict)
import Elm.Module
import Elm.Project exposing (Project)
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range exposing (Range)
import NoUnused.LamderaSupport as LamderaSupport
import Review.Rule as Rule exposing (Error, Rule)
import Set exposing (Set)


{-| Forbid the use of modules that are never used in your project.

A module is considered used if

  - it contains a `main` function (be it exposed or not)
  - it imports the `Test` module
  - it is imported in any other modules, even if it is not used.
  - the project is a package and the module is part of the `elm.json`'s `exposed-modules`
  - it is named `ReviewConfig`

```elm
config =
    [ NoUnused.Modules.rule
    ]
```


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-review-unused/example --rules NoUnused.Modules
```

-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "NoUnused.Modules" initialProjectContext
        |> Rule.withModuleVisitor moduleVisitor
        |> Rule.withModuleContext
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withElmJsonProjectVisitor elmJsonVisitor
        |> Rule.withFinalProjectEvaluation finalEvaluationForProject
        |> Rule.fromProjectRuleSchema


moduleVisitor : Rule.ModuleRuleSchema {} ModuleContext -> Rule.ModuleRuleSchema { hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Rule.withImportVisitor importVisitor
        |> Rule.withDeclarationListVisitor declarationListVisitor



-- CONTEXT


type alias ProjectContext =
    { modules :
        Dict
            ModuleName
            { moduleKey : Rule.ModuleKey
            , moduleNameLocation : Range
            }
    , usedModules : Set ModuleName
    , projectType : ProjectType
    }


type alias ModuleContext =
    { importedModules : Set ModuleName
    , containsMainFunction : Bool
    , projectType : ProjectType
    }


type ProjectType
    = Package
    | Application ElmApplicationType


type ElmApplicationType
    = ElmApplication
    | LamderaApplication


initialProjectContext : ProjectContext
initialProjectContext =
    { modules = Dict.empty
    , usedModules = Set.singleton [ "ReviewConfig" ]
    , projectType = Application ElmApplication
    }


fromProjectToModule : Rule.ModuleKey -> Node ModuleName -> ProjectContext -> ModuleContext
fromProjectToModule _ _ projectContext =
    { importedModules = Set.empty
    , containsMainFunction = False
    , projectType = projectContext.projectType
    }


fromModuleToProject : Rule.ModuleKey -> Node ModuleName -> ModuleContext -> ProjectContext
fromModuleToProject moduleKey moduleName moduleContext =
    { modules =
        Dict.singleton
            (Node.value moduleName)
            { moduleKey = moduleKey, moduleNameLocation = Node.range moduleName }
    , usedModules =
        if Set.member [ "Test" ] moduleContext.importedModules || moduleContext.containsMainFunction then
            Set.insert (Node.value moduleName) moduleContext.importedModules

        else
            moduleContext.importedModules
    , projectType = moduleContext.projectType
    }


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { modules = Dict.union previousContext.modules newContext.modules
    , usedModules = Set.union previousContext.usedModules newContext.usedModules
    , projectType = previousContext.projectType
    }



-- PROJECT VISITORS


elmJsonVisitor : Maybe { a | project : Project } -> ProjectContext -> ( List nothing, ProjectContext )
elmJsonVisitor maybeProject projectContext =
    let
        ( exposedModules, projectType ) =
            case maybeProject |> Maybe.map .project of
                Just (Elm.Project.Package { exposed }) ->
                    case exposed of
                        Elm.Project.ExposedList names ->
                            ( names, Package )

                        Elm.Project.ExposedDict fakeDict ->
                            ( List.concatMap Tuple.second fakeDict, Package )

                Just (Elm.Project.Application { depsDirect }) ->
                    let
                        elmApplicationType : ElmApplicationType
                        elmApplicationType =
                            if LamderaSupport.isLamderaApplication depsDirect then
                                LamderaApplication

                            else
                                ElmApplication
                    in
                    ( [], Application elmApplicationType )

                Nothing ->
                    ( [], Application ElmApplication )
    in
    ( []
    , { projectContext
        | usedModules =
            exposedModules
                |> List.map (Elm.Module.toString >> String.split ".")
                |> Set.fromList
                |> Set.union projectContext.usedModules
        , projectType = projectType
      }
    )


finalEvaluationForProject : ProjectContext -> List (Error scope)
finalEvaluationForProject { modules, usedModules } =
    modules
        |> Dict.filter (\moduleName _ -> not <| Set.member moduleName usedModules)
        |> Dict.toList
        |> List.map error


error : ( ModuleName, { moduleKey : Rule.ModuleKey, moduleNameLocation : Range } ) -> Error scope
error ( moduleName, { moduleKey, moduleNameLocation } ) =
    Rule.errorForModule moduleKey
        { message = "Module `" ++ String.join "." moduleName ++ "` is never used."
        , details = [ "This module is never used. You may want to remove it to keep your project clean, and maybe detect some unused code in your project." ]
        }
        moduleNameLocation



-- IMPORT VISITOR


importVisitor : Node Import -> ModuleContext -> ( List nothing, ModuleContext )
importVisitor node context =
    ( []
    , { context | importedModules = Set.insert (moduleNameForImport node) context.importedModules }
    )


moduleNameForImport : Node Import -> ModuleName
moduleNameForImport node =
    node
        |> Node.value
        |> .moduleName
        |> Node.value



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> ModuleContext -> ( List nothing, ModuleContext )
declarationListVisitor list context =
    case context.projectType of
        Package ->
            ( [], context )

        Application elmApplicationType ->
            let
                mainName : String
                mainName =
                    mainFunctionName elmApplicationType

                containsMainFunction : Bool
                containsMainFunction =
                    List.any
                        (\declaration ->
                            case Node.value declaration of
                                Declaration.FunctionDeclaration function ->
                                    (function.declaration |> Node.value |> .name |> Node.value) == mainName

                                _ ->
                                    False
                        )
                        list
            in
            ( []
            , { context | containsMainFunction = containsMainFunction }
            )


mainFunctionName : ElmApplicationType -> String
mainFunctionName elmApplicationType =
    case elmApplicationType of
        ElmApplication ->
            "main"

        LamderaApplication ->
            "app"
