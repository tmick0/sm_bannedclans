#include <sourcemod>
#include <autoexecconfig>
#include <adt_trie>
#include <cstrike>

#pragma newdecls required

public Plugin myinfo =
{
    name = "Clan tag ban manager",
    author = "tmick0",
    description = "Allows moderation of clan tags which are disallowed in the server",
    version = "0.1",
    url = "github.com/tmick0/sm_bannedclans"
};

#define LINE_MAX 128

#define KICK_MESSAGE "The clan tag you are displaying has been deemed inappropriate for this server. Please change it before reconnecting."
#define BAN_MESSAGE "You have displayed a clan tag which was deemed inappropriate for this server."

#define CMD_GETCLANID "sm_getclanid"

#define CVAR_ENABLE "sm_bannedclans_enable"
#define CVAR_FILE "sm_bannedclans_file"
#define CVAR_MAXWARNINGS "sm_bannedclans_maxwarnings"
#define CVAR_BANDURATION "sm_bannedclans_banduration"
#define CVAR_DBCONFIG "sm_bannedclans_dbconfig"

#define ACTION_KICK 1
#define ACTION_BAN 2

ConVar CvarEnable;
ConVar CvarFile;
ConVar CvarMaxWarnings;
ConVar CvarBanDuration;
ConVar CvarDbConfig;

int Enabled;
StringMap Actions;
int MaxWarnings;
int BanDuration;
Database Db;
char DbType[8];

public void OnPluginStart() {
    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_bannedclans");
    CvarEnable = AutoExecConfig_CreateConVar(CVAR_ENABLE, "0", "1 to enable, 0 to disable");
    CvarFile = AutoExecConfig_CreateConVar(CVAR_FILE, "", "path to file containing rules for clan ids");
    CvarMaxWarnings = AutoExecConfig_CreateConVar(CVAR_MAXWARNINGS, "1", "number of kicks a user can receive before action being escalated to a ban");
    CvarBanDuration = AutoExecConfig_CreateConVar(CVAR_BANDURATION, "60", "duration of bans in minutes (0 for permanent)");
    CvarDbConfig = AutoExecConfig_CreateConVar(CVAR_DBCONFIG, "default", "sourcemod database config profile to use");
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    HookConVarChange(CvarEnable, CvarsUpdated);
    HookConVarChange(CvarFile, CvarsUpdated);
    HookConVarChange(CvarMaxWarnings, CvarsUpdated);
    HookConVarChange(CvarBanDuration, CvarsUpdated);
    HookConVarChange(CvarDbConfig, CvarsUpdated);

    RegAdminCmd(CMD_GETCLANID, CmdGetClanId, ADMFLAG_GENERIC, "return information pertaining to the currently displayed clan tag of the targeted user");

    LoadConfig();
}

void CvarsUpdated(ConVar convar, const char[] oldvalue, const char[] newvalue) {
    LoadConfig();
}

void LoadConfig() {
    Enabled = GetConVarInt(CvarEnable);
    if (!Enabled) {
        return;
    }

    MaxWarnings = GetConVarInt(CvarMaxWarnings);
    BanDuration = GetConVarInt(CvarBanDuration);

    InitDbConnection();

    Actions = CreateTrie();

    char path[PLATFORM_MAX_PATH];
    GetConVarString(CvarFile, path, PLATFORM_MAX_PATH);
    if (strlen(path) == 0) {
        LogMessage("no bannedclans config file specified");
        return;
    }

    Handle fh = OpenFile(path, "r");
    if (fh == INVALID_HANDLE) {
        LogMessage("failed to open bannedclans config file");
        return;
    }

    int count = 0;
    char line[LINE_MAX];
    while (ReadFileLine(fh, line, LINE_MAX)) {
        TrimString(line);
        if (strlen(line) > 0 && line[0] != '#') {
            char parts[2][LINE_MAX];
            if (ExplodeString(line, " ", parts, 2, LINE_MAX) == 2) {
                int tag;
                if (StringToIntEx(parts[1], tag) != strlen(parts[1])) {
                    LogMessage("could not parse group id <%s> in bannedclans config file", parts[1]);
                }
                else if (StrEqual("ban", parts[0], false)) {
                    Actions.SetValue(parts[1], ACTION_BAN);
                    ++count;
                }
                else if (StrEqual("kick", parts[0], false)) {
                    Actions.SetValue(parts[1], ACTION_KICK);
                    ++count;
                }
                else {
                    LogMessage("ignoring unknown directive <%s> in bannedclans config file", parts[0]);
                }
            }
            else {
                LogMessage("ignoring malformed line in bannedclans config file: <%s>", line);
            }
        }
    }

    LogMessage("loaded %d entries from bannedclans config file <%s>", count, path);
}

void InitDbConnection() {
    char config[512];
    GetConVarString(CvarDbConfig, config, sizeof(config));

    char err[512];
    Db = SQL_Connect(config, true, err, sizeof(err));
    if (Db == INVALID_HANDLE) {
        LogMessage("failed to connect to database: %s", err);
        return;
    }

    Db.Driver.GetIdentifier(DbType, sizeof(DbType));

    if (StrEqual(DbType, "sqlite")) {
        SQL_FastQuery(Db, "create table if not exists bannedclans_warnings (steam64 integer primary key, count integer not null default 0);");
    }
    else if (StrEqual(DbType, "mysql")) {
        SQL_FastQuery(Db, "create table if not exists bannedclans_warnings (steam64 bigint primary key, count integer not null default 0);");
    }
    else {
        LogMessage("unsupported database type <%s>", DbType);
        Db = view_as<Database>(INVALID_HANDLE);
    }
}

public void OnClientAuthorized(int client, const char[] auth) {
    if (!Enabled || IsFakeClient(client)) {
        return;
    }
    DoClanIdQuery(client, -1);
}

void DoClanIdQuery(int client, int requester) {
    if (QueryClientConVar(client, "cl_clanid", OnClientClanId, requester) == QUERYCOOKIE_FAILED) {
        LogMessage("failed to query cl_clanid for client %d", client);
        if (requester != -1) {
            ReplyToCommand(requester, "failed to query cl_clanid for client %d", client);
        }
    }
}

void OnClientClanId(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, int requester) {
    if (result != ConVarQuery_Okay) {
        LogMessage("query for cl_clanid for client %d failed", client);
        if (requester != -1) {
            ReplyToCommand(requester, "query for cl_clanid for client %d failed", client);
        }
        return;
    }

    // we are handling a lookup command
    if (requester != -1) {
        char clantag[LINE_MAX];
        char steamid[LINE_MAX];
        GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid));
        CS_GetClientClanTag(client, clantag, LINE_MAX);
        ReplyToCommand(requester, "client %d: steamid <%s> clanid <%s> clantag <%s>", client, steamid, cvarValue, clantag);
    }

    // we are handling a the query on connect
    else {
        char steam64[24];
        if (!GetClientAuthId(client, AuthId_SteamID64, steam64, sizeof(steam64))) {
            LogMessage("failed to get steamid64 for client %d", client);
            return;
        }
        CheckUserClanTag(client, steam64, cvarValue);
    }   
}

Action CmdGetClanId(int client, int argc) {
    if (argc != 1) {
        ReplyToCommand(client, "Usage: %s <target>", CMD_GETCLANID);
        return Plugin_Handled;
    }

    char target[LINE_MAX];
    GetCmdArg(1, target, LINE_MAX);
    
    int tid = FindTarget(client, target, true, false);
    if (tid < 0) {
        ReplyToCommand(client, "invalid target <%s>", target);
        return Plugin_Handled;
    }

    DoClanIdQuery(tid, client);

    return Plugin_Handled;
}

void HandleWarningCountRetrieved(Database db, any client, int queries, DBResultSet[] res, any[] data) {
    if (queries != 2) {
        LogMessage("failed to retrieve warning count for client %d (unknown error)", client);
        return;
    }

    if (!res[1].FetchRow()) {
        LogMessage("failed to retrieve warning count for client %d (unknown error)", client);
        return;
    }

    int warncount = res[1].FetchInt(0);

    if (warncount > MaxWarnings) {
        HandleBanAction(client);
    }
    else {
        KickClient(client, KICK_MESSAGE);
    }

}

void HandleWarningCountFailed(Database db, any client, int queries, const char[] err, int failidx, any[] data) {
    LogMessage("failed to retrieve warning count for client %d: %s", client, err);
}

void HandleKickAction(int client, const char[] steam64) {
    Transaction tx = SQL_CreateTransaction();

    char query[1024];
    if (StrEqual(DbType, "sqlite")) {
        Db.Format(query, sizeof(query), "insert into bannedclans_warnings (steam64, count) values (%s, 1) on conflict(steam64) do update set count = count + 1", steam64);
    }
    else if (StrEqual(DbType, "mysql")) {
        Db.Format(query, sizeof(query), "insert into bannedclans_warnings (steam64, count) values (%s, 1) on duplicate key update count = count + 1", steam64);
    }
    tx.AddQuery(query);

    Db.Format(query, sizeof(query), "select count from bannedclans_warnings where steam64 = %s", steam64);
    tx.AddQuery(query);

    Db.Execute(tx, HandleWarningCountRetrieved, HandleWarningCountFailed, client);
}

void HandleBanAction(int client) {
    BanClient(client, BanDuration, BANFLAG_AUTO, BAN_MESSAGE, BAN_MESSAGE, "sm_bannedclans");
}

void CheckUserClanTag(int client, const char[] steam64, const char[] cvarValue) {
    int action;
    if (Actions.GetValue(cvarValue, action)) {
        if (action == ACTION_KICK) {
            HandleKickAction(client, steam64);
        }
        else if (action == ACTION_BAN) {
            HandleBanAction(client);
        }
    }
}
