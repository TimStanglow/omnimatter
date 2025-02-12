-------------------------------------------------------------------------------
--[[Local Declarations]]--
-------------------------------------------------------------------------------
local lab_inputs = {}
local compressed_techs={}
local pack_sizes={}
local tiered_tech = {}
local alwaysSP = omni.lib.split(settings.startup["omnicompression_always_compress_sp"].value,",")
local min_compress = settings.startup["omnicompression_compressed_tech_min"].value
-------------------------------------------------------------------------------
--[[Locally defined functions]]--
-------------------------------------------------------------------------------
-- lab input checks
local has_input  = function(tab)
    local  found = false
    for _, li in pairs(lab_inputs) do
        local has_all = true
        for _,e in pairs(tab) do
            if not omni.lib.is_in_table(e,li) then
                has_all=false
                break
            end
        end
        if has_all then
            found = true
            break
        end
    end
    return found
end
--contains at least one of the packs
local containsOne = function(t,d)
    for _,p in pairs(t) do
        for _,q in pairs(d) do
            if p[1]==q then
                return true
            elseif p.name==q then
                return true
            end
        end
    end
    return false
end

local splitTech = function(tech)
    local match = select(3, tech:find("()%-%d+$"))
    if match then
        local level = tech:sub(match+1)
        local name = tech:sub(1, match-1)
        return name, level
    else
        return tech
    end
end
-------------------------------------------------------------------------------
--[[Set-up loops]]--
-------------------------------------------------------------------------------
log("start tech compression checks")
--add compressed packs to labs
for _, lab in pairs(data.raw.lab) do
    local l = table.deepcopy(lab)
    if not has_input(lab.inputs) then
        lab_inputs[#lab_inputs+1]=lab.inputs
    end
    for _, ing in pairs(lab.inputs) do
        local hidden = false
        local proto = omni.lib.find_prototype(ing)
        if proto then
            for _, flag in ipairs(proto.flags or {}) do
                if flag == "hidden" then hidden = true end
            end
        end
        if proto and data.raw.tool["compressed-"..ing] and not omni.lib.start_with(ing,"compressed") and not omni.lib.is_in_table("compressed-"..ing,lab.inputs) and not hidden then
            table.insert(lab.inputs,"compressed-"..ing)
        end
        if proto and not pack_sizes[ing] then --only add it if it does not already exist (should save a few microns)
            if data.raw.tool[ing].stack_size then
                pack_sizes[ing]=data.raw.tool[ing].stack_size
            elseif data.raw.item[ing].stack_size then
                pack_sizes[ing]=data.raw.item[ing].stack_size
            end
        end
    end
end
--find lowest level in tiered techs that gets compressed to ensure chains are all compressed passed the first one
for _,tech in pairs(data.raw.technology) do --run always
    local name, lvl = splitTech(tech.name)
    if lvl == "" or lvl == nil then --tweak to allow techs that start with no number
        lvl = 1
        name = tech.name
    end
    --protect against pack removal
    if containsOne(tech.unit.ingredients,alwaysSP) then
        if not tiered_tech[name] then
            tiered_tech[name] = tonumber(lvl)
        elseif tiered_tech[name] > tonumber(lvl) then --in case techs are added out of order, always add the lowest
            tiered_tech[name] = tonumber(lvl)
        end
    end
    --protect against cost drops
    if tech.unit and ((tech.unit.count and type(tech.unit.count)=="number" and tech.unit.count > min_compress)) then
        if not tiered_tech[name] then
            tiered_tech[name] = tonumber(lvl)
        elseif tiered_tech[name] > tonumber(lvl) then --in case techs are added out of order, always add the lowest
            tiered_tech[name] = tonumber(lvl)
        end    
    end
end
--log(serpent.block(tiered_tech))
--compare tech to the list created (tiered_tech) to include techs missing packs previously in the chain
local include_techs = function(t)
  --extract name and level
    local name, lvl = splitTech(t.name)
    if lvl == "" or lvl == nil then --tweak to allow techs that start with no number
        lvl = 1
        name = t.name
    end
    if tiered_tech[name] then
        if tonumber(lvl) >= tiered_tech[name] then
        return true
        end
    end
    return false
end
-------------------------------------------------------------------------------
--[[Compressed Tech creation]]--
-------------------------------------------------------------------------------
log("start tech compression")
for _,tech in pairs(data.raw.technology) do
    if (tech.unit and (tech.unit.count and type(tech.unit.count)=="number" and tech.unit.count > min_compress)) or
    include_techs(tech) or containsOne(tech.unit.ingredients,alwaysSP) or not tech.unit.count then
        --fetch original
        local t = table.deepcopy(tech)
        t.name = "omnipressed-"..t.name
        local class, tier = splitTech(tech.name)
        local locale = omni.lib.locale.of(tech).name
        if tier and tonumber(locale[#locale]) == nil and tech.level == tech.max_level then-- If the last key is a number, or there's multiple levels, it's already tiered.
            t.localised_name = omni.lib.locale.custom_name(tech, "compressed-tiered", tier)
            t.localised_description = {"technology-description.compressed-tiered", locale, tier}
        else
            t.localised_name = omni.lib.locale.custom_name(tech, "compressed")
            t.localised_description = {"technology-description.compressed", locale}
        end
        --Handle icons
        t.icons = omni.lib.add_overlay(t, "technology")
        t.icon = nil
        --if we req more than a (compressed) stack, we increment this counter
        local stacks_needed = 1
        local divisor = 1
        local lcm = {1}
        -- Stage 1: Standardize and find our LCM of the various stack sizes
        for _, ings in pairs(t.unit.ingredients) do
            if ings[1] then
                ings.name = ings[1]
                ings.amount = ings[2]
                ings[1] = nil
                ings[2] = nil
            end
            lcm[#lcm+1] = data.raw.tool[ings.name].stack_size
        end
        lcm = omni.lib.lcm(unpack(lcm))

        -- Stage 2: Determine our amounts and unit.count (stacks_needed)
        for _, ings in pairs(t.unit.ingredients) do
            divisor = math.max(divisor, data.raw.tool[ings.name].stack_size)
            ings.amount = (ings.amount * (t.unit.count or lcm)) / pack_sizes[ings.name]
            ings.amount = math.max(1, omni.lib.round(ings.amount))
            ings.name = "compressed-"..ings.name
            if ings.amount > data.raw.tool[ings.name].stack_size then
                stacks_needed = omni.lib.lcm(stacks_needed, math.ceil(ings.amount / data.raw.tool[ings.name].stack_size))
            end
        end

        -- Stage 3: Do the final adjustment of our amount requirements, dividing amount by unit count
        for num, ings in pairs(t.unit.ingredients) do
            ings.amount = ings.amount / stacks_needed
            ings.amount = math.max(1, omni.lib.round(ings.amount))
        end
        --if valid remove effects from compressed and update cost curve
        if t.effects then
            for i, eff in pairs(t.effects) do
                if eff.type ~= "unlock-recipe" then t.effects[i] = nil end
            end
        end
        if t.unit.count then
            t.unit.time = omni.lib.round((t.unit.time * t.unit.count) / stacks_needed)
            t.unit.time = math.max(1, t.unit.time)
            t.unit.count = math.min(stacks_needed, 2^64-1)
        else
            t.unit.time = t.unit.time * divisor
            t.unit.count_formula = "(" .. t.unit.count_formula..")*".. string.format("%f", 1 / divisor)
        end
        compressed_techs[#compressed_techs+1]=table.deepcopy(t)
    end
end

if #compressed_techs >= 1 then --in case no tech is compressed
    data:extend(compressed_techs)
end
log("end tech compression")
