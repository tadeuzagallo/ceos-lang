module Typing.Decl (c_decl) where

import Typing.Ctx
import Typing.Expr
import Typing.Util
import Typing.State
import Typing.Substitution
import Typing.TypeError
import Typing.Types

import Absyn.Base
import Absyn.Meta
import Absyn.ValueOccursCheck
import qualified Absyn.Untyped as U
import qualified Absyn.Typed as T
import Util.Error

import Control.Monad (when)
import Data.List (intersect)

{-
   Δ : types context
   Γ : values context
   Ψ : implementations context (for brevity only mentioned on the necessary rules)
-}

c_decl :: U.Decl -> Tc T.Decl

{-
  Δ; Γ ⊢ f : T
  ----------------------- FnDecl
  Δ; Γ ⊢ fn ⊣ Γ, f : T; Δ
-}
c_decl (FnStmt fn) = do
  (fn', ty) <-  i_fn fn
  addValueType (name fn, ty)
  return $ FnStmt fn'

{-
   ∀ Ci ∈ C1..Cn, ∀ Tij ∈ Ti1..Tik, Δ, S1 : *, ..., Sn : *, E : arity(m, *); Γ ⊢ Tik : *
   ------------------------------------------------------------------------------------------------------------------ EnumDecl
   Δ; Γ ⊢ enum E<S1, ..., Sm> { C1(T11..T1j), ..., Cn(Tn1..Tnk) }
        ⊣ Δ, E: arity(m, *); Γ, C1 : ∀ S1, ..., Sm. T1 -> ... Tj -> E, ..., Cn : ∀ S1, ..., Sm. T1 -> ... -> Tk -> E
-}
c_decl (Enum name generics ctors) = do
  generics' <- resolveGenericVars (defaultBounds generics)
  let mkEnumTy ty = case (ty, generics') of
                (Nothing, []) -> Con name
                (Nothing, _)  -> Forall (map fst generics') (TyApp (Con name) (map (uncurry Var) generics'))
                (Just t, [])   -> Fun generics' t (Con name)
                (Just t, _)   -> Fun generics' t (TyApp (Con name) (map (uncurry Var) generics'))
  let enumTy =
        if null generics
           then Con name
           else TyAbs (map fst generics') (TyApp (Con name) (map (uncurry Var) generics'))
  addType (name, enumTy)

  -- Only visible inside the enum
  m <- startMarker
  addGenerics generics'
  endMarker m

  ctors' <- mapM (i_ctor mkEnumTy) ctors

  -- cleanup before returning
  clearMarker m
  return $ Enum (name, enumTy) generics ctors'

{-
                   S :: *              T :: *              U :: *
                   Δ, S1 : *, ..., Sn : *; Γ, x : S, y: U ⊢ e : V
                                   V <: U
   -----------------------------------------------------------------------------------
   Δ; Γ ⊢ operator<V1, ..., Vn> (x : S) OP (y : T) -> U { e } ⊣ Δ; Γ, OP : S -> T -> U
-}
c_decl (Operator opAssoc opPrec opGenerics opLhs opName opRhs opRetType opBody) = do
  opGenerics' <- resolveGenericBounds opGenerics
  opGenericVars <- resolveGenericVars opGenerics'


  m <- startMarker
  addGenerics opGenericVars
  opLhs' <- resolveId opLhs
  opRhs' <- resolveId opRhs
  opRetType' <- resolveType opRetType
  addValueType opLhs'
  addValueType opRhs'
  endMarker m

  let ty = Fun opGenericVars [snd opLhs', snd opRhs'] opRetType'
  addValueType (opName, ty)
  (opBody', bodyTy) <- i_body opBody

  clearMarker m

  bodyTy <:! opRetType'
  return $ Operator { opAssoc
                    , opPrec
                    , opGenerics = opGenerics'
                    , opLhs = opLhs'
                    , opName = (opName, ty)
                    , opRhs = opRhs'
                    , opRetType = opRetType'
                    , opBody = opBody' }

{-

   T :: *      Δ; Γ, x: T ⊢ e : S     S <: T
   ----------------------------------------- LetRecDecl
      Δ; Γ ⊢ let x : T = e ⊣ Δ; Γ, x : T

           Δ; Γ ⊢ e : S
   ------------------------------ LetDecl
   Δ; Γ ⊢ let x = e ⊣ Δ; Γ, x : S
-}
c_decl (Let (var, ty) expr) = do
  (expr', exprTy) <-
    case ty of
      U.TPlaceholder -> do
        (expr', exprTy) <- i_expr expr
        addValueType (var, exprTy)
        return (expr', exprTy)
      _ -> do
        ty' <- resolveType ty
        addValueType (var, ty')
        _ <- valueOccursCheck var expr
        (expr', exprTy) <- i_expr expr
        exprTy <:! ty'
        return (expr', ty')
  return $ Let (var, exprTy) expr'

c_decl cls@(Class {}) = do
  i_class cls

{-
   NOTE: interface lets must bind to functions for now - it gets a bit more complicated with arbitrary types

   ∀ i ∈ 1..n, Δ, T :: * ⊢ Ti <: ⊥ -> ⊤
   ----------------------------------------------------- InterfaceDecl
   Δ; Γ ⊢ interface  I<T> {
     decl1 : T1
     ...
     decln : Tn
  } ⊣ Δ, I : Interface { decl1 : T1, ... decln : Tn } ;
      Γ, decl1 : ∀(T: I). T1, ..., decln :  ∀(T : I). Tn
-}
c_decl (Interface name param methods) = do
  g@[(param', [])] <- resolveGenericVars [(param, [])]

  m <- startMarker
  addGenerics g
  endMarker m

  (methods', methodsTy) <- unzip <$> mapM i_interfaceItem methods

  clearMarker m

  let ty = Intf name param' methodsTy
  mapM_ (aux ty param') methodsTy
  addInterface (name, ty)
  return $ Interface (name, void) param methods'
    where
      aux intf param (name, Fun gen params retType) =
        let ty = Fun ((param, [intf]) : gen) params retType
         in addValueType (name, ty)
      aux _ _ _ = throwError $ GenericError "let bindings within interfaces must be functions"

{-
   TODO: Check for existing implementation for type

  ∀ i ∈ 1..n, Δ, U1 :: *, ..., Un :: *; Γ ⊢ impli : T /\ T <: Δ(I)[impli]
  ---------------------------------------------- ImplementationDecl
   Δ; Γ; Ψ ⊢ implement<U1, ..., Un> I<T> {
     impl1
     ...
     impln
   } ⊣ Δ; Γ; Ψ, I<T> : { impl1, ..., impln }
-}
c_decl (Implementation implName generics ty methods) = do
  Intf _ param intfMethods <- getInterface implName
  generics' <- resolveGenericBounds generics
  genericVars <- resolveGenericVars generics'

  m <- startMarker

  addGenerics genericVars
  ty' <- resolveType ty
  let substs = mkSubst (param, ty')

  -- NOTE: this will add the implementation to the context, but implementations
  -- are not erased by markers
  extendCtx ty' genericVars

  (methods', names) <- unzip <$> mapM (i_implItem substs intfMethods) methods
  endMarker m

  clearMarker m

  checkCompleteInterface intfMethods names
  return $ Implementation (implName, void) generics' ty' methods'

  where
    extendCtx (TyApp ty args) genericVars@(_:_) | vars  `intersect` args == vars =
      addImplementation (implName, (ty, genericVars))
        where
          vars = map (uncurry Var) genericVars
    extendCtx ty@(TyApp _ _) [] =
      throwError (ImplementationError implName ty)
    extendCtx ty [] =
      addImplementation (implName, (ty, []))
    extendCtx ty _ =
      throwError (ImplementationError implName ty)

{-
  Δ, T1 :: *, ..., Tn :: *; Γ ⊢ well_formed U
  ------------------------------------------------- AliasTypeDecl
  Δ; Γ ⊢ type S<T1, ..., Tn> = U ⊣ Δ, ΛT1..Tn. U; Γ
-}
c_decl (TypeAlias aliasName aliasVars aliasType) = do
  aliasVars' <- resolveGenericVars (defaultBounds aliasVars)

  m <- startMarker
  addGenerics aliasVars'
  endMarker m

  aliasType' <- resolveType aliasType

  clearMarker m

  let aliasType'' = case aliasVars' of
                [] -> aliasType'
                _  -> TyAbs (map fst aliasVars') aliasType'
  addType (aliasName, aliasType'')
  return $ TypeAlias aliasName aliasVars aliasType''


checkCompleteInterface :: [(Name, Type)] -> [Name] -> Tc ()
checkCompleteInterface intf impl = do
  mapM_ aux intf
  where
    aux :: (Name, Type) -> Tc ()
    aux (methodName, _) =
      when (methodName `notElem` impl) $ throwError (ImplementationMissingMethod methodName)


getIntfType :: Name -> [(Name, Type)] -> Tc Type
getIntfType name intf = do
  case lookup name intf of
    Nothing -> throwError $ ExtraneousImplementation name
    Just ty -> return ty


-- TODO: this should switch to checking mode
i_implItem :: Substitution -> [(Name, Type)] -> U.ImplementationItem -> Tc (T.ImplementationItem, Name)
i_implItem subst intfTypes (ImplVar (name, expr)) = do
  (expr', exprTy) <- i_expr expr
  intfTy <- applySubst subst <$> getIntfType name intfTypes
  intfTy <:! exprTy
  return (ImplVar ((name, intfTy), expr'), name)

i_implItem subst intfTypes (ImplFunction name params body) = do
  intfTy <- applySubst subst <$> getIntfType name intfTypes
  Fun _ paramsTy retTy <- case intfTy of
                            Fun _ ps _ | length ps == length params -> return intfTy
                            _ -> throwError $ GenericError "Implementation type doesn't match interface"
  mapM_ addValueType (zip params paramsTy)
  (body', bodyTy) <- i_body body
  bodyTy <:! retTy
  return (ImplFunction (name, intfTy) params body', name)

i_implItem subst intfTypes (ImplOperator lhs op rhs body) = do
  intfTy <- applySubst subst <$> getIntfType op intfTypes
  Fun _ paramsTy retTy <- case intfTy of
                            Fun _ ps _ | length ps == 2 -> return intfTy
                            _ -> throwError $ GenericError "Implementation type doesn't match interface"
  mapM_ addValueType (zip [lhs, rhs] paramsTy)
  (body', bodyTy) <- i_body body
  bodyTy <:! retTy
  return (ImplOperator lhs (op, intfTy) rhs body', op)


i_ctor :: (Maybe [Type] -> Type) -> U.DataCtor -> Tc T.DataCtor
i_ctor mkEnumTy (name, types) = do
  types' <- sequence (mapM resolveType <$> types)
  let ty = mkEnumTy types'
  addValueType (name, ty)
  return ((name, ty), types')

i_class :: U.Decl -> Tc T.Decl
i_class (Class name vars methods) = do
  let classTy = Cls name
  addType (name, classTy)
  vars' <- mapM resolveId vars
  let ctorTy = [Rec vars'] ~> classTy
  addValueType (name, ctorTy)
  addInstanceVars (classTy, vars')
  mapM_ (i_addMethodType classTy) methods
  methods' <- mapM (i_method classTy) methods
  return $ Class (name, classTy) vars' methods'

i_class _ = undefined

i_addMethodType :: Type -> U.Function -> Tc ()
i_addMethodType classTy fn = do
  gen' <- resolveGenericBounds $ generics fn
  genericVars <- resolveGenericVars gen'
  let fn' = fn { params = ("self", U.TName "Self") : params fn }

  m <- startMarker
  addType ("Self", classTy)
  addGenerics genericVars
  endMarker m

  (ty, _, _) <- fnTy (genericVars, params fn', retType fn')

  clearMarker m

  addValueType (name fn', ty)

i_method :: Type -> U.Function -> Tc T.Function
i_method classTy fn = do
  m <- startMarker
  addType ("Self", classTy)
  endMarker m

  (fn', ty) <- i_fn $ fn { params = ("self", U.TName "Self") : params fn }
  addValueType (name fn, ty)

  clearMarker m

  return fn'


i_interfaceItem :: U.InterfaceItem -> Tc (T.InterfaceItem, T.Id)
i_interfaceItem (IntfVar id) = do
  id' <- resolveId id
  return (IntfVar id', id')

i_interfaceItem op@(IntfOperator _ _ lhs name rhs retType) = do
  lhs' <- resolveType lhs
  rhs' <- resolveType rhs
  retType' <- resolveType retType
  let ty = Fun [] [lhs', rhs'] retType'
  let op' = op { intfOpLhs = lhs'
               , intfOpName = (name, ty)
               , intfOpRhs = rhs'
               , intfOpRetType = retType'
               }
  return (op', (name, ty))
