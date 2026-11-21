-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/`). Table
-- alignment needs no configuration — registering the decoration provider is the whole
-- setup — so this turns it on out of the box.
--
-- `setup()` is a full reconfigure, so a user calling
-- `require("bemtvi-md-table").setup({...})` from their init.lua just re-applies it.
-- To switch it off use `btv.g.md_table_align = false` (global) or
-- `btv.b[bufnr].md_table_align = false` (one buffer), or `:MdTableToggle`. See
-- `:help bemtvi-md-table`.
require("bemtvi-md-table").setup({})
