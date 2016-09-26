module Naming (naming) where

import AST

import qualified Data.Map as Map

import Control.Monad (liftM)
import Control.Monad.State (State, evalState, gets, modify)

type Context = (Map.Map String Expr)
type NamingState = State Context

naming :: Program -> Program
naming program = evalState (naming_program program) Map.empty


naming_program :: Program -> NamingState Program
naming_program (Program imports decls) = do
  imports' <- mapM naming_import imports
  decls' <- mapM naming_decl decls
  return $ Program imports' decls'

naming_import :: Import -> NamingState Import
naming_import imp = return imp

naming_decl :: TopDecl -> NamingState TopDecl
naming_decl (InterfaceDecl interface) =
  InterfaceDecl <$> naming_interface interface 

naming_decl (ImplementationDecl implementation) =
  ImplementationDecl <$> naming_implementation implementation

naming_decl (ExternDecl prototype) =
  ExternDecl <$> naming_prototype prototype

naming_decl (TypeDecl enum_type) =
  return $ TypeDecl enum_type

naming_decl (ExprDecl expr) =
  ExprDecl <$> naming_expr expr

naming_interface :: Interface -> NamingState Interface
naming_interface interface = return interface

naming_implementation :: Implementation -> NamingState Implementation
naming_implementation implementation = return implementation

naming_prototype :: Prototype -> NamingState Prototype
naming_prototype prototype = return prototype

naming_expr :: Expr -> NamingState Expr
naming_expr expr = return expr
