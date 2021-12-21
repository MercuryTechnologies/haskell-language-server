{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE CPP                #-}

module Development.IDE.Plugin.CodeAction.ExactPrint (
  Rewrite (..),
  rewriteToEdit,
  rewriteToWEdit,
#if !MIN_VERSION_ghc(9,2,0)
  transferAnn,
#endif

  -- * Utilities
  appendConstraint,
  removeConstraint,
  extendImport,
  hideSymbol,
  liftParseAST,
) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Extra                   (whenJust)
import           Control.Monad.Trans
import           Data.Char                             (isAlphaNum)
import           Data.Data                             (Data)
import           Data.Functor
import           Data.Generics                         (listify)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromJust, isNothing,
                                                        mapMaybe)
import qualified Data.Text                             as T
import           Development.IDE.GHC.Compat
import qualified Development.IDE.GHC.Compat.Util       as Util
import           Development.IDE.GHC.Error
import           Development.IDE.GHC.ExactPrint        (ASTElement (parseAST),
#if !MIN_VERSION_ghc(9,2,0)
                                                        Annotate
#endif
                                                        )
import           Development.IDE.Spans.Common
import           GHC.Exts                              (IsList (fromList))
import           Language.Haskell.GHC.ExactPrint
#if !MIN_VERSION_ghc(9,2,0)
import           Language.Haskell.GHC.ExactPrint.Types (DeltaPos (DP),
                                                        KeywordId (G), mkAnnKey)
#endif
import           Language.LSP.Types

------------------------------------------------------------------------------

-- | Construct a 'Rewrite', replacing the node at the given 'SrcSpan' with the
--   given 'ast'.
data Rewrite where
  Rewrite ::
#if !MIN_VERSION_ghc(9,2,0)
    Annotate ast =>
#else
    ExactPrint (GenLocated (Anno ast) ast) =>
#endif
    -- | The 'SrcSpan' that we want to rewrite
    SrcSpan ->
    -- | The ast that we want to graft
#if !MIN_VERSION_ghc(9,2,0)
    (DynFlags -> TransformT (Either String) (Located ast)) ->
#else
    (DynFlags -> TransformT (Either String) (GenLocated (Anno ast) ast)) ->
#endif
    Rewrite

------------------------------------------------------------------------------

-- | Convert a 'Rewrite' into a list of '[TextEdit]'.
rewriteToEdit ::
  DynFlags ->
#if !MIN_VERSION_ghc(9,2,0)
  Anns ->
#endif
  Rewrite ->
  Either String [TextEdit]
rewriteToEdit dflags
#if !MIN_VERSION_ghc(9,2,0)
              anns
#endif
              (Rewrite dst f) = do
  (ast, anns , _) <- runTransformT
#if !MIN_VERSION_ghc(9,2,0)
                            anns
#endif
                          $ do
    ast <- f dflags
#if !MIN_VERSION_ghc(9,2,0)
    ast <$ setEntryDPT ast (DP (0, 0))
#else
    pure ast
#endif
  let editMap =
        [ TextEdit (fromJust $ srcSpanToRange dst) $
            T.pack $ exactPrint ast
#if !MIN_VERSION_ghc(9,2,0)
                       (fst anns)
#endif
        ]
  pure editMap

-- | Convert a 'Rewrite' into a 'WorkspaceEdit'
rewriteToWEdit :: DynFlags
               -> Uri
#if !MIN_VERSION_ghc(9,2,0)
               -> Anns
#endif
               -> Rewrite
               -> Either String WorkspaceEdit
rewriteToWEdit dflags uri
#if !MIN_VERSION_ghc(9,2,0)
               anns
#endif
               r = do
  edits <- rewriteToEdit dflags
#if !MIN_VERSION_ghc(9,2,0)
                         anns
#endif
                         r
  return $
    WorkspaceEdit
      { _changes = Just (fromList [(uri, List edits)])
      , _documentChanges = Nothing
      , _changeAnnotations = Nothing
      }

------------------------------------------------------------------------------

-- | Fix the parentheses around a type context
fixParens ::
  (Monad m, Data (HsType pass), pass ~ GhcPass p0) =>
#if !MIN_VERSION_ghc(9,2,0)
  Maybe DeltaPos ->
  Maybe DeltaPos ->
#endif
  LHsContext pass ->
  TransformT m [LHsType pass]
fixParens
#if !MIN_VERSION_ghc(9,2,0)
          openDP closeDP
#endif
          ctxt@(L _ elems) = do
  -- Paren annotation for type contexts are usually quite screwed up
  -- we remove duplicates and fix negative DPs
#if !MIN_VERSION_ghc(9,2,0)
  let parens = Map.fromList [(G AnnOpenP, dp00), (G AnnCloseP, dp00)]
  modifyAnnsT $
    Map.adjust
      ( \x ->
          let annsMap = Map.fromList (annsDP x)
           in x
                { annsDP =
                    Map.toList $
                      Map.alter (\_ -> openDP <|> Just dp00) (G AnnOpenP) $
                        Map.alter (\_ -> closeDP <|> Just dp00) (G AnnCloseP) $
                          annsMap <> parens
                }
      )
      (mkAnnKey ctxt)
#endif
  return $ map dropHsParTy elems
 where

  dropHsParTy :: LHsType (GhcPass pass) -> LHsType (GhcPass pass)
  dropHsParTy (L _ (HsParTy _ ty)) = ty
  dropHsParTy other                = other

removeConstraint ::
  -- | Predicate: Which context to drop.
  (LHsType GhcPs -> Bool) ->
  LHsType GhcPs ->
  Rewrite
removeConstraint toRemove = go
  where
    go :: LHsType GhcPs -> Rewrite
#if !MIN_VERSION_ghc(9,2,0)
    go (L l it@HsQualTy{hst_ctxt = L l' ctxt, hst_body}) = Rewrite (locA l) $ \_ -> do
#else
    go (L l it@HsQualTy{hst_ctxt = Just (L l' ctxt), hst_body}) = Rewrite (locA l) $ \_ -> do
#endif
      let ctxt' = L l' $ filter (not . toRemove) ctxt
#if !MIN_VERSION_ghc(9,2,0)
      when ((toRemove <$> headMaybe ctxt) == Just True) $
        setEntryDPT hst_body (DP (0, 0))
      return $ L l $ it{hst_ctxt = ctxt'}
#else
      return $ L l $ it{hst_ctxt = Just ctxt'}
#endif
    go (L _ (HsParTy _ ty)) = go ty
    go (L _ HsForAllTy{hst_body}) = go hst_body
    go (L l other) = Rewrite (locA l) $ \_ -> return $ L l other

-- | Append a constraint at the end of a type context.
--   If no context is present, a new one will be created.
appendConstraint ::
  -- | The new constraint to append
  String ->
  -- | The type signature where the constraint is to be inserted, also assuming annotated
  LHsType GhcPs ->
  Rewrite
appendConstraint constraintT = go
 where
#if !MIN_VERSION_ghc(9,2,0)
  go (L l it@HsQualTy{hst_ctxt = L l' ctxt}) = Rewrite (locA l) $ \df -> do
#else
  go (L l it@HsQualTy{hst_ctxt = Just (L l' ctxt)}) = Rewrite (locA l) $ \df -> do
#endif
    constraint <- liftParseAST df constraintT
#if !MIN_VERSION_ghc(9,2,0)
    setEntryDPT constraint (DP (0, 1))

    -- Paren annotations are usually attached to the first and last constraints,
    -- rather than to the constraint list itself, so to preserve them we need to reposition them
    closeParenDP <- lookupAnn (G AnnCloseP) `mapM` lastMaybe ctxt
    openParenDP <- lookupAnn (G AnnOpenP) `mapM` headMaybe ctxt
#endif
    ctxt' <- fixParens
#if !MIN_VERSION_ghc(9,2,0)
                (join openParenDP) (join closeParenDP)
#endif
                (L l' ctxt)

#if !MIN_VERSION_ghc(9,2,0)
    addTrailingCommaT (last ctxt')
    return $ L l $ it{hst_ctxt = L l' $ ctxt' ++ [constraint]}
#else
    return $ L l $ it{hst_ctxt = Just $ L l' $ ctxt' ++ [constraint]}
#endif
  go (L _ HsForAllTy{hst_body}) = go hst_body
  go (L _ (HsParTy _ ty)) = go ty
  go (L l other) = Rewrite (locA l) $ \df -> do
    -- there isn't a context, so we must create one
    constraint <- liftParseAST df constraintT
    lContext <- uniqueSrcSpanT
    lTop <- uniqueSrcSpanT
#if !MIN_VERSION_ghc(9,2,0)
    let context = L lContext [constraint]
    addSimpleAnnT context (DP (0, 0)) $
      (G AnnDarrow, DP (0, 1)) :
      concat
        [ [ (G AnnOpenP, dp00)
          , (G AnnCloseP, dp00)
          ]
        | hsTypeNeedsParens sigPrec $ unLoc constraint
        ]
#else
    let context = Just $ reLocA $ L lContext [constraint]
#endif

    return $ reLocA $ L lTop $ HsQualTy noExtField context (L l other)

liftParseAST :: forall ast l. (ASTElement l ast
                              )
             => DynFlags -> String
#if MIN_VERSION_ghc(9,2,0)
             -> TransformT (Either String) (GenLocated (SrcAnn l) ast)
#else
             -> TransformT (Either String) (Located ast)
#endif
liftParseAST df s = case parseAST df "" s of
#if !MIN_VERSION_ghc(9,2,0)
  Right (anns, x) -> modifyAnnsT (anns <>) $> x
#else
  Right x ->  pure x
#endif
  Left _          -> lift $ Left $ "No parse: " <> s

#if !MIN_VERSION_ghc(9,2,0)
lookupAnn :: (Data a, Monad m)
          => KeywordId -> Located a -> TransformT m (Maybe DeltaPos)
lookupAnn comment la = do
  anns <- getAnnsT
  return $ Map.lookup (mkAnnKey la) anns >>= lookup comment . annsDP

dp00 :: DeltaPos
dp00 = DP (0, 0)

-- | Copy anns attached to a into b with modification, then delete anns of a
transferAnn :: (Data a, Data b) => Located a -> Located b -> (Annotation -> Annotation) -> TransformT (Either String) ()
transferAnn la lb f = do
  anns <- getAnnsT
  let oldKey = mkAnnKey la
      newKey = mkAnnKey lb
  oldValue <- liftMaybe "Unable to find ann" $ Map.lookup oldKey anns
  putAnnsT $ Map.delete oldKey $ Map.insert newKey (f oldValue) anns

#endif

headMaybe :: [a] -> Maybe a
headMaybe []      = Nothing
headMaybe (a : _) = Just a

lastMaybe :: [a] -> Maybe a
lastMaybe []    = Nothing
lastMaybe other = Just $ last other

liftMaybe :: String -> Maybe a -> TransformT (Either String) a
liftMaybe _ (Just x) = return x
liftMaybe s _        = lift $ Left s

------------------------------------------------------------------------------
extendImport :: Maybe String -> String -> LImportDecl GhcPs -> Rewrite
extendImport mparent identifier lDecl@(L l _) =
  Rewrite (locA l) $ \df -> do
    case mparent of
      Just parent -> extendImportViaParent df parent identifier lDecl
      _           -> extendImportTopLevel identifier lDecl

-- | Add an identifier or a data type to import list
--
-- extendImportTopLevel "foo" AST:
--
-- import A --> Error
-- import A (foo) --> Error
-- import A (bar) --> import A (bar, foo)
extendImportTopLevel ::
  -- | rendered
  String ->
  LImportDecl GhcPs ->
  TransformT (Either String) (LImportDecl GhcPs)
extendImportTopLevel thing (L l it@ImportDecl{..})
  | Just (hide, L l' lies) <- ideclHiding
    , hasSibling <- not $ null lies = do
    src <- uniqueSrcSpanT
    top <- uniqueSrcSpanT
    let rdr = reLocA $ L src $ mkRdrUnqual $ mkVarOcc thing

    let alreadyImported =
          showNameWithoutUniques (occName (unLoc rdr))
            `elem` map (showNameWithoutUniques @OccName) (listify (const True) lies)
    when alreadyImported $
      lift (Left $ thing <> " already imported")

    let lie = reLocA $ L src $ IEName rdr
        x = reLocA $ L top $ IEVar noExtField lie
    if x `elem` lies
      then lift (Left $ thing <> " already imported")
      else do
#if !MIN_VERSION_ghc(9,2,0)
        when hasSibling $
          addTrailingCommaT (last lies)
        addSimpleAnnT x (DP (0, if hasSibling then 1 else 0)) []
        addSimpleAnnT rdr dp00 [(G AnnVal, dp00)]
        -- Parens are attachted to `lies`, so if `lies` was empty previously,
        -- we need change the ann key from `[]` to `:` to keep parens and other anns.
        unless hasSibling $
          transferAnn (L l' lies) (L l' [x]) id
#endif
        return $ L l it{ideclHiding = Just (hide, L l' $ lies ++ [x])}
extendImportTopLevel _ _ = lift $ Left "Unable to extend the import list"

-- | Add an identifier with its parent to import list
--
-- extendImportViaParent "Bar" "Cons" AST:
--
-- import A --> Error
-- import A (Bar(..)) --> Error
-- import A (Bar(Cons)) --> Error
-- import A () --> import A (Bar(Cons))
-- import A (Foo, Bar) --> import A (Foo, Bar(Cons))
-- import A (Foo, Bar()) --> import A (Foo, Bar(Cons))
extendImportViaParent ::
  DynFlags ->
  -- | parent (already parenthesized if needs)
  String ->
  -- | rendered child
  String ->
  LImportDecl GhcPs ->
  TransformT (Either String) (LImportDecl GhcPs)
extendImportViaParent df parent child (L l it@ImportDecl{..})
  | Just (hide, L l' lies) <- ideclHiding = go hide l' [] lies
 where
  go _hide _l' _pre ((L _ll' (IEThingAll _ (L _ ie))) : _xs)
    | parent == unIEWrappedName ie = lift . Left $ child <> " already included in " <> parent <> " imports"
  go hide l' pre (lAbs@(L ll' (IEThingAbs _ absIE@(L _ ie))) : xs)
    -- ThingAbs ie => ThingWith ie child
    | parent == unIEWrappedName ie = do
      srcChild <- uniqueSrcSpanT
      let childRdr = reLocA $ L srcChild $ mkRdrUnqual $ mkVarOcc child
          childLIE = reLocA $ L srcChild $ IEName childRdr
#if !MIN_VERSION_ghc(9,2,0)
          x :: LIE GhcPs = L ll' $ IEThingWith noExtField absIE NoIEWildcard [childLIE] []
      -- take anns from ThingAbs, and attatch parens to it
      transferAnn lAbs x $ \old -> old{annsDP = annsDP old ++ [(G AnnOpenP, DP (0, 1)), (G AnnCloseP, dp00)]}
      addSimpleAnnT childRdr dp00 [(G AnnVal, dp00)]
#else
          x :: LIE GhcPs = L ll' $ IEThingWith mempty absIE NoIEWildcard [childLIE]
#endif
      return $ L l it{ideclHiding = Just (hide, L l' $ reverse pre ++ [x] ++ xs)}
#if !MIN_VERSION_ghc(9,2,0)
  go hide l' pre ((L l'' (IEThingWith _ twIE@(L _ ie) _ lies' _)) : xs)
#else
  go hide l' pre ((L l'' (IEThingWith _ twIE@(L _ ie) _ lies')) : xs)
#endif
    -- ThingWith ie lies' => ThingWith ie (lies' ++ [child])
    | parent == unIEWrappedName ie
      , hasSibling <- not $ null lies' =
      do
        srcChild <- uniqueSrcSpanT
        let childRdr = reLocA $ L srcChild $ mkRdrUnqual $ mkVarOcc child

        let alreadyImported =
              showNameWithoutUniques (occName (unLoc childRdr))
                `elem` map (showNameWithoutUniques @OccName) (listify (const True) lies')
        when alreadyImported $
          lift (Left $ child <> " already included in " <> parent <> " imports")

        let childLIE = reLocA $ L srcChild $ IEName childRdr
#if !MIN_VERSION_ghc(9,2,0)
        when hasSibling $
          addTrailingCommaT (last lies')
        addSimpleAnnT childRdr (DP (0, if hasSibling then 1 else 0)) [(G AnnVal, dp00)]
        return $ L l it{ideclHiding = Just (hide, L l' $ reverse pre ++ [L l'' (IEThingWith noExtField twIE NoIEWildcard (lies' ++ [childLIE]) [])] ++ xs)}
#else
        return $ L l it{ideclHiding = Just (hide, L l' $ reverse pre ++ [L l'' (IEThingWith mempty twIE NoIEWildcard (lies' ++ [childLIE]))] ++ xs)}
#endif
  go hide l' pre (x : xs) = go hide l' (x : pre) xs
  go hide l' pre []
    | hasSibling <- not $ null pre = do
      -- [] => ThingWith parent [child]
      l'' <- uniqueSrcSpanT
      srcParent <- uniqueSrcSpanT
      srcChild <- uniqueSrcSpanT
      parentRdr <- liftParseAST df parent
      let childRdr = reLocA $ L srcChild $ mkRdrUnqual $ mkVarOcc child
          isParentOperator = hasParen parent
#if !MIN_VERSION_ghc(9,2,0)
      when hasSibling $
        addTrailingCommaT (head pre)
      let parentLIE = L srcParent $ (if isParentOperator then IEType parentRdr else IEName parentRdr)
          childLIE = reLocA $ L srcChild $ IEName childRdr
#else
      let parentLIE = reLocA $ L srcParent $ (if isParentOperator then IEType mempty parentRdr else IEName parentRdr)
          childLIE = reLocA $ L srcChild $ IEName childRdr
#endif
#if !MIN_VERSION_ghc(9,2,0)
          x :: LIE GhcPs = reLocA $ L l'' $ IEThingWith noExtField parentLIE NoIEWildcard [childLIE] []
      -- Add AnnType for the parent if it's parenthesized (type operator)
      when isParentOperator $
        addSimpleAnnT parentLIE (DP (0, 0)) [(G AnnType, DP (0, 0))]
      addSimpleAnnT parentRdr (DP (0, if hasSibling then 1 else 0)) $ unqalDP 1 isParentOperator
      addSimpleAnnT childRdr (DP (0, 0)) [(G AnnVal, dp00)]
      addSimpleAnnT x (DP (0, 0)) [(G AnnOpenP, DP (0, 1)), (G AnnCloseP, DP (0, 0))]
      -- Parens are attachted to `pre`, so if `pre` was empty previously,
      -- we need change the ann key from `[]` to `:` to keep parens and other anns.
      unless hasSibling $
        transferAnn (L l' $ reverse pre) (L l' [x]) id
#else
          x :: LIE GhcPs = reLocA $ L l'' $ IEThingWith mempty parentLIE NoIEWildcard [childLIE]
#endif
      return $ L l it{ideclHiding = Just (hide, L l' $ reverse pre ++ [x])}
extendImportViaParent _ _ _ _ = lift $ Left "Unable to extend the import list via parent"

unIEWrappedName :: IEWrappedName (IdP GhcPs) -> String
unIEWrappedName (occName -> occ) = showSDocUnsafe $ parenSymOcc occ (ppr occ)

hasParen :: String -> Bool
hasParen ('(' : _) = True
hasParen _         = False

#if !MIN_VERSION_ghc(9,2,0)
unqalDP :: Int -> Bool -> [(KeywordId, DeltaPos)]
unqalDP c paren =
  ( if paren
      then \x -> (G AnnOpenP, DP (0, c)) : x : [(G AnnCloseP, dp00)]
      else pure
  )
    (G AnnVal, dp00)
#endif

------------------------------------------------------------------------------

-- | Hide a symbol from import declaration
hideSymbol ::
  String -> LImportDecl GhcPs -> Rewrite
hideSymbol symbol lidecl@(L loc ImportDecl{..}) =
  case ideclHiding of
    Nothing -> Rewrite (locA loc) $ extendHiding symbol lidecl Nothing
    Just (True, hides) -> Rewrite (locA loc) $ extendHiding symbol lidecl (Just hides)
    Just (False, imports) -> Rewrite (locA loc) $ deleteFromImport symbol lidecl imports
hideSymbol _ (L _ (XImportDecl _)) =
  error "cannot happen"

extendHiding ::
  String ->
  LImportDecl GhcPs ->
#if !MIN_VERSION_ghc(9,2,0)
  Maybe (Located [LIE GhcPs]) ->
#else
  Maybe (XRec GhcPs [LIE GhcPs]) ->
#endif
  DynFlags ->
  TransformT (Either String) (LImportDecl GhcPs)
extendHiding symbol (L l idecls) mlies df = do
  L l' lies <- case mlies of
#if !MIN_VERSION_ghc(9,2,0)
    Nothing -> flip L [] <$> uniqueSrcSpanT
#else
    Nothing -> flip L [] . noAnnSrcSpanDP0 <$> uniqueSrcSpanT
#endif
    Just pr -> pure pr
  let hasSibling = not $ null lies
  src <- uniqueSrcSpanT
  top <- uniqueSrcSpanT
  rdr <- liftParseAST df symbol
  let lie = reLocA $ L src $ IEName rdr
      x = reLocA $ L top $ IEVar noExtField lie
      singleHide = L l' [x]
#if !MIN_VERSION_ghc(9,2,0)
  when (isNothing mlies) $ do
    addSimpleAnnT
      singleHide
      dp00
      [ (G AnnHiding, DP (0, 1))
      , (G AnnOpenP, DP (0, 1))
      , (G AnnCloseP, DP (0, 0))
      ]
  addSimpleAnnT x (DP (0, 0)) []
  addSimpleAnnT rdr dp00 $ unqalDP 0 $ isOperator $ unLoc rdr
  if hasSibling
    then when hasSibling $ do
      addTrailingCommaT x
      addSimpleAnnT (head lies) (DP (0, 1)) []
      unless (null $ tail lies) $
        addTrailingCommaT (head lies) -- Why we need this?
    else forM_ mlies $ \lies0 -> do
      transferAnn lies0 singleHide id
#endif
  return $ L l idecls{ideclHiding = Just (True, L l' $ x : lies)}
 where
  isOperator = not . all isAlphaNum . occNameString . rdrNameOcc

deleteFromImport ::
  String ->
  LImportDecl GhcPs ->
#if !MIN_VERSION_ghc(9,2,0)
  Located [LIE GhcPs] ->
#else
  XRec GhcPs [LIE GhcPs] ->
#endif
  DynFlags ->
  TransformT (Either String) (LImportDecl GhcPs)
deleteFromImport (T.pack -> symbol) (L l idecl) llies@(L lieLoc lies) _ = do
  let edited = L lieLoc deletedLies
      lidecl' =
        L l $
          idecl
            { ideclHiding = Just (False, edited)
            }
#if !MIN_VERSION_ghc(9,2,0)
  -- avoid import A (foo,)
  whenJust (lastMaybe deletedLies) removeTrailingCommaT
  when (not (null lies) && null deletedLies) $ do
    transferAnn llies edited id
    addSimpleAnnT
      edited
      dp00
      [ (G AnnOpenP, DP (0, 1))
      , (G AnnCloseP, DP (0, 0))
      ]
#endif
  pure lidecl'
 where
  deletedLies =
    mapMaybe killLie lies
  killLie :: LIE GhcPs -> Maybe (LIE GhcPs)
  killLie v@(L _ (IEVar _ (L _ (unqualIEWrapName -> nam))))
    | nam == symbol = Nothing
    | otherwise = Just v
  killLie v@(L _ (IEThingAbs _ (L _ (unqualIEWrapName -> nam))))
    | nam == symbol = Nothing
    | otherwise = Just v
#if !MIN_VERSION_ghc(9,2,0)
  killLie (L lieL (IEThingWith xt ty@(L _ (unqualIEWrapName -> nam)) wild cons flds))
#else
  killLie (L lieL (IEThingWith xt ty@(L _ (unqualIEWrapName -> nam)) wild cons))
#endif
    | nam == symbol = Nothing
    | otherwise =
      Just $
        L lieL $
          IEThingWith
            xt
            ty
            wild
            (filter ((/= symbol) . unqualIEWrapName . unLoc) cons)
#if !MIN_VERSION_ghc(9,2,0)
            (filter ((/= symbol) . T.pack . Util.unpackFS . flLabel . unLoc) flds)
#endif
  killLie v = Just v
