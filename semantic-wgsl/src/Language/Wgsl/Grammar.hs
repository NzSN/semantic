{-# LANGUAGE TemplateHaskell #-}
module Language.Wgsl.Grammar
( tree_sitter_wgsl,
  Grammar(..)
) where

import AST.Grammar.TH
import Language.Haskell.TH
import TreeSitter.Wgsl (tree_sitter_wgsl)

-- | Statically-known rules corresponding to symbols in the grammar.
mkStaticallyKnownRuleGrammarData (mkName "Grammar") tree_sitter_wgsl
