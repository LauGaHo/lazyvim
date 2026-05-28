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
  if not vim.uv.fs_stat(package_json) then return "" end
  local ok, content = pcall(vim.fn.readblob, package_json)
  if not ok or not content then return "" end
  local decoded_ok, json = pcall(vim.json.decode, content)
  if not decoded_ok or type(json) ~= "table" then return "" end
  local version = (json.dependencies or {})["@angular/core"] or (json.devDependencies or {})["@angular/core"] or ""
  return version:match("%d+%.%d+%.%d+") or ""
end

local function append_existing(paths, path)
  if path and path ~= "" and vim.uv.fs_stat(path) and not vim.tbl_contains(paths, path) then
    paths[#paths + 1] = path
  end
end

local function angular_index_roots(root)
  local roots = {}
  append_existing(roots, vim.fs.joinpath(root, "src"))
  append_existing(roots, vim.fs.joinpath(root, "projects"))
  append_existing(roots, vim.fs.joinpath(root, "libs"))
  append_existing(roots, vim.fs.joinpath(root, "node_modules"))
  return roots
end

local function exact_word(line, word)
  return line:find("%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]")
end

local function project_root()
  return vim.fs.root(0, { "angular.json", "nx.json", "package.json" }) or vim.fn.getcwd()
end

local function angular_tag_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for start_col, closing, tag in line:gmatch("()<(/?)([A-Za-z][%w-]*)") do
    local end_col = start_col + #closing + #tag
    if col >= start_col and col <= end_col and tag:find("-", 1, true) then
      return tag
    end
  end
  return nil
end

local function angular_tag_on_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  for lnum = cursor[1], math.max(1, cursor[1] - 50), -1 do
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
    local limit = lnum == cursor[1] and cursor[2] + 1 or #line
    local before_cursor = line:sub(1, limit)
    local found
    for _, tag in before_cursor:gmatch("()<([A-Za-z][%w-]*)") do
      found = tag
    end
    if found then return found end
    if before_cursor:find(">", 1, true) then return nil end
  end
  return nil
end

local function angular_binding_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for start_col, name in line:gmatch("()%[([A-Za-z][%w-]*)%]") do
    local end_col = start_col + #name + 1
    if col >= start_col and col <= end_col then
      return angular_tag_on_line(), name
    end
  end
  for start_col, name in line:gmatch("()%(([A-Za-z][%w-]*)%)") do
    local end_col = start_col + #name + 1
    if col >= start_col and col <= end_col then
      return angular_tag_on_line(), name
    end
  end
  return nil, nil
end

local function angular_expression_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local word = vim.fn.expand("<cword>")
  if word == "" then return nil end
  for start_col, value in line:gmatch('=%s*"()([^"]*)"') do
    local end_col = start_col + #value
    if col >= start_col and col <= end_col then return word end
  end
  return nil
end

local function angular_pipe_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  for pipe_col, pipe in line:gmatch("|%s*()([A-Za-z][%w]*)") do
    local end_col = pipe_col + #pipe
    if col >= pipe_col and col <= end_col then return pipe end
  end
  return nil
end

local function selector_definition(tag)
  local root = project_root()
  local roots = angular_index_roots(root)
  if vim.tbl_isempty(roots) then return nil, nil end
  local cmd = { "rg", "-n", "--glob", "*.ts", "--glob", "*.d.ts",
    "--glob", "!**/.cache/**", "--glob", "!**/.angular/**", tag }
  vim.list_extend(cmd, roots)
  local result = vim.system(cmd, { cwd = root, text = true }):wait()
  if result.code ~= 0 and result.stdout == "" then return nil, nil end
  local function result_path(file)
    return file:sub(1, 1) == "/" and file or vim.fs.joinpath(root, file)
  end
  for line in result.stdout:gmatch("[^\n]+") do
    local file, lnum, text = line:match("^([^:]+):(%d+):(.*)$")
    if file and (text:find("selector:", 1, true) or text:find("ɵɵComponentDeclaration", 1, true)) then
      local selectors = text:match("selector:%s*['\"]([^'\"]+)['\"]")
      if selectors then
        for selector in selectors:gmatch("[^,%s]+") do
          if selector == tag then return result_path(file), tonumber(lnum) end
        end
      elseif text:find('"' .. tag .. '"', 1, true) or text:find("'" .. tag .. "'", 1, true) then
        return result_path(file), tonumber(lnum)
      end
    end
  end
  return nil, nil
end

local function component_input_definition(tag, input)
  local file = selector_definition(tag)
  if not file then return nil, nil end
  local lines = vim.fn.readfile(file)
  for lnum, line in ipairs(lines) do
    if exact_word(line, input) and not line:find("ɵcmp", 1, true) then
      return file, lnum
    end
  end
  return file, 1
end

local function pipe_definition(pipe)
  local root = project_root()
  local roots = angular_index_roots(root)
  if vim.tbl_isempty(roots) then return nil, nil end
  local cmd = { "rg", "-n", "--glob", "*.ts", "--glob", "*.d.ts",
    "--glob", "!**/.cache/**", "--glob", "!**/.angular/**", pipe }
  vim.list_extend(cmd, roots)
  local result = vim.system(cmd, { cwd = root, text = true }):wait()
  if result.code ~= 0 and result.stdout == "" then return nil, nil end
  local function result_path(file)
    return file:sub(1, 1) == "/" and file or vim.fs.joinpath(root, file)
  end
  for line in result.stdout:gmatch("[^\n]+") do
    local file, lnum, text = line:match("^([^:]+):(%d+):(.*)$")
    if file and (text:find("PipeDeclaration", 1, true) or text:find("@Pipe", 1, true)) then
      if text:find('"' .. pipe .. '"', 1, true) or text:find("'" .. pipe .. "'", 1, true) then
        return result_path(file), tonumber(lnum)
      end
    end
  end
  return nil, nil
end

local function component_member_definition(member)
  local html = vim.api.nvim_buf_get_name(0)
  local ts = html:gsub("%.html$", ".ts")
  if ts == html or vim.fn.filereadable(ts) ~= 1 then return nil, nil end
  local lines = vim.fn.readfile(ts)
  for lnum, line in ipairs(lines) do
    if exact_word(line, member)
      and (line:find(member .. "%s*[:=]", 1) or line:find(member .. "%s*%(", 1) or line:find("get%s+" .. member, 1))
      and not line:find("this%." .. member)
    then
      return ts, lnum
    end
  end
  return nil, nil
end

local function jump_to(file, lnum)
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd.normal({ "zz", bang = true })
end

local function angular_definition()
  if not vim.tbl_contains({ "html", "htmlangular" }, vim.bo.filetype) then
    return vim.lsp.buf.definition()
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "angularls" })[1]

  local function lsp_definition()
    if not client then return vim.lsp.buf.definition() end
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
    client:request("textDocument/definition", params, function(err, result)
      if err then
        vim.notify(err.message or tostring(err), vim.log.levels.ERROR)
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
      vim.notify("No definition found", vim.log.levels.INFO)
    end, bufnr)
  end

  local tag, input = angular_binding_at_cursor()
  if tag and input then
    local file, lnum = component_input_definition(tag, input)
    if file then return jump_to(file, lnum) end
  end

  local pipe = angular_pipe_at_cursor()
  if pipe then
    local file, lnum = pipe_definition(pipe)
    if file then return jump_to(file, lnum) end
  end

  local expression = angular_expression_at_cursor()
  if expression then
    local file, lnum = component_member_definition(expression)
    if file then return jump_to(file, lnum) end
  end

  tag = angular_tag_at_cursor()
  if tag then
    local file, lnum = selector_definition(tag)
    if file then return jump_to(file, lnum) end
  end

  return lsp_definition()
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
    "chaozwn/angular-quickswitch.nvim",
    event = "VeryLazy",
    opts = { use_default_keymaps = false },
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
        on_attach = function()
          vim.keymap.set(
            "n",
            "<leader>cq",
            vim.cmd.NgQuickSwitchToggle,
            { desc = "Angular quick switch toggle", noremap = true, silent = true, buffer = true }
          )
        end,
        settings = {
          angular = {
            provideAutocomplete = true,
            validate = true,
            suggest = {
              includeAutomaticOptionalChainCompletions = true,
              includeCompletionsWithSnippetText = true,
            },
            ["enable-strict-mode-prompt"] = true,
          },
        },
      })
    end,
  },
}
