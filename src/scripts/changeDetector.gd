@tool
extends GDTComponent

class_name GDTChangeDetector

signal scene_changed
signal node_properties_changed(node: Node, changed_keys: Array[StringName])
signal node_removed(node: Node, path: NodePath)
signal node_added(node: Node)
signal node_renamed(node: Node, old_name: String, new_name: String)
signal node_reparented(node: Node, old_parent: Node, new_parent: Node)
signal node_reordered(node: Node, new_index: int)

enum ResourceType {
	LOCAL,
	FILE,
}

const IGNORED_PROPERTY_USAGE_FLAGS := [
	PROPERTY_USAGE_NONE,
	PROPERTY_USAGE_GROUP,
	PROPERTY_USAGE_CATEGORY,
	PROPERTY_USAGE_SUBGROUP,
	PROPERTY_USAGE_INTERNAL,
	PROPERTY_USAGE_READ_ONLY,
]

# TODO: Ignores for different kinds of objects, Ignore resource_path
const IGNORED_PROPERTIES: Dictionary = {
	&"Node": [
		&"owner",
		&"multiplayer",
	],
	&"Resource": [
		&"resource_path",
	],
}

const REFRESH_RATE: float = 0.1

const KEY_NAME := &"name"
const KEY_PARENT_TRACKER := &"parent_tracker"
const KEY_INDEX_TRACKER := &"index_tracker"

# Dicts are faster than arrays apparently
var observed_nodes := { }
var supressed_nodes := { }

var observed_nodes_cache := { }
var incoming_nodes := {
	# scene path: Array[NodePath]
}

var node_watcher: Timer = Timer.new()
var rescan_timer: Timer = Timer.new()

var last_scene := ""

var filesystem_watcher: Timer = Timer.new()
var suppress_filesystem_sync := false
var cached_file_hashes := { }


static func get_ignored_properties(obj: Object) -> Array[StringName]:
	for key in IGNORED_PROPERTIES.keys():
		if obj.is_class(key):
			return IGNORED_PROPERTIES[key]

	var empty: Array[StringName] = []
	return empty


static func get_property_keys(obj: Object) -> Array[StringName]:
	var res: Array[StringName] = []

	var ignored: Array[StringName] = get_ignored_properties(obj)

	for i in obj.get_property_list():
		var con := true

		if i.name in ignored:
			continue

		for usage in IGNORED_PROPERTY_USAGE_FLAGS:
			if i.usage & usage:
				con = false
				break

		if not con:
			continue
		res.append(i.name)

	return res


static func get_property_dict(obj: Object) -> Dictionary:
	var res := { }

	for i in get_property_keys(obj):
		var value = obj[i]

		if value is Resource:
			value = encode_resource(value)

		res[i] = value

	return res


static func hash_value(value) -> int:
	if value is Object:
		return hash(value) + hash(get_property_hash_dict(value))
	else:
		return hash(value)


static func get_property_hash_dict(obj: Object) -> Dictionary:
	var res := { }

	for i in get_property_keys(obj):
		res[i] = hash_value(obj[i])

	return res


static func is_encoded_resource(value) -> bool:
	return value is Dictionary and "_gdtRes" in value


static func is_file_resource(resource: Resource) -> bool:
	return resource.resource_path != ""


static func encode_resource(resource: Resource) -> Dictionary:
	var res = {
		"_gdtRes": ResourceType.LOCAL,
		"sub": { },
	}

	var cloned = false

	for key in get_property_keys(resource):
		var value = resource[key]

		if value is Resource:
			if not cloned:
				cloned = true
				resource = resource.duplicate()

			resource[key] = null
			res["sub"][key] = encode_resource(value)

	if not is_file_resource(resource):
		res["buf"] = var_to_bytes_with_objects(resource)
	else:
		res["_gdtRes"] = ResourceType.FILE
		res["path"] = resource.resource_path

	return res


static func decode_resource(dict: Dictionary) -> Resource:
	assert(is_encoded_resource(dict), "Provided dict isn't a resource dict")

	var resource: Resource

	if "path" in dict:
		assert(GDTValidator.is_path_safe(dict["path"]), "Cannot load resource from unsafe path %s" % dict["path"])

		resource = load(dict["path"])
	elif "buf" in dict:
		resource = bytes_to_var_with_objects(dict["buf"])
		assert(resource is Resource, "Decoded resource isn't a resource")

		if "sub" in dict:
			var sub = dict["sub"]

			if sub is Dictionary:
				for key in sub.keys():
					resource[key] = decode_resource(sub[key])
	else:
		push_error("Cannot decode resource: 'buf' and 'path' missing from resource dict")

	return resource


func _ready() -> void:
	node_watcher.wait_time = REFRESH_RATE
	node_watcher.timeout.connect(_cycle)
	add_child(node_watcher)
	node_watcher.start()

	rescan_timer.wait_time = 3
	rescan_timer.timeout.connect(observe_current_scene)
	add_child(rescan_timer)
	rescan_timer.start()

	filesystem_watcher.wait_time = 1.0
	filesystem_watcher.timeout.connect(_check_filesystem_changes)
	add_child(filesystem_watcher)
	filesystem_watcher.start()

	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_filesystem_changed)


func _cycle() -> void:
	var root := EditorInterface.get_edited_scene_root()

	if not main:
		return
	if not root:
		return

	if GDTSettings.get_setting("dev/disable_node_scanning"):
		return

	var current_scene_path := root.scene_file_path

	if last_scene != current_scene_path:
		last_scene = current_scene_path
		scene_changed.emit()

	for node in observed_nodes:
		if not is_instance_valid(node):
			continue

		if not node.is_inside_tree():
			continue

		track_node_parent(node)

		var cached: Dictionary = observed_nodes_cache[node]
		var current := get_property_hash_dict(node)

		var changed_keys: Array[StringName] = []

		for i in current.keys():
			if i == KEY_NAME:
				if (i in cached) and (cached[i] != current[i]):
					var old_name = observed_nodes[node][KEY_NAME]

					if not supressed_nodes.has(node):
						node_renamed.emit(node, old_name, node.name)

					observed_nodes[node][KEY_NAME] = node.name

			if (not i in cached) or (not i in current) or (cached[i] != current[i]):
				changed_keys.append(i)

		if changed_keys.size() != 0:
			if not supressed_nodes.has(node):
				node_properties_changed.emit(node, changed_keys)

			observed_nodes_cache[node] = current


func track_node_parent(node: Node) -> void:
	var data: Dictionary = observed_nodes[node]

	if not KEY_PARENT_TRACKER in data:
		data[KEY_PARENT_TRACKER] = node.get_parent()
		data[KEY_INDEX_TRACKER] = node.get_index()

	var old_parent = data[KEY_PARENT_TRACKER]
	var current_parent = node.get_parent()

	if old_parent != current_parent and is_instance_valid(old_parent) and is_instance_valid(current_parent):
		data[KEY_PARENT_TRACKER] = current_parent
		data[KEY_INDEX_TRACKER] = node.get_index()
		node_reparented.emit(node, old_parent, current_parent)
	else:
		var old_index: int = data[KEY_INDEX_TRACKER]
		var current_index: int = node.get_index()
		if old_index != current_index:
			data[KEY_INDEX_TRACKER] = current_index
			if not supressed_nodes.has(node):
				node_reordered.emit(node, current_index)


func _node_added(node: Node) -> void:
	var current_scene := EditorInterface.get_edited_scene_root()
	var scene_path := current_scene.scene_file_path

	if scene_path in incoming_nodes:
		var incoming = incoming_nodes[scene_path]
		var node_path = current_scene.get_path_to(node)

		if node_path in incoming:
			incoming.erase(node_path)
			return

	if not node in observed_nodes:
		observe_recursive(node)
		node_added.emit(node)


func _node_exiting(node: Node) -> void:
	var scene = EditorInterface.get_edited_scene_root()
	if not scene or not is_instance_valid(node):
		return

	if scene.is_ancestor_of(node):
		var node_path = scene.get_path_to(node)
		node_removed.emit(node, node_path)


func observe_current_scene() -> void:
	var scene = EditorInterface.get_edited_scene_root()
	if not scene:
		return

	if scene.scene_file_path.begins_with("res://addons/GodotTogether/"):
		return

	main.change_detector.observe_recursive(scene)

	if not scene.tree_exiting.is_connected(delayed_observe_current_scene):
		scene.tree_exiting.connect(delayed_observe_current_scene)


func delayed_observe_current_scene() -> void:
	await get_tree().process_frame

	observe_current_scene()


func disconnect_signal_from_self(sig: Signal) -> void:
	for i in sig.get_connections():
		var fn: Callable = i.callable

		if fn.get_object() == self:
			sig.disconnect(fn)


func clear() -> void:
	for node in observed_nodes.keys():
		disconnect_signal_from_self(node.tree_exiting)
		disconnect_signal_from_self(node.child_entered_tree)

	observed_nodes.clear()
	observed_nodes_cache.clear()
	incoming_nodes.clear()


func pause() -> void:
	node_watcher.paused = true


func resume() -> void:
	node_watcher.paused = false


func merge(node: Node, property_dict: Dictionary) -> void:
	observe(node)

	if KEY_NAME in property_dict:
		observed_nodes[node][KEY_NAME] = property_dict[KEY_NAME]

	for key in property_dict.keys():
		observed_nodes_cache[node][key] = hash_value(node[key])


func set_node_supression(node: Node, supressed: bool) -> void:
	if supressed:
		supressed_nodes.get_or_add(node, true)
	else:
		supressed_nodes.erase(node)


func get_observed_nodes() -> Array[Node]:
	var res: Array[Node]

	for i in observed_nodes.keys():
		res.append(i)

	return res


func suppress_add_signal(scene_path: String, node_path: NodePath) -> void:
	if not scene_path in incoming_nodes:
		incoming_nodes[scene_path] = []

	incoming_nodes[scene_path].append(node_path)


func observe(node: Node) -> void:
	if node in observed_nodes:
		return

	observed_nodes_cache[node] = get_property_hash_dict(node)
	observed_nodes[node] = {
		KEY_NAME: node.name,
		KEY_PARENT_TRACKER: node.get_parent(),
		KEY_INDEX_TRACKER: node.get_index(),
	}

	node.tree_exiting.connect(_node_exiting.bind(node))
	node.child_entered_tree.connect(_node_added)


func observe_recursive(node: Node) -> void:
	observe(node)

	for i in GDTUtils.get_descendants(node):
		observe(i)


func can_sync_files() -> bool:
	return not node_watcher.paused and not suppress_filesystem_sync and not GDTSettings.get_setting("dev/disable_real_time_file_sync")


func _filesystem_changed() -> void:
	await get_tree().create_timer(0.5).timeout
	_check_filesystem_changes()


func _check_filesystem_changes() -> void:
	if not main:
		return
	if not main.is_session_active():
		return
	if not can_sync_files():
		return

	if main.client.is_active() and not main.client.is_fully_synced:
		return

	var current_hashes = GDTFiles.get_file_tree_hashes()

	for path in current_hashes:
		if not path in cached_file_hashes:
			_file_added(path)
		elif cached_file_hashes[path] != current_hashes[path]:
			_file_modified(path)

	for path in cached_file_hashes:
		if not path in current_hashes:
			_file_removed(path)

	cached_file_hashes = current_hashes


func _file_added(path: String) -> void:
	if main.client.is_active():
		var buffer = FileAccess.get_file_as_bytes(path)

		if buffer:
			print("[CLIENT] Sending file add: ", path)
			main.server.file_add_from_client.rpc_id(1, path, buffer)

	elif main.server.is_active():
		print("[SERVER] Broadcasting file add: ", path)
		main.server.broadcast_file_add(path)


func _file_modified(path: String) -> void:
	if main.client.is_active():
		var buffer = FileAccess.get_file_as_bytes(path)

		if buffer:
			print("[CLIENT] Sending file modify: ", path)
			main.server.file_modify_from_client.rpc_id(1, path, buffer)

	elif main.server.is_active():
		print("[SERVER] Broadcasting file modify: ", path)
		main.server.broadcast_file_modify(path)


func _file_removed(path: String) -> void:
	if main.client.is_active():
		print("[CLIENT] Sending file remove: ", path)
		main.server.file_remove_from_client.rpc_id(1, path)

	elif main.server.is_active():
		print("[SERVER] Broadcasting file remove: ", path)
		main.server.broadcast_file_remove(path)
