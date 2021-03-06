{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE  FlexibleContexts #-}

-- | Benchmarks for Shelley test generators.
module Shelley.Spec.Ledger.Bench.Gen
  ( genTriple,
    genBlock,
    genChainState,
  ) where

import Cardano.Ledger.Era(Crypto, Era)

import Control.State.Transition.Extended (IRC (..))
import Data.Either (fromRight)
import Data.Proxy
import Shelley.Spec.Ledger.API
  ( Block,
    ChainState(..),
    Tx,
  )
import Shelley.Spec.Ledger.LedgerState
  ( LedgerState(..),
    NewEpochState(..),
    EpochState(..),
  )
import Test.QuickCheck (generate)
import qualified Test.Shelley.Spec.Ledger.Generator.Block as GenBlock
import Test.Shelley.Spec.Ledger.Generator.Constants
  ( Constants
      ( maxGenesisUTxOouts,
        maxMinFeeA,
        minGenesisUTxOouts
      ),
  )
import Test.Shelley.Spec.Ledger.Generator.Core (GenEnv, geConstants)
import Test.Shelley.Spec.Ledger.Generator.Trace.Chain (mkGenesisChainState)
import Test.Shelley.Spec.Ledger.Serialisation.Generators()  -- Arbitrary Coin
import Test.Shelley.Spec.Ledger.ConcreteCryptoTypes(Mock)
import Test.Shelley.Spec.Ledger.Generator.Presets (genEnv)
import Test.Shelley.Spec.Ledger.Generator.Utxo(genTx)
import Test.Shelley.Spec.Ledger.BenchmarkFunctions(ledgerEnv)

-- =============================================================================

-- | Generate a genesis chain state given a UTxO size
genChainState :: Era era => Int -> GenEnv era -> IO (ChainState era)
genChainState n ge =
  let cs =
        (geConstants ge)
          { minGenesisUTxOouts = n,
            maxGenesisUTxOouts = n,
            -- We are using real crypto types here, which can be larger than
            -- those expected by the mock fee calculations. Since this is
            -- unimportant for now, we set the A part of the fee to 0
            maxMinFeeA = 0
          }
   in fromRight (error "genChainState failed")
        <$> ( generate $
                mkGenesisChainState cs (IRC ())
            )

-- | Benchmark generating a block given a chain state.
genBlock :: (Mock (Crypto era),Era era) => GenEnv era -> ChainState era -> IO (Block era)
genBlock ge cs = generate $ GenBlock.genBlock ge cs


-- The order one does this is important, since all these things must flow from the same
-- GenEnv, so that the addresses ind signatures in the UTxO are known and consistent.
-- 1) genEnv from a (Proxy era)
-- 2) genChainState from a GenEnv
-- 3) get a UTxOState from the ChainState
-- 4) get a DPState from the ChainState
-- 5) get a Transaction (Tx) from GenEnv and ChainState


genTriple :: (Mock (Crypto era),Era era) => Proxy era -> Int -> IO(GenEnv era, ChainState era, GenEnv era -> IO (Tx era))
genTriple proxy n = do
  let ge = genEnv proxy
  cs <- genChainState n ge
  let nes = chainNes cs  -- NewEpochState
  let es = nesEs nes     -- EpochState
  let (LedgerState utxoS dpstate) = esLState es   -- LedgerState
  let fun genenv = generate $ genTx genenv ledgerEnv (utxoS,dpstate)
  pure (ge,cs,fun)
