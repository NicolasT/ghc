\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

-- Type definitions for the constraint solver
module TcSMonad ( 

       -- Canonical constraints, definition is now in TcRnTypes

    WorkList(..), isEmptyWorkList, emptyWorkList,
    workListFromEq, workListFromNonEq, workListFromCt, 
    extendWorkListEq, extendWorkListNonEq, extendWorkListCt, 
    appendWorkListCt, appendWorkListEqs, unionWorkList, selectWorkItem,

    getTcSWorkList, updWorkListTcS, updWorkListTcS_return, keepWanted,
    getTcSWorkListTvs, 

    Ct(..), Xi, tyVarsOfCt, tyVarsOfCts, tyVarsOfCDicts, 
    emitFrozenError,

    isWanted, isGivenOrSolved, isDerived,
    isGivenOrSolvedCt, isGivenCt, 
    isWantedCt, isDerivedCt, pprFlavorArising,

    isFlexiTcsTv,

    canRewrite, canSolve,
    mkSolvedLoc, mkGivenLoc,
    ctWantedLoc,

    TcS, runTcS, failTcS, panicTcS, traceTcS, -- Basic functionality 
    traceFireTcS, bumpStepCountTcS, doWithInert,
    tryTcS, nestImplicTcS, recoverTcS,
    wrapErrTcS, wrapWarnTcS,

    SimplContext(..), isInteractive, simplEqsOnly, performDefaulting,

    -- Getting and setting the flattening cache
    getFlatCache, updFlatCache, addToSolved, 
    
    
    setEvBind,
    XEvTerm(..),
    MaybeNew (..), isFresh,
    xCtFlavor, -- Transform a CtFlavor during a step 
    rewriteCtFlavor,          -- Specialized version of xCtFlavor for coercions
    newWantedEvVar, newGivenEvVar, instDFunConstraints, newKindConstraint,
    newDerived,
    xCtFlavor_cache, rewriteCtFlavor_cache,
    
       -- Creation of evidence variables
    setWantedTyBind,

    getInstEnvs, getFamInstEnvs,                -- Getting the environments
    getTopEnv, getGblEnv, getTcEvBinds, getUntouchables,
    getTcEvBindsMap, getTcSContext, getTcSTyBinds, getTcSTyBindsMap,


    newFlattenSkolemTy,                         -- Flatten skolems 

        -- Inerts 
    InertSet(..), InertCans(..), 
    getInertEqs, getCtCoercion,
    emptyInert, getTcSInerts, lookupInInerts, updInertSet, extractUnsolved,
    extractUnsolvedTcS, modifyInertTcS,
    updInertSetTcS, partitionCCanMap, partitionEqMap,
    getRelevantCts, extractRelevantInerts,
    CCanMap (..), CtTypeMap, CtFamHeadMap(..), CtPredMap(..),
    pprCtTypeMap, partCtFamHeadMap,


    instDFunTypes,                              -- Instantiation
    -- instDFunConstraints,          
    newFlexiTcSTy, instFlexiTcS,

    compatKind, mkKindErrorCtxtTcS,

    TcsUntouchables,
    isTouchableMetaTyVar,
    isTouchableMetaTyVar_InRange, 

    getDefaultInfo, getDynFlags,

    matchClass, matchFam, MatchInstResult (..), 
    checkWellStagedDFun, 
    warnTcS,
    pprEq                                    -- Smaller utils, re-exported from TcM
                                             -- TODO (DV): these are only really used in the 
                                             -- instance matcher in TcSimplify. I am wondering
                                             -- if the whole instance matcher simply belongs
                                             -- here 
) where 

#include "HsVersions.h"

import HscTypes
import BasicTypes 

import Inst
import InstEnv 
import FamInst 
import FamInstEnv

import qualified TcRnMonad as TcM
import qualified TcMType as TcM
import qualified TcEnv as TcM 
       ( checkWellStaged, topIdLvl, tcGetDefaultTys )
import {-# SOURCE #-} qualified TcUnify as TcM ( mkKindErrorCtxt )
import Kind
import TcType
import DynFlags
import Type

import TcEvidence
import Class
import TyCon

import Name
import Var
import VarEnv
import Outputable
import Bag
import MonadUtils
import VarSet

import FastString
import Util
import Id 
import TcRnTypes

import Unique 
import UniqFM
import Maybes ( orElse )

import Control.Monad( when )
import StaticFlags( opt_PprStyle_Debug )
import Data.IORef
import Data.List ( find )
import Control.Monad ( zipWithM )
import TrieMap

\end{code}


\begin{code}
compatKind :: Kind -> Kind -> Bool
compatKind k1 k2 = k1 `tcIsSubKind` k2 || k2 `tcIsSubKind` k1 

mkKindErrorCtxtTcS :: Type -> Kind 
                   -> Type -> Kind 
                   -> ErrCtxt
mkKindErrorCtxtTcS ty1 ki1 ty2 ki2
  = (False,TcM.mkKindErrorCtxt ty1 ty2 ki1 ki2)

\end{code}

%************************************************************************
%*									*
%*                            Worklists                                *
%*  Canonical and non-canonical constraints that the simplifier has to  *
%*  work on. Including their simplification depths.                     *
%*                                                                      *
%*									*
%************************************************************************

Note [WorkList]
~~~~~~~~~~~~~~~

A WorkList contains canonical and non-canonical items (of all flavors). 
Notice that each Ct now has a simplification depth. We may 
consider using this depth for prioritization as well in the future. 

As a simple form of priority queue, our worklist separates out
equalities (wl_eqs) from the rest of the canonical constraints, 
so that it's easier to deal with them first, but the separation 
is not strictly necessary. Notice that non-canonical constraints 
are also parts of the worklist. 

Note [NonCanonical Semantics]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Note that canonical constraints involve a CNonCanonical constructor. In the worklist
we use this constructor for constraints that have not yet been canonicalized such as 
   [Int] ~ [a] 
In other words, all constraints start life as NonCanonicals. 

On the other hand, in the Inert Set (see below) the presence of a NonCanonical somewhere
means that we have a ``frozen error''. 

NonCanonical constraints never interact directly with other constraints -- but they can
be rewritten by equalities (for instance if a non canonical exists in the inert, we'd 
better rewrite it as much as possible before reporting it as an error to the user)

\begin{code}

-- See Note [WorkList]
data WorkList = WorkList { wl_eqs    :: [Ct]
                         , wl_funeqs :: [Ct]
                         , wl_rest   :: [Ct] 
                         }


unionWorkList :: WorkList -> WorkList -> WorkList
unionWorkList new_wl orig_wl = 
   WorkList { wl_eqs    = wl_eqs new_wl ++ wl_eqs orig_wl
            , wl_funeqs = wl_funeqs new_wl ++ wl_funeqs orig_wl
            , wl_rest   = wl_rest new_wl ++ wl_rest orig_wl }


extendWorkListEq :: Ct -> WorkList -> WorkList
-- Extension by equality
extendWorkListEq ct wl 
  | Just {} <- isCFunEqCan_Maybe ct
  = wl { wl_funeqs = ct : wl_funeqs wl }
  | otherwise
  = wl { wl_eqs = ct : wl_eqs wl }

extendWorkListNonEq :: Ct -> WorkList -> WorkList
-- Extension by non equality
extendWorkListNonEq ct wl 
  = wl { wl_rest = ct : wl_rest wl }

extendWorkListCt :: Ct -> WorkList -> WorkList
-- Agnostic
extendWorkListCt ct wl
 | isEqPred (ctPred ct) = extendWorkListEq ct wl
 | otherwise = extendWorkListNonEq ct wl

appendWorkListCt :: [Ct] -> WorkList -> WorkList
-- Agnostic
appendWorkListCt cts wl = foldr extendWorkListCt wl cts

appendWorkListEqs :: [Ct] -> WorkList -> WorkList
-- Append a list of equalities
appendWorkListEqs cts wl = foldr extendWorkListEq wl cts

isEmptyWorkList :: WorkList -> Bool
isEmptyWorkList wl 
  = null (wl_eqs wl) &&  null (wl_rest wl) && null (wl_funeqs wl)

emptyWorkList :: WorkList
emptyWorkList = WorkList { wl_eqs  = [], wl_rest = [], wl_funeqs = [] }

workListFromEq :: Ct -> WorkList
workListFromEq ct = extendWorkListEq ct emptyWorkList

workListFromNonEq :: Ct -> WorkList
workListFromNonEq ct = extendWorkListNonEq ct emptyWorkList

workListFromCt :: Ct -> WorkList
-- Agnostic 
workListFromCt ct | isEqPred (ctPred ct) = workListFromEq ct 
                  | otherwise            = workListFromNonEq ct


selectWorkItem :: WorkList -> (Maybe Ct, WorkList)
selectWorkItem wl@(WorkList { wl_eqs = eqs, wl_funeqs = feqs, wl_rest = rest })
  = case (eqs,feqs,rest) of
      (ct:cts,_,_)     -> (Just ct, wl { wl_eqs    = cts })
      (_,(ct:cts),_)   -> (Just ct, wl { wl_funeqs = cts })
      (_,_,(ct:cts))   -> (Just ct, wl { wl_rest   = cts })
      (_,_,_)          -> (Nothing,wl)

-- Pretty printing 
instance Outputable WorkList where 
  ppr wl = vcat [ text "WorkList (eqs)   = " <+> ppr (wl_eqs wl)
                , text "WorkList (funeqs)= " <+> ppr (wl_funeqs wl)
                , text "WorkList (rest)  = " <+> ppr (wl_rest wl)
                ]

keepWanted :: Cts -> Cts
keepWanted = filterBag isWantedCt
    -- DV: there used to be a note here that read: 
    -- ``Important: use fold*r*Bag to preserve the order of the evidence variables'' 
    -- DV: Is this still relevant? 

-- Canonical constraint maps
data CCanMap a = CCanMap { cts_given   :: UniqFM Cts
                                          -- Invariant: all Given
                         , cts_derived :: UniqFM Cts 
                                          -- Invariant: all Derived
                         , cts_wanted  :: UniqFM Cts } 
                                          -- Invariant: all Wanted

cCanMapToBag :: CCanMap a -> Cts 
cCanMapToBag cmap = foldUFM unionBags rest_wder (cts_given cmap)
  where rest_wder = foldUFM unionBags rest_der  (cts_wanted cmap) 
        rest_der  = foldUFM unionBags emptyCts  (cts_derived cmap)

emptyCCanMap :: CCanMap a 
emptyCCanMap = CCanMap { cts_given = emptyUFM, cts_derived = emptyUFM, cts_wanted = emptyUFM } 

updCCanMap:: Uniquable a => (a,Ct) -> CCanMap a -> CCanMap a 
updCCanMap (a,ct) cmap 
  = case cc_flavor ct of 
      Wanted {}  -> cmap { cts_wanted  = insert_into (cts_wanted cmap)  } 
      Given {}   -> cmap { cts_given   = insert_into (cts_given cmap)   }
      Derived {} -> cmap { cts_derived = insert_into (cts_derived cmap) }
      Solved {}  -> panic "updCCanMap update with solved!" 
  where 
    insert_into m = addToUFM_C unionBags m a (singleCt ct)

getRelevantCts :: Uniquable a => a -> CCanMap a -> (Cts, CCanMap a) 
-- Gets the relevant constraints and returns the rest of the CCanMap
getRelevantCts a cmap 
    = let relevant = lookup (cts_wanted cmap) `unionBags`
                     lookup (cts_given cmap)  `unionBags`
                     lookup (cts_derived cmap) 
          residual_map = cmap { cts_wanted  = delFromUFM (cts_wanted cmap) a
                              , cts_given   = delFromUFM (cts_given cmap) a
                              , cts_derived = delFromUFM (cts_derived cmap) a }
      in (relevant, residual_map) 
  where
    lookup map = lookupUFM map a `orElse` emptyCts

lookupCCanMap :: Uniquable a => a -> (Ct -> Bool) -> CCanMap a -> Maybe Ct
lookupCCanMap a p map
   = let possible_cts = lookupUFM (cts_given map)   a `orElse` 
                        lookupUFM (cts_wanted map)  a `orElse` 
                        lookupUFM (cts_derived map) a `orElse` emptyCts
     in find p (bagToList possible_cts)


partitionCCanMap :: (Ct -> Bool) -> CCanMap a -> (Cts,CCanMap a) 
-- All constraints that /match/ the predicate go in the bag, the rest remain in the map
partitionCCanMap pred cmap
  = let (ws_map,ws) = foldUFM_Directly aux (emptyUFM,emptyCts) (cts_wanted cmap) 
        (ds_map,ds) = foldUFM_Directly aux (emptyUFM,emptyCts) (cts_derived cmap)
        (gs_map,gs) = foldUFM_Directly aux (emptyUFM,emptyCts) (cts_given cmap) 
    in (ws `andCts` ds `andCts` gs, cmap { cts_wanted  = ws_map
                                         , cts_given   = gs_map
                                         , cts_derived = ds_map }) 
  where aux k this_cts (mp,acc_cts) = (new_mp, new_acc_cts)
                                    where new_mp      = addToUFM mp k cts_keep
                                          new_acc_cts = acc_cts `andCts` cts_out
                                          (cts_out, cts_keep) = partitionBag pred this_cts

partitionEqMap :: (Ct -> Bool) -> TyVarEnv (Ct,TcCoercion) -> ([Ct], TyVarEnv (Ct,TcCoercion))
partitionEqMap pred isubst 
  = let eqs_out = foldVarEnv extend_if_pred [] isubst
        eqs_in  = filterVarEnv_Directly (\_ (ct,_) -> not (pred ct)) isubst
    in (eqs_out, eqs_in)
  where extend_if_pred (ct,_) cts = if pred ct then ct : cts else cts


extractUnsolvedCMap :: CCanMap a -> (Cts, CCanMap a)
-- Gets the wanted or derived constraints and returns a residual
-- CCanMap with only givens.
extractUnsolvedCMap cmap =
  let wntd = foldUFM unionBags emptyCts (cts_wanted cmap)
      derd = foldUFM unionBags emptyCts (cts_derived cmap)
  in (wntd `unionBags` derd, 
      cmap { cts_wanted = emptyUFM, cts_derived = emptyUFM })


-- Maps from PredTypes to Constraints
type CtTypeMap = TypeMap Ct
newtype CtPredMap = 
  CtPredMap { unCtPredMap :: CtTypeMap }       -- Indexed by TcPredType
newtype CtFamHeadMap = 
  CtFamHeadMap { unCtFamHeadMap :: CtTypeMap } -- Indexed by family head

pprCtTypeMap :: TypeMap Ct -> SDoc 
pprCtTypeMap ctmap = ppr (foldTM (:) ctmap [])

ctTypeMapCts :: TypeMap Ct -> Cts
ctTypeMapCts ctmap = foldTM (\ct cts -> extendCts cts ct) ctmap emptyCts


partCtFamHeadMap :: (Ct -> Bool) 
                 -> CtFamHeadMap 
                 -> (Cts, CtFamHeadMap)
partCtFamHeadMap f ctmap
  = let (cts,tymap_final) = foldTM upd_acc tymap_inside (emptyBag, tymap_inside)
    in (cts, CtFamHeadMap tymap_final)
  where
    tymap_inside = unCtFamHeadMap ctmap 
    upd_acc ct (cts,acc_map)
         | f ct      = (extendCts cts ct, alterTM ct_key (\_ -> Nothing) acc_map)
         | otherwise = (cts,acc_map)
         where ct_key | EqPred ty1 _ <- classifyPredType (ctPred ct)
                      = ty1 
                      | otherwise 
                      = panic "partCtFamHeadMap, encountered non equality!"


\end{code}

%************************************************************************
%*									*
%*                            Inert Sets                                *
%*                                                                      *
%*									*
%************************************************************************

\begin{code}


-- All Given (fully known) or Wanted or Derived, never Solved
-- See Note [Detailed InertCans Invariants] for more
data InertCans 
  = IC { inert_eqs :: TyVarEnv Ct
              -- Must all be CTyEqCans! If an entry exists of the form: 
              --   a |-> ct,co
              -- Then ct = CTyEqCan { cc_tyvar = a, cc_rhs = xi } 
              -- And  co : a ~ xi
       , inert_eq_tvs :: InScopeSet
              -- Superset of the type variables of inert_eqs
       , inert_dicts :: CCanMap Class
              -- Dictionaries only, index is the class
              -- NB: index is /not/ the whole type because FD reactions 
              -- need to match the class but not necessarily the whole type.
       , inert_ips :: CCanMap (IPName Name)
              -- Implicit parameters, index is the name
              -- NB: index is /not/ the whole type because IP reactions need 
              -- to match the ip name but not necessarily the whole type.
       , inert_funeqs :: CtFamHeadMap
              -- Family equations, index is the whole family head type.
       , inert_irreds :: Cts       
              -- Irreducible predicates
       }
    
                     
\end{code}

Note [Detailed InertCans Invariants]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The InertCans represents a collection of constraints with the following properties:
  1 All canonical
  2 All Given or Wanted or Derived. No (partially) Solved
  3 No two dictionaries with the same head
  4 No two family equations with the same head 
      NB: This is enforced by construction since we use a CtFamHeadMap for inert_funeqs
  5 Family equations inert wrt top-level family axioms
  6 Dictionaries have no matching top-level instance 
  
  7 Non-equality constraints are fully rewritten with respect to the equalities (CTyEqCan)

  8 Equalities _do_not_ form an idempotent substitution but they are guarranteed to not have
    any occurs errors. Additional notes: 

       - The lack of idempotence of the inert substitution implies that we must make sure 
         that when we rewrite a constraint we apply the substitution /recursively/ to the 
         types involved. Currently the one AND ONLY way in the whole constraint solver 
         that we rewrite types and constraints wrt to the inert substitution is 
         TcCanonical/flattenTyVar.

       - In the past we did try to have the inert substituion as idempotent as possible but
         this would only be true for constraints of the same flavor, so in total the inert 
         substitution could not be idempotent, due to flavor-related issued. 
         Note [Non-idempotent inert substitution] explains what is going on. 

       - Whenever a constraint ends up in the worklist we do recursively apply exhaustively
         the inert substitution to it to check for occurs errors but if an equality is already
         in the inert set and we can guarantee that adding a new equality will not cause the
         first equality to have an occurs check then we do not rewrite the inert equality. 
         This happens in TcInteract, rewriteInertEqsFromInertEq. 
         
         See Note [Delicate equality kick-out] to see which inert equalities can safely stay
         in the inert set and which must be kicked out to be rewritten and re-checked for 
         occurs errors. 

  9 Given family or dictionary constraints don't mention touchable unification variables
\begin{code}


-- The Inert Set
data InertSet
  = IS { inert_cans :: InertCans
              -- Canonical Given,Wanted,Solved
       , inert_frozen :: Cts       
              -- Frozen errors (as non-canonicals)
                               
       , inert_solved :: CtPredMap
              -- Solved constraints (for caching): 
              -- (i) key is by predicate type
              -- (ii) all of 'Solved' flavor, may or may not be canonicals
              -- (iii) we use this field for avoiding creating newEvVars
       , inert_flat_cache :: CtFamHeadMap 
              -- All ``flattening equations'' are kept here. 
              -- Always canonical CTyFunEqs (Given or Wanted only!)
              -- Key is by family head. We used this field during flattening only
       , inert_solved_funeqs :: CtFamHeadMap
              -- Memoized Solved family equations co :: F xis ~ xi
              -- Stored not necessarily as fully rewritten; we'll do that lazily
              -- when we lookup
       }


instance Outputable InertCans where 
  ppr ics = vcat [ vcat (map ppr (varEnvElts (inert_eqs ics)))
                 , vcat (map ppr (Bag.bagToList $ cCanMapToBag (inert_dicts ics)))
                 , vcat (map ppr (Bag.bagToList $ cCanMapToBag (inert_ips ics))) 
                 , vcat (map ppr (Bag.bagToList $ 
                                  ctTypeMapCts (unCtFamHeadMap $ inert_funeqs ics)))
                 , vcat (map ppr (Bag.bagToList $ inert_irreds ics))
                 ]
            
instance Outputable InertSet where 
  ppr is = vcat [ ppr $ inert_cans is
                , text "Frozen errors =" <+> -- Clearly print frozen errors
                    braces (vcat (map ppr (Bag.bagToList $ inert_frozen is)))
                , text "Solved and cached" <+>
                    int (foldTypeMap (\_ x -> x+1) 0 
                             (unCtPredMap $ inert_solved is)) <+> 
                    text "more constraints" ]

emptyInert :: InertSet
emptyInert
  = IS { inert_cans = IC { inert_eqs    = emptyVarEnv
                         , inert_eq_tvs = emptyInScopeSet
                         , inert_dicts  = emptyCCanMap
                         , inert_ips    = emptyCCanMap
                         , inert_funeqs = CtFamHeadMap emptyTM 
                         , inert_irreds = emptyCts }
       , inert_frozen        = emptyCts
       , inert_flat_cache    = CtFamHeadMap emptyTM
       , inert_solved        = CtPredMap emptyTM 
       , inert_solved_funeqs = CtFamHeadMap emptyTM }

type AtomicInert = Ct 

updInertSet :: InertSet -> AtomicInert -> InertSet 
-- Add a new inert element to the inert set. 
updInertSet is item 
  | isSolved (cc_flavor item)
    -- Solved items go in their special place
  = let pty = ctPred item
        upd_solved Nothing = Just item
        upd_solved (Just _existing_solved) = Just item 
               -- .. or Just existing_solved? Is this even possible to happen?
    in is { inert_solved = 
               CtPredMap $ 
               alterTM pty upd_solved (unCtPredMap $ inert_solved is) }

  | isCNonCanonical item 
    -- NB: this may happen if we decide to kick some frozen error 
    -- out to rewrite him. Frozen errors are just NonCanonicals
  = is { inert_frozen = inert_frozen is `Bag.snocBag` item }
    
  | otherwise  
    -- A canonical Given, Wanted, or Derived
  = is { inert_cans = upd_inert_cans (inert_cans is) item }
  
  where upd_inert_cans :: InertCans -> AtomicInert -> InertCans
        -- Precondition: item /is/ canonical
        upd_inert_cans ics item
          | isCTyEqCan item                     
          = let upd_err a b = pprPanic "updInertSet" $
                              vcat [ text "Multiple inert equalities:"
                                   , text "Old (already inert):" <+> ppr a
                                   , text "Trying to insert   :" <+> ppr b ]
        
                eqs'     = extendVarEnv_C upd_err (inert_eqs ics) 
                                                  (cc_tyvar item) item        
                inscope' = extendInScopeSetSet (inert_eq_tvs ics)
                                               (tyVarsOfCt item)
                
            in ics { inert_eqs = eqs', inert_eq_tvs = inscope' }

          | Just x  <- isCIPCan_Maybe item      -- IP 
          = ics { inert_ips   = updCCanMap (x,item) (inert_ips ics) }  
            
          | isCIrredEvCan item                  -- Presently-irreducible evidence
          = ics { inert_irreds = inert_irreds ics `Bag.snocBag` item }

          | Just cls <- isCDictCan_Maybe item   -- Dictionary 
          = ics { inert_dicts = updCCanMap (cls,item) (inert_dicts ics) }

          | Just _tc <- isCFunEqCan_Maybe item  -- Function equality
          = let fam_head = mkTyConApp (cc_fun item) (cc_tyargs item)
                upd_funeqs Nothing = Just item
                upd_funeqs (Just _already_there) 
                  = panic "updInertSet: item already there!"
            in ics { inert_funeqs = CtFamHeadMap 
                                      (alterTM fam_head upd_funeqs $ 
                                         (unCtFamHeadMap $ inert_funeqs ics)) }
          | otherwise
          = pprPanic "upd_inert set: can't happen! Inserting " $ 
            ppr item 

updInertSetTcS :: AtomicInert -> TcS ()
-- Add a new item in the inerts of the monad
updInertSetTcS item
  = do { traceTcS "updInertSetTcs {" $ 
         text "Trying to insert new inert item:" <+> ppr item

       ; modifyInertTcS (\is -> ((), updInertSet is item)) 
                        
       ; traceTcS "updInertSetTcs }" $ empty }


modifyInertTcS :: (InertSet -> (a,InertSet)) -> TcS a 
-- Modify the inert set with the supplied function
modifyInertTcS upd 
  = do { is_var <- getTcSInertsRef
       ; curr_inert <- wrapTcS (TcM.readTcRef is_var)
       ; let (a, new_inert) = upd curr_inert
       ; wrapTcS (TcM.writeTcRef is_var new_inert)
       ; return a }


addToSolved :: Ct -> TcS ()
-- Don't do any caching for IP preds because of delicate shadowing
addToSolved ct
  | isIPPred (ctPred ct)  
  = return () 
  | otherwise
  = ASSERT ( isSolved (cc_flavor ct) )
    updInertSetTcS ct

extractUnsolvedTcS :: TcS (Cts,Cts) 
-- Extracts frozen errors and remaining unsolved and sets the 
-- inert set to be the remaining! 
extractUnsolvedTcS = 
  modifyInertTcS extractUnsolved 

extractUnsolved :: InertSet -> ((Cts,Cts), InertSet)
-- Postcondition
-- -------------
-- When: 
--   ((frozen,cts),is_solved) <- extractUnsolved inert
-- Then: 
-- -----------------------------------------------------------------------------
--  cts       |  The unsolved (Derived or Wanted only) residual 
--            |  canonical constraints, that is, no CNonCanonicals.
-- -----------|-----------------------------------------------------------------
--  frozen    | The CNonCanonicals of the original inert (frozen errors), 
--            | of all flavors
-- -----------|-----------------------------------------------------------------
--  is_solved | Whatever remains from the inert after removing the previous two. 
-- -----------------------------------------------------------------------------
extractUnsolved (IS { inert_cans = IC { inert_eqs    = eqs
                                      , inert_eq_tvs = eq_tvs
                                      , inert_irreds = irreds
                                      , inert_ips    = ips
                                      , inert_funeqs = funeqs
                                      , inert_dicts  = dicts
                                      }
                    , inert_frozen = frozen
                    , inert_solved = solved
                    , inert_flat_cache = flat_cache 
                    , inert_solved_funeqs = funeq_cache
                    })
  
  = let is_solved  = IS { inert_cans = IC { inert_eqs    = solved_eqs
                                          , inert_eq_tvs = eq_tvs
                                          , inert_dicts  = solved_dicts
                                          , inert_ips    = solved_ips
                                          , inert_irreds = solved_irreds
                                          , inert_funeqs = solved_funeqs }
                        , inert_frozen = emptyCts -- All out
                                         
                              -- At some point, I used to flush all the solved, in 
                              -- fear of evidence loops. But I think we are safe, 
                              -- flushing is why T3064 had become slower
                        , inert_solved        = solved      -- CtPredMap emptyTM
                        , inert_flat_cache    = flat_cache  -- CtFamHeadMap emptyTM
                        , inert_solved_funeqs = funeq_cache -- CtFamHeadMap emptyTM
                        }
    in ((frozen, unsolved), is_solved)

  where solved_eqs = filterVarEnv_Directly (\_ ct -> isGivenOrSolvedCt ct) eqs
        unsolved_eqs = foldVarEnv (\ct cts -> cts `extendCts` ct) emptyCts $
                       eqs `minusVarEnv` solved_eqs

        (unsolved_irreds, solved_irreds) = Bag.partitionBag (not.isGivenOrSolvedCt) irreds
        (unsolved_ips, solved_ips)       = extractUnsolvedCMap ips
        (unsolved_dicts, solved_dicts)   = extractUnsolvedCMap dicts

        (unsolved_funeqs, solved_funeqs) = 
          partCtFamHeadMap (not . isGivenOrSolved . cc_flavor) funeqs

        unsolved = unsolved_eqs `unionBags` unsolved_irreds `unionBags`
                   unsolved_ips `unionBags` unsolved_dicts `unionBags` unsolved_funeqs



extractRelevantInerts :: Ct -> TcS Cts
-- Returns the constraints from the inert set that are 'relevant' to react with 
-- this constraint. The monad is left with the 'thinner' inerts. 
-- NB: This function contains logic specific to the constraint solver, maybe move there?
extractRelevantInerts wi 
  = modifyInertTcS (extract_relevants wi)
  where extract_relevants wi is 
          = let (cts,ics') = extract_ics_relevants wi (inert_cans is)
            in (cts, is { inert_cans = ics' }) 
            
        extract_ics_relevants (CDictCan {cc_class = cl}) ics = 
            let (cts,dict_map) = getRelevantCts cl (inert_dicts ics) 
            in (cts, ics { inert_dicts = dict_map })
        extract_ics_relevants ct@(CFunEqCan {}) ics = 
            let (cts,feqs_map)  = 
                  let funeq_map = unCtFamHeadMap $ inert_funeqs ics
                      fam_head = mkTyConApp (cc_fun ct) (cc_tyargs ct)
                      lkp = lookupTM fam_head funeq_map
                      new_funeq_map = alterTM fam_head xtm funeq_map
                      xtm Nothing    = Nothing
                      xtm (Just _ct) = Nothing
                  in case lkp of 
                    Nothing -> (emptyCts, funeq_map)
                    Just ct -> (singleCt ct, new_funeq_map)
            in (cts, ics { inert_funeqs = CtFamHeadMap feqs_map })
        extract_ics_relevants (CIPCan { cc_ip_nm = nm } ) ics = 
            let (cts, ips_map) = getRelevantCts nm (inert_ips ics) 
            in (cts, ics { inert_ips = ips_map })
        extract_ics_relevants (CIrredEvCan { }) ics = 
            let cts = inert_irreds ics 
            in (cts, ics { inert_irreds = emptyCts })
        extract_ics_relevants _ ics = (emptyCts,ics)
        

lookupInInerts :: InertSet -> TcPredType -> Maybe Ct
-- Is this exact predicate type cached in the solved or canonicals of the InertSet
lookupInInerts (IS { inert_solved = solved, inert_cans = ics }) pty
  = case lookupInSolved solved pty of
      Just ct -> return ct
      Nothing -> lookupInInertCans ics pty

lookupInSolved :: CtPredMap -> TcPredType -> Maybe Ct
-- Returns just if exactly this predicate type exists in the solved.
lookupInSolved tm pty = lookupTM pty $ unCtPredMap tm

lookupInInertCans :: InertCans -> TcPredType -> Maybe Ct
-- Returns Just if exactly this pred type exists in the inert canonicals
lookupInInertCans ics pty
  = lkp_ics (classifyPredType pty)
  where lkp_ics (ClassPred cls _)
          = lookupCCanMap cls (\ct -> ctPred ct `eqType` pty) (inert_dicts ics)
        lkp_ics (EqPred ty1 _ty2)
          | Just tv <- getTyVar_maybe ty1
          , Just ct <- lookupVarEnv (inert_eqs ics) tv
          , ctPred ct `eqType` pty
          = Just ct
        lkp_ics (EqPred ty1 _ty2) -- Family equation
          | Just _ <- splitTyConApp_maybe ty1
          , Just ct <- lookupTM ty1 (unCtFamHeadMap $ inert_funeqs ics)
          , ctPred ct `eqType` pty
          = Just ct
        lkp_ics (IrredPred {}) 
          = find (\ct -> ctPred ct `eqType` pty) (bagToList (inert_irreds ics))
        lkp_ics _ = Nothing -- NB: No caching for IPs
\end{code}




%************************************************************************
%*									*
%*		The TcS solver monad                                    *
%*									*
%************************************************************************

Note [The TcS monad]
~~~~~~~~~~~~~~~~~~~~
The TcS monad is a weak form of the main Tc monad

All you can do is
    * fail
    * allocate new variables
    * fill in evidence variables

Filling in a dictionary evidence variable means to create a binding
for it, so TcS carries a mutable location where the binding can be
added.  This is initialised from the innermost implication constraint.

\begin{code}
data TcSEnv
  = TcSEnv { 
      tcs_ev_binds    :: EvBindsVar,
      
      tcs_ty_binds :: IORef (TyVarEnv (TcTyVar, TcType)),
          -- Global type bindings

      tcs_context :: SimplContext,
                     
      tcs_untch :: TcsUntouchables,

      tcs_ic_depth   :: Int,       -- Implication nesting depth
      tcs_count      :: IORef Int, -- Global step count

      tcs_inerts   :: IORef InertSet, -- Current inert set
      tcs_worklist :: IORef WorkList  -- Current worklist

    }

type TcsUntouchables = (Untouchables,TcTyVarSet)
-- Like the TcM Untouchables, 
-- but records extra TcsTv variables generated during simplification
-- See Note [Extra TcsTv untouchables] in TcSimplify
\end{code}

\begin{code}
data SimplContext
  = SimplInfer SDoc	   -- Inferring type of a let-bound thing
  | SimplRuleLhs RuleName  -- Inferring type of a RULE lhs
  | SimplInteractive	   -- Inferring type at GHCi prompt
  | SimplCheck SDoc	   -- Checking a type signature or RULE rhs

instance Outputable SimplContext where
  ppr (SimplInfer d)   = ptext (sLit "SimplInfer") <+> d
  ppr (SimplCheck d)   = ptext (sLit "SimplCheck") <+> d
  ppr (SimplRuleLhs n) = ptext (sLit "SimplRuleLhs") <+> doubleQuotes (ftext n)
  ppr SimplInteractive = ptext (sLit "SimplInteractive")

isInteractive :: SimplContext -> Bool
isInteractive SimplInteractive = True
isInteractive _                = False

simplEqsOnly :: SimplContext -> Bool
-- Simplify equalities only, not dictionaries
-- This is used for the LHS of rules; ee
-- Note [Simplifying RULE lhs constraints] in TcSimplify
simplEqsOnly (SimplRuleLhs {}) = True
simplEqsOnly _                 = False

performDefaulting :: SimplContext -> Bool
performDefaulting (SimplInfer {})   = False
performDefaulting (SimplRuleLhs {}) = False
performDefaulting SimplInteractive  = True
performDefaulting (SimplCheck {})   = True

---------------
newtype TcS a = TcS { unTcS :: TcSEnv -> TcM a } 

instance Functor TcS where
  fmap f m = TcS $ fmap f . unTcS m

instance Monad TcS where 
  return x  = TcS (\_ -> return x) 
  fail err  = TcS (\_ -> fail err) 
  m >>= k   = TcS (\ebs -> unTcS m ebs >>= \r -> unTcS (k r) ebs)

-- Basic functionality 
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
wrapTcS :: TcM a -> TcS a 
-- Do not export wrapTcS, because it promotes an arbitrary TcM to TcS,
-- and TcS is supposed to have limited functionality
wrapTcS = TcS . const -- a TcM action will not use the TcEvBinds

wrapErrTcS :: TcM a -> TcS a 
-- The thing wrapped should just fail
-- There's no static check; it's up to the user
-- Having a variant for each error message is too painful
wrapErrTcS = wrapTcS

wrapWarnTcS :: TcM a -> TcS a 
-- The thing wrapped should just add a warning, or no-op
-- There's no static check; it's up to the user
wrapWarnTcS = wrapTcS

failTcS, panicTcS :: SDoc -> TcS a
failTcS      = wrapTcS . TcM.failWith
panicTcS doc = pprPanic "TcCanonical" doc

traceTcS :: String -> SDoc -> TcS ()
traceTcS herald doc = wrapTcS (TcM.traceTc herald doc)

bumpStepCountTcS :: TcS ()
bumpStepCountTcS = TcS $ \env -> do { let ref = tcs_count env
                                    ; n <- TcM.readTcRef ref
                                    ; TcM.writeTcRef ref (n+1) }

traceFireTcS :: SubGoalDepth -> SDoc -> TcS ()
-- Dump a rule-firing trace
traceFireTcS depth doc 
  = TcS $ \env -> 
    TcM.ifDOptM Opt_D_dump_cs_trace $ 
    do { n <- TcM.readTcRef (tcs_count env)
       ; let msg = int n 
                <> text (replicate (tcs_ic_depth env) '>')
                <> brackets (int depth) <+> doc
       ; TcM.dumpTcRn msg }

runTcS :: SimplContext
       -> Untouchables 	       -- Untouchables
       -> InertSet             -- Initial inert set
       -> WorkList             -- Initial work list
       -> TcS a		       -- What to run
       -> TcM (a, Bag EvBind)
runTcS context untouch is wl tcs 
  = do { ty_binds_var <- TcM.newTcRef emptyVarEnv
       ; ev_binds_var <- TcM.newTcEvBinds
       ; step_count <- TcM.newTcRef 0

       ; inert_var <- TcM.newTcRef is 
       ; wl_var <- TcM.newTcRef wl

       ; let env = TcSEnv { tcs_ev_binds = ev_binds_var
                          , tcs_ty_binds = ty_binds_var
                          , tcs_context  = context
                          , tcs_untch    = (untouch, emptyVarSet) -- No Tcs untouchables yet
			  , tcs_count    = step_count
			  , tcs_ic_depth = 0
                          , tcs_inerts   = inert_var
                          , tcs_worklist = wl_var }

	     -- Run the computation
       ; res <- unTcS tcs env
	     -- Perform the type unifications required
       ; ty_binds <- TcM.readTcRef ty_binds_var
       ; mapM_ do_unification (varEnvElts ty_binds)

       ; when debugIsOn $ do {
             count <- TcM.readTcRef step_count
           ; when (opt_PprStyle_Debug && count > 0) $
             TcM.debugDumpTcRn (ptext (sLit "Constraint solver steps =") 
                                <+> int count <+> ppr context)
         }
             -- And return
       ; ev_binds <- TcM.getTcEvBinds ev_binds_var
       ; return (res, ev_binds) }
  where
    do_unification (tv,ty) = TcM.writeMetaTyVar tv ty


doWithInert :: InertSet -> TcS a -> TcS a 
doWithInert inert (TcS action)
  = TcS $ \env -> do { new_inert_var <- TcM.newTcRef inert
                     ; action (env { tcs_inerts = new_inert_var }) }

nestImplicTcS :: EvBindsVar -> TcsUntouchables -> TcS a -> TcS a 
nestImplicTcS ref (inner_range, inner_tcs) (TcS thing_inside) 
  = TcS $ \ TcSEnv { tcs_ty_binds = ty_binds
                   , tcs_untch = (_outer_range, outer_tcs)
                   , tcs_count = count
                   , tcs_ic_depth = idepth
                   , tcs_context = ctxt
                   , tcs_inerts = inert_var
                   , tcs_worklist = wl_var } -> 
    do { let inner_untch = (inner_range, outer_tcs `unionVarSet` inner_tcs)
       		   -- The inner_range should be narrower than the outer one
		   -- (thus increasing the set of untouchables) but 
		   -- the inner Tcs-untouchables must be unioned with the
		   -- outer ones!

         -- Inherit the inerts from the outer scope
       ; orig_inerts <- TcM.readTcRef inert_var
       ; new_inert_var <- TcM.newTcRef orig_inerts
                           
       ; let nest_env = TcSEnv { tcs_ev_binds    = ref
                               , tcs_ty_binds    = ty_binds
                               , tcs_untch       = inner_untch
                               , tcs_count       = count
                               , tcs_ic_depth    = idepth+1
                               , tcs_context     = ctxtUnderImplic ctxt 
                               , tcs_inerts      = new_inert_var
                               , tcs_worklist    = wl_var 
                               -- NB: worklist is going to be empty anyway, 
                               -- so reuse the same ref cell
                               }
       ; thing_inside nest_env } 

recoverTcS :: TcS a -> TcS a -> TcS a
recoverTcS (TcS recovery_code) (TcS thing_inside)
  = TcS $ \ env ->
    TcM.recoverM (recovery_code env) (thing_inside env)

ctxtUnderImplic :: SimplContext -> SimplContext
-- See Note [Simplifying RULE lhs constraints] in TcSimplify
ctxtUnderImplic (SimplRuleLhs n) = SimplCheck (ptext (sLit "lhs of rule") 
                                               <+> doubleQuotes (ftext n))
ctxtUnderImplic ctxt              = ctxt

tryTcS :: TcS a -> TcS a
-- Like runTcS, but from within the TcS monad 
-- Completely afresh inerts and worklist, be careful! 
-- Moreover, we will simply throw away all the evidence generated. 
tryTcS tcs
  = TcS (\env -> 
             do { wl_var <- TcM.newTcRef emptyWorkList
                ; is_var <- TcM.newTcRef emptyInert

                ; ty_binds_var <- TcM.newTcRef emptyVarEnv
                ; ev_binds_var <- TcM.newTcEvBinds

                ; let env1 = env { tcs_ev_binds = ev_binds_var
                                 , tcs_ty_binds = ty_binds_var
                                 , tcs_inerts   = is_var
                                 , tcs_worklist = wl_var } 
                ; unTcS tcs env1 })

-- Getters and setters of TcEnv fields
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Getter of inerts and worklist
getTcSInertsRef :: TcS (IORef InertSet)
getTcSInertsRef = TcS (return . tcs_inerts)

getTcSWorkListRef :: TcS (IORef WorkList) 
getTcSWorkListRef = TcS (return . tcs_worklist) 

getTcSInerts :: TcS InertSet 
getTcSInerts = getTcSInertsRef >>= wrapTcS . (TcM.readTcRef) 

getTcSWorkList :: TcS WorkList
getTcSWorkList = getTcSWorkListRef >>= wrapTcS . (TcM.readTcRef) 


getTcSWorkListTvs :: TcS TyVarSet
-- Return the variables of the worklist
getTcSWorkListTvs 
  = do { wl <- getTcSWorkList
       ; return $
         cts_tvs (wl_eqs wl) `unionVarSet` cts_tvs (wl_funeqs wl) `unionVarSet` cts_tvs (wl_rest wl) }
  where cts_tvs = foldr (unionVarSet . tyVarsOfCt) emptyVarSet 


updWorkListTcS :: (WorkList -> WorkList) -> TcS () 
updWorkListTcS f 
  = updWorkListTcS_return (\w -> ((),f w))

updWorkListTcS_return :: (WorkList -> (a,WorkList)) -> TcS a
updWorkListTcS_return f
  = do { wl_var <- getTcSWorkListRef
       ; wl_curr <- wrapTcS (TcM.readTcRef wl_var)
       ; let (res,new_work) = f wl_curr
       ; wrapTcS (TcM.writeTcRef wl_var new_work)
       ; return res }

emitFrozenError :: CtFlavor -> SubGoalDepth -> TcS ()
-- Emits a non-canonical constraint that will stand for a frozen error in the inerts. 
emitFrozenError fl depth 
  = do { traceTcS "Emit frozen error" (ppr (ctFlavPred fl))
       ; inert_ref <- getTcSInertsRef 
       ; inerts <- wrapTcS (TcM.readTcRef inert_ref)
       ; let ct = CNonCanonical { cc_flavor = fl
                                , cc_depth = depth } 
             inerts_new = inerts { inert_frozen = extendCts (inert_frozen inerts) ct } 
       ; wrapTcS (TcM.writeTcRef inert_ref inerts_new) }

instance HasDynFlags TcS where
    getDynFlags = wrapTcS getDynFlags

getTcSContext :: TcS SimplContext
getTcSContext = TcS (return . tcs_context)

getTcEvBinds :: TcS EvBindsVar
getTcEvBinds = TcS (return . tcs_ev_binds) 

getFlatCache :: TcS CtTypeMap 
getFlatCache = getTcSInerts >>= (return . unCtFamHeadMap . inert_flat_cache)

updFlatCache :: Ct -> TcS ()
-- Pre: constraint is a flat family equation (equal to a flatten skolem)
updFlatCache flat_eq@(CFunEqCan { cc_flavor = fl, cc_fun = tc, cc_tyargs = xis })
  = modifyInertTcS upd_inert_cache
  where upd_inert_cache is = ((), is { inert_flat_cache = CtFamHeadMap new_fc })
                           where new_fc = alterTM pred_key upd_cache fc
                                 fc = unCtFamHeadMap $ inert_flat_cache is
        pred_key = mkTyConApp tc xis
        upd_cache (Just ct) | cc_flavor ct `canSolve` fl = Just ct 
        upd_cache (Just _ct) = Just flat_eq 
        upd_cache Nothing    = Just flat_eq
updFlatCache other_ct = pprPanic "updFlatCache: non-family constraint" $
                        ppr other_ct
                        


getUntouchables :: TcS TcsUntouchables
getUntouchables = TcS (return . tcs_untch)

getTcSTyBinds :: TcS (IORef (TyVarEnv (TcTyVar, TcType)))
getTcSTyBinds = TcS (return . tcs_ty_binds)

getTcSTyBindsMap :: TcS (TyVarEnv (TcTyVar, TcType))
getTcSTyBindsMap = getTcSTyBinds >>= wrapTcS . (TcM.readTcRef) 

getTcEvBindsMap :: TcS EvBindMap
getTcEvBindsMap
  = do { EvBindsVar ev_ref _ <- getTcEvBinds 
       ; wrapTcS $ TcM.readTcRef ev_ref }

setWantedTyBind :: TcTyVar -> TcType -> TcS () 
-- Add a type binding
-- We never do this twice!
setWantedTyBind tv ty 
  = do { ref <- getTcSTyBinds
       ; wrapTcS $ 
         do { ty_binds <- TcM.readTcRef ref
            ; when debugIsOn $
                  TcM.checkErr (not (tv `elemVarEnv` ty_binds)) $
                  vcat [ text "TERRIBLE ERROR: double set of meta type variable"
                       , ppr tv <+> text ":=" <+> ppr ty
                       , text "Old value =" <+> ppr (lookupVarEnv_NF ty_binds tv)]
            ; TcM.writeTcRef ref (extendVarEnv ty_binds tv (tv,ty)) } }


\end{code}
Note [Optimizing Spontaneously Solved Coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ 

Spontaneously solved coercions such as alpha := tau used to be bound as everything else
in the evidence binds. Subsequently they were used for rewriting other wanted or solved
goals. For instance: 

WorkItem = [S] g1 : a ~ tau
Inerts   = [S] g2 : b ~ [a]
           [S] g3 : c ~ [(a,a)]

Would result, eventually, after the workitem rewrites the inerts, in the
following evidence bindings:

        g1 = ReflCo tau
        g2 = ReflCo [a]
        g3 = ReflCo [(a,a)]
        g2' = g2 ; [g1] 
        g3' = g3 ; [(g1,g1)]

This ia annoying because it puts way too much stress to the zonker and
desugarer, since we /know/ at the generation time (spontaneously
solving) that the evidence for a particular evidence variable is the
identity.

For this reason, our solution is to cache inside the GivenSolved
flavor of a constraint the term which is actually solving this
constraint. Whenever we perform a setEvBind, a new flavor is returned
so that if it was a GivenSolved to start with, it remains a
GivenSolved with a new evidence term inside. Then, when we use solved
goals to rewrite other constraints we simply use whatever is in the
GivenSolved flavor and not the constraint cc_id.

In our particular case we'd get the following evidence bindings, eventually: 

       g1 = ReflCo tau
       g2 = ReflCo [a]
       g3 = ReflCo [(a,a)]
       g2'= ReflCo [a]
       g3'= ReflCo [(a,a)]

Since we use smart constructors to get rid of g;ReflCo t ~~> g etc.

\begin{code}


warnTcS :: CtLoc orig -> Bool -> SDoc -> TcS ()
warnTcS loc warn_if doc 
  | warn_if   = wrapTcS $ TcM.setCtLoc loc $ TcM.addWarnTc doc
  | otherwise = return ()

getDefaultInfo ::  TcS (SimplContext, [Type], (Bool, Bool))
getDefaultInfo 
  = do { ctxt <- getTcSContext
       ; (tys, flags) <- wrapTcS TcM.tcGetDefaultTys
       ; return (ctxt, tys, flags) }

-- Just get some environments needed for instance looking up and matching
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

getInstEnvs :: TcS (InstEnv, InstEnv) 
getInstEnvs = wrapTcS $ Inst.tcGetInstEnvs 

getFamInstEnvs :: TcS (FamInstEnv, FamInstEnv) 
getFamInstEnvs = wrapTcS $ FamInst.tcGetFamInstEnvs

getTopEnv :: TcS HscEnv 
getTopEnv = wrapTcS $ TcM.getTopEnv 

getGblEnv :: TcS TcGblEnv 
getGblEnv = wrapTcS $ TcM.getGblEnv 

-- Various smaller utilities [TODO, maybe will be absorbed in the instance matcher]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

checkWellStagedDFun :: PredType -> DFunId -> WantedLoc -> TcS () 
checkWellStagedDFun pred dfun_id loc 
  = wrapTcS $ TcM.setCtLoc loc $ 
    do { use_stage <- TcM.getStage
       ; TcM.checkWellStaged pp_thing bind_lvl (thLevel use_stage) }
  where
    pp_thing = ptext (sLit "instance for") <+> quotes (ppr pred)
    bind_lvl = TcM.topIdLvl dfun_id

pprEq :: TcType -> TcType -> SDoc
pprEq ty1 ty2 = pprType $ mkEqPred ty1 ty2

isTouchableMetaTyVar :: TcTyVar -> TcS Bool
isTouchableMetaTyVar tv 
  = do { untch <- getUntouchables
       ; return $ isTouchableMetaTyVar_InRange untch tv } 

isTouchableMetaTyVar_InRange :: TcsUntouchables -> TcTyVar -> Bool 
isTouchableMetaTyVar_InRange (untch,untch_tcs) tv 
  = ASSERT2 ( isTcTyVar tv, ppr tv )
    case tcTyVarDetails tv of 
      MetaTv TcsTv _ -> not (tv `elemVarSet` untch_tcs)
                        -- See Note [Touchable meta type variables] 
      MetaTv {}      -> inTouchableRange untch tv 
      _              -> False 


\end{code}


Note [Touchable meta type variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Meta type variables allocated *by the constraint solver itself* are always
touchable.  Example: 
   instance C a b => D [a] where...
if we use this instance declaration we "make up" a fresh meta type
variable for 'b', which we must later guess.  (Perhaps C has a
functional dependency.)  But since we aren't in the constraint *generator*
we can't allocate a Unique in the touchable range for this implication
constraint.  Instead, we mark it as a "TcsTv", which makes it always-touchable.


\begin{code}
-- Flatten skolems
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

newFlattenSkolemTy :: TcType -> TcS TcType
newFlattenSkolemTy ty = mkTyVarTy <$> newFlattenSkolemTyVar ty

newFlattenSkolemTyVar :: TcType -> TcS TcTyVar
newFlattenSkolemTyVar ty
  = do { tv <- wrapTcS $ 
               do { uniq <- TcM.newUnique
                  ; let name = TcM.mkTcTyVarName uniq (fsLit "f")
                  ; return $ mkTcTyVar name (typeKind ty) (FlatSkol ty) } 
       ; traceTcS "New Flatten Skolem Born" $
         ppr tv <+> text "[:= " <+> ppr ty <+> text "]"
       ; return tv }

-- Instantiations 
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

instDFunTypes :: [Either TyVar TcType] -> TcS [TcType] 
instDFunTypes mb_inst_tys 
  = mapM inst_tv mb_inst_tys
  where
    inst_tv :: Either TyVar TcType -> TcS Type
    inst_tv (Left tv)  = mkTyVarTy <$> instFlexiTcS tv
    inst_tv (Right ty) = return ty 

instFlexiTcS :: TyVar -> TcS TcTyVar 
-- Like TcM.instMetaTyVar but the variable that is created is 
-- always touchable; we are supposed to guess its instantiation.
-- See Note [Touchable meta type variables] 
instFlexiTcS tv = instFlexiTcSHelper (tyVarName tv) (tyVarKind tv) 

newFlexiTcSTy :: Kind -> TcS TcType  
newFlexiTcSTy knd 
  = wrapTcS $
    do { uniq <- TcM.newUnique 
       ; ref  <- TcM.newMutVar  Flexi 
       ; let name = TcM.mkTcTyVarName uniq (fsLit "uf")
       ; return $ mkTyVarTy (mkTcTyVar name knd (MetaTv TcsTv ref)) }

isFlexiTcsTv :: TyVar -> Bool
isFlexiTcsTv tv
  | not (isTcTyVar tv)                  = False
  | MetaTv TcsTv _ <- tcTyVarDetails tv = True
  | otherwise                           = False

instFlexiTcSHelper :: Name -> Kind -> TcS TcTyVar
instFlexiTcSHelper tvname tvkind
  = wrapTcS $ 
    do { uniq <- TcM.newUnique 
       ; ref  <- TcM.newMutVar  Flexi 
       ; let name = setNameUnique tvname uniq 
             kind = tvkind 
       ; return (mkTcTyVar name kind (MetaTv TcsTv ref)) }


-- Creating and setting evidence variables and CtFlavors
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

data XEvTerm = 
  XEvTerm { ev_comp   :: [EvVar] -> EvTerm
                         -- How to compose evidence 
          , ev_decomp :: EvVar -> [EvTerm]
                         -- How to decompose evidence 
          }

data MaybeNew a = Fresh  { mn_thing :: a } 
                | Cached { mn_thing :: a }

isFresh :: MaybeNew a -> Bool
isFresh (Fresh {}) = True
isFresh _ = False

setEvBind :: EvVar -> EvTerm -> TcS ()
setEvBind ev t
  = do { tc_evbinds <- getTcEvBinds
       ; wrapTcS $ TcM.addTcEvBind tc_evbinds ev t

       ; traceTcS "setEvBind" $ vcat [ text "ev =" <+> ppr ev
                                     , text "t  =" <+> ppr t ]

#ifndef DEBUG
       ; return () }
#else
       ; binds <- getTcEvBindsMap
       ; let cycle = any (reaches binds) (evVarsOfTerm t)
       ; when cycle (fail_if_co_loop binds) }

  where fail_if_co_loop binds
          = do { traceTcS "Cycle in evidence binds" $ vcat [ text "evvar =" <+> ppr ev
                                                           , ppr (evBindMapBinds binds) ]
               ; when (isEqVar ev) (pprPanic "setEvBind" (text "BUG: Coercion loop!")) }

        reaches :: EvBindMap -> Var -> Bool 
        -- Does this evvar reach ev? 
        reaches ebm ev0 = go ev0
          where go ev0
                  | ev0 == ev = True
                  | Just (EvBind _ evtrm) <- lookupEvBind ebm ev0
                  = any go (evVarsOfTerm evtrm)
                  | otherwise = False
#endif

newGivenEvVar  :: TcPredType -> EvTerm -> TcS (MaybeNew EvVar)
newGivenEvVar pty evterm
  = do { is <- getTcSInerts
       ; case lookupInInerts is pty of
            Just ct | isGivenOrSolvedCt ct 
                    -> return (Cached (ctId ct))
            _ -> do { new_ev <- wrapTcS $ TcM.newEvVar pty
                    ; setEvBind new_ev evterm
                    ; return (Fresh new_ev) } }

newWantedEvVar :: TcPredType -> TcS (MaybeNew EvVar)
newWantedEvVar pty
  = do { is <- getTcSInerts
       ; case lookupInInerts is pty of
            Just ct | not (isDerivedCt ct) 
                    -> do { traceTcS "newWantedEvVar/cache hit" $ ppr ct
                          ; return (Cached (ctId ct)) }
            _ -> do { new_ev <- wrapTcS $ TcM.newEvVar pty
                    ; traceTcS "newWantedEvVar/cache miss" $ ppr new_ev
                    ; return (Fresh new_ev) } }

newDerived :: TcPredType -> TcS (MaybeNew TcPredType)
newDerived pty
  = do { is <- getTcSInerts
       ; case lookupInInerts is pty of
            Just {} -> return (Cached pty)
            _       -> return (Fresh pty) }
    
newKindConstraint :: TcTyVar -> Kind -> TcS (MaybeNew EvVar)
-- Create new wanted CoVar that constrains the type to have the specified kind. 
newKindConstraint tv knd
  = do { tv_k <- instFlexiTcSHelper (tyVarName tv) knd 
       ; let ty_k = mkTyVarTy tv_k
       ; newWantedEvVar (mkTcEqPred (mkTyVarTy tv) ty_k) }

instDFunConstraints :: TcThetaType -> TcS [MaybeNew EvVar]
instDFunConstraints = mapM newWantedEvVar

                
xCtFlavor :: CtFlavor              -- Original flavor   
          -> [TcPredType]          -- New predicate types
          -> XEvTerm               -- Instructions about how to manipulate evidence
          -> ([CtFlavor] -> TcS a) -- What to do with any remaining /fresh/ goals!
          -> TcS a
xCtFlavor = xCtFlavor_cache True          


xCtFlavor_cache :: Bool            -- True = if wanted add to the solved bag!    
          -> CtFlavor              -- Original flavor   
          -> [TcPredType]          -- New predicate types
          -> XEvTerm               -- Instructions about how to manipulate evidence
          -> ([CtFlavor] -> TcS a) -- What to do with any remaining /fresh/ goals!
          -> TcS a
xCtFlavor_cache _ (Given { flav_gloc = gl, flav_evar = evar }) ptys xev cont_with
  = do { let ev_trms = ev_decomp xev evar
       ; new_evars <- zipWithM newGivenEvVar ptys ev_trms
       ; cont_with $
         map (\x -> Given gl (mn_thing x)) (filter isFresh new_evars) }
  
xCtFlavor_cache cache (Wanted { flav_wloc = wl, flav_evar = evar }) ptys xev cont_with
  = do { new_evars <- mapM newWantedEvVar ptys
       ; let evars  = map mn_thing new_evars
             evterm = ev_comp xev evars
       ; setEvBind evar evterm
       ; let solved_flav = Solved { flav_gloc = mkSolvedLoc wl UnkSkol
                                  , flav_evar = evar }
       ; when cache $ addToSolved (mkNonCanonical solved_flav)
       ; cont_with $
         map (\x -> Wanted wl (mn_thing x)) (filter isFresh new_evars) }
    
xCtFlavor_cache _ (Derived { flav_wloc = wl }) ptys _xev cont_with
  = do { ders <- mapM newDerived ptys
       ; cont_with $ 
         map (\x -> Derived wl (mn_thing x)) (filter isFresh ders) }
    
    -- I am not sure I actually want to do this (e.g. from recanonicalizing a solved?)
    -- but if we plan to use xCtFlavor for rewriting as well then I might as well add a case
xCtFlavor_cache _ (Solved { flav_gloc = gl, flav_evar = evar }) ptys xev cont_with
  = do { let ev_trms = ev_decomp xev evar
       ; new_evars <- zipWithM newGivenEvVar ptys ev_trms
       ; cont_with $
         map (\x -> Solved gl (mn_thing x)) (filter isFresh new_evars) }

rewriteCtFlavor :: CtFlavor
                -> TcPredType   -- new predicate
                -> TcCoercion   -- new ~ old     
                -> TcS (Maybe CtFlavor)
rewriteCtFlavor = rewriteCtFlavor_cache True
-- Returns Nothing only if rewriting has happened and the rewritten constraint is cached
-- Returns Just if either (i) we rewrite by reflexivity or 
--                        (ii) we rewrite and original not cached

rewriteCtFlavor_cache :: Bool 
                -> CtFlavor
                -> TcPredType   -- new predicate
                -> TcCoercion   -- new ~ old     
                -> TcS (Maybe CtFlavor)
-- If derived, don't even look at the coercion
-- NB: this allows us to sneak away with ``error'' thunks for 
-- coercions that come from derived ids (which don't exist!) 
rewriteCtFlavor_cache _cache (Derived wl _pty_orig) pty_new _co
  = newDerived pty_new >>= from_mn
  where from_mn (Cached {}) = return Nothing
        from_mn (Fresh {})  = return $ Just (Derived wl pty_new)
        
rewriteCtFlavor_cache cache fl pty co
  | isTcReflCo co
  -- If just reflexivity then you may re-use the same variable as optimization
  = if ctFlavPred fl `eqType` pty then 
      -- E.g. for type synonyms we want to use the original type 
      -- since it's not flattened to report better error messages.
      return $ Just fl
    else 
      -- E.g. because we rewrite with a spontaneously solved one
      return (Just $ case fl of
                 Derived wl _pty_orig -> Derived wl pty
                 Given gl ev  -> Given  gl (setVarType ev pty)
                 Wanted wl ev -> Wanted wl (setVarType ev pty)
                 Solved gl ev -> Solved gl (setVarType ev pty))
  | otherwise 
  = xCtFlavor_cache cache fl [pty] (XEvTerm ev_comp ev_decomp) cont
  where ev_comp [x] = mkEvCast x co
        ev_comp _   = panic "Coercion can only have one subgoal"
        ev_decomp x = [mkEvCast x (mkTcSymCo co)]
        cont []     = return Nothing
        cont [fl]   = return $ Just fl
        cont _      = panic "At most one constraint can be subgoal of coercion!"


-- Matching and looking up classes and family instances
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

data MatchInstResult mi
  = MatchInstNo         -- No matching instance 
  | MatchInstSingle mi  -- Single matching instance
  | MatchInstMany       -- Multiple matching instances


matchClass :: Class -> [Type] -> TcS (MatchInstResult (DFunId, [Either TyVar TcType])) 
-- Look up a class constraint in the instance environment
matchClass clas tys
  = do	{ let pred = mkClassPred clas tys 
        ; instEnvs <- getInstEnvs
--        ; traceTcS "matchClass" $ empty -- text "instEnvs=" <+> ppr instEnvs
        ; case lookupInstEnv instEnvs clas tys of {
            ([], unifs, _)               -- Nothing matches  
                -> do { traceTcS "matchClass not matching"
                                 (vcat [ text "dict" <+> ppr pred, 
                                         text "unifs" <+> ppr unifs ]) 
                      ; return MatchInstNo  
                      } ;  
	    ([(ispec, inst_tys)], [], _) -- A single match 
		-> do	{ let dfun_id = is_dfun ispec
			; traceTcS "matchClass success"
				   (vcat [text "dict" <+> ppr pred, 
				          text "witness" <+> ppr dfun_id
                                           <+> ppr (idType dfun_id) ])
				  -- Record that this dfun is needed
                        ; return $ MatchInstSingle (dfun_id, inst_tys)
                        } ;
     	    (matches, unifs, _)          -- More than one matches 
		-> do	{ traceTcS "matchClass multiple matches, deferring choice"
			           (vcat [text "dict" <+> ppr pred,
				   	  text "matches" <+> ppr matches,
				   	  text "unifs" <+> ppr unifs])
                        ; return MatchInstMany 
		        }
	}
        }

matchFam :: TyCon -> [Type] -> TcS (Maybe (FamInst, [Type]))
matchFam tycon args = wrapTcS $ tcLookupFamInst tycon args
\end{code}


-- Rewriting with respect to the inert equalities 
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}

getInertEqs :: TcS (TyVarEnv Ct, InScopeSet)
getInertEqs = do { inert <- getTcSInerts
                 ; let ics = inert_cans inert
                 ; return (inert_eqs ics, inert_eq_tvs ics) }

getCtCoercion :: EvBindMap -> Ct -> TcCoercion
-- Precondition: A CTyEqCan which is either Wanted or Given, never Derived or Solved!
getCtCoercion bs ct 
  = case lookupEvBind bs cc_id of
        -- Given and bound to a coercion term
      Just (EvBind _ (EvCoercion co)) -> co
                      -- NB: The constraint could have been rewritten due to spontaneous 
                -- unifications but because we are optimizing away mkRefls the evidence
                -- variable may still have type (alpha ~ [beta]). The constraint may 
                -- however have a more accurate type (alpha ~ [Int]) (where beta ~ Int has
                -- been previously solved by spontaneous unification). So if we are going 
                -- to use the evidence variable for rewriting other constraints, we'd better 
                -- make sure it's of the right type!
                -- Always the ctPred type is more accurate, so we just pick that type

      _ -> mkTcCoVarCo (setVarType cc_id (ctPred ct))
      
  where cc_id = ctId ct

\end{code}
