/*
- Changelog:
v1.5
    - Plugin rewrite
    - Use Database.Format, no longer needed manual escaping

v1.4
    - Added lprank_announce_playtime to display a message when a player joins
    - Update translations
    - Plugin now requires colors include
    - Fix Wipe command, now doesn't wipe play time

v1.3
    - You can now see players stats from the top10 menu
    - Update translations

v1.2
    - Plugin now tracks playtime
    - Update translations

v1.1
    - Escape names with single quotes '\''

v1.0
    - First release
*/

#include <sourcemod>
#include <dbi>
#include <left4dhooks>
#include <colors>

#define WIPE_PASSWORD ""
#define HITGROUP_HEAD 1

//
// Database
//
Database rankDB;
int Top10Score[10] = { 0 };
char Top10Names[10][MAX_NAME_LENGTH];
char Top10SteamID[10][64];
//

//
// Player stats
//
enum struct Stats
{
    int CIKills;
    int SIKills;
    int Headshots;
    int HeadshotDamage;
    int PlayTime;
    int JoinTime;
    int InitialScore;
    char SteamID[32];
    bool AllowedToSave;
}
Stats PlayerStats[MAXPLAYERS + 1];


enum struct SIKills
{
    int Kills[9];
    int Damage[9];
}
enum SIArrayType
{
    KillsType = 1,
    DamageType
}
SIKills PlayerSIStats[MAXPLAYERS + 1];


//
ConVar cCommonInfectedMult, cSpecialInfectedMult, cHeadshotMult, cHeadshotDamageQuotient;
float fCommonInfectedMult, fSpecialInfectedMult, fHeadshotMult, fHeadshotDamageQuotient;
ConVar cAnnouncePlayTime;
bool bAnnouncePlayTime;
//

public Plugin myinfo =
{
    name = "[L4D2] Simple rank system",
    author = "liquidplasma",
    description = "Simple rank system with top10",
    version = "1.5",
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion L4D2Only = GetEngineVersion();
    if (L4D2Only != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Plugin only supports L4D2");
        return APLRes_Failure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    if (InitDB())
        LogMessage("Connected to SQLite successfully");

    LoadTranslations("l4d2_lp_simple_rank.phrases");
    cCommonInfectedMult =       CreateConVar("lprank_common_mult", "0.2", "Multiplier for the scoring system from common infected kills");
    cSpecialInfectedMult =      CreateConVar("lprank_special_mult", "3.0", "Multiplier for the scoring system from special infected kills");
    cHeadshotMult =             CreateConVar("lprank_headshot_mult", "10.0", "Multiplier for the scoring system for headshots");
    cHeadshotDamageQuotient =   CreateConVar("lprank_headshotdamage_quotient", "1000.0", "Quotient for the scoring system for headshot damage");
    cAnnouncePlayTime =         CreateConVar("lprank_announce_playtime", "0", "Shows a message relaying playtime to a joining player (0 - disabled / 1 - enabled)");

    cCommonInfectedMult.AddChangeHook(ChangedConvar);
    cSpecialInfectedMult.AddChangeHook(ChangedConvar);
    cHeadshotMult.AddChangeHook(ChangedConvar);
    cHeadshotDamageQuotient.AddChangeHook(ChangedConvar);
    cAnnouncePlayTime.AddChangeHook(ChangedConvar);
    AutoExecConfig(true, "l4d2_lp_simple_rank");

    HookEvent("player_death", PlayerDeathEvent, EventHookMode_Post);
    HookEvent("player_hurt", PlayerHurtEvent, EventHookMode_Post);
    HookEvent("infected_death", InfectedDeathEvent, EventHookMode_Post);
    HookEvent("map_transition", MapTransition, EventHookMode_PostNoCopy);

    RegConsoleCmd("sm_rank", RankMenu, "Opens simple rank menu");
    RegConsoleCmd("sm_top10", Top10Menu, "Open the top 10 players");
    RegAdminCmd("sm_lp_wipe", WipeDB, ADMFLAG_ROOT, "Wipes the database");
    RegAdminCmd("sm_lp_remove_entry", CleanLowScoresCMD, ADMFLAG_ROOT, "Clean entries with a score lower than this");

    GetCvars();
    GetTop10(0);
}

public bool InitDB()
{
    char error[255];
    rankDB = SQLite_UseDatabase("lp_simple_rank_db", error, sizeof(error));
    if (rankDB == INVALID_HANDLE)
    {
        SetFailState(error);
        return false;
    }
    SQL_FastQuery(rankDB, "CREATE TABLE IF NOT EXISTS lp_simple_rank (steamid TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, CIKills INTEGER, SIKills INTEGER, Headshots INTEGER, HeadshotDamage INT, Score INT);");
    SQL_FastQuery(rankDB, "CREATE TABLE IF NOT EXISTS lp_simple_rank_sikills (id INTEGER PRIMARY KEY AUTOINCREMENT, steamid TEXT NOT NULL, array_type INTEGER, zombie_class INTEGER, value INTEGER, FOREIGN KEY(steamid) REFERENCES lp_simple_rank(steamid));");
    SQL_FastQuery(rankDB, "CREATE INDEX IF NOT EXISTS idx_steamid ON lp_simple_rank_sikills(steamid);");
    SQL_FastQuery(rankDB, "CREATE INDEX IF NOT EXISTS idx_steamid_arraytype ON lp_simple_rank_sikills(steamid, array_type);");
    //CheckForColumn("PlayTime", "INTEGER DEFAULT 0");
    return true;
}

public void ChangedConvar(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

void GetCvars()
{
    fCommonInfectedMult = cCommonInfectedMult.FloatValue;
    fSpecialInfectedMult = cSpecialInfectedMult.FloatValue;
    fHeadshotMult = cHeadshotMult.FloatValue;
    fHeadshotDamageQuotient = cHeadshotDamageQuotient.FloatValue;
    bAnnouncePlayTime = cAnnouncePlayTime.BoolValue;
}

public void OnMapStart()
{
    CreateTimer(5.0, SetPlayerNum, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action SetPlayerNum(Handle timer, any data)
{
    char query[128];
    rankDB.Format(query, sizeof(query), "SELECT COUNT(*) FROM lp_simple_rank WHERE steamid IS NOT NULL;");
    SQL_TQuery(rankDB, PlayerCountCallback, query);
    return Plugin_Continue;
}

void PlayerCountCallback(Handle db, Handle query, const char[] error, any data)
{
    if (!StrEqual(error, ""))
    {
        LogError("SQL error in PlayerCountCallback: %s", error);
        return;
    }

    if (!SQL_HasResultSet(query))
        return;

    if (SQL_FetchRow(query))
    {
        int count = SQL_FetchInt(query, 0);
        //LogMessage("Count is %i", count);
        if (count > 0)
            GameRules_SetProp("m_iServerPlayerCount", count);
    }
}

//
// Table
//

// Check if a column exists, if not create it
/*public void CheckForColumn(const char[] columnName, const char[] columnDataType)
{
    strcopy(ColumnName, sizeof(ColumnName), columnName)
    strcopy(ColumnDataType, sizeof(ColumnDataType), columnDataType);
    char query[64];
    rankDB.Format(query, sizeof(query), "PRAGMA table_info(lp_simple_rank);");
    SQL_TQuery(rankDB, AddColumn, query);
}

void AddColumn(Handle db, Handle query, const char[] error, any data)
{
    if (StrEqual(error, ""))
    {
        char colName[64];
        bool columnExists = false;
        while (SQL_FetchRow(query))
        {
            SQL_FetchString(query, 1, colName, sizeof(colName));
            if (StrEqual(colName, ColumnName))
            {
                columnExists = true;
                break;
            }
        }

        if (!columnExists)
        {
            char fastQuery[96];
            rankDB.Format(fastQuery, sizeof(fastQuery), "ALTER TABLE lp_simple_rank ADD COLUMN %s %s;", ColumnName, ColumnDataType);
            LogMessage("Added column %s successfully", ColumnName);
            SQL_FastQuery(rankDB, fastQuery);
        }
    }
    else
        LogError("SQL Error in AddColumn: %s", error);
}*/

// Check if steamid exists and update name if necessary
public void CheckAndUpdateName(int client)
{
    if (!GetClientAuthId(client, AuthId_SteamID64, PlayerStats[client].SteamID, 32))
    {
        LogError("Failed to get %N SteamID64. Ignore saving stats to database", client);
        PlayerStats[client].AllowedToSave = false;
        return;
    }

    PlayerStats[client].AllowedToSave = true;
    char query[256];
    rankDB.Format(query, sizeof(query), "SELECT name FROM lp_simple_rank WHERE steamid = '%s';", PlayerStats[client].SteamID);
    SQL_TQuery(rankDB, CheckNameCallback, query, client);
}

// Callback function to process the query result
public void CheckNameCallback(Handle db, Handle query, const char[] error, any data)
{
    int client = data;
    if (!IsValidClient(client))
        return;

    char oldName[MAX_NAME_LENGTH];
    char newName[MAX_NAME_LENGTH];

    if (StrEqual(error, ""))
    {
        if (SQL_HasResultSet(query) && SQL_FetchRow(query))
        {
            // Fetch existing name
            SQL_FetchString(query, 0, oldName, sizeof(oldName));
            GetClientName(client, newName, sizeof(newName));

            // No longer requires manual escaping
            // Database.Format method already escapes the name if necessary
            if (strcmp(oldName, newName) != 0)
            {
                // Name has changed, update it
                char updateQuery[256];
                rankDB.Format(updateQuery, sizeof(updateQuery), "UPDATE lp_simple_rank SET name = '%s' WHERE steamid = '%s';", newName, PlayerStats[client].SteamID);
                SQL_TQuery(rankDB, SQLErrorCallBack, updateQuery);
            }
        }
        else
        {
            // If steamid does not exist, insert the new record
            GetClientName(client, newName, sizeof(newName));
            char insertQuery[256];
            rankDB.Format(insertQuery, sizeof(insertQuery), "INSERT OR REPLACE INTO lp_simple_rank (steamid, name) VALUES ('%s', '%s')", PlayerStats[client].SteamID, newName);
            SQL_TQuery(rankDB, SQLErrorCallBack, insertQuery);
        }
    }
    else
        LogError("SQL Error in check name callback: %s", error);
}

// Saves a client stats with scoring
public void SaveStats(int client)
{
    if (!PlayerStats[client].AllowedToSave)
        return;

    char query[320], siQuery[320];

    int score = CalculateScore(client);
    int sessionTime = CalculateSessionTime(client);
    rankDB.Format(query, sizeof(query),
            "UPDATE lp_simple_rank SET CIKills = %i, SIKills = %i, Headshots = %i, HeadshotDamage = %i, Score = %i, PlayTime = PlayTime + %i WHERE steamid = '%s'",
            PlayerStats[client].CIKills,
            PlayerStats[client].SIKills,
            PlayerStats[client].Headshots,
            PlayerStats[client].HeadshotDamage,
            score,
            sessionTime,
            PlayerStats[client].SteamID);
    SQL_TQuery(rankDB, SQLErrorCallBack, query);

    for (int array_type = 1; array_type <= 2; array_type++)
    {
        for (int zombie_class = 1; zombie_class <= 8; zombie_class++)
        {
            if (view_as<L4D2ZombieClassType>(zombie_class) == L4D2ZombieClass_Witch) // Ignore witch
                continue;

            int value = (array_type == 1) ? PlayerSIStats[client].Kills[zombie_class] : PlayerSIStats[client].Damage[zombie_class];

            rankDB.Format(siQuery, sizeof(siQuery),
                "INSERT OR REPLACE INTO lp_simple_rank_sikills (steamid, array_type, zombie_class, value) VALUES ('%s', %i, %i, %i);",
                PlayerStats[client].SteamID, array_type, zombie_class, value);

            SQL_FastQuery(rankDB, siQuery);
        }
    }
}

// Loads a client stats
public void LoadStats(int client)
{
    char query[320], siQuery[320];

    rankDB.Format(query, sizeof(query),
           "SELECT CIKills, SIKills, Headshots, HeadshotDamage, PlayTime FROM lp_simple_rank WHERE steamid = '%s';",
           PlayerStats[client].SteamID);
    SQL_TQuery(rankDB, LoadMainStatsCallback, query, client);

    for (int i = 1; i <= 2; i++)
    {
        DataPack pack = new DataPack();
        pack.WriteCell(client);
        pack.WriteCell(i);
        pack.Reset();

        rankDB.Format(siQuery, sizeof(siQuery), "SELECT zombie_class, value FROM lp_simple_rank_sikills WHERE steamid = '%s' AND array_type = '%i' ORDER BY zombie_class;", PlayerStats[client].SteamID, i);
        SQL_TQuery(rankDB, LoadSiKillsCallback, siQuery, pack);
    }

    // Announce message
    if (bAnnouncePlayTime)
        CreateTimer(5.0, PrintPlayTime, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void LoadSiKillsCallback(Handle db, Handle query, const char[] error, DataPack pack)
{
    int client = pack.ReadCell();
    SIArrayType array_type = pack.ReadCell();
    delete pack;

    if (query == null)
    {
        LogError("LoadSiKillsCallback failed: %s", error);
        return;
    }

    while (SQL_FetchRow(query))
    {
        L4D2ZombieClassType zombie_class = view_as<L4D2ZombieClassType>(SQL_FetchInt(query, 0));
        if (zombie_class == L4D2ZombieClass_Witch) // Ignore witch
            continue;

        int value = SQL_FetchInt(query, 1);
        switch (array_type)
        {
            case KillsType:
                PlayerSIStats[client].Kills[zombie_class] = value;
            case DamageType:
                PlayerSIStats[client].Damage[zombie_class] = value;
        }
    }
}

public void LoadMainStatsCallback(Handle db, Handle query, const char[] error, any data)
{
    int client = data;
    if (!IsValidClient(client))
        return;

    if (StrEqual(error, ""))
    {
        if (SQL_HasResultSet(query) && SQL_FetchRow(query))
        {
            // Retrieve values from the result set
            PlayerStats[client].CIKills = SQL_FetchInt(query, 0);
            PlayerStats[client].SIKills = SQL_FetchInt(query, 1);
            PlayerStats[client].Headshots = SQL_FetchInt(query, 2);
            PlayerStats[client].HeadshotDamage = SQL_FetchInt(query, 3);
            PlayerStats[client].PlayTime = SQL_FetchInt(query, 4);
            PlayerStats[client].InitialScore = CalculateScore(client);
        }
        else
        {
            PlayerStats[client].CIKills = 0;
            PlayerStats[client].SIKills = 0;
            PlayerStats[client].Headshots = 0;
            PlayerStats[client].HeadshotDamage = 0;
            PlayerStats[client].PlayTime = 0;
            PlayerStats[client].InitialScore = CalculateScore(client);
        }
    }
    else
    {
        // Handle SQL error
        LogError("SQL Error in load stats callback: %s", error);
    }
}

public Action PrintPlayTime(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client))
        return Plugin_Stop;

    char buffer[256];
    char playerName[MAX_NAME_LENGTH];
    GetClientName(client, playerName, sizeof(playerName));
    FormatPlayTime(client, PlayerStats[client].PlayTime, buffer, sizeof(buffer), playerName, false, true);
    CPrintToChat(client, buffer);
    return Plugin_Continue;
}

// Calculates this clients score
public int CalculateScore(int client)
{
    int commonScore = RoundToNearest(PlayerStats[client].CIKills * fCommonInfectedMult);
    int specialInfectedScore = RoundToNearest(PlayerStats[client].SIKills * fSpecialInfectedMult);
    int headshotScore = RoundToNearest(PlayerStats[client].Headshots * fHeadshotMult);
    int headshotDamageScore = RoundToNearest(PlayerStats[client].HeadshotDamage / fHeadshotDamageQuotient);
    return commonScore + specialInfectedScore + headshotScore + headshotDamageScore;
}

public int CalculateSessionTime(int client)
{
    return GetTime() - PlayerStats[client].JoinTime;
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    CheckAndUpdateName(client);
    PlayerStats[client].JoinTime = GetTime();
    LoadStats(client);
}

public void OnClientDisconnect(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    CheckAndUpdateName(client);
    SaveStats(client);
    PlayerStats[client].CIKills =
    PlayerStats[client].SIKills =
    PlayerStats[client].Headshots =
    PlayerStats[client].HeadshotDamage =
    PlayerStats[client].PlayTime =
    PlayerStats[client].JoinTime = 0;
}

public void SQLErrorCallBack(Handle owner, Handle handle, const char[] error, any data)
{
    if (!StrEqual("", error))
        LogError("SQLite Error in generic error callback: %s", error);
}

///
/// Events
///

public void PlayerDeathEvent(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    bool headshot = event.GetBool("headshot");
    if (!OnSurvivorTeam(attacker) || !OnInfectedTeam(victim) || IsFakeClient(attacker))
        return;

    L4D2ZombieClassType SIClass = L4D2_GetPlayerZombieClass(victim);
    if (SIClass != L4D2ZombieClass_NotInfected)
        PlayerSIStats[attacker].Kills[SIClass]++;

    if (headshot)
        PlayerStats[attacker].Headshots++;
    PlayerStats[attacker].SIKills++;
}

public void PlayerHurtEvent(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int damage = event.GetInt("dmg_health");
    bool headshot = event.GetInt("hitgroup") == HITGROUP_HEAD;
    if (!OnSurvivorTeam(attacker) || !OnInfectedTeam(victim) || IsFakeClient(attacker))
        return;

    L4D2ZombieClassType SIClass = L4D2_GetPlayerZombieClass(victim);
    if (SIClass != L4D2ZombieClass_NotInfected)
    {
        if (SIClass == L4D2ZombieClass_Tank && L4D_IsPlayerIncapacitated(victim))
            return;

        int health = GetClientHealth(victim);
        if (health < 0)
            damage -= -health;

        PlayerSIStats[attacker].Damage[SIClass] += damage;
    }

    if (headshot)
        PlayerStats[attacker].HeadshotDamage += damage;
}

public void InfectedDeathEvent(Event event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int commonID = event.GetInt("infected_id");
    bool headshot = event.GetBool("headshot");
    if (!IsValidClient(attacker) || !IsValidEntity(commonID))
        return;
    if (!OnSurvivorTeam(attacker))
        return;

    PlayerStats[attacker].CIKills++;
    if (headshot)
        PlayerStats[attacker].Headshots++;
}

public void MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    char message[128];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || IsFakeClient(i) || !OnSurvivorTeam(i))
            continue;

        Format(message, sizeof(message), "%T", "SessionScore", i, CalculateScore(i), Math_Abs(CalculateScore(i) - PlayerStats[i].InitialScore));
        CPrintToChat(i, message);
    }
}

///
/// Menus and commands
///

public Action CleanLowScoresCMD(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "Usage: sm_lp_remove_entry <min score>");
        return Plugin_Handled;
    }
    int floor = GetCmdArgInt(args);
    if (floor < 0)
    {
        ReplyToCommand(client, "Argument must be 0 or higher");
        return Plugin_Handled;
    }
    char timeBuffer[32];
    FormatTime(timeBuffer, sizeof(timeBuffer), NULL_STRING, GetTime());
    if (client == 0) // Server console, rcon, etc
    {
        CleanLowScores(floor);
        LogMessage("CONSOLE cleared scores below %i on %s", floor, timeBuffer);
        return Plugin_Handled;
    }
    char steamid[20];
    if (GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        ReplyToCommand(client, "%N [%s] cleared scores below %i on %s", client, steamid, floor, timeBuffer);
        LogMessage("%N [%s] cleared scores below %i on %s", client, steamid, floor, timeBuffer);
        CleanLowScores(floor);
        return Plugin_Handled;
    }
    return Plugin_Handled;
}

public Action WipeDB(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "This action cannot be made from the CONSOLE/Server side");
        return Plugin_Handled;
    }
    if (args < 1)
    {
        ReplyToCommand(client, "Usage: sm_lp_wipe <password defined in plugin source>");
        return Plugin_Handled;
    }
    char cmdBuffer[32];
    GetCmdArgString(cmdBuffer, sizeof(cmdBuffer));
    if (!StrEqual(cmdBuffer, WIPE_PASSWORD))
    {
        ReplyToCommand(client, "Wrond password for database wipe");
        ReplyToCommand(client, "Usage: sm_lp_wipe <password defined in plugin source>");
        return Plugin_Handled;
    }
    char steamid[20];
    if (GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid)))
    {
        char timeBuffer[32];
        FormatTime(timeBuffer, sizeof(timeBuffer), NULL_STRING, GetTime());
        LogMessage("%N [%s] wiped database on %s", client, steamid, timeBuffer);
        WipeDatabase();
        return Plugin_Handled;
    }
    return Plugin_Handled;
}

public Action RankMenu(int client, int args)
{
    if (!client)
        return Plugin_Handled;

    RankMenuDisplay(client);
    return Plugin_Handled;
}

void RankMenuDisplay(int client)
{
    Menu rankMenu = new Menu(RankMenuHandler);
    char menuBuffer[96];
    char playerName[MAX_NAME_LENGTH];
    char formattedPlayTime[128];
    GetClientName(client, playerName, sizeof(playerName));
    FormatPlayTime(client, PlayerStats[client].PlayTime, formattedPlayTime, sizeof(formattedPlayTime), playerName);

    rankMenu.SetTitle(formattedPlayTime);
    rankMenu.AddItem("Spacer", "-====\\====-", ITEMDRAW_RAWLINE);

    int score = CalculateScore(client);
    Format(menuBuffer, sizeof(menuBuffer), "%T", "Score", client, score, Math_Abs(score - PlayerStats[client].InitialScore));
    rankMenu.AddItem("Score", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "CommonKilled", client, PlayerStats[client].CIKills);
    rankMenu.AddItem("CIKills", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "SpecialKilled", client, PlayerStats[client].SIKills);
    rankMenu.AddItem("SIKills", menuBuffer, ITEMDRAW_DEFAULT);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "Headshots", client, PlayerStats[client].Headshots);
    rankMenu.AddItem("Headshots", menuBuffer, ITEMDRAW_DISABLED);

    float headshotsPerKill = float(PlayerStats[client].Headshots) / float((PlayerStats[client].SIKills + PlayerStats[client].CIKills)) * 100.0;
    Format(menuBuffer, sizeof(menuBuffer), "%T", "HeadshotsPerKill", client, headshotsPerKill);
    rankMenu.AddItem("HeadshotsPerKill", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "HeadshotDamage", client, PlayerStats[client].HeadshotDamage);
    rankMenu.AddItem("HeadshotDamage", menuBuffer, ITEMDRAW_DISABLED);

    rankMenu.Display(client, MENU_TIME_FOREVER);
}

public Action Top10Menu(int client, int args)
{
    if (!client)
        return Plugin_Handled;

    GetTop10(client);
    return Plugin_Handled;
}

public int RankMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info))
            if (StrEqual(info, "SIKills"))
                SIStatsMenu(param1);
        }
        case MenuAction_End:
            delete menu;
    }
    return 0;
}

public void SIStatsMenu(int client)
{
    char info[64], infectedName[16], menuBuffer[64];

    Menu siStatsMenu = new Menu(SIStatsMenuHandler);
    siStatsMenu.SetTitle("%T", "SIStatsMenu", client);
    for (int i = 1; i <= 8; i++)
    {
        if (i == 7) // Ignore witch
            continue;

        int arrayIndex = i - 1;
        strcopy(infectedName, sizeof(infectedName), L4D2ZombieClassname[arrayIndex]);
        infectedName[0] = CharToUpper(infectedName[0]);
        strcopy(info, sizeof(info), infectedName);

        Format(menuBuffer, sizeof(menuBuffer), "[%s]: %i | Damage: %i", infectedName, PlayerSIStats[client].Kills[i], PlayerSIStats[client].Damage[i]);
        siStatsMenu.AddItem(info, menuBuffer, ITEMDRAW_DISABLED);
    }
    siStatsMenu.ExitBackButton = true;
    siStatsMenu.Display(client, MENU_TIME_FOREVER);
}

int SIStatsMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Cancel:
        {
            int client = param1;
            int endReason = param2;
            if (endReason == MenuCancel_ExitBack)
                RankMenuDisplay(client);
        }
    }
    return 0;
}

/**
 *  Function to retrieve top10
 */
public void GetTop10(int client)
{
    char query[96];

    rankDB.Format(query, sizeof(query), "SELECT steamid, name, Score FROM lp_simple_rank ORDER BY Score DESC LIMIT 10;");
    SQL_TQuery(rankDB, Top10Callback, query, client);
}

public void Top10Callback(Handle db, Handle query, const char[] error, any data)
{
    int client = data;
    if (StrEqual(error, ""))
    {
        int rank = 0;
        char playerName[MAX_NAME_LENGTH * 2];
        char steamid[64];
        int score;

        while (SQL_FetchRow(query))
        {
            SQL_FetchString(query, 0, steamid, sizeof(steamid));
            SQL_FetchString(query, 1, playerName, sizeof(playerName));
            score = SQL_FetchInt(query, 2);

            strcopy(Top10SteamID[rank], sizeof(steamid), steamid);
            strcopy(Top10Names[rank], MAX_NAME_LENGTH, playerName);
            Top10Score[rank] = score;
            rank++;
        }
        if (IsValidClient(client))
            Top10MenuShow(client);
    }
    else
    {
        LogError("SQL Error in top10 callback: %s", error);
    }
}

/**
 *  Function to create and display the Top 10 menu
 */
public void Top10MenuShow(int client)
{
    char menuBuffer[64];
    char info[64];
    Menu top10Menu = new Menu(Top10MenuHandler);
    top10Menu.SetTitle("     - Top 10 Players -     ");

    for (int i = 0; i < sizeof(Top10Score); i++)
    {
        if (Top10Score[i] != 0)
        {
            Format(menuBuffer, sizeof(menuBuffer), "%s: %i", Top10Names[i], Top10Score[i]);
            Format(info, sizeof(info), "Top10Pos%i", i + 1);
            top10Menu.AddItem(info, menuBuffer, ITEMDRAW_DEFAULT);
        }
    }

    top10Menu.Display(client, MENU_TIME_FOREVER);
}

public int Top10MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int client = param1;
            int selectedPlayer = param2;
            GetRankFromTop10(client, selectedPlayer);
        }
        case MenuAction_End:
            delete menu;
    }
    return 0;
}

public void GetRankFromTop10(int client, int selectedPlayer)
{
    char query[320];
    rankDB.Format(query, sizeof(query), "SELECT name, CIKills, SIKills, Headshots, HeadshotDamage, Score, PlayTime FROM lp_simple_rank WHERE steamid = '%s';", Top10SteamID[selectedPlayer]);
    SQL_TQuery(rankDB, RankTop10PrintMenu, query, client);
}

public void RankTop10PrintMenu(Handle db, Handle query, const char[] error, any data)
{
    int client = data;
    if (StrEqual(error, ""))
    {
        if (SQL_HasResultSet(query) && SQL_FetchRow(query))
        {
            char playerName[MAX_NAME_LENGTH];
            int ciKills = SQL_FetchInt(query, 1);
            int siKills = SQL_FetchInt(query, 2);
            int headshots = SQL_FetchInt(query, 3);
            int headshotDamage = SQL_FetchInt(query, 4);
            int score = SQL_FetchInt(query, 5);
            int playTime = SQL_FetchInt(query, 6);

            SQL_FetchString(query, 0, playerName, sizeof(playerName));
            RankTop10MenuShow(playerName, client, ciKills, siKills, headshots, headshotDamage, score, playTime);
        }
    }
    else
        LogError("SQL Error in RankTop10PrintMenu callback: %s", error);
}

// Show a players stats from the top10 menu
public void RankTop10MenuShow(char[] playerName, int client, int ciKills, int siKills, int headshots, int headshotdamage, int score, int playtime)
{
    Menu rankTop10Choice = new Menu(SpecificPlayerMenu);
    char formattedTime[128];
    char menuBuffer[96];
    FormatPlayTime(client, playtime, formattedTime, sizeof(formattedTime), playerName, true);
    rankTop10Choice.SetTitle(formattedTime);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "Score", client, score, 0);
    rankTop10Choice.AddItem("Score", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "CommonKilled", client, ciKills);
    rankTop10Choice.AddItem("CIKills", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "SpecialKilled", client, siKills);
    rankTop10Choice.AddItem("SIKills", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "Headshots", client, headshots);
    rankTop10Choice.AddItem("Headshots", menuBuffer, ITEMDRAW_DISABLED);

    float headshotsPerKill = float(headshots) / float((siKills + ciKills));
    Format(menuBuffer, sizeof(menuBuffer), "%T", "HeadshotsPerKill", client, headshotsPerKill);
    rankTop10Choice.AddItem("HeadshotsPerKill", menuBuffer, ITEMDRAW_DISABLED);

    Format(menuBuffer, sizeof(menuBuffer), "%T", "HeadshotDamage", client, headshotdamage);
    rankTop10Choice.AddItem("HeadshotDamage", menuBuffer, ITEMDRAW_DISABLED);

    rankTop10Choice.ExitBackButton = true;
    rankTop10Choice.Display(client, MENU_TIME_FOREVER);
}

int SpecificPlayerMenu(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Cancel:
        {
            int client = param1;
            int endReason = param2;
            if (endReason == MenuCancel_ExitBack)
                Top10MenuShow(client);
        }
        case MenuAction_End:
            delete menu;
    }
    return 0;
}

//
// Admins commands
//

public void WipeDatabase()
{
    for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i))
			continue;

        PlayerStats[i].CIKills = PlayerStats[i].SIKills = PlayerStats[i].Headshots = PlayerStats[i].HeadshotDamage = 0;
    }
    char query[136];
    rankDB.Format(query, sizeof(query), "UPDATE lp_simple_rank SET CIKills = 0, SIKills = 0, Headshots = 0, HeadshotDamage = 0, Score = 0 WHERE steamid IS NOT NULL;");
    SQL_TQuery(rankDB, WipeDatabaseCallback, query);
}

public void WipeDatabaseCallback(Handle db, Handle query, const char[] error, any data)
{
    if (StrEqual(error, ""))
    {
        LogMessage("Database wiped successfully.");
    }
    else
    {
        LogError("SQL Error during wipe: %s", error);
    }
}

public void CleanLowScores(int minScore)
{
    char query[96];
    rankDB.Format(query, sizeof(query), "DELETE FROM lp_simple_rank WHERE Score < %d OR Score IS NULL;", minScore);
    SQL_TQuery(rankDB, CleanLowScoresCallback, query);
}

public void CleanLowScoresCallback(Handle db, Handle query, const char[] error, any data)
{
    if (StrEqual(error, ""))
        LogMessage("Low scores have been cleaned from the database.");
    else
        LogError("SQL Error during cleaning: %s", error);
}

//
// Misc methods
//

void FormatPlayTime(int client, int playTime, char[] buffer, int maxlen, char[] playerName, bool top10Menu = false, bool welcomeMessage = false)
{
    int months = playTime / 2592000;
    int days = (playTime % 2592000) / 86400;
    int hours = (playTime % 86400) / 3600;
    int minutes = (playTime % 3600) / 60;

    if (welcomeMessage)
    {
        days = playTime / 86400;
        Format(buffer, maxlen, "%T", "LoginMessage", client, playerName, days, hours, minutes);
        return;
    }

    if (top10Menu)
    {
        Format(buffer, maxlen, "%T", "SeeOtherPlayer", client, playerName, months, days, hours, minutes);
        return;
    }

    if (months > 0)
        Format(buffer, maxlen, "%T", "WelcomeMonths", client, playerName, months, days, hours, minutes);
    else
        Format(buffer, maxlen, "%T", "WelcomeDays", client, playerName, days, hours, minutes);
}

any Math_Abs(any number)
{
	return number >= 0 ? number : (number * -1);
}

stock bool IsValidClient(int client, bool replaycheck = true)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return false;
    if (replaycheck && (IsClientSourceTV(client) || IsClientReplay(client)))
        return false;
    return true;
}

/**
 * Returns if this player is on the infected team
 */
stock bool OnInfectedTeam(int client)
{
    if (!IsValidClient(client))
		return false;

    return L4D_GetClientTeam(client) == L4DTeam_Infected;
}

/**
 * Returns if this player in on the survivor team
 */
stock bool OnSurvivorTeam(int client)
{
    if (!IsValidClient(client))
		return false;

    return L4D_GetClientTeam(client) == L4DTeam_Survivor;
}