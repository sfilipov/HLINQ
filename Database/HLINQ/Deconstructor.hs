{-# LANGUAGE TemplateHaskell #-}
module Database.HLINQ.Deconstructor where
import Control.Monad
import Language.Haskell.TH.Syntax
import Language.Haskell.TH
import Data.List(partition)
import Database.HLINQ.Constructor
import System.IO.Unsafe

hsBoolOp :: [Name]
hsBoolOp = ['(&&),'(||), 'not]

hsBinOp :: [Name]
hsBinOp = ['(==), '(<), '(>), '(<=), '(>=), '(/=)]

guardExp :: Exp -> ValueExpr
guardExp (InfixE (Just exp1) (VarE fun) (Just exp2))
 | fun `elem` hsBinOp = BinOp (appExp exp1) (hsBinOpToSQL fun) (appExp exp2)
 | fun `elem` hsBoolOp = BinOp (guardExp exp1) (hsBoolOpToSQL fun) (guardExp exp2)
 | otherwise = error $ "Unsupported operator = " ++ (nameBase fun)
guardExp (AppE (VarE fun) exp)
 | fun == 'null = NotExists (expQToSQL (returnQ exp))
 | otherwise = error $ show exp


hsBoolOpToSQL :: Name -> String
hsBoolOpToSQL name
 | name == '(&&) = "AND"
 | name == '(||) = "OR"
 | name == 'not = "NOT"
 | otherwise = ""

hsBinOpToSQL :: Name -> String
hsBinOpToSQL name
 | name == '(==) = "="
 | otherwise = nameBase name

returnExp :: Exp -> [ValueExpr]
returnExp (TupE exps) = map appExp exps
returnExp exp = [appExp exp]

appExp :: Exp -> ValueExpr
appExp (InfixE (Just exp1) (VarE op) (Just exp2)) = BinOp (appExp exp1) (nameBase op) (appExp exp2)
appExp (AppE (VarE column) (VarE table)) = DIden (nameBase column) (showName table)
appExp (LitE (IntegerL val)) = NumLit val
appExp (LitE (StringL val)) = StringLit val
appExp (ListE str@[LitE (CharL x)]) = StringLit $ rebuildString str
appExp (ListE str@((LitE (CharL x)):xs)) = StringLit $ rebuildString str
appExp (AppE (VarE fun) (TupE exps))
 | fun == 'fst = appExp $ head exps
 | fun == 'snd = appExp $ exps !! 1
 | otherwise = error "Only one and two tuples supported"
appExp exp = error $ "Appexp err: " ++ show exp


rebuildString :: [Exp] -> String
rebuildString [] = ""
rebuildString [LitE (CharL x)] = [x]
rebuildString ((LitE (CharL x)):xs) = [x] ++ rebuildString xs

bindS' :: Pat -> Exp -> String
bindS' (VarP varName) (VarE table) = show $ TRAlias (TRSimple (nameBase table)) (nameBase varName) --show TableAlias {alias = showName varName, tableName = showName table}


data Subst = Subst {varExp :: Exp, valExp :: Exp} deriving (Eq, Show)

normalise :: ExpQ -> ExpQ
normalise exprQ = do
  expr <- exprQ
  let reduced = betaReduce expr
  let reduced2 = reduce  reduced
  let reduced3 = DoE $ flatten $ (\(DoE stmts) -> stmts) reduced2
  let reducedAdHoc = DoE $ adHocReduction $ (\(DoE stmts) -> stmts) reduced3
  return reducedAdHoc

reduce :: Exp -> Exp
reduce (DoE expr) = DoE $ symbolicReduceLoop expr
reduce (VarE exp) = error $ "The queries must be spliced into the quotes, add '$$' in front of " ++ show (nameBase exp)
reduce _ = error "Only do expression syntax is supported"

symbolicReduceLoop :: [Stmt] -> [Stmt]
symbolicReduceLoop stmts
  | stmts == symbolicReduceInnerLoop stmts = stmts
  | otherwise = symbolicReduceLoop $ symbolicReduceInnerLoop stmts

symbolicReduceInnerLoop :: [Stmt] -> [Stmt]
symbolicReduceInnerLoop [] = []
symbolicReduceInnerLoop [x] = symbolicReduce x []
symbolicReduceInnerLoop (x:xs) = symbolicReduce x xs

symbolicReduce :: Stmt -> [Stmt] -> [Stmt]
symbolicReduce allExp@(BindS pat (DoE ((NoBindS (InfixE (Just (VarE fun)) (|$|) (Just exp))) : xs))) rem
  | fun == 'guard = forIf allExp ++ symbolicReduceInnerLoop rem
  | fun == 'return = forYld allExp rem
symbolicReduce allExp@(BindS pat ((DoE (NoBindS (AppE (VarE fun) (exp)) : xs)))) rem
  | fun == 'guard = forIf allExp ++ symbolicReduceInnerLoop rem
  | fun == 'guard && exp == (ConE 'True) = symbolicReduceInnerLoop rem
  | fun == 'guard && exp == (ConE 'False) = []
  | fun == 'return = forYld allExp rem

symbolicReduce allExp@(BindS pat (ListE [])) rem = []
symbolicReduce allExp@(BindS pat exp@(DoE _)) rem = forFor allExp ++ symbolicReduceInnerLoop rem
symbolicReduce xs rem = [xs] ++ symbolicReduceInnerLoop rem



forFor :: Stmt -> [Stmt]
forFor (BindS pat (DoE ((BindS innerPat innerExp):xs))) = [BindS innerPat innerExp, BindS pat (DoE xs)]

forIf :: Stmt -> [Stmt]
forIf (BindS pat (DoE (grd@(NoBindS (InfixE (Just (VarE fun)) (|$|) (Just exp))) : xs)))
  | fun == 'guard = [grd, BindS pat (DoE xs)]

forYld :: Stmt -> [Stmt] -> [Stmt]
forYld (BindS (VarP pat) (DoE (rtn@(NoBindS (InfixE (Just (VarE fun)) (|$|) (Just exp))) : xs))) rem
  | fun == 'return = map (\x -> substituteStatements x (Subst (VarE pat) exp)) rem
forYld (BindS (VarP pat) (DoE (rtn@(NoBindS (AppE (VarE fun)  exp)) : xs))) rem
  | fun == 'return = map (\x -> substituteStatements x (Subst (VarE pat) exp)) rem
forYld exp rem = error $ "forYld: " ++ (show exp)



flatten :: [Stmt] -> [Stmt]
flatten [] = []
flatten [(NoBindS (DoE stmts))] = stmts
flatten [x] = [x]
flatten ((NoBindS (DoE stmts)):xs) = stmts ++ flatten xs
flatten (x:xs) = x : flatten xs

adHocReduction :: [Stmt] -> [Stmt]
adHocReduction stmts = afterReduction where
            guards = partition isGuard stmts
            afterReduction = snd guards ++ (joinGuards $ fst guards)

isGuard :: Stmt -> Bool
isGuard (NoBindS (InfixE (Just (VarE fun)) (|$|) (Just exp)))
  | fun == 'guard = True
isGuard _ = False


-- Joins the conditions form guard statement to a single large guard statement for convenient transformation to SQL.
joinGuards :: [Stmt] -> [Stmt]
joinGuards [] = []
joinGuards [x] = [x]
joinGuards [guard1, guard2] = [NoBindS (InfixE (Just (VarE 'guard)) (VarE '($)) (Just (InfixE (Just (extractFromGuard guard1)) (VarE '(&&)) (Just (extractFromGuard guard2)))))]
joinGuards (guard1 : guard2 : xs) = joinGuards $ [NoBindS (InfixE (Just (VarE 'guard)) (VarE '($)) (Just (InfixE (Just (extractFromGuard guard1)) (VarE '(&&)) (Just (extractFromGuard guard2)))))] ++ xs

--joinGuards [(NoBindS (InfixE fun@_ dollar@_ (Just exp1))),(NoBindS (InfixE _ _ (Just exp2)))] = [NoBindS (InfixE fun dollar (Just (InfixE (Just exp1) (VarE '(&&)) (Just exp2))))]
--joinGuards ((NoBindS (InfixE fun@_ dollar@_ (Just exp1))):(NoBindS (InfixE _ _ (Just exp2))):xs) = joinGuards $ [NoBindS (InfixE fun dollar (Just (InfixE (Just exp1) (VarE '(&&)) (Just exp2))))] ++ xs

extractFromGuard :: Stmt -> Exp
extractFromGuard (NoBindS (InfixE _ _ (Just exp))) = exp
extractFromGuard (NoBindS (AppE _ exp)) = exp

-- Applies beta reduction to the expression, meant to resolve lambda functions inside the expression.
betaReduce :: Exp -> Exp
betaReduce expr = foldr (\y x -> substitute x y) simplified toSubst where
  simplified = if (suitableForReduction expr) then simplify expr else expr
  toSubst = extractPairs expr


-- Extracts name value pairs which will be substituted during beta reduction stage.
extractPairs :: Exp -> [Subst]
extractPairs expr@(AppE expr1 expr2) = zipWith (\(VarP x) y -> Subst (VarE x) y) (getVarNames expr) (reverse $ getVals expr)
extractPairs _ = []


-- Gets variable names of the lambda function which will need to be substited
getVarNames :: Exp -> [Pat]
getVarNames (AppE expr _) = getVarNames expr
getVarNames (LamE vars _) = vars
getVarNames _ = []
-- getVarNames exp = error $ "getVarNames Unsupported syntax: " ++ (show exp)

-- Gets the values to which the variables will be substituted
getVals :: Exp -> [Exp]
getVals (AppE expr1 expr2) = expr2 : (getVals expr1)
getVals (LamE _ _) = []

-- Discards the AppE from applying values to the lambda function and the LamE itself, since it is not relevent after reduction
simplify :: Exp -> Exp
simplify (AppE expr1 expr2) = simplify expr1
simplify (LamE _ expr) = simplify expr
simplify expr@(DoE _) = expr
simplify expr = expr

substitute :: Exp -> Subst -> Exp
substitute (DoE exp) subst = DoE $ map (\x -> substituteStatements x subst) exp
substitute expr@(AppE exp1 exp2) subst
 | suitableForReduction expr = substitute (betaReduce expr) subst
 | otherwise = AppE (substitute exp1 subst) (substitute exp2 subst)
substitute (LamE pat exp) subst = LamE pat (substitute exp subst)
substitute (InfixE (Just exp1) midExp@(_) (Just exp2)) subst = InfixE (Just $ substitute exp1 subst) midExp (Just $ betaReduce $ substitute exp2 subst)
substitute var@(VarE _) subst = substituteExp var subst
substitute exp@(LitE _) subst = exp
substitute exp@(TupE exps) subst = TupE $ map (\x -> substitute x subst) exps
substitute exp _  = error $ "\nUnsupported syntax: " ++ (show exp)

suitableForReduction :: Exp -> Bool
suitableForReduction (AppE exp@(AppE _ _) _) = suitableForReduction exp
suitableForReduction exp@(AppE (LamE _ _) _) = True
suitableForReduction _ = False

substituteExp :: Exp -> Subst -> Exp
substituteExp exp subst
  | exp == (varExp subst) = if (suitableForReduction $ valExp subst) then betaReduce $ valExp subst else valExp subst
  | otherwise = exp

substituteStatements :: Stmt -> Subst -> Stmt
substituteStatements (NoBindS exp) subst = NoBindS $ (substitute exp subst)
substituteStatements (BindS pat exp) subst = BindS pat $ substitute exp subst
substituteStatements (LetS decs) subst = LetS $ map (\(ValD pat (NormalB exp) decls) -> (ValD pat (NormalB (substitute exp subst)) decls)) decs

expQToSQL :: ExpQ -> QueryExpr
expQToSQL exp = unsafePerformIO . runQ . fmap expToSQL $ normalised where
          normalised = normalise exp

tExpQToSQL :: Q (TExp a) -> QueryExpr
tExpQToSQL exp = unsafePerformIO . runQ . fmap expToSQL $ normalised where
          normalised = normalise $ unTypeQ exp

expToSQL :: Exp -> QueryExpr
expToSQL (DoE stmt) = Select {
  qeSelectList = map (\x -> (x, Nothing)) $ returnStatements stmt,
  qeFrom = bindStatements stmt,
  qeWhere = whereS,
  qeGroupBy = [],
  qeHaving = Nothing,
  qeOrderBy = []
} where
  guardS = (guardStatements stmt)
  whereS = case length guardS of
          0 -> Nothing
          otherwise -> Just $ head guardS
expToSQL _ = error "Unimplemented syntax"

expQToExpr :: ExpQ -> [ValueExpr]
expQToExpr = unsafePerformIO . runQ . fmap expToExpr

expToExpr :: Exp -> [ValueExpr]
expToExpr (DoE stmt) = returnStatements stmt

bindStatements :: [Stmt] -> [TableRef]
bindStatements [(BindS pat exp)] = [(bindStatement pat exp)]
bindStatements [x] = []
bindStatements ((BindS pat exp): xs) = (bindStatement pat exp) : (bindStatements xs)
bindStatements (x : xs) = [] ++ (bindStatements xs)

bindStatement :: Pat -> Exp -> TableRef
bindStatement (VarP varName) (VarE table) = TRAlias (TRSimple (nameBase table)) (showName varName)
bindStatement (VarP varName) (AppE (VarE table) (VarE db)) = TRAlias (TRSimple (nameBase table)) (showName varName)

noBindStatements :: [Stmt] -> [ValueExpr]
noBindStatements [(NoBindS exp)] = (noBindStatement exp)
noBindStatements ((NoBindS exp) : xs) = (noBindStatement exp) ++ (noBindStatements xs)
noBindStatements [x] = []
noBindStatements (x:xs) = [] ++ (noBindStatements xs)

guardStatements :: [Stmt] -> [ValueExpr]
guardStatements [(NoBindS exp)] = (guardStatement exp)
guardStatements ((NoBindS exp) : xs) = (guardStatement exp) ++ (guardStatements xs)
guardStatements [x] = []
guardStatements (x:xs) = [] ++ (guardStatements xs)

guardStatement :: Exp -> [ValueExpr]
guardStatement (InfixE (Just (VarE fun)) (|$|) (Just exp))
 | fun == 'guard = [guardExp exp] -- Where clause is built from this part
 | fun == 'return = []
guardStatement (AppE (VarE fun) (exp))
 | fun == 'return = []
 | fun == 'guard = [guardExp exp]
guardStatement exp = error $ "Guard statement error: " ++  show exp

returnStatements :: [Stmt] -> [ValueExpr]
returnStatements [(NoBindS exp)] = (returnStatement exp)
returnStatements ((NoBindS exp) : xs) = (returnStatement exp) ++ (returnStatements xs)
returnStatements [x] = []
returnStatements (x:xs) = [] ++ (returnStatements xs)

returnStatement :: Exp -> [ValueExpr]
returnStatement (InfixE (Just (VarE fun)) (|$|) (Just exp))
 | fun == 'return = returnExp exp -- Where clause is built from this part
 | fun == 'guard = []
returnStatement (AppE (VarE fun) (exp))
 | fun == 'return = returnExp exp
 | fun == 'guard = []
returnStatement exp = error $ "Error in return statement: \n" ++  show exp


noBindStatement :: Exp -> [ValueExpr]
noBindStatement (InfixE (Just (VarE fun)) (|$|) (Just exp))
 | fun == 'guard = [guardExp exp]
 | fun == 'return = returnExp exp -- Where clause is built from this part
noBindStatement (DoE exps) = undefined
noBindStatement exp = error $ "NoBinds error: " ++ show exp


isEmpty :: [a] -> Bool
isEmpty [] = True
isEmpty a = False

types :: [(String,[String])] -> [(String, [(String, String)])] -> [String]
types tables infos= do
        (infoTable, infoFields) <- infos
        (table, fields) <- tables
        guard $ (table == infoTable)
        let returnTypes = matchTypes fields infoFields
        returnTypes


matchTypes :: [String] -> [(String, String)] -> [String]
matchTypes [] infos = []
matchTypes [x] infos = matchType x infos
matchTypes (x:xs) infos = matchType x infos ++ (matchTypes xs infos)

matchType :: String -> [(String, String)] -> [String]
matchType fieldName [(infoField, infoType)]
  | fieldName == infoField = [infoType]
  | otherwise = []
matchType fieldName ((infoField, infoType) : xs)
  | fieldName == infoField = [infoType]
  | otherwise = matchType fieldName xs

getSelectTypes :: (ValueExpr, Maybe String) -> ValueExpr
getSelectTypes (iden@(DIden _ _), _) = iden
getSelectTypes ((BinOp iden@(DIden _ _) _ _), _) = iden

recordsToTables :: [ValueExpr] -> TableRef -> [String]
recordsToTables [(((DIden field tableAlias)))] table@(TRAlias (TRSimple ref) s)
  | tableAlias == s = [field]
  | otherwise = []
recordsToTables (((DIden field tableAlias)): ys) table@(TRAlias (TRSimple ref) s)
  | tableAlias == s = (field : (recordsToTables ys table))
  | otherwise = recordsToTables ys table


fieldsToTables :: [ValueExpr] -> [TableRef] -> [(String, [String])]
fieldsToTables records tables = do
                  table@(TRAlias (TRSimple ref) s) <- tables
                  let fields = recordsToTables records table
                  guard $ not $ isEmpty fields
                  return (ref, fields)
