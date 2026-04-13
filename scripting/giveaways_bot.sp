#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#include <giveaways>
#include <ripext>

#define PLUGIN_VERSION "1.2.0"
#define PRIZE_MAX 127
#define INVENTORY_FILE "data/giveaways_bot_inventory.json"

bool g_bBotInitiated;
bool g_bHttpInProgress;

ConVar g_cvApiBase;
ConVar g_cvApiSecret;
ConVar g_cvBotProfileUrl;

ArrayList g_PrizeStrings;

public Plugin myinfo = {
  name = "Giveaways — Steam bot bridge",
  author = "vidya-steam-bot",
  description = "Inventory menu + delivery recording for vidya-steam-bot",
  version = PLUGIN_VERSION,
  url = "https://github.com/vidyagaemstf2/giveaways-bot"
};

public void OnPluginStart() {
  LoadTranslations("common.phrases");

  g_cvApiBase = CreateConVar(
    "sm_giveaways_bot_api_base",
    "http://127.0.0.1:3000",
    "Base URL of the Steam bot HTTP API (no trailing slash). Paths /inventory, /delivery/record are appended automatically."
  );
  g_cvApiSecret = CreateConVar(
    "sm_giveaways_bot_api_secret",
    "",
    "Same value as the bot's API_SECRET (sent as X-Bot-Secret).",
    FCVAR_PROTECTED
  );
  g_cvBotProfileUrl = CreateConVar(
    "sm_giveaways_bot_profile_url",
    "https://steamcommunity.com/id/your-bot",
    "Steam profile/community URL shown to giveaway winners."
  );

  AutoExecConfig(true, "giveaways_bot", "sourcemod");

  g_PrizeStrings = new ArrayList(ByteCountToCells(PRIZE_MAX + 1));
}

void TrimTrailingSlash(char[] s) {
  int len = strlen(s);
  while (len > 0 && s[len - 1] == '/') {
    s[len - 1] = '\0';
    len--;
  }
}

void FormatApiUrl(const char[] path, char[] out, int maxlen) {
  char base[512];
  g_cvApiBase.GetString(base, sizeof(base));
  TrimTrailingSlash(base);
  if (base[0] == '\0') {
    out[0] = '\0';
    return;
  }
  Format(out, maxlen, "%s%s", base, path);
}

public void OnPluginEnd() {
  delete g_PrizeStrings;
}

public Action Giveaways_OnGiveawayStart(int client, const char[] prize) {
  if (g_bBotInitiated) {
    g_bBotInitiated = false;
    return Plugin_Continue;
  }

  if (prize[0] != '\0') {
    return Plugin_Continue;
  }

  if (g_bHttpInProgress) {
    PrintToChat(client, "[Giveaways] Inventory request already in progress.");
    return Plugin_Handled;
  }

  char secret[256];
  g_cvApiSecret.GetString(secret, sizeof(secret));
  if (secret[0] == '\0') {
    PrintToChat(client, "[Giveaways] sm_giveaways_bot_api_secret is not set.");
    return Plugin_Handled;
  }

  char url[512];
  FormatApiUrl("/inventory?minimal=1", url, sizeof(url));
  if (url[0] == '\0') {
    PrintToChat(client, "[Giveaways] sm_giveaways_bot_api_base is not set.");
    return Plugin_Handled;
  }

  g_bHttpInProgress = true;

  char path[PLATFORM_MAX_PATH];
  BuildPath(Path_SM, path, sizeof(path), INVENTORY_FILE);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.DownloadFile(path, OnInventoryFile, GetClientUserId(client));

  return Plugin_Handled;
}

void OnInventoryFile(HTTPStatus status, any userid, const char[] error) {
  g_bHttpInProgress = false;

  int client = GetClientOfUserId(userid);
  if (!client || !IsClientInGame(client)) {
    return;
  }

  if (status != HTTPStatus_OK) {
    if (error[0] != '\0') {
      PrintToChat(client, "[Giveaways] HTTP %d — %s", status, error);
    } else {
      PrintToChat(client, "[Giveaways] Bot returned HTTP %d.", status);
    }
    return;
  }

  char path[PLATFORM_MAX_PATH];
  BuildPath(Path_SM, path, sizeof(path), INVENTORY_FILE);

  JSONArray arr = JSONArray.FromFile(path);
  DeleteFile(path);

  if (arr == null) {
    if (error[0] != '\0') {
      LogError("[giveaways_bot] Inventory parse failed (transport: %s)", error);
    }
    PrintToChat(client, "[Giveaways] Failed to read bot inventory.");
    return;
  }

  int len = arr.Length;
  if (len == 0) {
    delete arr;
    PrintToChat(client, "[Giveaways] Bot inventory is empty.");
    return;
  }

  g_PrizeStrings.Clear();

  for (int i = 0; i < len; i++) {
    JSON el = arr.Get(i);
    if (el == null || !IsValidHandle(el)) {
      continue;
    }
    JSONObject obj = view_as<JSONObject>(el);

    char name[256];
    char assetId[128];
    if (!obj.GetString("name", name, sizeof(name))) {
      strcopy(name, sizeof(name), "Unknown item");
    }
    if (!obj.GetString("assetId", assetId, sizeof(assetId))) {
      delete el;
      continue;
    }

    SanitizeQuotes(name, sizeof(name));

    char prize[192];
    FormatPrizeString(name, assetId, prize, sizeof(prize));
    g_PrizeStrings.PushString(prize);
  }

  delete arr;

  if (g_PrizeStrings.Length == 0) {
    PrintToChat(client, "[Giveaways] No usable items in bot inventory.");
    return;
  }

  Menu menu = new Menu(MenuHandler_Inventory);
  menu.SetTitle("Select a prize (bot inventory)");

  char disp[64];
  char idx[8];
  for (int i = 0; i < g_PrizeStrings.Length; i++) {
    char prize[192];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    SplitPrizeForDisplay(prize, disp, sizeof(disp));
    IntToString(i, idx, sizeof(idx));
    menu.AddItem(idx, disp);
  }

  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

void SanitizeQuotes(char[] s, int maxlen) {
  ReplaceString(s, maxlen, "\"", "'", false);
}

/** Build "displayName|assetId" and trim so len <= PRIZE_MAX (sm-giveaways g_cPrize[128]). */
void FormatPrizeString(const char[] name, const char[] assetId, char[] out, int maxlen) {
  char tmp[384];
  Format(tmp, sizeof(tmp), "%s|%s", name, assetId);
  if (strlen(tmp) > PRIZE_MAX) {
    int overhead = strlen(assetId) + 1;
    int nameBudget = PRIZE_MAX - overhead;
    if (nameBudget < 1) {
      nameBudget = 1;
    }
    char shortName[256];
    strcopy(shortName, sizeof(shortName), name);
    if (strlen(shortName) > nameBudget) {
      shortName[nameBudget] = '\0';
    }
    Format(out, maxlen, "%s|%s", shortName, assetId);
  } else {
    strcopy(out, maxlen, tmp);
  }
}

void SplitPrizeForDisplay(const char[] prize, char[] disp, int dispMax) {
  int pipe = FindCharInString(prize, '|');
  if (pipe == -1) {
    strcopy(disp, dispMax, prize);
    return;
  }
  strcopy(disp, dispMax, prize);
  if (pipe < dispMax) {
    disp[pipe] = '\0';
  }
  if (strlen(disp) > 48) {
    disp[45] = '.';
    disp[46] = '.';
    disp[47] = '.';
    disp[48] = '\0';
  }
}

public int MenuHandler_Inventory(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_End) {
    delete menu;
    return 0;
  }
  if (action != MenuAction_Select) {
    return 0;
  }

  int client = param1;
  char idxStr[8];
  menu.GetItem(param2, idxStr, sizeof(idxStr));
  int index = StringToInt(idxStr);

  char prize[192];
  if (index < 0 || index >= g_PrizeStrings.Length) {
    return 0;
  }
  g_PrizeStrings.GetString(index, prize, sizeof(prize));

  g_bBotInitiated = true;

  char cmd[256];
  Format(cmd, sizeof(cmd), "sm_gstart \"%s\"", prize);
  FakeClientCommand(client, cmd);
  return 0;
}

/**
 * sm_gstart is refired as sm_gstart "Name|assetId"; GetCmdArgString keeps the surrounding quotes.
 * Remove one pair of ASCII double quotes so split fields are clean for SQL.
 */
void StripOuterDoubleQuotes(char[] str, int maxlen) {
  int len = strlen(str);
  if (len < 2) {
    return;
  }
  if (str[0] != '"' || str[len - 1] != '"') {
    return;
  }
  for (int i = 1; i < len - 1; i++) {
    str[i - 1] = str[i];
  }
  str[len - 2] = '\0';
}

/** After split: g_cPrize can be truncated without a closing quote; trim stray " on each field. */
void TrimQuoteEdges(char[] s, int maxlen) {
  int n = 0;
  while ((n = strlen(s)) > 0 && s[0] == '"') {
    for (int i = 0; i < n; i++) {
      s[i] = s[i + 1];
    }
  }
  TrimString(s);
  n = strlen(s);
  while (n > 0 && s[n - 1] == '"') {
    s[n - 1] = '\0';
    n--;
  }
}

public void Giveaways_OnGiveawayEnded(int creator, int winner, int participants, const char[] prize) {
  if (participants == 0 || winner < 1 || winner > MaxClients || !IsClientInGame(winner)) {
    return;
  }

  if (prize[0] == '\0') {
    return;
  }

  char normalized[192];
  strcopy(normalized, sizeof(normalized), prize);
  StripOuterDoubleQuotes(normalized, sizeof(normalized));

  int pipe = FindCharInString(normalized, '|');
  if (pipe <= 0) {
    LogMessage("[giveaways_bot] Prize has no '|' separator; skipping delivery record.");
    return;
  }

  char itemName[512];
  char assetId[256];
  strcopy(itemName, sizeof(itemName), normalized);
  if (pipe < sizeof(itemName)) {
    itemName[pipe] = '\0';
  }
  strcopy(assetId, sizeof(assetId), normalized[pipe + 1]);

  TrimQuoteEdges(itemName, sizeof(itemName));
  TrimQuoteEdges(assetId, sizeof(assetId));

  char steamId[32];
  if (!GetClientAuthId(winner, AuthId_SteamID64, steamId, sizeof(steamId))) {
    LogError("[giveaways_bot] GetClientAuthId failed for winner %d", winner);
    return;
  }

  char secret[256];
  g_cvApiSecret.GetString(secret, sizeof(secret));
  if (secret[0] == '\0') {
    PrintWinnerAddBotHint(GetClientUserId(winner));
    return;
  }

  char url[512];
  FormatApiUrl("/delivery/record", url, sizeof(url));
  if (url[0] == '\0') {
    PrintWinnerAddBotHint(GetClientUserId(winner));
    return;
  }

  JSONObject body = new JSONObject();
  body.SetString("steamId64", steamId);
  body.SetString("assetId", assetId);
  body.SetString("itemName", itemName);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Post(body, OnDeliveryRecordHttp, GetClientUserId(winner));
}

void OnDeliveryRecordHttp(HTTPResponse response, any userid, const char[] error) {
  if (error[0] != '\0') {
    LogError("[giveaways_bot] POST /delivery/record failed: %s", error);
    PrintWinnerAddBotHint(userid);
    return;
  }

  if (response.Status != HTTPStatus_Created && response.Status != HTTPStatus_OK) {
    LogError("[giveaways_bot] POST /delivery/record HTTP %d", response.Status);
    PrintWinnerAddBotHint(userid);
    return;
  }

  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  bool isFriend = false;
  JSON root = response.Data;
  if (root != null && IsValidHandle(root)) {
    JSONObject obj = view_as<JSONObject>(root);
    isFriend = obj.GetBool("isFriend");
    delete root;
  }

  if (isFriend) {
    PrintToChat(
      client,
      "[Giveaways] You're already Steam friends with the bot — a trade offer should arrive shortly; check Steam."
    );
  } else {
    PrintWinnerAddBotHint(userid);
  }
}

void PrintWinnerAddBotHint(int winnerUid) {
  int w = GetClientOfUserId(winnerUid);
  if (w < 1 || !IsClientInGame(w)) {
    return;
  }
  char profileUrl[512];
  g_cvBotProfileUrl.GetString(profileUrl, sizeof(profileUrl));
  PrintToChat(w, "[Giveaways] Congratulations! Add %s to receive your prize.", profileUrl);
}
