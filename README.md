# LOTUS ORDERS v1.9

A shared weekly order list for Raj, his brother and the manager. There are no accounts and no app store, and it costs $0 to run.

## How it works

| Action | What happens |
|---|---|
| Type a quantity | The item goes **on the order** (yellow) |
| Tap a product name | Puts the item on the order with no quantity. Tap the name again to take it off. |
| Tap ○ | Marks the item **done ✓** (green, crossed out) |
| **Couldn't get** (button on each item on the order) | Marks it out of stock (grey). It carries over to next week automatically (↻ From last week). |
| **All / On order / Left to do** | Filters the list. Use *Left to do* while shopping or receiving. |
| **Send Order** | Asks to confirm, then alerts everyone else: "🛒 Order ready from Raj · 12 items". Tapping **View** on that alert opens *Left to do*. |
| **Rebuild** | Closes the week into **History** and starts a new blank week for everyone. Couldn't-get items carry over, and this week's quantities show as "Last: 5" hints. **Undo** shows for 20 seconds, and works for up to 15 minutes. |
| **History** | Past weeks (who sent, who finished, what was out) and **Usage** per item over the last 8 weeks. |
| **Owner PIN** (⚙︎ Settings) | When set, Edit List, Rebuild, Undo and list restore/reset need the PIN. Forgot it? In Supabase → SQL Editor run `select public.lotus_reset_pin('your-store-code');` |
| **Use last order** | Fills in last week's quantities so you only adjust them. |
| **Edit List** | Add, rename, remove, reorder and re-categorize products. Changes reach every phone. |

**Alerts (banners at the top of the app):**
- 🛒 **Order ready**: someone tapped Send Order.
- ✓ **All items done**: every item on the order is checked off.
- 🟡 **"Manager updated the order"**: shows what other people added, removed, finished, or rebuilt since you last looked.

Banners appear within about 8 seconds while the app is open, and immediately when you open it. They are in-app alerts, not lock-screen notifications.

---

## Deploy it (free, about 15 minutes, one time)

You need two free services:
- **GitHub Pages** hosts the app.
- **Supabase** is the shared database, so all three phones see the same list.

### 1. Put the app online (GitHub Pages)
1. On a computer, go to <https://github.com/new>. Name the repo `lotus-orders`, set it to **Public**, and click **Create repository**.
2. Click **uploading an existing file**. Drag in **everything inside** the `lotus-orders` folder (`index.html`, `app.js`, the `icons` folder, and the rest). Click **Commit changes**.
3. Go to **Settings → Pages → Build and deployment**. Set Source to **Deploy from a branch**, Branch to **main** and **/(root)**, then click **Save**.
4. After about a minute, your app is live at **`https://prabadelic.github.io/lotus-orders/`**.

Netlify works too. Drag the folder onto <https://app.netlify.com/drop>.

### 2. Create the shared database (Supabase)
1. Sign up at <https://supabase.com> (the GitHub login is fine). Click **New project**, give it any name, choose a region near Baltimore (East US), and pick any database password.
2. When the project is ready, open **SQL Editor → New query**, paste **all** of `supabase/setup.sql`, and click **Run**. You should see "Success".
3. Go to **Project Settings → API Keys** (or **Data API**) and keep two values handy:
   - **Project URL**, like `https://abcd1234.supabase.co`
   - **Publishable key** (`sb_publishable_…`) or the legacy **anon** key (`eyJ…`)

### 3. Connect your phone, then invite the team
1. On your iPhone, open the app URL in **Safari** and tap **⚙︎**.
2. Enter your name. Paste the Project URL and key, tap **Suggest** to get a store code, then tap **Create store**.
3. Tap **Copy invite link** and send it to your brother and manager on WhatsApp.
4. They open the link, and their phone connects automatically. They only need to type their name.

### 4. Make it an app icon (each phone)
In Safari, tap **Share → Add to Home Screen → Add**. It opens full-screen like a normal app and still works with no signal. Changes sync when the phone is back online.

> On iPhone, use Safari for this step. Other browsers can't add it as a full-screen app.

---

## Good to know
- **Security:** the database is locked. Phones can only call the app's functions, and every call needs the store code. Anyone who has the invite link can edit the list, so keep it in your team chat. To change the code, run `select public.lotus_change_code('old-code','new-code');` in the Supabase SQL Editor, then create a new invite.
- **Free tier:** Supabase pauses a free project after about a week with no activity. The GitHub Action in `.github/workflows/keepalive.yml` pings it every 3 days (and makes a tiny monthly commit so GitHub keeps the schedule running). If it ever pauses anyway, click **Restore** in the Supabase dashboard. Your data is kept.
- **Two people editing at once:** changes to different items are both kept. For the same item, the most recent change wins. If two people save the product list at the same time, the app asks which version to keep.
- **Updating the app:** upload the changed files to the repo again. Phones pick up the new version the next time they open the app online.
- **Optional:** to skip pasting the URL and key on your own phone, put them in `config.js`. The invite link carries them for everyone else either way.
