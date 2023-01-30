
# RFG zone file format
This file describes the zone format used by RFG. These files have either the `.rfgzone_pc` or `.layer_pc` extension. They contain a list of objects and their properties for a single map zone. Multiplayer and Wrecking Crew maps all consist of one zone. The Singleplayer maps consist of many zones. 

# Format description
This section hasn't been written yet. Please refer to [ZoneFile.bf](https://github.com/Moneyl/RfgTools/blob/main/src/Formats/Zones/ZoneFile.bf).

# Object types
This section lists all zone object types and the properties they support. Zone objects also have the properties of any type they inherit. This applies recursively. E.g. If type `C` inherits `B` which inherits `A`. Then `C` has all the properties of `B` and `A`. The property names are the unique identifiers the game uses for them. There are some intentional typos in the names since the typos are hardcoded into the vanilla game.

## General objects
These types are used in all game modes.

----------------

### **object**
The base type inherited by all other objects.


**just_pos** (*Vec3*, Type=5, Size=12):

Object position. If the object has this property then `orient` is set to the identity matrix.


**op** (*ObjectProperties*, Type=5, Size=48, Optional):

Position (Vec3) and orient (Mat33). This will be ignored if the object also has a `just_pos` property.


**display_name** (*string*, Type=4, Optional):

It's unknown if this has any use in the release version of the game. This might be a remnant from CLOE. The game seems to store the name at runtime, so it might be useful for locating items when we eventually have in game debugging tools.

----------------

### **obj_zone** (*inherits **object***)
Each zone has one of these objects. They sit at the center of the zone and define the terrain file to use for that zone.


**ambient_spawn** (*string*, Type=4, Optional):

Name of the `ambient_spawn_info.xtbl` entry used by this object.


**spawn_resource** (*string*, Type=4, Optional):

Name of the `spawn_resource.xtbl` entry used by this object.

Default = "Default"


**terrain_file_name** (*string*, Type=4):

Base name for the terrain files used by this zone. E.g. If it equals `mp_crescent` then the terrain files should be `mp_crescent.cterrain_pc`, `mp_crescent_0.ctmesh_pc`, etc.


**wind_min_speed** (*float*, Type=5, Size=4, Optional):

Unconfirmed purpose. Might related to the ambient wind effect seen on some maps.

Default = 50.0f


**wind_max_speed** (*float*, Type=5, Size=4, Optional):

Unconfirmed purpose. Might related to the ambient wind effect seen on some maps.

Default = 80.0f

----------------

### **object_bounding_box** (*inherits **object***)
General bounding box used by the game for mission scripting.


**bb** (*bbox*, Type=5, Size=24):
Local space bounding box. 


**bounding_box_type** (*string*, Type=4, Optional):
Likely used to determine what logic the game should run on it.

Options = {"GPS Target", "None"}

Default = "None"

----------------

### **object_dummy** (*inherits **object***)
Dummy object used for scripting.


**dummy_type** (*string*, Type=4):

It's currently unknown what effect each of these types has.

Options = {"None", "Tech Reponse Pos", "VRail Spawn", "Demo Master", "Cutscene", "Air Bomb", "Rally", "Barricade", "Reinforced_Fence", "Smoke Plume", "Demolition"}

----------------


### **player_start** (*inherits **object***)

### **trigger_region** (*inherits **object***)

### **object_mover** (*inherits **object***)

### **general_mover** (*inherits **object_mover***)

### **rfg_mover** (*inherits **object_mover***)

### **shape_cutter** (*inherits **object***)

### **object_effect** (*inherits **object***)

### **item** (*inherits **object***)

### **weapon** (*inherits **item***)

### **ladder** (*inherits **object***)

### **obj_light** (*inherits **object***)


## MP only objects
These types are only used in multiplayer maps.

### **multi_object_marker** (*inherits **object***)

### **multi_object_flag** (*inherits **item***)

### **multi_object_backpack** (*inherits **item***)


## SP only objects
These types are only used in single player zones. One exception is `navpoint` and `cover_node` objects found in the Nordic Special map. This is thought to be a mistake or some objects left behind from the remaster developers learning the mapping tools. The section is incomplete since the Nanoforge rewrite doesn't support opening and editing single player maps yet. It'll be updated when SP support is added.

### **navpoint** (*inherits **object***)
Thought to be used by AI for navigation.

### **cover_node** (*inherits **object***)
Thought to be used for the players cover system.

### **constraint** (*inherits **object***)

### **object_squad** (*inherits **object***)

### **object_turret_spawn_node** (*inherits **object***)

### **object_air_strike_defense_node** (*inherits **object***)
Start location for a cancelled or incomplete activity.

### **object_spawn_region** (*inherits **object***)

### **object_demolitions_master_node** (*inherits **object***)

### **object_convoy** (*inherits **object***)

### **object_convoy_end_point** (*inherits **object***)

### **object_courier_end_point** (*inherits **object***)

### **object_vehicle_spawn_node** (*inherits **object***)

### **object_riding_shotgun_node** (*inherits **object***)

### **object_area_defense_node** (*inherits **object***)

### **object_action_node** (*inherits **object***)

### **object_raid_node** (*inherits **object***)

### **object_guard_node** (*inherits **object***)

### **object_house_arrest_node** (*inherits **object***)

### **object_safehouse** (*inherits **object***)

### **object_activity_spawn** (*inherits **object***)

### **object_squad_spawn_node** (*inherits **object***)

### **object_upgrade_node** (*inherits **object***)

### **object_path_road** (*inherits **object***)

### **object_bftp_node** (*inherits **object***)

### **object_mission_start_node** (*inherits **object***)

### **marauder_ambush_region** (*inherits **object***)

### **object_roadblock_node** (*inherits **object***)

### **object_restricted_area** (*inherits **object***)

### **object_delivery_node** (*inherits **object***)

### **object_ambient_behavior_region** (*inherits **object***)

### **object_npc_spawn_node** (*inherits **object***)

### **object_patrol** (*inherits **object***)

## Runtime objects
These types aren't found in vanilla zone files. They're only created by the game at runtime. No one has tested adding one of these to a map at the time of writing since Nanoforge doesn't support them yet. The section is incomplete for the same reason.

### **vehicle** (*inherits **object***)

### **automobile** (*inherits **vehicle***)

### **walker** (*inherits **vehicle***)

### **flyer** (*inherits **vehicle***)

### **human** (*inherits **object***)

### **npc** (*inherits **human***)

### **player** (*inherits **human***)

### **turret** (*inherits **object***)

### **object_debris** (*inherits **object***)

### **district** (*inherits **object***)

### **projectile** (*inherits **item***)
