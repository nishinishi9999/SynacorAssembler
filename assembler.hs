module Main where

import Data.Word (Word16)
import Data.Char (isLower, isAlpha, isNumber, ord, toLower)
import Data.List (all)
import qualified Data.ByteString.Lazy as BS
import qualified Data.Binary.Put as P
import qualified Data.List.Split as S
import System.IO
import Tokenizer
import Debug.Trace

-- |
-- | Datatypes
-- |

data ConstType = NumType Int | ChrType Char | StrType [Char]
  deriving Show

data Register = A | B | C | D | E | F | G | H
  deriving Show

data Section = Section { s_name :: [Char], s_line :: Int, s_tokens :: [TokenInfo] }
  deriving Show

data Const =
    C_Num { c_name :: [Char], c_num :: Int   }
  deriving (Eq, Show)

data Tag = Tag { _jmp_ptr :: Int, _name :: [Char] }
  deriving Show

-- |
-- | Types
-- |

type Identifier = [Char]

-- |
-- | Constants
-- |

_MAX_NUM :: Int
_MAX_NUM = 32768

-- |
-- | Boolean checking functions
-- |

is_reg :: Int -> Bool
is_reg   n = n > 32767 && n < 32775
is_value :: Int -> Bool
is_value n = n >= 0 && n < 32776

to_int :: [Char] -> Int
to_int n = read n :: Int

-- |
-- | Error throwing
-- |

--throw_err :: [Char] -> Int -> ()
throw_err err line = error $ "Error: " ++ err ++ " at line " ++ (show line)

throw_invalid_token t = throw_err ("Invalid token: " ++ (show . t_token $ t)) (t_line t)

-- |
-- | Second pass - Sections
-- |

check_sections sections
  | not . has_section "data" $ sections = throw_err "Lacking data section" (-1)
  | not . has_section "code" $ sections = throw_err "Lacking code section" (-1)
  | length sections /= 2 = throw_err "Invalid number of sections (unimplemented)" (-1)
  | otherwise            = sections
  where has_section name sections = any (\s -> s_name s == name) $ sections

split_sections :: [TokenInfo] -> [Section]
split_sections = map to_section . split_sections'
  where split_sections' = S.split (S.dropBlanks $ S.keepDelimsL $ S.whenElt (is_section_token . t_token))
        to_section tokens = case t_token . head $ tokens of
          T_Section name -> Section {
                             s_name   = name
                           , s_line   = (t_line . head $ tokens)
                           -- | Drop following Newline
                           , s_tokens = drop 2 tokens
                         }
          _         -> throw_err "Token outside of section" (t_line . head $ tokens)
        is_section_token (T_Section _) = True
        is_section_token _             = False
  
-- |
-- | Third pass - Parse sections
-- |

parse_num :: Int -> Int
parse_num n
  | n >= 0 = mod n _MAX_NUM
  | n < 0  = parse_num $ n + _MAX_NUM

filter_tags :: [TokenInfo] -> [TokenInfo]
filter_tags = filter (is_tag . t_token)
  where is_tag (T_Tag name) = True
        is_tag _            = False

-- | .data

tag_name :: TokenInfo -> [Char]
tag_name t = case t_token t of
  T_Tag name -> name
  _          -> throw_err "Invalid tag in const checking" (t_line t)

check_consts :: [Const] -> [TokenInfo] -> [Const]
check_consts [] _ = []
check_consts (c:consts) tags
  | any (\c' -> c_name c == c_name c') consts =
    throw_err ("Redeclared constant: " ++ (c_name c)) (-1)
  | any (\t -> is_tag t c) tags =
    throw_err ("Ambiguous constant: " ++ (c_name c)) (-1)
  | otherwise = c : check_consts consts tags
  where is_tag t c = c_name c == tag_name t

check_entry_point:: [TokenInfo] -> [TokenInfo]
check_entry_point tags
  | not . any (\t -> tag_name t == "main") $ tags = throw_err "Entry point not defined" (-1)
  | otherwise = tags

check_tags :: [TokenInfo] -> [TokenInfo]
check_tags [] = []
check_tags (t:tags)
  | any (\t' -> tag_name t == tag_name t') tags = throw_err "Redeclarated tag" (t_line t)
  | otherwise   = t : check_tags tags

parse_s_data :: [TokenInfo] -> [Const]
parse_s_data ts = d_identifier ts
  where d_identifier []     = []
        d_identifier (t:ts) = case t_token t of
          T_Identifier t_name' -> d_type ts t_name'
          _                    -> throw_err "Invalid token" (t_line t)
        d_type (t:ts) t_name' = case t_token t of
          T_Type t_type' -> d_value ts t_name' t_type'
          _              -> throw_err "Invalid token" (t_line t)
        d_value (t:ts) t_name' t_type' = case t_token t of
          T_Number n -> if t_type' == "NUM"
            then (C_Num t_name' $ parse_num n) : d_newline ts
            else throw_err "Invalid constant type" (t_line t)
          T_Chr    c -> if t_type' == "CHR"
            then (C_Num t_name' $ ord c) : d_newline ts
            else throw_err "Invalid constant type" (t_line t)
          _          -> throw_err "Invalid token" (t_line t)
        d_newline (t:ts) = case t_token t of
          T_Newline -> d_identifier ts
          _         -> throw_err "Invalid token" (t_line t)

-- | .code

resolve_identifier :: [Const] -> [TokenInfo] -> [Char] -> Int -> Token
resolve_identifier const' tags name line_n
  | null c_matches && null tag_matches =
    throw_err ("Constant or tag not declared: " ++ name) line_n
  | null c_matches = T_Identifier name
  | otherwise = case head c_matches of
    C_Num _ n  -> T_Number n
  where c_matches   = filter (\c -> c_name c == name) const'
        tag_matches = filter (\t -> tag_name t == name) tags

fix_s_code :: [Const] -> [TokenInfo] -> [TokenInfo] -> [TokenInfo]
fix_s_code _      _    [] = []
fix_s_code const' tags (t:ts) = t' : fix_s_code const' tags ts
  where resolve_reg r = 32671 + (ord . toLower $ r)
        t' = TokenInfo (t_line t) $ case t_token t of
          T_Number n        -> T_Number . parse_num $ n
          T_Chr c           -> T_Number . ord $ c
          T_Register r      -> T_Number . resolve_reg $ r
          T_Identifier name -> resolve_identifier const' tags name (t_line t)
          _                 -> t_token t

-- |
-- | Fourth pass - Tags
-- |

-- | (Opcode, Number of arguments)
instr_info :: [Char] -> (Int, [String])
instr_info op = case op of
  "HALT"   -> (0x00, [])
  "SET"    -> (0x01, ["REG", "VAL"])
  "PUSH"   -> (0x02, ["VAL"])
  "POP"    -> (0x03, ["REG"])
  "EQ"     -> (0x04, ["REG", "VAL", "VAL"])
  "GT"     -> (0x05, ["REG", "VAL", "VAL"])
  "JMP"    -> (0x06, ["TAG"])
  "JT"     -> (0x07, ["VAL", "TAG"])
  "JF"     -> (0x08, ["VAL", "TAG"])
  "ADD"    -> (0x09, ["REG", "VAL", "VAL"])
  "MULT"   -> (0x0A, ["REG", "VAL", "VAL"])
  "MOD"    -> (0x0B, ["REG", "VAL", "VAL"])
  "AND"    -> (0x0C, ["REG", "VAL", "VAL"])
  "OR"     -> (0x0D, ["REG", "VAL", "VAL"])
  "NOT"    -> (0x0E, ["REG", "VAL"])
  "RMEM"   -> (0x0F, ["REG", "VAL"])
  "WMEM"   -> (0x10, ["VAL", "REG"])
  "CALL"   -> (0x11, ["TAG"])
  "RET"    -> (0x12, [])
  "OUT"    -> (0x13, ["VAL"])
  "IN"     -> (0x14, ["REG"])
  "NOOP"   -> (0x15, [])
  _        -> throw_err "Invalid opcode" (-1)

fourth_pass :: [TokenInfo] -> Int -> [Tag]
fourth_pass [] _ = []
fourth_pass (t:ts) ptr = case t_token t of
  T_Tag    name -> (Tag ptr name) : fourth_pass ts (traceShow ptr ptr)
  T_Comma       -> fourth_pass ts ptr
  T_Newline     -> fourth_pass ts ptr
  _             -> fourth_pass ts (ptr+1)

-- |
-- | Fifth pass - Opcode parsing
-- |

is_num n = n >= 0 && n < 32768

res_raw t tags = case t_token t of
  T_Number n -> n
  T_Identifier name -> _jmp_ptr . head . filter (\tag -> _name tag == name) $ tags

fifth_pass :: [TokenInfo] -> [Tag] -> [Int]
fifth_pass [] _ = []
fifth_pass (t:ts) tags = case t_token t of
  T_Tag    name -> fifth_pass ts tags
  T_Opcode name -> if null args_t
    then f_newline ts args_t
    else op : f_arg ts args_t
    where (op, args_t) = instr_info name
  T_Newline     -> fifth_pass ts tags
  _             -> throw_invalid_token t
  where -- | Argument
        f_arg ts [] = throw_err "f_arg: No more tokens" (-1)
        f_arg (t:ts) (arg_t:args_t) = case arg_t of
          -- | 32767 < n < 32776
          "REG" -> if is_reg n then n : f_endarg ts args_t else throw_err "Not a register" line
          -- | Number literal or register
          "VAL" -> n : f_endarg ts args_t
          -- | No current restriction
          "TAG" -> n : f_endarg ts args_t
          where n = res_raw t tags
                line = t_line t
        -- | End of the argument
        f_endarg (t:ts) args_t = case t_token t of
          T_Comma   -> f_arg ts args_t
          T_Newline -> f_newline (t:ts) args_t
          _         -> throw_invalid_token t
        f_newline (t:ts) args_t = if null args_t
            -- | All arguments are valid
            then fifth_pass ts tags
            -- | There are arguments not resolved
            else throw_err "Not enough arguments" (t_line t)

main :: IO ()
main = do
  src <- openFile "src/test.txt" ReadMode >>= hGetContents
  putStrLn src

  -- | Tokenizer
  
  let tokens = tokenize [] (lines src) 1
  putStrLn "First pass - Tokenize"
  mapM_ putStrLn $ map (("    "++) . show) tokens

  -- | Section
  
  let sections = split_sections tokens
  putStrLn "\nSecond pass - Split into sections"
  mapM_ putStrLn $ map (\s ->
       (s_name s ++ " (Line " ++ (show . s_line $ s) ++ ")\n")
    ++ (concat . map (("    "++) . (++"\n") . show) . s_tokens $ s)
    ) sections

  -- | Section parsing
  
  let s_data = s_tokens . head . filter ((=="data") . s_name) $ sections
  let s_code = s_tokens . head . filter ((=="code") . s_name) $ sections
  let tags_t = check_tags . check_entry_point . filter_tags $ s_code

  let consts  = check_consts (parse_s_data s_data) tags_t
  let s_code' = fix_s_code consts tags_t s_code

  putStrLn "\nThird pass - Section parsing"
  putStrLn "Consts"
  mapM_ print consts
  putStrLn "Tags"
  mapM_ print tags_t
  putStrLn "Fix .code"
  mapM_ putStr $ map (("    "++) . (++"\n") . show) $ s_code'

  -- | Fourth pass
  let tags = fourth_pass s_code' 0
  putStrLn "\nFourth pass - Tags"
  mapM_ print tags

  -- | Fifth pass
  putStrLn "\nFifth pass - Bytecode"
  let bytecode = (fifth_pass s_code' tags) ++ [0, 0]
  print bytecode

  BS.writeFile "bin/test.bin" $ P.runPut $ mapM_ P.putWord16le $ map (\n -> fromIntegral n :: Word16) bytecode

