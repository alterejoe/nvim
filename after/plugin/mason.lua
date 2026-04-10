local function parse_yaml(path)
    local raw = vim.fn.system({ "yq", "-o=json", ".", path })
    if vim.v.shell_error ~= 0 then
        vim.notify("mason.lua: failed to parse " .. path, vim.log.levels.ERROR)
        return nil
    end
    local ok, result = pcall(vim.fn.json_decode, raw)
    if not ok then
        vim.notify("mason.lua: failed to decode json: " .. tostring(result), vim.log.levels.ERROR)
        return nil
    end
    return result
end

local function collect_mason_packages(languages)
    local packages = {}
    for _, config in pairs(languages) do
        if config.mason then
            for _, pkg in ipairs(config.mason) do
                table.insert(packages, pkg)
            end
        end
    end
    return packages
end

local data = parse_yaml(vim.fn.stdpath("config") .. "/languages.yaml")
if not data then
    return
end

require("mason").setup()

local registry = require("mason-registry")
local packages = collect_mason_packages(data.languages)

registry.refresh(function()
    local seen = {}
    for _, pkg_name in ipairs(packages) do
        if not seen[pkg_name] then
            seen[pkg_name] = true
            local ok, pkg = pcall(registry.get_package, pkg_name)
            if ok and not pkg:is_installed() then
                vim.notify("mason: installing " .. pkg_name, vim.log.levels.INFO)
                pkg:install()
            end
        end
    end
end)
