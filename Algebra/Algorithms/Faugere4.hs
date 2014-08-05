{-# LANGUAGE ConstraintKinds, DataKinds, FlexibleContexts                   #-}
{-# LANGUAGE FlexibleInstances, GADTs, MultiParamTypeClasses                #-}
{-# LANGUAGE NoImplicitPrelude, NoMonomorphismRestriction, ParallelListComp #-}
{-# LANGUAGE QuasiQuotes, RankNTypes, ScopedTypeVariables, TemplateHaskell  #-}
{-# LANGUAGE TypeFamilies, TypeOperators, ViewPatterns                      #-}
{-# OPTIONS_GHC -fno-warn-type-defaults -fno-warn-orphans #-}
module Algebra.Algorithms.Faugere4 where
import qualified Algebra.LinkedMatrix    as LM
import           Algebra.Matrix          hiding (trace)
import qualified Algebra.Repa            as Repa
import           Algebra.Ring.Ideal
import           Algebra.Ring.Polynomial
import           Algebra.Wrapped
import           Control.Arrow
import           Control.Monad.Identity
import           Control.Parallel
import qualified Data.Array.Repa         as Repa
import qualified Data.Array.Repa.Eval    as Repa
import           Data.Function
import qualified Data.HashSet            as S
import           Data.List
import qualified Data.Matrix             as DM
import           Data.Maybe
import           Data.Proxy              (Proxy)
import           Data.Type.Natural       hiding (one, zero)
import qualified Data.Vector             as V
import           Data.Vector.Sized       (Vector ((:-), Nil))
import qualified Data.Vector.Sized       as SV
import           Debug.Trace
import           Numeric.Algebra         hiding (sum, (<), (>), (\\))
import qualified Numeric.Algebra         as NA
import           Numeric.Decidable.Zero  (isZero)
import           Numeric.Field.Fraction  (Fraction)
import           Prelude                 hiding (Num (..), recip, subtract, (/),
                                          (^))
import           Prelude                 (Num ())
import qualified Prelude                 as P

tr :: Show a => String -> a -> a
tr lab a = trace (lab ++ ": " ++ show a) a

data Pair r ord n = Pair { lcmPair    :: OrderedMonomial ord n
                         , leftMonom  :: OrderedMonomial ord n
                         , leftPoly   :: OrderedPolynomial r ord n
                         , rightMonom :: OrderedMonomial ord n
                         , rightPoly  :: OrderedPolynomial r ord n
                         } deriving (Show, Eq, Ord)
type Strategy r ord n = [Pair r ord n] -> [Pair r ord n]

faugere4 :: (Show r, Normed r, Field r, Fractional r, IsMonomialOrder ord, IsPolynomial r n,
             Repa.Elt r, Repa.Target (Repa.DefVec r) r, Repa.Source (Repa.DefVec r) r)
         => Strategy r ord n -> Ideal (OrderedPolynomial r ord n)
         -> Ideal (OrderedPolynomial r ord n)
faugere4 sel (generators -> fs) = {-# SCC "F_4" #-}
  let (gs0, ps0) = foldl' (uncurry update) ([], []) fs
  in go gs0 ps0 []
  where
    go gs ps fds
      | null ps   = toIdeal gs
      | otherwise =
        let pd   = sel ps
            ps'  = ps \\ pd
            ls   = map leftP pd ++ map rightP pd
            (fdp, fd) = redF4 ls gs fds
            (gs2, ps2) = foldl' (uncurry update) (gs, ps') fdp
        in go gs2 ps2 (fd:fds)

leftP, rightP :: Pair r ord n -> (OrderedMonomial ord n, OrderedPolynomial r ord n)
leftP  = leftMonom &&& leftPoly
rightP = rightMonom &&& rightPoly

degPair :: Pair r ord n -> Int
degPair = totalDegree . lcmPair

mkPair :: (IsPolynomial r n, IsMonomialOrder ord)
       => OrderedPolynomial r ord n -> OrderedPolynomial r ord n -> Pair r ord n
mkPair f g =
  let f0  = leadingMonomial f
      g0  = leadingMonomial g
      lij = lcmMonomial f0 g0
      ti  = lij / f0
      tj  = lij / g0
  in Pair lij ti f tj g

redF4 :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Field r, Normed r,
          Fractional r, Repa.Elt r, Repa.Target (Repa.DefVec r) r, Repa.Source (Repa.DefVec r) r)
      => [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
      -> [OrderedPolynomial r ord n]
      -> [[OrderedPolynomial r ord n]]
      -> ([OrderedPolynomial r ord n], [OrderedPolynomial r ord n])
redF4 ls gs fss = {-# SCC "reduction" #-}
  let fs  = symbolicPP ls gs fss
      fs' = rowEchelon fs
  in ([ f | f <- fs', not $ leadingMonomial f `elem` map leadingMonomial fs], fs)

polysToMatrix :: (IsMonomialOrder ord, IsPolynomial r n, Num r, Repa.Target (Repa.DefVec r) r)
          => [OrderedPolynomial r ord n] -> (Repa.Matrix r, [OrderedMonomial ord n])
polysToMatrix fs =
  let ts  = nub $ sortBy (flip compare) $ concatMap monomials fs
  in (Repa.fromLists $ map (\f -> map (\t -> coeff t f) ts) fs, ts)

matToPolysWith :: (IsMonomialOrder ord, IsPolynomial r n, Num r, Repa.Source (Repa.DefVec r) r, Repa.Target (Repa.DefVec r) r)
            => [OrderedMonomial ord n] -> Repa.Matrix r -> [OrderedPolynomial r ord n]
matToPolysWith ts mat =
  map (NA.sum . zipWith (flip $ curry toPolynomial) ts . V.toList) $ Repa.toRows mat

rowEchelon :: forall r ord n. (IsPolynomial r n, IsMonomialOrder ord, Field r, Num r,
                               Normed r, Repa.Elt r, Repa.Target (Repa.DefVec r) r,
                               Repa.Source (Repa.DefVec r) r, Fractional r)
           => [OrderedPolynomial r ord n]
           -> [OrderedPolynomial r ord n]
rowEchelon fs = {-# SCC "rowEchelon" #-}
  let (mf, ts) = {-# SCC "buildMatrix" #-} polysToMatrix fs
      mf' = matToPolysWith ts $ fst $ {-# SCC "eche/red" #-} runIdentity $ Repa.gaussReductionP mf
  in nub mf' \\ [0]

symbolicPP :: forall r ord n. (Show r, IsPolynomial r n, IsMonomialOrder ord, Field r, Num r,
                               Normed r, Fractional r, Repa.Elt r,
                               Repa.Target (Repa.DefVec r) r, Repa.Source (Repa.DefVec r) r)
           => [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
           -> [OrderedPolynomial r ord n]
           -> [[OrderedPolynomial r ord n]]
           -> [OrderedPolynomial r ord n]
symbolicPP ls gs fss = {-# SCC "symbolicPP" #-}
  let fs0 = map mul ls
  in go fs0 (S.fromList $ concatMap monomials fs0) (S.fromList $ map leadingMonomial fs0)
  where
    mul = uncurry (>*) . uncurry (simplify fss)
    go fs ts done
      | S.null (ts `S.difference` done) = fs
      | otherwise =
        let m = head $ S.toList $ ts `S.difference` done
            done' = S.insert m done
            ts'   = S.delete m ts
        in case find (\f -> leadingMonomial f `divs` m) gs of
          Just f -> let m' = m / leadingMonomial f
                        f' = mul (m', f)
                        ts'' = S.fromList (monomials f') `S.difference` done'
                    in go (f' : fs) (ts' `S.union` ts'') done'
          Nothing -> go fs ts' done'

optimalStrategy :: Strategy r ord n
optimalStrategy ps =
  let d = minimum $ map degPair ps
  in filter ((==d) . degPair) ps

sugarStrategy :: (DecidableZero r, SingI n, IsOrder ord, Ring r) => Strategy r ord n
sugarStrategy ps =
  let d = minimum $ map calcSug ps
  in filter ((==d) . calcSug) ps

calcSug :: (DecidableZero r, Ring r, SingI n, IsOrder ord) => Pair r ord n -> Int
calcSug p =
  let f = leftPoly p
      g = rightPoly p
      deg' = maximum . map (totalDegree . snd) . getTerms
      tsgr h = deg' h - totalDegree (leadingMonomial h)
      sugar = P.max (tsgr f) (tsgr g) + totalDegree (lcmMonomial (leadingMonomial f) (leadingMonomial g))
  in sugar

combinationsWith :: (a -> a -> b) -> [a] -> [b]
combinationsWith f xs = concat $ zipWith (map . f) xs $ drop 1 $ tails xs

notDivs :: OrderedMonomial ord n -> OrderedMonomial ord n -> Bool
notDivs = (not .) . divs

update :: (IsPolynomial r n, IsMonomialOrder ord)
       => [OrderedPolynomial r ord n] -> [Pair r ord n] -> OrderedPolynomial r ord n
       -> ([OrderedPolynomial r ord n], [Pair r ord n])
update gs bs h = {-# SCC "update" #-}
  let cs = map (mkPair h) gs
      dsStep ds0 [] = ds0
      dsStep ds0 (p:cs0) =
        let cond1 = isRelativelyPrime (leadingMonomial $ leftPoly p) (leadingMonomial $ rightPoly p)
            cond2 = all (\q -> lcmPair q `notDivs` lcmPair p) cs0
                 && all (\q -> lcmPair q `notDivs` lcmPair p) ds0
        in if cond1 || cond2 then p:ds0 else ds0
      ds = foldl' dsStep [] $ init $ tails cs
      es = [ p
           | p <- ds
           , not $ isRelativelyPrime (leadingMonomial $ leftPoly p) (leadingMonomial $ rightPoly p)
           ]
      bs' = [p | p <- bs
               , let l = lcmPair p
               , or [leadingMonomial h `notDivs` lcmPair p
                    ,lcmMonomial (leadingMonomial $ leftPoly p) (leadingMonomial h) == l
                    ,lcmMonomial (leadingMonomial h) (leadingMonomial $ rightPoly p) == l
                    ]
               ]
      gs' = [g | g <- gs, leadingMonomial h `notDivs` leadingMonomial g ]
  in (es `par` bs' `par` gs') `pseq` (h : gs', bs' ++ es)

cyclic :: (SingI n)
       => SNat n -> Ideal (Polynomial (Fraction Integer) n)
cyclic sn =
  let vars = genVars sn
      cycs = tails $ cycle vars
      arity = sNatToInt sn
  in toIdeal $ NA.product vars - one : [ NA.sum $ map (NA.product . take i) $ take arity cycs | i <- [arity - 1,arity-2..1]]

simplify :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Normed r, Field r, Num r,
             Fractional r, Repa.Elt r, Repa.Target (Repa.DefVec r) r, Repa.Source (Repa.DefVec r) r)
         => [[OrderedPolynomial r ord n]]
         -> OrderedMonomial ord n -> OrderedPolynomial r ord n
         -> (OrderedMonomial ord n, OrderedPolynomial r ord n)
simplify fss t f = go $ divisors t
  where
    go []       = (t, f)
    go (u : us) =
      case find (u >* f `elem`) fss of
        Nothing -> go us
        Just fs ->
          let fs' = rowEchelon fs
              Just p = find (\g -> leadingMonomial g == leadingMonomial (u >* f)) fs'
          in if u /= t
             then simplify fss (t/u) p
             else (one, p)

divisors :: (SingI n, IsOrder ord) => OrderedMonomial ord n -> [OrderedMonomial ord n]
divisors t = [om
             | m <- sequenceSV (SV.map (enumFromTo 0) $ getMonomial t)
             , let om = OrderedMonomial m
             , om /= one
             ]

sequenceSV :: SV.Vector [a] n -> [SV.Vector a n]
sequenceSV Nil = [Nil]
sequenceSV (xs :- xss) = concatMap (\x -> map (x :-) $ sequenceSV xss) xs

simplifyG :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Elem mat r,
              Matrix mat, Normed r, Commutative r, Field r)
         => Proxy mat -> [[OrderedPolynomial r ord n]]
         -> OrderedMonomial ord n -> OrderedPolynomial r ord n
         -> (OrderedMonomial ord n, OrderedPolynomial r ord n)
simplifyG pxy fss t f = go $ divisors t
  where
    go []       = (t, f)
    go (u : us) =
      case find (u >* f `elem`) fss of
        Nothing -> go us
        Just fs ->
          let fs' = rowEchelonG pxy fs
              Just p = find (\g -> leadingMonomial g == leadingMonomial (u >* f)) fs'
          in if u /= t
             then simplifyG pxy fss (t/u) p
             else (one, p)

rowEchelonG :: (IsPolynomial r n, IsMonomialOrder ord, Matrix mat, Normed r,
                DecidableZero r, Elem mat r, Commutative r, Field r)
           => Proxy mat -> [OrderedPolynomial r ord n]
           -> [OrderedPolynomial r ord n]
rowEchelonG pxy fs = {-# SCC "rowEchelon" #-}
  let (mf, ts) = {-# SCC "buildMatrix" #-} polysToMatrixG fs
      mf' = matToPolysWithG pxy ts $ fst $ {-# SCC "eche/red" #-} gaussReduction mf
  in filter (not . isZero) $ nub mf'

polysToMatrixG :: (Matrix mat, IsMonomialOrder ord, IsPolynomial r n, Elem mat r)
          => [OrderedPolynomial r ord n] -> (mat r, [OrderedMonomial ord n])
polysToMatrixG fs =
  let ts  = nub $ sortBy (flip compare) $ concatMap monomials fs
  in (fromLists $ map (\f -> map (\t -> coeff t f) ts) fs, ts)

matToPolysWithG :: (IsMonomialOrder ord, IsPolynomial r n, Matrix mat, Elem mat r)
            => Proxy mat -> [OrderedMonomial ord n] -> mat r -> [OrderedPolynomial r ord n]
matToPolysWithG _ ts mat =
  map (NA.sum . zipWith (flip $ curry toPolynomial) ts . V.toList) $ toRows mat

symbolicPPG :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Field r, Num r,
                Normed r, Fractional r, Matrix mat, Elem mat r)
           => Proxy mat -> [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
           -> [OrderedPolynomial r ord n]
           -> [[OrderedPolynomial r ord n]]
           -> [OrderedPolynomial r ord n]
symbolicPPG pxy ls gs fss = {-# SCC "symbolicPP" #-}
  let fs0 = map mul ls
  in go fs0 (S.fromList $ concatMap monomials fs0) (S.fromList $ map leadingMonomial fs0)
  where
    mul = uncurry (>*) . uncurry (simplifyG pxy fss)
    go fs ts done
      | S.null (ts `S.difference` done) = fs
      | otherwise =
        let m = head $ S.toList $ ts `S.difference` done
            done' = S.insert m done
            ts'   = S.delete m ts
        in case find (\f -> leadingMonomial f `divs` m) gs of
          Just f -> let m' = m / leadingMonomial f
                        f' = mul (m', f)
                        ts'' = S.fromList (monomials f') `S.difference` done'
                    in go (f' : fs) (ts' `S.union` ts'') done'
          Nothing -> go fs ts' done'

faugere4G :: (Show r, Normed r, Field r, Fractional r, IsMonomialOrder ord, IsPolynomial r n,
              Matrix mat, Elem mat r)
         => Proxy mat -> Strategy r ord n -> Ideal (OrderedPolynomial r ord n)
         -> Ideal (OrderedPolynomial r ord n)
faugere4G pxy sel (generators -> fs) = {-# SCC "F_4" #-}
  let (gs0, ps0) = foldl' (uncurry update) ([], []) fs
  in go gs0 ps0 []
  where
    go gs ps fds
      | null ps   = toIdeal gs
      | otherwise =
        let pd   = sel ps
            ps'  = ps \\ pd
            ls   = map leftP pd ++ map rightP pd
            (fdp, fd) = redF4G pxy ls gs fds
            (gs2, ps2) = foldl' (uncurry update) (gs, ps') fdp
        in go gs2 ps2 (fd:fds)

redF4G :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Normed r,
           Elem mat r, Matrix mat, Commutative r, Field r, Num r, Fractional r)
      => Proxy mat -> [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
      -> [OrderedPolynomial r ord n]
      -> [[OrderedPolynomial r ord n]]
      -> ([OrderedPolynomial r ord n], [OrderedPolynomial r ord n])
redF4G pxy ls gs fss = {-# SCC "reduction" #-}
  let fs  = symbolicPPG pxy ls gs fss
      fs' = rowEchelonG pxy fs
  in ([ f | f <- fs', not $ leadingMonomial f `elem` map leadingMonomial fs], fs)

-- Structured

simplifyLM :: (Show r, IsPolynomial r n, IsMonomialOrder ord,
              Normed r, Commutative r, Field r)
         => [[OrderedPolynomial r ord n]]
         -> OrderedMonomial ord n -> OrderedPolynomial r ord n
         -> (OrderedMonomial ord n, OrderedPolynomial r ord n)
simplifyLM fss t f = go $ divisors t
  where
    go []       = (t, f)
    go (u : us) =
      case find (u >* f `elem`) fss of
        Nothing -> go us
        Just fs ->
          let fs' = rowEchelonLM fs
              Just p = find (\g -> leadingMonomial g == leadingMonomial (u >* f)) fs'
          in if u /= t
             then simplifyLM fss (t/u) p
             else (one, p)

rowEchelonLM :: (IsPolynomial r n, IsMonomialOrder ord, Normed r,Show r,
                DecidableZero r, Division r, Commutative r, Field r)
           => [OrderedPolynomial r ord n]
           -> [OrderedPolynomial r ord n]
rowEchelonLM fs = {-# SCC "rowEchelon" #-}
  let (mf, ts) = {-# SCC "buildMatrix" #-} polysToMatrixLM fs
      mf' = matToPolysWithLM ts $ fst $ {-# SCC "eche/red" #-} LM.structuredGauss mf
  in filter (not . isZero) $ nub mf'

trM :: (Show a, Monoidal a) => String -> LM.Matrix a -> LM.Matrix a
trM str mat = trace (str ++ ": " ++ show (LM.toList mat)) $ mat

polysToMatrixLM :: (IsMonomialOrder ord, IsPolynomial r n)
          => [OrderedPolynomial r ord n] -> (LM.Matrix r, [OrderedMonomial ord n])
polysToMatrixLM fs =
  let ts  = nub $ sortBy (flip compare) $ concatMap monomials fs
  in (fromLists $ map (\f -> map (\t -> coeff t f) ts) fs, ts)

matToPolysWithLM :: (IsMonomialOrder ord, IsPolynomial r n)
            => [OrderedMonomial ord n] -> LM.Matrix r -> [OrderedPolynomial r ord n]
matToPolysWithLM ts mat =
  map (NA.sum . zipWith (flip $ curry toPolynomial) ts . V.toList) $ toRows mat

symbolicPPLM :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Field r, Num r,
                Normed r, Division r)
           => [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
           -> [OrderedPolynomial r ord n]
           -> [[OrderedPolynomial r ord n]]
           -> [OrderedPolynomial r ord n]
symbolicPPLM ls gs fss = {-# SCC "symbolicPP" #-}
  let fs0 = map mul ls
  in go fs0 (S.fromList $ concatMap monomials fs0) (S.fromList $ map leadingMonomial fs0)
  where
    mul = uncurry (>*) . uncurry (simplifyLM fss)
    go fs ts done
      | S.null (ts `S.difference` done) = fs
      | otherwise =
        let m = head $ S.toList $ ts `S.difference` done
            done' = S.insert m done
            ts'   = S.delete m ts
        in case find (\f -> leadingMonomial f `divs` m) gs of
          Just f -> let m' = m / leadingMonomial f
                        f' = mul (m', f)
                        ts'' = S.fromList (monomials f') `S.difference` done'
                    in go (f' : fs) (ts' `S.union` ts'') done'
          Nothing -> go fs ts' done'

faugere4LM :: (Show r, Normed r, Field r, Fractional r, IsMonomialOrder ord, IsPolynomial r n)
         => Strategy r ord n -> Ideal (OrderedPolynomial r ord n)
         -> Ideal (OrderedPolynomial r ord n)
faugere4LM sel (generators -> fs) = {-# SCC "F_4" #-}
  let (gs0, ps0) = foldl' (uncurry update) ([], []) fs
  in go gs0 ps0 []
  where
    go gs ps fds
      | null ps   = toIdeal gs
      | otherwise =
        let pd   = sel ps
            ps'  = ps \\ pd
            ls   = map leftP pd ++ map rightP pd
            (fdp, fd) = redF4LM ls gs fds
            (gs2, ps2) = foldl' (uncurry update) (gs, ps') fdp
        in go gs2 ps2 (fd:fds)

redF4LM :: (Show r, IsPolynomial r n, IsMonomialOrder ord, Normed r,
            Commutative r, Field r, Num r, Fractional r)
      => [(OrderedMonomial ord n, OrderedPolynomial r ord n)]
      -> [OrderedPolynomial r ord n]
      -> [[OrderedPolynomial r ord n]]
      -> ([OrderedPolynomial r ord n], [OrderedPolynomial r ord n])
redF4LM ls gs fss = {-# SCC "reduction" #-}
  let fs  = symbolicPPLM ls gs fss
      fs' = rowEchelonLM fs
  in ([ f | f <- fs', not $ leadingMonomial f `elem` map leadingMonomial fs], fs)

