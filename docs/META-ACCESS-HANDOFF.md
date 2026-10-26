# Meta access for SalesFixr — instructions for the Page owner

**Who this is for:** the person who owns the Facebook Page and Instagram account the
booking assistant will answer: my friend for the portfolio demo, or a client.
**What it does:** gives the SalesFixr automation permission to read and answer
**Messenger and Instagram DMs** for one Page, **without anyone sharing a password or
logging into anyone else's account.**

It uses a Meta **System User**: a non-human account inside your Business Manager. It
has no password and no login, only a token that you can revoke at any time in one
click. This is how Meta expects agencies and automation tools to connect.

**Do this on a computer** (business.facebook.com and developers.facebook.com are hard
to use on a phone). About 30 minutes.

There are two versions. Pick yours:

- **Part A — Portfolio / demo** (my friend): you create the app and the token on your
  side and send me 4 values.
- **Part B — Client**: you add my agency's Business Manager as a **partner**. I create
  the token on my side. You send me nothing secret.

---

## Before anything: 4 checks (5 minutes, everyone)

If any of these is wrong, nothing later will work, and the errors are confusing.

| # | Check | How |
|---|---|---|
| 1 | Instagram is a **Business** or **Creator** account (not personal) | Instagram app → Profile → ☰ → **Settings and activity** → **Account type and tools**. It must say Professional. If not: **Switch to professional account** → Business |
| 2 | Instagram is **linked to the Facebook Page** | Facebook → the Page → **Settings** → **Linked accounts** → Instagram shows your account. If not: **Connect** |
| 3 | The Page and Instagram are in **your Business portfolio** | **business.facebook.com/settings** → **Accounts** → **Pages** (your Page is listed) and **Instagram accounts** (yours is listed). If not: **Add** → *Add a Page* / *Connect an Instagram account* |
| 4 | Instagram **allows access to messages** for connected tools | Instagram app → ☰ → **Settings and activity** → **Messages and story replies** → **Message controls** → **Connected tools** → **Allow access to messages: ON** |

---

## Part A — Portfolio / demo (asset owner creates the token)

### A1. Create the developer app

1. **https://developers.facebook.com** → **Get Started** if you've never used it (verify
   phone + email, choose *Developer*). Otherwise **My Apps**.
2. **Create app** → App name: `SalesFixr Demo` → your email → **Next**.
3. **Use cases:** tick **Engage with customers on Messenger from Meta** → **Next**.
4. **Business:** select **your Business portfolio** (the one from check 3) → **Next** →
   **Go to dashboard**.
5. **Use cases** → **Customize** on the Messenger card → in the permissions list click
   **Add** next to `instagram_manage_messages`, `instagram_basic` and
   `pages_read_engagement` (the others are already there).
6. **App settings → Basic:** note the **App ID** and the **App secret** (*Show*).

Leave the app in **Development** mode. That's correct for a demo: no Meta review needed.

### A2. Create the System User and its token

1. **business.facebook.com/settings** → **Users** → **System users** → **Add**.
   - Name: `n8n-automation` · Role: **Admin** → **Create system user**.
2. With `n8n-automation` selected → **Assign assets**:
   - **Apps** → `SalesFixr Demo` → **Full control** (Manage app) → **Assign**.
   - **Pages** → your Page → **Full control** (everything) → **Assign**.
   - **Instagram accounts** → your account → **Full control** → **Assign**.
3. **Generate token** → App: `SalesFixr Demo` → Token expiration: **Never** →
   tick exactly these permissions:

   `pages_show_list` · `pages_read_engagement` · `pages_manage_metadata` ·
   `pages_messaging` · `instagram_basic` · `instagram_manage_messages` ·
   `business_management`

   → **Generate token** → **Copy** (it's shown once; you can generate another later).

### A3. Let me test from my own accounts (optional)

In Development mode the bot only answers people who have a role on the app.

- **Facebook:** developers.facebook.com → your app → **App roles** → **Roles** →
  **Add People** → **Tester** → my Facebook name. (I accept it under my profile icon
  on developers.facebook.com; until then it shows *Pending* for you.)
- **Instagram:** same page → **Add People** → **Instagram Tester** → my Instagram
  username. (I accept in Instagram → Settings → **Apps and websites** → *Tester
  invites*.)

Otherwise I'll test by messaging the Page from your own accounts.

### A4. Send me these 4 values

| Value | Where |
|---|---|
| App ID | A1 step 6 |
| App secret | A1 step 6 |
| System user token | A2 step 3 |
| Page ID | business.facebook.com/settings → Accounts → **Pages** → click the Page (the number under its name) |

Send the App secret and the token through a **password manager's share feature** or a
**one-time secret link** (one that deletes itself after it's opened), not as a plain
chat message. Never send a password or a login code. I don't need them, and nobody
should ever ask for them.

**To revoke at any time:** business.facebook.com/settings → System users →
`n8n-automation` → **Revoke tokens** (or remove its assets). The automation stops
immediately; your accounts are untouched.

---

## Part B — Client (partner access, nothing secret is sent)

You keep full ownership. My agency's Business Manager gets permission to manage
**messages** for your Page and Instagram, which you can remove at any time.

1. Do the **4 checks** above.
2. I'll send you my agency's **Business ID** (a number).
3. **business.facebook.com/settings** → **Users** → **Partners** → **Add** →
   **Give a partner access to your assets** → paste the Business ID → **Next**.
4. Assign:
   - **Pages** → your Page → **Messages** and **Content**/*Everything* as I ask (for a
     booking assistant: full control of messaging is enough) → **Save**.
   - **Instagram accounts** → your account → **Messages** / full control → **Save**.
5. Tell me it's done. Send me your **Page ID** (not secret).

From here everything happens on my side: my System User gets your Page and Instagram,
and a token is generated for my agency's app. **To revoke:** Business settings →
Partners → my agency → **Remove**.

> **For real patients, the app must be Live.** In Development mode only people with a
> role on the app get answers. Going live requires Meta **App Review** for the
> messaging permissions (a short screen recording of the bot in use, a public privacy
> policy URL) and **Business Verification** of my agency's Business Manager. That's a
> one-time process on my side and takes days to a few weeks, so it's planned before a
> client launch, not after.
