-- core/Scheduler: isolated factory; dependencies are explicit parameters.
return function(ctx)
    -- One owned scheduler, one render connection, one idempotent shutdown path.
    local Scheduler = { jobs = {}, names = {} }
    function Scheduler.Add(name, interval, callback)
        assert(not Scheduler.names[name], "Duplicate scheduler job: " .. name)
        local job = {name=name, interval=interval, callback=callback, elapsed=0, busy=false}
        Scheduler.names[name] = job
        table.insert(Scheduler.jobs, job)
    end
    function Scheduler.Step(dt)
        for _, job in ipairs(Scheduler.jobs) do
            if not ctx.alive then break end
            job.elapsed += dt
            if not job.busy and (job.interval == 0 or job.elapsed >= job.interval) then
                local elapsed = job.elapsed
                job.elapsed = job.interval > 0 and elapsed % job.interval or 0
                job.busy = true
                local ok, err = pcall(job.callback, elapsed)
                job.busy = false
                if not ok and (not job.errorAt or os.clock() - job.errorAt >= 2) then
                    job.errorAt = os.clock()
                    warn("[SwaX Core] " .. job.name .. ": " .. tostring(err))
                end
            end
        end
    end
    function Scheduler.Clean()
        table.clear(Scheduler.jobs)
        table.clear(Scheduler.names)
    end


    return Scheduler
end
