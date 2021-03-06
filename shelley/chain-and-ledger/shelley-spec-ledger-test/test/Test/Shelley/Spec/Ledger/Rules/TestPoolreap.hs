{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Test.Shelley.Spec.Ledger.Rules.TestPoolreap
  ( removedAfterPoolreap,
  )
where

import Control.Iterate.SetAlgebra (dom, eval, setSingleton, (∩), (⊆), (▷))
import qualified Data.Set as Set (Set, null)
import Shelley.Spec.Ledger.Keys (KeyHash, KeyRole (StakePool))
import Shelley.Spec.Ledger.LedgerState
  ( PState (..),
    _pParams,
  )
import Shelley.Spec.Ledger.Slot (EpochNo (..))
import Test.QuickCheck (Property, property)

-----------------------------
-- Properties for POOLREAP --
-----------------------------

-- | Check that after a POOLREAP certificate transition the pool is removed from
-- the stake pool and retiring maps.
removedAfterPoolreap ::
  forall era.
  PState era ->
  PState era ->
  EpochNo ->
  Property
removedAfterPoolreap p p' e =
  property $
    eval (retire ⊆ dom stp)
      && Set.null (eval (retire ∩ dom stp'))
      && Set.null (eval (retire ∩ dom retiring'))
  where
    stp = _pParams p
    stp' = _pParams p'
    retiring = _retiring p
    retiring' = _retiring p'
    retire :: Set.Set (KeyHash 'StakePool era) -- This declaration needed to disambiguate 'eval'
    retire = eval (dom (retiring ▷ setSingleton e))
