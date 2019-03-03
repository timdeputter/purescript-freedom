module Freedom.Renderer
  ( Renderer
  , createRenderer
  , render
  ) where

import Prelude

import Control.Monad.Free.Trans (runFreeT, hoistFreeT)
import Control.Monad.Reader (ReaderT, ask, local, runReaderT, withReaderT)
import Data.Array (take, (!!), (:))
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console (error)
import Effect.Ref (Ref, modify, new, read, write)
import Freedom.Renderer.Diff (diff)
import Freedom.Renderer.Util (class IsRenderEnv, class Affable)
import Freedom.Renderer.Util as Util
import Freedom.Styler (Styler)
import Freedom.TransformF.Type (TransformF)
import Freedom.VNode (VNode(..), VElement(..), VRender, VRenderEnv(..), runVRender)
import Unsafe.Coerce (unsafeCoerce)
import Web.DOM.Element as E
import Web.DOM.Node (Node, appendChild, insertBefore, removeChild)
import Web.DOM.ParentNode (QuerySelector(..), querySelector)
import Web.DOM.Text as T
import Web.HTML (window)
import Web.HTML.HTMLDocument (toParentNode)
import Web.HTML.Window (document)

newtype Renderer f state = Renderer
  { container :: Maybe Node
  , view :: state -> VNode f state
  , historyRef :: Ref (Array (VNode f state))
  , transformF :: TransformF f state
  , getState :: Effect state
  , styler :: Styler
  }

createRenderer
  :: forall f state
   . String
  -> (state -> VNode f state)
  -> TransformF f state
  -> Effect state
  -> Styler
  -> Effect (Renderer f state)
createRenderer selector view transformF getState styler = do
  parentNode <- toParentNode <$> (window >>= document)
  container <- map E.toNode <$> querySelector (QuerySelector selector) parentNode
  historyRef <- new []
  pure $ Renderer { container, view, historyRef, transformF, getState, styler }

render
  :: forall f state
   . Functor (f state)
  => Renderer f state
  -> Effect Unit
render (Renderer r@{ transformF, getState, styler }) =
  case r.container of
    Nothing -> error "Received selector is not found."
    Just node -> do
      state <- getState
      history <- flip modify r.historyRef \h -> take 2 $ r.view state : h
      flip runReaderT (RenderEnv { transformF, styler, isSVG: false }) $ patch
        { current: history !! 1
        , next: history !! 0
        , realParentNode: node
        , realNodeIndex: 0
        , moveIndex: Nothing
        }

newtype RenderEnv f state = RenderEnv
  { styler :: Styler
  , transformF :: TransformF f state
  , isSVG :: Boolean
  }

newtype Operator f state = Operator
  { styler :: Styler
  , transformF :: TransformF f state
  , isSVG :: Boolean
  , operationRef :: Ref (Array (Array (VNode f state)))
  , prevOriginChildren :: Array (VNode f state)
  , currentOriginChildren :: Array (VNode f state)
  }

type Render f state a = ReaderT (RenderEnv f state) Effect a

type OperativeRender f state a = ReaderT (Operator f state) Effect a

type PatchArgs f state =
  { current :: Maybe (VNode f state)
  , next :: Maybe (VNode f state)
  , realParentNode :: Node
  , realNodeIndex :: Int
  , moveIndex :: Maybe Int
  }

patch
  :: forall f state
   . Functor (f state)
  => PatchArgs f state
  -> Render f state Unit
patch { current, next, realParentNode, realNodeIndex, moveIndex } =
  case current, next of
    Nothing, Nothing -> pure unit

    Nothing, Just (VNode _ next') -> switchContextIfSVG next' do
      newNode <- operateCreating next'
      maybeNode <- liftEffect $ Util.childNode realNodeIndex realParentNode
      liftEffect do
        void case maybeNode of
          Nothing -> appendChild newNode realParentNode
          Just node -> insertBefore newNode node realParentNode

    Just (VNode _ current'), Nothing -> switchContextIfSVG current' do
      maybeNode <- liftEffect $ Util.childNode realNodeIndex realParentNode
      case maybeNode of
        Nothing -> pure unit
        Just node -> do
          operateDeleting node current'
          liftEffect $ void $ removeChild node realParentNode

    Just (VNode _ current'), Just (VNode _ next') -> switchContextIfSVG next' do
      maybeNode <- liftEffect $ Util.childNode realNodeIndex realParentNode
      case maybeNode of
        Nothing -> pure unit
        Just node -> do
          case moveIndex of
            Nothing -> pure unit
            Just mi -> liftEffect do
              let adjustedIdx = if realNodeIndex < mi then mi + 1 else mi
              maybeAfterNode <- Util.childNode adjustedIdx realParentNode
              void case maybeAfterNode of
                Nothing -> appendChild node realParentNode
                Just afterNode -> insertBefore node afterNode realParentNode
          operateUpdating node current' next'

switchContextIfSVG
  :: forall f state
   . VElement f state
  -> Render f state Unit
  -> Render f state Unit
switchContextIfSVG (Text _) m = m
switchContextIfSVG (Element element) m =
  local (changeSVGContext $ element.tag == "svg") m
switchContextIfSVG (OperativeElement element) m =
  local (changeSVGContext $ element.tag == "svg") m

changeSVGContext :: forall f state. Boolean -> RenderEnv f state -> RenderEnv f state
changeSVGContext isSVG (RenderEnv r) =
  if r.isSVG
    then RenderEnv r
    else RenderEnv r { isSVG = isSVG }

operateCreating
  :: forall f state
   . Functor (f state)
  => VElement f state
  -> Render f state Node
operateCreating (Text text) =
  liftEffect $ Util.createText_ text >>= T.toNode >>> pure
operateCreating (OperativeElement element) = do
  operator <- genOperator [] element.children
  withReaderT (const operator) do
    el <- Util.createElement_ element
    Util.runLifecycle $ element.didCreate el
    pure $ E.toNode el
operateCreating (Element element) = do
  el <- Util.createElement_ element
  let node = E.toNode el
  diff patch node [] element.children
  Util.runLifecycle $ element.didCreate el
  pure node

operateDeleting
  :: forall f state
   . Functor (f state)
  => Node
  -> VElement f state
  -> Render f state Unit
operateDeleting _ (Text _) = pure unit
operateDeleting _ (OperativeElement { children, didDelete }) = do
  operator <- genOperator children []
  withReaderT (const operator) $ Util.runLifecycle didDelete
operateDeleting node (Element { children, didDelete }) = do
  diff patch node children []
  Util.runLifecycle didDelete

operateUpdating
  :: forall f state
   . Functor (f state)
  => Node
  -> VElement f state
  -> VElement f state
  -> Render f state Unit
operateUpdating node (Text c) (Text n) =
  liftEffect $ Util.updateText_ c n node
operateUpdating node (OperativeElement c) (OperativeElement n) = do
  operator <- genOperator c.children n.children
  withReaderT (const operator) do
    let el = unsafeCoerce node
    Util.updateElement_ c n el
    Util.runLifecycle $ n.didUpdate el
operateUpdating node (Element c) (Element n) = do
  let el = unsafeCoerce node
  Util.updateElement_ c n el
  diff patch node c.children n.children
  Util.runLifecycle $ n.didUpdate el
operateUpdating _ _ _ = pure unit

genOperator
  :: forall f state
   . Array (VNode f state)
  -> Array (VNode f state)
  -> Render f state (Operator f state)
genOperator prevOriginChildren currentOriginChildren = do
  operationRef <- liftEffect $ new []
  RenderEnv { transformF, styler, isSVG } <- ask
  pure $ Operator
    { transformF
    , styler
    , isSVG
    , operationRef
    , prevOriginChildren
    , currentOriginChildren
    }

instance affableAff :: Functor (f state) => Affable (RenderEnv f state) f state Aff where
  toAff (RenderEnv r) = runFreeT r.transformF

instance affableVRender :: Functor (f state) => Affable (Operator f state) f state (VRender f state) where
  toAff (Operator r) = runFreeT r.transformF <<< hoistFreeT nt
    where
      getPrevChildren = (_ !! 0) <$> read r.operationRef
      getPrevOriginChildren = pure r.prevOriginChildren
      getCurrentOriginChildren = pure r.currentOriginChildren
      renderChildren node prev current = do
        write [ current, prev ] r.operationRef
        flip runReaderT renderEnv $ diff patch node prev current

      renderEnv = RenderEnv
        { transformF: r.transformF
        , styler: r.styler
        , isSVG: r.isSVG
        }

      nt :: VRender f state ~> Aff
      nt = flip runVRender $ VRenderEnv
        { getPrevChildren
        , getPrevOriginChildren
        , getCurrentOriginChildren
        , renderChildren
        }

instance isRenderEnvRenderEnv :: IsRenderEnv (RenderEnv f state) where
  toStyler (RenderEnv r) = r.styler
  toIsSVG (RenderEnv r) = r.isSVG

instance isRenderEnvOperator :: IsRenderEnv (Operator f state) where
  toStyler (Operator r) = r.styler
  toIsSVG (Operator r) = r.isSVG