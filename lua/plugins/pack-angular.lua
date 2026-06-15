local function add_existing(paths, path)
  if path and path ~= "" and vim.uv.fs_stat(path) and not vim.tbl_contains(paths, path) then
    paths[#paths + 1] = vim.fs.normalize(path)
  end
end

local function find_node_modules(root_dir)
  local direct = vim.fs.joinpath(root_dir, "node_modules")
  if vim.uv.fs_stat(direct) then
    return vim.fs.normalize(direct)
  end

  local found = vim.fs.find("node_modules", { path = root_dir, upward = true })[1]
  return found and vim.fs.normalize(found) or nil
end

local function angular_core_version(root_dir)
  local node_modules = find_node_modules(root_dir)
  local package_root = node_modules and vim.fs.dirname(node_modules) or root_dir
  local package_json = vim.fs.joinpath(package_root, "package.json")

  if not vim.uv.fs_stat(package_json) then
    return ""
  end

  local ok, content = pcall(vim.fn.readblob, package_json)
  if not ok or not content then
    return ""
  end

  local decoded, json = pcall(vim.json.decode, content)
  if not decoded or type(json) ~= "table" then
    return ""
  end

  local version = (json.dependencies or {})["@angular/core"] or (json.devDependencies or {})["@angular/core"] or ""
  return type(version) == "string" and (version:match("%d+%.%d+%.%d+") or "") or ""
end

local function angular_major_version(root_dir)
  return angular_core_version(root_dir):match("^(%d+)")
end

local function package_major_version(node_modules, package_name)
  if not node_modules then
    return nil
  end

  local package_json = vim.fs.joinpath(node_modules, package_name, "package.json")
  if not vim.uv.fs_stat(package_json) then
    return nil
  end

  local ok, content = pcall(vim.fn.readblob, package_json)
  if not ok or not content then
    return nil
  end

  local decoded, json = pcall(vim.json.decode, content)
  if not decoded or type(json) ~= "table" or type(json.version) ~= "string" then
    return nil
  end

  return tonumber(json.version:match("^(%d+)"))
end

local function server_from_node_modules(node_modules)
  local bin = node_modules and vim.fs.joinpath(node_modules, ".bin", "ngserver") or nil
  if bin and vim.uv.fs_stat(bin) then
    return node_modules, bin
  end
end

local function server_from_root(root)
  return server_from_node_modules(root and vim.fs.joinpath(root, "node_modules"))
end

local function angular_language_server(root_dir)
  if vim.env.NVIM_ANGULARLS_SERVER_ROOT then
    return server_from_root(vim.env.NVIM_ANGULARLS_SERVER_ROOT)
  end

  local angular_major = tonumber(angular_major_version(root_dir))
  local project_node_modules = find_node_modules(root_dir)
  local server_node_modules, server_bin = server_from_node_modules(project_node_modules)
  if
    server_node_modules
    and not (angular_major == 15 and (package_major_version(server_node_modules, "@angular/language-server") or 0) < 19)
  then
    return server_node_modules, server_bin
  end

  local data_dir = vim.fn.stdpath("data")

  -- Angular LS 15 starts, but under Neovim it leaves external templates in an inferred project.
  -- 19.x is the first locally tested server that associates Angular 15 external HTML templates correctly.
  if angular_major == 15 then
    server_node_modules, server_bin = server_from_root(vim.fs.joinpath(data_dir, "angular-language-server-19"))
    if server_node_modules then
      return server_node_modules, server_bin
    end
  end

  server_node_modules, server_bin =
    server_from_root(angular_major and vim.fs.joinpath(data_dir, "angular-language-server-" .. angular_major))
  if server_node_modules then
    return server_node_modules, server_bin
  end

  return server_from_root(LazyVim.get_pkg_path("angular-language-server"))
end

local function angularls_cmd(dispatchers, config)
  local root_dir = (config and config.root_dir) or vim.fn.getcwd()
  local project_node_modules = find_node_modules(root_dir)
  local server_node_modules, server_bin = angular_language_server(root_dir)
  local server_language_service_node_modules = server_node_modules
    and vim.fs.joinpath(server_node_modules, "@angular", "language-server", "node_modules")

  local ts_probe_locations = {}
  add_existing(ts_probe_locations, project_node_modules)
  add_existing(ts_probe_locations, server_node_modules)
  add_existing(ts_probe_locations, server_language_service_node_modules)

  local ng_probe_locations = {}
  add_existing(ng_probe_locations, project_node_modules)
  add_existing(ng_probe_locations, server_node_modules)
  add_existing(ng_probe_locations, server_language_service_node_modules)

  return vim.lsp.rpc.start({
    server_bin or "ngserver",
    "--stdio",
    "--tsProbeLocations",
    table.concat(ts_probe_locations, ","),
    "--ngProbeLocations",
    table.concat(ng_probe_locations, ","),
    "--angularCoreVersion",
    angular_core_version(root_dir),
    "--forceStrictTemplates",
    unpack(vim.env.NVIM_ANGULARLS_LOG and {
      "--logFile",
      vim.env.NVIM_ANGULARLS_LOG,
      "--logVerbosity",
      "verbose",
    } or {}),
  }, dispatchers)
end

-- Keep Angular templates as htmlangular so Angular-specific tools keep working,
-- but use Treesitter folds because angularls returns only single-line fold ranges
-- for external templates in some projects.
local function use_angular_treesitter_folds(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "htmlangular" then
    return
  end
  pcall(vim.treesitter.start, buf, "angular")
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "htmlangular" then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win].foldmethod = "expr"
      vim.wo[win].foldexpr = "v:lua.LazyVim.treesitter.foldexpr()"
    end
  end)
end

local angular_folds = vim.api.nvim_create_augroup("config_angular_folds", { clear = true })

-- Re-apply on LSP attach because LazyVim may switch foldexpr to the LSP provider
-- after angularls starts.
vim.api.nvim_create_autocmd({ "FileType", "LspAttach" }, {
  desc = "Use Treesitter folds for Angular templates",
  group = angular_folds,
  callback = function(ev)
    use_angular_treesitter_folds(ev.buf)
  end,
})

-- Guard against later foldexpr changes from any LSP folding hook.
vim.api.nvim_create_autocmd("OptionSet", {
  desc = "Keep Angular template folds on Treesitter",
  group = angular_folds,
  pattern = "foldexpr",
  callback = function()
    if vim.v.option_new == "v:lua.vim.lsp.foldexpr()" then
      use_angular_treesitter_folds(vim.api.nvim_get_current_buf())
    end
  end,
})

vim.schedule(function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    use_angular_treesitter_folds(buf)
  end
end)

return {
  recommended = function()
    return LazyVim.extras.wants({
      root = { "angular.json", "nx.json" },
    })
  end,

  { import = "lazyvim.plugins.extras.lang.angular" },

  {
    "softoika/ngswitcher.vim",
    keys = {
      { "<leader>ac", "<cmd>NgSwitchTS<cr>", desc = "Angular Component" },
      { "<leader>at", "<cmd>NgSwitchHTML<cr>", desc = "Angular Template" },
      { "<leader>ay", "<cmd>NgSwitchCSS<cr>", desc = "Angular Style" },
      { "<leader>aS", "<cmd>NgSwitchSpec<cr>", desc = "Angular Spec" },
    },
  },

  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      if not vim.tbl_contains(opts.ensure_installed, "angular-language-server") then
        opts.ensure_installed[#opts.ensure_installed + 1] = "angular-language-server"
      end
    end,
  },

  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        angularls = {
          cmd = angularls_cmd,
          settings = {
            angular = {
              provideAutocomplete = true,
              validate = true,
              suggest = {
                includeAutomaticOptionalChainCompletions = true,
                includeCompletionsWithSnippetText = true,
              },
            },
          },
        },
      },
    },
  },
}
