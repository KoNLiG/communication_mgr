#include <sourcemod>
#include <sdktools>
#include <chat-processor>

#pragma semicolon 1
#pragma newdecls required

// Maximum characters length for a console command.
#define MAX_COMMAND_LENGTH 256

// MySQL constants.
#define DATABASE_ENTRY "CommunicationMgr" // Relative to the config specified in databases.cfg
#define DATABASE_TABLE_NAME "communication_mgr" // Table will be created will this name

// MySQL database handle.
Database g_Database;

Player g_Players[MAXPLAYERS + 1];

enum struct Player
{
	// Client value of 'GetSteamAccountID()'
	int account_id;
	
	// Player userid.
	int userid;
	
	// Player slot index.
	int index;
	
	bool is_muted[MAXPLAYERS + 1];
	bool is_gagged[MAXPLAYERS + 1];
	
	//=======================================//
	
	void Init(int client)
	{
		if (!(this.account_id = GetSteamAccountID(client)))
		{
			return;
		}
		
		this.index = client;
		
		this.userid = GetClientUserId(client);
		
		this.FetchCommData();
	}
	
	void Close()
	{
		if (this.account_id)
		{
			SetAllPlayersSilence(this.index, false);
		}
	}
	
	void SetPlayerSilence(int other_client, bool val)
	{
		this.is_muted[other_client] = val;
		this.is_gagged[other_client] = val;
		
		this.ApplyListenOverride(other_client, !val);
	}
	
	void ApplyListenOverride(int other_client, bool listen)
	{
		SetListenOverride(this.index, other_client, listen ? Listen_Yes : Listen_No);
	}
	
	//============[ DB Help Functions ]============//
	
	void FetchCommData()
	{
		char query[128];
		Format(query, sizeof(query), "SELECT * FROM `%s` WHERE `account_id` = '%d' OR `other_account_id` = '%d'", DATABASE_TABLE_NAME, this.account_id, this.account_id);
		g_Database.Query(SQL_FetchComm, query, this.userid);
	}
	
	void UpdateCommData()
	{
		Transaction txn = new Transaction();
		
		char query[256];
		
		for (int current_client = 1; current_client <= MaxClients; current_client++)
		{
			if (!IsClientInGame(current_client) || !g_Players[current_client].account_id)
			{
				continue;
			}
			
			if ((this.is_muted[current_client] || this.is_gagged[current_client]))
			{
				this.GetInsertOrUpdateQuery(current_client, query, sizeof(query));
				
				txn.AddQuery(query);
			}
			
			if (g_Players[current_client].is_muted[this.index] || g_Players[current_client].is_gagged[this.index])
			{
				g_Players[current_client].GetInsertOrUpdateQuery(this.index, query, sizeof(query));
				
				txn.AddQuery(query);
			}
		}
		
		// Execute the transaction. ('txn' handle will be freed)
		g_Database.Execute(txn);
	}
	
	// 'other' represents the player we're working against.
	void GetInsertOrUpdateQuery(int other, char[] buffer, int maxlength)
	{
		Format(buffer, maxlength, "INSERT INTO %s(`account_id`, `other_account_id`, `muted`, `gagged`) VALUES(%d, %d, %d, %d) ON DUPLICATE KEY UPDATE `muted` = %d, `gagged` = %d", 
			DATABASE_TABLE_NAME, 
			this.account_id, 
			g_Players[other].account_id, 
			this.is_muted[other], 
			this.is_gagged[other], 
			this.is_muted[other], 
			this.is_gagged[other]
			);
	}
}

// Used to perform a lateload loop when needed.
bool g_Lateload;

public Plugin myinfo = 
{
	name = "Communication Manager", 
	author = "KoNLiG", 
	description = "Provides a fully user communication managment panel.", 
	version = "1.0.0", 
	url = "https://steamcommunity.com/id/KoNLiG/ || KoNLiG#6417"
};

// Implemented to determine whether the plugin lateloaded.
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_Lateload = late;
	
	return APLRes_Success;
}

public void OnPluginStart()
{
	// Attempt to maintain a database connection.
	Database.Connect(SQL_OnDatabaseConnected, DATABASE_ENTRY);
	
	LoadTranslations("communication_mgr.phrases");
	
	// Load the plugin command from the configuration file.
	LoadCommands();
}

public void OnPluginEnd()
{
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client))
		{
			OnClientDisconnect(current_client);
		}
	}
}

//================================[ Events ]================================//

// Server events.

// Used to filter out chat messages between clients who blocked each other.
public Action CP_OnChatMessageSendPre(int sender, int reciever, char[] flag, char[] buffer, int maxlength)
{
	return g_Players[reciever].is_gagged[sender] ? Plugin_Handled : Plugin_Continue;
}

// Client events.
public void OnClientPutInServer(int client)
{
	g_Players[client].Init(client);
}

public void OnClientDisconnect(int client)
{
	g_Players[client].UpdateCommData();
	g_Players[client].Close();
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && current_client != client)
		{
			g_Players[current_client].SetPlayerSilence(client, false);
		}
	}
}

//================================[ Commands Callbacks ]================================//

Action Command_CommunicationManagement(int client, int argc)
{
	if (!client)
	{
		ReplyToCommand(client, "This command is not available from the server console.");
		return Plugin_Handled;
	}
	
	Menus_CommunicationManagement(client);
	
	return Plugin_Handled;
}

//================================[ Menus ]================================//

void Menus_CommunicationManagement(int client)
{
	Menu menu = new Menu(Handler_CommunicationManagement);
	menu.SetTitle("%T\n ", "MenuTitle", client);
	
	char item_display[64], item_info[11];
	
	Format(item_display, sizeof(item_display), "%T", !HasSilencedAnyPlayer(client) ? "SilenceAll" : "UnSilenceAll", client);
	menu.AddItem("", item_display);
	
	Format(item_display, sizeof(item_display), "%T", !HasSilencedTeammate(client) ? "SilenceTeammates" : "UnSilenceTeammates", client);
	menu.AddItem("", item_display);
	
	Format(item_display, sizeof(item_display), "%T\n \n◾ %T\n ", !HasSilencedEnemy(client) ? "SilenceEnemies" : "UnSilenceEnemies", client, "ListOfPlayers", client, GetClientCount() - 1);
	menu.AddItem("", item_display);
	
	// Iterate through all clients and insert each into the menu.
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && current_client != client)
		{
			// Convert the client userid to a string in order to pass it through his own menu item.
			IntToString(g_Players[current_client].userid, item_info, sizeof(item_info));
			
			FormatEx(item_display, sizeof(item_display), "• %N%s", current_client, GetCommInfoStr(client, current_client));
			menu.AddItem(item_info, item_display);
		}
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

int Handler_CommunicationManagement(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		int client = param1, selected_item = param2;
		
		switch (selected_item)
		{
			case 0:
			{
				bool val = HasSilencedAnyPlayer(client);
				
				int count = SetAllPlayersSilence(client, !val);
				
				if (!count)
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, "NoPlayersFound", client);
				}
				else
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, !val ? "SilencedAllPlayers" : "UnSilencedAllPlayers", client, count);
				}
				
				Menus_CommunicationManagement(client);
			}
			case 1:
			{
				bool val = HasSilencedTeammate(client);
				
				int count = SetTeammatesSilence(client, !val);
				
				if (!count)
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, "NoPlayersFound", client);
				}
				else
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, !val ? "SilencedTeammates" : "UnSilencedTeammates", client, count);
				}
				
				Menus_CommunicationManagement(client);
			}
			case 2:
			{
				bool val = HasSilencedEnemy(client);
				
				int count = SetEnemiesSilence(client, !val);
				
				if (!count)
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, "NoPlayersFound", client);
				}
				else
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, !val ? "SilencedEnemies" : "UnSilencedEnemies", client, count);
				}
				
				Menus_CommunicationManagement(client);
			}
			default:
			{
				// Represents the selected player userid. As a string of-course.
				char item_info[11];
				menu.GetItem(selected_item, item_info, sizeof(item_info));
				
				int other_client = GetClientOfUserId(StringToInt(item_info));
				if (!other_client)
				{
					PrintToChat(client, "%T%T", "MessagesPrefix", client, "PlayerNotAvailable", client);
					return 0;
				}
				
				Menus_PlayerOverview(client, other_client);
			}
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

void Menus_PlayerOverview(int client, int other_client)
{
	Menu menu = new Menu(Handler_PlayerOverview);
	menu.SetTitle("%T\n ", "OverviewMenuTitle", client, other_client);
	
	char item_info[11];
	IntToString(g_Players[other_client].userid, item_info, sizeof(item_info));
	
	menu.AddItem(item_info, g_Players[client].is_muted[other_client] ? "Unmute" : "Mute");
	menu.AddItem("", g_Players[client].is_gagged[other_client] ? "Ungag" : "Gag");
	
	menu.ExitBackButton = true;
	
	FixMenuGap(menu);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

int Handler_PlayerOverview(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			int client = param1, selected_item = param2;
			
			// Represents the selected player userid. As a string of-course.
			char item_info[11];
			menu.GetItem(0, item_info, sizeof(item_info));
			
			int other_client = GetClientOfUserId(StringToInt(item_info));
			if (!other_client)
			{
				PrintToChat(client, "%T%T", "MessagesPrefix", client, "PlayerNotAvailable", client);
				return 0;
			}
			
			switch (selected_item)
			{
				case 0:
				{
					g_Players[client].is_muted[other_client] = !g_Players[client].is_muted[other_client];
					
					g_Players[client].ApplyListenOverride(other_client, !g_Players[client].is_muted[other_client]);
					
					PrintToChat(client, "%T%T", "MessagesPrefix", client, g_Players[client].is_muted[other_client] ? "PlayerMuted" : "PlayerUnmuted", client, other_client);
				}
				case 1:
				{
					g_Players[client].is_gagged[other_client] = !g_Players[client].is_gagged[other_client];
					
					PrintToChat(client, "%T%T", "MessagesPrefix", client, g_Players[client].is_gagged[other_client] ? "PlayerGagged" : "PlayerUngagged", client, other_client);
				}
			}
			
			Menus_PlayerOverview(client, other_client);
		}
		
		case MenuAction_Cancel:
		{
			int client = param1, cancel_reason = param2;
			
			if (cancel_reason == MenuCancel_ExitBack)
			{
				Menus_CommunicationManagement(client);
			}
		}
		
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

//================================[ Database ]================================//

void SQL_OnDatabaseConnected(Database db, const char[] error, any data)
{
	if (!(g_Database = db))
	{
		SetFailState("Unable to maintain a database connection. (Error: %s)", error);
	}
	
	char query[256];
	Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS `%s`(`account_id` INT NOT NULL, `other_account_id` INT NOT NULL, `muted` INT(1) NOT NULL, `gagged` INT(1) NOT NULL, PRIMARY KEY(`account_id`, `other_account_id`))", DATABASE_TABLE_NAME);
	g_Database.Query(SQL_EmptyCallback, query);
	
	if (g_Lateload)
	{
		for (int current_client = 1; current_client <= MaxClients; current_client++)
		{
			if (IsClientInGame(current_client))
			{
				OnClientPutInServer(current_client);
			}
		}
	}
}

void SQL_FetchComm(Database db, DBResultSet results, const char[] error, int userid)
{
	// An error has occurred
	if (!db || !results || error[0])
	{
		ThrowError("[SQL_FetchComm] Databse error, %s", error);
		return;
	}
	
	// Initialize the client index by the given userid, and perform validation.
	int client = GetClientOfUserId(userid);
	if (!client)
	{
		return;
	}
	
	int other_client;
	while (results.FetchRow())
	{
		if (!(other_client = GetClientOfAccountID(results.FetchInt(1))))
		{
			continue;
		}
		
		if (client != other_client)
		{
			g_Players[client].is_muted[other_client] = (results.FetchInt(2) != 0);
			g_Players[client].is_gagged[other_client] = (results.FetchInt(3) != 0);
		}
		else if ((other_client = GetClientOfAccountID(results.FetchInt(0))))
		{
			g_Players[other_client].is_muted[client] = (results.FetchInt(2) != 0);
			g_Players[other_client].is_gagged[client] = (results.FetchInt(3) != 0);
		}
	}
}

void SQL_EmptyCallback(Database db, DBResultSet results, const char[] error, any data)
{
	// An error has occurred
	if (!db || !results || error[0])
	{
		ThrowError("[SQL_EmptyCallback] General databse error (Error: %s)", error);
	}
}

//================================[ Functions ]================================//

int GetClientOfAccountID(int account_id)
{
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && g_Players[current_client].account_id == account_id)
		{
			return current_client;
		}
	}
	
	return 0;
}

bool HasSilencedAnyPlayer(int client)
{
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && (g_Players[client].is_muted[current_client] || g_Players[client].is_gagged[current_client]))
		{
			return true;
		}
	}
	
	return false;
}

bool HasSilencedTeammate(int client)
{
	int client_team = GetClientTeam(client);
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && client_team == GetClientTeam(current_client) && 
			(g_Players[client].is_muted[current_client] || g_Players[client].is_gagged[current_client]))
		{
			return true;
		}
	}
	
	return false;
}

bool HasSilencedEnemy(int client)
{
	int client_team = GetClientTeam(client);
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && client_team != GetClientTeam(current_client) && 
			(g_Players[client].is_muted[current_client] || g_Players[client].is_gagged[current_client]))
		{
			return true;
		}
	}
	
	return false;
}

int SetAllPlayersSilence(int client, bool val)
{
	int count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && current_client != client)
		{
			g_Players[client].SetPlayerSilence(current_client, val);
			
			count++;
		}
	}
	
	return count;
}

int SetTeammatesSilence(int client, bool val)
{
	int client_team = GetClientTeam(client), count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && current_client != client && client_team == GetClientTeam(current_client))
		{
			g_Players[client].SetPlayerSilence(current_client, val);
			
			count++;
		}
	}
	
	return count;
}

int SetEnemiesSilence(int client, bool val)
{
	int client_team = GetClientTeam(client), count;
	
	for (int current_client = 1; current_client <= MaxClients; current_client++)
	{
		if (IsClientInGame(current_client) && current_client != client && client_team != GetClientTeam(current_client))
		{
			g_Players[client].SetPlayerSilence(current_client, val);
			
			count++;
		}
	}
	
	return count;
}

char[] GetCommInfoStr(int client, int other_client)
{
	char info[32];
	
	if (!g_Players[client].is_muted[other_client] && !g_Players[client].is_gagged[other_client])
	{
		return info;
	}
	
	Format(info, sizeof(info), " [%T]", 
		g_Players[client].is_muted[other_client] && g_Players[client].is_gagged[other_client] ? "Silenced" : 
		g_Players[client].is_muted[other_client] ? "Muted" : 
		g_Players[client].is_gagged[other_client] ? "Gagged" : "", client);
	
	return info;
}

void FixMenuGap(Menu menu)
{
	int max = (6 - menu.ItemCount);
	for (int i; i < max; i++)
	{
		menu.AddItem("", "", ITEMDRAW_NOTEXT);
	}
}

void LoadCommands()
{
	// Build the config file path.
	char file_path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, file_path, sizeof(file_path), "configs/cm_commands.cfg");
	
	// Make sure the config file is exists.
	if (!FileExists(file_path))
	{
		SetFailState("Unable to locate file '%s'", file_path);
	}
	
	// Read line by line the config file.
	File file = OpenFile(file_path, "r");
	
	char cmd[MAX_COMMAND_LENGTH];
	while (file.ReadLine(cmd, sizeof(cmd)))
	{
		// Extra security.
		TrimString(cmd);
		
		// Register the command.
		RegConsoleCmd(cmd, Command_CommunicationManagement, "Access the communication management menu.");
	}
	
	delete file;
}

//================================================================//