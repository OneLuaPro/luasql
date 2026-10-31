-- LDoc configuration of the LuaSQL documentation.
-- Run from the root of the repository:
--   ldoc -c doc/ldoc/config.ld -d <output directory> .
-- Paths below are relative to this directory.

project = 'LuaSQL'
title = 'LuaSQL Reference'
description = 'Database access for Lua, for OneLuaPro'
full_description = [[
LuaSQL connects Lua programs to databases: it opens connections, executes
SQL statements and reads the results row by row. Start with the
@{01-introduction.md|introduction}.
]]

file = { '../../src/ls_oci8.c' }
topics = {
   'manual/01-introduction.md',
   'manual/02-prepared-statements.md',
   'manual/03-oracle.md',
}
examples = {
   'examples/oci8_basics.lua',
   'examples/oci8_prepared.lua',
   'examples/oci8_transactions.lua',
   'examples/oci8_lobs_json.lua',
   'examples/oci8_lanes.lua',
}

format = 'markdown'
use_markdown_titles = true
backtick_references = false
no_space_before_args = true
sort_modules = false
kind_names = { topic = 'Manual', module = 'Drivers' }

style = '!pale'
custom_css = 'luasql.css'
