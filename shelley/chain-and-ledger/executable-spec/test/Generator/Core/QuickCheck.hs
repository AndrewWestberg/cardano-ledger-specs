{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Generator.Core.QuickCheck
  ( AllPoolKeys (..)
  , NatNonce (..)
  , coreNodeVKG
  , findPayKeyPair
  , findPayScript
  , genBool
  , genCoin
  , genCoinList
  , genInteger
  , genNatural
  , genWord64
  , genTxOut
  , genUtxo0
  , genesisAccountState
  , genesisDelegs0
  , increasingProbabilityAt
  , maxLovelaceSupply
  , numCoreNodes
  , coreKeyPairs
  , coreNodeKeys
  , traceKeyPairs
  , traceKeyHashMap
  , traceVRFKeyPairs
  , traceMSigScripts
  , traceMSigCombinations
  , someKeyPairs
  , someScripts
  , pickStakeKey
  , toAddr
  , toCred
  , zero
  , unitIntervalToNatural
  , mkBlock)
  where

import           Cardano.Crypto.VRF (deriveVerKeyVRF, genKeyVRF)
import           Control.Monad (replicateM)
import           Crypto.Random (drgNewTest, withDRG)
import           Data.Coerce (coerce)
import qualified Data.List as List (findIndex, (\\))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map (empty, fromList, insert, lookup)
import           Data.Ratio ((%))
import           Data.Sequence (fromList)
import           Data.Tuple (swap)
import           Data.Word (Word64)

import           Cardano.Crypto.VRF.Fake (WithResult (..))
import           Test.QuickCheck (Gen)
import qualified Test.QuickCheck as QC

import           Address (scriptsToAddr, toAddr, toCred)
import           BaseTypes (Nonce (..), UnitInterval, intervalValue)
import           BlockChain (pattern BHBody, pattern BHeader, pattern Block, ProtVer (..),
                     TxSeq (..), bBodySize, bbHash, mkSeed, seedEta, seedL)
import           Coin (Coin (..))
import           ConcreteCryptoTypes (Addr, AnyKeyHash, Block, CoreKeyPair, GenKeyHash, HashHeader,
                     KeyHash, KeyPair, KeyPairs, MultiSig, MultiSigPairs, SKeyES, SignKeyVRF, Tx,
                     TxOut, UTxO, VKey, VKeyES, VKeyGenesis, VerKeyVRF)
import           Generator.Core.Constants (maxGenesisOutputVal, maxNumKeyPairs, minGenesisOutputVal,
                     numBaseScripts)
import           Keys (pattern KeyPair, hashAnyKey, hashKey, sKey, sign, signKES,
                     undiscriminateKeyHash, vKey)
import           LedgerState (AccountState (..), genesisCoins)
import           Numeric.Natural (Natural)
import           OCert (KESPeriod (..), pattern OCert)
import           Slot (BlockNo (..), SlotNo (..))
import           Test.Utils (mkCertifiedVRF, mkGenKey, mkKESKeyPair, mkKeyPair, mkVRFKeyPair,
                     unsafeMkUnitInterval)
import           Tx (pattern TxOut, hashScript)
import           TxData (pattern AddrBase, pattern KeyHashObj, pattern RequireAllOf,
                     pattern RequireAnyOf, pattern RequireMOf, pattern RequireSignature,
                     pattern ScriptHashObj)

genBool :: Gen Bool
genBool = QC.arbitraryBoundedRandom

genInteger :: Integer -> Integer -> Gen Integer
genInteger lower upper = QC.choose (lower, upper)

-- | Generator for a natural number between 'lower' and 'upper'
genNatural :: Natural -> Natural -> Gen Natural
genNatural lower upper = fromInteger <$> QC.choose (lower', upper')
 where
  lower' = fromIntegral lower
  upper' = fromIntegral upper

-- | Generator for a Word64 between 'lower' and 'upper'
genWord64 :: Word64 -> Word64 -> Gen Word64
genWord64 lower upper = fromIntegral
  <$> genNatural (fromIntegral lower) (fromIntegral upper)

mkKeyPairs :: Word64 -> (KeyPair, KeyPair)
mkKeyPairs n
  = (mkKeyPair_ (2*n), mkKeyPair_ (2*n+1))
  where
    mkKeyPair_ n_ = (uncurry KeyPair . swap) (mkKeyPair (n_,n_,n_,n_,n_))

-- | Constant list of KeyPairs intended to be used in the generators.
traceKeyPairs :: KeyPairs
traceKeyPairs = mkKeyPairs <$> [1 .. maxNumKeyPairs]

-- | Mapping from key hash to key pair
traceKeyHashMap :: Map AnyKeyHash KeyPair
traceKeyHashMap =
  foldl (\m (payKey, stakeKey) ->
           let m' = Map.insert (hashAnyKey $ vKey payKey) payKey m
           in       Map.insert (hashAnyKey $ vKey stakeKey) stakeKey m')
  Map.empty traceKeyPairs

numCoreNodes :: Word64
numCoreNodes = 7

-- | Multi-Sig Scripts based on the `traceKeyPairs` key pairs
traceMSigScripts :: MultiSigPairs
traceMSigScripts = map mkScriptsFromKeyPair traceKeyPairs

-- | Combine a list of multisig pairs into hierarchically structured multi-sig
-- scripts, list must have at least length 3. Be careful not to call with too
-- many pairs in order not to create too many of the possible combinations.
traceMSigCombinations :: MultiSigPairs -> MultiSigPairs
traceMSigCombinations msigs =
  if length msigs < 3 then error "length of input msigs must be at least 3"
  else foldl (++) [] $
       do
         (k1, k2) <- msigs
         (k3, k4) <- msigs List.\\ [(k1, k2)]
         (k5, k6) <- msigs List.\\ [(k1, k2), (k3, k4)]

         pure [(pay, stake) | pay <- [ RequireAnyOf [k1, k3, k5]
                                     , RequireAllOf [k1, k3, k5]
                                     , RequireMOf 1 [k1, k3, k5]
                                     , RequireMOf 2 [k1, k3, k5]
                                     , RequireMOf 3 [k1, k3, k5]]
                            , stake <- [ RequireAnyOf [k2, k4, k6]
                                       , RequireAllOf [k2, k4, k6]
                                       , RequireMOf 1 [k2, k4, k6]
                                       , RequireMOf 2 [k2, k4, k6]
                                       , RequireMOf 3 [k2, k4, k6]]]

mkScriptsFromKeyPair :: (KeyPair, KeyPair) -> (MultiSig, MultiSig)
mkScriptsFromKeyPair (k0, k1) = (mkScriptFromKey k0, mkScriptFromKey k1)

mkScriptFromKey :: KeyPair -> MultiSig
mkScriptFromKey = (RequireSignature . hashAnyKey . vKey)

data AllPoolKeys = AllPoolKeys
  { cold :: KeyPair
  , vrf :: (SignKeyVRF, VerKeyVRF)
  , hot :: (SKeyES, VKeyES)
  , hk  :: KeyHash
  } deriving (Show)

-- Pairs of (genesis key, node keys)
--
-- NOTE: we use a seed range in the [1000...] range
-- to create keys that don't overlap with any of the other generated keys
coreNodeKeys :: [(CoreKeyPair, AllPoolKeys)]
coreNodeKeys =
  [ ( (toKeyPair . mkGenKey)  (x, 0, 0, 0, 0)
    , let (skCold, vkCold) = mkKeyPair (x, 0, 0, 0, 1) in
        AllPoolKeys
          (toKeyPair (skCold, vkCold))
          (mkVRFKeyPair (x, 0, 0, 0, 2))
          (mkKESKeyPair (x, 0, 0, 0, 3))
          (hashKey vkCold)
    )
  | x <- [1001..1000+numCoreNodes]
  ]
  where
    toKeyPair (sk,vk) = KeyPair {sKey = sk, vKey = vk}

-- Pairs of (genesis key, node cold key)
coreNodeVKG :: Int -> VKeyGenesis
coreNodeVKG = vKey . fst . (coreNodeKeys !!)

coreKeyPairs :: [CoreKeyPair]
coreKeyPairs = fst . unzip $ coreNodeKeys

-- | Select between _lower_ and _upper_ keys from 'traceKeyPairs'
someKeyPairs :: Int -> Int -> Gen KeyPairs
someKeyPairs lower upper =
  take
    <$> QC.choose (lower, upper)
    <*> QC.shuffle traceKeyPairs

-- | Select between _lower_ and _upper_ scripts from the possible combinations
-- of the first `numBaseScripts` multi-sig scripts of `traceMSigScripts`.
someScripts :: Int -> Int -> Gen MultiSigPairs
someScripts lower upper =
  take
  <$> QC.choose (lower, upper)
  <*> QC.shuffle (traceMSigCombinations $ take numBaseScripts traceMSigScripts)

-- | Find first matching key pair for address. Returns the matching key pair
-- where the first element of the pair matched the hash in 'addr'.
findPayKeyPair :: Addr -> Map AnyKeyHash KeyPair -> KeyPair
findPayKeyPair (AddrBase (KeyHashObj addr) _) keyHashMap =
    case Map.lookup (undiscriminateKeyHash addr) keyHashMap of
      Nothing -> error "findPayKeyPair: could not find a match for the given address"
      Just kp -> kp
findPayKeyPair _ _ = error "findPayKeyPair: expects only AddrBase addresses"

-- | Find first matching script for address.
findPayScript :: Addr -> MultiSigPairs -> (MultiSig, MultiSig)
findPayScript (AddrBase (ScriptHashObj scriptHash) _) scripts =
  case List.findIndex (\(pay, _) -> scriptHash == hashScript pay) scripts of
    Nothing -> error "findPayScript: could not find matching script for given address"
    Just i  -> scripts !! i
findPayScript _ _ = error "findPayScript: unsupported address format"

-- | Select one random verification staking key from list of pairs of KeyPair.
pickStakeKey :: KeyPairs -> Gen VKey
pickStakeKey keys = vKey . snd <$> QC.elements keys

-- | Generates a list of coins for the given 'Addr' and produced a 'TxOut' for each 'Addr'
--
-- Note: we need to keep the initial utxo coin sizes large enough so that
-- when we simulate sequences of transactions, we have enough funds available
-- to include certificates that require deposits.
genTxOut :: [Addr] -> Gen [TxOut]
genTxOut addrs = do
  ys <- genCoinList minGenesisOutputVal maxGenesisOutputVal (length addrs) (length addrs)
  return (uncurry TxOut <$> zip addrs ys)

-- | Generates a list of 'Coin' values of length between 'lower' and 'upper'
-- and with values between 'minCoin' and 'maxCoin'.
genCoinList :: Integer -> Integer -> Int -> Int -> Gen [Coin]
genCoinList minCoin maxCoin lower upper = do
  len <- QC.choose (lower, upper)
  replicateM len $ genCoin minCoin maxCoin

-- TODO this should be an exponential distribution, not constant
genCoin :: Integer -> Integer -> Gen Coin
genCoin minCoin maxCoin = Coin <$> QC.choose (minCoin, maxCoin)

genUtxo0 :: Int -> Int -> Gen UTxO
genUtxo0 lower upper = do
  genesisKeys <- someKeyPairs lower upper
  genesisScripts <- someScripts lower upper
  outs <- genTxOut (fmap toAddr genesisKeys ++ fmap scriptsToAddr genesisScripts)
  return (genesisCoins outs)

genesisDelegs0 :: Map GenKeyHash KeyHash
genesisDelegs0
  = Map.fromList
      [ (hashVKey gkey, hashVKey (cold pkeys))
      | (gkey, pkeys) <- coreNodeKeys]
  where
    hashVKey = hashKey . vKey

-- | Account with empty treasury
genesisAccountState :: AccountState
genesisAccountState =
  AccountState
  { _treasury = Coin 0
  , _reserves = maxLovelaceSupply
  }

maxLovelaceSupply :: Coin
maxLovelaceSupply = Coin 45*1000*1000*1000*1000*1000

-- | Generate values the given distribution in 90% of the cases, and values at
-- the bounds of the range in 10% of the cases.
--
-- This can be used to generate enough extreme values. The exponential and
-- linear distributions provided by @hedgehog@ will generate a small percentage
-- of these (0-1%).
increasingProbabilityAt
  :: Gen a
  -> (a, a)
  -> Gen a
increasingProbabilityAt gen (lower, upper)
  = QC.frequency [ (5, pure lower)
                 , (90, gen)
                 , (5, pure upper)
                 ]

-- | A pre-populated space of VRF keys for use in the generators.
traceVRFKeyPairs :: [(SignKeyVRF, VerKeyVRF)]
traceVRFKeyPairs = [body (0,0,0,0,i) | i <- [1 .. 50]]
 where
  body seed = fst . withDRG (drgNewTest seed) $ do
    sk <- genKeyVRF
    return (sk, deriveVerKeyVRF sk)

zero :: UnitInterval
zero = unsafeMkUnitInterval 0

-- | Try to map the unit interval to a natural number. We don't care whether
-- this is surjective. But it should be right inverse to `fromNatural` - that
-- is, one should be able to recover the `UnitInterval` value used here.
unitIntervalToNatural :: UnitInterval -> Natural
unitIntervalToNatural = floor . ((10000 % 1) *) . intervalValue

mkBlock
  :: HashHeader   -- ^ Hash of previous block
  -> AllPoolKeys  -- ^ All keys in the stake pool
  -> [Tx]         -- ^ Transactions to record
  -> SlotNo       -- ^ Current slot
  -> BlockNo      -- ^ Block number/chain length/chain "difficulty"
  -> Nonce        -- ^ EpochNo nonce
  -> NatNonce     -- ^ Block nonce
  -> UnitInterval -- ^ Praos leader value
  -> Natural      -- ^ Period of KES (key evolving signature scheme)
  -> Block
mkBlock prev pkeys txns s blockNo enonce (NatNonce bnonce) l kesPeriod =
  let
    (shot, vhot) = hot pkeys
    nonceNonce = mkSeed seedEta s enonce prev
    leaderNonce = mkSeed seedL s enonce prev
    bhb = BHBody
            prev
            (vKey $ cold pkeys)
            (snd $ vrf pkeys)
            s
            blockNo
            (coerce $ mkCertifiedVRF (WithResult nonceNonce bnonce) (fst $ vrf pkeys))
            (coerce $ mkCertifiedVRF (WithResult leaderNonce $ unitIntervalToNatural l) (fst $ vrf pkeys))
            (fromIntegral $ bBodySize $ (TxSeq . fromList) txns)
            (bbHash $ TxSeq $ fromList txns)
            (OCert
              vhot
              (vKey $ cold pkeys)
              0
              (KESPeriod 0)
              (sign (sKey $ cold pkeys) (vhot, 0, KESPeriod 0))
            )
            (ProtVer 0 0 0)
    bh = BHeader bhb (signKES shot bhb kesPeriod)
  in
    Block bh (TxSeq $ fromList txns)

-- | We provide our own nonces to 'mkBlock', which we then wish to recover as
-- the output of the VRF functions. In general, however, we just derive them
-- from a natural. Since the nonce is a hash, we do not want to recover it to
-- find a preimage. In testing, therefore, we just wrap the raw natural, which
-- we then encode into the fake VRF implementation.
newtype NatNonce = NatNonce Natural
