{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE FlexibleInstances  #-}

module Database.Neo4j.Batch.Types where

import Control.Exception.Base (throw)
import Data.Aeson ((.=), (.:))
import Control.Monad.State (state, State, runState)

import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import qualified Network.HTTP.Types as HT

import Database.Neo4j.Graph
import Database.Neo4j.Http
import Database.Neo4j.Types

newtype BatchFuture a = BatchFuture Int

type CmdParser = J.Value -> Graph -> Graph

data BatchCmd = BatchCmd {cmdMethod :: HT.Method, cmdPath ::T.Text, cmdBody :: J.Value,
                            cmdParse :: CmdParser, cmdId :: Int}

defCmd :: BatchCmd
defCmd = BatchCmd{cmdMethod = HT.methodGet, cmdPath = "", cmdBody = "", cmdParse = \_ g -> g, cmdId = -1}

data BatchState = BatchState {commands :: [BatchCmd], batchId :: Int}

type Batch a = State BatchState (BatchFuture a)

getCmds :: Batch a -> [BatchCmd]
getCmds s = let (_, BatchState cmds _) = runState s (BatchState [] (-1)) in reverse cmds

instance J.ToJSON (Batch a) where
    toJSON b = J.toJSON $ getCmds b

instance J.ToJSON BatchCmd where
    toJSON (BatchCmd m p b _ cId) = J.object ["method" .= TE.decodeUtf8 m, "to" .= p, "body" .= b, "id" .= cId]

tryParse :: J.FromJSON a => J.Value -> a
tryParse (J.Object jb) = let res = flip JT.parseEither jb $ \obj -> (obj .: "body") >>= J.parseJSON
               in case res of
                     Right entity -> entity
                     Left e -> throw $ Neo4jParseException ("Error parsing entity: " ++ e)
tryParse _ = throw $ Neo4jParseException "Error expecting an object"

nextState :: BatchCmd -> Batch a
nextState cmd = state $ \(BatchState cmds cId) ->
                                 (BatchFuture $ cId + 1, BatchState (cmd{cmdId = cId + 1} : cmds) (cId + 1))

parseBatchResponse :: J.Array -> Batch a -> Graph
parseBatchResponse jarr b = foldl (flip ($)) empty appliedParsers
    where cmds = getCmds b
          parsers = foldl (\ps cmd -> cmdParse cmd : ps) [] cmds
          appliedParsers = zipWith ($) parsers (V.toList jarr)

runBatch :: Batch a -> Neo4j Graph
runBatch b = Neo4j $ \conn -> do
        arr <- httpCreate conn "/db/data/batch" $ J.encode b
        return $ parseBatchResponse arr b