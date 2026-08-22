-- Client-side sprite atlas helper. Loads a tilemap image and hands out cached
-- quads for individual tiles so draw code never allocates a quad per frame.
--
-- The ability tilemap (sprites/abilities_tilemap.png) is a 3x2 grid of 64px
-- tiles read row-major: Beam (0,0), Bear Trap (1,0), Morgana Stun (2,0),
-- Morgana's Pool (0,1), and the remaining two tiles are reserved for abilities
-- that don't have sprites yet. Each ability module declares its own tile via an
-- `icon` field { col, row } so the sprite metadata stays next to the ability it
-- belongs to.
--
-- Other sheets use a different tile size (e.g. the flytrap sheet is a 5x4 grid
-- of 320px tiles); pass an explicit tile size to Sprites.new for those. The
-- frame index is mapped to its quad by the caller via col = frame % cols,
-- row = floor(frame / cols).

local Sprites = {}

local TILE = 64

-- Create an atlas for a tilemap image. `tile` defaults to the 64px ability
-- tile; pass a custom size for sheets with other grid dimensions.
function Sprites.new(path, tile)
    local image = love.graphics.newImage(path)
    image:setFilter("linear", "linear")
    return {
        image = image,
        tile = tile or TILE,
        quads = {}, -- "col,row" -> quad cache
    }
end

-- Return a quad for a tile (0-indexed column/row), cached on the atlas.
function Sprites.quad(atlas, col, row)
    local key = col .. "," .. row
    local quad = atlas.quads[key]
    if not quad then
        quad = love.graphics.newQuad(
            col * atlas.tile,
            row * atlas.tile,
            atlas.tile,
            atlas.tile,
            atlas.image:getDimensions()
        )
        atlas.quads[key] = quad
    end
    return quad
end

return Sprites
