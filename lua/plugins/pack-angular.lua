local function angular_project_node_modules(root_dir)
  local direct = vim.fs.joinpath(root_dir, "node_modules")
  if vim.uv.fs_stat(direct) then
    return direct
  end

  local found = vim.fs.find("node_modules", { path = root_dir, upward = true })[1]
  return found and vim.fs.normalize(found) or nil
end

local function angular_core_version(root_dir)
  local node_modules = angular_project_node_modules(root_dir)
  local project_root = node_modules and vim.fs.dirname(node_modules) or root_dir
  local package_json = vim.fs.joinpath(project_root, "package.json")
  if not vim.uv.fs_stat(package_json) then
    return ""
  end

  local ok, content = pcall(vim.fn.readblob, package_json)
  if not ok or not content then
    return ""
  end

  local decoded_ok, json = pcall(vim.json.decode, content)
  if not decoded_ok or type(json) ~= "table" then
    return ""
  end

  local version = (json.dependencies or {})["@angular/core"] or (json.devDependencies or {})["@angular/core"] or ""
  return version:match("%d+%.%d+%.%d+") or ""
end

local function append_existing(paths, path)
  if path and path ~= "" and vim.uv.fs_stat(path) and not vim.tbl_contains(paths, path) then
    paths[#paths + 1] = path
  end
end

local function is_inside_event_binding(line, col, word)
  local cursor = col + 1
  local search_from = 1

  while true do
    local attr_start, value_start = line:find('%([%w:._-]+%)%s*=%s*"', search_from)
    if not attr_start then
      return false
    end

    local value_end = line:find('"', value_start + 1, true)
    if not value_end then
      return false
    end

    if cursor >= value_start + 1 and cursor <= value_end - 1 then
      local expression = line:sub(value_start + 1, value_end - 1)
      return expression:match("^%s*" .. word .. "%s*%(") ~= nil
    end

    search_from = value_end + 1
  end
end

local function angular_template_method_fallback()
  local word = vim.fn.expand("<cword>")
  if not word:match("^[_%a][_%w]*$") then
    return false
  end

  local source = vim.api.nvim_buf_get_name(0)
  local target = source:gsub("%.component%.html$", ".component.ts")
  if source == target or not vim.uv.fs_stat(target) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  if not is_inside_event_binding(line, cursor[2], word) then
    return false
  end

  local ok, lines = pcall(vim.fn.readfile, target)
  if not ok then
    return false
  end

  for lnum, line in ipairs(lines) do
    if
      line:match("^%s*" .. word .. "%s*%(")
      or line:match("^%s*public%s+" .. word .. "%s*%(")
      or line:match("^%s*protected%s+" .. word .. "%s*%(")
      or line:match("^%s*private%s+" .. word .. "%s*%(")
    then
      vim.cmd.edit(vim.fn.fnameescape(target))
      vim.api.nvim_win_set_cursor(0, { lnum, math.max(line:find(word, 1, true) - 1, 0) })
      vim.cmd.normal({ "zz", bang = true })
      return true
    end
  end

  return false
end

local function angular_definition()
  if not vim.tbl_contains({ "html", "htmlangular" }, vim.bo.filetype) then
    return vim.lsp.buf.definition()
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "angularls" })
  local client = clients[1]
  if not client then
    return vim.lsp.buf.definition()
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
  client:request("textDocument/definition", params, function(err, result)
    if err then
      vim.notify(err.message, vim.log.levels.ERROR)
      return
    end

    if result and not vim.tbl_isempty(result) then
      local locations = (result.uri or result.targetUri) and { result } or result
      local location = locations[1]
      local range = location.targetSelectionRange or location.range
      vim.lsp.util.show_document({
        uri = location.targetUri or location.uri,
        range = range,
      }, client.offset_encoding or "utf-16", { focus = true })
      return
    end

    if not angular_template_method_fallback() then
      vim.notify("No definition found", vim.log.levels.INFO)
    end
  end, bufnr)
end

return {
  recommended = function()
    return LazyVim.extras.wants({
      root = { "angular.json", "nx.json" },
    })
  end,

  { import = "lazyvim.plugins.extras.lang.angular" },

  {
    "mason-org/mason-lspconfig.nvim",
    opts = {
      ensure_installed = { "angularls@15.2.1" },
    },
  },

  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.angularls = vim.tbl_deep_extend("force", opts.servers.angularls or {}, {
        mason = false,
        keys = {
          { "gd", angular_definition, desc = "Goto Definition" },
        },
        cmd = function(dispatchers, config)
          local root_dir = (config and config.root_dir) or vim.fn.getcwd()
          local project_node_modules = angular_project_node_modules(root_dir)
          local mason_node_modules = LazyVim.get_pkg_path("angular-language-server", "/node_modules")
          local mason_language_server_node_modules =
            LazyVim.get_pkg_path("angular-language-server", "/node_modules/@angular/language-server/node_modules")

          local ts_probe_locations = {}
          append_existing(ts_probe_locations, project_node_modules)
          append_existing(ts_probe_locations, mason_node_modules)
          append_existing(ts_probe_locations, mason_language_server_node_modules)

          local ng_probe_locations = {}
          append_existing(ng_probe_locations, project_node_modules)
          append_existing(ng_probe_locations, mason_language_server_node_modules)

          local cmd = {
            "ngserver",
            "--stdio",
            "--tsProbeLocations",
            table.concat(ts_probe_locations, ","),
            "--ngProbeLocations",
            table.concat(ng_probe_locations, ","),
            "--angularCoreVersion",
            angular_core_version(root_dir),
          }

          return vim.lsp.rpc.start(cmd, dispatchers)
        end,
      })
    end,
  },
}
