-- ==================================================
-- recipes.lua : what's made from what
--
-- The Crafter makes things with these (craft.lua), and the
-- Miner uses them to work out how much rock the plan still
-- needs (quarry.lua). Each step is a 2 by 2 square: 4 make 4,
-- so everything in a chain takes one of what it starts from.
-- ==================================================

local recipes = {}

-- product -> what it's crafted from
recipes.CRAFTED = {
  ["minecraft:polished_deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:deepslate_bricks"] = "minecraft:polished_deepslate",
  ["minecraft:deepslate_tiles"] = "minecraft:deepslate_bricks",
}

-- in the order to make them (each from the one before)
recipes.ORDER = { "minecraft:polished_deepslate", "minecraft:deepslate_bricks", "minecraft:deepslate_tiles" }

-- what a Miner digs up to start a chain
recipes.MINED = {
  ["minecraft:cobbled_deepslate"] = true,
}


-- What a thing is made from in the end: "minecraft:deepslate_tiles"
-- -> "minecraft:cobbled_deepslate". Things that aren't crafted
-- are their own start.
function recipes.startOf(name)
  local seen = 0
  while recipes.CRAFTED[name] and seen < 16 do
    name = recipes.CRAFTED[name]
    seen = seen + 1
  end
  return name
end

-- How much of each mined thing is still needed for the plan's
-- materials, counting everything already in stock (crafted or
-- not) along the way: { ["minecraft:cobbled_deepslate"] = 1234 }.
-- Only things a Miner digs up are counted.
function recipes.stillToMine(materials, stock)
  local need, have = {}, {}
  for name, count in pairs(materials) do
    local start = recipes.startOf(name)
    if recipes.MINED[start] then
      need[start] = (need[start] or 0) + count
    end
  end
  for name, count in pairs(stock) do
    local start = recipes.startOf(name)
    if need[start] then
      have[start] = (have[start] or 0) + count
    end
  end
  local short = {}
  for start, count in pairs(need) do
    if count > (have[start] or 0) then
      short[start] = count - (have[start] or 0)
    end
  end
  return short
end


return recipes
