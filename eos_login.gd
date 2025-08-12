extends Control

@onready var display = $MessageDisplay
@onready var peer: EOSGMultiplayerPeer = EOSGMultiplayerPeer.new()

@export var game_scene: PackedScene

var local_user_id = ""
var is_server = false
var peer_user_id = 0

func _ready() -> void:
	#Initialize the SDK
	var init_opts = EOS.Platform.InitializeOptions.new()
	init_opts.product_name = EosCredentials.PRODUCT_NAME
	init_opts.product_version = EosCredentials.PRODUCT_ID
	
	var init_results = EOS.Platform.PlatformInterface.initialize(init_opts)
	if init_results != EOS.Result.Success:
		printerr("Failed to initialize EOS SDK: " + EOS.result_str(init_results))
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
	
	var create_results = 0
	var attempt_count = 0
	create_results = EOS.Platform.PlatformInterface.create(create_opts)
	print("EOS Platform created")
	
	# Setup Logs from EOS
	EOS.get_instance().logging_interface_callback.connect(_on_logging_interface_callback)
	var res := EOS.Logging.set_log_level(EOS.Logging.LogCategory.AllCategories, EOS.Logging.LogLevel.Info)
	if res != EOS.Result.Success:
		print("Failed to set log level: ", EOS.result_str(res))
	
	EOS.get_instance().connect_interface_login_callback.connect(_on_connect_login_callback)
	
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	
	_anon_login()
	
func _on_logging_interface_callback(msg) -> void:
	msg = EOS.Logging.LogMessage.from(msg) as EOS.Logging.LogMessage
	print("SDK %s | %s" % [msg.category, msg.message])
	
func _on_connect_login_callback(data: Dictionary) -> void:
	if not data.success:
		print("Login failed")
		EOS.print_result(data)
		display.text = "Login failed"
		return
	print_rich("[b]Login successfull[/b]: local_user_id=", data.local_user_id)
	local_user_id = data.local_user_id
	HAuth.product_user_id = local_user_id
	display.text = "Successful login"
	$Temp.visible = true
	
func _anon_login() -> void:
	# Login using Device ID (no user interaction/credentials required)
	var opts = EOS.Connect.CreateDeviceIdOptions.new()
	opts.device_model = OS.get_name() + " " + OS.get_model_name()
	EOS.Connect.ConnectInterface.create_device_id(opts)
	await EOS.get_instance().connect_interface_create_device_id_callback

	var credentials = EOS.Connect.Credentials.new()
	credentials.token = null
	credentials.type = EOS.ExternalCredentialType.DeviceidAccessToken

	var login_options = EOS.Connect.LoginOptions.new()
	login_options.credentials = credentials
	var user_login_info = EOS.Connect.UserLoginInfo.new()
	user_login_info.display_name = "User"
	login_options.user_login_info = user_login_info
	EOS.Connect.ConnectInterface.login(login_options)
	
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
	display.text = "Created lobby"
	is_server = true
	$Temp.visible = false;

#LOBBY JOIN CODE
#---------------------------------------#
func search_lobbies():
	# Search for public lobbies
	var lobbies = await HLobbies.search_by_bucket_id_async("Fight_Poker")
	if not lobbies:
		printerr("No lobbies found")
		display.text = "No lobbies found"
		return

	# Join a lobby
	var lobby: HLobby = lobbies[0]
	await HLobbies.join_by_id_async(lobby.lobby_id)
	
	var result := peer.create_client("cdfightpoker", lobby.owner_product_user_id)
	if result != OK:
		printerr("Failed to create client: " + EOS.result_str(result))
		return
	multiplayer.multiplayer_peer = peer
	$Temp.visible = false
	display.text = "Found lobby"
	
#GAME CODE
#-----------------------------------#
func _on_peer_connected(peer_id: int) -> void:
	display.text = "Player %d connected" % peer_id
	print("Player %d connected" % peer_id)
	if(is_server):
		$Play.visible = true
		peer_user_id = peer_id

func _on_peer_disconnected(peer_id: int) -> void:
	display.text = "Player %d disconnected" % peer_id
	print("Player %d disconnected" % peer_id)

@rpc("any_peer", "call_local", "reliable")
func start_game() -> void:
	$Play.visible = false
	print("Game Started\n-------------")
	var game_instance = game_scene.instantiate()
	get_tree().current_scene.add_child(game_instance)
	display.hide()

# Example RPC for sending player data to all peers
@rpc("any_peer", "call_remote", "reliable")
func send_player_data(name: String, id: int) -> void:
	var play = GameManager.call("getPlayer")
	
	if not play.has(id):
		play[id] = {
			"Name": name,
			"Id": id,
			"Score": 50
		}

	if is_server:
		for player_id in play.keys():
			var player = play[player_id]
			var player_name = player["Name"]
			var player_id_val = player["Id"]
			send_player_data.rpc(name, id)

func _on_test_pressed() -> void:
	GameManager.call("SendPlayerData", "Thing one", multiplayer.get_unique_id())
	GameManager.call("SendPlayerData", "Thing two", peer_user_id)
	
	await get_tree().process_frame
	start_game.rpc()
