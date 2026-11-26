-- Composition root: this is the only module that wires all components together.
return function(import)
    local Maid=import("core/Maid")
    local CoreMath=import("core/Math")
    local services={}
    for _,name in ipairs({"Players","RunService","UserInputService","CoreGui","Workspace","Teams"}) do
        services[name]=game:GetService(name)
    end
    assert(services.Players.LocalPlayer,"SwaX Core must run on the client")
    if services.CoreGui:FindFirstChild("_SwaXFrame") or services.CoreGui:FindFirstChild("_SwaXCoreFrame") then
        warn("[SwaX Core] Unload the previous instance before running the loader.")
        return nil
    end
    local marker=Instance.new("BoolValue")
    marker.Name="_SwaXCoreFrame"
    marker.Parent=services.CoreGui
    local ctx={services=services,localPlayer=services.Players.LocalPlayer,
        camera=services.Workspace.CurrentCamera,alive=true,maid=Maid.new(),marker=marker}
    local parts={math=CoreMath,maidClass=Maid}
    local runtime
    local ok,err=xpcall(function()
        parts.config=import("core/Config")(ctx)
        parts.cache=import("rig/Cache")()
        parts.teams=import("rig/Teams")(ctx)
        parts.registry=import("rig/Registry")(ctx,parts.config,Maid,parts.cache,parts.teams)
        parts.geometry=import("rig/Geometry")(ctx,parts.config,parts.cache,CoreMath)
        parts.visibility=import("targeting/Visibility")(ctx,parts.config,parts.registry,parts.geometry)
        parts.selector=import("targeting/Selector")(ctx,parts.config,parts.registry,parts.geometry,parts.visibility,CoreMath)
        parts.lock=import("targeting/Lock")(ctx,parts.config,parts.registry,parts.geometry,parts.visibility,parts.selector)
        parts.aim=import("targeting/Aim")(ctx,parts.config,parts.lock,parts.selector,CoreMath,parts.registry)
        parts.visuals=import("visuals/ESP")(ctx,parts.config,parts.registry,parts.geometry,parts.visibility)
        parts.scheduler=import("core/Scheduler")(ctx)
        runtime=import("Runtime")(ctx,parts.config,parts.registry,parts.visibility,parts.lock,parts.aim,parts.visuals,parts.scheduler)
        parts.ui=import("ui/Panel")(ctx,parts.config,runtime,parts.registry,parts.scheduler,parts.lock,parts.visuals)
        runtime.Components=parts
        runtime.Context=ctx
        parts.ui.Init()
        runtime.Start()
    end,debug.traceback)
    if not ok then
        if runtime then
            pcall(runtime.Destroy)
        else
            ctx.alive=false
            ctx.maid:Clean()
            for _,name in ipairs({"registry","visuals","cache","config"}) do
                local part=parts[name]
                if part and type(part.Clean)=="function" then pcall(part.Clean) end
            end
            marker:Destroy()
        end
        error("[SwaX Core] Startup failed: "..tostring(err),0)
    end
    return runtime
end
