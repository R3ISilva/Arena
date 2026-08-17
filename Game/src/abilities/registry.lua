-- Shared ability registry. This is the single module boundary for abilities:
-- both the server and the client load identical ability modules through it, so
-- every ability behaves the same on both sides (which is what keeps predicted
-- casts bit-for-bit identical to the authoritative simulation).
--
-- An ability id maps to a module under src/abilities/<id>.lua. Each module
-- exposes static tuning properties (name, type, cooldown, damage, range, radius,
-- duration) plus the uniform lifecycle: new() to create an instance, and
-- instance methods cast/update/draw.

local registry = {}

local modules = {}

-- Load (and cache) the ability module for an id.
function registry.load(id)
    if not modules[id] then
        modules[id] = require("src.abilities." .. id)
    end
    return modules[id]
end

-- Return a previously loaded module (nil if not loaded yet).
function registry.get(id)
    return modules[id]
end

-- Convenience: create a fresh instance of an ability by id.
function registry.new(id, owner, x, y, remaining)
    local module = registry.load(id)
    return module.new(owner, x, y, remaining)
end

return registry
