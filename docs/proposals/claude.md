# orch mobile M0: a simulated prototype (proposal, Claude)

Status: proposal for the owner, 10 Oct 2026. Independent of the Codex proposal. Nothing here changes the spec
(`orch-core/docs/architecture/orch-v2.md`, "spec") or the wire contract (`orch-relay/docs/protocol-v2.md`, "proto").
References: spec §n, proto §n, D-numbers, spikes S1/S2, issues `orch-mobile#n`.

**The phase in one sentence.** Build the real app (real Core, real protocol v2 suite 2, real custody, real
storage, real extensions) against an **in-process FakeRelay + FakeHost that speak the actual wire protocol**,
so that M1 swaps one transport object for `URLSession` and nothing above it changes. Demo mode on TestFlight
is the same binary pointed at the same fakes.

---

## 0. The ten choices that matter

1. **The seam is the relay wire, not a repository.** `RelayTransport` carries real `ORB2` envelopes, signed
   objects and Drop blobs. FakeRelay implements it in memory; FakeHost and FakePrimary sit behind it and do the
   host and primary side of proto §8.3/§8.4 with real crypto. Every byte the app produces in M0 is a byte the
   real relay will see in M1.
2. **FakeHost is held to the vectors, not to the app.** Its host-side constructions run `host_cases`,
   `pair_answers`, `cert_request`, `wk_grants`, `push.cases` in `swift test`, so the app and the fake cannot be
   wrong *together*.
3. **No root tab bar.** Home is one scrolling stack: a "Needs you" strip, workspace cards, Drop. A workspace
   opens a detail with a segmented control (Questions, Tickets, Files, Terminal later). This is spec §7's model
   and keeps workspace isolation visible.
4. **D49 is final.** No Face ID per signature anywhere (the spec §3/§7 text, the README and issues #3, #4, #7
   still say otherwise; §5 lists the fix). The sign sheet is the security moment: exact text, scroll-to-end,
   short arming delay, one tap.
5. **Two keychain access groups, least privilege.** `…orch.keys` (app + share extension: device keys, `WK_e`)
   and `…orch.push` (app + NSE: only `K_push(ws,e)`, pinned `wsk_pub`, display name). The NSE never sees
   `WK_e` or a device key.
6. **Per-workspace containers in the app's own sandbox, not in the App Group.** Raw SQLite3 (no GRDB, no
   SwiftData), `NSFileProtectionComplete`, excluded from backup, closed on lock. The App Group holds only the
   NSE replay table, the share targets list and the share outbox.
7. **Custody backend is chosen by build target, never at runtime.** Device: Secure Enclave, always (also in
   Demo). Simulator: software P-256 in the keychain. The software backend is not compiled into device builds.
8. **The share extension never needs the app's process.** It seals the object itself (DEK, `wk` wrap,
   `dk_sig` descriptor) into an App Group outbox; the app (or, in M1, the extension) uploads. Demo works
   because the in-process FakeRelay lives in the app.
9. **Honest push testing.** `simctl push` does not start the NSE (S2). The NSE logic lives in `OrchPush` and
   runs as a library in `swift test` and through an in-app injection hook in XCUITest; `simctl push` scripts
   cover delivery, the generic fallback text, foreground handling and tap routing. The NSE as its own process
   is an iPhone-session item.
10. **Zero third-party code in the binary.** Apple frameworks only. xcodegen as a dev tool, generated project
    gitignored (as in S2). Swift 6 language mode, complete concurrency checking.

---

## 1. Product and UX

### 1.1 Information architecture

```
Welcome (first run, no workspace)                      Demo banner (violet stripe) on every screen in Demo
└─ Home  (NavigationStack root)
   ├─ Needs you strip            → Needs you list (all workspaces, grouped) → Question → Sign sheet
   ├─ Workspace card × n         → Workspace
   │                                ├─ [Questions] → Question → Sign sheet
   │                                ├─ [Tickets]   → Ticket (read) · "New ticket" → compose → Sign sheet
   │                                ├─ [Files]     → File (QuickLook) · Send file
   │                                └─ [Terminal]  shown only if scopes ⊇ type; "Later" placeholder in M0
   │                                Workspace ⋯ menu → Workspace settings (notifications, members, epoch, Leave)
   ├─ Drop card                  → Drop (received across workspaces, sent, Send…)
   ├─ toolbar "+"                → Add workspace (Scan / Paste) → Pairing flow (full-screen cover)
   └─ toolbar gear               → Settings
Deep links: orch://pair#…, https://<relay>/pair#…  → Pairing flow
Notification tap (verified)                         → Workspace → item
```

Why no root `TabView`: the spec makes the workspace the unit of trust and storage (spec §7, D2). A global
"Questions" tab next to a global "Files" tab blurs which workspace an answer goes to. The one cross-workspace
view (Needs you) is kept because it is the phone's main job, but every row in it carries its workspace's rail
colour and name, and the sign sheet repeats the workspace. Rejected: a TIX-style 5-tab bar (Workspaces, Needs
you, Tickets, Files, Settings); it was designed for one account, not for n isolated workspaces.

### 1.2 Screens

**Welcome.** Orbit mark, one line ("Answer your workspaces from your phone. Everything is end-to-end
encrypted."), primary button *Scan pairing code*, secondary *Paste pairing link* (SwiftUI `PasteButton`, no
paste prompt), tertiary *Try the demo*. In an M0 TestFlight build, scan/paste are present but say "Pairing with
a real workspace comes with the relay" on use, unless the build flag `ORCH_LIVE` is set. No notification prompt
here.

**Scanner.** `AVCaptureMetadataOutput` (QR only) in a sheet, viewfinder corners in brand teal, torch toggle,
"Paste link instead". Rejected VisionKit `DataScannerViewController`: heavier, no gain for one QR type. The
camera permission string says why. The Simulator has no camera: the sheet shows the paste path only.

**Pairing flow** (full-screen cover, cannot be swiped away while a request is pending; a Cancel button is
always there). One view, driven by the device-side state machine of proto §8.3/§8.4:

| State | What the phone shows |
|---|---|
| `parsing` | Nothing visible; a bad link goes straight to *Link not valid* ("This isn't an orch pairing link, or it was cut off."). Parsing is strict per proto §8.3.1 (vectors `bridge.links`). |
| `cert_check` | Only when the phone already has a certificate for this `pk_pin`'s person. If it holds a certificate of *another* person: "This workspace belongs to someone else." Nothing is sent (proto §8.3.2). |
| `sending` | "Connecting to <relay host>…" |
| `pending` | Big 6-character code, grouped `K7Q MX2`, label **"Compare with the code on your Mac"**, a hint "Approve only if both codes match. Reject if they don't." and a spinner "Waiting for approval". |
| `cert_pending`, no challenge | First code **cleared** (proto §8.4 UI rules). Illustration of a second device, **"Open orch on <primary_label>"**, a 10-minute countdown ring. |
| `cert_pending`, challenge verified | A second code in a **visibly different frame** (info blue, key icon) labelled **"Compare with <primary_label>"**, hidden at `expires_ms`. |
| `approved` | "Fetching the workspace key…" (relay login, grant fetch and verify). |
| `done` | Workspace name and rail colour, "Added. Turn on notifications?" (pre-prompt, then the system prompt). |
| `rejected` / `expired` | "Not approved on <host>." / "Nobody approved in 10 minutes. Start again on your Mac." |
| `pairing_closed` or 60 s silence | "This link was already used by someone else. Reject it on your Mac." (proto §8.3.4) |
| **`not_my_key` alarm** | Full screen, danger colour, octagon icon, warning haptic: **"Stop: someone else is trying to pair with this link."** Steps: "Reject on your Mac. Don't approve any code. Make a new link." Only button: *Close*. Logged as reason code only. |
| `wsk_pin` / `pk_pin` mismatch, challenge failures | Treated like the alarm but worded "The answer didn't come from the workspace in the link." |

A passcode check runs before key creation (D49 class `WhenPasscodeSetThisDeviceOnly`): with no passcode the
flow stops at "Set a passcode on this iPhone to use orch."

**Home.**
- *Needs you strip* (only when n > 0): magenta mark, "3 need you", the oldest question's first line and
  workspace. Tap → Needs you list.
- *Workspace cards* (one per workspace, user-reorderable, max density 3 cards per screen on a 6.1" phone):
  left rail in the workspace hue; name (expanded width); host machine label; a status row of chips
  (`2 questions` magenta, `1 running` neutral, `Offline · 14:02` grey); **client-hosted banner** across the
  card top in orange "Hosted by Acme AG" (decided from the PK-signed delegation flag; "hosted by (unknown)"
  if the sealed name is empty; proto §7.1). It cannot be dismissed.
- *Drop card*: tray icon, "2 new files", last item name.
- *Removed tombstone* (after revoke or `not_member`): greyed card "Removed from <name>: this phone's data for
  it was deleted." with *Dismiss*. The data is already gone; only the id, name and reason survive until
  dismissed.
- Empty state (no workspace, not first run): "No workspaces. Pair one from orch on your Mac (Remote → Pair
  phone)." with the two pairing buttons.

**Workspace.** Large title = name, under it the host line and a connection chip (`Live` teal dot, `Offline as
of 14:02`, `Reconnecting`). A segmented control pinned under the title. The ⋯ menu: Workspace settings, Leave.

- *Questions*: open questions first (magenta mark), then "Answered recently" collapsed. Row: first line,
  ticket key, age. Empty: "Nothing needs you here." Offline: rows from the cached snapshot, banner "Saved copy ·
  answers are off until you're back" (TIX wording).
- *Question*: full text (the same safe-text renderer as the sign sheet), the ticket, options as large buttons,
  "Other answer" text field. Choosing an option opens the sign sheet. After a send: "Sent · waiting for the
  host", then "Applied" (success haptic) or the refusal: `already_answered` → "Answered on <device> at 14:02"
  (question greys out); `question_changed` → "The question changed. Read it again." and the view reloads with
  the changed lines highlighted.
- *Tickets*: list with status chips (dashboard statuses), filter by status (chips row), search. Ticket view is
  read-only (title, status, requirements, recent events). Toolbar "New ticket": title + requirements → sign
  sheet → `new_ticket` op. Start/move (Operate) is out of M0.
- *Files*: this workspace's Drop objects addressed to or from this phone: received (unread dot), sent, each
  with expiry ("expires in 3 d"); swipe to delete local copy; *Send file* (PhotosPicker, Files importer,
  Camera). Expired objects disappear on the next refresh.
- *Terminal*: only if the member scopes include `type`; M0 shows "Terminal comes later" with no controls.

**Sign sheet** (spec §7 "unlock sheet", TIX #97 / `unlock.js` as UI reference). A `.sheet` with
`.presentationDetents([.large])`, interactive dismiss disabled while armed:

```
 ┌────────────────────────────────────────────┐
 │ ▍orch-core  ·  Hosted by Acme AG            │  workspace rail + name (+ hosted marker)
 │ You are signing                              │
 │ ┌──────────────────────────────────────────┐ │
 │ │ Answer to "Ship L-0042 to staging?"       │ │  exact text, SF Mono for machine text,
 │ │ → Yes, ship it                            │ │  runs of ≥3 spaces / ≥2 blank lines drawn
 │ │ [… 4 spaces …]                            │ │  as marker chips, never as host text
 │ └──────────────────────────────────────────┘ │
 │ The text ends with: "…ship it"               │  tail, always shown separately
 │ 12 lines · 214 characters · hash 3f9a·c2e1   │  facts
 │ Signed by this iPhone ("Severin's iPhone")   │
 │ [ Sign and send ]        (armed after 0.8 s  │
 │                           and scroll-to-end) │
 │   Cancel                                     │
 └────────────────────────────────────────────┘
```

Rules carried from TIX `inspectText`: refuse text with invisible or look-alike spacing, more than 2 combining
marks in a row, over 40 lines or 2,000 characters ("The host sent text this phone can't check. Answer on your
Mac."); bidi isolation; the button arms only after 0.8 s *and* the text is scrolled to its end; one use. No
Face ID (D49): the button label is "Sign and send", never "Confirm with Face ID". The sheet is the only path
to `dk_sig`; nothing signs from notification data (S2 receiver rules).

**Needs you list.** Grouped by workspace (section header = rail + name), same rows as Questions.

**Drop.** Segments *Received* / *Sent*. Rows show the workspace, file name (from sealed metadata), size,
expiry. *Send…* → choose workspace (the share extension's picker, reused) → item → send. Personal space,
inbox claim, documents and links are P6 and not shown.

**Settings.**
- *This iPhone*: label (editable before first pairing; afterwards set on the primary), device id (short,
  monospaced, copyable), key custody ("Secure Enclave" / "Software key (Simulator)"), certificate person and
  expiry.
- *Workspaces*: list → Workspace settings: notifications on/off (registers or removes the `(device, ws)`
  push registration), scopes, epoch number and "keys held: epochs 3–4", members (count, labels as given by the
  host), **Leave workspace** (destructive).
- *Notifications*: system status (authorized, denied → "Open Settings"), token state.
- *Lost another device?* Explains revocation is done on the primary ("Revoke it in orch on <primary>"). The
  phone is never the primary in P4 (§5, gap G8).
- *Demo mode* toggle (see below), *Appearance* (System / Light / Dark), *About* (version, build, protocol v2
  suite 2, vectors hash), *Diagnostics* (reason-code log, redacted, share as file), *Reset this iPhone* (wipe
  all workspaces, keys, certificate; typed confirmation).

**Leave workspace** (D7, `orch-mobile#4`): confirmation dialog: "Leave <name>? This deletes its questions,
files and keys from this iPhone and stops its notifications. Your other devices keep access. Nothing on your Mac
changes." Order of operations: unregister push → deregister membership at the relay → delete keychain items →
delete container → remove from index → tombstone not shown (user-initiated). If the relay is unreachable the
local wipe still happens at once, and a "pending deregistration" record (ws id + session-less signed request)
is retried; local wipe never waits on the network.

**Being revoked or removed** (detected by a `not_member`/`revoked` refusal, a member list without this device,
or a relay 403): wipe immediately, then show the tombstone. Old content readable by old epochs is already gone
from this phone, so the honest-limit text belongs on the Mac, not here.

### 1.3 Demo mode

- Entered from Welcome or Settings. A separate **realm**: its own storage root, keychain service prefix,
  device identity and index. Turning Demo off wipes the realm. Live and demo data never mix, never appear on one
  Home.
- A violet 3-pt stripe under the status bar and a "Demo" chip in every navigation bar.
- Seed: two workspaces, "orch-core" (own Mac) and "Acme data platform" (client-hosted, "Hosted by Acme AG"),
  four questions (one long, one with odd spacing to show the sign sheet's markers), eight tickets, three files.
- **Simulated Mac panel**: a floating button (laptop symbol) opens a sheet that *is* the host and the primary:
  *Pair a new workspace* (shows the host screen: QR/link, the code, Reject/Approve with "I compared the codes"
  switch, then the primary's cert code and Confirm), *Ask a question*, *Answer on Mac* (→ `question.closed`),
  *Send a file to the phone*, *Rotate keys*, *Remove this phone*, *Scenario* (first-time vs existing
  certificate, primary offline, R1 attack, link already used). Every action goes through FakeHost → FakeRelay →
  the real client stack.
- Demo push: FakeHost seals a real push payload; the app runs it through `OrchPush` (the NSE's code) and posts a
  **local** notification with the verified content, `threadIdentifier` and `orch_key`. This is labelled as
  simulated in Diagnostics. Real APNs and the NSE process need the relay (M1).

### 1.4 Notification UX

- Permission asked after the first successful pairing, with a pre-prompt naming what arrives ("Questions from
  your workspaces, files, answers made elsewhere"). Denied → a quiet row in Settings, never a nag.
- Content (all produced by the NSE from a verified payload): title = workspace display name, subtitle by kind
  (Question, Ticket update, File, Answered elsewhere, From <peer>, Pairing), body = `label`. Fallback on any
  failure, timeout or missing key: `orch` / `New activity`, nothing else (S2).
- `threadIdentifier = ws` set locally; no `thread-id` from the relay (S2).
- No notification categories, no lock-screen actions (S2: nothing actionable rests on notification text).
- `question.closed`: remove delivered notifications whose `orch_key == "<ws>/<id>"`, then show "Answered on
  <device>" in the same thread (spec §6.3). Apple has no silent push, so the replacement is visible by design.
- Tap: the app re-opens `o` with `OrchPush` (or fetches from the host) and navigates only on success; otherwise
  it opens Home.
- Badge: set by the app on foreground from the reconciled open-question count; the relay never sets it.
- Privacy: when `scenePhase != .active` a blur overlay with the orbit mark covers the UI (app switcher
  snapshots would otherwise keep codes and questions).

---

## 2. Visual language: "Orbit, native"

Direction: the dashboard's *Orbit* identity (near-black surfaces, teal actions, restrained motion) translated
into iOS idioms rather than ported. Distinctive through three things only: **expanded-width SF for names and
titles**, **a workspace colour rail**, and **machine text set in SF Mono with marker chips**. Everything else
is stock SwiftUI (List, Form, sheets, SF Symbols) so it feels like an iPhone app, supports Dynamic Type and
VoiceOver for free, and ages with the OS.

Rejected: bundling Geist (dashboard) or Figtree/Manrope (TIX). Custom fonts need `relativeTo:` scaling work
for every style, look like a web app on iOS, and add a licence file for little gain. Also rejected: dark-only
(the dashboard's choice). A phone is used outdoors and in bed; it follows the system setting, with dark as the
reference design.

### 2.1 Tokens (`OrchUI/Tokens.swift`)

```swift
public enum OC {                           // colours, light / dark (asset catalog "Any, Dark")
  static let bg         = dyn(0xF2F3F5, 0x0E1014)
  static let surface    = dyn(0xFFFFFF, 0x15181D)
  static let surface2   = dyn(0xF7F8F9, 0x1C2027)
  static let line       = dyn(0xE1E4E8, 0x2A3038)
  static let lineStrong = dyn(0xC9CED4, 0x3A424D)
  static let text       = dyn(0x15171A, 0xE8EAED)
  static let textMuted  = dyn(0x495159, 0x9AA3AD)
  static let brand      = dyn(0x0A7F68, 0x2FC6A3)   // actions, links, focus, Live dot (≥4.5:1 on surface)
  static let onBrand    = dyn(0xFFFFFF, 0x06231C)
  static let you        = dyn(0xB8136A, 0xFF8FC4)   // "needs you": text/chips   (TIX --you-*)
  static let youMark    = dyn(0xE0287F, 0xF84A9B)   //            : dots, strip mark
  static let hosted     = dyn(0xB4530F, 0xF07A2E)   // client-hosted marker only (dashboard addon orange)
  static let ok         = dyn(0x008A6B, 0x4ADE80)
  static let warn       = dyn(0x7A4E00, 0xFBBF24)
  static let danger     = dyn(0xB42318, 0xF87171)   // alarm, destructive
  static let info       = dyn(0x1F5FD1, 0x60A5FA)   // the primary's cert code frame
  static let demo       = dyn(0x6D4AFF, 0xB392F0)   // demo stripe and chip, nothing else
  static func soft(_ c: Color) -> Color { c.opacity(0.14) }   // chip backgrounds (dashboard *-soft)
  // Workspace hues: index = workspace_id[0] % 6. Never magenta, orange, red or violet (reserved above).
  static let wsHues: [Color] = [dyn(0x0A7F68,0x2FC6A3), dyn(0x0369A1,0x38BDF8), dyn(0x4338CA,0x818CF8),
                                dyn(0x4D7C0F,0xA3E635), dyn(0x8A6A3B,0xD6B98C), dyn(0x475569,0x94A3B8)]
}
public enum OF {                           // type: system styles only, so Dynamic Type works
  static let display   = Font.largeTitle.width(.expanded).weight(.bold)
  static let wsName    = Font.title3.width(.expanded).weight(.semibold)
  static let section   = Font.headline
  static let body      = Font.body
  static let meta      = Font.footnote.weight(.medium).monospacedDigit()
  static let machine   = Font.callout.monospaced()                       // sign-sheet text, ids, hashes
  static let code      = Font.system(.largeTitle, design: .monospaced).weight(.semibold)   // SAS, cert code
}
public enum OS { static let s1 = 4.0, s2 = 8.0, s3 = 12.0, s4 = 16.0, s5 = 20.0, s6 = 24.0, s8 = 32.0 }
public enum OR { static let card = 16.0, control = 10.0, chip = 999.0, rail = 4.0 }  // .continuous corners
public enum OM {                           // motion
  static let standard = Animation.snappy(duration: 0.25)     // no bounce; the dashboard caps at 200 ms
  static let reveal   = Animation.easeOut(duration: 0.2)     // codes: crossfade only, never slide
  // Reduce Motion: opacity only. Security surfaces (pairing codes, alarm, sign sheet) never animate content.
}
```

Density: cards 20 pt padding, 12 pt gap; list rows system height (44 pt minimum tap); chips 22 pt high.
Shadows: none in dark, `0 1 3 rgba(21,23,26,.08)` on cards in light. Haptics: `.success` on applied decision
and on `done`, `.warning` on the alarm, `.selection` on segment change; none elsewhere.

### 2.2 Iconography

SF Symbols, hierarchical rendering, one symbol per concept: workspace `square.stack.3d.up`, host
`laptopcomputer`, question `questionmark.bubble`, tickets `list.bullet.rectangle`, files `doc.on.doc`,
terminal `apple.terminal`, Drop `tray.and.arrow.down`, sign `signature`, hosted `building.2`, pairing
`qrcode.viewfinder`, cert code `key.horizontal`, alarm `exclamationmark.octagon.fill`, offline `wifi.slash`,
demo `theatermasks`. App icon: the orbit (a ring with one dot) in teal on `#0E1014`; tinted and dark variants
from the same vector.

---

## 3. Architecture

### 3.1 Repository and targets

```
orch-mobile/
├── project.yml                 xcodegen; OrchMobile.xcodeproj is generated and gitignored
├── Core/  (SwiftPM package "OrchKit", platforms iOS 18, macOS 15)
│   ├── OrchProtocol    pure: cj + strict JSON, b64u/hex, suite 2 (strict verify, seal, SALTED-AEAD, HKDF),
│   │                   ORB2 envelopes, device-side pairing state machine, certs, grants, member lists,
│   │                   push open, Drop blob/meta/wrap/descriptor, question hash, safe-text inspector.
│   │                   No I/O, no keychain, no Foundation networking. Deterministic seams for vectors only.
│   ├── OrchCustody     DeviceCustody (SE / software), Keychain wrapper with access groups, SecretVault
│   ├── OrchStore       SQLite3 wrapper (~300 lines), Realm, WorkspaceContainer, wipe, App Group files
│   ├── OrchPush        NSE logic: PushPipeline (open → replay table → content), depends on OrchProtocol +
│   │                   a read-only push vault; kept tiny for the NSE's ~24 MB limit
│   ├── OrchClient      RelayTransport, BridgeSession, PairingCoordinator, WorkspaceSession, WorkspaceAPI,
│   │                   DropService, PushRegistry, Clock
│   ├── OrchFakeHost    FakeRelay (RelayTransport), FakeHost, FakePrimary, scenarios, seed, fake clock
│   ├── OrchUI          tokens, components (card, chip, code view, safe-text view, sign sheet)
│   └── Tests/          OrchProtocolTests (vectors), OrchClientTests (against FakeHost), OrchStoreTests,
│                       OrchPushTests, Vectors/vectors_v2.json + VECTORS.lock (orch-relay commit + sha256)
├── App/                OrchApp target (io.severin.orch): SwiftUI screens, AppModel, routing, demo panel
├── NotificationService/ OrchNotify (io.severin.orch.notify): ~40 lines calling OrchPush
├── ShareExtension/     OrchShare (io.severin.orch.share): SwiftUI composer, seals into the outbox
├── UITests/            OrchUITests (XCUITest)
├── AppTests/           hosted unit tests: custody (software + keychain), view models
├── tools/orch-fake     macOS CLI on OrchFakeHost: deterministic `.apns` files, pairing links for simctl
└── e2e/ios/            simctl scripts (push, share smoke), iPhone session checklists
```

Linkage: App → all modules; OrchNotify → OrchPush (+OrchProtocol); OrchShare → OrchProtocol, OrchCustody,
OrchStore (outbox only), OrchUI. OrchFakeHost is linked **only into the app** (Demo needs it on TestFlight);
it is never linked into an extension.

Rejected: one big app target with folders (no `swift test` on macOS, slow loop); a pure SwiftPM app (no
extensions, entitlements or XCUITest); Tuist (heavier tool, second config language); a committed `.xcodeproj`
(merge conflicts, S2 already chose xcodegen); a separate repo for Core (vectors and app move together).

### 3.2 Network isolation: the interfaces

```swift
public protocol RelayTransport: Sendable {                    // M0: FakeRelay. M1: HTTPRelayTransport.
  func challenge() async throws -> RelayChallenge                               // proto §12.2
  func login(_ signed: RelayLogin) async throws -> RelaySession                 // 15 min bearer
  func postPairing(ws: WorkspaceID, envelope: Data) async throws                // epoch 0, unauthenticated
  func pollPairing(ws: WorkspaceID, offer: OfferID, device: DeviceID, wait: Duration) async throws -> [Data]
  func post(ws: WorkspaceID, envelope: Data, _ s: RelaySession) async throws    // bridge request
  func poll(ws: WorkspaceID, _ s: RelaySession, wait: Duration) async throws -> [Data]   // response chunks
  func grants(ws: WorkspaceID, sinceEpoch: UInt32, _ s: RelaySession) async throws -> [SignedObject]
  func memberList(ws: WorkspaceID, _ s: RelaySession) async throws -> SignedObject
  func card(ws: WorkspaceID, _ s: RelaySession) async throws -> Card
  func registerPush(ws: WorkspaceID, token: Data, env: APNsEnv, _ s: RelaySession) async throws   // gap G6
  func unregisterPush(ws: WorkspaceID, _ s: RelaySession) async throws
  func leave(ws: WorkspaceID, _ s: RelaySession) async throws                   // D7 deregistration, gap G6
  func dropPut(_ o: DropUpload, _ s: RelaySession) async throws
  func dropList(ws: WorkspaceID, since: Cursor?, _ s: RelaySession) async throws -> DropPage
  func dropGet(_ id: ObjectID, version: UInt32, _ s: RelaySession) async throws -> DropBlob
}

public protocol WorkspaceAPI: Sendable {                      // above the bridge; what screens use
  func snapshot() async throws -> WorkspaceSnapshot           // questions, tickets, scopes, host label
  func decide(_ d: SignedDecision) async throws -> DecisionOutcome    // `decision` op, proto §13
  func newTicket(_ t: SignedTicketRequest) async throws        // `new_ticket` op (fields: gap G7)
  func events() -> AsyncStream<WorkspaceEvent>                 // long-poll driven
}
```

`BridgeWorkspaceAPI` implements `WorkspaceAPI` over `BridgeSession` (seq window, rid store, epoch handling,
`stale_epoch` → `grants` → resend, clock offset, response checks of proto §8.8). Screens and view models see
only `WorkspaceAPI`, `DropService` and `PairingCoordinator`. SwiftUI previews use a static `PreviewWorkspaceAPI`;
Demo and tests never do (they use the real stack on FakeRelay).

Rejected: faking at `WorkspaceAPI` level for the demo. It is quicker for week one, but it leaves pairing,
sealing, epochs and push unexercised until M1, which is where the risk is.

### 3.3 FakeRelay, FakeHost, FakePrimary

All three are actors in `OrchFakeHost`, wired to one injected `Clock` (UI tests run it at ×60, so 10-minute
windows take 10 s).

- **FakeRelay**: mailboxes per `(ws, device)` and per offer, 60 s body lifetime, the person queue for
  `cert_request`/`cert_challenge`, directory (certs, cards, revocations), grants per `(ws, device, epoch)`,
  member lists with the proto §7.2 checks, push registrations, Drop objects. It enforces proto §8.9 (header
  device = session device, member list) so the app meets real refusals.
- **FakeHost** (the host side of proto §8.3), keys `WSK`, `WXK`, `WK_e`:
  1. `createOffer(scopes:)` → `offer_id`, `S`, `sas_nonce` (32 B); link
     `https://relay.demo.invalid/pair#v2.<ws>.<offer>.<S>.<wsk_pin>.<pk_pin>`; 10 min, single use.
  2. On an epoch-0 envelope: proto §8.6 steps 1–3 (shape, offer key `K_pair`, tag: silence on failure), then
     §8.3.3 in order (meta → offer open/unused or same-key resend → `device_id` + signature → window → cert
     checks), refusals with `wsk_pub`, offer budget 5/min; marks the offer used, records the cleaned label,
     answers `pending` with `sas_nonce` and the key echo; exposes `HostScreen(code:, label:)` to the panel.
  3. Approve (only after the panel's "codes match" switch; default Reject): valid cert or `hostIsPrimary` →
     step 6; else `cert_pending`: a `WSK`-signed `cert_request` with `inner` sealed to the primary's `dk_kx`
     (purpose `cert-request`), posted to the person queue; `pair_status` answers `cert_pending` with
     `primary_label`, `pk_pub`, the relayed challenge or `null`; `expired` after 10 min.
  4. Step 6: upload the certificate, seal `WK_e` to the phone's `dk_kx` (purpose `wk`), sign the `wk_grant` with
     `WSK`, publish the member list (`list_seq + 1`), answer `approved` with scopes, cert, `pk_pub`, epoch.
  5. Bridge: `http` (provisional host API, gap G7), `decision` (field set, detached signature,
     compare-and-set, `already_answered`, `question_changed`), `new_ticket`, `member_remove`, `drop_rewrap`;
     rotation (new `WK_{e+1}`, grants, list, end streams with `stale_epoch`); push sealing (`K_push`, `WSK`
     signature, `ts_ms`) and fan-out to registrations.
- **FakePrimary** holds the person key `PK` (software; the demo's "Mac"): proto §8.4.2 checks in order,
  draws `primary_nonce` after receiving the keys, signs `cert_challenge`, shows `cert_code`, and on confirm signs
  exactly its challenge's keys once (`already_signed`), one open request per workspace.
- **Scenarios** (launch argument or panel): `firstTime` (default), `existingCert`, `hostIsPrimary`,
  `primaryOffline`, `linkUsed`, `r1Attack` (host asks the primary for its own key → phone must alarm),
  `echoWrongKey`, `otherPerson`, `rejectOnHost`, `rejectOnPrimary`, `revokeAfter(s)`.

**Keeping the fake honest**: `OrchFakeHost` has its own vector tests: host-side `bridge.host_cases`
(47, suite 2), `cert_request.*`, `wk_grants`, `member_lists`, push sealing re-opened by `push.cases`' opener,
and the two proto §16 round trips (`pairing_through_cert_pending`, `r1_attack_fails`) run app-side-against-fake.
The FakeHost's code is test-grade but ships in the binary for Demo; it is never reachable outside the demo
realm (`relay.demo.invalid` host, demo keychain prefix).

### 3.4 Key custody (D49 policy)

```swift
public protocol DeviceCustody: Sendable {
  var kind: CustodyKind { get }                         // .secureEnclave | .software
  func deviceKeys(realm: Realm) throws -> DeviceKeys?   // nil = not created
  func createDeviceKeys(realm: Realm) throws -> DeviceKeys
  func destroyDeviceKeys(realm: Realm) throws
}
public struct DeviceKeys: Sendable { let sig: any DeviceSigner; let kx: any KeyAgreementKey }  // proto §1.1: two keys
public protocol DeviceSigner: Sendable { var publicKey: P256.Signing.PublicKey { get }; func sign(_ m: Data) throws -> Sig64 }
public protocol KeyAgreementKey: Sendable { var publicKey: P256.KeyAgreement.PublicKey { get }; func agree(_ p: P256.KeyAgreement.PublicKey) throws -> Data }
public protocol SecretVault: Sendable {                  // WK_e, K_push, pins
  func putWK(_ k: SymmetricKey, ws: WorkspaceID, epoch: UInt32) throws
  func wk(ws: WorkspaceID, epoch: UInt32) throws -> SymmetricKey?
  func putPushMaterial(_ m: PushMaterial, ws: WorkspaceID) throws   // K_push per epoch, wsk_pub, display name
  func wipe(ws: WorkspaceID) throws
}
```

| Item | Backend (device) | Keychain group | Accessibility | Notes |
|---|---|---|---|---|
| `dk_sig` | SE, `.privateKeyUsage` only (D49: no presence flag) | `<TEAM>.io.severin.orch.keys` | `WhenPasscodeSetThisDeviceOnly` | blob is the custody boundary (S1) |
| `dk_kx` | SE, `.privateKeyUsage` | same | `WhenPasscodeSetThisDeviceOnly` | grants are opened in the foreground only, so no `AfterFirstUnlock` (S1 suggested it for background; we have no background opener) |
| `WK_e` (each held epoch) | generic password | `…orch.keys` | `WhenUnlockedThisDeviceOnly` | app + share extension |
| certificate(s), keyed by `person_id` | generic password | `…orch.keys` | `WhenUnlockedThisDeviceOnly` | public, but integrity matters |
| `K_push(ws,e)`, pinned `wsk_pub`, ws display name | generic password | `<TEAM>.io.severin.orch.push` | `AfterFirstUnlockThisDeviceOnly` | the only thing the NSE can read (S2) |

Never synchronizable; every query passes `kSecUseDataProtectionKeychain` and an explicit access group.

- **Simulator**: `SoftwareCustody` (CryptoKit `P256.*.PrivateKey`, raw bytes in the keychain,
  `WhenUnlockedThisDeviceOnly`, because the Simulator has no passcode and `WhenPasscodeSet` items fail there).
  Compiled only under `#if targetEnvironment(simulator)`. `SecureEnclave.isAvailable` is never consulted (S1:
  it is `true` in the Simulator).
- **Device, including Demo and TestFlight**: `SecureEnclaveCustody`, no fallback; no passcode → stop with an
  explanation. Demo uses its own SE keys under the demo realm prefix.
- **Reinstall**: keychain items survive app deletion; containers do not. On launch, if the realm index is
  missing but keychain items exist, delete all items in both groups for that realm before anything else.
- **Tests**: `swift test` injects `SoftwareCustody` built from vector seeds (S1's `scalar(fromSeed:)`, test-only).

### 3.5 Storage

**Engine: SQLite3 C API behind a ~300-line wrapper.** Data per workspace is small (pins, epoch, seq counters,
rid store, cached snapshot, Drop index, decision outbox). We need exact control of file protection, WAL,
`close on lock` and deletion; and the reviewer must read every line.

- Rejected **GRDB**: excellent, but a large third-party dependency in a security-reviewed binary, for features
  (record mapping, observation) we can do with 20 lines of `@Observable`.
- Rejected **SwiftData**: weak control over file placement and protection per store, awkward with actors and
  extensions, migrations opaque, and "delete exactly this workspace's store and nothing else" is harder to prove.

Layout:

```
<app container>/Library/Application Support/orch/        (not App Group; isExcludedFromBackup)
  <realm: live|demo>/index.sqlite                        workspace ids, order, tombstones   Complete
  <realm>/ws/<ws_hex>/ws.sqlite (+ -wal, -shm)           one store per workspace            Complete
  <realm>/ws/<ws_hex>/files/<object>.<version>           decrypted Drop files, QuickLook    Complete
  <realm>/ws/<ws_hex>/tmp/                               partial downloads                  Complete
<App Group group.io.severin.orch>/
  push/last-shown.json + .lock                           NSE replay table (S2)       UntilFirstUserAuthentication
  share/targets.json                                     ws id, display name, hue    Complete (ext runs unlocked)
  share/outbox/<uuid>/{descriptor,wraps,blob}            sealed, ready to upload     CompleteUnlessOpen
```

- The protection class is set on each directory at creation; files inherit it. SQLite is opened with
  `SQLITE_OPEN_FILEPROTECTION_COMPLETE`; `WorkspaceContainer` closes every handle on
  `protectedDataWillBecomeUnavailable` and reopens on `…DidBecomeAvailable`. The app does no locked
  background work in M0.
- No cross-workspace table exists anywhere except `index.sqlite`, which holds ids and order only (names live in
  each workspace store; the share list's names are a deliberate, documented copy).
- **Wipe(ws)** is one function, in this order: cancel the workspace's tasks → unregister push → keychain
  `SecretVault.wipe(ws)` (both groups) → remove the share target → close and delete `ws/<ws_hex>/` → delete the
  index row → purge replay-table entries for `ws`. `orch-mobile#1`'s acceptance test enumerates the container
  and both keychain groups afterwards.
- Leaving the last workspace keeps the device keys and certificate (re-pairing then skips `cert_pending`);
  *Reset this iPhone* removes them too. (Owner decision: §5 D-1.)

### 3.6 State and concurrency

- Swift 6 language mode, strict concurrency complete, all Core types `Sendable`.
- Actors: `BridgeSession` and `WorkspaceSession` (one per workspace), `PairingCoordinator`, `DropService`,
  `FakeRelay`, `FakeHost`, `FakePrimary`. Crypto runs on the calling actor (SE signatures cost ~6 ms).
- UI: `@MainActor @Observable` models: `AppModel` (realm, workspace list, routing, scene phase),
  `WorkspaceModel` (snapshot, connection state, needs-you count), `PairingModel` (state machine projection),
  `DropModel`. Views own no logic beyond formatting. `Environment` injects `AppModel`; no singletons.
- Each `WorkspaceSession` owns its long-poll `Task`; `scenePhase == .background` cancels all polls (60 s body
  lifetime makes background polling pointless without silent push); `.active` reconciles every shown question
  (spec §8 "reconcile on open").
- Navigation: one `NavigationStack(path:)` with a typed `Route` enum (`workspace(ws)`, `question(ws, id)`,
  `ticket(ws, key)`, `file(ws, obj)`, `needsYou`, `drop`, `settings…`). Deep links and notification taps produce
  `Route` values after verification.
- Errors: a closed `OrchError` enum mapped to fixed user text per code (proto §14: "a device shows its own
  fixed text per code"). Host-supplied strings are never shown in error UI.

### 3.7 Dependency policy

Apple frameworks only in every shipped target: SwiftUI, CryptoKit, Security, LocalAuthentication,
AVFoundation, PhotosUI, QuickLook, UserNotifications, SQLite3, os. Any exception is a decisions-log entry
with the reviewer's sign-off. Dev tools (xcodegen, swift-format) live outside the binary and are pinned in
`bin/bootstrap`. No SwiftPM plugins, no CocoaPods, no binary frameworks.

### 3.8 Launch arguments and environment (DEBUG builds and UI tests)

| Argument | Effect |
|---|---|
| `-orch.realm demo` | start in the demo realm (also the TestFlight Demo switch's persisted value) |
| `-orch.reset all` | wipe both realms and both keychain groups before launch |
| `-orch.seed <name>` | `empty`, `default`, `twoWorkspaces`, `clientHosted`, `longQuestion`, `oddText` |
| `-orch.scenario <name>` | FakeHost scenario (§3.3) |
| `-orch.clock.speed 60` / `-orch.clock.fixed <ms>` | fake clock |
| `-orch.keys deterministic` | software keys from a fixed seed (Simulator only), so `tools/orch-fake` can produce matching `.apns` files |
| `-orch.uitest` | disables animations and the 0.8 s arming delay becomes 0.1 s (never 0), shows the debug menu |
| `-orch.pairLink <link>` | opens the pairing flow with this link (no camera, no pasteboard) |
| `-orch.injectPush <path>` | feeds an APNs JSON file through the same handler as `willPresent` |
| `-orch.share <fixture>` | presents the share composer in-app with fixture items |
| `-orch.storageReport` | Diagnostics shows a listing of the container and keychain item counts per group |

These are parsed by one `LaunchConfig` and **ignored in Release builds**, except `-orch.realm` which Release
reads only from its own persisted setting.

### 3.9 Share extension

- Activation rule: files, images, movies, text and URLs; max 10 items; 250 MB total (the Drop chunk format
  allows more; the extension's memory does not).
- UI: SwiftUI composer: workspace picker (from `share/targets.json`, rail + name, hosted marker), item
  previews, optional note, expiry (1 d / 7 d / 30 d), *Send*. No sign sheet: a Drop put is not a human approval
  (D49 makes the key usable while unlocked; spec §6.4 signs the descriptor with `dk_sig`).
- Work: stream each item through `OrchProtocol.DropSealer` (fresh DEK per version, ORD2 chunks, sealed meta,
  `wk` wrap under the current `WK_e`, descriptor signed with `dk_sig`, `origin: human`) into
  `share/outbox/<uuid>/`, then finish. M1: also start a background `URLSession` upload with the outbox as source;
  the app removes outbox entries the relay confirms.
- The app drains the outbox on every foreground and shows "Sending 2 files" on the Drop card.
- No workspace yet → "Pair a workspace in orch first."

---

## 4. Testing

| Layer | Tool | Runs where | What |
|---|---|---|---|
| T0 | `swift test` (Core, macOS) | laptop, CI on every push | all suite 2 vectors in scope for a phone: encodings, sign, hkdf, salted_aead, seal/seal_open, certs, wk_grants, member_lists, bridge.seal/links/sas/device_cases/pair_answers, cert_request challenge + code, push.cases, drop (blob, meta, wraps, descriptors), question_hash, decisions, relay_auth. FakeHost host_cases. Round trips app-side ↔ FakeHost: first-time pairing through `cert_pending`, R1 attack alarm, existing cert, `stale_epoch` after rotation, decision CAS, push open + replay, Drop both directions. Safe-text inspector cases ported from TIX's tests. Wipe completeness on a temp dir. |
| T1 | `xcodebuild test` AppTests (Simulator) | laptop, CI on every push | keychain groups (software custody), container protection attributes, reinstall cleanup, view-model state machines, `LaunchConfig` ignored in Release. |
| T2 | XCUITest (Simulator) | laptop per PR group, CI nightly + on label | the scenario list below |
| T2 | `e2e/ios/*.sh` with `simctl` | laptop | push delivery, generic fallback, tap routing; share sheet smoke |
| T3 | TestFlight build, iPhone session | owner, end of M0 (Demo) and M1 (live) | camera, SE, NSE process, real APNs |

**XCUITest scenarios** (each with `-orch.reset all -orch.uitest -orch.clock.speed 60`):
pair first time through `cert_pending` via `-orch.pairLink`, approving in the Simulated Mac panel; pair a second
workspace with the existing certificate (no `cert_pending`); reject on host; reject on primary; `cert_pending`
expiry; link used (`pairing_closed`); R1 attack → alarm, no code shown; answer a question (sign sheet: armed only
after scrolling; text markers visible) → Applied; answered on Mac first → `already_answered` text and greyed
question; question changed; leave workspace → `-orch.storageReport` shows nothing for that `ws` in either
keychain group or the container; removed by the Mac → tombstone; key rotation while open → transparent resend;
Drop: phone → workspace (the panel shows the decrypted file name and hash) and workspace → phone (QuickLook
opens); share composer via `-orch.share`; injected push (`-orch.injectPush`) → verified in-app banner → tap
navigates; tampered push → generic text, no navigation; demo realm isolation (live Home empty after demo).

**`simctl push`.** `tools/orch-fake push --seed deterministic --ws A --kind question --id …` writes the `.apns`
JSON (the S2 shape: fixed `aps.alert`, `mutable-content`, `o` as a string). `e2e/ios/push.sh <udid>` launches
the app with `-orch.keys deterministic -orch.seed default`, pushes, and checks: background → the fixed generic
banner (the NSE does not run in the Simulator, S2); foreground → the verified content via `willPresent`; tap →
route. XCUITest cannot call `simctl`; the script coordinates with a running UI test through a marker file in a
host directory passed as `SIMCTL_CHILD_ORCH_E2E_DIR` (the Simulator shares the host filesystem). This is T2,
not a CI gate.

**Share extension.** Logic in `swift test` (sealer, outbox format, open by FakeHost). Composer UI through
`-orch.share`. One smoke test drives the real extension: the app's debug menu has a `ShareLink` with a fixture
file; XCUITest picks "orch" in the share sheet (an app's own extensions appear there) and asserts the outbox
entry. If the share sheet proves flaky in CI, that one test moves to the `e2e` script.

**GitHub macOS CI** (`.github/workflows/ci.yml`):
- `core`: `macos-15` (or the newest image with Xcode ≥ 16.4), `swift test --parallel` in `Core/`, check
  `VECTORS.lock` sha256. Every push and PR, ~3 min.
- `app`: `brew install xcodegen`, `xcodegen`, `xcodebuild build-for-testing` + `test-without-building`
  for AppTests on an iPhone 16 / iOS 18 Simulator; unsigned (`CODE_SIGNING_ALLOWED=NO` for tests). Every PR.
- `ui`: XCUITest suite; nightly on `develop` and on PRs labelled `ui-tests` (macOS minutes cost 10×).
- Merge only on green (`gh pr checks`), as the owner's rule says.
- **TestFlight is not built in CI** in M0: `bin/testflight` runs on the laptop: `xcodegen`, `xcodebuild archive`
  with automatic signing and the ASC API key (`-allowProvisioningUpdates -authenticationKeyPath …`),
  `-exportArchive` with `method app-store-connect`, upload; build number = UTC timestamp `yyMMddHHmm`. The `.p8`
  never leaves the laptop. CI signing can come later with an encrypted secret if the owner wants it.

---

## 5. Risks, inconsistencies and gaps

### 5.1 Spec and protocol inconsistencies

| # | Where | Problem | Proposal |
|---|---|---|---|
| I1 | spec §2 non-goals | Still lists "A native mobile app", contradicting D45. | Delete the line. |
| I2 | spec §3 table, §4, §7 "Unlock sheet … asks for Face ID", §7 step 5 "fresh Face ID signature"; orch-mobile README (D46 line); issues #3 "biometric-gated", #4 "Face ID", #7 "Face ID presence" | All contradict D49 (no per-signature Face ID on iPhone). | Amend the text and the issues to D49; the sign sheet is the human act. |
| I3 | spec §7 step 1 vs proto §8.3.1 | Spec: `orch://pair#v2.<ws>.<offer>.<secret>.<wsk_pin>` (4 fields) and `https://<relay>/pair#`. Proto: `https://<relay>/app/pair#v2…` with a fifth field `pk_pin`. | Five fields everywhere; path `/pair` (D54: no `/app`). The app parses the fragment identically for both forms. |
| I4 | spec §7 custom scheme | `orch://pair#…` carries **no relay URL**; the phone cannot know where to send the pair request. | Either drop the custom scheme from QR codes (universal link only) or define `orch://pair?relay=<url-encoded origin>#v2…`. Recommended: QR is always the https form; `orch://` only for copy/paste with `?relay=`. |
| I5 | proto header, §1, §8.7, §9, §14, §18 R2/R5 | Still describes "orch mobile: the PWA", suite 1 as primary, WebAuthn passkey registration in pairing step 6.4, "service worker", "Web Push payload", `tag = id`, R2 web-delivered JS. | Adopt S1/S2 wording proposals; replace §9's receiver text with the NSE rules from S2. |
| I6 | proto §8.6 step 11, §8.7, §14 | The Type scope and typing lease rely on WebAuthn assertions (`assertion_required`, `assert` op). There is no native replacement defined. Under D49 a `dk_sig` signature adds nothing over the envelope signature. | Decide for P4: Type needs a fresh `sig_decision`-style detached signature over the assert challenge from the sign sheet, or Type is out of P4. M0 hides Terminal. |
| I7 | spec §6.3 | "The NSE … sets `thread-id` and `apns-collapse-id` to the id." The NSE cannot set `apns-collapse-id` (an APNs request header the relay sends), and S2 recommends no relay `thread-id`. | NSE sets `threadIdentifier` locally and removes by `(ws,id)`; collapse id optional per S2's HMAC proposal, owner decision. |
| I8 | spec §6.3 vs proto §13 | "`question.closed` … rendered from the sealed fetch" vs a push payload whose `label` already is "Answered on <device label>". | Proto wins: no fetch in the NSE. |
| I9 | spec §5.1 "DK signing + key agreement" | Proto §1.1 and S1: two SE keys, `dk_sig` and `dk_kx`. | Amend spec §5.1. |
| I10 | spec §6.3 kinds `join` | No payload meaning for the phone is defined. | Define (another device joined?) or drop for the phone. |
| I11 | issue #1 "data protection `complete`" | Fine, but SQLite with `Complete` fails when the phone locks with an open handle. | Close on lock (§3.5); document in the issue. |

### 5.2 Gaps the phone needs filled before M1

- **G1 Universal link plumbing.** The relay must serve `/.well-known/apple-app-site-association` (a JSON file;
  D54 says "no pages" — needs an explicit allowance) for `relay.dev.severin.io` and `relay.orch.severin.io`.
  Associated domains are fixed at build time, so a self-hosted internal relay (D5) can never be a universal
  link: it needs I4's custom-scheme form.
- **G2 APNs environment.** TestFlight builds use the **production** APNs gateway even while they talk to the
  dev relay (D48); Xcode-installed builds use sandbox. Push registration must carry `env`, and the relay must
  pick the gateway per registration.
- **G3 Pairing transport.** Proto §8.9 has "an unauthenticated pairing route" but no endpoint or how the device
  polls epoch-0 answers (`pair_status`) for its offer. FakeRelay defines one provisionally.
- **G4 Relay session for the phone across workspaces.** One `device_id` everywhere; is a session per relay or
  per workspace? FakeRelay: one session per relay, scoped by member lists.
- **G5 Grants and member list fetch endpoints** are described (proto §7.3) but not specified as HTTP routes.
- **G6 Push registration and deregistration** (`POST /push/…`, `leave`) are in spec §6.3/D7 but have no wire
  form. The APNs token is the same for every workspace, so the relay links them (accepted under R4; say so).
- **G7 The host API over the bridge** (`http` op mapping, F3): question list, ticket list, ticket detail, files
  list, `new_ticket` fields. M0 defines a provisional `host-api v0` in FakeHost
  (`GET /v2/snapshot`, `GET /v2/tickets/<key>`, `GET /v2/drop`), documented in `docs/host-api-v0.md`, for
  orch-core to accept or replace. Highest drift risk in this plan.
- **G8 Is the phone ever the primary device?** Issue #4 asks for "Revoke UI on the primary device … in the
  app". If the phone can be primary, P4 must add recovery-code entry (D50), `PK` custody (software key wrapped
  by an SE key), the cert-request queue, `cert_code` confirmation and revocation signing. Recommendation: no
  in P4; the Mac is primary; the phone shows "Revoke on <primary>". Owner decision.
- **G9 Device labels.** The phone cannot read other devices' `label_sealed` (no `PVK`). Member lists and
  "Answered on <device>" therefore come from the host. Fine, but the Settings members view depends on G7.
- **G10 Multiple people's certificates (D1 C, P8).** One device key, possibly certificates from several
  persons. Store certificates keyed by `person_id` now and select by the link's `pk_pin`.
- **G11 Workspace display name source.** The sealed card part (purpose `card`, `CK`) or a bridge answer?
  Both are possible; FakeHost sends the card `CK` to the phone at approval. Needs a decision.

### 5.3 Platform and delivery risks

| Risk | Mitigation |
|---|---|
| `simctl push` never runs the NSE (S2); the NSE process, its memory and time limits and locked-phone keychain access are unproven. | `OrchPush` small and tested as a library; in-app injection hook; real-process check in the first iPhone session with real APNs (M1). |
| Simulator SE is emulated (`isAvailable == true`); `WhenPasscodeSet` items fail without a passcode. | Software custody in the Simulator by build target; SE behaviour (classes, reinstall, passcode removal deletes keys) in iPhone session 1 on a Demo TestFlight build. |
| Removing the iPhone passcode deletes `WhenPasscodeSet` keys; the phone silently loses its identity. | Detect on launch (keys missing, index present) → wipe all workspaces with a clear explanation; re-pair. |
| Keychain items survive uninstall. | Reinstall cleanup (§3.4). |
| FakeHost and app agree with each other but not with orch-core. | Vectors on both sides; `host-api v0` reviewed by orch-core before M1; the fake is deleted from test paths once the real relay e2e exists (kept for Demo). |
| Shipping FakeHost in a TestFlight binary confuses data realms. | Separate realm, `.invalid` relay host, demo keychain prefix, violet stripe, wipe on exit. |
| Export compliance: E2E encryption with standard algorithms. | Set `ITSAppUsesNonExemptEncryption` and answer the ASC questionnaire once (owner); likely exempt, but it blocks TestFlight distribution until answered. |
| App Group `group.io.severin.orch` cannot be registered via the API (memory note). | First signed archive with automatic signing registers it; do this once interactively before CI ever signs. |
| CI images lag Xcode versions; the laptop runs Xcode 27. | Pin `DEVELOPER_DIR` per job, keep iOS 18 deployment target, build with the newest Xcode the runner has; don't use Xcode-27-only APIs. |
| Sign sheet usability vs. safety (two codes in `cert_pending`, R8). | Follow proto §8.4 UI rules exactly; test in iPhone session 1 with the owner. |
| App-switcher snapshots expose codes and questions. | Privacy overlay when not active (§1.4). |
| `already_answered` races between phone and Mac. | Host CAS is authoritative; phone shows the refusal text, never an error. |

### 5.4 Owner decisions requested

- **D-1** Keep device keys and certificate after leaving the last workspace (recommended) or wipe them too.
- **D-2** Phone never primary in P4 (G8, recommended).
- **D-3** QR always as the universal link; `orch://` only with `?relay=` (I4).
- **D-4** `apns-collapse-id`: skip (recommended, S2's safer default) or the HMAC form.
- **D-5** Type scope on the phone: out of P4 (recommended for now) or a defined sign-sheet signature (I6).
- **D-6** Workspace name source: sealed card vs bridge (G11).

---

## 6. M0 build order (suggested slices, one PR each into `develop`)

1. Project skeleton: xcodegen, three targets, OrchKit with empty modules, CI `core` + `app`, tokens + Home
   with static preview data.
2. OrchProtocol with vectors (port of S1 `S1Support` and S2 `PushCore`, hardened to Swift 6).
3. OrchCustody + OrchStore + wipe, with AppTests.
4. FakeRelay/FakeHost/FakePrimary pairing + the pairing flow UI + XCUITests for every pairing scenario.
5. Bridge session, host-api v0, Questions/Tickets, sign sheet, decisions.
6. Push: OrchPush, NSE target, injection hook, `tools/orch-fake`, `simctl` script, demo local notifications.
7. Drop basics + share extension + outbox.
8. Demo mode polish, Settings, Leave/revoke, `bin/testflight`, first Demo TestFlight build, iPhone session 1
   checklist (`e2e/iphone/session-1.md`: install, Demo pairing incl. `cert_pending` codes, sign sheet, SE key
   created and survives relaunch, passcode-removal behaviour, share from Photos, privacy overlay).
