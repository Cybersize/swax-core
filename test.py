"""Test actual local-loader imports in separate module environments."""
from pathlib import Path
import argparse, subprocess, tempfile

ROOT=Path(__file__).resolve().parent
parser=argparse.ArgumentParser()
parser.add_argument('--luau',required=True,help='Path to the official Luau CLI')
parser.add_argument('--github',action='store_true',help='Test the GitHub loader with mocked HTTP')
args=parser.parse_args()

def quote(value):
    equals='='
    while ']'+equals+']' in value: equals+='='
    return '['+equals+'[\n'+value+']'+equals+']'

prefix=(ROOT/'tests/mock_engine.luau').read_text(encoding='utf8')
entry='github-loader.luau' if args.github else 'loader.luau'
files={'swax-core/loader.luau':(ROOT/entry).read_text(encoding='utf8')}
files.update({'swax-core/'+p.relative_to(ROOT).as_posix():p.read_text(encoding='utf8') for p in (ROOT/'modules').rglob('*.luau')})
filesystem='\nlocal files={\n'+',\n'.join('[ '+quote(path)+' ]='+quote(text) for path,text in sorted(files.items()))+'\n}\n'
harness=r'''
local reads,drawingObjects={},{ }
local Drawing={new=function(kind)
    local draw={kind=kind,removed=false}
    function draw:Remove() self.removed=true end
    table.insert(drawingObjects,draw)
    return draw
end}
local base=getfenv()
local engine={game=game,workspace=workspace,Instance=Instance,Enum=Enum,Color3=Color3,Vector3=Vector3,
    Vector2=Vector2,CFrame=CFrame,UDim=UDim,UDim2=UDim2,task=task,tick=tick,warn=warn,
    RaycastParams=RaycastParams,typeof=typeof,Drawing=Drawing}
engine.readfile=function(path)
    reads[path]=(reads[path] or 0)+1
    return assert(files[path],"File not found: "..path)
end
setmetatable(engine,{__index=function(_,name)
    local value=base[name]
    if value==nil and name~="mousemoverel" then error("Undeclared engine global: "..name,0) end
    return value
end})
local nativeCompile=loadstring
local function compile(source,label)
    local chunk,err=nativeCompile(source,label)
    if chunk then setfenv(chunk,setmetatable({},{__index=engine,
        __newindex=function(_,name) error("Module attempted a global write: "..name,0) end})) end
    return chunk,err
end
engine.loadstring=compile
local function launch() return assert(compile(files["swax-core/loader.luau"],"@loader.luau"))() end
local Runtime=assert(launch())
local Context=Runtime.Context
local components=Runtime.Components
local ConfigService,CoreMath=components.config,components.math
local CharacterRegistry,GeometryService=components.registry,components.geometry
local TargetSelector,LockController,AimController=components.selector,components.lock,components.aim
local VisualDebug,Scheduler,Maid=components.visuals,components.scheduler,components.maidClass
local Camera=Context.camera

check("Each actual module loads in its own environment",function()
    local count=0
    for path in pairs(files) do
        if path~="swax-core/loader.luau" then assert(reads[path]==1,path);count+=1 end
    end
    assert(count==15,"Expected all 15 independent modules")
end)
check("Loader rejects a duplicate live instance before reading modules",function()
    local count=0;for _,n in pairs(reads) do count+=n end
    assert(launch()==nil)
    local after=0;for _,n in pairs(reads) do after+=n end;assert(after==count)
end)
check("Calling Runtime.Start twice does not stack connections",function()
    local before=#game:GetService("RunService").Heartbeat.listeners
    Runtime.Start();assert(#game:GetService("RunService").Heartbeat.listeners==before)
end)
check("Camera replacements update the explicit runtime context",function()
    local original=workspace.CurrentCamera
    local replacement=Instance.new("Camera");replacement.CFrame=CFrame.new();replacement.ViewportSize=Vector2.new(800,600)
    workspace.CurrentCamera=replacement;workspace:GetPropertyChangedSignal("CurrentCamera"):Fire()
    assert(Context.camera==replacement)
    workspace.CurrentCamera=original;workspace:GetPropertyChangedSignal("CurrentCamera"):Fire()
    replacement:Destroy()
end)
'''
if args.github:
    harness=harness.replace('engine.readfile=function(path)', 'engine.readfile=function(path) error("Remote loader must not read local files");end\nlocal unusedReadfile=function(path)',1)
    harness=harness.replace('local base=getfenv()', '''
function methods:HttpGet(url)
    local prefix="https://raw.githubusercontent.com/Cybersize/swax-core/eea4eb7343edf2a6b83caedc00f3c28b0aecafac/modules/"
    assert(url:sub(1,#prefix)==prefix,"Module URL must be revision-pinned")
    local path="swax-core/modules/"..url:sub(#prefix+1)
    reads[path]=(reads[path] or 0)+1
    return assert(files[path],"File not found: "..path)
end
local base=getfenv()
''',1)
math_tests=(ROOT/'tests/math_regressions.luau').read_text(encoding='utf8')
assertions=(ROOT/'tests/assertions.luau').read_text(encoding='utf8')
tail=r'''
check("Unload releases every Drawing object",function()
    for _,draw in ipairs(drawingObjects) do assert(draw.removed,"Drawing resource leaked") end
end)
check("Missing local modules fail with cleanup and a useful path",function()
    local path="swax-core/modules/rig/Geometry.luau";local saved=files[path];files[path]=nil
    local ok,err=pcall(launch);assert(not ok and tostring(err):find(path,1,true))
    assert(not game:GetService("CoreGui"):FindFirstChild("_SwaXCoreFrame"))
    files[path]=saved
end)
check("Late startup failure cleans render bindings and allocated visuals",function()
    local path="swax-core/modules/ui/Panel.luau";local saved=files[path];files[path]=nil
    local ok=pcall(launch);assert(not ok)
    assert(next(bindings)==nil and not game:GetService("CoreGui"):FindFirstChild("_SwaXCoreFrame"))
    for _,draw in ipairs(drawingObjects) do assert(draw.removed) end
    files[path]=saved
end)
print(string.format("%d MODULAR TESTS PASSED (actual loader, isolated module environments, mock Roblox engine)",passed))
'''
with tempfile.TemporaryDirectory(prefix='swax-modules-') as folder:
    path=Path(folder)/'test_modules.luau'
    path.write_text(prefix+filesystem+harness+'\n'+math_tests+'\n'+assertions+'\n'+tail,encoding='utf8')
    subprocess.run([args.luau,str(path)],check=True)
