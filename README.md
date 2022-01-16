# bannedclans

A sourcemod plugin to manage the moderation of clan tags 

## Overview

This plugin allows you to kick or ban users displaying unwanted clan tags from your server. A kick will be escalated to a ban after a configurable number of offenses.

Currently, clan tags are only checked when the user first connects. Periodic re-checking will be added in a later version.

CS:GO is tested as working, but this may work for other versions of CS as well. Some CS-specific code is used so this is currently not applicable to other games.

## Convars

- `sm_bannedclans_enable <0|1>`: enable or disable the plugin (default 0)
- `sm_bannedclans_file <path>`: path to list of clan IDs to moderate (see below). path is specified relative to the server's `csgo` directory.
- `sm_bannedclans_maxwarnings <number>`: number of warning kicks before a user will be banned (default 1)
- `sm_bannedclans_banduration <number>`: number of minutes for bans, or 0 for permanent bans (default 60)
- `sm_bannedclans_dbconfig <id>`: sourcemod database configuration to use (default `default`)

A default configuration file will be created at the plugin's first load.

## Commands

- `sm_getclanid <target>`: look up the clan ID8 and other information for a player

## Config file

The config file is a series of lines of the format `action id`, where `action` is either `kick` or `ban`, and `id` is the group id8 (i.e., the parameter to `cl_clanid`).

For example,

```
kick 1234
ban 5678
```

will result in users displaying the clan tag associated with group 1234 being kicked (up to `maxwarnings`) and users displaying the clan tag of group 5678 being immediately banned.

You can use `sm_getclanid` to look up the id8, or subtract `103582791429521408` from a groupid64.

Any convar update pertaining to this plugin will result in the config file being reloaded.

## Database

Both mysql and sqlite are supported as database backends. Tables will automatically be created when the plugin loads. Currently the database is only used to persist the number of times a user has been warned.

## Compiling

This plugin supports compilation with [sourceknight](https://github.com/tmick0/sourceknight); simply type `sourceknight build` from the root of this repo. The plugin will be output in the `addons/sourcemod/plugins` directory.

## License

This plugin is released under the terms of the GNU General Public License, version 3. See the [LICENSE](LICENSE) file for details.
