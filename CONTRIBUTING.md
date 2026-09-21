# Set up ClashKing for development

Follow these steps once. After that, you only need the commands at the bottom.
You will create your own Discord test bot and Clash API keys.

## 1. Install the tools

### Windows: use Ubuntu through WSL

WSL runs Linux tools inside Windows. You keep using Windows normally; Ubuntu is
just the terminal where you run the commands in this guide.

Open **PowerShell as Administrator** (right-click it in Start), then run:

```powershell
wsl --install -d Ubuntu-24.04
winget install -e --id Docker.DockerDesktop
```

Restart Windows. Open **Ubuntu 24.04** from Start and choose a Linux username and
password when asked. Password typing is invisible; that is normal. Open Docker
Desktop, finish its initial setup, then enable **Settings → General → Use the
WSL 2 based engine** and **Resources → WSL Integration → Ubuntu-24.04**. Apply changes.

From now on, run shell commands in **Ubuntu**, not PowerShell. You can reopen it
from Start or run `wsl -d Ubuntu-24.04` in PowerShell. Store the projects under
`~/ClashKing` inside Ubuntu, not under `/mnt/c`, for faster file updates.
See [Microsoft's WSL instructions](https://learn.microsoft.com/en-us/windows/wsl/install)
and [Docker's WSL settings](https://docs.docker.com/desktop/features/wsl/) if installation fails.

In **Ubuntu**, paste these commands:

```sh
sudo apt update
sudo apt install -y git curl ca-certificates gnupg unzip build-essential golang-go tmux util-linux lsof nano
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh -o /tmp/nvm-install.sh
bash /tmp/nvm-install.sh
source ~/.bashrc
nvm install 26
nvm alias default 26
go env -w GOTOOLCHAIN=go1.26.4+auto
go install github.com/pressly/goose/v3/cmd/goose@latest
echo 'export PATH="$HOME/go/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Install the tunnel tool:

```sh
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update
sudo apt install -y cloudflared
docker info
```

If `docker info` fails, reopen Docker Desktop and check its Ubuntu integration.
To browse the current Ubuntu folder in Windows Explorer, run `explorer.exe .`.

### macOS

Install Homebrew from <https://brew.sh> if needed, then in Terminal run:

```sh
brew install node@26 git go goose gnupg cloudflared tmux
brew install --cask docker
export PATH="$(brew --prefix node@26)/bin:$PATH"
```

Add that PATH line to `~/.zshrc` to keep it for new terminals. Open Docker Desktop
and finish its setup. Leave Docker running while developing.

## 2. Get the projects

Run the following in Ubuntu on Windows, or Terminal on macOS:

```sh
mkdir -p ~/ClashKing
cd ~/ClashKing
git clone https://github.com/ClashKingInc/DevKit.git clashking_schemas
npm install --global ./clashking_schemas/cli
clashking init .
clashking repos clone
```

If you already have the projects, set their paths in `.clashking/workspace.json`
instead of downloading them again. Install the JavaScript dependencies:

```sh
npm ci --prefix clashking_api
npm ci --prefix clashking_bot/worker
npm ci --prefix ClashKingDashboard
npm ci --prefix ClashKingApp/expo
```

Go downloads its dependencies when the services first start. If GitHub refuses
access to a private project, sign in with your authorized GitHub account first.

## 3. Fill in your settings

Open **`.clashking/local.env`** in your new folder. This is your one local settings
file. Never commit it, share it publicly, or replace the generated keys casually.

Create a test application in Discord's Developer Portal, invite its bot to your
test server, and fill in:

| Setting | What to enter |
| --- | --- |
| `DISCORD_CLIENT_ID` | Your test application's ID |
| `DISCORD_CLIENT_SECRET` | Its OAuth2 client secret |
| `DISCORD_BOT_TOKEN` | Its bot token |
| `DISCORD_PUBLIC_KEY` | Its public key |
| `COC_KEYS` | Your Clash API keys, explained below |
| `DATASET_R2_BUCKET` | Already set to `clashking-bucket`; leave it unchanged |
| `R2_ENDPOINT` | Paste the public bucket URL shared with you; no R2 account ID or access keys needed |
| `DATASET_DECRYPTION_KEY` | Backup decryption key supplied privately by a maintainer |

Keep the generated database settings unchanged. Docker containers are called
`clashking-timescale` and `clashking-valkey`. The database inside Timescale is
called `clashking_dev`. The commands start these automatically.

The public URL already points to the bucket, so don't add the bucket name to it.
The command downloads `database/latest.json` beneath that URL, then the encrypted
data file it names. The decryption key is still required to open the data.

### Get your Clash of Clans API key

1. Sign up or sign in at <https://developer.clashofclans.com>.
2. From the computer running this setup, run `curl -4 https://api.ipify.org` to see
   its public IPv4 address. This contacts a public IP lookup service.
3. In the developer site's account page, create a key, give it a name such as
   `Local development`, and enter that IP under allowed IP addresses.
4. Copy the generated key into `local.env` like this:

   ```dotenv
   COC_KEYS="paste-your-key-here"
   ```

   One key is enough. For multiple keys, separate them with commas, without spaces:
   `COC_KEYS="first-key,second-key"`. Do not include the word `Bearer`.

If you change networks, turn on a VPN, or your public IP changes, update the key's
allowed IP address. These are developer API keys, not a player's in-game API token.

## 4. Set up the required Cloudflare tunnel

**A Cloudflare tunnel is required.** It gives the local bot an HTTPS address that
Discord can reach. You need a domain in your Cloudflare account. If it is not
there yet, choose **Add a domain** in Cloudflare and follow the nameserver steps
at your domain registrar. Wait until Cloudflare shows the domain as active.

The examples below use `example.com`. Replace it with your domain everywhere.
Use new, unused names so you don't replace an existing website.

In your terminal, run:

```sh
cloudflared tunnel login
cloudflared tunnel create clashking-local
cloudflared tunnel route dns clashking-local local-api.example.com
cloudflared tunnel route dns clashking-local local-bot.example.com
cloudflared tunnel route dns clashking-local local-dash.example.com
```

The login command opens a browser. Sign in and select your domain. If WSL doesn't
open it, copy the printed link into your Windows browser. Creating the tunnel
prints an ID and the path to a `.json` credentials file. Keep both.

From `~/ClashKing`, run `nano .clashking/tunnel.yml`. Paste this, replacing the
ID, credentials-file path, and domain. Use the full credentials path printed by
cloudflared, such as `/home/YOUR_LINUX_USER/.cloudflared/TUNNEL_ID.json`:

```yaml
tunnel: TUNNEL_ID
credentials-file: /full/path/to/TUNNEL_ID.json
ingress:
  - hostname: local-api.example.com
    service: http://127.0.0.1:8787
  - hostname: local-bot.example.com
    service: http://127.0.0.1:8788
  - hostname: local-dash.example.com
    service: http://127.0.0.1:3002
  - service: http_status:404
```

In nano, press **Ctrl+O**, **Enter**, then **Ctrl+X** to save and close.
Run `realpath .clashking/tunnel.yml`. Copy its output into the `tunnelConfig`
field in `.clashking/workspace.json`, keeping the JSON quotes. Set these in `local.env`:

```dotenv
CLASHKING_API_ORIGIN="https://local-api.example.com"
CLASHKING_DASHBOARD_ORIGIN="https://local-dash.example.com"
```

Check the file with:

```sh
cloudflared tunnel --config .clashking/tunnel.yml ingress validate
```

It should say `OK`. `clashking up` will start this tunnel for you. The routes are:

| Address you choose | Destination on your computer |
| --- | --- |
| API | `http://127.0.0.1:8787` |
| Bot | `http://127.0.0.1:8788` |
| Dashboard | `http://127.0.0.1:3002` |

Do not expose the database or Valkey. Discord must be able to reach the bot URL
without a separate website login.

## 5. Get the sample data and start

Allow at least 60 GB of free disk space. Run:

```sh
clashking doctor
clashking data pull --replace
clashking up
clashking app start
```

The data command downloads the latest approved, compressed and encrypted backup
from the bucket's `database/` folder, checks it, and unlocks it with your env key.
**It replaces your active local data.** You only need it once, or when you explicitly
want a newer sample. Stop services and the App before running it again. It keeps
the previous database under another name for manual cleanup, which uses extra disk.

`clashking up` starts the database, cache, API, proxy, bot, Discord connection,
Dashboard, and tunnel. `clashking app start` starts Metro for the mobile app,
without opening a web app. Open your development build on the same network and
connect to Metro. Code changes then reload automatically; no restart is needed
for normal edits. Use `clashking app attach` to see Metro's QR code and controls.

You need a ClashKing **development build** installed on the device first; Metro
does not install it, and the standard Expo Go app is not enough for this project's
native modules. Windows cannot run the iOS simulator. Use a physical device with
an installed development build, or an Android development setup.

### Connecting a phone to Metro from WSL

On Windows 11 22H2 or newer, use WSL's mirrored networking so your phone can reach
Metro over your home network. In PowerShell, run `notepad "$env:USERPROFILE\.wslconfig"`.
Create the file if needed. Add these settings, preserving anything already there
and avoiding a second `[wsl2]` section:

```ini
[wsl2]
networkingMode=mirrored
```

Save, then run `wsl --shutdown` in PowerShell. This stops all WSL programs, so reopen
Docker Desktop and Ubuntu afterward. In **PowerShell as Administrator**, allow
only Metro's port through the WSL firewall:

```powershell
New-NetFirewallHyperVRule -Name "ClashKingMetro" -DisplayName "ClashKing Metro" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 7357
```

Restart with `clashking up` and `clashking app start` in Ubuntu. Keep the phone
and computer on the same trusted Wi-Fi. If the QR address is wrong, run `ipconfig`
in PowerShell and enter `http://YOUR_WIFI_IPV4:7357` in the development build's
server-address field. Do not open this port on your internet router.
These steps follow [Microsoft's WSL networking guide](https://learn.microsoft.com/en-us/windows/wsl/networking).
Windows 10 needs a separate port-forwarding setup; the phone connection above is
for Windows 11 and has not been tested on a Windows machine in this task.

## 6. Finish Discord setup

In the test application's OAuth2 settings, add your Dashboard HTTPS address plus
`/auth/callback` and the mobile callback `clashking://com.clashking.clashkingapp/oauth`,
then save. For example, your Dashboard callback is
`https://local-dash.example.com/auth/callback`.

With the services running, set Discord's **Interactions Endpoint URL** to your
bot HTTPS address plus `/interactions`. Then run:

```sh
clashking bot sync-commands
```

## Everyday commands

Run these from your workspace folder, with Docker Desktop open:

| What you want | Command |
| --- | --- |
| Start the local services | `clashking up` |
| Start mobile Metro | `clashking app start` |
| Restart Metro after settings change | `clashking app restart` |
| Ask the App to reload | `clashking app reload` |
| See Metro output or its QR code | `clashking app attach` |
| Check services / App | `clashking status` / `clashking app status` |
| Read errors | `clashking logs api` or `clashking logs bot` |
| Stop services / App | `clashking down` / `clashking app stop` |
| Replace data with the latest approved sample | `clashking data pull --replace` |

There are no daily database-management steps. Data remains after stopping services.
The database and cache stay running in Docker until you stop Docker or those containers.

## If something doesn't work

- Run `clashking doctor`, then check the affected service's logs.
- A Cloudflare error usually means the tunnel or its local service isn't running.
- “Invalid OAuth2 redirect_uri” means the exact login address is missing from Discord's settings.
- A Discord rate limit is separate from the gateway connection; avoid repeated login attempts.
- A data download error means the public bucket URL is wrong or its starter files are unavailable; no access keys are required.

This is still a local working setup, not a fully automatic installer. Automatic
updates and emoji syncing are not built yet. Game tracking scripts are not started.
Images, badges, and archived war files are still read from the live ClashKing sites.
Nothing here publishes code or changes production data.
