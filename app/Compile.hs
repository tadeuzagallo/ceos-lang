module Compile
  ( evalProgram
  , runPipeline -- re-export for Main
  , loadPrelude
  ) where

import Env
import Options
import Runners

import Absyn.Untyped
import Reassoc.Env (importReassocEnv)
import Renamer.Renamer (renameImport)
import Syntax.Parser (parseFile)
import Typing.State (importModule)
import Interpreter.Env (importEvalEnv)

import Control.Monad.IO.Class (liftIO)
import Data.Char (toUpper)
import Data.List (intercalate)
import Paths_verve (getDataFileName)
import System.Directory (getCurrentDirectory)
import System.FilePath.Posix ((</>), (<.>), takeDirectory, takeFileName, dropExtension, joinPath)

evalProgram :: StmtsFn -> Pipeline ()
evalProgram processStmts = do
  loadPrelude
  inputFiles <- option files
  mapM_ (\f -> execFile processStmts (modNameFromFile f) f) inputFiles

loadPrelude :: Pipeline ()
loadPrelude = do
  prelude <- liftIO $ getDataFileName "lib/Std.vrv"
  execFile runAll "Std" prelude
  flush >> return ()

execFile :: StmtsFn -> String -> FilePath -> Pipeline ()
execFile processStmts moduleName file = do
  pwd <- liftIO getCurrentDirectory
  let file' = pwd </> file
  result <- liftIO $ parseFile file'
  result |> runModule processStmts file' moduleName

runModule :: StmtsFn -> FilePath -> String -> Module -> Pipeline ()
runModule processStmts file modName (Module imports stmts) = do
  resolveImports file imports
  processStmts modName stmts

-- Imports
resolveImports :: FilePath -> [Import] -> Pipeline ()
resolveImports file imports =
  mapM_ (resolveImport file) imports

resolveImport :: FilePath -> Import -> Pipeline ()
resolveImport file imp@(Import _ mod _ _) = do
  let path = takeDirectory file </> joinPath mod <.> "vrv"
  (prevNEnv, prevRnEnv, prevTcState, _, prevEnv) <- getEnv
  updateEnv defaultEnv
  loadPrelude
  execFile runAll (intercalate "." mod) path
  (impNEnv, impRnEnv, impTcState, impDsState, impEnv) <- getEnv
  let (rnEnv', renamedImports) = renameImport prevRnEnv impRnEnv imp
   in updateEnv ( importReassocEnv renamedImports prevNEnv impNEnv
                , rnEnv'
                , importModule renamedImports prevTcState impTcState
                , impDsState
                , importEvalEnv renamedImports prevEnv impEnv
                )

modNameFromFile :: FilePath -> FilePath
modNameFromFile file =
  case dropExtension $ takeFileName file of
    [] -> undefined
    x:xs -> toUpper x : xs
