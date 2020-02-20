{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{-# LANGUAGE OverloadedLists #-}
module Stack.Graph (Direction(..), Graph(..), Node, (>>-), (-<<), scope) where

import           Algebra.Graph.Label (Label)
import           Algebra.Graph.Labelled ((-<), (>-))
import qualified Algebra.Graph.Labelled as Labelled
import           Data.Semilattice.Lower
import           Data.String
import           Data.Text (Text)
import           GHC.Exts

data Direction = From | To
    deriving (Show, Eq, Ord)

newtype Symbol = Symbol Text
    deriving (IsString, Show, Eq)

data Node = Root
  | Declaration Symbol
  | Reference Symbol
  | PushSymbol Symbol
  | PopSymbol Symbol
  | PushScope
  | Scope Symbol
  | ExportedScope
  | JumpToScope
  | IgnoreScope
  deriving (Show, Eq)

instance Lower Node where
  lowerBound = Root

newtype Graph a = Graph { unGraph :: Labelled.Graph (Label Direction) a }
  deriving (Show)

instance Lower a => Lower (Graph a) where
  lowerBound = Graph (Labelled.vertex lowerBound)

scope, declaration, popSymbol, reference, pushSymbol :: Symbol -> Graph Node
scope = Graph . Labelled.vertex . Scope
declaration = Graph . Labelled.vertex . Declaration
reference = Graph . Labelled.vertex . Reference
popSymbol = Graph . Labelled.vertex . PopSymbol
pushSymbol = Graph . Labelled.vertex . PushSymbol
root :: Graph Node
root = Graph (Labelled.vertex Root)

(>>-), (-<<) :: Graph a -> Graph a -> Graph a
Graph left >>- Graph right = Graph (Labelled.connect [From] left right)
(-<<) = flip (>>-)

testGraph :: Graph Node
testGraph = (scope "current" >>- declaration "a") >>- (popSymbol "member" >>- declaration "b") >>- (reference "b" >>- pushSymbol "member") >>- (reference "a" >>- root)
