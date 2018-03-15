{-# LANGUAGE CPP, DataKinds, DeriveFoldable, DeriveFunctor   #-}
{-# LANGUAGE DeriveTraversable, MultiWayIf, OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables                             #-}
module Algebra.Algorithms.Groebner.Homogeneous
       ( calcGroebnerBasisAfterHomogenising
       , calcHomogeneousGroebnerBasis
       , unsafeCalcHomogeneousGroebnerBasis
       , hilbertPoincareSeries
       , hilbertPoincareSeriesBy
       , hilbertPoincareSeriesForMonomials
       , HPS, taylorHPS, toRationalFunction
       , calcHomogeneousGroebnerBasisHilbert
       , calcHomogeneousGroebnerBasisHilbertBy
       , calcHomogeneousGroebnerBasisHilbertWithSeries
       ) where
import           Algebra.Field.RationalFunction
import           Algebra.Prelude.Core                hiding (empty, filter,
                                                      insert)
import           Algebra.Ring.Polynomial.Homogenised
import           Algebra.Ring.Polynomial.Univariate
import           Control.Lens                        (ix, (%~), (&))
import           Control.Monad.Loops                 (whileJust_)
import           Control.Monad.ST.Strict
import qualified Data.Coerce                         as C
import qualified Data.Foldable                       as F
import           Data.Function                       (on)
import           Data.Functor.Identity
import           Data.Heap                           (Entry (..), Heap)
import qualified Data.Heap                           as H
import qualified Data.IntMap                         as IM
import qualified Data.List                           as L
import           Data.Maybe                          (fromJust)
import qualified Data.Sized.Builtin                  as SV
import           Data.STRef                          (STRef, modifySTRef',
                                                      newSTRef, readSTRef,
                                                      writeSTRef)
import qualified Data.Vector                         as V
import qualified Data.Vector.Mutable                 as MV
import           GHC.Exts                            (Constraint)
import qualified Numeric.Field.Fraction              as NA

isHomogeneous :: IsOrderedPolynomial poly
              => poly -> Bool
isHomogeneous poly =
  let degs = map F.sum $ F.toList $ monomials poly
  in and $ zipWith (==) degs (tail degs)

-- | Calculates Groebner basis once homogenise, apply @'unsafeCalcHomogeneousGroebnerBasis'@,
--   and then dehomogenise.
calcGroebnerBasisAfterHomogenising :: (Field (Coefficient poly), IsOrderedPolynomial poly)
                  => Ideal poly -> [poly]
calcGroebnerBasisAfterHomogenising i
  | F.all isHomogeneous i = unsafeCalcHomogeneousGroebnerBasis i
  | otherwise = map unhomogenise $ unsafeCalcHomogeneousGroebnerBasis $ fmap homogenise i

-- | Calculates a Groebner basis of the given /homogeneous/ ideal,
--   i.e. an ideal generated by homogeneous polynomials.
--   Returns @'Nothing'@ if the given ideal is inhomogeneous.
--
--   See also @'unsafeCalcHomogeneousGroebnerBasis'@.
calcHomogeneousGroebnerBasis :: (Field (Coefficient poly), IsOrderedPolynomial poly)
                             => Ideal poly -> Maybe [poly]
calcHomogeneousGroebnerBasis i
  | F.all isHomogeneous i = Just $ unsafeCalcHomogeneousGroebnerBasis i
  | otherwise = Nothing

-- | Calculates a Groebner basis of the given /homogeneous/ ideal,
--   i.e. an ideal generated by homogeneous polynomials.
--
--   __N.B.__ This function /DOES NOT/ check homogeniety of the given ideal.
--   See also @'calcHomogeneousGroebnerBasis'@.
unsafeCalcHomogeneousGroebnerBasis :: (Field (Coefficient poly), IsOrderedPolynomial poly)
                             => Ideal poly -> [poly]
unsafeCalcHomogeneousGroebnerBasis ideal = runST $ do
  gs <- newSTRef =<< V.unsafeThaw (V.fromList $ generators ideal)
  sigs <- newSTRef
          =<< buildTable gs [0 .. length (generators ideal) - 1]
  let ins g = do
        j <- snoc gs g
        news <- buildTable gs [j]
        modifySTRef' sigs $ H.union news
  whileJust_ (H.uncons <$> readSTRef sigs) $ \(Entry _ (i, j), h') -> do
    writeSTRef sigs h'
    (fi, fj) <- (,) <$> at gs i <*> at gs j
    gs' <- V.toList <$> (V.unsafeFreeze =<< readSTRef gs)
    let s = sPolynomial fi fj `modPolynomial` gs'
    unless (isZero s) $ ins s
  V.toList <$> (V.unsafeFreeze =<< readSTRef gs)

type Signatures weight = H.Heap (Entry weight (Int, Int))

buildTable :: IsOrderedPolynomial poly
           => RefVec s poly -> [Int] -> ST s (Signatures Int)
buildTable gs inds =
  H.fromList <$> sequence
          [ flip Entry (i, j) <$> deg gs i j
          | j <- inds
          , i <- [0 .. j - 1]
          ]

type RefVec s a = STRef s (MV.MVector s a)

at :: RefVec s a -> Int -> ST s a
at mv i = flip MV.read i =<< readSTRef mv

snoc :: RefVec s a -> a -> ST s Int
snoc ref v = do
  vec <- flip MV.grow 1 =<< readSTRef ref
  let ind = MV.length vec - 1
  MV.write vec ind v
  writeSTRef ref vec
  return ind
{-# INLINE snoc #-}

deg :: IsOrderedPolynomial poly => RefVec s poly -> Int -> Int -> ST s Int
deg gs i j = do
  vec <- readSTRef gs
  (totalDegree .) . (lcmMonomial `on` leadingMonomial)
       <$> MV.read vec i
       <*> MV.read vec j
{-# INLINE deg #-}

data ReversedEntry p a = ReversedEntry { rePriority :: p
                                       , rePayload  :: a}
                     deriving (Read, Show, Functor, Foldable)

instance Eq p => Eq (ReversedEntry p a) where
  (==) = (==) `on` rePriority

instance (Ord p) => Ord (ReversedEntry p a) where
  compare = flip (comparing rePriority)

viewMax :: Ord p => Heap (ReversedEntry p a) -> Maybe (ReversedEntry p a, Heap (ReversedEntry p a))
viewMax = H.viewMin

class (Foldable f) => Container f where
  type Element f a :: Constraint
  filter    :: (a -> Bool) -> f a -> f a
  insert    :: Element f a => a -> f a -> f a
  empty     :: f a

instance Container Heap where
  {-# SPECIALISE instance Container Heap #-}
  type Element Heap a = (Ord a)
  filter = H.filter
  insert = H.insert
  empty = H.empty

instance Container [] where
  {-# SPECIALISE instance Container [] #-}
  type Element [] a = ()
  filter = L.filter
  insert = (:)
  empty = []

head' :: Foldable t => t a -> a
head' = fromJust . F.find (const True)

divs' :: Foldable t => t (Monomial n) -> t (Monomial n) -> Bool
divs' = divs `on` orderMonomial (Just Lex) . head'

minimalGenerators' :: forall t f n. (Container t, KnownNat n, Element t (f (Monomial n)), Foldable f)
                  => t (f (Monomial n)) -> t (f (Monomial n))
minimalGenerators' bs
  | any (all (== 0) . head') bs = empty
  | otherwise = F.foldr check empty bs
  where
    check a acc =
      if any (`divs'` a) acc
      then acc
      else insert a $ filter (not . (a `divs'`)) acc
{-# SPECIALISE minimalGenerators' :: KnownNat n => [Identity (Monomial n)] -> [Identity (Monomial n)] #-}
{-# SPECIALISE minimalGenerators' :: (KnownNat n, Ord p) => Heap (ReversedEntry p (Monomial n)) -> Heap (ReversedEntry p (Monomial n)) #-}

-- | Computes a minimal generator of monomial ideal
minimalGenerators :: KnownNat n => [Monomial n] -> [Monomial n]
minimalGenerators =
  C.coerce . minimalGenerators' .
  (C.coerce :: [Monomial n] -> [Identity (Monomial n)])
{-# INLINE minimalGenerators #-}

-- | Calculates the Hilbert-Poincare serires of a given homogeneous ideal,
--   using the specified monomial ordering.
hilbertPoincareSeriesBy :: forall ord poly.
                           (IsMonomialOrder (Arity poly) ord,
                            Field (Coefficient poly),
                            IsOrderedPolynomial poly)
                        => ord -> Ideal poly -> HPS (Arity poly)
hilbertPoincareSeriesBy _ =
    hilbertPoincareSeriesForMonomials
  . map (getMonomial . leadingMonomial)
  . unsafeCalcHomogeneousGroebnerBasis
  . map (mapPolynomial id id :: poly -> OrderedPolynomial (Coefficient poly) ord (Arity poly))

-- | A variant of @'hilbertPoincareSeriesBy'@ using @'Grevlex'@ ordering.
hilbertPoincareSeries :: (Field (Coefficient poly), IsOrderedPolynomial poly)
                      =>  Ideal poly -> HPS (Arity poly)
hilbertPoincareSeries = hilbertPoincareSeriesBy Grevlex

-- | One-point compactification of ordered space.
data Compactified a = Infinity
                    | Finite a
                      deriving (Read, Show, Eq, Functor, Foldable, Traversable)

instance Ord a => Ord (Compactified a) where
  compare Infinity   Infinity   = EQ
  compare Infinity   _          = GT
  compare _          Infinity   = LT
  compare (Finite a) (Finite b) = compare a b

  Infinity < _         = False
  Finite _ < Infinity  = True
  Finite a < Finite b  = a < b

  _        <= Infinity = True
  Finite a <= Finite b = a <= b
  Infinity <= Finite _ = False

data HPS n = HPS { taylorHPS :: [Integer]
                 , hpsNumerator :: Unipol Integer
                 }

instance Eq (HPS a) where
  (==) = (==) `on` hpsNumerator

instance KnownNat n => Show (HPS n) where
  showsPrec d = showsPrec d . toRationalFunction

instance Additive (HPS n) where
  HPS cs f + HPS ds g = HPS (zipWith (+) cs ds) (f + g)

instance LeftModule Natural (HPS n) where
  n .* HPS cs f = HPS (map (toInteger n*) cs) (n .* f)

instance RightModule Natural (HPS n) where
  HPS cs f *. n = HPS (map (*toInteger n) cs) (f *. n)

instance LeftModule Integer (HPS n) where
  n .* HPS cs f = HPS (map (n*) cs) (n .* f)

instance RightModule Integer (HPS n) where
  HPS cs f *. n = HPS (map (*n) cs) (f *. n)

instance Monoidal (HPS n) where
  zero = HPS (repeat 0) zero

instance Group (HPS n) where
  negate (HPS cs f) = HPS (map negate cs) (negate f)
  HPS cs f - HPS ds g = HPS (zipWith (-) cs ds) (f - g)
instance Abelian (HPS n)

convolute :: [Integer] -> [Integer] -> [Integer]
convolute ~(x : xs) ~(y : ys) =
  x * y : zipWith3 (\a b c -> a + b + c) (map (x*) ys) (map (y*) xs) (0 : convolute xs ys)
{-# INLINE convolute #-}

instance LeftModule (Unipol Integer) (HPS n) where
  poly .* HPS cs g = HPS (convolute (coeffList poly ++ repeat 0) cs) (poly * g)

binoms :: forall n. KnownNat n => Natural -> HPS n
binoms p =
  let n = natVal (sing :: Sing n)
  in ((1 - #x) ^ p :: Unipol Integer)
     .* HPS [ binom (n + m - 1) m | m <- [0..]] 1
{-# INLINE binoms #-}

binom :: Integer -> Integer -> Integer
binom m k = product [m - k + 1 .. m] `div` product [1..k]
{-# INLINE binom #-}

toRationalFunction :: KnownNat n => HPS n -> RationalFunction Rational
toRationalFunction s@(HPS _ f) =
  fromPolynomial (mapCoeffUnipol (NA.% 1) f) / fromPolynomial ((1 - #x) ^ fromIntegral (natVal s) :: Unipol Rational)

hilbertPoincareSeriesForMonomials :: forall t n. (KnownNat n, Foldable t)
                                  => t (Monomial n) -> HPS n
hilbertPoincareSeriesForMonomials ms0 =
  go $ H.fromList [ ReversedEntry (F.sum m) m
                  | m <- minimalGenerators $ F.toList ms0 ]
  where
    go ms =
      let n  = fromIntegral $ natVal (Proxy :: Proxy n)
      in case viewMax ms of
        Nothing                     -> binoms n
        Just (ReversedEntry 0 _, _) -> zero
        Just (ReversedEntry 1 _, _) -> binoms $ fromIntegral $ H.size ms
        Just (ReversedEntry _ m, _) ->
          let Just i = SV.sFindIndex (> 0) m
              xi = varMonom sing i
              upd (ReversedEntry d xs) =
                   let xs' = (xs & ix i %~ max 0 . pred)
                   in ReversedEntry (F.sum xs') xs'
              added = minimalGenerators' $ insert (ReversedEntry 1 xi) ms
              quo = minimalGenerators' $ H.map upd ms
          in go added + (#x :: Unipol Integer) .* go quo

buildHilbTable :: IsOrderedPolynomial poly
               => RefVec s poly
               -> [Int]
               -> ST s (IntMap [(Int, Int)])
buildHilbTable gs js =
  IM.unionsWith (++) <$>
         sequence [ flip IM.singleton [(i,j)] <$> deg gs i j
                  | j <- js, i <- [0..j-1]
                  ]

whileForM_ :: (Foldable t, Monad m) => m Bool -> t a -> (a -> m b) -> m ()
whileForM_ test xs f =
  F.foldr (\x act -> test >>= flip when (f x >> act)) (return ()) xs
{-# INLINE whileForM_ #-}

calcHomogeneousGroebnerBasisHilbertWithSeries :: ( Field (Coefficient poly), IsOrderedPolynomial poly)
                                              => Ideal poly
                                              -> HPS (Arity poly)
                                              -> [poly]
calcHomogeneousGroebnerBasisHilbertWithSeries ip hps = runST $ do
  delta <- newSTRef Infinity
  let v0 = V.fromList $ generators ip
  gs <- newSTRef =<< V.unsafeThaw v0
  bs <- newSTRef . IM.insertWith (++) 0 []
        =<< buildHilbTable gs [0..V.length v0 - 1]
  let ins g = do
        j <- snoc gs g
        news <- buildHilbTable gs [j]
        modifySTRef' bs $ IM.unionWith (++) news
  whileJust_ (IM.minView <$> readSTRef bs) $ \(sigs, bs') -> do
    writeSTRef bs bs'
    whileForM_ ((> Finite 0) <$> readSTRef delta) sigs $ \(i, j) -> do
      spol <- modPolynomial <$> (sPolynomial <$> at gs i <*> at gs j)
                            <*> (F.toList <$> (V.unsafeFreeze =<< readSTRef gs))
      unless (isZero spol) $ do
        ins spol
        modifySTRef' delta (fmap pred)
    hps' <- hilbertPoincareSeriesForMonomials . fmap (getMonomial . leadingMonomial)
              <$> (V.unsafeFreeze =<< readSTRef gs)
    if hps' == hps
      then writeSTRef bs IM.empty
      else do
        let Just (m',  orig, new) =
              find (\(_,b,c) -> b /= c) $
              zip3 [0..] (taylorHPS hps) (taylorHPS hps')
        writeSTRef delta $ Finite $ new - orig
        writeSTRef bs . snd . IM.split (m' - 1) =<< readSTRef bs
  V.toList <$> (V.unsafeFreeze =<< readSTRef gs)

-- | First compute Hilbert-Poicare series w.r.t. @ord@ by
--   @'hilbertPoincareSeriesBy'@, and then apply @'calcHomogeneousGroebnerBasisHilbertWithSeries'@.
calcHomogeneousGroebnerBasisHilbertBy :: (Field (Coefficient poly),
                                          IsOrderedPolynomial poly,
                                          IsMonomialOrder (Arity poly) ord)
                                      => ord -> Ideal poly -> [poly]
calcHomogeneousGroebnerBasisHilbertBy ord is =
  calcHomogeneousGroebnerBasisHilbertWithSeries is (hilbertPoincareSeriesBy ord is)

-- | Calculates homogeneous Groebner basis by Hilbert-driven method,
--   computing Hilbert-Poincare series w.r.t. Grevlex.
calcHomogeneousGroebnerBasisHilbert :: (Field (Coefficient poly),
                                        IsOrderedPolynomial poly)
                                    => Ideal poly -> [poly]
calcHomogeneousGroebnerBasisHilbert = calcHomogeneousGroebnerBasisHilbertBy Grevlex
