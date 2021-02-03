--------------------------------------------------------
-- Minetest :: Basic Survival Mod (survival)
--
-- See README.txt for licensing and release notes.
-- Copyright (c) 2016-2020, Leslie E. Krause
--
-- ./games/just_test_tribute/mods/survival/init.lua
--------------------------------------------------------

local S1, S1_ = Stopwatch( "survival" )

local config = minetest.load_config( )
local players = { }

----------------------

local range_effects_list = { }
local touch_effects_list = { }
local touch_below_effects = { }

for k, v in pairs( config.effects ) do
	-- create a lookup-table of relevant touch effects
	if v.touch_temp then
		touch_below_effects[ k ] = v
	end
end

for k, v in pairs( config.effects ) do
	-- create a list of relevant range effects
	if v.range_temp then
		table.insert( range_effects_list, k )
	end
end

for k, v in pairs( config.effects ) do
	-- create a list of relevant touch effects
	if v.touch_temp then
		table.insert( touch_effects_list, k )
	end
end

----------------------

local old_after_joinplayer = armor.after_joinplayer
local old_after_leaveplayer = armor.after_leaveplayer
local old_reset_player_armor = armor.reset_player_armor

armor.after_joinplayer = function ( player )
	local player_name = player:get_player_name( )
	local def = {
		gauges = { },
		wetness = 0.0,
		felt_temp = 72,		-- the perceived temperature by the body
		body_temp = 95,		-- the actual temperature of the body
		is_immortal = minetest.check_player_privs( player_name, { server = true } ),
	}

	def.screen = player:hud_add( {
		hud_elem_type = "image",
		text ="survival_screen.png",
		scale = { x = -100, y = -100 },
		alignment = { x = 1, y = 1 },
	} )

	def.gauges.felt_temp = player:hud_add( {
		hud_elem_type = "image",
		text = "",
		position = { x = 0.05, y = 0.95 },
		scale = { x = 0.8, y = 0.8 },
		alignment = { x = 1, y = 0 },
	} )

	def.gauges.wetness = player:hud_add( {
		hud_elem_type = "image",
		text = "",
		position = { x = 0.15, y = 0.95 },
		scale = { x = 1.0, y = 1.0 },
		alignment = { x = 1, y = 0 },
	} )

	player:hud_add( {
		hud_elem_type = "text",
		text = "Temp Felt:",
		number = 0xFFFFFF,
		offset = { x = 0, y = -30 },
		position = { x = 0.05, y = 0.95 },
		scale = { x = -100, y = -100 },
		alignment = { x = 1, y = 0 },
	} )

	players[ player_name ] = def
	old_after_joinplayer( player )
end

minetest.register_on_respawnplayer( function ( player )
	local name = player:get_player_name( )

	player:hud_change( players[ name ].screen, "text", "survival_screen.png" )
	players[ name ].felt_temp = 72

	return false
end )

armor.after_leaveplayer = function ( player )
	old_after_leaveplayer( )

	players[ player:get_player_name( ) ] = nil
end

armor.reset_player_armor = function ( player_name )
	old_reset_player_armor( player_name )
	--print( "RESET ARMOR", dump( armor.def[ player_name ] ) )

	local pdata = armor.get_player_armor( player_name )

	if not pdata or pdata.ratings.level == 0 then		-- sanity check since sometimes 3d_armor gets player_pos nil?
		players[ player_name ].clothing = nil
		players[ player_name ].footwear = nil
	else
		-- obtain clothing and optional footwear attributes
		players[ player_name ].clothing = {
			real_temp = 72,				-- current/starting temperature of clothing
			insulation = pdata.ratings.insulation,	-- the degree by which clothing resists changes in temperature
			conduction = pdata.ratings.conduction,	-- the degree by which clothing absorbs and transfers heat and cold
		}
		if pdata.groups.feet then
			players[ player_name ].footwear = {
				insulation = pdata.groups.feet.insulation,	-- the degree by which footwear resists changes in temperature
				conduction = pdata.groups.feet.conduction,	-- the degree by which footwear absorbs and transfers heat and cold
			}
		else
			players[ player_name ].footwear = nil
		end
	end
	--print( "ADDED ARMOR!", dump( players[ player_name ] ) )
end

----------------------

local safe_temp_range = ( config.safe_temp_max - config.safe_temp_min ) / 2
local room_temp = config.safe_temp_min + safe_temp_range

local function get_felt_temp_texture( felt_temp, is_metric )
	local offset = math.min( math.floor( math.abs( room_temp - felt_temp ) / safe_temp_range * 8 ), 8 )

	-- red for warmer temp (20 bits left shift)
	-- blue for cooler temp (4 bits left shift)
	return snowdrift.create_temp_texture( is_metric,
		is_metric and ( felt_temp - 32 ) * 5 / 9 or felt_temp,
		felt_temp > room_temp and 0x666666 + offset * 2 ^ 20 or 0x666666 + offset * 2 ^ 4
	)
end

local function get_wetness_texture( wetness )
	return wetness == 0 and "" or string.format( "survival_waves%d.png", math.ceil( 3 * wetness ) )
end

local function get_screen_color( sensation, hp )
	local color_codes = { warm = "#ff2222%02x", cool = "#2222ff%02x" }

	return string.format( "survival_screen.png^[colorize:" .. color_codes[ sensation ],
		hp < config.danger_threshold and 0xdd or 0x99 )
end

local function get_player_damage( felt_temp )
	if felt_temp < config.safe_temp_min then
		return ( config.safe_temp_min - felt_temp ) / config.damage_ratio, "cool"
	elseif felt_temp > config.safe_temp_max then
		return ( felt_temp - config.safe_temp_max ) / config.damage_ratio, "warm"
	end
	return 0, felt_temp < room_temp and "cool" or "warm"
end

----------------------

local function FeltTempCalc( felt_temp )
	local a_sum = 0
	local b_sum = 0
	return {
		insert = function ( amplitude, insulation, goal_temp )
			-- sum amplitude and goal_temp for weighted average
			local weight = amplitude * math.max( 1 - insulation, 0 )
			a_sum = a_sum + weight
			b_sum = b_sum + goal_temp * weight
		end,
		get_result = function ( rate )
			return felt_temp + ( b_sum / a_sum - felt_temp ) * rate
		end,
	}
end

local function RealTempCalc( real_temp )
	local a_sum = 0
	local b_sum = 0
	return {
		insert = function ( amplitude, conduction, goal_temp )
			-- sum amplitude and goal_temp for weighted average
			local weight = amplitude * conduction
			a_sum = a_sum + weight
			b_sum = b_sum + goal_temp * weight
		end,
		get_result = function ( )
			-- if conduction is 0, then real_temp doesn't change
			return a_sum > 0 and real_temp + ( b_sum / a_sum - real_temp ) or real_temp
		end,
	}
end

function Thermostat( self, def )
	local safe_temp_min = def.safe_temp_min or config.safe_temp_min
	local safe_temp_max = def.safe_temp_max or config.safe_temp_max
	local damage_ratio = def.damage_ratio or config.damage_ratio

	self.felt_temp = def.base_temp or ( safe_temp_max - safe_temp_min ) / 2

	local function get_damage( felt_temp )
		if felt_temp < safe_temp_min then
			return ( safe_temp_min - felt_temp ) / damage_ratio
		elseif felt_temp > safe_temp_max then
			return ( felt_temp - safe_temp_max ) / damage_ratio
		end
		return 0
	end

	self.timekeeper.start( 2.0, "survival", function ( )
		local hp = self.object:get_hp( )
		local origin_temp = snowdrift.calc_temp_at( vector.round( self.pos ) )

		self.felt_temp = recalc_temp( vector.round( self.pos ), self.felt_temp, origin_temp )

		if hp > 0 then
			local damage = get_damage( self.felt_temp )
			local new_hp = math.floor( hp - damage )

			if damage > 0 then
				self.object:set_hp( new_hp )
			end
		end
	end )
end

----------------------

local function clamp( val, min, max )
	return val < min and min or val > max and max or val
end

local function ramp( base, scale, cur_val, max_val )
	return base + scale * clamp( cur_val / max_val, 0, 1 )
end

local function recalc_temp( pos, felt_temp, node_temp )
	local felt_calc = FeltTempCalc( felt_temp )

	-- step 1: apply ambient indoor or outdoor temperature
	felt_calc.insert( 0.4, 0.0, node_temp )

	-- step 2: apply conduction temperature from adjacent nodes
	local touch_counts = minetest.count_nodes_in_area(
		{ x = pos.x - 0.4, y = pos.y - 0.4, z = pos.z - 0.4 },
		{ x = pos.x + 0.4, y = pos.y + 0.4, z = pos.z + 0.4 },
		touch_effects_list
	)
	local touch_temp_sum = 0
	local touch_temp_len = 0
	for k, v in pairs( touch_counts ) do
		if v > 0 then	-- make sure the count is non-zero to apply the effect
			touch_temp_sum = touch_temp_sum + config.effects[ k ].touch_temp
			touch_temp_len = touch_temp_len + 1
		end
	end
	if touch_temp_len > 0 then
		felt_calc.insert( 0.8, 0.0, touch_temp_sum / touch_temp_len )
	end

	-- step 4: apply conduction temperature from nearby nodes
	local range_counts = minetest.count_nodes_in_area(
		{ x = pos.x - 3, y = pos.y - 3, z = pos.z - 3 },
		{ x = pos.x + 3, y = pos.y + 3, z = pos.z + 3 },
		range_effects_list
	)
	local total = 0
	local range_temp_sum = 0
	local range_temp_len = 0

	for k, v in pairs( range_counts ) do
		local touch_count = touch_counts[ k ] or 0
		local count = v - touch_count

		if count > 0 then	-- eliminate already counted nodes
			range_temp_sum = range_temp_sum + config.effects[ k ].range_temp
			range_temp_len = range_temp_len + 1
			total = total + count
		end
	end
	if range_temp_len > 0 then
		local weight = ramp( 0.3, 0.5, total, 25 )  -- range is 0.3 to 0.8
		felt_calc.insert( weight, 0.0, range_temp_sum / range_temp_len )
	end

	return felt_calc.get_result( 0.6 )
end

function get_daylight( param1 )
	return ( param1 / 16 ) % 1 * 16
end

----------------------

globaltimer.start( config.timer_period, "survival:temp_regulator", function ( cycles )
	S1( )
	for name, data in pairs( registry.connected_players ) do
		local player = data.obj
		local self = players[ name ]

		if not registry.avatar_list[ name ] then
			local pos = player:get_pos( )
			local node_temp, is_metric = snowdrift.get_player_temp( name )
			local wetness = 0.9 * snowdrift.get_rainfall_at( pos )

			if self.clothing then
				local felt_calc = FeltTempCalc( self.felt_temp )
				local real_calc = RealTempCalc( self.clothing.real_temp )

				-- step 1: apply ambient indoor or outdoor temperature
				felt_calc.insert( 0.4, self.clothing.insulation, node_temp )
				real_calc.insert( 0.4, self.clothing.conduction, node_temp )

				-- step 2: apply conduction temperature from wielded item
				local item_name = player:get_wielded_item( ):get_name( )
				if config.effects[ item_name ] and config.effects[ item_name ].wield_temp then
					felt_calc.insert( 0.8, 0.0, config.effects[ item_name ].wield_temp )
				end

				-- step 3: apply conduction temperature from node below
				local node_below_name

				if self.footwear then
					node_below_name = minetest.get_node_above( pos, -0.1 ).name
					if touch_below_effects[ node_below_name ] then
						local f = self.footwear
						felt_calc.insert( 0.8, f.insulation * 4, config.effects[ node_below_name ].touch_temp )
						real_calc.insert( 0.8, f.conduction * 4, config.effects[ node_below_name ].touch_temp )
					end
				end

				-- step 4: apply conduction temperature from adjacent nodes
				local touch_counts = minetest.count_nodes_in_area(
					{ x = pos.x - 0.5, y = pos.y + ( self.footwear and 0.3 or -0.1 ), z = pos.z - 0.5 },
					{ x = pos.x + 0.5, y = pos.y + 1.9, z = pos.z + 0.5 },
					touch_effects_list
				)
				local touch_temp_sum = 0
				local touch_temp_len = 0
				for k, v in pairs( touch_counts ) do
					if v > 0 then	-- make sure the count is non-zero to apply the effect
						touch_temp_sum = touch_temp_sum + config.effects[ k ].touch_temp
						touch_temp_len = touch_temp_len + 1
						if config.effects[ k ].wetness then
							-- TODO: revamp to determine how much we're immersed. this also
							-- needs to account for leveled nodes and nodeboxes
							wetness = math.max( wetness,
								config.effects[ k ].wetness * clamp( v - 2, 1, 4 ) / 4
							)
						end
					end
				end
				if touch_temp_len > 0 then
					felt_calc.insert( 0.8, self.clothing.insulation, touch_temp_sum / touch_temp_len )
					real_calc.insert( 0.8, self.clothing.conduction, touch_temp_sum / touch_temp_len )
				end

				-- step 5: apply conduction temperature from nearby nodes
				local range_counts = minetest.count_nodes_in_area(
					{ x = pos.x - 3, y = pos.y - 2.5, z = pos.z - 3 },
					{ x = pos.x + 3, y = pos.y + 4.5, z = pos.z + 3 },
					range_effects_list
				)
				local total = 0
				local range_temp_sum = 0
				local range_temp_len = 0

				for k, v in pairs( range_counts ) do
					local touch_count = touch_counts[ k ] or 0
					local below_count = k == node_below_name and 1 or 0
					local count = v - touch_count - below_count

					if count > 0 then	-- eliminate already counted nodes
						range_temp_sum = range_temp_sum + config.effects[ k ].range_temp
						range_temp_len = range_temp_len + 1
						total = total + count
					end
				end
				if range_temp_len > 0 then
					local weight = ramp( 0.3, 0.5, total, 25 )  -- range is 0.3 to 0.8
					felt_calc.insert( weight, self.clothing.insulation, range_temp_sum / range_temp_len )
					real_calc.insert( weight, self.clothing.conduction, range_temp_sum / range_temp_len )
				end

				-- step 6: apply body temperature based on inverse insulation
				felt_calc.insert( 0.4, 1 - self.clothing.insulation, self.body_temp )

				-- step 7: apply clothing temperature based on no insulation
				self.clothing.real_temp = real_calc.get_result( )
				felt_calc.insert( self.clothing.conduction, 0.0, self.clothing.real_temp )

				-- step 8: apply wetness temperature from all sources
				self.wetness = math.max( wetness, self.wetness * ( 1.0 - config.dryness_rate ) )
				if self.wetness < 0.05 then
					self.wetness = 0.0  -- close enough to zero, so floor it
				else
					felt_calc.insert( self.wetness * 0.8, self.clothing.insulation, config.wetness_temp )
				end

				self.felt_temp = felt_calc.get_result( 0.6 )

			else
				local felt_calc = FeltTempCalc( self.felt_temp )

				-- step 1: apply ambient indoor or outdoor temperature
				felt_calc.insert( 0.4, 0.0, node_temp )

				-- step 2: apply conduction temperature from wielded item
				local item_name = player:get_wielded_item( ):get_name( )
				if config.effects[ item_name ] and config.effects[ item_name ].wield_temp then
					felt_calc.insert( 0.8, 0.0, config.effects[ item_name ].wield_temp )
				end

				-- step 3: apply conduction temperature from adjacent nodes
				local touch_counts = minetest.count_nodes_in_area(
					{ x = pos.x - 0.4, y = pos.y - 0.1, z = pos.z - 0.4 },
					{ x = pos.x + 0.4, y = pos.y + 1.9, z = pos.z + 0.4 },
					touch_effects_list
				)
				local touch_temp_sum = 0
				local touch_temp_len = 0

				for k, v in pairs( touch_counts ) do
					if v > 0 then	-- make sure the count is non-zero to apply the effect
						touch_temp_sum = touch_temp_sum + config.effects[ k ].touch_temp
						touch_temp_len = touch_temp_len + 1
						if config.effects[ k ].wetness then
							-- TODO: revamp to determine how much we're immersed.
							wetness = math.max( wetness,
								config.effects[ k ].wetness * clamp( v - 2, 1, 4 ) / 4
							)
						end
					end
				end
				if touch_temp_len > 0 then
					felt_calc.insert( 0.8, 0.0, touch_temp_sum / touch_temp_len )
				end

				-- step 4: apply conduction temperature from nearby nodes
				local range_counts = minetest.count_nodes_in_area(
					{ x = pos.x - 3, y = pos.y - 2.5, z = pos.z - 3 },
					{ x = pos.x + 3, y = pos.y + 4.5, z = pos.z + 3 },
					range_effects_list
				)
				local total = 0
				local range_temp_sum = 0
				local range_temp_len = 0

				for k, v in pairs( range_counts ) do
					local touch_count = touch_counts[ k ] or 0
					local count = v - touch_count

					if count > 0 then	-- eliminate already counted nodes
						range_temp_sum = range_temp_sum + config.effects[ k ].range_temp
						range_temp_len = range_temp_len + 1
						total = total + count
					end
				end
				if range_temp_len > 0 then
					local weight = ramp( 0.3, 0.5, total, 25 )
					felt_calc.insert( weight, 0.0, range_temp_sum / range_temp_len )
				end

				-- step 5: apply wetness temperature from all sources
				self.wetness = math.max( wetness, self.wetness * ( 1.0 - config.dryness_rate ) )
				if self.wetness < 0.05 then
					self.wetness = 0.0  -- close enough to zero, so floor it
				else
					felt_calc.insert( self.wetness * 0.8, 0.0, config.wetness_temp )
				end

				self.felt_temp = felt_calc.get_result( 0.6 )
			end

			player:hud_change( players[ name ].gauges.felt_temp, "text", get_felt_temp_texture( self.felt_temp, is_metric ) )
			player:hud_change( players[ name ].gauges.wetness, "text", get_wetness_texture( self.wetness ) )

			local hp = player:get_hp( )

			if hp > 0 and not self.is_immortal then
				local damage, sensation = get_player_damage( self.felt_temp )
				local new_hp = math.floor( hp - damage )

				if damage > 0 and cycles % math.max( 1, math.ceil( 4 - damage ) ) == 0 then
					-- inflict damage to player
					player:set_hp( new_hp )
					player:hud_change( players[ name ].screen, "text", get_screen_color( sensation, new_hp ) )

					if new_hp < config.danger_threshold then
						minetest.chat_send_player( name, string.format( "You are suffering from %s!",
							( { cool = "frostbite", warm = "heat stroke" } )[ sensation ] ) )
					else
						minetest.chat_send_player( name, string.format( "You are %s to death!",
							( { cool = "freezing", warm = "burning" } )[ sensation ] ) )
					end
				else
					player:hud_change( players[ name ].screen, "text", "survival_screen.png" )
				end
			end

			--[[
			if self.clothing then
				print( string.format( "player=%d, insulation=%0.2f, conduction=%0.2f, real=%d, body=%d, felt=%d, damage=%0.1f",
					node_temp, self.clothing.insulation, self.clothing.conduction, self.clothing.real_temp, self.body_temp, self.felt_temp, damage ) )
			else
				print( string.format( "player=%d, insulation=NA, conduction=NA, real=NA, body=NA, felt=%d, damage=%0.1f",
					node_temp, self.felt_temp, damage ) )
			end]]
		end
	end
	S1_( )
end, config.timer_delay )

minetest.register_node( "survival:thermometer", {
	description = "Thermometer",
	groups = { dig_immediate = 3 },
	drawtype = "nodebox",
	paramtype = "light",
	paramtype2 = "facedir",
	walkable = false,
	sunlight_propagates = true,

	inventory_image = "thermometer_item.png",
	wield_image = "thermometer_item.png",
	tiles = { "thermometer.png" },
	sounds = default.node_sound_wood_defaults( ),

	node_box = {
		type = "fixed",
		fixed = {
			{ -0.1, -0.25, 0.43, 0.1, 0.25, 0.5 }
		}
	},

	on_construct = function ( pos )
		local meta = minetest.get_meta( pos )
		meta:set_string( "infotext", "Current temperature:" )
		meta:set_float( "felt_temp", room_temp )
		minetest.get_node_timer( pos ):start( 2.0 )
	end,

	on_timer = function ( pos, elapsed )
		local meta = minetest.get_meta( pos )
		local felt_temp = meta:get_float( "felt_temp" )
		local node_temp = snowdrift.calc_temp_at( pos )
		local node = minetest.get_node( pos )
		local to_offset = {
			[0] = { x = 0, y = 0, z = 0.4 },
			[1] = { x = 0.4, y = 0, z = 0 },
			[2] = { x = 0, y = 0, z = -0.4 },
			[3] = { x =-0.4, y = 0, z = 0 },
		}
		local wall_pos = vector.add( pos, to_offset[ node.param2 ] )  -- account for orientation

		felt_temp = recalc_temp( wall_pos, felt_temp, node_temp ) 

		meta:set_string( "infotext", string.format( "Current temperture: %0.1f F (%0.1f C)",
			felt_temp, ( felt_temp - 32 ) * 5 / 9 ) )
		meta:set_float( "felt_temp", felt_temp )

		return true
	end,
} )

minetest.register_craft( {
	output = "survival:thermometer",
	recipe = {
		{ "default:glass" },
		{ "bucket:bucket_river_water" },
		{ "default:steel_ingot" },
	}
} )

minetest.register_alias( "snowdrift:thermometer", "survival:thermometer" )
