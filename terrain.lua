-- ==================================================
-- terrain.lua : what kind of block is this?
--
-- Used by nav.lua (only natural terrain may be dug), mining.lua
-- and the rest. (Every block goes on the map now: see sightings.lua.)
-- Takes a block as turtle.inspect gives it: { name, tags }.
-- ==================================================

local terrain = {}

-- Minecraft's own groups of natural blocks (modded stone and
-- ores usually join these too)
local NATURAL_TAGS = {
  "minecraft:base_stone_overworld", -- stone, deepslate, granite, tuff...
  "minecraft:base_stone_nether",    -- netherrack, basalt, blackstone
  "minecraft:dirt",                 -- dirt, grass, podzol, mud...
  "minecraft:sand",
  "minecraft:replaceable",          -- tall grass, snow layers...
  "minecraft:small_flowers", "minecraft:leaves",
  "minecraft:stone_ore_replaceables", "minecraft:deepslate_ore_replaceables",
  "forge:stone", "c:stones",
  "c:ores", "forge:ores",
}

-- and some by name, in case a block isn't tagged
local NATURAL_NAMES = {
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true,
  ["minecraft:granite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:andesite"] = true, ["minecraft:tuff"] = true,
  ["minecraft:calcite"] = true, ["minecraft:dirt"] = true,
  ["minecraft:grass_block"] = true, ["minecraft:coarse_dirt"] = true,
  ["minecraft:gravel"] = true, ["minecraft:sand"] = true,
  ["minecraft:red_sand"] = true, ["minecraft:clay"] = true,
  ["minecraft:netherrack"] = true, ["minecraft:dripstone_block"] = true,
  -- modded stone that isn't tagged as stone (Create, TFMG)
  ["create:crimsite"] = true, ["create:asurine"] = true,
  ["create:ochrum"] = true, ["create:veridium"] = true,
  ["create:limestone"] = true, ["create:scoria"] = true,
  ["create:scorchia"] = true,
  ["tfmg:bauxite"] = true, ["tfmg:galena"] = true,
}


function terrain.isOre(block)
  if block.name:find("_ore$") then
    return true
  end
  return block.tags ~= nil and (block.tags["c:ores"] or block.tags["forge:ores"]) == true
end

-- Natural terrain: may be dug through.
function terrain.isNatural(block)
  if NATURAL_NAMES[block.name] or terrain.isOre(block) then
    return true
  end
  for _, tag in ipairs(NATURAL_TAGS) do
    if block.tags and block.tags[tag] then
      return true
    end
  end
  return false
end


return terrain
