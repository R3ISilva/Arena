-- Client-side sprite atlas helper. Loads a tilemap image and hands out cached
-- quads for individual tiles so draw code never allocates a quad per frame.
--
-- The ability tilemap (sprites/abilities_tilemap.png) is a 3x2 grid of 64px
-- tiles: top-left is Beam, top-middle is Bear Trap, and the remaining four
-- tiles are reserved for abilities that don't have sprites yet. Each ability
-- module declares its own tile via an `icon` field { col, row } so the sprite
-- metadata stays next to the ability it belongs to.

local Sprites = {}

local TILE = 64

-- Create an atlas for a tilemap image.
function Sprites.new(path)
    local image = love.graphics.newImage(path)
    image:setFilter("linear", "linear")
    return {
        image = image,
        tile = TILE,
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
