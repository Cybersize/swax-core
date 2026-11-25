-- Runtime: isolated factory; dependencies are explicit parameters.
return function(ctx, ConfigService, CharacterRegistry, VisibilityService, LockController, AimController, VisualDebug, Scheduler)
    local RunService=ctx.services.RunService
    local UserInputService=ctx.services.UserInputService
    local Workspace=ctx.services.Workspace
    local LocalPlayer=ctx.localPlayer
    local Runtime = { GUI=nil }
    local started=false
    function Runtime.Destroy()
        if not ctx.alive then return end
        ctx.alive = false
        AimController.ClearTarget()
        pcall(LockController.DropTarget, "destroyed")
        ctx.maid:Clean()
        pcall(CharacterRegistry.Clean)
        pcall(VisualDebug.Clean)
        ConfigService.Clean()
        if ctx.marker then ctx.marker:Destroy() end
    end

    ctx.maid:Give(Scheduler.Clean)
    ctx.maid:Give(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        ctx.camera = Workspace.CurrentCamera
    end))
    ctx.maid:Give(UserInputService.InputBegan:Connect(function(input)
        if not ctx.alive or UserInputService:GetFocusedTextBox() then return end
        if input.UserInputType == Enum.UserInputType.MouseButton2 then LockController.SetActive(true) end
    end))
    ctx.maid:Give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then LockController.SetActive(false) end
    end))
    ctx.maid:Give(UserInputService.WindowFocusReleased:Connect(function()
        LockController.SetActive(false)
        AimController.ClearTarget()
    end))
    ctx.maid:Give(LocalPlayer.CharacterRemoving:Connect(function()
        LockController.SetActive(false)
        AimController.ClearTarget()
    end))
    ctx.maid:Give(ConfigService.OnChanged("Enabled", function(enabled)
        if not enabled then LockController.SetActive(false); AimController.ClearTarget() end
    end))

    Scheduler.Add("Lock", 1/30, LockController.Update)
    Scheduler.Add("VisibilityPriority", 1/20, function()
        local target = LockController.GetLockedTarget()
        VisibilityService.SetPriorityChar(target and target.char or nil)
        if VisualDebug.NeedsVisibility() or ConfigService.Get("WallCheck") then VisibilityService.UpdatePriority() end
    end)
    Scheduler.Add("Visibility", 0.1, function()
        if VisualDebug.NeedsVisibility() or ConfigService.Get("WallCheck") then VisibilityService.UpdateAll() end
    end)
    Scheduler.Add("VisualState", 1/VisualDebug.UPDATE_HZ, VisualDebug.UpdateState)

    -- Connections are started after the UI and registry have initialized.
    function Runtime.Start()
        if started or not ctx.alive then return end
        started=true
        CharacterRegistry.Init()
        ctx.maid:Give(RunService.Heartbeat:Connect(Scheduler.Step))
        ctx.maid:Give(RunService.RenderStepped:Connect(function(dt)
            if not ctx.alive then return end
            if ctx.camera then VisualDebug.SetCameraSnapshot(ctx.camera.CFrame, ctx.camera.ViewportSize) end
            AimController.Update()
            VisualDebug.RendererTick(dt)
            VisualDebug.UpdateFOV()
            VisualDebug.UpdateCrosshair()
        end))
    end

    return Runtime
end
