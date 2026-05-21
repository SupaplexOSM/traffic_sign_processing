-- lua-config for importing osm data with osm2pgsql for traffic sign processing
--------------------------------------------------------------------------------------
-- Imported data/tables:
--   - nodes with traffic_sign=*
--   - highway segments with traffic_sign=*
--   - highway segments intersecting nodes and ways with traffic_sign=*

--------------------------------------------------------------------------------------

-- local metric coordinate reference system of the target area (e.g. UTM zone) in which all the data is stored and processed
-- TODO: remove?
local crs = 25833

-- default country code for traffic signs
local default_country_code = 'DE'

-- country specific traffic sign id's for human readable traffic sign values
local human_readable_values = {
    city_limit = '310',
    city_limit_end = '311',
    maxspeed = '274',
    maxspeed_implicit = '278',
    stop = '206',
    give_way = '205',
    overtaking_no = '276',
    overtaking_yes = '280',
    maxwidth = '264',
    maxheight = '265',
    maxweight = '262',
    stop_ahead = '205,1004-32',
    yield_ahead = '205,1004-30',
    signal_ahead = '131',
    hazard = '101',
}

-- country specific traffic sign id's for zone traffic signs (to prevent showing a traffic sign at each junction)
-- (or traffic signs, that should be treated like zone traffic signs, because it's not necessary to repeat them at each intersection, like access restrictions)
local zone_ids = { '242', '250', '251', '253', '260', '270', '274.1', '290', '314', '325' }
-- ! Note: traffic_sign_way.sql also contains a list of this traffic sign IDs (unnest array "sign_id" in zone_ids)

-- ! Note: A country-specific pattern to distinguish main signs from additional signs is defined in the "is_main_sign" function, which may have to be adapted for use in countries other than Germany!


-- define columns for all tables
---------------------------------

-- traffic sign nodes
local tbl_traffic_sign_node = osm2pgsql.define_table({
    name = 'traffic_sign_node',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'country_code' },
        { column = 'main_signs' },
        { column = 'sign_list' },
        { column = 'highway' },
        { column = 'direction' },
        { column = 'layer', type = 'integer' },
        { column = 'geom', type = 'point', projection = crs, not_null = true }
    }
})

-- traffic sign ways
local tbl_traffic_sign_way = osm2pgsql.define_table({
    name = 'traffic_sign_way',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'country_code' },
        { column = 'main_signs' },
        { column = 'sign_list' },
        { column = 'highway' },
        { column = 'oneway' },
        { column = 'oneway:bicycle' },
        { column = 'layer' },
        { column = 'geom', type = 'linestring', projection = crs, not_null = true }
    }
})

-- traffic sign zones
local tbl_traffic_sign_zone = osm2pgsql.define_table({
    name = 'traffic_sign_zone',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'country_code' },
        { column = 'main_signs' },
        { column = 'sign_list' },
        { column = 'highway' },
        { column = 'oneway' },
        { column = 'oneway:bicycle' },
        { column = 'layer' },
        { column = 'geom', type = 'linestring', projection = crs, not_null = true }
    }
})

-- highway ways
local tbl_highway = osm2pgsql.define_table({
    name = 'highway',
    ids = { type = 'any', type_column = 'osm_type', id_column = 'osm_id' },
    columns = {
        { column = 'highway' },
        { column = 'name' },
        { column = 'oneway' },
        { column = 'oneway:bicycle' },
        { column = 'traffic_sign' },
        { column = 'layer', type = 'integer' },
        { column = 'geom', type = 'linestring', projection = crs, not_null = true }
    }
})


-- Helper functions
--------------------------------------------------------------------------------------

-- Converts a string into a list, with a character or regular expression specified as a separator
local function tolist(value, separator)
    if value == nil then
        return nil
    end

    -- default separator
    separator = separator or ";"

    -- iterate through the parts of the string, separated by the separator
    local result = {}
    for part in string.gmatch(value, "([^" .. separator .. "]+)") do
        table.insert(result, part)
    end
    return result
end

-- Concat a table
local function join_list(list, separator)
    local result = ""
    for i = 1, #list do
        result = result .. list[i]
        if i < #list then
            result = result .. separator
        end
    end
    if result == "" then
        return nil
    end
    return result
end

-- Translate cardinal direction values to direction degrees
local cardinal_direction = {
    north = 0,
    east  = 90,
    south = 180,
    west  = 270,

    n   = 0,
    nne = 22,
    ne  = 45,
    ene = 67,
    e   = 90,
    ese = 112,
    se  = 135,
    sse = 157,
    s   = 180,
    ssw = 202,
    sw  = 225,
    wsw = 247,
    w   = 270,
    wnw = 292,
    nw  = 315,
    nnw = 337,

    northnortheast = 22,
    northeast      = 45,
    eastnortheast  = 67,
    eastsoutheast  = 112,
    southeast      = 135,
    southsoutheast = 157,
    southsouthwest = 202,
    southwest      = 225,
    westsouthwest  = 247,
    westnorthwest  = 292,
    westnordost    = 1337,
    northwest      = 315,
    northnorthwest = 337,

    ["north-north-east"] = 22,
    ["north-east"]       = 45,
    ["east-north-east"]  = 67,
    ["east-south-east"]  = 112,
    ["south-east"]       = 135,
    ["south-south-east"] = 157,
    ["south-south-west"] = 202,
    ["south-west"]       = 225,
    ["west-south-west"]  = 247,
    ["west-north-west"]  = 292,
    ["north-west"]       = 315,
    ["north-north-west"] = 337,
}

local function cardinaltodegree(value)
    for key, deg in pairs(cardinal_direction) do
        if key == string.lower(value) then
            return deg
        end
    end
    return nil
end

local function directiontodegree(value)
    if value == nil then
        return nil
    end

    -- degree values
    if tonumber(value) ~= nil then
        local val = tonumber(value)
        -- normalize negative values
        if val < 0 then
            return val + 360
        else
            return val
        end
    end

    -- classic cardinal direction strings and abbreviations
    if cardinaltodegree(value) ~= nil then
        return cardinaltodegree(value)
    end

    -- two semicolon separated values with opposite values: Take the first of them (e.g. "255;75" -> 255, "E;W" -> 90)
    if string.find(value, ";") then
        local list = tolist(value);
        if #list == 2 then
            if tonumber(list[1]) ~= nil and tonumber(list[2]) ~= nil then
                if math.abs(list[1] - list[2]) == 180 then
                    return tonumber(list[1])
                end
            end

            if cardinaltodegree(list[1]) ~= nil and cardinaltodegree(list[1]) ~= nil then
                if math.abs(cardinaltodegree(list[1]) - cardinaltodegree(list[2])) == 180 then
                    return cardinaltodegree(list[1])
                end
            end

            return nil
        else
            return nil
        end
    end

    -- convert ranges to mean value (e.g. "300-80" -> "70")
    if value.find(value, "%-", 2) then
        local val1, val2 = value:match("^(%-?%d+)%-(%d+)$")
        if tonumber(val1) and tonumber(val2) then
            return mid_angle(tonumber(val1), tonumber(val2))
        end
    end

    return nil
end

-- Identify main signs: Check whether the sign ID consists of three digits
-- (Note: Thats the German situation. Adjust this condition for other countries than Germany!)
local function is_main_sign(sign_id)
    if sign_id == nil then
        return nil
    end

    if sign_id:sub(1, 3):match("%d%d%d") then -- Why isn't lua schema "%d%d%d[^%d]?" working here?
        local fourth = sign_id:sub(4, 4)
        if fourth == "" or not fourth:match("%d") then
            return true
        end
    end
    return false
end

-- Converts a simple traffic sign list into a nested list in which each sub-list contains a main sign with its respective sub-signs
-- e.g. the OSM traffic_sign tag "260,1020-30;325" ({ '260', '1020-30', '325' } as a list) is converted to { { '260', '1020-30'}, { '325' } }
local function get_nested_sign_list(sign_list)
    if sign_list == nil then
        return nil
    end

    local nested_sign_list = {}
    local current_group = nil
    for i, sign_id in ipairs(sign_list) do
        if sign_id ~= nil then
            if is_main_sign(sign_id) then
                -- each main sign starts a new sublist
                current_group = { sign_id }
                table.insert(nested_sign_list, current_group)
            else
                -- additional signs: start a new subgroup, if no current subgroup exists (in case of stand alone additional signs)
                if not current_group then
                    current_group = { sign_id }
                    table.insert(nested_sign_list, current_group)
                else
                    -- common case: add additional sign to the list of it's main sign
                    table.insert(current_group, sign_id)
                end
            end
        end
    end
    if #nested_sign_list == 0 then
        return nil
    end
    return nested_sign_list
end

-- Extract main signs from all traffic signs
function get_main_signs(nested_list)
    local result = {}
    for i, sublist in ipairs(nested_list) do
        if sublist[1] then
            local main_sign = sublist[1]:gsub("%b[]", "")
            -- exclude sign specific values like 274[30] -> 274
            table.insert(result, main_sign)
        end
    end
    return table.concat(result, ";")
end

-- Check whether a sign has only zonal signs, no zonal signs or mixed (street/road geometries with zone traffic signs are processed differently)
local function get_zone_status(nested_list)

    if nested_list == nil then
        return "no"
    end

    local zone_count = 0
    local total = 0
    for i, sublist in ipairs(nested_list) do
        if sublist[1] then
            main_sign = sublist[1]
            total = total + 1
            for j, zone_id in ipairs(zone_ids) do
                if main_sign == zone_id or main_sign:sub(1, #zone_id) == zone_id then
                    zone_count = zone_count + 1
                end
            end
        end
    end
    
    if zone_count == total then
        return "only"
    elseif zone_count == 0 then
        return "no"
    else
        return "yes"
    end
end

-- Remove traffic signs from the nested traffic sign list that are related to a zone
local function remove_zone_signs(nested_sign_list)
    local filtered_list = {}
    -- Take a look at each main sign: If it's a zone sign, remove it and it's sub signs from the nested sign table
    for i, sublist in ipairs(nested_sign_list) do
        local main_sign = sublist[1]
        local is_zone = false
        for j, zone_id in ipairs(zone_ids) do
            if main_sign == zone_id or main_sign:sub(1, #zone_id) == zone_id then
                is_zone = true
                break
            end
        end
        if not is_zone then
            table.insert(filtered_list, sublist)
        end
    end
    return filtered_list
end

-- Remove traffic signs from the nested traffic sign list that are not related to a zone
local function remove_regular_signs(nested_sign_list)
    local filtered_list = {}
    -- Take a look at each main sign: If it's not a zone sign, remove it and it's sub signs from the nested sign table
    for i, sublist in ipairs(nested_sign_list) do
        local main_sign = sublist[1]
        local is_zone = false
        for j, zone_id in ipairs(zone_ids) do
            if main_sign == zone_id or main_sign:sub(1, #zone_id) == zone_id then
                is_zone = true
                break
            end
        end
        if is_zone then
            table.insert(filtered_list, sublist)
        end
    end
    return filtered_list
end

-- Converts a nested list into a string, with the sub-list elements separated by “,” and the lists below each other separated by “;”
-- According to the OSM traffic sign convention, e.g. { { '260', '1020-30'}, { '325' } } -> "260,1020-30;325"
function get_sign_list(nested_sign_list)
    local result = {}
    
    for i, sublist in ipairs(nested_sign_list) do
        table.insert(result, table.concat(sublist, ","))
    end

    return table.concat(result, ";")
end


-- Process data
----------------

-- TODO: support traffic_sign:forward/backward

-- traffic_sign: translate human readlable values, extract country code, exclude specific values like "none" or "street_name_sign"
function process_traffic_sign(object, geom, table)

    -- remove "none"/"no"/"yes" and "street_name_sign"
    local traffic_sign_value = object.tags.traffic_sign:gsub("none[;,]?", ""):gsub("no[;,]?", ""):gsub("yes[;,]?", ""):gsub("street_name_sign[;,]?", "")

    -- look for a country code (substring "*:" should be a country code, but don't look for ":" into brackets, because they aren't part of country codes)
    local country_code = string.match(string.match(traffic_sign_value, ".*(:)(?=[^:]*[%[,;])") or traffic_sign_value, "^(.-):")

    -- extract the rest without country code and convert it into a list containing individual signs/subsigns
    local country_code_len = 0
    if country_code then
        country_code_len = #country_code + 1
    end
    local rest = traffic_sign_value:sub(country_code_len + 1)
    -- convert signs into a list, using ";" and "," as separator characters
    local sign_list = tolist(rest, ";,")

    -- exclude geometries without significant information
    if sign_list == nil or sign_list[1] == nil or #sign_list[1] < 1 then
        return
    end

    -- normalize and clean up the traffic sign list
    for i, sign_id in ipairs(sign_list) do

        -- remove repeating country codes
        if country_code then
            if sign_id:sub(1, 3) == country_code .. ':' then
                sign_list[i] = sign_id:sub(4)
            end
        end

        -- replace human readable values by traffic sign id's
        if human_readable_values[sign_id] then
            if sign_id == 'city_limit' and object.tags.city_limit == 'end' then
                sign_list[i] = human_readable_values['city_limit_end']
            elseif sign_id == 'maxspeed' then
                if object.tags.maxspeed == 'implicit' then
                    sign_list[i] = human_readable_values['maxspeed_implicit']
                elseif tonumber(object.tags.maxspeed) ~= nil then
                    sign_list[i] = human_readable_values['maxspeed'] .. '-' .. object.tags.maxspeed
                else
                    sign_list[i] = human_readable_values['maxspeed']
                end
            elseif sign_id == 'overtaking' then
                if object.tags.overtaking == 'yes' then
                    sign_list[i] = human_readable_values['overtaking_yes']
                else
                    sign_list[i] = human_readable_values['overtaking_no']
                end
            else
                sign_list[i] = human_readable_values[sign_id]
            end
            -- add a country code for signs from human readable values
            if country_code == nil then
                country_code = default_country_code
            end
        end
    end

    -- create a nested list with sublists for every main sign and its additional signs
    local nested_sign_list = get_nested_sign_list(sign_list)

    -- insert for way segments
    if table == tbl_traffic_sign_way then

        -- distinguish regular and zonal traffic signs (traffic signs for zones are located at the zone "entrance" only, regular traffic signs at every intersection)
        local zone_status = get_zone_status(nested_sign_list) -- returns a zone status (no/yes/only)
        local table_list = { tbl_traffic_sign_way }
        -- segments with zone signs only are stored in a specific table and excluded from the regular traffic sign way table
        if zone_status == 'only' then
            table_list = { tbl_traffic_sign_zone }
        -- segments with regular and zone signs are stored in both tables
        elseif zone_status == 'yes' then
            table_list = { tbl_traffic_sign_way, tbl_traffic_sign_zone }
        end

        for i, table in ipairs(table_list) do

            -- Exclude zone traffic signs from the lists for regular traffic sign way segments and vice versa
            if table == tbl_traffic_sign_way then
                nested_sign_list = remove_zone_signs(nested_sign_list)
            else
                nested_sign_list = remove_regular_signs(nested_sign_list)
            end
            
            table:insert({
                country_code = country_code,
                main_signs = get_main_signs(nested_sign_list),
                sign_list = get_sign_list(nested_sign_list),
                oneway = object.tags.oneway,
                ["oneway:bicycle"] = object.tags["oneway:bicycle"],
                highway = object.tags.highway,
                layer = object.tags.layer,
                geom = geom
            })
        end

    -- insert for nodes
    else
        table:insert({
            country_code = country_code,
            main_signs = get_main_signs(nested_sign_list),
            sign_list = get_sign_list(nested_sign_list),
            direction = directiontodegree(object.tags.direction),
            layer = object.tags.layer,
            geom = geom
        })
    end
end

function process_highway(object, geom, table)
    table:insert({
        highway = object.tags.highway,
        name = object.tags.name,
        oneway = object.tags.oneway,
        ["oneway:bicycle"] = object.tags["oneway:bicycle"],
        traffic_sign = object.tags.traffic_sign,
        layer = object.tags.layer,
        geom = geom
    })
end

-- Trigger table filling
-------------------------

-- traffic sign nodes
function osm2pgsql.process_node(object)
    if object.tags.traffic_sign then
        process_traffic_sign(object, object:as_point(), tbl_traffic_sign_node)
    end
end

function osm2pgsql.process_way(object)

    -- traffic sign ways (for way features, let's focus on traffic_sign tags on highway centerlines)
    if object.tags.traffic_sign and object.tags.highway then
        process_traffic_sign(object, object:as_linestring(), tbl_traffic_sign_way)
    end

    -- highway ways
    if object.tags.highway and not (object.is_closed and object.tags.area == 'yes') then
        process_highway(object, object:as_linestring(), tbl_highway)
    end
end