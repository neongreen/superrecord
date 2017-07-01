{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE MagicHash #-}
module SuperRecord
    ( -- * Basics
      (:=)(..)
    , Rec, rnil, rcons, (&)
    , Has
    , get, (&.)
    , set, SetPath(..), SPath(..), (&:), snil
    , combine, (++:), RecAppend
      -- * Reflection
    , reflectRec,  RecApply(..)
      -- * Machinery
    , RecTyIdxH
    , showRec, RecKeys(..)
    , RecEq(..)
    , recToValue, recToEncoding
    , recJsonParser, RecJsonParse(..)
    , RecNfData(..)
    , RecSize, RemoveAccessTo
    , FldProxy(..), RecDeepTy
    , KeyDoesNotExist
    )
where

import Control.DeepSeq
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Constraint
import Data.Proxy
import Data.Typeable
import GHC.Base (Int(..))
import GHC.IO ( IO(..) )
import GHC.OverloadedLabels
import GHC.Prim
import GHC.TypeLits
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as T

-- | Field named @l@ labels value of type @t@ adapted from the awesome /labels/ package.
-- Example: @(#name := \"Chris\") :: (\"name\" := String)@
data label := value = KnownSymbol label => FldProxy label := !value
deriving instance Typeable (:=)
deriving instance Typeable (label := value)
infix 6 :=

instance (Eq value) => Eq (label := value) where
  (_ := x) == (_ := y) = x == y
  {-# INLINE (==) #-}

instance (Ord value) => Ord (label := value) where
  compare (_ := x) (_ := y) = x `compare` y
  {-# INLINE compare #-}

instance (Show t) =>
         Show (l := t) where
  showsPrec p (l := t) =
      showParen (p > 10) (showString ("#" ++ symbolVal l ++ " := " ++ show t))

-- | A proxy witness for a label. Very similar to 'Proxy', but needed to implement
-- a non-orphan 'IsLabel' instance
data FldProxy (t :: Symbol)
    = FldProxy
    deriving (Show, Read, Eq, Ord, Typeable)

instance l ~ l' => IsLabel (l :: Symbol) (FldProxy l') where
    fromLabel _ = FldProxy

-- | The core record type.
data Rec (lts :: [*])
   = Rec { _unRec :: SmallArray# Any } -- Note that the values are physically in reverse order

instance (RecApply lts lts Show) => Show (Rec lts) where
    show = show . showRec

instance RecEq lts lts => Eq (Rec lts) where
    (==) (a :: Rec lts) (b :: Rec lts) = recEq a b (Proxy :: Proxy lts)
    {-# INLINE (==) #-}

instance
    ( RecApply lts lts ToJSON
    ) => ToJSON (Rec lts) where
    toJSON = recToValue
    toEncoding = recToEncoding

instance (RecSize lts ~ s, KnownNat s, RecJsonParse lts) => FromJSON (Rec lts) where
    parseJSON = recJsonParser

instance RecNfData lts lts => NFData (Rec lts) where
    rnf = recNfData (Proxy :: Proxy lts)

-- | An empty record
rnil :: Rec '[]
rnil = unsafeRnil 0
{-# INLINE rnil #-}

-- newByteArray# :: Int# -> State# s -> (#State# s, MutableByteArray# s#)

-- | An empty record with an initial size for the record
unsafeRnil :: Int -> Rec '[]
unsafeRnil (I# n#) =
    unsafePerformIO $! IO $ \s# ->
    case newSmallArray# n# (error "No Value") s# of
      (# s'#, arr# #) ->
          case unsafeFreezeSmallArray# arr# s'# of
            (# s''#, a# #) -> (# s''# , Rec a# #)

    -- (A.newArray initSize (error "No Value") >>= A.unsafeFreezeArray)
{-# INLINE unsafeRnil #-}

-- | Prepend a record entry to a record 'Rec'
rcons ::
    forall l t lts s.
    (RecSize lts ~ s, KnownNat s, KeyDoesNotExist l lts)
    => l := t -> Rec lts -> Rec (l := t ': lts)
rcons (_ := val) (Rec vec#) =
    unsafePerformIO $! IO $ \s# ->
    case newSmallArray# newSize# (error "No value") s# of
      (# s'#, arr# #) ->
          case copySmallArray# vec# 0# arr# 0# size# s'# of
            s''# ->
                case writeSmallArray# arr# size# (unsafeCoerce# val) s''# of
                  s'''# ->
                      case unsafeFreezeSmallArray# arr# s'''# of
                        (# s''''#, a# #) -> (# s''''#, Rec a# #)
    where
        !(I# newSize#) = size + 1
        !(I# size#) = size
        size = fromIntegral $ natVal' (proxy# :: Proxy# s)
{-# INLINE rcons #-}

-- | Prepend a record entry to a record 'Rec'. Assumes that the record was created with
-- 'unsafeRnil' and still has enough free slots, mutates the original 'Rec' which should
-- not be reused after
unsafeRCons ::
    forall l t lts s.
    (RecSize lts ~ s, KnownNat s, KeyDoesNotExist l lts)
    => l := t -> Rec lts -> Rec (l := t ': lts)
unsafeRCons (_ := val) (Rec vec#) =
    unsafePerformIO $! IO $ \s# ->
    case unsafeThawSmallArray# vec# s# of
      (# s'#, arr# #) ->
          case writeSmallArray# arr# size# (unsafeCoerce# val) s'# of
            s''# ->
                case unsafeFreezeSmallArray# arr# s''# of
                  (# s'''#, a# #) -> (# s'''#, Rec a# #)
    where
        !(I# size#) = fromIntegral $ natVal' (proxy# :: Proxy# s)
{-# INLINE unsafeRCons #-}

-- | Alias for 'rcons'
(&) ::
    forall l t lts s.
    (RecSize lts ~ s, KnownNat s, KeyDoesNotExist l lts)
    => l := t -> Rec lts -> Rec (l := t ': lts)
(&) = rcons
{-# INLINE (&) #-}

infixr 5 &

type family KeyDoesNotExist (l :: Symbol) (lts :: [*]) :: Constraint where
    KeyDoesNotExist l '[] = 'True ~ 'True
    KeyDoesNotExist l (l := t ': lts) =
        TypeError
        ( 'Text "Duplicate key " ':<>: 'Text l
        )
    KeyDoesNotExist q (l := t ': lts) = KeyDoesNotExist q lts

type RecAppend lhs rhs = RecAppendH lhs rhs rhs '[]

type family ListConcat (xs :: [*]) (ys :: [*]) :: [*] where
    ListConcat '[] ys = ys
    ListConcat xs '[] = xs
    ListConcat (x ': xs) ys = x ': (ListConcat xs ys)

type family ListReverse (xs :: [*]) :: [*] where
    ListReverse (x ': xs) = ListConcat (ListReverse xs) '[x]
    ListReverse '[] = '[]

type family RecAppendH (lhs ::[*]) (rhs :: [*]) (rhsall :: [*]) (accum :: [*]) :: [*] where
    RecAppendH (l := t ': lhs) (m := u ': rhs) rhsall acc = RecAppendH (l := t ': lhs) rhs rhsall acc
    RecAppendH (l := t ': lhs) '[] rhsall acc = RecAppendH lhs rhsall rhsall (l := t ': acc)
    RecAppendH '[] rhs rhsall acc = ListConcat (ListReverse acc) rhsall

type family RecSize (lts :: [*]) :: Nat where
    RecSize '[] = 0
    RecSize (l := t ': lts) = 1 + RecSize lts

type RecVecIdxPos l lts = RecSize lts - RecTyIdxH 0 l lts - 1

type family RecTyIdxH (i :: Nat) (l :: Symbol) (lts :: [*]) :: Nat where
    RecTyIdxH idx l (l := t ': lts) = idx
    RecTyIdxH idx m (l := t ': lts) = RecTyIdxH (1 + idx) m lts
    RecTyIdxH idx m '[] =
        TypeError
        ( 'Text "Could not find label "
          ':<>: 'Text m
        )

type family RecTy (l :: Symbol) (lts :: [*]) :: * where
    RecTy l (l := t ': lts) = t
    RecTy q (l := t ': lts) = RecTy q lts

-- | State that a record contains a label
type Has l lts v =
   ( RecTy l lts ~ v
   , KnownNat (RecSize lts)
   , KnownNat (RecVecIdxPos l lts)
   )

-- | Get an existing record field
get ::
    forall l v lts.
    ( Has l lts v )
    => FldProxy l -> Rec lts -> v
get _ (Rec vec#) =
    let !(I# readAt#) =
            fromIntegral (natVal' (proxy# :: Proxy# (RecVecIdxPos l lts)))
        anyVal :: Any
        anyVal =
           case indexSmallArray# vec# readAt# of
             (# a# #) -> a#
    in unsafeCoerce# anyVal
{-# INLINE get #-}

-- | Alias for 'get'
(&.) :: forall l v lts. (Has l lts v) => Rec lts -> FldProxy l -> v
(&.) = flip get
infixl 3 &.

-- | Update an existing record field
set ::
    forall l v lts.
    (Has l lts v)
    => FldProxy l -> v -> Rec lts -> Rec lts
set _ !val (Rec vec#) =
    let !(I# size#) = fromIntegral $ natVal' (proxy# :: Proxy# (RecSize lts))
        !(I# setAt#) = fromIntegral (natVal' (proxy# :: Proxy# (RecVecIdxPos l lts)))
        dynVal :: Any
        !dynVal = unsafeCoerce# val
        r2 =
            unsafePerformIO $! IO $ \s# ->
            case newSmallArray# size# (error "No value") s# of
              (# s'#, arr# #) ->
                  case copySmallArray# vec# 0# arr# 0# size# s'# of
                    s''# ->
                        case writeSmallArray# arr# setAt# dynVal s''# of
                          s'''# ->
                              case unsafeFreezeSmallArray# arr# s'''# of
                                (# s''''#, a# #) -> (# s''''#, Rec a# #)
    in r2
{-# INLINE set #-}

-- | Path to the key that should be updated
data SPath (t :: [Symbol]) where
    SCons :: FldProxy l -> SPath ls -> SPath (l ': ls)
    SNil :: SPath '[]

-- | Alias for 'SNil'
snil :: SPath '[]
snil = SNil

{-# INLINE snil #-}

-- | Alias for 'SCons'
(&:) :: FldProxy l -> SPath ls -> SPath (l ': ls)
(&:) = SCons
infixr 8 &:

{-# INLINE (&:) #-}

type family RecDeepTy (ls :: [Symbol]) (lts :: k) :: * where
    RecDeepTy (l ': more) (Rec q) = RecDeepTy (l ': more) q
    RecDeepTy (l ': more) (l := Rec t ': lts) = RecDeepTy more t
    RecDeepTy (l ': more) (l := t ': lts) = t
    RecDeepTy (l ': more) (q := t ': lts) = RecDeepTy (l ': more) lts
    RecDeepTy '[] v = v

class SetPath k x where
    -- | Perform a deep update, setting the key along the path to the
    -- desired value
    setPath :: SPath k -> RecDeepTy k x -> x -> x

instance SetPath '[] v where
    setPath _ v _ = v
    {-# INLINE setPath #-}

instance
    ( SetPath more v
    , Has l lts v
    , RecDeepTy (l ': more) (Rec lts) ~ RecDeepTy more v
    ) => SetPath (l ': more) (Rec lts)
    where
    setPath (SCons k more) v r =
        let innerVal = get k r
        in set k (setPath more v innerVal) r
    {-# INLINE setPath #-}

-- | Combine two records
combine ::
    forall lhs rhs.
    (KnownNat (RecSize lhs), KnownNat (RecSize rhs), KnownNat (RecSize lhs + RecSize rhs))
    => Rec lhs
    -> Rec rhs
    -> Rec (RecAppend lhs rhs)
combine (Rec l#) (Rec r#) =
    let !(I# sizeL#) = fromIntegral $ natVal' (proxy# :: Proxy# (RecSize lhs))
        !(I# sizeR#) = fromIntegral $ natVal' (proxy# :: Proxy# (RecSize rhs))
        !(I# size#) = fromIntegral $ natVal' (proxy# :: Proxy# (RecSize lhs + RecSize rhs))
    in unsafePerformIO $! IO $ \s# ->
            case newSmallArray# size# (error "No value") s# of
              (# s'#, arr# #) ->
                  case copySmallArray# r# 0# arr# 0# sizeR# s'# of
                    s''# ->
                        case copySmallArray# l# 0# arr# sizeR# sizeL# s''# of
                          s'''# ->
                              case unsafeFreezeSmallArray# arr# s'''# of
                                (# s''''#, a# #) -> (# s''''#, Rec a# #)
{-# INLINE combine #-}

-- | Alias for 'combine'
(++:) ::
    forall lhs rhs.
    (KnownNat (RecSize lhs), KnownNat (RecSize rhs), KnownNat (RecSize lhs + RecSize rhs))
    => Rec lhs
    -> Rec rhs
    -> Rec (RecAppend lhs rhs)
(++:) = combine
{-# INLINE (++:) #-}

-- | Get keys of a record on value and type level
class RecKeys (lts :: [*]) where
    type RecKeysT lts :: [Symbol]
    recKeys :: t lts -> [String]

instance RecKeys '[] where
    type RecKeysT '[] = '[]
    recKeys _ = []

instance (KnownSymbol l, RecKeys lts) => RecKeys (l := t ': lts) where
    type RecKeysT (l := t ': lts) = (l ': RecKeysT lts)
    recKeys (_ :: f (l := t ': lts)) =
        let lbl :: FldProxy l
            lbl = FldProxy
            more :: Proxy lts
            more = Proxy
        in (symbolVal lbl : recKeys more)

-- | Apply a function to each key element pair for a record
reflectRec ::
    forall c r lts. (RecApply lts lts c)
    => Proxy c
    -> (forall a. c a => String -> a -> r)
    -> Rec lts
    -> [r]
reflectRec _ f r =
    recApply (\(Dict :: Dict (c a)) s v -> f s v) r (Proxy :: Proxy lts)
{-# INLINE reflectRec #-}

-- | Convert all elements of a record to a 'String'
showRec :: forall lts. (RecApply lts lts Show) => Rec lts -> [(String, String)]
showRec = reflectRec @Show Proxy (\k v -> (k, show v))

recToValue :: forall lts. (RecApply lts lts ToJSON) => Rec lts -> Value
recToValue r = toJSON $ reflectRec @ToJSON Proxy (\k v -> (T.pack k, toJSON v)) r

recToEncoding :: forall lts. (RecApply lts lts ToJSON) => Rec lts -> Encoding
recToEncoding r = pairs $ mconcat $ reflectRec @ToJSON Proxy (\k v -> (T.pack k .= v)) r

recJsonParser :: forall lts s. (RecSize lts ~ s, KnownNat s, RecJsonParse lts) => Value -> Parser (Rec lts)
recJsonParser =
    withObject "Record" $ \o ->
    recJsonParse initSize o
    where
        initSize = fromIntegral $ natVal' (proxy# :: Proxy# s)

-- | Machinery needed to implement 'reflectRec'
class RecApply (rts :: [*]) (lts :: [*]) c where
    recApply :: (forall a. Dict (c a) -> String -> a -> r) -> Rec rts -> Proxy lts -> [r]

instance RecApply rts '[] c where
    recApply _ _ _ = []

instance
    ( KnownSymbol l
    , RecApply rts (RemoveAccessTo l lts) c
    , Has l rts v
    , c v
    ) => RecApply rts (l := t ': lts) c where
    recApply f r (_ :: Proxy (l := t ': lts)) =
        let lbl :: FldProxy l
            lbl = FldProxy
            val = get lbl r
            res = f Dict (symbolVal lbl) val
            pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
            pNext = Proxy
        in (res : recApply f r pNext)

-- | Machinery to implement equality
class RecEq (rts :: [*]) (lts :: [*]) where
    recEq :: Rec rts -> Rec rts -> Proxy lts -> Bool

instance RecEq rts '[] where
    recEq _ _ _ = True

instance
    ( RecEq rts (RemoveAccessTo l lts)
    , Has l rts v
    , Eq v
    ) => RecEq rts (l := t ': lts) where
    recEq r1 r2 (_ :: Proxy (l := t ': lts)) =
       let lbl :: FldProxy l
           lbl = FldProxy
           val = get lbl r1
           val2 = get lbl r2
           res = val == val2
           pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
           pNext = Proxy
       in res && recEq r1 r2 pNext

type family RemoveAccessTo (l :: Symbol) (lts :: [*]) :: [*] where
    RemoveAccessTo l (l := t ': lts) = RemoveAccessTo l lts
    RemoveAccessTo q (l := t ': lts) = (l := t ': RemoveAccessTo l lts)
    RemoveAccessTo q '[] = '[]

-- | Machinery to implement parseJSON
class RecJsonParse (lts :: [*]) where
    recJsonParse :: Int -> Object -> Parser (Rec lts)

instance RecJsonParse '[] where
    recJsonParse initSize _ = pure (unsafeRnil initSize)

instance
    ( KnownSymbol l, FromJSON t, RecJsonParse lts
    , RecSize lts ~ s, KnownNat s, KeyDoesNotExist l lts
    ) => RecJsonParse (l := t ': lts) where
    recJsonParse initSize obj =
        do let lbl :: FldProxy l
               lbl = FldProxy
           (v :: t) <- obj .: T.pack (symbolVal lbl)
           rest <- recJsonParse initSize obj
           pure $ unsafeRCons (lbl := v) rest

-- | Machinery for NFData
class RecNfData (lts :: [*]) (rts :: [*]) where
    recNfData :: Proxy lts -> Rec rts -> ()

instance RecNfData '[] rts where
    recNfData _ _ = ()

instance
    ( Has l rts v
    , NFData v
    , RecNfData (RemoveAccessTo l lts) rts
    ) => RecNfData (l := t ': lts) rts where
    recNfData (_ :: (Proxy (l := t ': lts))) r =
        let !v = get (FldProxy :: FldProxy l) r
            pNext :: Proxy (RemoveAccessTo l (l := t ': lts))
            pNext = Proxy
        in deepseq v (recNfData pNext r)
