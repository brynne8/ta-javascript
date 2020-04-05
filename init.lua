-- Copyright 2018 Alexander Misel. See LICENSE.
local re = require('re')

local M = {}

-- Sets default buffer properties for JavaScript files.
events.connect(events.LEXER_LOADED, function(lang)
  if lang == 'javascript' then
    buffer.use_tabs = false
    buffer.tab_width = 4
  end
end)

-- Autocompletion and documentation.
---
-- List of ctags files to use for autocompletion.
-- @class table
-- @name tags
M.tags = { _USERHOME..'/modules/js/browser.tags', _USERHOME..'/modules/js/ecma.tags',
  _USERHOME..'/modules/js/jquery.tags' }
---
-- Map of expression patterns to their types.
-- Expressions are expected to match after the '=' sign of a statement.
-- @class table
-- @name expr_types
M.expr_types = {
  ['^[\'"`]'] = '+String',
  ['^%['] = '+Array',
  ['^{'] = '+Object',
  ['^function'] = '+Function',
  ['^/'] = '+RegExp',
  ['^%$%(.-%)'] = 'jQuery.fn'
}

M.symbol_subst = {
  ['^[\'"`].*[\'"`]$'] = '+String',
  ['^%[.*%]$'] = '+Array',
  ['^/.+/[gimuy]*$'] = '+RegExp'
}

-- Only plain names of JS object are captured
M.js_object = re.compile[==[
  js_obj <- {| '{' __ name_val_pair __ (',' __ name_val_pair __)* '}' |}
  name_val_pair <- name %s* ':' %s* value

  name  <- {plain_name} / string_name / paired_bracket
  value <- (paired_brace / paired_bracket / paired_paren / string / [^,}])+
  __    <- (%s+ / block_comment / line_comment)*
  block_comment <- '/*' (!'*/' .)* '*/'
  line_comment  <- '//' [^%nl]*

  string_name <- '"' ({plain_name} '"' / [^"]* '"') / "'" ({plain_name} "'" / [^']* "'")
  string      <- '"' [^"]* '"' / "'" [^']* "'"
  plain_name  <- [a-zA-Z0-9_$]+
  paired_brace   <- '{' ([^{}] / paired_brace)* '}'
  paired_bracket <- '[' ([^][] / paired_bracket)* ']'
  paired_paren   <- '(' ([^()] / paired_paren)* ')'
]==]

M.js_expr = re.compile[[
  js_line      <- {| js_expr !. / js_expr_nonstart |}
  js_expr_nonstart <- ([^a-zA-Z0-9_$] js_expr / . js_expr_nonstart) !. / . js_expr_nonstart
  js_expr      <- ((jq_selector / prev_token) '.' / '') {:part: %a* :}
  jq_selector  <- {:symbol: '$' balanced -> 'jQuery.fn' :} func*
  func         <- '.' %a+ balanced
  prev_token   <- {:symbol: [a-zA-Z0-9_$/'"`]+ :} balanced?
  balanced     <- '(' ([^()] / balanced)* ')'
]]

local XPM = textadept.editing.XPM_IMAGES
local xpms = {
  c = XPM.CLASS, f = XPM.METHOD, m = XPM.VARIABLE
}
local sep = string.char(buffer.auto_c_type_separator)

local function has_value (tab, val)
  if not tab then
    return false
  end
  for index, value in ipairs(tab) do
    if value == val then return true end
  end
  return false
end

-- case insensitive pattern
-- https://stackoverflow.com/questions/11401890/case-insensitive-lua-pattern-matching
function ipattern(pattern)
  -- find an optional '%' (group 1) followed by any character (group 2)
  local p = pattern:gsub("(%%?)(.)", function(percent, letter)
    if percent ~= "" or not letter:match("%a") then
      -- if the '%' matched, or `letter` is not a letter, return "as is"
      return percent .. letter
    else
      -- else, return a case-insensitive character class of the matched letter
      return string.format("[%s%s]", letter:lower(), letter:upper())
    end
  end)

  return p
end

textadept.editing.autocompleters.javascript = function()
  local list = {}
  -- Retrieve the symbol behind the caret.
  local line, pos = buffer:get_cur_line()

  local symbol = ''
  local rawsymbol, op, part
  local matched = M.js_expr:match(line:sub(1, pos))
  if matched then
    rawsymbol, part = matched.symbol, matched.part
  else
    return
  end
  
  if rawsymbol then
    rawsymbol = rawsymbol:gsub('^window$', '')
    for patt, type in pairs(M.symbol_subst) do
      if rawsymbol:find(patt) then
        symbol = type
        break
      end
    end
  end

  -- Attempt to identify the symbol type.
  local line_num = buffer:line_from_position(buffer.current_pos)
  local name_patt = '^' .. part
  local name_ipatt = ipattern('^' .. part)
  if rawsymbol and symbol == '' then
    symbol = rawsymbol:match('([%w_%$%.]*)$')

    if symbol ~= '' then
      local buffer = buffer
      local assignment = symbol:gsub('(%p)', '%%%1') .. '%s*=%s*()([^;]-)%s*;?%s*$'
      for i = line_num - 1, 1, -1 do
        local pos, expr = buffer:get_line(i):match(assignment)
        if expr then
          local symbol_changed = false
          for patt, type in pairs(M.expr_types) do
            if expr:find(patt) then
              symbol = type
              symbol_changed = true
              break
            end
          end
          if symbol_changed then
            if symbol == '+Object' then
              local start_pos = buffer:position_from_line(i) + pos
              local end_pos = buffer:brace_match(start_pos, 0)
              local obj_props = M.js_object:match(buffer:text_range(start_pos, end_pos + 1))
              if obj_props then
                for _, name in ipairs(obj_props) do
                  if name:match(name_ipatt) then
                    list[#list + 1] = string.format('%s%s%d', name, sep, xpms.m)
                  end
                end
              end
            end
            break
          end
          local new_instance = expr:match('^new%s+([%w_.]+)%s*%b()$')
          if new_instance then
            symbol = '+' .. new_instance -- e.g. a = new Foo()
            break
          end
        end
      end
    end
  end
  ui.statusbar_text = symbol
  -- Search through ctags for completions for that symbol.
  ::start::
  for _, filename in ipairs(M.tags) do
    if not lfs.attributes(filename) then goto continue end
    local hasFound = false
    for line in io.lines(filename) do
      local name = line:match('^%S+')
      if name == symbol then
        local ret = line:match('typeref:(.*)$')
        if ret then
          symbol = ret
          goto start
        end
      elseif not name:find(name_patt) then
        if hasFound and not name:find(name_ipatt) then break end
      elseif not list[name] then
        hasFound = true
        local fields = line:match(';"\t(.*)$')
        if fields then
          local k, class = fields:sub(1, 1), fields:match('class:(%S+)') or ''

          if class == symbol then
            list[#list + 1] = string.format('%s%s%d', name, sep, xpms[k])
            list[name] = true
          end
        end
      end
    end
    ::continue::
  end
  return #part, list
end

-- Snippets.

if type(snippets) == 'table' then
---
-- Table of JS-specific snippets.
-- @class table
-- @name _G.snippets.javascript
  snippets.javascript = {
    ['do'] = 'do {\n\t%0\n} while (%1)',
    ['if'] = 'if (%1) {\n\t%0\n}',
    eif = 'else if (%1) {\n\t%0\n}',
    ['else'] = 'else {\n\t%0\n}',
    interval = 'setInterval(%0(function), %1(delay))',
    timeout = 'setTimeout(%0(function), %1(delay))',
    ['for'] = 'for (%1; %2; %3) {\n\t%0\n}',
    fori = 'for (%1 in %2) {\n\t%0\n}',
    ['while'] = 'while (%1) {\n\t%0\n}',
    try = 'try {\n\t%1\n} catch (%2(e)) {\n\t%3\n}',
    ['/*'] = '/**\n * %0\n */',
    log = 'console.log(%1)',
    func = 'function %1(name) (%2) {\n\t%0\n}',
    afunc = 'function (%1) {\n\t%0\n}'
  }
end

return M
