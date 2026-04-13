# giveaways_bot

SourceMod bridge between **[sm-giveaways](https://github.com/maxijabase/sm-giveaways)** and the **vidya-steam-bot** HTTP API: inventory menu, MySQL `pending_deliveries`, and prize strings for the Steam bot.

Repository: **[vidyagaemstf2/giveaways-bot](https://github.com/vidyagaemstf2/giveaways-bot)**.

## Layout

- `scripting/giveaways_bot.sp` — plugin source
- `include/` — vendored [RipExt](https://github.com/ErikMinekus/sm-ripext) headers (`ripext.inc`, `ripext/http.inc`, `ripext/json.inc`)

`giveaways.inc` comes from **sm-giveaways** (not vendored here). Point `spcomp` at both include roots.

## Compile

Example (adjust paths to your machine and SourceMod `spcomp`):

```bat
spcomp.exe ^
  -i.\include ^
  -i..\sm-giveaways\addons\sourcemod\scripting\include ^
  scripting\giveaways_bot.sp ^
  -o giveaways_bot.smx
```

Install `giveaways_bot.smx` under the server `addons/sourcemod/plugins/` and add to `plugins.ini` **after** `giveaways.smx`.

## Configuration

RipExt (`rip.ext`) must be installed on the server. Set ConVars in `cfg/sourcemod/giveaways_bot.cfg` (see `scripting/giveaways_bot.sp` for names): `sm_giveaways_bot_api_base`, `sm_giveaways_bot_api_secret`, `sm_giveaways_bot_profile_url`, and MySQL `databases.cfg` section `giveaways_bot` for `pending_deliveries`.
