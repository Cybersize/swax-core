-- Interface double only. This does not render or execute the real CrispyLib.
local function newMockCrispy()
    local library = {windows={}, loaders={}, flags={}, controls={}, listeners={}, cancelled={}}
    local config, state = {}, {}
    library.Config, library.State = config, state
    function state.Get(flag) return library.flags[flag] end
    function config.OnApplied(callback)
        local listener = {callback=callback, active=true}
        library.listeners[#library.listeners+1] = listener
        return function() listener.active=false end
    end
    function config.Apply(values, options)
        for flag, value in pairs(values) do
            local control=library.controls[flag]
            if control then control:Set(value,true) else library.flags[flag]=value end
        end
        if not options or options.Callbacks~=false then
            for flag in pairs(values) do
                local control=library.controls[flag]
                if control and control.spec.Callback then control.spec.Callback(library.flags[flag]) end
            end
        end
        for _, listener in ipairs(library.listeners) do
            if listener.active then task.spawn(listener.callback,table.clone(library.flags),{Applied=true}) end
        end
        return true
    end
    function config.Load()
        library.loadCalls=(library.loadCalls or 0)+1
        if not library.saved then return false,"config does not exist" end
        return config.Apply(library.saved,{Callbacks=false})
    end
    function config.Save() library.saved=table.clone(library.flags);return true end
    function config.CreateProfileUI(tab) library.profileTab=tab end
    function config.SetProfile(_) return config.Load() end
    library.Tasks={Cancel=function(_,token) library.cancelled[token]=true end}
    function config.StopAutoSave()
        if config._autoSaveToken then library.Tasks:Cancel(config._autoSaveToken);config._autoSaveToken=nil end
    end
    function config.AutoSave(period)
        config.StopAutoSave();config._autoSaveToken={period=period};return config._autoSaveToken
    end
    function library.CreateLoadingScreen(spec)
        local loader={spec=spec,Instance=Instance.new("ScreenGui")}
        loader.Instance.Parent=pg
        function loader:SetStatus(value) self.status=value end
        function loader:SetProgress(value) self.progress=value end
        function loader:Destroy() self.destroyed=true;self.Instance:Destroy() end
        function loader:Finish() self.finished=true;self:Destroy() end
        library.loaders[#library.loaders+1]=loader
        return loader
    end
    function library.CreateWindow(first,second)
        local spec=second or first
        local window={spec=spec,_tabs={},sections={},_screenGui=Instance.new("ScreenGui")}
        window._screenGui.Parent=pg
        window._screenGui.Enabled=true
        function window:SetAccent(value) self.accent=value end
        function window:AddSidebarSection(value) self.sections[#self.sections+1]=value end
        function window:AddTab(tabSpec)
            local tab={spec=tabSpec,controls={},buttons={}}
            function tab:AddSection(_) end
            function tab:AddDivider(_) end
            local function addControl(kind,controlSpec)
                local control={kind=kind,spec=controlSpec,value=controlSpec.Default}
                function control:Set(value,silent)
                    if kind=="Slider" then value=math.clamp(value,self.spec.Min,self.spec.Max) end
                    self.value=value
                    if self.spec.Flag then library.flags[self.spec.Flag]=value end
                    if not silent and self.spec.Callback then self.spec.Callback(value) end
                end
                function control:Get() return self.value end
                function control:DependsOn(other) self.dependency=other;return self end
                control:Set(controlSpec.Default,true)
                if controlSpec.Flag then library.controls[controlSpec.Flag]=control end
                tab.controls[#tab.controls+1]=control
                return control
            end
            for _,kind in ipairs({"Toggle","Slider","Dropdown","ColorPicker"}) do
                tab["Add"..kind]=function(_,controlSpec) return addControl(kind,controlSpec) end
            end
            function tab:AddButton(buttonSpec) self.buttons[buttonSpec.Name]=buttonSpec.Callback end
            function tab:AddDataCard(cardSpec)
                local card={value=cardSpec.Value}
                function card:Set(value) self.value=value end
                return card
            end
            self._tabs[#self._tabs+1]=tab
            return tab
        end
        local keyConnection=game:GetService("UserInputService").InputBegan:Connect(function(input,processed)
            if not processed and input.KeyCode==spec.Keybind then window._screenGui.Enabled=not window._screenGui.Enabled end
        end)
        function window:Destroy()
            if self.destroyed then return end
            self.destroyed=true;keyConnection:Disconnect();self._screenGui:Destroy()
        end
        library.windows[#library.windows+1]=window
        return window
    end
    return library
end
