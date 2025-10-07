extends Node2D

@onready var display = $CanvasLayer/MessageDisplay
@onready var back_button = $CanvasLayer/Back
@onready var peer: EOSGMultiplayerPeer = EOSGMultiplayerPeer.new()

@export var game_scene: PackedScene

var local_user_id = ""
var is_server = false
var peer_user_id = 0

var local_lobby: HLobby

func _ready() -> void:
	display.text = "Starting"
	
	#Initialize the SDK
	if not EosCredentials.EosSetup:
		var init_opts = EOS.Platform.InitializeOptions.new()
		init_opts.product_name = EosCredentials.PRODUCT_NAME
		init_opts.product_version = EosCredentials.PRODUCT_ID
	
		var init_results = EOS.Platform.PlatformInterface.initialize(init_opts)
		if init_results != EOS.Result.Success:
			printerr("Failed to initialize EOS SDK: " + EOS.result_str(init_results))
			display.text = "Failed to initialize EOS SDK: " + EOS.result_str(init_results)
			back_button.visible = true
			return
		print("Initialized EOS Platform")
	
		# Create EOS platform
		var create_opts = EOS.Platform.CreateOptions.new()
		create_opts.product_id = EosCredentials.PRODUCT_ID
		create_opts.sandbox_id = EosCredentials.SANDBOX_ID
		create_opts.deployment_id = EosCredentials.DEPLOYMENT_ID
		create_opts.client_id = EosCredentials.CLIENT_ID
		create_opts.client_secret = EosCredentials.CLIENT_SECRET
		create_opts.encryption_key = EosCredentials.ENCRYPTION_KEY
	
		var _create_results = 0
		_create_results = EOS.Platform.PlatformInterface.create(create_opts)
		print("EOS Platform created")
		display.text = "Waiting"
	
		# Setup Logs from EOS
		EOS.get_instance().logging_interface_callback.connect(_on_logging_interface_callback)
		var res := EOS.Logging.set_log_level(EOS.Logging.LogCategory.AllCategories, EOS.Logging.LogLevel.Info)
		if res != EOS.Result.Success:
			print("Failed to set log level: ", EOS.result_str(res))
			display.text = "Failed to set log level: " + EOS.result_str(res)
	
		EOS.get_instance().connect_interface_login_callback.connect(_on_connect_login_callback)
	
		peer.peer_connected.connect(_on_peer_connected)
		peer.peer_disconnected.connect(_on_peer_disconnected)
	
		await HAuth.login_anonymous_async("User")
		EosCredentials.EosSetup = true
		back_button.visible = true
	else:
		peer.peer_connected.connect(_on_peer_connected)
		peer.peer_disconnected.connect(_on_peer_disconnected)
		findMatch()
		back_button.visible = true
	
func _on_logging_interface_callback(msg) -> void:
	msg = EOS.Logging.LogMessage.from(msg) as EOS.Logging.LogMessage
	print("SDK %s | %s" % [msg.category, msg.message])
	
func exit_game():
	if peer:
		peer.close()
	
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer = null
	if is_server and local_lobby:
		await local_lobby.destroy_async()
	elif local_lobby:
		await local_lobby.leave_async()
	
func _exit_tree() -> void:
	exit_game()
		
func findMatch():
	display.text = "Successful login"
	await get_tree().create_timer(1.0).timeout
	if not await search_lobbies():
		display.text = "Trying again"
		await get_tree().create_timer(randf_range(0.1, 3)).timeout
		if not await search_lobbies():
			display.text = "Making game"
			await get_tree().create_timer(0.5).timeout
			create_lobby()

func _on_connect_login_callback(data: Dictionary) -> void:
	if not data.success:
		print("Login failed")
		EOS.print_result(data)
		display.text = "Login failed"
		return
	print_rich("[b]Login successfull[/b]: local_user_id=", data.local_user_id)
	local_user_id = data.local_user_id
	HAuth.product_user_id = local_user_id
	findMatch()
	
#LOBBY CREATION CODE
#-----------------------------------#
func create_lobby():
	var create_opts := EOS.Lobby.CreateLobbyOptions.new()
	create_opts.bucket_id = "Fight_Poker"
	create_opts.max_lobby_members = 2

	var new_lobby = await HLobbies.create_lobby_async(create_opts)
	if new_lobby == null:
		display.text = "Lobby creation failed"
		return
	
	# Start listening for P2P
	var result := peer.create_server("cdfightpoker")
	if result != OK:
		printerr("Failed to create client: " + EOS.result_str(result))
		return
	multiplayer.multiplayer_peer = peer
	display.text = "Waiting for another player"
	$Timer.start()
	is_server = true
	$CanvasLayer/Temp.visible = false;
	
	local_lobby = new_lobby

#LOBBY JOIN CODE
#---------------------------------------#
func search_lobbies() -> bool:
	# Search for public lobbies
	var lobbies = await HLobbies.search_by_bucket_id_async("Fight_Poker")
	if not lobbies:
		printerr("No lobbies found")
		display.text = "No lobbies found"
		return false

	# Join a lobby
	var lobby: HLobby = lobbies[0]
	await HLobbies.join_by_id_async(lobby.lobby_id)
	
	var result := peer.create_client("cdfightpoker", lobby.owner_product_user_id)
	if result != OK:
		printerr("Failed to create client: " + EOS.result_str(result))
		return false
	multiplayer.multiplayer_peer = peer
	$CanvasLayer/Temp.visible = false
	display.text = "Found lobby"
	return true
	
func lock_lobby():
	if is_server and local_lobby:
		local_lobby.permission_level = EOS.Lobby.LobbyPermissionLevel.InviteOnly
		var success = await local_lobby.update_async()
		if success:
			print("Lobby locked (hidden from search)")
		else:
			print("Failed to lock lobby")
	
#GAME CODE
#-----------------------------------#
func _on_peer_connected(peer_id: int) -> void:
	display.text = "Player %d connected" % peer_id
	print("Player %d connected" % peer_id)
	lock_lobby()
	peer_user_id = peer_id
	$Timer.stop()
	await get_tree().create_timer(1.5).timeout
	start_game()

func _on_peer_disconnected(peer_id: int) -> void:
	display.text = "Player %d disconnected" % peer_id
	print("Player %d disconnected" % peer_id)
	exit_game()

@rpc("any_peer", "call_local", "reliable")
func start_game() -> void:
	print("Game Started\n-------------")
	var game_instance = game_scene.instantiate()
	game_instance.set("IsServer", is_server)
	game_instance.set("PlayerName", DataSave.data.playerName)
	get_tree().current_scene.add_child(game_instance)
	$CanvasLayer.visible = false

func _on_timer_timeout() -> void:
	$CanvasLayer/Temp.visible = true

func _on_bot_game_pressed() -> void:
	get_tree().change_scene_to_file("res://Scenes/direct_to_bot.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://Scenes/main_menu.tscn")
