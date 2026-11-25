-- Copy the entire swax-core folder into your executor's workspace, then run
-- this loader. Files remain separate: no HTTP requests or bundled script.
local ROOT="swax-core"
assert(type(readfile)=="function","This loader needs local readfile support")
assert(type(loadstring)=="function","This loader needs loadstring support")

local gui=game:GetService("CoreGui")
if gui:FindFirstChild("_SwaXFrame") or gui:FindFirstChild("_SwaXCoreFrame") then
    warn("[SwaX Core] Unload the previous instance first.")
    return nil
end

local loaded,loading={},{}
local function import(name)
    assert(type(name)=="string" and name:match("^[%w_/-]+$")
        and name:sub(1,1)~="/" and not name:find("..",1,true),"Invalid module name")
    if loaded[name]~=nil then return loaded[name] end
    assert(not loading[name],"Circular module import: "..name)
    loading[name]=true
    local path=ROOT.."/modules/"..name..".luau"
    local ok,value=pcall(function()
        local readOK,source=pcall(readfile,path)
        assert(readOK and type(source)=="string" and #source>0,"Cannot read "..path.."; copy the complete folder into the executor workspace")
        local chunk,compileError=loadstring(source,"@"..path)
        assert(chunk,"Cannot compile "..path..": "..tostring(compileError))
        local result=chunk()
        assert(type(result)=="table" or type(result)=="function","Module must return a table or factory: "..name)
        return result
    end)
    loading[name]=nil
    if not ok then error(value,0) end
    loaded[name]=value
    return value
end

return import("App")(import)
