#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#include <giveaways>
#include <ripext>
#include <morecolors>

#define PLUGIN_VERSION "2.0.1"
#define PRIZE_MAX 127
#define MAX_ITEMS 256
#define INVENTORY_FILE "data/giveaways_bot_inventory.json"
#define TRADE_OFFER_ID_MAX 64
#define DONATION_ITEM_LABEL_MAX 191
#define DONATION_ITEMS_PER_PANEL 6

// Wizard mode: 0 = none, 1 = gstart, 2 = gsend
int g_WizardMode[MAXPLAYERS + 1];
bool g_SelectedItem[MAXPLAYERS + 1][MAX_ITEMS];
char g_SendTargetSteamId[MAXPLAYERS + 1][32];
char g_SendTargetName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

bool g_bHttpInProgress;
bool g_bDonationPromptServed[MAXPLAYERS + 1];

ConVar g_cvApiBase;
ConVar g_cvApiSecret;
ConVar g_cvBotProfileUrl;

ArrayList g_PrizeStrings;
ArrayList g_PrizeAssetIds;
ArrayList g_TrackedPrizeNames;
ArrayList g_TrackedAssetIds;
ArrayList g_DonationOfferIds;
ArrayList g_DonationOfferDonors;
ArrayList g_DonationOfferItemStarts;
ArrayList g_DonationOfferItemCounts;
ArrayList g_DonationItemLabels;

int g_SelectedDonationOffer[MAXPLAYERS + 1];
int g_SelectedDonationPage[MAXPLAYERS + 1];

public Plugin myinfo = {
  name = "Giveaways - Steam bot bridge",
  author = "ampere",
  description = "Menú de inventario y registro de entregas para vidya-steam-bot",
  version = PLUGIN_VERSION,
  url = "https://github.com/vidyagaemstf2/giveaways-bot"
};

public void OnPluginStart() {
  LoadTranslations("common.phrases");

  g_cvApiBase = CreateConVar(
    "sm_giveaways_bot_api_base",
    "http://127.0.0.1:3000",
    "URL base de la API HTTP del bot de Steam (sin barra final). Se agregan automáticamente rutas como /inventory y /delivery/record."
  );
  g_cvApiSecret = CreateConVar(
    "sm_giveaways_bot_api_secret",
    "",
    "Mismo valor que API_SECRET del bot (se manda como X-Bot-Secret).",
    FCVAR_PROTECTED
  );
  g_cvBotProfileUrl = CreateConVar(
    "sm_giveaways_bot_profile_url",
    "https://steamcommunity.com/id/your-bot",
    "URL del perfil/comunidad de Steam que se muestra a ganadores."
  );

  AutoExecConfig(true, "giveaways_bot", "sourcemod");

  RegConsoleCmd("sm_donar", Command_Donate, "Abrir una ventana de donación con el bot de Steam.");
  RegConsoleCmd("sm_donate", Command_Donate, "Abrir una ventana de donación con el bot de Steam.");
  RegAdminCmd("sm_donaciones", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");
  RegAdminCmd("sm_gdonaciones", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");
  RegAdminCmd("sm_gdonations", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");
  RegAdminCmd("sm_gsend", Command_GsendTarget, ADMFLAG_GENERIC, "Enviar item(s) del inventario del bot a un jugador. Uso: sm_gsend <jugador | @me>");

  HookEvent("post_inventory_application", Event_PostInventoryApplication, EventHookMode_Post);

  g_PrizeStrings = new ArrayList(ByteCountToCells(PRIZE_MAX + 1));
  g_PrizeAssetIds = new ArrayList(ByteCountToCells(128));
  g_TrackedPrizeNames = new ArrayList(ByteCountToCells(PRIZE_MAX + 1));
  g_TrackedAssetIds = new ArrayList(ByteCountToCells(128));
  g_DonationOfferIds = new ArrayList(ByteCountToCells(TRADE_OFFER_ID_MAX + 1));
  g_DonationOfferDonors = new ArrayList(ByteCountToCells(128));
  g_DonationOfferItemStarts = new ArrayList();
  g_DonationOfferItemCounts = new ArrayList();
  g_DonationItemLabels = new ArrayList(ByteCountToCells(DONATION_ITEM_LABEL_MAX + 1));
}

public void OnPluginEnd() {
  delete g_PrizeStrings;
  delete g_PrizeAssetIds;
  delete g_TrackedPrizeNames;
  delete g_TrackedAssetIds;
  delete g_DonationOfferIds;
  delete g_DonationOfferDonors;
  delete g_DonationOfferItemStarts;
  delete g_DonationOfferItemCounts;
  delete g_DonationItemLabels;
}

public void OnClientDisconnect(int client) {
  g_bDonationPromptServed[client] = false;
  g_WizardMode[client] = 0;
  g_SendTargetSteamId[client][0] = '\0';
  g_SendTargetName[client][0] = '\0';
  for (int i = 0; i < MAX_ITEMS; i++) {
    g_SelectedItem[client][i] = false;
  }
  g_SelectedDonationOffer[client] = -1;
  g_SelectedDonationPage[client] = 0;
}

/* ─── Shared helpers ─────────────────────────────────────────────────────── */

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

bool GetApiSecretOrReply(int client, char[] secret, int maxlen) {
  g_cvApiSecret.GetString(secret, maxlen);
  if (secret[0] == '\0') {
    if (client > 0) {
      MC_PrintToChat(client, "[SM] {red}sm_giveaways_bot_api_secret no está configurado.");
    }
    return false;
  }
  return true;
}


void SanitizeQuotes(char[] s, int maxlen) {
  ReplaceString(s, maxlen, "\"", "'", false);
}


void ResetClientSelection(int client) {
  for (int i = 0; i < MAX_ITEMS; i++) {
    g_SelectedItem[client][i] = false;
  }
}

int CountClientSelection(int client) {
  int n = 0;
  int limit = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;
  for (int i = 0; i < limit; i++) {
    if (g_SelectedItem[client][i]) n++;
  }
  return n;
}

/* ─── Inventory fetch ────────────────────────────────────────────────────── */

void FetchInventoryForClient(int client) {
  if (g_bHttpInProgress) {
    MC_PrintToChat(client, "[SM] {orange}Ya hay una consulta de inventario en curso.");
    g_WizardMode[client] = 0;
    return;
  }

  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    g_WizardMode[client] = 0;
    return;
  }

  char url[512];
  FormatApiUrl("/inventory?minimal=1", url, sizeof(url));
  if (url[0] == '\0') {
    MC_PrintToChat(client, "[SM] {red}sm_giveaways_bot_api_base no está configurado.");
    g_WizardMode[client] = 0;
    return;
  }

  g_bHttpInProgress = true;
  MC_PrintToChat(client, "[SM] {grey}Cargando inventario del bot…");

  char path[PLATFORM_MAX_PATH];
  BuildPath(Path_SM, path, sizeof(path), INVENTORY_FILE);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.DownloadFile(path, OnInventoryFile, GetClientUserId(client));
}

void OnInventoryFile(HTTPStatus status, any userid, const char[] error) {
  g_bHttpInProgress = false;

  int client = GetClientOfUserId(userid);
  if (!client || !IsClientInGame(client)) {
    return;
  }

  int mode = g_WizardMode[client];
  if (mode == 0) {
    return;
  }

  if (status != HTTPStatus_OK) {
    if (error[0] != '\0') {
      MC_PrintToChat(client, "[SM] {red}Error al cargar el inventario (HTTP %d): %s", status, error);
    }
    else {
      MC_PrintToChat(client, "[SM] {red}El bot respondió HTTP %d.", status);
    }
    g_WizardMode[client] = 0;
    return;
  }

  char path[PLATFORM_MAX_PATH];
  BuildPath(Path_SM, path, sizeof(path), INVENTORY_FILE);

  JSONArray arr = JSONArray.FromFile(path);
  DeleteFile(path);

  if (arr == null) {
    MC_PrintToChat(client, "[SM] {red}No pude leer el inventario del bot.");
    g_WizardMode[client] = 0;
    return;
  }

  int len = arr.Length;
  if (len == 0) {
    delete arr;
    MC_PrintToChat(client, "[SM] {orange}El inventario del bot está vacío.");
    g_WizardMode[client] = 0;
    return;
  }

  g_PrizeStrings.Clear();
  g_PrizeAssetIds.Clear();

  for (int i = 0; i < len; i++) {
    JSON el = arr.Get(i);
    if (el == null || !IsValidHandle(el)) {
      continue;
    }
    JSONObject obj = view_as<JSONObject>(el);

    char name[PRIZE_MAX + 1];
    char assetId[128];
    char donor[128];
    if (!obj.GetString("name", name, sizeof(name))) {
      strcopy(name, sizeof(name), "Item desconocido");
    }
    if (!obj.GetString("assetId", assetId, sizeof(assetId))) {
      delete el;
      continue;
    }
    if (obj.GetString("donorName", donor, sizeof(donor)) && donor[0] != '\0') {
      char donatedName[PRIZE_MAX + 1];
      Format(donatedName, sizeof(donatedName), "%s (donado por %s)", name, donor);
      strcopy(name, sizeof(name), donatedName);
    }
    SanitizeQuotes(name, sizeof(name));

    g_PrizeStrings.PushString(name);
    g_PrizeAssetIds.PushString(assetId);

    delete el;
  }

  delete arr;

  if (g_PrizeStrings.Length == 0) {
    MC_PrintToChat(client, "[SM] {orange}No hay ítems utilizables en el inventario del bot.");
    g_WizardMode[client] = 0;
    return;
  }

  ResetClientSelection(client);
  OpenCheckboxMenu(client);
}

/* ─── Checkbox multi-select menu ─────────────────────────────────────────── */

void OpenCheckboxMenu(int client) {
  int nSelected = CountClientSelection(client);
  int itemCount = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;

  Menu menu = new Menu(MenuHandler_Checkbox);

  char confirmLabel[64];
  Format(confirmLabel, sizeof(confirmLabel), "Confirmar (%d seleccionados)", nSelected);
  menu.AddItem("confirm", confirmLabel, nSelected > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

  for (int i = 0; i < itemCount; i++) {
    char name[PRIZE_MAX + 1];
    g_PrizeStrings.GetString(i, name, sizeof(name));

    char label[PRIZE_MAX + 6];
    Format(label, sizeof(label), "%s %s", g_SelectedItem[client][i] ? "[x]" : "[ ]", name);
    if (strlen(label) > 62) {
      label[59] = '.';
      label[60] = '.';
      label[61] = '.';
      label[62] = '\0';
    }

    char key[8];
    IntToString(i, key, sizeof(key));
    menu.AddItem(key, label);
  }

  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Checkbox(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_End) {
    delete menu;
    return 0;
  }
  if (action == MenuAction_Cancel) {
    g_WizardMode[param1] = 0;
    return 0;
  }
  if (action != MenuAction_Select) {
    return 0;
  }

  int client = param1;
  char key[8];
  menu.GetItem(param2, key, sizeof(key));

  if (StrEqual(key, "confirm")) {
    int mode = g_WizardMode[client];
    if (mode == 1) {
      ShowGstartSummaryPanel(client);
    }
    else if (mode == 2) {
      ShowGsendSummaryPanel(client);
    }
    return 0;
  }

  int idx = StringToInt(key);
  if (idx >= 0 && idx < MAX_ITEMS) {
    g_SelectedItem[client][idx] = !g_SelectedItem[client][idx];
  }

  OpenCheckboxMenu(client);
  return 0;
}

/* ─── gstart wizard ──────────────────────────────────────────────────────── */

void ShowGstartSummaryPanel(int client) {
  int nSelected = CountClientSelection(client);

  Panel panel = new Panel();
  char title[64];
  Format(title, sizeof(title), "Sorteo: %d ganador(es)", nSelected);
  panel.SetTitle(title);
  panel.DrawText(" ");
  panel.DrawText("Premios:");
  panel.DrawText(" ");

  int count = 0;
  int limit = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;
  for (int i = 0; i < limit; i++) {
    if (!g_SelectedItem[client][i]) continue;
    char prize[PRIZE_MAX + 1];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    char line[80];
    Format(line, sizeof(line), "%d. %s", count + 1, prize);
    if (strlen(line) > 63) {
      line[60] = '.'; line[61] = '.'; line[62] = '.'; line[63] = '\0';
    }
    panel.DrawText(line);
    count++;
    if (count >= 10) {
      panel.DrawText("...");
      break;
    }
  }

  panel.DrawText(" ");
  panel.DrawItem("Iniciar sorteo");
  panel.DrawItem("Cancelar");

  panel.Send(client, PanelHandler_GstartSummary, MENU_TIME_FOREVER);
  delete panel;
}

public int PanelHandler_GstartSummary(Menu menu, MenuAction action, int param1, int param2) {
  if (action != MenuAction_Select) {
    if (action == MenuAction_Cancel) {
      g_WizardMode[param1] = 0;
    }
    return 0;
  }

  int client = param1;

  if (param2 == 2) {
    g_WizardMode[client] = 0;
    return 0;
  }

  int nSelected = CountClientSelection(client);
  if (nSelected == 0) {
    MC_PrintToChat(client, "[SM] {orange}No seleccionaste ningún ítem.");
    g_WizardMode[client] = 0;
    return 0;
  }

  g_TrackedPrizeNames.Clear();
  g_TrackedAssetIds.Clear();

  char argsStr[1024];
  Format(argsStr, sizeof(argsStr), "%d", nSelected);

  int limit = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;
  for (int i = 0; i < limit; i++) {
    if (!g_SelectedItem[client][i]) continue;
    char prize[PRIZE_MAX + 1];
    char assetId[128];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    g_PrizeAssetIds.GetString(i, assetId, sizeof(assetId));

    g_TrackedPrizeNames.PushString(prize);
    g_TrackedAssetIds.PushString(assetId);

    SanitizeQuotes(prize, sizeof(prize));
    Format(argsStr, sizeof(argsStr), "%s \"%s\"", argsStr, prize);
  }

  g_WizardMode[client] = 0;

  FakeClientCommand(client, "sm_gstart_now %s", argsStr);
  return 0;
}

/* ─── sm_gsend wizard ────────────────────────────────────────────────────── */

public Action Command_GsendTarget(int client, int args) {
  if (client < 1 || !IsClientInGame(client)) {
    return Plugin_Handled;
  }

  if (args < 1) {
    MC_ReplyToCommand(client, "[SM] {green}Uso: sm_gsend <jugador>");
    return Plugin_Handled;
  }

  char targetStr[64];
  GetCmdArg(1, targetStr, sizeof(targetStr));

  char resolvedName[MAX_NAME_LENGTH];
  int targets[1];
  bool tnIsMl;
  int count = ProcessTargetString(
    targetStr, client, targets, 1,
    COMMAND_FILTER_NO_MULTI | COMMAND_FILTER_NO_BOTS,
    resolvedName, sizeof(resolvedName), tnIsMl
  );

  if (count <= 0) {
    MC_ReplyToCommand(client, "[SM] {red}Jugador no encontrado o target inválido (no se permiten targets múltiples).");
    return Plugin_Handled;
  }

  int target = targets[0];
  if (!IsClientInGame(target)) {
    MC_ReplyToCommand(client, "[SM] {red}El jugador ya no está en el servidor.");
    return Plugin_Handled;
  }

  char steamId[32];
  if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId))) {
    MC_ReplyToCommand(client, "[SM] {red}No pude obtener el SteamID64 del jugador.");
    return Plugin_Handled;
  }

  char playerName[MAX_NAME_LENGTH];
  GetClientName(target, playerName, sizeof(playerName));

  strcopy(g_SendTargetSteamId[client], sizeof(g_SendTargetSteamId[]), steamId);
  strcopy(g_SendTargetName[client], sizeof(g_SendTargetName[]), playerName);
  g_WizardMode[client] = 2;
  FetchInventoryForClient(client);

  return Plugin_Handled;
}

void ShowGsendSummaryPanel(int client) {
  int nSelected = CountClientSelection(client);

  Panel panel = new Panel();
  char title[64];
  char displayName[MAX_NAME_LENGTH];
  if (g_SendTargetName[client][0] != '\0')
    strcopy(displayName, sizeof(displayName), g_SendTargetName[client]);
  else
    strcopy(displayName, sizeof(displayName), g_SendTargetSteamId[client]);
  Format(title, sizeof(title), "Enviar a %s", displayName);
  panel.SetTitle(title);
  panel.DrawText(" ");

  char headerLine[64];
  Format(headerLine, sizeof(headerLine), "Enviando %d item(s):", nSelected);
  panel.DrawText(headerLine);
  panel.DrawText(" ");

  int count = 0;
  int limit = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;
  for (int i = 0; i < limit; i++) {
    if (!g_SelectedItem[client][i]) continue;
    char prize[PRIZE_MAX + 1];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    char line[80];
    Format(line, sizeof(line), "%d. %s", count + 1, prize);
    if (strlen(line) > 63) {
      line[60] = '.'; line[61] = '.'; line[62] = '.'; line[63] = '\0';
    }
    panel.DrawText(line);
    count++;
    if (count >= 10) {
      panel.DrawText("...");
      break;
    }
  }

  panel.DrawText(" ");
  panel.DrawItem("Enviar");
  panel.DrawItem("Cancelar");

  panel.Send(client, PanelHandler_GsendSummary, MENU_TIME_FOREVER);
  delete panel;
}

public int PanelHandler_GsendSummary(Menu menu, MenuAction action, int param1, int param2) {
  if (action != MenuAction_Select) {
    if (action == MenuAction_Cancel) {
      g_WizardMode[param1] = 0;
    }
    return 0;
  }

  int client = param1;

  if (param2 == 2) {
    g_WizardMode[client] = 0;
    return 0;
  }

  int nSelected = CountClientSelection(client);
  if (nSelected == 0) {
    MC_PrintToChat(client, "[SM] {orange}No seleccionaste ningún ítem.");
    g_WizardMode[client] = 0;
    return 0;
  }

  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    g_WizardMode[client] = 0;
    return 0;
  }

  char url[512];
  FormatApiUrl("/delivery/admin-send", url, sizeof(url));
  if (url[0] == '\0') {
    MC_PrintToChat(client, "[SM] {red}sm_giveaways_bot_api_base no está configurado.");
    g_WizardMode[client] = 0;
    return 0;
  }

  JSONObject body = new JSONObject();
  body.SetString("winnerSteamId", g_SendTargetSteamId[client]);

  JSONArray items = new JSONArray();
  int limit = g_PrizeStrings.Length < MAX_ITEMS ? g_PrizeStrings.Length : MAX_ITEMS;
  for (int i = 0; i < limit; i++) {
    if (!g_SelectedItem[client][i]) continue;
    char prize[PRIZE_MAX + 1];
    char assetId[128];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    g_PrizeAssetIds.GetString(i, assetId, sizeof(assetId));

    JSONObject item = new JSONObject();
    item.SetString("assetId", assetId);
    item.SetString("itemName", prize);
    items.Push(item);
    delete item;
  }
  body.Set("items", items);
  delete items;

  g_WizardMode[client] = 0;
  MC_PrintToChat(client, "[SM] {grey}Enviando entrega al bot…");

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Post(body, OnAdminSendHttp, GetClientUserId(client));
  delete body;

  return 0;
}

void OnAdminSendHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0') {
    MC_PrintToChat(client, "[SM] {red}Error al enviar entrega: %s", error);
    return;
  }

  if (response.Status != HTTPStatus_Created && response.Status != HTTPStatus_OK) {
    MC_PrintToChat(client, "[SM] {red}Falló la entrega (HTTP %d).", response.Status);
    return;
  }

  int count = 0;
  JSON root = response.Data;
  if (root != null && IsValidHandle(root)) {
    JSONObject obj = view_as<JSONObject>(root);
    if (obj.HasKey("count")) {
      count = obj.GetInt("count");
    }
    delete root;
  }

  MC_PrintToChat(client, "[SM] {green}Entrega registrada: %d ítem(s) en cola.", count);
}

/* ─── Donation management ────────────────────────────────────────────────── */

public void Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast) {
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (client < 1 || !IsClientInGame(client) || IsFakeClient(client)) {
    return;
  }

  if (g_bDonationPromptServed[client]) {
    return;
  }

  if (!CheckCommandAccess(client, "sm_gdonations", ADMFLAG_GENERIC)) {
    return;
  }

  g_bDonationPromptServed[client] = true;
  CheckPendingDonationsForPrompt(client);
}

public Action Command_Donate(int client, int args) {
  if (client < 1 || !IsClientInGame(client)) {
    return Plugin_Handled;
  }

  ShowDonationConfirmPanel(client);
  return Plugin_Handled;
}

void ShowDonationConfirmPanel(int client) {
  Panel panel = new Panel();
  panel.SetTitle("Donar items a los sorteos?");
  panel.DrawText(" ");
  panel.DrawText("Estas por abrir una ventana de donacion de 15 min con el bot de Steam.");
  panel.DrawText(" ");
  panel.DrawText("Que pasa despues:");
  panel.DrawText("- Agrega al bot en Steam si todavia no son amigos.");
  panel.DrawText("- Manda una oferta con SOLO los items que queres donar.");
  panel.DrawText("- Durante esta ventana no hace falta mensaje especial.");
  panel.DrawText("- Si mandas una oferta directa sin ventana, usa !donar.");
  panel.DrawText("- Un admin va a revisar la oferta antes de aceptarla.");
  panel.DrawText(" ");
  panel.DrawText("No incluyas items que esperas recuperar.");
  panel.DrawText(" ");
  panel.DrawItem("Entiendo - abrir ventana de donacion");
  panel.DrawItem("Cancelar");
  panel.Send(client, PanelHandler_DonationConfirm, 45);
  delete panel;
}

public int PanelHandler_DonationConfirm(Menu menu, MenuAction action, int param1, int param2) {
  if (action != MenuAction_Select) {
    return 0;
  }

  int client = param1;
  if (client < 1 || !IsClientInGame(client)) {
    return 0;
  }

  if (param2 != 1) {
    MC_PrintToChat(client, "[SM] {grey}Donación cancelada.");
    return 0;
  }

  OpenDonationWindow(client);
  return 0;
}

void OpenDonationWindow(int client) {
  char steamId[32];
  if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) {
    MC_PrintToChat(client, "[SM] {red}No pude leer tu SteamID64.");
    return;
  }

  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return;
  }

  char url[512];
  FormatApiUrl("/donations/session", url, sizeof(url));
  if (url[0] == '\0') {
    MC_PrintToChat(client, "[SM] {red}sm_giveaways_bot_api_base no está configurado.");
    return;
  }

  MC_PrintToChat(client, "[SM] {grey}Abriendo ventana de donación…");

  char name[MAX_NAME_LENGTH];
  GetClientName(client, name, sizeof(name));

  JSONObject body = new JSONObject();
  body.SetString("steamId64", steamId);
  body.SetString("donorName", name);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Post(body, OnDonationSessionHttp, GetClientUserId(client));
  delete body;
}

void OnDonationSessionHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0' || (response.Status != HTTPStatus_Created && response.Status != HTTPStatus_OK)) {
    if (error[0] != '\0') {
      MC_PrintToChat(client, "[SM] {red}No se pudo preparar la donación: %s", error);
    }
    else {
      MC_PrintToChat(client, "[SM] {red}No se pudo preparar la donación (HTTP %d).", response.Status);
    }
    return;
  }

  bool alreadyActive = false;
  JSON root = response.Data;
  if (root != null && IsValidHandle(root)) {
    JSONObject obj = view_as<JSONObject>(root);
    if (obj.HasKey("alreadyActive")) {
      alreadyActive = obj.GetBool("alreadyActive");
    }
    delete root;
  }

  char profileUrl[512];
  g_cvBotProfileUrl.GetString(profileUrl, sizeof(profileUrl));
  if (alreadyActive) {
    MC_PrintToChat(client, "[SM] {orange}Ya tenés una ventana de donación activa. Usala antes de abrir otra.");
  }
  else {
    MC_PrintToChat(client, "[SM] {green}Ventana de donación abierta por 15 minutos.");
  }
  MC_PrintToChat(client, "{default}Agregá a %s y mandá una oferta con solo los ítems que querés donar.", profileUrl);
  MC_PrintToChat(client, "{default}Durante esta ventana no hace falta poner !donar en el trade. Si mandás una oferta directa sin ventana activa, ahí sí usá !donar o !donate.");
}

public Action Command_Donations(int client, int args) {
  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return Plugin_Handled;
  }

  char url[512];
  FormatApiUrl("/donations/pending", url, sizeof(url));
  if (url[0] == '\0') {
    MC_ReplyToCommand(client, "[SM] {red}sm_giveaways_bot_api_base no está configurado.");
    return Plugin_Handled;
  }

  MC_PrintToChat(client, "[SM] {grey}Cargando donaciones pendientes…");

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Get(OnPendingDonationsHttp, GetClientUserId(client));

  return Plugin_Handled;
}

void CheckPendingDonationsForPrompt(int client) {
  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return;
  }

  char url[512];
  FormatApiUrl("/donations/pending", url, sizeof(url));
  if (url[0] == '\0') {
    return;
  }

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Get(OnPendingDonationPromptHttp, GetClientUserId(client));
}

void OnPendingDonationsHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0' || response.Status != HTTPStatus_OK) {
    if (error[0] != '\0') {
      MC_PrintToChat(client, "[SM] {red}No se pudo cargar la lista de donaciones: %s", error);
    }
    else {
      MC_PrintToChat(client, "[SM] {red}No se pudo cargar la lista de donaciones (HTTP %d).", response.Status);
    }
    return;
  }

  JSON root = response.Data;
  if (root == null || !IsValidHandle(root)) {
    MC_PrintToChat(client, "[SM] {red}La respuesta de donaciones no fue JSON válido.");
    return;
  }

  JSONArray arr = view_as<JSONArray>(root);
  if (arr.Length == 0) {
    delete root;
    MC_PrintToChat(client, "[SM] {green}No hay donaciones pendientes de revisión.");
    return;
  }

  if (!LoadPendingDonationData(arr)) {
    delete root;
    MC_PrintToChat(client, "[SM] {orange}No llegaron donaciones pendientes utilizables.");
    return;
  }

  delete root;
  DisplayDonationListMenu(client);
}

void OnPendingDonationPromptHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0' || response.Status != HTTPStatus_OK) {
    return;
  }

  JSON root = response.Data;
  if (root == null || !IsValidHandle(root)) {
    return;
  }

  JSONArray arr = view_as<JSONArray>(root);
  if (arr.Length == 0) {
    delete root;
    return;
  }

  if (!LoadPendingDonationData(arr)) {
    delete root;
    return;
  }

  int pendingCount = g_DonationOfferIds.Length;
  delete root;
  ShowPendingDonationPrompt(client, pendingCount);
}

bool LoadPendingDonationData(JSONArray arr) {
  g_DonationOfferIds.Clear();
  g_DonationOfferDonors.Clear();
  g_DonationOfferItemStarts.Clear();
  g_DonationOfferItemCounts.Clear();
  g_DonationItemLabels.Clear();

  for (int i = 0; i < arr.Length; i++) {
    JSON el = arr.Get(i);
    if (el == null || !IsValidHandle(el)) {
      continue;
    }

    JSONObject obj = view_as<JSONObject>(el);
    char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
    char donor[128];
    tradeOfferId[0] = '\0';
    donor[0] = '\0';

    obj.GetString("tradeOfferId", tradeOfferId, sizeof(tradeOfferId));
    if (!obj.GetString("donorName", donor, sizeof(donor)) || donor[0] == '\0') {
      strcopy(donor, sizeof(donor), "Donante sin nombre");
    }

    int itemStart = g_DonationItemLabels.Length;
    int itemCount = 0;
    JSON itemsJson = obj.Get("items");
    if (itemsJson != null && IsValidHandle(itemsJson)) {
      JSONArray items = view_as<JSONArray>(itemsJson);
      for (int itemIndex = 0; itemIndex < items.Length; itemIndex++) {
        JSON itemJson = items.Get(itemIndex);
        if (itemJson == null || !IsValidHandle(itemJson)) {
          continue;
        }

        JSONObject itemObj = view_as<JSONObject>(itemJson);
        char itemName[128];
        if (!itemObj.GetString("name", itemName, sizeof(itemName)) || itemName[0] == '\0') {
          strcopy(itemName, sizeof(itemName), "Item sin nombre");
        }

        char itemLabel[DONATION_ITEM_LABEL_MAX + 1];
        Format(itemLabel, sizeof(itemLabel), "%d. %s", itemCount + 1, itemName);
        g_DonationItemLabels.PushString(itemLabel);
        itemCount++;

        delete itemJson;
      }
      delete itemsJson;
    }

    if (tradeOfferId[0] != '\0') {
      g_DonationOfferIds.PushString(tradeOfferId);
      g_DonationOfferDonors.PushString(donor);
      g_DonationOfferItemStarts.Push(itemStart);
      g_DonationOfferItemCounts.Push(itemCount);
    }

    delete el;
  }

  return g_DonationOfferIds.Length > 0;
}

void DisplayDonationListMenu(int client) {
  if (g_DonationOfferIds.Length == 0) {
    MC_PrintToChat(client, "[SM] {orange}No llegaron donaciones pendientes utilizables.");
    return;
  }

  Menu menu = new Menu(MenuHandler_DonationList);
  menu.SetTitle("Donaciones pendientes");

  for (int i = 0; i < g_DonationOfferIds.Length; i++) {
    char idxStr[8];
    char display[192];
    char donor[128];
    char firstItem[128];

    int itemStart = g_DonationOfferItemStarts.Get(i);
    int itemCount = g_DonationOfferItemCounts.Get(i);

    IntToString(i, idxStr, sizeof(idxStr));
    g_DonationOfferDonors.GetString(i, donor, sizeof(donor));

    if (itemCount > 0) {
      g_DonationItemLabels.GetString(itemStart, firstItem, sizeof(firstItem));
    }
    else {
      strcopy(firstItem, sizeof(firstItem), "Sin items visibles");
    }

    if (itemCount > 1) {
      Format(display, sizeof(display), "%s: %s +%d", donor, firstItem, itemCount - 1);
    }
    else {
      Format(display, sizeof(display), "%s: %s", donor, firstItem);
    }
    menu.AddItem(idxStr, display);
  }

  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

void ShowPendingDonationPrompt(int client, int pendingCount) {
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  Panel panel = new Panel();
  panel.SetTitle("Donaciones pendientes");
  panel.DrawText(" ");

  char line[128];
  Format(line, sizeof(line), "Hay %d donaciones pendientes.", pendingCount);
  panel.DrawText(line);
  panel.DrawText(" ");
  panel.DrawItem("Revisar ahora");
  panel.DrawItem("Mas tarde");
  panel.Send(client, PanelHandler_PendingDonationPrompt, 30);
  delete panel;
}

public int PanelHandler_PendingDonationPrompt(Menu menu, MenuAction action, int param1, int param2) {
  if (action != MenuAction_Select) {
    return 0;
  }

  int client = param1;
  if (client < 1 || !IsClientInGame(client)) {
    return 0;
  }

  if (param2 == 1) {
    DisplayDonationListMenu(client);
  }
  return 0;
}

public int MenuHandler_DonationList(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_End) {
    delete menu;
    return 0;
  }
  if (action != MenuAction_Select) {
    return 0;
  }

  char idxStr[8];
  menu.GetItem(param2, idxStr, sizeof(idxStr));
  int index = StringToInt(idxStr);
  if (index < 0 || index >= g_DonationOfferIds.Length) {
    return 0;
  }

  ShowDonationReviewPanel(param1, index, 0);
  return 0;
}

void ShowDonationReviewPanel(int client, int offerIndex, int page) {
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }
  if (offerIndex < 0 || offerIndex >= g_DonationOfferIds.Length) {
    MC_PrintToChat(client, "[SM] {orange}La donación seleccionada ya no está disponible.");
    return;
  }

  int itemStart = g_DonationOfferItemStarts.Get(offerIndex);
  int itemCount = g_DonationOfferItemCounts.Get(offerIndex);
  int pageCount = 1;
  if (itemCount > 0) {
    pageCount = (itemCount + DONATION_ITEMS_PER_PANEL - 1) / DONATION_ITEMS_PER_PANEL;
  }
  if (page < 0) {
    page = 0;
  }
  if (page >= pageCount) {
    page = pageCount - 1;
  }

  g_SelectedDonationOffer[client] = offerIndex;
  g_SelectedDonationPage[client] = page;

  char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
  char donor[128];
  g_DonationOfferIds.GetString(offerIndex, tradeOfferId, sizeof(tradeOfferId));
  g_DonationOfferDonors.GetString(offerIndex, donor, sizeof(donor));

  Panel panel = new Panel();
  panel.SetTitle("Revision de donacion");  // panels don't render accents reliably
  panel.DrawText(" ");

  char line[256];
  Format(line, sizeof(line), "Donante: %s", donor);
  panel.DrawText(line);
  Format(line, sizeof(line), "Oferta: %s", tradeOfferId);
  panel.DrawText(line);
  Format(line, sizeof(line), "Items: %d", itemCount);
  panel.DrawText(line);
  panel.DrawText(" ");

  if (itemCount == 0) {
    panel.DrawText("- No hay items registrados en esta oferta.");
  }
  else {
    Format(line, sizeof(line), "Pagina %d/%d", page + 1, pageCount);
    panel.DrawText(line);

    int firstItem = page * DONATION_ITEMS_PER_PANEL;
    int lastItem = firstItem + DONATION_ITEMS_PER_PANEL;
    if (lastItem > itemCount) {
      lastItem = itemCount;
    }

    for (int itemIndex = firstItem; itemIndex < lastItem; itemIndex++) {
      char itemLabel[DONATION_ITEM_LABEL_MAX + 1];
      g_DonationItemLabels.GetString(itemStart + itemIndex, itemLabel, sizeof(itemLabel));
      panel.DrawText(itemLabel);
    }
  }

  bool hasNext = (page + 1) < pageCount;
  panel.DrawText(" ");
  if (hasNext) {
    panel.DrawText("Revisa todas las paginas antes de decidir.");
  }
  if (page > 0) {
    panel.DrawItem("Pagina anterior");
  }
  if (hasNext) {
    panel.DrawItem("Ver mas items");  // panels don't render accents reliably
  }
  else {
    panel.DrawItem("Aprobar y aceptar oferta");
    panel.DrawItem("Rechazar y declinar oferta");
  }
  panel.DrawItem("Volver a donaciones");
  panel.DrawText(" ");
  panel.Send(client, PanelHandler_DonationReview, MENU_TIME_FOREVER);
  delete panel;
}

public int PanelHandler_DonationReview(Menu menu, MenuAction action, int param1, int param2) {
  if (action != MenuAction_Select) {
    return 0;
  }

  int client = param1;
  if (client < 1 || !IsClientInGame(client)) {
    return 0;
  }

  int offerIndex = g_SelectedDonationOffer[client];
  if (offerIndex < 0 || offerIndex >= g_DonationOfferIds.Length) {
    MC_PrintToChat(client, "[SM] {orange}La donación seleccionada ya no está disponible.");
    return 0;
  }

  int page = g_SelectedDonationPage[client];
  int itemCount = g_DonationOfferItemCounts.Get(offerIndex);
  int pageCount = 1;
  if (itemCount > 0) {
    pageCount = (itemCount + DONATION_ITEMS_PER_PANEL - 1) / DONATION_ITEMS_PER_PANEL;
  }
  bool hasNext = (page + 1) < pageCount;

  int button = 1;
  if (page > 0) {
    if (param2 == button) {
      ShowDonationReviewPanel(client, offerIndex, page - 1);
      return 0;
    }
    button++;
  }

  if (hasNext) {
    if (param2 == button) {
      ShowDonationReviewPanel(client, offerIndex, page + 1);
      return 0;
    }
    button++;
  }
  else {
    char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
    g_DonationOfferIds.GetString(offerIndex, tradeOfferId, sizeof(tradeOfferId));

    if (param2 == button) {
      SendDonationReview(client, tradeOfferId, true);
      return 0;
    }
    button++;

    if (param2 == button) {
      SendDonationReview(client, tradeOfferId, false);
      return 0;
    }
    button++;
  }

  if (param2 == button) {
    Command_Donations(client, 0);
  }
  return 0;
}

void SendDonationReview(int client, const char[] tradeOfferId, bool approve) {
  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return;
  }

  char path[160];
  if (approve) {
    Format(path, sizeof(path), "/donations/%s/approve", tradeOfferId);
  }
  else {
    Format(path, sizeof(path), "/donations/%s/reject", tradeOfferId);
  }

  char url[512];
  FormatApiUrl(path, url, sizeof(url));
  if (url[0] == '\0') {
    MC_PrintToChat(client, "[SM] {red}sm_giveaways_bot_api_base no está configurado.");
    return;
  }

  MC_PrintToChat(client, "[SM] {grey}Enviando revisión al bot…");

  char adminSteamId[32];
  char adminName[MAX_NAME_LENGTH];
  if (!GetClientAuthId(client, AuthId_SteamID64, adminSteamId, sizeof(adminSteamId))) {
    adminSteamId[0] = '\0';
  }
  GetClientName(client, adminName, sizeof(adminName));

  JSONObject body = new JSONObject();
  body.SetString("reviewerSteamId", adminSteamId);
  body.SetString("reviewerName", adminName);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 45;
  req.Post(body, OnDonationReviewHttp, GetClientUserId(client));
  delete body;
}

void OnDonationReviewHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0') {
    MC_PrintToChat(client, "[SM] {red}Falló la revisión de la donación: %s", error);
    return;
  }

  if (response.Status != HTTPStatus_OK) {
    char apiError[256];
    apiError[0] = '\0';
    JSON errRoot = response.Data;
    if (errRoot != null && IsValidHandle(errRoot)) {
      JSONObject errObj = view_as<JSONObject>(errRoot);
      errObj.GetString("error", apiError, sizeof(apiError));
      delete errRoot;
    }
    if (apiError[0] != '\0') {
      MC_PrintToChat(client, "[SM] {red}Falló la revisión (HTTP %d): %s", response.Status, apiError);
    } else {
      MC_PrintToChat(client, "[SM] {red}Falló la revisión de la donación (HTTP %d).", response.Status);
    }
    return;
  }

  MC_PrintToChat(client, "[SM] {green}Donación revisada correctamente.");
}

/* ─── Giveaway forwards ──────────────────────────────────────────────────── */

public Action Giveaways_OnGiveawayStart(int client, const char[] prize) {
  if (prize[0] != '\0') {
    return Plugin_Continue;
  }

  g_WizardMode[client] = 1;
  FetchInventoryForClient(client);
  return Plugin_Handled;
}

public void Giveaways_OnGiveawayEnded(int creator, int winner, int participants, const char[] prize) {
  if (participants == 0 || winner < 1 || winner > MaxClients || !IsClientInGame(winner)) {
    return;
  }

  if (prize[0] == '\0') {
    return;
  }

  char normalized[PRIZE_MAX + 1];
  strcopy(normalized, sizeof(normalized), prize);

  char assetId[128];
  bool found = false;

  for (int i = 0; i < g_TrackedPrizeNames.Length; i++) {
    char trackedName[PRIZE_MAX + 1];
    g_TrackedPrizeNames.GetString(i, trackedName, sizeof(trackedName));
    if (StrEqual(normalized, trackedName, false)) {
      g_TrackedAssetIds.GetString(i, assetId, sizeof(assetId));
      g_TrackedPrizeNames.Erase(i);
      g_TrackedAssetIds.Erase(i);
      found = true;
      break;
    }
  }

  char itemName[PRIZE_MAX + 1];
  if (found) {
    strcopy(itemName, sizeof(itemName), normalized);
  }
  else {
    int pipe = FindCharInString(normalized, '|');
    if (pipe <= 0) {
      LogMessage("[giveaways_bot] No tracked asset id for prize '%s'; skipping delivery record.", normalized);
      return;
    }
    strcopy(itemName, sizeof(itemName), normalized);
    itemName[pipe] = '\0';
    strcopy(assetId, sizeof(assetId), normalized[pipe + 1]);
    TrimQuoteEdges(itemName);
    TrimQuoteEdges(assetId);
  }

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
  delete body;
}

public Action Giveaways_OnGiveawayCancel(int creator, int cancelator) {
  g_TrackedPrizeNames.Clear();
  g_TrackedAssetIds.Clear();
  return Plugin_Continue;
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
    MC_PrintToChat(client, "[SM] {green}Ya sos amigo del bot en Steam. La oferta debería llegar en breve; revisá Steam.");
  }
  else {
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
  MC_PrintToChat(w, "[SM] {green}¡Felicitaciones! Agregá %s para recibir tu premio.", profileUrl);
}

void TrimQuoteEdges(char[] s) {
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
