# AzerothCore AMP Install Guide

This guide covers the AzerothCore Generic Module template in `RyanTheTechMan/AMPTemplates`. It is intended for a private Wrath of the Lich King 3.3.5a realm managed entirely through CubeCoders AMP.

The template keeps the service stack inside the AMP instance/container: it downloads and compiles AzerothCore, installs a portable MySQL server, starts `authserver` and `worldserver`, and manages the common server settings exposed in AMP.

## Before you start

You will need:

- A working CubeCoders AMP installation with Docker/container support.
- An x86_64 host. The template currently targets Linux x86_64 inside AMP's container environment.
- Roughly **20 GB free disk** as a practical starting point for the first build.
- For a normal AzerothCore realm, start with **4 container CPUs and 8-12 GB RAM**.
- For Playerbots, use **6 container CPUs and at least 16 GB RAM**; **24-32 GB** is preferable for larger bot populations.
- A legally obtained World of Warcraft Wrath of the Lich King **3.3.5a** client. AzerothCore does not distribute the Blizzard game client.
- TCP ports **3724** and **8085** available by default, unless you change them in AMP.

On a Windows AMP host, use AMP's Docker/container support so the AzerothCore instance still runs in the same Linux environment described by this guide.

The template uses `cubecoders/ampbase:debian`, CubeCoders' primary AMP base image, which is currently based on **Debian 13**. Do not manually add Debian's `default-libmysqlclient-dev` or MariaDB compatibility development packages to this instance: the template intentionally compiles and runs against its own bundled Oracle MySQL client libraries.

For AMP's container limits, `0` means unlimited. Unlimited can work on a dedicated host, but explicit CPU/RAM limits are safer when other AMP instances share the machine. The installer itself caps automatic compilation at four parallel jobs unless **Parallel Build Jobs** is changed.

## 1. Add this template repository to AMP

From the ADS/controller instance:

1. Open **Configuration**.
2. Open **Instance Deployment**.
3. Under **Configuration Repositories**, click **Add**.
4. Enter:

   ```text
   RyanTheTechMan/AMPTemplates
   ```

5. Click **OK**.
6. Click **Fetch Latest**.
7. Refresh the AMP web interface.

`AzerothCore` should now be available when creating a new instance.

If you are testing an unmerged branch, AMP also accepts the repository in this form:

```text
RyanTheTechMan/AMPTemplates:branch-name
```

When testing a branch, set **Template Repository Ref** in the AzerothCore settings to the same branch before running Update.

## 2. Create the AzerothCore instance

Create a new instance and select **AzerothCore**.

The template requires an AMP-managed container. This is intentional: AzerothCore is built from source and needs a consistent compiler, library, MySQL, and runtime environment. The expected container image is `cubecoders/ampbase:debian` (currently Debian 13).

Before the first Update, review these settings first:

- **Server Distribution / Version**
- **Realm Name**
- **Realm Address Selection**
- **Manual Realm Address**, when applicable
- **Realm Local Address**
- **Authentication Port**
- **World Port**
- **Player Limit**
- **MySQL Release Stream**

Most gameplay settings can safely be adjusted later.

## 3. Choose the server distribution

The template provides several server tracks, similar to choosing a server flavor in other game panels.

| AMP option | What it installs | Recommended use |
| --- | --- | --- |
| **AzerothCore rolling master** | Official `azerothcore/azerothcore-wotlk` `master` | Normal server; recommended default |
| **AzerothCore v4.0.0** | Official historical `v4.0.0` tag | Compatibility/testing only |
| **AzerothCore v3.0.0** | Official historical `v3.0.0` tag | Compatibility/testing only |
| **AzerothCore custom** | Your chosen AzerothCore-compatible repository and Git ref | Forks, tags, or exact commit pins |
| **Playerbots stable** | `mod-playerbots/azerothcore-wotlk` `Playerbot` plus `mod-playerbots` `master` | Recommended Playerbots server |
| **Playerbots testing** | Playerbots testing core/module branches | Development/testing |
| **Playerbots legacy v16** | Playerbots v16-compatible core/module branches | Legacy compatibility |
| **Playerbots custom** | Your chosen paired Playerbots-compatible core and module refs | Advanced use |

Playerbots is not a normal drop-in module. Its project requires a custom AzerothCore core branch, so use one of the Playerbots distribution choices instead of adding `mod-playerbots` through **Additional AzerothCore Modules**.

The historical AzerothCore v3/v4 choices are convenience compatibility targets. They may require additional work as modern compilers and dependencies change. For a new server, use rolling master unless you specifically need an older core.

## 4. Run the first Update

Press **Update** in AMP.

The first update performs substantially more work than a typical game-server update. It can:

1. Download the selected AzerothCore source tree.
2. Download the compatible Playerbots module when a Playerbots distribution is selected.
3. Download any repositories listed under **Additional AzerothCore Modules**.
4. Download and initialize the portable Oracle MySQL installation.
5. Verify the bundled MySQL headers/client library and required symbols.
6. Configure CMake with explicit paths to that same bundled MySQL installation.
7. Verify CMake did not select a distro `libmysqlclient`/MariaDB compatibility library.
8. Compile AzerothCore.
9. Install the resulting binaries and verify their runtime MySQL linkage.
10. Download/install the selected AzerothCore client-data package.

Later updates are normally incremental. The template triggers a clean build when structural settings such as the distribution, module list, build type, or CMake options require one.

Do not interrupt the first compile unless it is clearly failing. If Update fails, inspect the update output in AMP; the troubleshooting section below covers the most common causes.

## 5. Configure the realm address

AzerothCore advertises a realm address to the WoW client. That address must be reachable by the players using the server.

### Internet server

Use **Automatic External IP** when the AMP host has a normal public IP and players connect directly over the internet.

Forward these TCP ports from your router/firewall to the AMP host unless you changed them:

```text
3724/TCP  Authentication
8085/TCP  World server
```

### DNS name or custom public address

Select the manual realm-address option and enter a hostname such as:

```text
wow.example.com
```

The hostname must resolve to the public address that ultimately reaches AMP.

### LAN players

Set **Realm Local Address** to the AMP host's LAN address, for example:

```text
192.168.1.50
```

This lets local clients connect directly instead of relying on router hairpin/NAT loopback behavior.

### VPN or private network

Use the VPN/private address as the manual realm address when every client connects through the same private network.

### Proxy Protocol

The template exposes Proxy Protocol v2 support because AzerothCore supports it on its network listeners. Leave it **disabled** unless a compatible TCP proxy/load balancer is explicitly configured to send Proxy Protocol v2. Enabling it for direct WoW clients will break connections.

## 6. Start the server

After Update finishes successfully, press **Start**.

The launcher starts the components in order:

1. Instance-local MySQL
2. Database initialization/update as needed
3. `authserver`
4. `worldserver`

AMP marks the instance Ready from AzerothCore's actual worldserver startup output.

The AMP console is connected to `worldserver`, so normal AzerothCore console commands can be entered directly from the panel.

## 7. Create your first account

After the worldserver is Ready, create an account from the AMP console:

```text
account create FRIENDADMIN A-STRONG-PASSWORD
```

To grant administrator/GM permissions:

```text
account set gmlevel FRIENDADMIN 3 -1
```

Useful console commands include:

```text
server info
server debug
account online list
saveall
help
```

Do not use a weak password simply because the realm is private. If the authentication port is reachable from the internet, it will receive unsolicited traffic eventually.

## 8. Configure the WoW 3.3.5a client

On each client, find the locale-specific `realmlist.wtf`, commonly:

```text
World of Warcraft/Data/enUS/realmlist.wtf
```

Set it to the same hostname or address that the server advertises:

```text
set realmlist your.server.address
```

Examples:

```text
set realmlist wow.example.com
```

or for a LAN-only server:

```text
set realmlist 192.168.1.50
```

If authentication succeeds but the realm cannot be entered, the advertised realm address is one of the first things to verify.

## 9. Online-player tracking in AMP

The template uses AzerothCore's own player login/logout messages to populate AMP's online-user list.

For real clients, AzerothCore exposes:

- Character name
- Account ID
- Remote IP/endpoint
- Login and logout events

AMP uses those events to add and remove players from its active-user view.

Playerbots create internal sessions without a real network endpoint. The AMP matching expression requires a non-empty endpoint, so random bots and controlled bots are intentionally excluded from the human online-player list.

When a real player is online, AMP can offer player actions such as **Kick**, **Ban 1 hour**, and **Ban 1 day** using AzerothCore's normal console commands.

## 10. Optional AMP chat feed

**Enable AMP Chat Feed** is disabled by default.

When enabled, the template turns on AzerothCore chat logging and routes supported chat events into AMP so administrators can see activity such as say, yell, party, raid, guild, channel, and whisper messages.

This can expose private conversations to AMP administrators. Only enable it when that behavior is appropriate for your server and understood by the people playing on it.

Addon protocol traffic is intentionally excluded from the activity feed.

## 11. Playerbots setup

For the easiest Playerbots setup, select **Playerbots stable** before running Update.

Common AMP settings include:

- Random Bot Autologin
- Minimum / Maximum Random Bots
- Disable Bots Without Real Players
- Login / Logout delays around real-player activity
- Maximum controlled bots
- AddClass account pool
- Random-bot account count
- Altbot autologin
- Account, guild, and trusted-account bot permissions
- Random-bot processing interval
- Random guild count and size
- Bot invitations, chat, emotes, and broadcasts

Start conservatively. Hundreds of active bots can substantially increase CPU load, memory use, startup time, and database activity.

The upstream Playerbots documentation is available at:

https://github.com/mod-playerbots/mod-playerbots/wiki

## 12. Add other AzerothCore modules

There is no custom AMP mod-store provider for AzerothCore modules in this template. Source modules can still be managed from **Additional AzerothCore Modules**.

Enter comma-separated GitHub repositories:

```text
azerothcore/mod-autobalance@master,azerothcore/mod-individual-progression
```

Supported forms are:

```text
owner/repository
owner/repository@branch
owner/repository@tag
owner/repository@commit-sha
```

A module without an explicit ref follows the repository's default/current HEAD.

Changing the module list causes the template to update the source tree and rebuild the server as needed.

Again, do **not** add `mod-playerbots` this way; choose a Playerbots distribution so the required matching core is used.

## 13. Useful AMP integration settings

The template exposes more than just launch arguments. Depending on the selected core, AMP can manage common settings for:

- Realm type and population limit
- MOTD and login information
- XP, money, item-drop, reputation, honor, and arena rates
- Starting level/money and cinematics
- Creature health/damage scaling
- Instance restrictions
- Cross-faction features
- Character save intervals
- Warden and client-version checking
- Wrong-password protection
- IP/proxy logging behavior
- Network and worker threads
- Compression
- MySQL memory allocation
- Playerbots behavior

The full upstream files remain available in the instance under the installed configuration directory for settings that are not represented in AMP.

## 14. Important instance paths

The template keeps its persistent state under the AzerothCore AMP instance directory. Important locations include:

```text
source/           AzerothCore source checkout
source/modules/   source modules
build/            CMake build tree
dist/             installed AzerothCore runtime
mysql/            portable MySQL installation
mysql-data/       MySQL data directory
logs/             server logs
temp/             temporary runtime files
state/            template installation/build state
```

Exact contents may evolve with the template, but the goal is to keep everything necessary for the realm inside the AMP instance's persistent storage.

## 15. Updating AzerothCore

For a rolling-master server:

1. Stop the instance.
2. Take a backup or snapshot.
3. Press **Update**.
4. Review the update/compile output.
5. Start the instance and confirm database updates complete normally.

For a pinned tag or commit, Update keeps using the selected ref until you change it.

Changing between normal AzerothCore and Playerbots is a larger structural change than a normal update. Back up first. Database/module schema differences can make downgrades or switching forks unsafe.

## 16. Backups

Back up the entire AMP instance before major upgrades, distribution changes, or experimental module changes.

At minimum, preserve:

- MySQL data
- AzerothCore configuration files
- Module configuration files
- The selected source/module refs

An AMP instance backup/snapshot of the whole persistent directory is preferable because it keeps the database and runtime configuration together.

For a live server, stop the instance before taking a raw filesystem copy of the MySQL data directory unless you are using a database-aware backup method.

## 17. Troubleshooting

### AzerothCore does not appear in Create Instance

- Confirm `RyanTheTechMan/AMPTemplates` is present in **Configuration Repositories**.
- Click **Fetch Latest** again.
- Refresh the AMP page.
- If testing a branch, ensure the repository entry includes `:branch-name`.

### Update fails during compilation

Check the first compiler/CMake error in AMP rather than the final summary line.

Common causes include:

- Not using the required container environment
- Insufficient RAM causing the compiler to be killed
- Insufficient disk space
- A third-party module that no longer compiles against the selected core ref
- A historical v3/v4 core that is incompatible with the current toolchain
- Custom CMake options that are no longer valid

Temporarily remove additional modules and retry a clean rebuild if the failing file comes from `source/modules`.

### Linker error: `mysql_stmt_bind_named_param`

Current AzerothCore/Playerbots can use MySQL 8.4 client APIs such as `mysql_stmt_bind_named_param`. Template version 3 deliberately prevents the MySQL headers from one installation being combined with `libmysqlclient` from another.

If you see an error similar to:

```text
undefined reference to `mysql_stmt_bind_named_param'
```

verify that the instance is using `cubecoders/ampbase:debian`, fetch the current template, and run **Update** again. The installer should now stop *before compilation* if CMake does not resolve both the headers and client library from the instance-local `mysql/` directory. On a fresh instance, do not add `default-libmysqlclient-dev` or `libmysql++-dev` manually.

### MySQL will not start

Check AMP's console/update output for the MySQL error. Common causes are:

- The instance was interrupted during initial database creation
- Files are not writable inside the container
- The container ran out of memory or disk
- A previous unclean stop left stale runtime files

Avoid deleting the MySQL data directory unless you intentionally want to reset the realm database.

### Client cannot connect to authentication

Verify:

- `3724/TCP` (or your configured auth port) is listening/forwarded
- The client `realmlist.wtf` uses the correct address
- A host firewall is not blocking the port
- Proxy Protocol is disabled unless a compatible proxy is actually in use

### Client authenticates but cannot enter the realm

Verify:

- `8085/TCP` (or your configured world port) is reachable
- The realm's advertised public address is correct
- **Realm Local Address** is correct for LAN clients
- DNS resolves to the intended host
- The client is a compatible 3.3.5a build

Use:

```text
server info
```

and inspect the `realmlist` entry if necessary.

### AMP does not show an online player

First confirm the player has fully entered the world, not merely reached the character-selection screen.

Then inspect the worldserver console for an AzerothCore login line similar to:

```text
Account: 1 (IP: 192.0.2.10) Login Character:[Example] (...) Level: 80
```

The AMP online-player matcher depends on the real player endpoint being present. Playerbots intentionally do not match.

### Player stays listed after disconnecting

Look for the corresponding AzerothCore logout event in the worldserver console. If the server crashed or was force-killed, AMP may not receive a normal logout line; restarting the instance clears stale runtime state.

### Chat feed is empty

Confirm **Enable AMP Chat Feed** is enabled and restart the instance so the logging configuration is regenerated. Then send a normal say/channel message from a real player.

### Playerbots compile fails

Do not mix arbitrary Playerbots core and module refs. Use one of the paired distributions unless you know the custom refs are compatible.

The Playerbots project explicitly requires its custom AzerothCore branch:

https://github.com/mod-playerbots/mod-playerbots

### Server uses too much CPU or RAM with Playerbots

Reduce **Maximum Random Bots** first. Also consider:

- Lower bot processing counts per interval
- Longer manager intervals
- Disabling bot activity when no real players are online
- Increasing AMP container memory
- Giving MySQL a reasonable but not excessive buffer pool

### The old v3/v4 selections fail

Those options are historical compatibility targets, not guaranteed modern builds. Use rolling master for a new server unless an older core is specifically required.

## 18. Upstream documentation

AzerothCore installation and Linux requirements:

- https://www.azerothcore.org/wiki/installation
- https://www.azerothcore.org/wiki/linux-requirements

AzerothCore documentation:

- https://www.azerothcore.org/wiki/home

Playerbots:

- https://github.com/mod-playerbots/mod-playerbots
- https://github.com/mod-playerbots/mod-playerbots/wiki

## 19. Reporting template problems

When reporting a problem with the AMP template, include:

- AMP version
- Selected AzerothCore distribution
- Core ref/commit if custom
- Playerbots ref if applicable
- Additional module list
- The first relevant error from Update or the server console
- Whether AMP is running on Linux or Windows with Docker

Do not include database passwords, account passwords, or other secrets in public issue reports.
