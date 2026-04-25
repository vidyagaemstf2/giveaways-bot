#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#include <giveaways>
#include <ripext>

#define PLUGIN_VERSION "1.5"
#define PRIZE_MAX 127
#define INVENTORY_FILE "data/giveaways_bot_inventory.json"
#define TRADE_OFFER_ID_MAX 64

bool g_bBotInitiated;
bool g_bHttpInProgress;

ConVar g_cvApiBase;
ConVar g_cvApiSecret;
ConVar g_cvBotProfileUrl;

ArrayList g_PrizeStrings;
ArrayList g_PrizeAssetIds;
ArrayList g_DonationOfferIds;

char g_ActivePrizeName[256];
char g_ActiveAssetId[128];

public Plugin myinfo = {
  name = "Giveaways - Steam bot bridge",
  author = "ampere",
  description = "Menu de inventario y registro de entregas para vidya-steam-bot",
  version = PLUGIN_VERSION,
  url = "https://github.com/vidyagaemstf2/giveaways-bot"
};

public void OnPluginStart() {
  LoadTranslations("common.phrases");

  g_cvApiBase = CreateConVar(
    "sm_giveaways_bot_api_base",
    "http://127.0.0.1:3000",
    "URL base de la API HTTP del bot de Steam (sin barra final). Se agregan automaticamente rutas como /inventory y /delivery/record."
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

  RegConsoleCmd("sm_donar", Command_Donate, "Abrir una ventana de donacion con el bot de Steam.");
  RegConsoleCmd("sm_donate", Command_Donate, "Abrir una ventana de donacion con el bot de Steam.");
  RegAdminCmd("sm_donaciones", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");
  RegAdminCmd("sm_gdonaciones", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");
  RegAdminCmd("sm_gdonations", Command_Donations, ADMFLAG_GENERIC, "Revisar donaciones pendientes del bot de Steam.");

  g_PrizeStrings = new ArrayList(ByteCountToCells(PRIZE_MAX + 1));
  g_PrizeAssetIds = new ArrayList(ByteCountToCells(128));
  g_DonationOfferIds = new ArrayList(ByteCountToCells(TRADE_OFFER_ID_MAX + 1));
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

bool GetApiSecretOrReply(int client, char[] secret, int maxlen) {
  g_cvApiSecret.GetString(secret, maxlen);
  if (secret[0] == '\0') {
    if (client > 0) {
      PrintToChat(client, "[SM] sm_giveaways_bot_api_secret no esta configurado.");
    }
    return false;
  }
  return true;
}

public void OnPluginEnd() {
  delete g_PrizeStrings;
  delete g_PrizeAssetIds;
  delete g_DonationOfferIds;
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
  panel.DrawText("Estas por abrir una ventana de donacion de 15 minutos con el bot de Steam.");
  panel.DrawText(" ");
  panel.DrawText("Que pasa despues:");
  panel.DrawText("- Agrega al bot en Steam si todavia no son amigos.");
  panel.DrawText("- Manda una oferta con SOLO los items que queres donar.");
  panel.DrawText("- Pone !donar o !donate en el mensaje de la oferta.");
  panel.DrawText("- Un admin va a revisar la oferta antes de que el bot la acepte.");
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
    PrintToChat(client, "[SM] Donacion cancelada.");
    return 0;
  }

  OpenDonationWindow(client);
  return 0;
}

void OpenDonationWindow(int client) {
  char steamId[32];
  if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId))) {
    PrintToChat(client, "[SM] No pude leer tu SteamID64.");
    return;
  }

  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return;
  }

  char url[512];
  FormatApiUrl("/donations/session", url, sizeof(url));
  if (url[0] == '\0') {
    PrintToChat(client, "[SM] sm_giveaways_bot_api_base no esta configurado.");
    return;
  }

  char name[MAX_NAME_LENGTH];
  GetClientName(client, name, sizeof(name));

  JSONObject body = new JSONObject();
  body.SetString("steamId64", steamId);
  body.SetString("donorName", name);

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Post(body, OnDonationSessionHttp, GetClientUserId(client));
}

void OnDonationSessionHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0' || (response.Status != HTTPStatus_Created && response.Status != HTTPStatus_OK)) {
    if (error[0] != '\0') {
      PrintToChat(client, "[SM] No se pudo preparar la donacion: %s", error);
    } else {
      PrintToChat(client, "[SM] No se pudo preparar la donacion (HTTP %d).", response.Status);
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
    PrintToChat(client, "[SM] Ya tenes una ventana de donacion activa. Usala antes de abrir otra.");
  } else {
    PrintToChat(client, "[SM] Ventana de donacion abierta por 15 minutos.");
  }
  PrintToChat(client, "[SM] Agrega a %s y manda una oferta con solo los items que queres donar.", profileUrl);
  PrintToChat(client, "[SM] Pone !donar o !donate en el mensaje de trade. Si te olvidas de eso, el bot rechaza la oferta. Los admins la revisan antes de que el bot acepte.");
}

public Action Command_Donations(int client, int args) {
  char secret[256];
  if (!GetApiSecretOrReply(client, secret, sizeof(secret))) {
    return Plugin_Handled;
  }

  char url[512];
  FormatApiUrl("/donations/pending", url, sizeof(url));
  if (url[0] == '\0') {
    ReplyToCommand(client, "[SM] sm_giveaways_bot_api_base no esta configurado.");
    return Plugin_Handled;
  }

  HTTPRequest req = new HTTPRequest(url);
  req.SetHeader("X-Bot-Secret", "%s", secret);
  req.Timeout = 30;
  req.Get(OnPendingDonationsHttp, GetClientUserId(client));

  return Plugin_Handled;
}

void OnPendingDonationsHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0' || response.Status != HTTPStatus_OK) {
    if (error[0] != '\0') {
      PrintToChat(client, "[SM] No se pudo cargar la lista de donaciones: %s", error);
    } else {
      PrintToChat(client, "[SM] No se pudo cargar la lista de donaciones (HTTP %d).", response.Status);
    }
    return;
  }

  JSON root = response.Data;
  if (root == null || !IsValidHandle(root)) {
    PrintToChat(client, "[SM] La respuesta de donaciones no fue JSON valido.");
    return;
  }

  JSONArray arr = view_as<JSONArray>(root);
  if (arr.Length == 0) {
    delete root;
    PrintToChat(client, "[SM] No hay donaciones pendientes de revision.");
    return;
  }

  g_DonationOfferIds.Clear();

  Menu menu = new Menu(MenuHandler_DonationList);
  menu.SetTitle("Donaciones pendientes");

  for (int i = 0; i < arr.Length; i++) {
    JSON el = arr.Get(i);
    if (el == null || !IsValidHandle(el)) {
      continue;
    }

    JSONObject obj = view_as<JSONObject>(el);
    char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
    char donor[128];
    char firstItem[128];
    tradeOfferId[0] = '\0';
    donor[0] = '\0';
    firstItem[0] = '\0';

    obj.GetString("tradeOfferId", tradeOfferId, sizeof(tradeOfferId));
    if (!obj.GetString("donorName", donor, sizeof(donor)) || donor[0] == '\0') {
      obj.GetString("donorSteamId", donor, sizeof(donor));
    }

    int itemCount = 0;
    JSON itemsJson = obj.Get("items");
    if (itemsJson != null && IsValidHandle(itemsJson)) {
      JSONArray items = view_as<JSONArray>(itemsJson);
      itemCount = items.Length;
      if (itemCount > 0) {
        JSON firstJson = items.Get(0);
        if (firstJson != null && IsValidHandle(firstJson)) {
          JSONObject first = view_as<JSONObject>(firstJson);
          first.GetString("name", firstItem, sizeof(firstItem));
          delete firstJson;
        }
      }
      delete itemsJson;
    }

    if (tradeOfferId[0] != '\0') {
      int idx = g_DonationOfferIds.Length;
      g_DonationOfferIds.PushString(tradeOfferId);

      char idxStr[8];
      char display[192];
      IntToString(idx, idxStr, sizeof(idxStr));
      if (itemCount > 1) {
        Format(display, sizeof(display), "%s: %s +%d", donor, firstItem, itemCount - 1);
      } else {
        Format(display, sizeof(display), "%s: %s", donor, firstItem);
      }
      menu.AddItem(idxStr, display);
    }

    delete el;
  }

  delete root;

  if (g_DonationOfferIds.Length == 0) {
    delete menu;
    PrintToChat(client, "[SM] No llegaron donaciones pendientes utilizables.");
    return;
  }

  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
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

  char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
  g_DonationOfferIds.GetString(index, tradeOfferId, sizeof(tradeOfferId));

  Menu actions = new Menu(MenuHandler_DonationAction);
  actions.SetTitle("Donacion %s", tradeOfferId);
  actions.AddItem(tradeOfferId, "Aprobar y aceptar oferta");
  actions.AddItem(tradeOfferId, "Rechazar y declinar oferta");
  actions.ExitButton = true;
  actions.Display(param1, MENU_TIME_FOREVER);
  return 0;
}

public int MenuHandler_DonationAction(Menu menu, MenuAction action, int param1, int param2) {
  if (action == MenuAction_End) {
    delete menu;
    return 0;
  }
  if (action != MenuAction_Select) {
    return 0;
  }

  char tradeOfferId[TRADE_OFFER_ID_MAX + 1];
  menu.GetItem(param2, tradeOfferId, sizeof(tradeOfferId));
  SendDonationReview(param1, tradeOfferId, param2 == 0);
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
  } else {
    Format(path, sizeof(path), "/donations/%s/reject", tradeOfferId);
  }

  char url[512];
  FormatApiUrl(path, url, sizeof(url));
  if (url[0] == '\0') {
    PrintToChat(client, "[SM] sm_giveaways_bot_api_base no esta configurado.");
    return;
  }

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
}

void OnDonationReviewHttp(HTTPResponse response, any userid, const char[] error) {
  int client = GetClientOfUserId(userid);
  if (client < 1 || !IsClientInGame(client)) {
    return;
  }

  if (error[0] != '\0') {
    PrintToChat(client, "[SM] Fallo la revision de la donacion: %s", error);
    return;
  }

  if (response.Status != HTTPStatus_OK) {
    PrintToChat(client, "[SM] Fallo la revision de la donacion (HTTP %d).", response.Status);
    return;
  }

  PrintToChat(client, "[SM] Revision de donacion enviada.");
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
    PrintToChat(client, "[SM] Ya hay una consulta de inventario en curso.");
    return Plugin_Handled;
  }

  char secret[256];
  g_cvApiSecret.GetString(secret, sizeof(secret));
  if (secret[0] == '\0') {
    PrintToChat(client, "[SM] sm_giveaways_bot_api_secret no esta configurado.");
    return Plugin_Handled;
  }

  char url[512];
  FormatApiUrl("/inventory?minimal=1", url, sizeof(url));
  if (url[0] == '\0') {
    PrintToChat(client, "[SM] sm_giveaways_bot_api_base no esta configurado.");
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
      PrintToChat(client, "[SM] HTTP %d - %s", status, error);
    } else {
      PrintToChat(client, "[SM] El bot respondio HTTP %d.", status);
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
    PrintToChat(client, "[SM] No pude leer el inventario del bot.");
    return;
  }

  int len = arr.Length;
  if (len == 0) {
    delete arr;
    PrintToChat(client, "[SM] El inventario del bot esta vacio.");
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

    char name[256];
    char assetId[128];
    if (!obj.GetString("name", name, sizeof(name))) {
      strcopy(name, sizeof(name), "Item desconocido");
    }
    if (!obj.GetString("assetId", assetId, sizeof(assetId))) {
      delete el;
      continue;
    }
    SanitizeQuotes(name, sizeof(name));

    g_PrizeStrings.PushString(name);
    g_PrizeAssetIds.PushString(assetId);
  }

  delete arr;

  if (g_PrizeStrings.Length == 0) {
    PrintToChat(client, "[SM] No hay items utilizables en el inventario del bot.");
    return;
  }

  Menu menu = new Menu(MenuHandler_Inventory);
  menu.SetTitle("Elegir premio (inventario del bot)");

  char disp[64];
  char idx[8];
  for (int i = 0; i < g_PrizeStrings.Length; i++) {
    char prize[192];
    g_PrizeStrings.GetString(i, prize, sizeof(prize));
    strcopy(disp, sizeof(disp), prize);
    if (strlen(disp) > 48) {
      disp[45] = '.';
      disp[46] = '.';
      disp[47] = '.';
      disp[48] = '\0';
    }
    IntToString(i, idx, sizeof(idx));
    menu.AddItem(idx, disp);
  }

  menu.ExitButton = true;
  menu.Display(client, MENU_TIME_FOREVER);
}

void SanitizeQuotes(char[] s, int maxlen) {
  ReplaceString(s, maxlen, "\"", "'", false);
}

void ClearActivePrize() {
  g_ActivePrizeName[0] = '\0';
  g_ActiveAssetId[0] = '\0';
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
  if (index < 0 || index >= g_PrizeStrings.Length || index >= g_PrizeAssetIds.Length) {
    return 0;
  }
  g_PrizeStrings.GetString(index, prize, sizeof(prize));
  g_PrizeAssetIds.GetString(index, g_ActiveAssetId, sizeof(g_ActiveAssetId));
  strcopy(g_ActivePrizeName, sizeof(g_ActivePrizeName), prize);

  g_bBotInitiated = true;

  char cmd[256];
  Format(cmd, sizeof(cmd), "sm_gstart \"%s\"", prize);
  FakeClientCommand(client, cmd);
  return 0;
}

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
    ClearActivePrize();
    return;
  }

  if (prize[0] == '\0') {
    ClearActivePrize();
    return;
  }

  char normalized[192];
  strcopy(normalized, sizeof(normalized), prize);
  StripOuterDoubleQuotes(normalized, sizeof(normalized));

  char itemName[512];
  char assetId[256];

  if (g_ActiveAssetId[0] != '\0' && StrEqual(normalized, g_ActivePrizeName)) {
    strcopy(itemName, sizeof(itemName), normalized);
    strcopy(assetId, sizeof(assetId), g_ActiveAssetId);
  } else {
    int pipe = FindCharInString(normalized, '|');
    if (pipe <= 0) {
      LogMessage("[giveaways_bot] Prize has no tracked asset id; skipping delivery record.");
      ClearActivePrize();
      return;
    }

    strcopy(itemName, sizeof(itemName), normalized);
    if (pipe < sizeof(itemName)) {
      itemName[pipe] = '\0';
    }
    strcopy(assetId, sizeof(assetId), normalized[pipe + 1]);
  }

  TrimQuoteEdges(itemName, sizeof(itemName));
  TrimQuoteEdges(assetId, sizeof(assetId));

  char steamId[32];
  if (!GetClientAuthId(winner, AuthId_SteamID64, steamId, sizeof(steamId))) {
    LogError("[giveaways_bot] GetClientAuthId failed for winner %d", winner);
    ClearActivePrize();
    return;
  }

  char secret[256];
  g_cvApiSecret.GetString(secret, sizeof(secret));
  if (secret[0] == '\0') {
    PrintWinnerAddBotHint(GetClientUserId(winner));
    ClearActivePrize();
    return;
  }

  char url[512];
  FormatApiUrl("/delivery/record", url, sizeof(url));
  if (url[0] == '\0') {
    PrintWinnerAddBotHint(GetClientUserId(winner));
    ClearActivePrize();
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
  ClearActivePrize();
}

public Action Giveaways_OnGiveawayCancel(int creator, int cancelator) {
  ClearActivePrize();
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
    PrintToChat(
      client,
      "[SM] Ya sos amigo del bot en Steam. La oferta deberia llegar en breve; revisa Steam."
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
  PrintToChat(w, "[SM] Felicitaciones! Agrega %s para recibir tu premio.", profileUrl);
}
