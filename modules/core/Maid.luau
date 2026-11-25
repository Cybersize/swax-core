local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({ _items = {} }, Maid)
end

function Maid:Give(item)
    if item ~= nil then
        self._items[#self._items + 1] = item
    end
    return item
end

function Maid:Clean()
    local items = self._items
    -- Detach first so recursive cleanup cannot release an item twice.
    self._items = {}
    for i = #items, 1, -1 do
        local item = items[i]
        items[i] = nil
        if typeof(item) == "RBXScriptConnection" then
            if item.Connected then pcall(function() item:Disconnect() end) end
        elseif typeof(item) == "Instance" then
            pcall(function() item:Destroy() end)
        elseif type(item) == "table" then
            -- A resource should have one authoritative cleanup method. Calling
            -- both Disconnect and Destroy can double-release wrapped resources.
            if item.Disconnect then
                pcall(function() item:Disconnect() end)
            elseif item.Destroy then
                pcall(function() item:Destroy() end)
            elseif item.Clean then
                pcall(function() item:Clean() end)
            end
        elseif type(item) == "function" then
            pcall(item)
        end
    end
end


return Maid
