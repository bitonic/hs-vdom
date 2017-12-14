{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
-- | Note: we use 'Traversal' to keep a cursor to the
-- write end of the state, but really we should use an
-- "affine traversal" which guarantees we have either 0
-- or 1 positions to traverse. See
-- <https://www.reddit.com/r/haskell/comments/60fha5/affine_traversal/>
-- for why affine traversals do not play well with lens.
module Anapo.Component.Internal where

import qualified Data.HashMap.Strict as HMS
import Control.Lens (Lens', view, lens)
import qualified Control.Lens as Lens
import Control.Monad (ap, unless)
import Data.Monoid ((<>), Endo)
import qualified Data.DList as DList
import Data.String (IsString(..))
import GHC.StaticPtr (StaticPtr, deRefStaticPtr, staticKey)
import GHC.Stack (HasCallStack)
import Control.Monad.State (execStateT, StateT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.IO.Unlift (askUnliftIO, unliftIO, MonadUnliftIO, UnliftIO(..))
import Control.Exception.Safe (SomeException, uninterruptibleMask, tryAny)
import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Monad.Trans (lift)
import Data.Maybe (fromMaybe)
import Data.DList (DList)
import Data.IORef (IORef, newIORef, atomicModifyIORef', writeIORef)
import Control.Monad.Reader (MonadReader(..))

import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.GlobalEventHandlers as DOM
import qualified GHCJS.DOM.Element as DOM
import qualified GHCJS.DOM.EventM as DOM.EventM
import qualified GHCJS.DOM.HTMLInputElement as DOM.Input
import qualified GHCJS.DOM.HTMLButtonElement as DOM.Button
import qualified GHCJS.DOM.HTMLOptionElement as DOM.Option
import qualified GHCJS.DOM.HTMLLabelElement as DOM.Label
import qualified GHCJS.DOM.HTMLSelectElement as DOM.Select
import qualified GHCJS.DOM.HTMLIFrameElement as DOM.IFrame
import qualified GHCJS.DOM.HTMLTextAreaElement as DOM.TextArea
import qualified GHCJS.DOM.HTMLHyperlinkElementUtils as DOM.HyperlinkElementUtils
import qualified Data.Vector as Vec

import qualified Anapo.VDOM as V
import Anapo.Render
import Anapo.Logging
import Anapo.Text (Text, pack)
import qualified Anapo.Text as T

#if defined(ghcjs_HOST_OS)
import GHCJS.Types (JSVal)
#else
import qualified Language.Javascript.JSaddle as JSaddle
#endif

-- affine traversals
-- --------------------------------------------------------------------

-- | for the components we want affine traversals --
-- traversals which point either to one or to zero elements.
-- however lens currently does not provide them, see
-- <https://www.reddit.com/r/haskell/comments/60fha5/affine_traversal/>.
-- therefore we provide a type synonym for clarity.
type AffineTraversal a b c d = Lens.Traversal a b c d
type AffineTraversal' a b = Lens.Traversal' a b

-- | to be used with 'AffineTraversal'
toMaybeOf :: (HasCallStack) => Lens.Getting (Endo [a]) s a -> s -> Maybe a
toMaybeOf l x = case Lens.toListOf l x of
  [] -> Nothing
  [y] -> Just y
  _:_ -> error "toMaybeOf: multiple elements returned!"

-- Dispatching and handling
-- --------------------------------------------------------------------

newtype Dispatch stateRoot = Dispatch
  { unDispatch ::
      forall state props. AffineTraversal' stateRoot (Component props state) -> (state -> DOM.JSM state) -> IO ()
  }

-- Register / handle
-- --------------------------------------------------------------------

-- we use these two on events and on forks, so that we can handle
-- all exceptions in a central place and so that we don't leave
-- dangling threads

type RegisterThread = IO () -> IO ()
type HandleException = SomeException -> IO ()

-- Action
-- --------------------------------------------------------------------

-- | An action we'll spawn from a component -- for example when an event
-- fires or as a fork in an event
newtype Action state a = Action
  { unAction ::
         forall rootState compProps compState.
         ActionEnv rootState compProps compState state
      -> DOM.JSM a
  }

data ActionEnv rootState compProps compState state = ActionEnv
  { aeRegisterThread :: RegisterThread
  , aeHandleException :: HandleException
  , aeDispatch :: Dispatch rootState
  , aeTraverseToComp :: AffineTraversal' rootState (Component compProps compState)
  , aeTraverseToState :: AffineTraversal' compState state
  }

{-
{-# INLINE runAction #-}
runAction :: Action state a -> RegisterThread -> HandleException -> Dispatch state -> DOM.JSM a
runAction vdom reg hdl disp = unAction vdom reg hdl disp id
-}

instance Functor (Action state) where
  {-# INLINE fmap #-}
  fmap f (Action g) = Action $ \env -> do
    x <- g env
    return (f x)

instance Applicative (Action state) where
  {-# INLINE pure #-}
  pure = return
  {-# INLINE (<*>) #-}
  (<*>) = ap

instance Monad (Action state) where
  {-# INLINE return #-}
  return x = Action (\_env -> return x)
  {-# INLINE (>>=) #-}
  ma >>= mf = Action $ \env -> do
    x <- unAction ma env
    unAction (mf x) env

instance MonadIO (Action state) where
  {-# INLINE liftIO #-}
  liftIO m = Action (\_env -> liftIO m)

#if !defined(ghcjs_HOST_OS)
instance  JSaddle.MonadJSM (Action state) where
  {-# INLINE liftJSM' #-}
  liftJSM' m = Action (\_env -> m)
#endif

instance MonadUnliftIO (Action state) where
  {-# INLINE askUnliftIO #-}
  askUnliftIO = Action $ \env -> do
    u <- askUnliftIO
    return (UnliftIO (\(Action m) -> unliftIO u (m env)))

class (DOM.MonadJSM m) => MonadAction state m | m -> state where
  liftAction :: Action state a -> m a

instance MonadAction state (Action state) where
  {-# INLINE liftAction #-}
  liftAction = id

instance MonadAction state (StateT s (Action state)) where
  {-# INLINE liftAction #-}
  liftAction = lift

{-# INLINE zoomAction #-}
zoomAction :: MonadAction out m => AffineTraversal' out in_ -> Action in_ a -> m a
zoomAction t m =
  liftAction (Action (\env -> unAction m env{aeTraverseToState = aeTraverseToState env . t}))

{-# INLINE forkRegistered #-}
forkRegistered :: MonadUnliftIO m => RegisterThread -> HandleException -> m () -> m ThreadId
forkRegistered register handler m = do
  u <- askUnliftIO
  liftIO $ uninterruptibleMask $ \restore -> forkIO $ register $ do
    mbErr <- tryAny (restore (unliftIO u m))
    case mbErr of
      Left err -> do
        tid <- myThreadId
        logError ("Caught exception in registered thread " <> pack (show tid) <> ", will handle it upstream: " <> pack (show err))
        handler err
      Right _ -> return ()

{-# INLINE forkAction #-}
forkAction :: MonadAction state m => Action state () -> m ThreadId
forkAction m =
  liftAction (Action (\env -> forkRegistered (aeRegisterThread env) (aeHandleException env) (unAction m env)))

{-# INLINE dispatch #-}
dispatch :: MonadAction state m => StateT state (Action state) () -> m ()
dispatch m =
  liftAction $ Action $ \env ->
    liftIO $ unDispatch (aeDispatch env) (aeTraverseToComp env) $ aeTraverseToState env $ \st ->
      unAction (execStateT m st) env

{-# INLINE askRegisterThread #-}
askRegisterThread :: (MonadAction state m) => m RegisterThread
askRegisterThread = liftAction (Action (\env -> return (aeRegisterThread env)))

{-# INLINE askHandleException #-}
askHandleException :: (MonadAction state m) => m HandleException
askHandleException = liftAction (Action (\env -> return (aeHandleException env)))

-- Monad
-- --------------------------------------------------------------------

type ClearPlacedComponents = [IO ()]

data AnapoEnv stateRoot state = AnapoEnv
  { aeReversePath :: [VDomPathSegment]
  -- ^ this is stored in _reverse_ order
  , aePrevState :: Maybe stateRoot
  , aeState :: state
  }

newtype AnapoM dom state a = AnapoM
  { unAnapoM ::
         forall rootState compProps compState.
         ActionEnv rootState compProps compState state
      -> AnapoEnv rootState state
      -> ClearPlacedComponents
      -> dom
      -> DOM.JSM (ClearPlacedComponents, dom, a)
  }

-- the Int is to store the current index in the dom, to be able o build
-- tthe next path segment.
type Dom state = AnapoM (Int, DList (V.Node V.SomeVDomNode)) state ()
type Node state = AnapoM () state (V.Node V.SomeVDomNode)

instance MonadIO (AnapoM dom state) where
  {-# INLINE liftIO #-}
  liftIO m = AnapoM $ \_actEnv _anEnv comps dom -> do
    x <- liftIO m
    return (comps, dom, x)

#if !defined(ghcjs_HOST_OS)
instance JSaddle.MonadJSM (AnapoM dom state) where
  {-# INLINE liftJSM' #-}
  liftJSM' m = AnapoM $ \_actEnv _anEnv comps dom -> do
    x <- m
    return (comps, dom, x)
#endif

instance Functor (AnapoM dom state) where
  {-# INLINE fmap #-}
  fmap f (AnapoM g) = AnapoM $ \acEnv aeEnv comps dom -> do
    (comps', dom', x) <- g acEnv aeEnv comps dom
    return (comps', dom', f x)

instance Applicative (AnapoM dom state) where
  {-# INLINE pure #-}
  pure = return
  {-# INLINE (<*>) #-}
  (<*>) = ap

instance Monad (AnapoM dom state) where
  {-# INLINE return #-}
  return x = AnapoM (\_acEnv _aeEnv comps dom -> return (comps, dom, x))
  {-# INLINE (>>=) #-}
  ma >>= mf = AnapoM $ \acEnv anEnv comps0 dom0 -> do
    (comps1, dom1, x) <- unAnapoM ma acEnv anEnv comps0 dom0
    (comps2, dom2, y) <- unAnapoM (mf x) acEnv anEnv comps1 dom1
    return (comps2, dom2, y)

instance MonadAction state (AnapoM dom state) where
  {-# INLINE liftAction #-}
  liftAction (Action f) = AnapoM $ \acEnv _anEnv comps dom -> do
    x <- f acEnv
    return (comps, dom, x)

instance MonadReader state (AnapoM dom state) where
  {-# INLINE ask #-}
  ask = AnapoM (\_acEnv anEnv comps dom -> return (comps, dom, aeState anEnv))
  {-# INLINE local #-}
  local f m = AnapoM $ \acEnv anEnv comps dom -> do
    unAnapoM m acEnv anEnv{ aeState = f (aeState anEnv) } comps dom

{-# INLINE askPreviousState #-}
askPreviousState :: AnapoM dom state (Maybe state)
askPreviousState =
  AnapoM $ \acEnv anEnv comps dom ->
    return
      ( comps
      , dom
      , toMaybeOf (aeTraverseToComp acEnv.componentState.aeTraverseToState acEnv) =<< aePrevState anEnv
      )

{-# INLINE zoomL #-}
zoomL :: Lens' out in_ -> AnapoM dom in_ a -> AnapoM dom out a
zoomL l m = AnapoM $ \acEnv anEnv comps dom ->
  unAnapoM m
    acEnv{ aeTraverseToState = aeTraverseToState acEnv . l }
    anEnv{ aeState = view l (aeState anEnv) }
    comps
    dom

{-# INLINE zoomT #-}
zoomT ::
     HasCallStack
  => in_
  -> AffineTraversal' out in_
  -- ^ note: if the traversal is not affine you'll get crashes.
  -> AnapoM dom in_ a
  -> AnapoM dom out a
zoomT st l m = AnapoM $ \acEnv anEnv comps dom ->
  unAnapoM m
    acEnv{ aeTraverseToState = aeTraverseToState acEnv . l }
    anEnv{ aeState = st }
    comps
    dom

-- to manipulate nodes
-- --------------------------------------------------------------------

{-# INLINE unsafeWillMount #-}
unsafeWillMount :: (DOM.Node -> Action state ()) -> NodePatch el state
unsafeWillMount = NPUnsafeWillMount

{-# INLINE unsafeDidMount #-}
unsafeDidMount :: (DOM.Node -> Action state ()) -> NodePatch el state
unsafeDidMount = NPUnsafeDidMount

{-# INLINE unsafeWillPatch #-}
unsafeWillPatch :: (DOM.Node -> Action state ()) -> NodePatch el state
unsafeWillPatch = NPUnsafeWillPatch

{-# INLINE unsafeDidPatch #-}
unsafeDidPatch :: (DOM.Node -> Action state ()) -> NodePatch el state
unsafeDidPatch = NPUnsafeDidPatch

{-# INLINE unsafeWillRemove #-}
unsafeWillRemove :: (DOM.Node -> Action state ()) -> NodePatch el state
unsafeWillRemove = NPUnsafeWillRemove

-- useful shorthands
-- --------------------------------------------------------------------

{-# INLINE n #-}
n :: Node state -> Dom state
n getNode = AnapoM $ \acEnv anEnv comps (ix, dom) -> do
  (comps', _, nod) <- unAnapoM getNode acEnv anEnv{ aeReversePath = VDPSNormal ix : aeReversePath anEnv } comps ()
  return (comps', (ix+1, dom <> DList.singleton nod), ())

-- TODO right now this it not implemented, but we will implement it in
-- the future.
{-# INLINE key #-}
key :: Text -> Node state -> Dom state
key _k = n

{-# INLINE text #-}
text :: Text -> Node state
text txt = return $ V.Node
  { V.nodeBody = V.SomeVDomNode $ V.VDomNode
      { V.vdomMark = Nothing
      , V.vdomBody = V.VDBText txt
      , V.vdomCallbacks = mempty
      , V.vdomWrap = DOM.Text
      }
  , V.nodeChildren = Nothing
  }

instance (el ~ DOM.Text) => IsString (Node state) where
  {-# INLINE fromString #-}
  fromString = text . T.pack

{-# INLINE rawNode #-}
rawNode ::
     (DOM.IsNode el)
  => (DOM.JSVal -> el) -> el
  -> [NodePatch el state]
  -> Node state
rawNode wrap x patches = do
  node <- patchNode
    V.VDomNode
      { V.vdomMark = Nothing
      , V.vdomBody = V.VDBRawNode x
      , V.vdomCallbacks = mempty
      , V.vdomWrap = wrap
      }
    patches
  return V.Node
    { V.nodeBody = V.SomeVDomNode node
    , V.nodeChildren = Nothing
    }

-- TODO this causes linking errors, sometimes. bizzarely, the linking
-- errors seem to happen only if a closure is formed -- e.g. if we
-- define the function as
--
-- @
-- marked shouldRerender ptr = deRefStaticPtr ptr
-- @
--
-- things work, but if we define it as
--
-- @
-- marked shouldRerender ptr = do
--   nod <- deRefStaticPtr ptr
--   return nod
-- @
--
-- they don't. the errors look like this:
--
-- @
-- dist/build/test-app/test-app-tmp/Anapo/TestApps/YouTube.dyn_o: In function `hs_spt_init_AnapoziTestAppsziYouTube':
-- ghc_18.c:(.text.startup+0x3): undefined reference to `r19F9_closure'
-- @
--
-- at call site (see for example Anapo.TestApps.YouTube)
{-# INLINE marked #-}
marked ::
     (Maybe state -> state -> V.Rerender)
  -> StaticPtr (Node state) -> Node state
marked shouldRerender ptr = AnapoM $ \acEnv anEnv comps dom -> do
  let !fprint = staticKey ptr
  let !rer = shouldRerender
        (toMaybeOf (aeTraverseToComp acEnv.componentState.aeTraverseToState acEnv) =<< aePrevState anEnv)
        (aeState anEnv)
  (comps', _, V.Node (V.SomeVDomNode nod) children) <- unAnapoM (deRefStaticPtr ptr) acEnv anEnv comps dom
  return (comps', (), V.Node (V.SomeVDomNode nod{ V.vdomMark = Just (V.Mark fprint rer) }) children)

-- Utilities to quickly create nodes
-- --------------------------------------------------------------------

data SomeEventAction el write = forall e. (DOM.IsEvent e) =>
  SomeEventAction (DOM.EventM.EventName el e) (el -> e -> Action write ())
newtype UnsafeRawHtml = UnsafeRawHtml Text

data NodePatch el state =
    NPUnsafeWillMount (DOM.Node -> Action state ())
  | NPUnsafeDidMount (DOM.Node -> Action state ())
  | NPUnsafeWillPatch (DOM.Node -> Action state ())
  | NPUnsafeDidPatch (DOM.Node -> Action state ())
  | NPUnsafeWillRemove (DOM.Node -> Action state ())
  | NPStyle V.StylePropertyName V.StyleProperty
  | NPProperty V.ElementPropertyName (V.ElementProperty el)
  | NPEvent (SomeEventAction el state)

class IsElementChildren a state where
  elementChildren :: a -> AnapoM () state (V.Children V.SomeVDomNode)
instance IsElementChildren () state where
  {-# INLINE elementChildren #-}
  elementChildren _ = return (V.CNormal mempty)
instance (a ~ (), state1 ~ state2) => IsElementChildren (AnapoM (Int, DList (V.Node V.SomeVDomNode)) state1 a) state2 where
  {-# INLINE elementChildren #-}
  elementChildren (AnapoM f) = AnapoM $ \acEnv anEnv comps _ -> do
    (comps', (_, dom), _) <- f acEnv anEnv comps (0, mempty)
    return (comps', (), V.CNormal (Vec.fromList (DList.toList dom)))
instance (a ~ ()) => IsElementChildren UnsafeRawHtml state2 where
  {-# INLINE elementChildren #-}
  elementChildren (UnsafeRawHtml txt) = return (V.CRawHtml txt)

{-# INLINE patchNode #-}
patchNode ::
     (HasCallStack, DOM.IsNode el)
  => V.VDomNode el -> [NodePatch el state] -> AnapoM () state (V.VDomNode el)
patchNode node00 patches00 = do
  u <- liftAction askUnliftIO
  let
    modifyCallbacks body f =
      body{ V.vdomCallbacks = f (V.vdomCallbacks body) }
  let
    modifyElement ::
         V.VDomNode el
      -> ((DOM.IsElement el, DOM.IsElementCSSInlineStyle el) => V.Element el -> V.Element el)
      -> V.VDomNode el
    modifyElement body f = case V.vdomBody body of
      V.VDBElement e -> body{ V.vdomBody = V.VDBElement (f e) }
      V.VDBText{} -> error "got patch requiring an element body, but was NBText"
      V.VDBRawNode{} -> error "got patch requiring an element body, but was NBRawNode"
  let
    go !node = \case
      [] -> return node
      patch : patches -> case patch of
        NPUnsafeWillMount cback -> go
          (modifyCallbacks node $ \cbacks -> mappend
            cbacks
            mempty{ V.callbacksUnsafeWillMount = \e -> liftIO (unliftIO u (cback e)) })
          patches
        NPUnsafeDidMount cback -> go
          (modifyCallbacks node $ \cbacks -> mappend
            cbacks
            mempty{ V.callbacksUnsafeDidMount = \e -> liftIO (unliftIO u (cback e)) })
          patches
        NPUnsafeWillPatch cback -> go
          (modifyCallbacks node $ \cbacks -> mappend
            cbacks
            mempty{ V.callbacksUnsafeWillPatch = \e -> liftIO (unliftIO u (cback e)) })
          patches
        NPUnsafeDidPatch cback -> go
          (modifyCallbacks node $ \cbacks -> mappend
            cbacks
            mempty{ V.callbacksUnsafeDidPatch = \e -> liftIO (unliftIO u (cback e)) })
          patches
        NPUnsafeWillRemove cback -> go
          (modifyCallbacks node $ \cbacks -> mappend
            cbacks
            mempty{ V.callbacksUnsafeWillRemove = \e -> liftIO (unliftIO u (cback e)) })
          patches
        NPStyle styleName styleBody -> go
          (modifyElement node $ \vel -> vel
            { V.elementStyle =
                HMS.insert styleName styleBody (V.elementStyle vel)
            })
          patches
        NPProperty propName propBody -> go
          (modifyElement node $ \vel -> vel
            { V.elementProperties =
                HMS.insert propName propBody (V.elementProperties vel)
            })
          patches
        NPEvent (SomeEventAction evName evListener) -> go
          (modifyElement node $ \vel -> vel
            { V.elementEvents = DList.snoc
                (V.elementEvents vel)
                (V.SomeEvent evName $ \e ev ->
                  liftIO (unliftIO u (evListener e ev)))
            })
          patches
  go node00 patches00

{-# INLINE el #-}
el ::
     ( IsElementChildren a state
     , DOM.IsElement el, DOM.IsElementCSSInlineStyle el
     , HasCallStack
     )
  => V.ElementTag
  -> (DOM.JSVal -> el)
  -> [NodePatch el state]
  -> a
  -> Node state
el tag wrap patches isChildren = do
  children <- elementChildren isChildren
  vdom <- patchNode
    V.VDomNode
      { V.vdomMark = Nothing
      , V.vdomBody = V.VDBElement V.Element
          { V.elementTag = tag
          , V.elementProperties = mempty
          , V.elementStyle = mempty
          , V.elementEvents = mempty
          }
      , V.vdomCallbacks = mempty
      , V.vdomWrap = wrap
      }
    patches
  return V.Node
    { V.nodeBody = V.SomeVDomNode vdom
    , V.nodeChildren = Just children
    }

-- Elements
-- --------------------------------------------------------------------

{-# INLINE div_ #-}
div_ :: IsElementChildren a state => [NodePatch DOM.HTMLDivElement state] -> a -> Node state
div_ = el "div" DOM.HTMLDivElement

{-# INLINE span_ #-}
span_ :: IsElementChildren a state => [NodePatch DOM.HTMLSpanElement state] -> a -> Node state
span_ = el "span" DOM.HTMLSpanElement

{-# INLINE a_ #-}
a_ :: IsElementChildren a state => [NodePatch DOM.HTMLAnchorElement state] -> a -> Node state
a_ = el "a" DOM.HTMLAnchorElement

{-# INLINE p_ #-}
p_ :: IsElementChildren a state => [NodePatch DOM.HTMLParagraphElement state] -> a -> Node state
p_ = el "p" DOM.HTMLParagraphElement

{-# INLINE input_ #-}
input_ :: IsElementChildren a state => [NodePatch DOM.HTMLInputElement state] -> a -> Node state
input_ = el "input" DOM.HTMLInputElement

{-# INLINE form_ #-}
form_ :: IsElementChildren a state => [NodePatch DOM.HTMLFormElement state] -> a -> Node state
form_ = el "form" DOM.HTMLFormElement

{-# INLINE button_ #-}
button_ :: IsElementChildren a state => [NodePatch DOM.HTMLButtonElement state] -> a -> Node state
button_ = el "button" DOM.HTMLButtonElement

{-# INLINE ul_ #-}
ul_ :: IsElementChildren a state => [NodePatch DOM.HTMLUListElement state] -> a -> Node state
ul_ = el "ul" DOM.HTMLUListElement

{-# INLINE li_ #-}
li_ :: IsElementChildren a state => [NodePatch DOM.HTMLLIElement state] -> a -> Node state
li_ = el "li" DOM.HTMLLIElement

{-# INLINE h2_ #-}
h2_ :: IsElementChildren a state => [NodePatch DOM.HTMLHeadingElement state] -> a -> Node state
h2_ = el "h2" DOM.HTMLHeadingElement

{-# INLINE h5_ #-}
h5_ :: IsElementChildren a state => [NodePatch DOM.HTMLHeadingElement state] -> a -> Node state
h5_ = el "h5" DOM.HTMLHeadingElement

{-# INLINE select_ #-}
select_ :: IsElementChildren a state => [NodePatch DOM.HTMLSelectElement state] -> a -> Node state
select_ = el "select" DOM.HTMLSelectElement

{-# INLINE option_ #-}
option_ :: IsElementChildren a state => [NodePatch DOM.HTMLOptionElement state] -> a -> Node state
option_ = el "option" DOM.HTMLOptionElement

{-# INLINE label_ #-}
label_ :: IsElementChildren a state => [NodePatch DOM.HTMLLabelElement state] -> a -> Node state
label_ = el "label" DOM.HTMLLabelElement

{-# INLINE nav_ #-}
nav_ :: IsElementChildren a state => [NodePatch DOM.HTMLElement state] -> a -> Node state
nav_ = el "nav" DOM.HTMLElement

{-# INLINE h1_ #-}
h1_ :: IsElementChildren a state => [NodePatch DOM.HTMLHeadingElement state] -> a -> Node state
h1_ = el "h1" DOM.HTMLHeadingElement

{-# INLINE h4_ #-}
h4_ :: IsElementChildren a state => [NodePatch DOM.HTMLHeadingElement state] -> a -> Node state
h4_ = el "h4" DOM.HTMLHeadingElement

{-# INLINE h6_ #-}
h6_ :: IsElementChildren a state => [NodePatch DOM.HTMLHeadingElement state] -> a -> Node state
h6_ = el "h6" DOM.HTMLHeadingElement

{-# INLINE small_ #-}
small_ :: IsElementChildren a state => [NodePatch DOM.HTMLElement state] -> a -> Node state
small_ = el "small" DOM.HTMLElement

{-# INLINE pre_ #-}
pre_ :: IsElementChildren a state => [NodePatch DOM.HTMLElement state] -> a -> Node state
pre_ = el "pre" DOM.HTMLElement

{-# INLINE code_ #-}
code_ :: IsElementChildren a state => [NodePatch DOM.HTMLElement state] -> a -> Node state
code_ = el "code" DOM.HTMLElement

{-# INLINE iframe_ #-}
iframe_ :: IsElementChildren a state => [NodePatch DOM.HTMLIFrameElement state] -> a -> Node state
iframe_ = el "iframe" DOM.HTMLIFrameElement

-- Properties
-- --------------------------------------------------------------------

{-# INLINE style #-}
style :: (DOM.IsElementCSSInlineStyle el) => Text -> Text -> NodePatch el state
style = NPStyle

class_ :: (DOM.IsElement el) => Text -> NodePatch el state
class_ txt = NPProperty "class" $ V.ElementProperty
  { V.eaGetProperty = DOM.getClassName
  , V.eaSetProperty = DOM.setClassName
  , V.eaValue = return txt
  }

id_ :: (DOM.IsElement el) => Text -> NodePatch el state
id_ txt = NPProperty "id" $ V.ElementProperty
  { V.eaGetProperty = DOM.getId
  , V.eaSetProperty = DOM.setId
  , V.eaValue = return txt
  }

class HasTypeProperty el where
  htpGetType :: el -> DOM.JSM Text
  htpSetType :: el -> Text -> DOM.JSM ()

instance HasTypeProperty DOM.HTMLInputElement where
  htpGetType = DOM.Input.getType
  htpSetType = DOM.Input.setType

instance HasTypeProperty DOM.HTMLButtonElement where
  htpGetType = DOM.Button.getType
  htpSetType = DOM.Button.setType

type_ :: (HasTypeProperty el) => Text -> NodePatch el state
type_ txt = NPProperty "type" $ V.ElementProperty
  { V.eaGetProperty = htpGetType
  , V.eaSetProperty = htpSetType
  , V.eaValue = return txt
  }

class HasHrefProperty el where
  htpGetHref :: el -> DOM.JSM Text
  htpSetHref :: el -> Text -> DOM.JSM ()

instance HasHrefProperty DOM.HTMLAnchorElement where
  htpGetHref = DOM.HyperlinkElementUtils.getHref
  htpSetHref = DOM.HyperlinkElementUtils.setHref

href_ :: (HasHrefProperty el) => Text -> NodePatch el state
href_ txt = NPProperty "href" $ V.ElementProperty
  { V.eaGetProperty = htpGetHref
  , V.eaSetProperty = htpSetHref
  , V.eaValue = return txt
  }

class HasValueProperty el where
  hvpGetValue :: el -> DOM.JSM Text
  hvpSetValue :: el -> Text -> DOM.JSM ()

instance HasValueProperty DOM.HTMLInputElement where
  hvpGetValue = DOM.Input.getValue
  hvpSetValue = DOM.Input.setValue

instance HasValueProperty DOM.HTMLOptionElement where
  hvpGetValue = DOM.Option.getValue
  hvpSetValue = DOM.Option.setValue

value_ :: (HasValueProperty el) => Text -> NodePatch el state
value_ txt = NPProperty "value" $ V.ElementProperty
  { V.eaGetProperty = hvpGetValue
  , V.eaSetProperty = hvpSetValue
  , V.eaValue = return txt
  }

class HasCheckedProperty el where
  hcpGetChecked :: el -> DOM.JSM Bool
  hcpSetChecked :: el -> Bool -> DOM.JSM ()

instance HasCheckedProperty DOM.HTMLInputElement where
  hcpGetChecked = DOM.Input.getChecked
  hcpSetChecked = DOM.Input.setChecked

checked_ :: (HasCheckedProperty el) => Bool -> NodePatch el state
checked_ b = NPProperty "checked" $ V.ElementProperty
  { V.eaGetProperty = hcpGetChecked
  , V.eaSetProperty = hcpSetChecked
  , V.eaValue = return b
  }

selected_ :: Bool -> NodePatch DOM.HTMLOptionElement state
selected_ b = NPProperty "selected" $ V.ElementProperty
  { V.eaGetProperty = DOM.Option.getSelected
  , V.eaSetProperty = DOM.Option.setSelected
  , V.eaValue = return b
  }

class HasDisabledProperty el where
  hdpGetDisabled :: el -> DOM.JSM Bool
  hdpSetDisabled :: el -> Bool -> DOM.JSM ()

instance HasDisabledProperty DOM.HTMLButtonElement where
  hdpGetDisabled = DOM.Button.getDisabled
  hdpSetDisabled = DOM.Button.setDisabled

disabled_ :: HasDisabledProperty el => Bool -> NodePatch el state
disabled_ b = NPProperty "disabled" $ V.ElementProperty
  { V.eaGetProperty = hdpGetDisabled
  , V.eaSetProperty = hdpSetDisabled
  , V.eaValue = return b
  }

#if defined(ghcjs_HOST_OS)
-- Raw FFI on js for performance

foreign import javascript unsafe
  "$2[$1]"
  js_getProperty :: Text -> JSVal -> IO JSVal

foreign import javascript unsafe
  "$2[$1] = $3"
  js_setProperty :: Text -> JSVal -> JSVal -> IO ()

rawProperty :: (DOM.PToJSVal el, DOM.ToJSVal a) => Text -> a -> NodePatch el state
rawProperty k x = NPProperty k $ V.ElementProperty
  { V.eaGetProperty = \el_ -> js_getProperty k (DOM.pToJSVal el_)
  , V.eaSetProperty = \el_ y -> do
      js_setProperty k (DOM.pToJSVal el_) y
  , V.eaValue = DOM.toJSVal x
  }
#else
rawProperty :: (JSaddle.MakeObject el, DOM.ToJSVal a) => Text -> a -> NodePatch el state
rawProperty k x = NPProperty k $ V.ElementProperty
  { V.eaGetProperty = \el_ -> el_ JSaddle.! k
  , V.eaSetProperty = \el_ y -> (el_ JSaddle.<# k) y
  , V.eaValue = DOM.toJSVal x
  }
#endif

{-# INLINE rawAttribute #-}
rawAttribute :: (DOM.IsElement el) => Text -> Text -> NodePatch el state
rawAttribute k x = NPProperty k $ V.ElementProperty
  { V.eaGetProperty = \el_ -> fromMaybe "" <$> DOM.getAttribute el_ k
  , V.eaSetProperty = \el_ y -> DOM.setAttribute el_ k y
  , V.eaValue = return x
  }

class HasPlaceholderProperty el where
  getPlaceholder :: el -> DOM.JSM Text
  setPlaceholder :: el -> Text -> DOM.JSM ()

instance HasPlaceholderProperty DOM.HTMLInputElement where
  getPlaceholder = DOM.Input.getPlaceholder
  setPlaceholder = DOM.Input.setPlaceholder

instance HasPlaceholderProperty DOM.HTMLTextAreaElement where
  getPlaceholder = DOM.TextArea.getPlaceholder
  setPlaceholder = DOM.TextArea.setPlaceholder

placeholder_ :: (HasPlaceholderProperty el) => Text -> NodePatch el state
placeholder_ txt = NPProperty "placeholder" $ V.ElementProperty
  { V.eaGetProperty = getPlaceholder
  , V.eaSetProperty = setPlaceholder
  , V.eaValue = return txt
  }

{-# INLINE for_ #-}
for_ :: Text -> NodePatch DOM.HTMLLabelElement state
for_ txt = NPProperty "for" $ V.ElementProperty
  { V.eaGetProperty = DOM.Label.getHtmlFor
  , V.eaSetProperty = DOM.Label.setHtmlFor
  , V.eaValue = return txt
  }

class HasMultipleProperty el where
  getMultiple :: el -> DOM.JSM Bool
  setMultiple :: el -> Bool -> DOM.JSM ()

instance HasMultipleProperty DOM.HTMLInputElement where
  getMultiple = DOM.Input.getMultiple
  setMultiple = DOM.Input.setMultiple

instance HasMultipleProperty DOM.HTMLSelectElement where
  getMultiple = DOM.Select.getMultiple
  setMultiple = DOM.Select.setMultiple

{-# INLINE multiple_ #-}
multiple_ :: (HasMultipleProperty el) => Bool -> NodePatch el state
multiple_ txt = NPProperty "multiple" $ V.ElementProperty
  { V.eaGetProperty = getMultiple
  , V.eaSetProperty = setMultiple
  , V.eaValue = return txt
  }

class HasSrcProperty el where
  getSrc :: el -> DOM.JSM Text
  setSrc :: el -> Text -> DOM.JSM ()

instance HasSrcProperty DOM.HTMLIFrameElement where
  getSrc = DOM.IFrame.getSrc
  setSrc = DOM.IFrame.setSrc

{-# INLINE src_ #-}
src_ :: (HasSrcProperty el) => Text -> NodePatch el state
src_ txt = NPProperty "src" $ V.ElementProperty
  { V.eaGetProperty = getSrc
  , V.eaSetProperty = setSrc
  , V.eaValue = return txt
  }

{-# INLINE onEvent #-}
onEvent ::
     (DOM.IsEventTarget t, DOM.IsEvent e, MonadAction state m, MonadUnliftIO m)
  => t -> DOM.EventM.EventName t e -> (e -> m ()) -> m (DOM.JSM ())
onEvent el_ evName f = do
  u <- askUnliftIO
  DOM.liftJSM $ DOM.EventM.on el_ evName $ do
    ev <- ask
    liftIO (unliftIO u (f ev))

-- Events
-- --------------------------------------------------------------------

onclick_ ::
     (DOM.IsElement el, DOM.IsGlobalEventHandlers el)
  => (el -> DOM.MouseEvent -> Action state ()) -> NodePatch el state
onclick_ = NPEvent . SomeEventAction DOM.click

onchange_ ::
     (DOM.IsElement el, DOM.IsGlobalEventHandlers el)
  => (el -> DOM.Event -> Action state ()) -> NodePatch el state
onchange_ = NPEvent . SomeEventAction DOM.change

oninput_ ::
     (DOM.IsElement el, DOM.IsGlobalEventHandlers el)
  => (el -> DOM.Event -> Action state ()) -> NodePatch el state
oninput_ = NPEvent . SomeEventAction DOM.input

onsubmit_ ::
     (DOM.IsElement el, DOM.IsGlobalEventHandlers el)
  => (el -> DOM.Event -> Action state ()) -> NodePatch el state
onsubmit_ = NPEvent . SomeEventAction DOM.submit

onselect_ ::
     (DOM.IsElement el, DOM.IsGlobalEventHandlers el)
  => (el -> DOM.UIEvent -> Action state ()) -> NodePatch el state
onselect_ = NPEvent . SomeEventAction DOM.select

-- simple rendering
-- --------------------------------------------------------------------

simpleNode :: forall state. state ->  Node state -> DOM.JSM (V.Node V.SomeVDomNode)
simpleNode st node = do
  comp <- newComponent st (\() -> node)
  (_, _, vdom) <- unAnapoM
    (do
      registerComponent comp ()
      _componentNode comp ())
    ActionEnv
      { aeRegisterThread = \_ -> fail "Trying to register a thread from the simpleRenderNode"
      , aeHandleException = \_ -> fail "Trying to handle an exception from the simpleRenderNode"
      , aeDispatch = Dispatch (\_ _ -> fail "Trying to dispatch from the simpleRenderNode")
      , aeTraverseToComp = id
      , aeTraverseToState = id
      }
    AnapoEnv
      { aeReversePath = []
      , aePrevState = Nothing
      , aeState = st
      }
    [] ()
  return vdom

-- when we want a quick render of a component, e.g. inside a raw node.
-- any attempt to use dispatch will result in an exception; e.g. this
-- will never redraw anything, it's just to quickly draw some elements
simpleRenderNode :: state -> Node state -> DOM.JSM DOM.Node
simpleRenderNode st node = do
  vdom <- simpleNode st node
  renderVirtualDom vdom (return . renderedVDomNodeDom . V.nodeBody)

-- utils
-- --------------------------------------------------------------------

type UnliftJSM = UnliftIO

{-# INLINE askUnliftJSM #-}
askUnliftJSM :: MonadUnliftIO m => m (UnliftJSM m)
askUnliftJSM = askUnliftIO

{-# INLINE unliftJSM #-}
unliftJSM :: UnliftJSM m -> m a -> DOM.JSM a
unliftJSM u m = liftIO (unliftIO u m)

-- Components
-- --------------------------------------------------------------------

data Component props state = Component
  { _componentState :: state
  , _componentNode :: props -> Node state
  , _componentPlaced :: IORef (Maybe (props, VDomPath))
  }

{-# INLINE componentState #-}
componentState :: Lens' (Component props state) state
componentState = lens _componentState (\comp st -> comp{ _componentState = st })

{-# INLINE componentNode #-}
componentNode :: Lens' (Component props state) (props -> Node state)
componentNode = lens _componentNode (\comp st -> comp{ _componentNode = st })

{-# INLINE newComponent #-}
newComponent :: MonadIO m => state -> (props -> Node state) -> m (Component props state)
newComponent st node = do
  posRef <- liftIO (newIORef Nothing)
  return (Component st node posRef)

-- TODO: sadly the HasCallStack does nothing with fail -- i should add
-- the location explicitly
registerComponent :: HasCallStack => Component props state -> props -> AnapoM dom a ()
registerComponent comp props = AnapoM $ \_acEnv anEnv comps dom -> do
  -- check that the component hasn't been placed already...
  ok <-
    liftIO $ atomicModifyIORef' (_componentPlaced comp) $ \case
      Nothing -> (Just (props, reverse (aeReversePath anEnv)), True)
      x@Just{} -> (x, False)
  unless ok $
    fail "component: trying to place a component twice!"
  return (writeIORef (_componentPlaced comp) Nothing : comps, dom, ())

-- | This function will fail if you've already inserted the component in
-- the VDOM.
{-# INLINE component #-}
component :: HasCallStack => props -> Node (Component props state)
component props = do
  comp <- ask
  registerComponent comp props
  AnapoM $ \acEnv anEnv comps dom ->
    unAnapoM
      (_componentNode (aeState anEnv) props)
      acEnv
        { aeTraverseToComp = aeTraverseToComp acEnv.componentState.aeTraverseToState acEnv
        , aeTraverseToState = id
        }
      anEnv
        { aeState = _componentState (aeState anEnv) }
      comps
      dom

{-# INLINE componentL #-}
componentL :: Lens' out (Component props state) -> props -> Node out
componentL l props = zoomL l (component props)

{-# INLINE componentT #-}
componentT ::
     HasCallStack
  => Component props state
  -> AffineTraversal' out (Component props state)
  -- ^ note: if the traversal is not affine you'll get crashes.
  -> props
  -> Node out
componentT st l props = zoomT st l (component props)