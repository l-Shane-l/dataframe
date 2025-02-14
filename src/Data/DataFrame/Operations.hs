{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
module Data.DataFrame.Operations (
    addColumn,
    addColumnWithDefault,
    dimensions,
    columnNames,
    getColumn,
    getIntColumn,
    getIndexedColumn,
    apply,
    applyMany,
    applyWhere,
    applyAtIndex,
    applyInt,
    applyDouble,
    take,
    sum,
    sumWhere,
    filter,
    valueCounts,
    select,
    dropColumns,
    groupBy,
    reduceBy,
    columnSize,
    combine,
    parseDefaults,
    sortBy,
    SortOrder(..),
    columnInfo
) where

import Data.DataFrame.Internal ( Column(..), DataFrame(..), transformColumn )
import Data.Function (on)
import Data.Typeable (Typeable)
import Data.Type.Equality
    ( type (:~:)(Refl), TestEquality(testEquality) )
import Type.Reflection ( Typeable, TypeRep, typeRep, typeOf )
import Data.Vector (Vector)
import Prelude hiding (take, sum, filter)
import qualified Prelude as P

import qualified Data.ByteString.Char8 as C
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Map.Strict as MS
import qualified Data.Set as S
import qualified Data.Vector as V
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.DataFrame.Internal as DI
import Data.DataFrame.Util
    ( columnNotFound, typeMismatchError, inferType, getIndices, appendWithFrontMin, addCallPointInfo )
import Text.Read (readMaybe)
import GHC.Stack (HasCallStack)
import Data.ByteString.Lex.Fractional (readDecimal)


addColumn :: forall a. (Typeable a, Show a)
          => C.ByteString      -- Column Name
          -> V.Vector a        -- Data to add to column
          -> DataFrame         -- DataFrame to add to column
          -> DataFrame
addColumn name xs d = d {
           columns = MS.insert name (MkColumn xs) (columns d),
           _columnNames = if name `elem` _columnNames d
                            then _columnNames d
                          else _columnNames d ++ [name] }

addColumnWithDefault :: forall a. (Typeable a, Show a)
          => a          -- Default Value
          -> C.ByteString     -- Column name
          -> V.Vector a -- Data to add to column
          -> DataFrame  -- DataFrame to add to column
          -> DataFrame
addColumnWithDefault defaultValue name xs d = let
        (rows, _) = dimensions d
        values = xs V.++ V.fromList (repeat defaultValue)
    in addColumn name (V.take rows values) d

getColumn' :: forall a. (Typeable a, Show a)
          => Maybe C.ByteString -- Call point
          -> C.ByteString     -- Column Name
          -> DataFrame  -- DataFrame to get column from
          -> Vector a
getColumn' callPoint name d = case name `MS.lookup` columns d of
    Nothing -> error $ columnNotFound name
                                     (fromMaybe "getColumn" callPoint)
                                     (columnNames d)
    Just c@(MkColumn (column :: Vector b)) -> case DI.fetchColumn @a c of
                                                Left err -> error $ addCallPointInfo name callPoint err
                                                Right cs -> cs

getColumn :: forall a. (Typeable a, Show a)
          => C.ByteString     -- Column Name
          -> DataFrame        -- DataFrame to get column from
          -> Vector a
getColumn = getColumn' Nothing

getIntColumn :: C.ByteString -> DataFrame -> Vector Int
getIntColumn = getColumn' Nothing

getIndexedColumn :: forall a . (Typeable a, Show a) => C.ByteString -> DataFrame -> Vector (Int, a)
getIndexedColumn columnName df = V.indexed (getColumn columnName df)

apply :: forall b c. (Typeable b, Typeable c, Show b, Show c)
      => C.ByteString   -- Column name
      -> (b -> c)       -- function to apply
      -> DataFrame      -- DataFrame to apply operation to
      -> DataFrame
apply columnName f d =
    d { columns = MS.alter alteration columnName (columns d) }
    where
        alteration :: Maybe Column -> Maybe Column
        alteration c' = case c' of
            Nothing -> error $ columnNotFound columnName "apply" (columnNames d)
            Just column'  -> case transformColumn (V.map f) column' of
                                Left err -> error $ addCallPointInfo columnName (Just "apply") err
                                Right cs -> Just cs

applyMany :: (Typeable b, Typeable c, Show b, Show c)
          => [C.ByteString]
          -> (b -> c)
          -> DataFrame
          -> DataFrame
applyMany names f df = L.foldl' (\d name -> apply name f d) df names

applyInt :: (Typeable b, Show b)
         => C.ByteString       -- Column name
         -> (Int -> b)   -- function to apply
         -> DataFrame    -- DataFrame to apply operation to
         -> DataFrame
applyInt = apply

applyDouble :: (Typeable b, Show b)
            => C.ByteString          -- Column name
            -> (Double -> b)   -- function to apply
            -> DataFrame       -- DataFrame to apply operation to
            -> DataFrame
applyDouble = apply

applyWhere :: forall a b c. (Typeable a, Typeable b, Show a, Show b)
           => C.ByteString      -- Criterion Column
           -> (a -> Bool) -- Filter condition
           -> C.ByteString      -- Column name
           -> (b -> b)    -- function to apply
           -> DataFrame   -- DataFrame to apply operation to
           -> DataFrame
applyWhere filterColumnName condition columnName f df = let
        filterColumn = getIndexedColumn filterColumnName df
        indexes = V.map fst $ V.filter (condition . snd) filterColumn
    in if V.null indexes
       then df
       else L.foldl' (\d i -> applyAtIndex i columnName f d) df indexes

applyAtIndex :: forall a. (Typeable a, Show a)
           => Int         -- Index
           -> C.ByteString      -- Column name
           -> (a -> a)    -- function to apply
           -> DataFrame   -- DataFrame to apply operation to
           -> DataFrame
applyAtIndex i columnName f df = let
                valueColumn = getIndexedColumn columnName df
                updated = V.map (\(index, value) -> if index == i then f value else value) valueColumn
            in update columnName updated df

-- Take the first n rows of a DataFrame.
take :: Int -> DataFrame -> DataFrame
take n d = d { columns = MS.map
                       (\(MkColumn column') -> MkColumn (V.take n column')) (columns d) }

-- Get DataFrame dimensions.
dimensions :: DataFrame -> (Int, Int)
dimensions d = (numRows, numColumns)
    where columnSize (MkColumn column') = V.length column'
          numRows = L.foldl' (flip (max . columnSize . snd)) 0 (MS.toList (columns d))
          numColumns = MS.size $ columns d

-- Get column names of the DataFrame in order of insertion.
columnNames :: DataFrame -> [C.ByteString]
columnNames = _columnNames

sum :: (Typeable a, Show a, Ord a, Num a) => C.ByteString -> DataFrame -> a
sum name df = V.sum $ getColumn' (Just "sum") name df

sumWhere :: (Typeable a, Show a, Typeable b, Show b, Num b)
         => C.ByteString
         -> (a -> Bool)
         -> C.ByteString
         -> DataFrame
         -> b
sumWhere filterColumnName condition columnName df = let
            filterColumn = getIndexedColumn filterColumnName df
            indexes = S.fromList $ V.toList $ V.map fst $ V.filter (condition . snd) filterColumn
        in if indexes == S.empty
           then 0
           else V.sum $ V.ifilter (\i v -> i `S.member` indexes) $ getColumn' (Just "sum") columnName df

filter :: forall a . (Typeable a, Show a)
            => C.ByteString
            -> (a -> Bool)
            -> DataFrame
            -> DataFrame
filter filterColumnName condition df = let
        filterColumn = getIndexedColumn filterColumnName df
        indexes = S.fromList $ V.toList $ V.map fst $ V.filter (condition . snd) filterColumn
        f k c@(MkColumn (column :: Vector b)) = case DI.fetchColumn @b c of
                                                Right cs -> MkColumn $ V.ifilter (\i v -> i `S.member` indexes) cs
                                                Left err -> error $ addCallPointInfo k (Just "filter") err
    in df { columns = MS.mapWithKey f (columns df) }

data SortOrder = Ascending | Descending deriving (Eq)

sortBy ::forall a . (Typeable a, Show a, Ord a)
       => C.ByteString
       -> SortOrder
       -> DataFrame
       -> DataFrame
sortBy sortColumnName order df = let
        sortColumn = getIndexedColumn @a sortColumnName df
        sortOrder = if order == Ascending then compare else flip compare
        indices = map fst $ L.sortBy (sortOrder `on` snd) $ V.toList sortColumn
        f (MkColumn (column :: Vector b)) = MkColumn $ indices `getIndices` column
    in df { columns = MS.map f (columns df) }

columnSize :: C.ByteString -> DataFrame -> Int
columnSize name df = case name `MS.lookup` columns df of
                        Nothing -> error $ columnNotFound name "apply" (columnNames df)
                        Just (MkColumn (column' :: Vector a))  -> V.length column'

valueCounts :: forall a . (Typeable a, Show a) => C.ByteString -> DataFrame -> [(a, Integer)]
valueCounts columnName df = let
        column = L.sortBy (compare `on` snd) $ V.toList $ V.map (\v -> (v, show v)) (getColumn' @a (Just "valueCounts") columnName df)
    in map (\xs -> (fst (head xs), fromIntegral $ length xs)) (L.groupBy ((==) `on` snd) column)

select :: [C.ByteString]
              -> DataFrame
              -> DataFrame
select cs df
    | not $ any (`elem` columnNames df) cs = error $ columnNotFound (C.pack $ show $ cs L.\\ columnNames df) "select" (columnNames df)
    | otherwise = L.foldl' addKeyValue DI.empty cs
            where addKeyValue d k = d { columns = MS.insert k (columns df MS.! k) (columns d),
                                        _columnNames = _columnNames d ++ [k] }

dropColumns :: [C.ByteString]
            -> DataFrame
            -> DataFrame
dropColumns cs df = let
        keysToKeep = columnNames df L.\\ cs
    in select keysToKeep df


groupBy :: [C.ByteString]
        -> DataFrame
        -> DataFrame
groupBy names df
    | not $ any (`elem` columnNames df) names = error $ columnNotFound (C.pack $ show $ names L.\\ columnNames df) "groupBy" (columnNames df)
    | otherwise = L.foldl' addColumns initDf groupingColumns
            where -- Create a string representation of each row.
                  values = V.map (mkRowRep df (S.fromList names)) (V.generate (fst (dimensions df) - 1) id)
                  -- Create a mapping from the row representation to the list of indices that
                  -- have that row representation. This will allow us to combine the indexes
                  -- where the rows are the same.
                  valueIndices = V.ifoldl' (\m index rowRep -> MS.insertWith (appendWithFrontMin . head) rowRep [index] m) M.empty values
                  -- Since the min is at the head this allows us to get the min in constant time and sort by it
                  -- That way we can recover the original order of the rows.
                  valueIndicesInitOrder = L.sortBy (compare `on` (head . snd)) $! MS.toList valueIndices
                  -- For the ungrouped columns these will be the indexes to get for each row.
                  -- We rely on this list being in the same order as the rows.
                  indices = map snd valueIndicesInitOrder
                  -- These are the indexes of the grouping/key rows i.e the minimum elements
                  -- of the list.
                  keyIndices = map (head . snd) valueIndicesInitOrder
                  -- this will be our main worker function in the fold that takes all
                  -- indices and replaces each value in a column with a list of
                  -- the elements with the indices where the grouped row
                  -- values are the same.
                  addColumns = groupColumns indices df
                  -- Out initial DF will just be all the grouped rows added to an
                  -- empty dataframe. The entries are dedued and are in their
                  -- initial order.
                  initDf = L.foldl' (mkGroupedColumns keyIndices df) DI.empty names
                  -- All the rest of the columns that we are grouping by.
                  groupingColumns = columnNames df L.\\ names

mkRowRep :: DataFrame -> S.Set C.ByteString -> Int -> String
mkRowRep df names i = MS.foldlWithKey go "" (columns df)
    where go acc k (MkColumn c) =
            if S.notMember k names
            then acc
            else case c V.!? i of
                Just e -> acc ++ show e
                Nothing -> error $ "Column " ++ C.unpack k ++
                                    " has less items than " ++
                                    "the other columns."

mkGroupedColumns :: [Int] -> DataFrame -> DataFrame -> C.ByteString -> DataFrame
mkGroupedColumns indices df acc name
    = case (MS.!) (columns df) name of
        (MkColumn column) ->
            let
                vs = indices `getIndices` column
            in addColumn name vs acc

groupColumns :: [[Int]] -> DataFrame -> DataFrame -> C.ByteString -> DataFrame
groupColumns indices df acc name
    = case (MS.!) (columns df) name of
        (MkColumn column) ->
            let
                vs = V.fromList $ map (`getIndices` column) indices
            in addColumn name vs acc

reduceBy :: (Typeable a, Show a, Typeable b, Show b)
         => C.ByteString
         -> (Vector a -> b)
         -> DataFrame
         -> DataFrame
reduceBy = apply

combine :: forall a b c . (Typeable a, Show a, Typeable b, Show b, Typeable c, Show c)
        => C.ByteString
        -> C.ByteString
        -> (a -> b -> c)
        -> DataFrame
        -> V.Vector c
combine firstColumn secondColumn f df = V.zipWith f (getColumn' @a (Just "combine") firstColumn df)
                                                    (getColumn' @b (Just "combine") secondColumn df)

-- Since this potentially changes the length of a column and could break other operations e.g
-- groupBy and filter we do not (and should not) export it.
update :: forall a b. (Typeable a, Show a)
       => C.ByteString
       -> V.Vector a
       -> DataFrame
       -> DataFrame
update name xs df = df {columns = MS.adjust (const (MkColumn xs)) name (columns df)}

parseDefaults :: Bool -> DataFrame -> DataFrame
parseDefaults safeRead df = df { columns = MS.map (parseDefault safeRead) (columns df) }

parseDefault :: Bool -> Column -> Column
parseDefault safeRead (MkColumn (c :: V.Vector a)) = let
        repa :: Type.Reflection.TypeRep a = Type.Reflection.typeRep @a
        repByteString :: Type.Reflection.TypeRep C.ByteString = Type.Reflection.typeRep @C.ByteString
        emptyToNothing v = if v == C.empty || v == " " then Nothing else Just v
    in case repa `testEquality` repByteString of
        Nothing -> MkColumn c
        Just Refl -> let
                example = C.strip (V.head c)
            in case C.readInt example of
                Just (v, "") -> let
                        safeVector = V.map (fmap fst . (=<<) C.readInt . emptyToNothing) c
                        hasNulls = V.length (V.filter isNothing safeVector) > 0
                    in (if safeRead && hasNulls then MkColumn safeVector else MkColumn (V.map (fst . fromMaybe (0, ""). C.readInt) c))
                Just _ -> let
                        safeVector = V.map ((=<<) readDouble . emptyToNothing) c
                        hasNulls = V.length (V.filter isNothing safeVector) > 0
                    in if safeRead && hasNulls then MkColumn safeVector else MkColumn (V.map (fromMaybe 0 . readDouble) c)
                Nothing -> case readDouble example of
                    Just _ -> let
                            safeVector = V.map ((=<<) readDouble . emptyToNothing) c
                            hasNulls = V.length (V.filter isNothing safeVector) > 0
                        in if safeRead && hasNulls then MkColumn safeVector else MkColumn (V.map (fromMaybe 0 . readDouble) c)
                    Nothing -> MkColumn c

-- TODO: This is duplicated from the IO file. Refactor these into
-- A common file for type conversions.
readDouble :: HasCallStack => C.ByteString -> Maybe Double
readDouble s = let
        isNegative = (not (C.null s) && (C.head s == '-'))
    in case readDecimal (if isNegative then C.tail s else s) of
            Nothing -> Nothing
            Just(value, _) -> Just $ (if isNegative then -1.0 else 1.0) * value


columnInfo :: DataFrame -> [(String, Int)]
columnInfo df = L.sortBy (compare `on` snd) (MS.foldlWithKey go [] (columns df))
    where go acc k (MkColumn (c :: Vector a)) = (C.unpack k, V.length $ V.filter ((/=) "Nothing" . show) c) : acc
