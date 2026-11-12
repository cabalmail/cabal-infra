# Cabalmail User Manual

Cabalmail gives you one inbox and as many addresses as you want. Create a fresh address every time you hand out your contact information; when one starts attracting spam, revoke it and the spammers lose the ability to reach your servers at all.

Use the **native Apple apps** — iPhone, iPad, Mac, and Apple Vision Pro, plus an Apple Watch companion — for day-to-day mail. They carry the full experience: mail, addresses, folders, search, drafts. Android and Linux clients are planned.

**Webmail** at `https://admin.example.net/` (substituting your control domain) remains supported, but the admin site is best reserved for account signup, password recovery, and — for administrators — the admin dashboard.

Generic mail clients (Thunderbird, Apple Mail, Outlook, …) cannot be connected; there are no public IMAP or SMTP endpoints ([details](./mua_setup.md)).

## Accounts and signing in

**Creating an account.** Use the web app's Sign up form, or Create Account on the sign-in screen of the Apple or Android apps (enter your server's control domain first). If your operator configured an invitation code, you must enter it. After sign-up, wait for an administrator to approve your account.

**Signing in.** Username and password, then — if you are enrolled in two-factor authentication — a 6-digit code from your authenticator app (the Apple apps submit it automatically when the sixth digit lands). Operators can make two-factor mandatory; when it is, signing in without an enrolled authenticator walks you through enrollment (scan the QR code, confirm the first code) before you can proceed. You can also enroll voluntarily from the web app.

**Recovery.** Password reset is self-service: the code goes to your verified recovery email, or by SMS to your phone where the operator has SMS configured. Where SMS is configured the recovery email is optional; you can add or change it under **Security** in the web app, or **Settings › Account › Recovery Email** in the Apple and Android apps. Without either, ask your administrator. If you lose your authenticator, an administrator must reset your MFA.

## Addresses

Every address lives on its own subdomain (`foo@bar.example.com`) and delivers to your one inbox.

<img src="./app_screens/ios_addresses.png" alt="Address list on iPhone" width="300" />

- **Create** a named address, or use **Random** for signup forms. Record who got it in the comment field — that is how you find it later. New addresses are usable within a minute or two.
- **Copy** an address to the clipboard from the list; **favorite** the ones you use often (favorites are per-user).
- **Suspend** an address to make it stop receiving, reversibly: its DNS records are withdrawn but the address is kept and can be **reinstated** later. On the Apple apps, suspend/reinstate are swipe actions on the address list.
- **Revoke** an address to delete it permanently — the address, and its DNS, are gone for good. You can also revoke the receiving address right from a message you are reading.
- **Shared addresses.** An administrator can assign one address to several users; each assignee receives its mail in their own inbox.
- Administrators may limit which mail domains you can create addresses on.

## Mail

<img src="./app_screens/ios_inbox.png" alt="Inbox on iPhone: filter pills, sender avatars, sort and select controls" width="300" />

- **Folders.** Create, delete, and subscribe to folders; favorites sort to the top of pickers. Subscribed folders are refreshed proactively; unsubscribed folders load only when you open them. The folder name at the top of the message list is a menu: tap it to jump to another subscribed folder, or to any other folder under "Other folders". Two pills above the folder list narrow it, **Subscribed** and **Unread**, in any combination; turn both off to see every folder (the folder you are reading always stays listed, and so does INBOX under Unread, even with nothing unread). Choosing Unread on its own fetches a count for every folder, since unsubscribed folders are not tracked otherwise. The pill choice is remembered on each device. Nested folders can be expanded or collapsed at once from the buttons beside the pills (and, on the Mac, from the Mailbox menu).

  <img src="./app_screens/ios_folders.png" alt="Folder list on iPhone: All, Subscribed, and Unread pills above the folder tree" width="300" />
- **Reading.** Remote images are blocked by default (load them per message; loading can let a sender track you). A sender-authentication line shows the SPF/DKIM/DMARC verdicts stamped by your own relay, or "not verified" when there are none. Sender avatars come from your Contacts, the sender's published BIMI logo, or initials.

  <img src="./app_screens/ios_reader.png" alt="Reading a message on iPhone: SPF, DKIM, and DMARC verdicts under the sender" width="300" />
- **Search** is full-text across folders (Trash excluded). Text inside attachments is not indexed.
- **Triage.** By default, swipe right to toggle read/unread and swipe left to archive (inside Archive, the same gesture restores). Settings → Actions lets you bind either edge to toggle read, toggle the default flag, dispose, or nothing, with a separate pair for feed items. Multi-select for bulk move, flag, read/unread, and delete. Narrow the list with the Unread and Flagged pills (tap a lit pill again to show everything) and change the sort order from the toolbar.

  <img src="./app_screens/ios_swipe.png" alt="Swiping a message row left on iPhone reveals the Archive action" width="300" />
- **Flags.** Settings → Flags is one list: the built-in flag, named "Flagged" until you rename it, and up to 20 flags of your own, each with a name and a color. A message shows a dot for each of its flags on its row and a named chip in the reader, in the list's order. The first flag in the list is the **default flag**: the flag swipe, the Flag button, and the flag shortcuts (⇧⌘8 in the list, ⇧⌘L in the mail reader) set and clear it, and they carry its name once it is anything but the built-in flag still called "Flagged". To choose another, use Make Default in that flag's menu (touch and hold it, or right-click on the Mac), which moves it to the top of the list. Any flag can be set from the Flags menu on a message or on the reader's Flag button. In the Apple apps a feed item takes the same flags: its row shows the dots and its reader names them under the title, the Flags menu is on the item's row and on the feed reader's Flag button (its arrow on the Mac; touch and hold it elsewhere), and the feed swipe, ⇧⌘8 and the feed reader's Flag button set and clear the default flag. A flag set on a feed item while offline is sent when the connection returns. A flag of your own stays in the list until you delete it; there is no switch to turn one off. Deleting a flag leaves its tags on the messages and feed items that carry them, shown by the flag's slot id, and they can still be removed. A new flag takes the first free slot, so anything still tagged with a flag you deleted shows under the next flag you create; take the old tags off first if that matters. The built-in flag cannot be deleted: it offers Reset to Default instead, which gives it back its original name, color and first place. The Flagged pill and the search filter find the built-in flag only, under whatever name you gave it. The Android app has the same list under Settings → Flags: there, Make default is a button in the flag's own dialog, the reader's flag button is a star, the shortcut is Ctrl+Shift+L, and a feed item has the built-in flag only.
- **Rules.** Settings → Mail rules: ordered rules applied to every arriving message — file into a folder, flag, mark read, forward, auto-reply, or delete, with conditions on From / To / Cc / Subject / Body. Edits auto-save and follow your account across devices. See [Mail rules](./mail-rules.md) for the full behavior, limits, and the "why didn't my rule fire" checklist.
- **Trash.** Deleting moves a message to Trash. Permanent deletion — per message or Empty Trash — happens only inside Trash and cannot be undone.
- **Drafts** autosave and sync through the Drafts folder: start a reply on one device, finish it on another.
- **Compose** supports rich text and attachments; replies pick the From address and recipients from the original message, and forwards carry the original attachments.

## Siri and Shortcuts (iPhone and iPad)

Four intents work with Siri, the Shortcuts app, and Spotlight: mint a random address (copied to the clipboard), create a named address, check the inbox (unread count and latest senders), and open a folder by name. When invoked by voice, iOS requires one tap ("Continue") before the app may write to your clipboard.

## Apple Watch

The Watch companion manages addresses only — mint, list, and revoke from the wrist, with a large-type view for reading an address to someone. It installs alongside the iPhone app.

## Contacts (Apple apps)

At first sign-in the app asks for Contacts access (optional). Contact names and photos label message lists and avatars, and compose autocompletes recipients from your contacts; you can add a correspondent to Contacts from a message header. Lookups happen on your device — no contact data is ever sent to the server.

## Administration

Administrators are members of the `admin` group in the Cognito user pool. Granting that membership is done in the AWS Cognito console (add user to group) — the one administrative act still performed in AWS. Everything else is in the web app, which shows admins additional views:

- **Users** — approve pending sign-ups, disable, or delete accounts.
- **Addresses** — see every address in the system, create addresses on behalf of users, and assign an address to one or more users.
- **Domain access** — restrict which mail domains each user may create addresses on.
- **DMARC** — browse aggregate reports, auto-ingested every six hours from the system's report mailbox.
- **CAA** — review certificate-issuance violation reports ([details](./caa.md)).
- **DNS** — per-address health check with a Repair button that republishes missing records. Apex-domain problems are flagged but never auto-repaired.

Operators can require two-factor authentication for admins or for all users; see [GitHub setup](./github.md) for the enforcement variables and [operations](./operations.md) for day-to-day system care.
