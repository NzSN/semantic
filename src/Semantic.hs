{-# LANGUAGE GADTs #-}
module Semantic
( diffBlobPairs
, diffBlobPair
, parseAndRenderBlobs
, parseDiffAndRenderBlobPair
, parseBlobs
, parseBlob
) where

import qualified Control.Concurrent.Async as Async
import Data.Functor.Both as Both
import Data.Record
import Diff
import Info
import Interpreter
import qualified Language
import Patch
import Parser
import Prologue
import Renderer
import Semantic.Task as Task
import Source
import Syntax
import Term

-- This is the primary interface to the Semantic library which provides two
-- major classes of functionality: semantic parsing and diffing of source code
-- blobs.
--
-- Design goals:
--   - No knowledge of the filesystem or Git.
--   - Built in concurrency where appropriate.
--   - Easy to consume this interface from other application (e.g a cmdline or web server app).

-- | Diff a list of SourceBlob pairs to produce ByteString output using the specified renderer.
diffBlobPairs :: (Monoid output, StringConv output ByteString, HasField fields Category) => (Source -> Term (Syntax Text) (Record DefaultFields) -> Term (Syntax Text) (Record fields)) -> Renderer (Both SourceBlob, Diff (Syntax Text) (Record fields)) output -> [Both SourceBlob] -> IO ByteString
diffBlobPairs decorator renderer blobs = renderConcurrently parseDiffAndRender blobs
  where
    parseDiffAndRender blobPair = do
      diff <- diffBlobPair decorator blobPair
      pure $! case diff of
        Just a -> runRenderer renderer (blobPair, a)
        Nothing -> mempty

-- | Diff a pair of SourceBlobs.
diffBlobPair :: HasField fields Category => (Source -> Term (Syntax Text) (Record DefaultFields) -> Term (Syntax Text) (Record fields)) -> Both SourceBlob -> IO (Maybe (Diff (Syntax Text) (Record fields)))
diffBlobPair decorator blobs = do
  terms <- Async.mapConcurrently (parseBlob decorator) blobs
  pure $ case (runJoin blobs, runJoin terms) of
    ((left, right), (a, b)) | nonExistentBlob left && nonExistentBlob right -> Nothing
                            | nonExistentBlob right -> Just $ deleting a
                            | nonExistentBlob left -> Just $ inserting b
                            | otherwise -> Just $ runDiff (both a b)
  where
    runDiff terms = runBothWith diffTerms terms


parseAndRenderBlobs :: (Traversable t, Monoid output, StringConv output ByteString) => NamedDecorator -> TermRenderer output -> t SourceBlob -> Task ByteString
parseAndRenderBlobs decorator renderer = fmap (toS . fold) . distribute . fmap (parseAndRenderBlob decorator renderer)

parseAndRenderBlob :: NamedDecorator -> TermRenderer output -> SourceBlob -> Task output
parseAndRenderBlob decorator renderer blob@SourceBlob{..} = case blobLanguage of
  Just Language.Python -> do
    term <- parse pythonParser source
    term' <- decorate (case decorator of
      IdentityDecorator -> const identity
      IdentifierDecorator -> const identity) source term
    case renderer of
      JSONTermRenderer -> render (runRenderer JSONRenderer) (Identity blob, term')
      SExpressionTermRenderer -> render (runRenderer SExpressionParseTreeRenderer) (Identity blob, fmap (Info.Other "Term" :. ) term')
  language -> do
    term <- parse (parserForLanguage language) source
    case decorator of
      IdentifierDecorator -> do
        term' <- decorate (const identifierDecorator) source term
        case renderer of
          JSONTermRenderer -> render (runRenderer JSONRenderer) (Identity blob, term')
          SExpressionTermRenderer -> render (runRenderer SExpressionParseTreeRenderer) (Identity blob, term')
      IdentityDecorator ->
        case renderer of
          JSONTermRenderer -> render (runRenderer JSONRenderer) (Identity blob, term)
          SExpressionTermRenderer -> render (runRenderer SExpressionParseTreeRenderer) (Identity blob, term)


parseDiffAndRenderBlobPair :: NamedDecorator -> DiffRenderer output -> Both SourceBlob -> Task output
parseDiffAndRenderBlobPair decorator renderer blobs = do
  let languages = blobLanguage <$> blobs
  terms <- distributeFor blobs $ \ blob -> do
    term <- parse (if runBothWith (==) languages then parserForLanguage (Both.fst languages) else LineByLineParser) (source blob)
    case decorator of
      IdentityDecorator -> pure term
      IdentifierDecorator -> decorate (const identity) (source blob) term
  diffed <- diff (runBothWith diffTerms) terms
  case renderer of
    JSONDiffRenderer -> render (runRenderer JSONRenderer) (blobs, diffed)
    Task.SExpressionDiffRenderer -> render (runRenderer Renderer.SExpressionDiffRenderer) (blobs, diffed)


-- | Parse a list of SourceBlobs and use the specified renderer to produce ByteString output.
parseBlobs :: (Monoid output, StringConv output ByteString) => (Source -> Term (Syntax Text) (Record DefaultFields) -> Term (Syntax Text) (Record fields)) -> Renderer (Identity SourceBlob, Term (Syntax Text) (Record fields)) output -> [SourceBlob] -> IO ByteString
parseBlobs decorator renderer blobs = renderConcurrently parseAndRender (filter (not . nonExistentBlob) blobs)
  where
    parseAndRender blob = do
      term <- parseBlob decorator blob
      pure $! runRenderer renderer (Identity blob, term)

-- | Parse a SourceBlob.
parseBlob :: (Source -> Term (Syntax Text) (Record DefaultFields) -> Term (Syntax Text) (Record fields)) -> SourceBlob -> IO (Term (Syntax Text) (Record fields))
parseBlob decorator SourceBlob{..} = decorator source <$> runParser (parserForLanguage blobLanguage) source


-- Internal

renderConcurrently :: (Monoid output, StringConv output ByteString) => (input -> IO output) -> [input] -> IO ByteString
renderConcurrently f diffs = do
  outputs <- Async.mapConcurrently f diffs
  pure $ toS (mconcat outputs)
